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
    # The initial description can start the broker before the hold command.
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
check.finish()
