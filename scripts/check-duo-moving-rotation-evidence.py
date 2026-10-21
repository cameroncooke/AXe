#!/usr/bin/env python3
"""Validate saved moving-rotation evidence without simulator input."""
import argparse
import hashlib
import json
import math
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--current', action='store_true')
parser.add_argument('--evidence-root', type=Path, required=True)
args = parser.parse_args()
base = args.evidence_root.resolve()

def read(name):
    return json.loads((base / name).read_text())

def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()

candidate = read('candidate.json')
for pin in candidate['dependencies'] + candidate['tools']:
    assert digest(base / pin['copy']) == pin['sha256'], pin['copy']
    if args.current:
        assert digest(Path(pin['path'])) == pin['sha256'], pin['path']

verified = []
for name in ['rotation-fold', 'rotation-device-v2']:
    wrapper, summary = read(name + '/result.json'), read(name + '/case-result.json')
    assert wrapper['exitCode'] == 0 and wrapper['reaped'] and wrapper['stopReason'] is None
    process = read(name + '/processes.json')
    assert process['bothReaped'] and process['gestureExit'] != 0 and process['changeExit'] == 0
    assert process['gestureElapsedSeconds'] < 4
    context, geometry = read(name + '/input-context.json'), read(name + '/geometry.json')
    before, moving, after, settled, final = [read(name + '/' + n + '.json') for n in
        ['before', 'moving-before-change', 'after-interruption', 'settled', 'after-tap']]
    assert all(value['fixtureVersion'] == 6 and value['windowTraceDropped'] == 0 for value in [before, moving, after, settled, final])
    assert before['activeWindowTouches'] == after['activeWindowTouches'] == settled['activeWindowTouches'] == final['activeWindowTouches'] == 0
    assert moving['activeWindowTouches'] == 2 and after['windowTouchTrace'] == settled['windowTouchTrace']
    prefix = moving['windowTouchTrace'][len(before['windowTouchTrace']):]
    ids = {row['contactID'] for row in prefix}
    assert len(ids) == 2
    contacts = sorted([[row for row in prefix if row['contactID'] == contact] for contact in ids], key=lambda rows: rows[0]['x'])
    cx, cy, radius = geometry['centerX'], geometry['centerY'], geometry['radius']
    radians = math.radians(geometry['degrees'])
    for index, rows in enumerate(contacts):
        sign = -1 if index == 0 else 1
        assert rows[0]['phase'] == 'windowTouchBegan' and rows[0]['hitView'] == 'feature.pad'
        assert len(rows) >= 3 and math.hypot(rows[0]['x'] - (cx + sign * radius), rows[0]['y'] - cy) < 0.5
        assert math.hypot(rows[-1]['x'] - rows[0]['x'], rows[-1]['y'] - rows[0]['y']) > 2
        angles = []
        for row in rows:
            dx, dy = (row['x'] - cx) * sign, (row['y'] - cy) * sign
            assert abs(math.hypot(dx, dy) - radius) < 0.75
            angles.append(math.atan2(dy, dx))
        direction = 1 if radians > 0 else -1
        assert 0 < angles[-1] * direction < abs(radians)
        assert all((after - before) * direction >= -0.015 for before, after in zip(angles, angles[1:]))
    receipt, change = read(name + '/gesture-stdout'), read(name + '/change-stdout')
    assert receipt['outcome'] == 'failedNoReplay' and 'staleContext' in receipt['error']
    assert receipt['cleanup'] == 'releaseEnqueuedAndDrained' and 'quarantine' not in receipt
    assert summary['mode'] == change['mode'] and summary['normalEventsSent'] == receipt['enqueuedEventCount']
    assert summary['plannedNormalEvents'] == geometry['plannedNormalEvents'] and summary['degrees'] == geometry['degrees']
    assert receipt['version'] == 21 and receipt['context']['bootIdentity'] == context['boot']
    assert receipt['context']['screenID'] == context['screenID'] and receipt['context']['screenUUID'] == context['uuid']
    assert geometry['plannedNormalEvents'] == math.ceil(abs(radians) * radius / geometry['spacing']) + 3
    assert 3 <= receipt['enqueuedEventCount'] < geometry['plannedNormalEvents']
    assert max(row['timestamp'] for row in prefix) < change['startedUptime']
    trace = after['windowTouchTrace'][len(before['windowTouchTrace']):]
    assert {row['contactID'] for row in trace} == ids
    for contact in ids:
        rows = [row for row in trace if row['contactID'] == contact]
        assert rows[0]['phase'] == 'windowTouchBegan' and rows[-1]['phase'] in ['windowTouchEnded', 'windowTouchCancelled']
        assert all(row['phase'] not in ['windowTouchEnded', 'windowTouchCancelled'] for row in rows[:-1])
        sign = -1 if rows[0]['x'] < cx else 1
        endpoint = (cx + sign * radius * math.cos(radians), cy + sign * radius * math.sin(radians))
        assert math.hypot(rows[-1]['x'] - endpoint[0], rows[-1]['y'] - endpoint[1]) > 5
    release_delay = max(row['timestamp'] for row in trace) - change['startedUptime']
    assert 0 <= release_delay < 2
    fresh, tap = read(name + '/fresh-displays-stdout'), read(name + '/fresh-tap-stdout')
    active = fresh['activePanel']['identity']
    assert fresh['bootIdentity'] == context['boot'] == tap['context']['bootIdentity']
    assert active['displayID'] == tap['context']['screenID'] and active['uniqueID'] == tap['context']['screenUUID']
    assert int(fresh['activePanel']['currentOrientation'][3:]) == tap['context']['rotationDegrees']
    if summary['mode'] == 'fold':
        assert change['hinge']['outcome'] == 'observedMechanicalTarget' and change['hinge']['requestedDegrees'] == 0
        assert change['hinge']['before']['mechanicalDegrees'] == 180 and context['screenID'] == 3 and active['displayID'] == 1
    else:
        assert change['rotation']['vendorEventCount'] == 1 and context['screenID'] == active['displayID'] == 1
        assert change['rotation']['before']['rotation'] != change['rotation']['after']['rotation']
        assert context['rotation'] == 0 and tap['context']['rotationDegrees'] == 90
    assert tap['outcome'] == 'enqueuedAndDrained' and tap['enqueuedEventCount'] == 2 and tap['cleanup'] == 'notNeeded'
    assert 'error' not in tap and 'quarantine' not in tap
    validation = tap['ax']['validation']
    assert validation['expectedPID'] == validation['frontmostPID'] == validation['hitPID'] == context['pid']
    assert validation['verifiedTarget']['AXUniqueId'] == 'feature.tap'
    assert final['counts'].get('tap', 0) == settled['counts'].get('tap', 0) + 1
    tap_trace = final['windowTouchTrace'][len(settled['windowTouchTrace']):]
    assert [row['phase'] for row in tap_trace] == ['windowTouchBegan', 'windowTouchEnded']
    assert tap_trace[0]['contactID'] == tap_trace[1]['contactID']
    assert all(row['hitView'] == 'feature.tap' and math.hypot(row['x'] - validation['pointX'], row['y'] - validation['pointY']) < 0.5 for row in tap_trace)
    verified.append(summary)

