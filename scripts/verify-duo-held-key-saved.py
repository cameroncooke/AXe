#!/usr/bin/env python3
"""Read saved public held-key interruption proof. This sends no input."""
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


candidate = read(root / 'controls-candidate.json')
for pin in candidate['pins']:
    assert hashlib.sha256(Path(pin['path']).read_bytes()).hexdigest() == pin['sha256'], pin['path']
cases = [('controls-key-fold-focused', 'controls-key-fold-refind'), ('controls-key-rotate', 'controls-key-rotate')]
summary = {'status': 'BOUNDED_PUBLIC_HELD_KEY_CLEANUP_AND_REFIND_PROVED', 'candidatePins': len(candidate['pins']),
           'keyCases': [], 'exactKeyUpPrimitive': 'UNVERIFIED', 'keyUpTimestamp': 'UNAVAILABLE',
           'osPressedKeyInventory': 'UNVERIFIED', 'productionChange': False, 'security': 'UNVERIFIED'}
for name, tail_name in cases:
    folder = root / name
    tail = root / tail_name
    result = read(folder / 'result.json')
    assert result['status'] == ('FAILED_NO_REPLAY' if 'fold' in name else 'PASSED_BOUNDED')
    before = read(folder / 'focused-before-key.json')
    observed = read(folder / 'space-observed-before-change.json')
    after = read(folder / 'after-key-cleanup.json')
    response = read(folder / 'held-key-stdout')
    key_process = read(folder / 'held-key-process.json')
    change_process = read(folder / 'external-change-process.json')
    assert before['textFocused'] and observed['text'] == before['text'] + ' '
    assert observed['counts'].get('textChanged', 0) == before['counts'].get('textChanged', 0) + 1
    assert after['text'].startswith(before['text'])
    added = after['text'][len(before['text']):]
    assert len(added) >= 1 and set(added) == {' '}
    assert after['counts']['textChanged'] == before['counts'].get('textChanged', 0) + len(added)
    assert response['outcome'] == 'failedNoReplay' and response['enqueuedEventCount'] == 1
    assert response['cleanup'] == 'releaseEnqueuedAndDrained' and 'staleContext' in response['error']
    assert not response.get('quarantine') and response['keyboard']['validatedKeyDownCount'] == 1
    target = response['keyboard']['lastValidatedTarget']
    assert target['pid'] == 76615 and target['AXUniqueId'] == 'feature.text' and target['focused']
    assert key_process['reaped'] and key_process['exitCode'] == 1 and not key_process['signals']
    assert change_process['reaped'] and change_process['exitCode'] == 0 and not change_process['signals']
    ordered_files = ['space-observed-before-change.json', 'change-marker.json', 'held-key-process.json', 'after-key-cleanup.json']
    times = [(folder / file).stat().st_mtime_ns for file in ordered_files]
    assert times == sorted(times), name
    if 'fold' in name:
        stable = read(folder / 'late-release-stability.json')
        assert stable['first']['text'] == stable['second']['text'] == after['text']
        assert stable['first']['counts'] == stable['second']['counts'] == after['counts']
        review = read(root / 'controls-key-fold-review.json')
        assert review['originalWrapper'].startswith('FAILED_NO_REPLAY')
        assert all(row['state']['text'] == after['text'] and row['state']['counts']['textChanged'] == after['counts']['textChanged']
                   for row in review['laterTextStability'])
    else:
        for index in range(4):
            stable = read(folder / ('settled-key-' + str(index) + '.json'))
            assert stable['text'] == after['text'] and stable['counts'] == after['counts']
        assert len(read(folder / 'settled-key-times.json')) == 4
    tail_result = read(tail / 'result.json')
    assert tail_result['status'] == 'PASSED_BOUNDED'
    tap_before = read(tail / 'before-tap.json')
    tap_after = read(tail / 'after-tap.json')
    tap = read(tail / 'fresh-tap-stdout')
    assert tap['outcome'] == 'enqueuedAndDrained' and tap['enqueuedEventCount'] == 2 and tap['cleanup'] == 'notNeeded'
    assert tap['ax']['target']['pid'] == 76615 and tap['ax']['target']['AXUniqueId'] == 'feature.tap'
    assert tap['ax']['validation']['verifiedTarget']['pid'] == 76615
    assert tap_before['text'] == tap_after['text'] == after['text']
    assert tap_before['counts']['textChanged'] == tap_after['counts']['textChanged'] == after['counts']['textChanged']
    assert tap_after['counts']['tap'] == tap_before['counts']['tap'] + 1
    trace = tap_after['windowTouchTrace'][len(tap_before['windowTouchTrace']):]
    assert len(trace) == 2 and trace[0]['phase'] == 'windowTouchBegan' and trace[1]['phase'] == 'windowTouchEnded'
    assert trace[0]['contactID'] == trace[1]['contactID'] and all(v['hitView'] == 'feature.tap' for v in trace)
    point = tap['ax']['point']
    assert all(abs(v['x'] - point['x']) < 0.5 and abs(v['y'] - point['y']) < 0.5 for v in trace)
    assert tap_after['activeWindowTouches'] == 0 and not tap_after['windowTraceDropped']
    for result_name in {name, tail_name}:
        guard = read(root / (result_name + '-guard') / 'result.json')
        expected = 1 if result_name == 'controls-key-fold-focused' else 0
        assert guard['reaped'] and guard['exitCode'] == expected and guard['stopReason'] is None and not guard['signalsSent']
    summary['keyCases'].append({'case': name, 'originalWrapperStatus': result['status'],
                               'normalKeyDownCount': 1, 'spaceEffectsAtFirstCleanupRead': len(added),
                               'ownedCleanup': response['cleanup'], 'freshButtonBefore': tap_before['counts']['tap'],
                               'freshButtonAfter': tap_after['counts']['tap']})
shutdown = read(root / 'controls-final-shutdown/result.json')
assert shutdown['exitCode'] == 0 and shutdown['reaped'] and shutdown['stopReason'] is None
summary['deviceShutdown'] = True
(root / 'controls-held-key-saved-verification.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
