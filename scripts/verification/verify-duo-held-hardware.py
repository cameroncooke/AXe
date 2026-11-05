#!/usr/bin/env python3
"""Run one library or public CLI held-button interruption, without replay.

The library probe uses DOWN / delay6 / UP. This equals the selected CLI factory's
value sequence by source review, but does not call the CLI-private factory or
exercise its broker admission. Normal app return and fresh input are separate.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--button', choices=['home', 'side-button'], required=True)
parser.add_argument('--mode', choices=['fold', 'rotate'], required=True)
parser.add_argument('--fold-angle', type=float, default=0)
parser.add_argument('--cli', required=True)
parser.add_argument('--device', required=True)
parser.add_argument('--pid', type=int, required=True)
parser.add_argument('--probe', required=True)
parser.add_argument('--operator', required=True)
parser.add_argument('--out', required=True)
parser.add_argument('--public', action='store_true', help='Use the real public CLI; no independent live down marker')
args = parser.parse_args()
assert args.pid > 0 and 0 <= args.fold_angle <= 180
if args.public:
    # A per-proof worker is started with this flag, then stopped after safe cleanup.
    os.environ['FBSIMULATORCONTROL_LOG_HID_DETAILS'] = '1'
args.case = ('public-held-' if args.public else 'library-held-') + args.button + '-' + args.mode
spec = importlib.util.spec_from_file_location('duo_controls', Path(__file__).with_name('verify-duo-controls.py'))
controls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controls)
check = controls.Check(args)
probe = None
probe_files = []
probe_command = None
probe_started = None
probe_saved = False

class PublicHardwareBroker:
    """Test-only exact worker lifetime. Never reads a process environment."""
    def __init__(self, check):
        self.check = check
        self.created = None
        self.input_started = False
        self.cleanup_verified = False
        self.receipt = {'scope': 'this public hardware proof only', 'signals': [], 'prepared': False}
        source = Path(__file__).with_name('observe-media-process.py')
        spec = importlib.util.spec_from_file_location('hardware_kernel_identity', source)
        self.kernel = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.kernel)

    def identify(self, pid):
        # The same proc_bsdinfo/start/executable/UID binding as the existing broker restart test.
        value = self.kernel.BSDInfo()
        size = self.kernel.ctypes.sizeof(value)
        if self.kernel.libproc.proc_pidinfo(pid, 3, 0, self.kernel.ctypes.byref(value), size) != size:
            return None
        executable = self.kernel.ctypes.create_string_buffer(4096)
        if self.kernel.libproc.proc_pidpath(pid, executable, len(executable)) <= 0:
            return None
        return {'pid': pid, 'uid': value.uid, 'realUID': value.ruid,
                'startSeconds': value.startSeconds, 'startMicroseconds': value.startMicroseconds,
                'binary': str(Path(os.fsdecode(executable.value)).resolve(strict=True))}

    def find(self):
        # ps args excludes the environment. Do not use the media helper's argv/environment reader.
        result = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,uid=,args='],
                                capture_output=True, text=True, timeout=5, check=True)
        expected = self.check.cli + ' hid-broker --selected --udid ' + self.check.args.device
        matches = []
        for line in result.stdout.splitlines():
            fields = line.split(None, 2)
            if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit() and int(fields[1]) == os.getuid() and fields[2] == expected:
                matches.append(int(fields[0]))
        assert len(matches) == 1, 'Cannot identify exactly one owned broker; no signal was sent'
        identity = self.identify(matches[0])
        assert identity and identity['uid'] == identity['realUID'] == os.getuid() and identity['binary'] == self.check.cli
        return identity

    def unchanged(self, before, after):
        for key in ['counts', 'windowTouchTrace', 'text', 'textFocused', 'slider', 'switchOn',
                    'pageOffsetY', 'listOffsetY', 'pinchScale', 'rotationRadians']:
            assert before[key] == after[key], 'Broker preparation changed app input: ' + key

    def idle(self, name, expected_pid=None):
        arguments = ['describe-ui', '--agent', '--output', 'json', '--view', 'full']
        if expected_pid is not None:
            arguments += ['--expected-pid', str(expected_pid)]
        result = self.check.axe(name, *arguments)
        assert result.get('schema') == 'axe.output.agent-result' and result.get('didError') is False
        data = result['data']
        assert data.get('action') is None and data.get('quarantine') is None
        capture = data.get('capture')
        assert isinstance(capture, dict) and type(capture.get('applicationPID')) is int and capture['applicationPID'] > 0
        if expected_pid is not None:
            assert capture['applicationPID'] == expected_pid
        # This is the existing restart test's successful read-only broker-admission boundary.
        return capture

    def stop(self, owned):
        assert self.find() == owned and self.identify(owned['pid']) == owned
        os.kill(owned['pid'], signal.SIGTERM)
        self.receipt['signals'].append({'pid': owned['pid'], 'signal': 'SIGTERM', 'identity': owned})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            current = self.identify(owned['pid'])
            if current is not None:
                if (current['startSeconds'], current['startMicroseconds']) != (owned['startSeconds'], owned['startMicroseconds']):
                    return
            else:
                try:
                    os.kill(owned['pid'], 0)
                except ProcessLookupError:
                    return
            time.sleep(0.05)
        raise RuntimeError('Identified broker did not exit after SIGTERM; no further signal was sent')

    def prepare(self):
        assert os.environ.get('FBSIMULATORCONTROL_LOG_HID_DETAILS') == '1'
        before = self.check.state('hardware-broker-before-restart')
        self.idle('hardware-broker-old-idle', self.check.args.pid)
        owned = self.find()
        self.unchanged(before, self.check.state('hardware-broker-before-signal'))
        self.receipt['retired'] = owned
        controls.save(self.check.folder / 'hardware-diagnostic-broker.json', self.receipt)
        self.stop(owned)
        self.idle('hardware-broker-fresh-capture', self.check.args.pid)
        self.created = self.find()
        self.receipt['created'] = self.created
        assert self.created != owned, 'Hardware proof did not get a new broker'
        self.unchanged(before, self.check.state('hardware-broker-after-restart'))
        self.receipt['prepared'] = True
        controls.save(self.check.folder / 'hardware-diagnostic-broker.json', self.receipt)

    def close(self):
        if self.created is None:
            return
        try:
            assert not self.input_started or self.cleanup_verified, 'Hardware cleanup is unverified; diagnostic broker was not signalled'
            before = self.check.state('hardware-broker-before-close')
            self.idle('hardware-broker-final-idle')
            self.unchanged(before, self.check.state('hardware-broker-after-final-idle'))
            self.stop(self.created)
            self.receipt['diagnosticBrokerExitConfirmed'] = True
        except BaseException as error:
            self.receipt['diagnosticBrokerExitConfirmed'] = False
            self.receipt['closeError'] = str(error)
            raise
        finally:
            controls.save(self.check.folder / 'hardware-diagnostic-broker.json', self.receipt)


diagnostic_broker = PublicHardwareBroker(check) if args.public else None


def finish_probe():
    global probe_saved
    if probe is None or probe_saved:
        return
    signals = []
    if probe.poll() is None:
        for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGKILL]:
            if probe.poll() is not None:
                break
            probe.send_signal(sig)
            signals.append(sig.name)
            try:
                probe.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
    receipt = dict(command=probe_command, pid=probe.pid, exitCode=probe.poll(),
                   reaped=probe.poll() is not None, signals=signals,
                   elapsedSeconds=time.monotonic() - probe_started)
    check.commands.append(receipt)
    controls.save(check.folder / 'hardware-probe-process.json', receipt)
    probe_saved = True
    for handle in probe_files:
        handle.close()


try:
    check.container()
    if diagnostic_broker is not None:
        diagnostic_broker.prepare()
    before = check.state('before')
    catalogue = check.catalogue('before-catalogue')
    check.description('before-description', catalogue, args.pid)
    active = catalogue['activePanel']['identity']
    helper = str(Path(check.cli).with_name('cadisplay-context'))
    down_marker = check.folder / 'down-marker.json'
    if args.public:
        probe_command = [check.cli, 'button', args.button, '--duration', '6',
                         '--expected-boot', catalogue['bootIdentity'], *check.selection(catalogue), '--udid', args.device]
    else:
        probe_command = [args.probe, args.device, catalogue['bootIdentity'], str(active['displayID']),
                         active['uniqueID'], helper, args.button, str(down_marker)]
    controls.save(check.folder / 'hardware-probe-argv.json', probe_command)
    probe_files = [(check.folder / 'hardware-probe-stdout').open('xb'), (check.folder / 'hardware-probe-stderr').open('xb')]
    probe_started = time.monotonic()
    probe = subprocess.Popen(probe_command, stdout=probe_files[0], stderr=probe_files[1],
                             env=dict(os.environ, FBSIMULATORCONTROL_LOG_HID_DETAILS='1'))
    if diagnostic_broker is not None:
        diagnostic_broker.input_started = True
    controls.save(check.folder / 'hardware-probe-started.json', {'pid': probe.pid, 'command': probe_command})
    marker = None
    if args.public:
        # This schedules the external action only. It is not evidence that a
        # native DOWN occurred; the final typed receipt bounds that claim.
        time.sleep(2)
        controls.save(check.folder / 'public-schedule.json', {'delaySeconds': 2,
                      'clock': 'driverMonotonic', 'scheduledAt': time.monotonic(),
                      'independentLiveDownMarker': False})
    else:
        deadline = time.monotonic() + 12
        while not down_marker.is_file():
            assert probe.poll() is None, 'Hardware probe ended before a held-down marker; no external write'
            assert time.monotonic() < deadline, 'No held-down marker before deadline; no external write'
            time.sleep(0.01)
        marker = json.loads(down_marker.read_text())
        assert marker['button'] == args.button and marker['normalDownSentCount'] == 1 and marker['state'] == 'executing'
        assert marker['normalSendCompleted'] and not marker['wholeGestureDrainCompleted']
    assert probe.poll() is None, 'Hold ended before the external write'
    change = check.run('external-change', [args.operator, args.mode, catalogue['bootIdentity'],
                       str(active['displayID']), active['uniqueID'], str(args.fold_angle),
                       str(check.folder / 'change-marker.json'), args.device, helper])
    probe.wait(timeout=12)
    assert probe.returncode == 1
    finish_probe()
    raw = json.loads((check.folder / 'hardware-probe-stdout').read_text())
    if args.public:
        execution = raw['home'] if args.button == 'home' else raw['button']['execution']
        assert execution['plannedPrimitiveCount'] == 2 and execution['sentPrimitiveCount'] == 1
        assert execution['boundContext'] == raw['context']
        receipt = {'outcome': raw['outcome'], 'normalEventCount': raw['enqueuedEventCount'],
                   'phase': execution['phase'], 'interruption': execution['interruption']['kind'],
                   'cleanup': raw['cleanup'], 'cleanupEvidence': execution['cleanupEvidence'],
                   'expectedRelease': 'Button home up' if args.button == 'home' else 'Button side_button up'}
        assert not raw.get('quarantine')
    else:
        receipt = raw
        assert receipt['downMarkerWritten']
    assert receipt['outcome'] == 'failedNoReplay'
    assert receipt['normalEventCount'] == 1 and receipt['phase'] == 'delay'
    assert 'staleContext' in receipt['interruption'] and receipt['cleanup'] == 'releaseEnqueuedAndDrained'
    cleanup = receipt['cleanupEvidence']
    assert cleanup['outcome'] == 'releaseEnqueuedAndDrained' and not cleanup['timedOut']
    assert cleanup['contextValidation'] == 'releaseIdentityMatchedBeforeAndAfter'
    assert len(cleanup['releases']) == 1
    release = cleanup['releases'][0]
    assert release['primitive'] == receipt['expectedRelease'] and '<hidden>' not in release['primitive']
    assert release['returnedSuccessfully'] and not release.get('errorDescription')
    transport = release['transport']
    assert transport['messageType'] == 'IndigoButtonEvent'
    assert transport['hostEnqueueCompletedUptime'] >= transport['startedUptime']
    assert transport['guestBarrierCompletedUptime'] >= transport['guestBarrierStartedUptime']
    assert change['startedUptime'] <= release['startedUptime']
    if marker is not None:
        assert marker['capturedUptime'] < change['startedUptime']
    assert cleanup['drainCompletedUptime'] >= release['finishedUptime']
    assert cleanup['identityBefore']['bootIdentity'] == cleanup['identityAfter']['bootIdentity'] == catalogue['bootIdentity']
    assert cleanup['boundScreenID'] == active['displayID']
    if diagnostic_broker is not None:
        diagnostic_broker.cleanup_verified = True
    after = check.state('after-cleanup')
    assert before['windowTouchTrace'] == after['windowTouchTrace'] and before['counts'] == after['counts']
    fresh = check.catalogue('after-catalogue')
    assert fresh['bootIdentity'] == catalogue['bootIdentity']
    if args.mode == 'fold':
        assert fresh['activePanel']['identity'] != active
    else:
        assert fresh['activePanel']['identity'] == active
        assert fresh['activePanel']['currentOrientation'] != catalogue['activePanel']['currentOrientation']
    check.result.update(button=args.button, mode=args.mode,
                        proof='publicCLIWithRetrospectiveTiming' if args.public else 'realLibrarySessionNotPublicCLI',
                        beforeContext=catalogue, afterContext=fresh, downMarker=marker,
                        exactOwnedRelease=release, normalEventCount=1,
                        cleanup='releaseEnqueuedAndDrained', freshTap='SEPARATE_TAIL_PENDING',
                        osPressedButtonInventory='UNVERIFIED', securityLock='UNVERIFIED', power='UNVERIFIED')
except BaseException as error:
    finish_probe()
    check.finish(error)
    raise
finally:
    finish_probe()
    if diagnostic_broker is not None:
        try:
            diagnostic_broker.close()
        except BaseException as error:
            check.finish(error)
            raise
check.finish()
