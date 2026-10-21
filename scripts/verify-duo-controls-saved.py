#!/usr/bin/env python3
"""Check saved Duo control receipts without sending simulator input."""
import argparse
import hashlib
import json
from pathlib import Path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', required=True, type=Path)
args = parser.parse_args()
root = args.root


def read(file):
    return json.loads(file.read_text())


candidate = read(root / 'controls-candidate.json')
for pin in candidate['pins']:
    assert hashlib.sha256(Path(pin['path']).read_bytes()).hexdigest() == pin['sha256'], pin['path']

hinges = ['close0', 'open1', 'open5', 'open10', 'open20', 'open45', 'open90',
          'open135', 'close90', 'open105', 'open120', 'close110', 'open115',
          'close112', 'open113', 'open114', 'edge-open115', 'edge-close114']
cases = ['side', 'refind-r2', 'batch-side', 'batch-refind'] + ['hinge-' + item for item in hinges]
summary = {'status': 'PASSED_BOUNDED_SAVED_RECEIPTS', 'candidatePins': len(candidate['pins']),
           'acceptedCases': len(cases), 'panelSwitches': 0, 'freshTapEffects': 0, 'hingeReadings': [],
           'commands': 0, 'exactKeyUpPrimitive': 'UNVERIFIED', 'security': 'UNVERIFIED'}
for name in cases:
    folder = root / ('controls-' + name)
    result = read(folder / 'result.json')
    assert result['status'] == 'PASSED_BOUNDED', name
    assert result['cliSHA256'] == candidate['pins'][0]['sha256'], name
    for command in result['commands']:
        assert command['reaped'] and not command['signals'] and command['exitCode'] in [0, 1], (name, command)
        summary['commands'] += 1
    guard = read(root / ('controls-' + name + '-guard') / 'result.json')
    assert guard['reaped'] and guard['exitCode'] == 0 and guard['stopReason'] is None and not guard['signalsSent'], name
    if name in ['side', 'batch-side']:
        before = read(folder / 'before.json')
        after = read(folder / 'after.json')
        assert before['counts'] == after['counts'] and before['windowTouchTrace'] == after['windowTouchTrace']
        assert after['activeWindowTouches'] == 0
        if name == 'side':
            response = read(folder / 'side-stdout')
        else:
            rows = [json.loads(line) for line in (folder / 'side-batch-stdout').read_text().splitlines() if line.strip()]
            assert len(rows) == 2 and rows[0]['status'] == 'completed' and rows[1]['status'] == 'rejectedBeforeSend'
            assert not rows[1].get('requestID') and not rows[1].get('response')
            response = rows[0]['response']
        evidence = response['button']['execution']
        assert response['outcome'] == 'enqueuedAndDrained' and response['enqueuedEventCount'] == 2 and response['cleanup'] == 'notNeeded'
        assert evidence['phase'] == 'completed' and evidence['sentPrimitiveCount'] == evidence['plannedPrimitiveCount'] == 2
        assert evidence['allInputsReleasedBeforeCleanup'] and evidence['drainCompleted'] and not evidence.get('interruption')
        assert evidence['cleanupEvidence']['contextValidation'] == 'noOwnedInput'
        assert not evidence['cleanupEvidence']['releases'] and not evidence['cleanupEvidence']['timedOut']
        assert (folder / 'after.png').is_file() and read(folder / 'visual.json')['scope']
    if name.startswith('hinge-'):
        assert len(result['matchingSamples']) == 2
        assert all(abs(value['mechanicalDegrees'] - result['requestedDegrees']) <= 0.1 for value in result['matchingSamples'])
        summary['hingeReadings'].append({'case': name, 'degrees': result['requestedDegrees'],
                                      'screenID': result['afterPanel']['identity']['displayID']})
        if result['activePanelChanged']:
            summary['panelSwitches'] += 1
            reject = read(folder / 'stale-panel-tap-stdout')
            assert reject['enqueuedEventCount'] == 0 and reject['cleanup'] == 'notNeeded' and 'inactiveSelection' in json.dumps(reject)
    if result.get('freshTap'):
        summary['freshTapEffects'] += 1
        before = read(folder / 'before-tap.json')
        after = read(folder / 'after-tap.json')
        response = read(folder / 'fresh-tap-stdout')
        assert response['outcome'] == 'enqueuedAndDrained' and response['enqueuedEventCount'] == 2 and response['cleanup'] == 'notNeeded'
        assert response['ax']['target']['AXUniqueId'] == 'feature.tap' and response['ax']['target']['pid'] == 76615
        assert response['ax']['validation']['verifiedTarget']['pid'] == 76615
        trace = after['windowTouchTrace'][len(before['windowTouchTrace']):]
        assert len(trace) == 2 and trace[0]['phase'] == 'windowTouchBegan' and trace[1]['phase'] == 'windowTouchEnded'
        assert trace[0]['contactID'] == trace[1]['contactID'] and trace[1]['activeTouches'] == 0
        point = response['ax']['point']
        assert all(value['hitView'] == 'feature.tap' and abs(value['x'] - point['x']) < 0.5 and abs(value['y'] - point['y']) < 0.5 for value in trace)
        for key in set(before['counts']) | set(after['counts']):
            increase = 1 if key in ['tap', 'windowTouchBegan', 'windowTouchEnded'] else 0
            assert after['counts'].get(key, 0) == before['counts'].get(key, 0) + increase, (name, key)
        for key in ['text', 'textFocused', 'slider', 'switchOn', 'pageOffsetY', 'listOffsetY', 'pinchScale', 'rotationRadians']:
            assert before[key] == after[key], (name, key)
        assert after['activeWindowTouches'] == 0 and after['windowTraceDropped'] == 0
assert summary['panelSwitches'] == 9 and summary['freshTapEffects'] == 11
(root / 'controls-saved-verification.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
