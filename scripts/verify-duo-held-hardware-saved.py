#!/usr/bin/env python3
"""Verify saved held-hardware receipts and fresh taps. This sends no input."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, required=True)
args = parser.parse_args()
root = args.root


def read(file):
    return json.loads(file.read_text())


def process(file, exit_code):
    value = read(file)
    assert value['exitCode'] == exit_code and value['reaped'], str(file)
    assert not value.get('signals', value.get('signalsSent', [])), str(file)
    assert value.get('stopReason') is None, str(file)
    return value


candidate = read(root / 'hardware-candidate.json')
for pin in candidate['pins']:
    assert hashlib.sha256(Path(pin['path']).read_bytes()).hexdigest() == pin['sha256'], pin['path']
device = candidate['device']
boot = candidate['boot']
pid = candidate['pid']
cases = [('hardware-home-fold', 'home', 'fold', False),
         ('hardware-home-rotate-inner', 'home', 'rotate', False),
         ('hardware-side-fold', 'side-button', 'fold', False),
         ('hardware-side-rotate-inner', 'side-button', 'rotate', False),
         ('hardware-public-home-fold', 'home', 'fold', True),
         ('hardware-public-side-rotate-inner', 'side-button', 'rotate', True)]
summary = {'status': 'BOUNDED_HELD_HARDWARE_AND_REFIND_PROVED', 'candidatePins': len(candidate['pins']),
           'cases': [], 'osPressedButtonInventory': 'UNVERIFIED', 'securityLock': 'UNVERIFIED',
           'power': 'UNVERIFIED', 'productionChange': False, 'security': 'UNVERIFIED'}
for name, button, mode, public in cases:
    folder = root / name
    result = read(folder / 'result.json')
    assert result['status'] == 'PASSED_BOUNDED' and result['device'] == device
    before = result['beforeContext']
    after = result['afterContext']
    assert before['bootIdentity'] == after['bootIdentity'] == boot
    panel = before['activePanel']['identity']
    after_panel = after['activePanel']['identity']
    if mode == 'fold':
        assert panel['displayID'] == 3 and after_panel['displayID'] == 1
    else:
        assert panel == after_panel and panel['displayID'] == 3
        assert before['activePanel']['currentOrientation'] != after['activePanel']['currentOrientation']
    raw = read(folder / 'hardware-probe-stdout')
    expected_up = 'Button home up' if button == 'home' else 'Button side_button up'
    if public:
        execution = raw['home'] if button == 'home' else raw['button']['execution']
        assert execution['plannedPrimitiveCount'] == 2 and execution['sentPrimitiveCount'] == 1
        assert execution['boundContext'] == raw['context']
        assert execution['simulatorUDID'] == device
        assert raw['context']['bootIdentity'] == boot and raw['context']['screenID'] == panel['displayID']
        assert raw['context']['screenUUID'] == panel['uniqueID']
        assert execution['phase'] == 'delay' and execution['interruption']['kind'] == 'staleContext'
        assert raw['enqueuedEventCount'] == 1 and not raw.get('quarantine')
        assert not execution['allInputsReleasedBeforeCleanup'] and not execution['drainCompleted']
        cleanup = execution['cleanupEvidence']
        schedule = read(folder / 'public-schedule.json')
        assert not schedule['independentLiveDownMarker'] and schedule['delaySeconds'] == 2
        command = read(folder / 'hardware-probe-argv.json')
        assert command[:3] == [candidate['cli'], 'button', button] and '--input-mode' in command
        assert '--expected-boot' in command and boot in command and '--duration' in command and '6' in command
        assert not (folder / 'down-marker.json').exists()
    else:
        assert raw['normalEventCount'] == 1 and raw['phase'] == 'delay'
        assert 'staleContext' in raw['interruption'] and raw['downMarkerWritten']
        assert not raw['allInputsReleasedBeforeCleanup'] and not raw['normalDrainCompleted']
        marker = read(folder / 'down-marker.json')
        assert marker['source'] == 'publicLibrarySessionStatus' and marker['normalDownSentCount'] == 1
        assert marker['button'] == button and marker['device'] == device and marker['boot'] == boot
        assert marker['state'] == 'executing' and marker['normalSendCompleted']
        assert not marker['wholeGestureDrainCompleted'] and marker['screenID'] == panel['displayID']
        assert marker['screenUUID'] == panel['uniqueID']
        cleanup = raw['cleanupEvidence']
    assert raw['outcome'] == 'failedNoReplay' and raw['cleanup'] == 'releaseEnqueuedAndDrained'
    assert cleanup['outcome'] == 'releaseEnqueuedAndDrained' and not cleanup['timedOut']
    assert cleanup['contextValidation'] == 'releaseIdentityMatchedBeforeAndAfter' and cleanup['trigger'] == 'staleContext'
    assert cleanup['boundSimulatorUDID'] == device and cleanup['boundBootIdentity'] == boot
    assert cleanup['boundScreenID'] == panel['displayID'] and cleanup['boundScreenUUID'] == panel['uniqueID']
    assert len(cleanup['releases']) == 1
    release = cleanup['releases'][0]
    assert release['primitive'] == expected_up and release['returnedSuccessfully'] and not release.get('errorDescription')
    transport = release['transport']
    assert transport['messageType'] == 'IndigoButtonEvent'
    assert release['startedUptime'] <= transport['startedUptime'] <= transport['hostEnqueueCompletedUptime']
    assert transport['hostEnqueueCompletedUptime'] <= transport['guestBarrierStartedUptime']
    assert transport['guestBarrierStartedUptime'] <= transport['guestBarrierCompletedUptime'] <= release['finishedUptime']
    assert release['finishedUptime'] <= cleanup['drainStartedUptime'] <= cleanup['drainCompletedUptime'] <= cleanup['finishedUptime']
    for identity_name in ['identityBefore', 'identityAfter']:
        identity = cleanup[identity_name]
        assert identity['simulatorUDID'] == device and identity['bootIdentity'] == boot
        assert identity['screenID'] == panel['displayID'] and identity['screenUUID'] == panel['uniqueID']
        assert identity['nativePixelWidth'] == cleanup['boundNativeWidth']
        assert identity['nativePixelHeight'] == cleanup['boundNativeHeight'] and identity['scale'] == cleanup['boundScale']
    assert cleanup['identityBefore']['finishedUptime'] <= release['startedUptime']
    assert cleanup['drainCompletedUptime'] <= cleanup['identityAfter']['startedUptime']
    change = read(folder / 'change-marker.json')
    assert change['startedUptime'] <= release['startedUptime']
    if not public:
        assert raw['executionStartedUptime'] <= marker['capturedUptime'] < change['startedUptime']
    process(folder / 'hardware-probe-process.json', 1)
    process(folder / 'external-change-process.json', 0)
    process(root / (name + '-guard') / 'result.json', 0)
    before_state = read(folder / 'before.json')
    after_state = read(folder / 'after-cleanup.json')
    assert before_state['counts'] == after_state['counts']
    assert before_state['windowTouchTrace'] == after_state['windowTouchTrace']
    assert after_state['activeWindowTouches'] == 0 and not after_state['windowTraceDropped']
    returned = root / (name + '-return')
    process(returned / 'result.json', 0)
    assert (returned / 'stdout').read_text().strip() == 'com.camsoft.duo-session-probe: ' + str(pid)
    tail = root / (name + '-refind')
    assert read(tail / 'result.json')['status'] == 'PASSED_BOUNDED'
    process(root / (name + '-refind-guard') / 'result.json', 0)
    b = read(tail / 'before-tap.json')
    a = read(tail / 'after-tap.json')
    tap = read(tail / 'fresh-tap-stdout')
    assert tap['outcome'] == 'enqueuedAndDrained' and tap['enqueuedEventCount'] == 2 and tap['cleanup'] == 'notNeeded'
    assert tap['ax']['target']['pid'] == tap['ax']['validation']['verifiedTarget']['pid'] == pid
    assert tap['ax']['target']['AXUniqueId'] == tap['ax']['validation']['verifiedTarget']['AXUniqueId'] == 'feature.tap'
    assert tap['context']['bootIdentity'] == boot and tap['context']['screenID'] == after_panel['displayID']
    assert tap['context']['screenUUID'] == after_panel['uniqueID']
    assert a['counts']['tap'] == b['counts'].get('tap', 0) + 1
    for key in set(a['counts']) | set(b['counts']):
        expected_change = 1 if key in {'tap', 'windowTouchBegan', 'windowTouchEnded'} else 0
        assert a['counts'].get(key, 0) == b['counts'].get(key, 0) + expected_change
    assert a['text'] == b['text']
    trace = a['windowTouchTrace'][len(b['windowTouchTrace']):]
    assert len(trace) == 2 and trace[0]['phase'] == 'windowTouchBegan' and trace[1]['phase'] == 'windowTouchEnded'
    assert trace[0]['contactID'] == trace[1]['contactID'] and all(v['hitView'] == 'feature.tap' for v in trace)
    point = tap['ax']['point']
    assert all(abs(v['x'] - point['x']) < 0.5 and abs(v['y'] - point['y']) < 0.5 for v in trace)
    assert a['activeWindowTouches'] == 0 and not a['windowTraceDropped']
    summary['cases'].append({'case': name, 'proof': 'publicCLIRetrospectiveTiming' if public else 'realLibraryLiveDownMarker',
                             'exactOwnedRelease': expected_up, 'freshButtonBefore': b['counts'].get('tap', 0),
                             'freshButtonAfter': a['counts']['tap'], 'releasedTouches': True})
failed = root / 'hardware-home-rotate'
assert read(failed / 'result.json')['status'] == 'FAILED_NO_REPLAY'
raw = read(failed / 'hardware-probe-stdout')
assert raw['outcome'] == 'enqueuedAndDrained' and raw['phase'] == 'completed'
assert raw['normalEventCount'] == 2 and raw['allInputsReleasedBeforeCleanup'] and raw['normalDrainCompleted']
assert raw['cleanup'] == 'notNeeded'
process(failed / 'hardware-probe-process.json', 0)
process(failed / 'external-change-process.json', 2)
process(root / 'hardware-home-rotate-guard/result.json', 1)
findings = read(root / 'hardware-home-rotate-readonly-findings.json')
assert findings['classification'] == 'NOT_INTERRUPTED_NO_CONTEXT_CHANGE' and findings['cause'] == 'UNPROVEN'
assert not findings['persistedQuarantinePresent']
summary['preservedFailure'] = findings['classification']
process(root / 'hardware-shutdown/result.json', 0)
summary['deviceShutdown'] = True
(root / 'hardware-saved-verification.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