# Replay the existing strict complete-gesture grader against saved data only.
import importlib.util
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location('saved_complete_grader', base / 'verify-complete.py')
complete = importlib.util.module_from_spec(spec)
spec.loader.exec_module(complete)
complete_cases = []
for case in ['pad-tap', 'hold', 'double-tap', 'swipe', 'drag']:
    folder = 'outer270-' + case
    wrapper, result = read(folder + '/result.json'), read(folder + '/check/result.json')
    assert wrapper['exitCode'] == 0 and wrapper['reaped'] and wrapper['stopReason'] is None
    assert result['result'] == 'PASS' and result['context']['rotationDegrees'] == 270
    assert result['context']['screenID'] == 1 and result['activeWindowTouches'] == 0
    before, after = read(folder + '/check/state-before.json'), read(folder + '/check/state-after.json')
    description = read(folder + '/check/describe-receipt.json')
    final_description = read(folder + '/check/describe-after-receipt.json')
    args_for_case = SimpleNamespace(case=case, pid=result['pid'])
    center, frame, capacity = complete.geometry(args_for_case, description, before)
    verb, extra, counter = complete.make_command(args_for_case, *center)
    complete.grade(args_for_case, before, after, counter, center, frame, capacity)
    assert description['context'] == final_description['context'] == result['context']
    assert all(json.loads(file.read_text())['reaped'] for file in (base / folder / 'check').glob('*-process.json'))
    complete_cases.append(result)

# The assigned guest must be shut down; another worker can still own a different guest.
assert not any(device['udid'] == '3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463' for devices in read('stopped/stdout')['devices'].values() for device in devices)
commands = [json.loads(file.read_text()) for file in base.glob('*/result.json')]
assert all(command['reaped'] for command in commands)
assert read('boot/result.json')['exitCode'] == 0 and read('boot/result.json')['stopReason'].startswith('FINAL_MONITOR_ERROR: TimeoutExpired')
assert all(command['stopReason'] is None for command in commands if command['pid'] != read('boot/result.json')['pid'])
samples = [json.loads(line) for file in base.glob('*/resources.jsonl') for line in file.read_text().splitlines()]
summary = dict(date='2026-10-21', status='MOVING_ROTATION_NATIVE_PROOF_PASSED', wireVersion=21,
    candidatePins=len(candidate['dependencies']), toolPins=len(candidate['tools']), nativeCases=verified, completeOuter270Cases=complete_cases,
    freshButtonEffects=2, heldTouchesAtEnd=0, productionSourceChanges=False,
    peaks={group:dict(footprintGiB=max(row[group]['footprintGiB'] for row in samples), cpuPercent=max(row[group]['cpuPercent'] for row in samples)) for group in ['app', 'simulator', 'command']},
    thresholdStops=0, monitorStops=1, finalResources=read('stopped/result.json')['last'],
    limits=['One Duo/profile405/iOS27.2, fixture version6, local Debug arm64',
        'Clockwise twist with close at inner90; anticlockwise twist with outer0-to90 rotation',
        'Other poses and change combinations, retained library pairs and cleanup failure injection remain unverified',
        'App-contact release timing is not direct AXe send timing or a worst-case latency bound',
        'No atomic OS state/send guarantee'], securityScan='UNVERIFIED', productChanges=False, pushed=False)
(base / 'main-result.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
