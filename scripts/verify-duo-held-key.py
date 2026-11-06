#!/usr/bin/env python3
"""Interrupt one public held-Space command, then find and tap a Button again.

The public cleanup receipt confirms owned release and drain. It does not expose
an independent key-up primitive timestamp or the OS pressed-key inventory.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import signal
import subprocess
import time
from pathlib import Path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--mode', choices=['fold', 'rotate'], required=True)
parser.add_argument('--fold-angle', type=float, default=180)
parser.add_argument('--cli', required=True)
parser.add_argument('--device', required=True)
parser.add_argument('--pid', required=True, type=int)
parser.add_argument('--operator', required=True)
parser.add_argument('--out', required=True)
args = parser.parse_args()
assert args.pid > 0 and 0 <= args.fold_angle <= 180
args.case = 'held-key-' + args.mode
module_file = Path(__file__).with_name('verify-duo-controls.py')
spec = importlib.util.spec_from_file_location('duo_controls', module_file)
controls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controls)
check = controls.Check(args)
key = None
key_started = None
key_command = None
key_files = []
key_receipt_saved = False


def finish_key():
    global key_receipt_saved
    if key is None or key_receipt_saved:
        return
    sent = []
    if key.poll() is None:
        for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGKILL]:
            if key.poll() is not None:
                break
            key.send_signal(sig)
            sent.append(sig.name)
            try:
                key.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
    record = dict(command=key_command, pid=key.pid, exitCode=key.poll(),
                  reaped=key.poll() is not None, signals=sent,
                  elapsedSeconds=time.monotonic() - key_started,
                  startedMonotonicSeconds=key_started, finishedAtUTC=datetime.now(timezone.utc).isoformat())
    check.commands.append(record)
    controls.save(check.folder / 'held-key-process.json', record)
    key_receipt_saved = True
    for handle in key_files:
        handle.close()


try:
    check.container()
    original = check.catalogue('before-catalogue')
    selection = check.selection(original)
    check.description('before-description', original, args.pid)
    # Focus is an explicit, separate UI preparation action. This driver never
    # repeats a focus tap or assumes a callback delay after that action.
    before = check.state('focused-before-key')
    assert before['textFocused']
    key_command = [check.cli, 'key', '44', '--duration', '6', '--expected-pid', str(args.pid),
                   '--focus-id', 'feature.text', *selection, '--udid', args.device]
    controls.save(check.folder / 'held-key-argv.json', key_command)
    key_files = [(check.folder / 'held-key-stdout').open('xb'), (check.folder / 'held-key-stderr').open('xb')]
    key_started = time.monotonic()
    key = subprocess.Popen(key_command, stdout=key_files[0], stderr=key_files[1])
    controls.save(check.folder / 'held-key-started.json', {'pid': key.pid, 'command': key_command})
    deadline = time.monotonic() + 9
    while time.monotonic() < deadline:
        observed = json.loads(check.data.read_bytes())
        if observed['text'] == before['text'] + ' ':
            assert observed['counts'].get('textChanged', 0) == before['counts'].get('textChanged', 0) + 1
            assert key.poll() is None, 'The complete key command ended before the external change'
            controls.save(check.folder / 'space-observed-before-change.json', observed)
            controls.save(check.folder / 'space-observed-time.json',
                          {'capturedAtUTC': datetime.now(timezone.utc).isoformat(), 'clock': 'hostWallClock'})
            break
        assert key.poll() is None, 'Held key ended before its real Space effect was observed'
        time.sleep(0.025)
    else:
        raise AssertionError('No real Space effect observed before external change; do not send a state change')
    active = original['activePanel']['identity']
    change = check.run('external-change', [args.operator, args.mode, original['bootIdentity'],
                       str(active['displayID']), active['uniqueID'], str(args.fold_angle),
                       str(check.folder / 'change-marker.json'), args.device])
    key.wait(timeout=12)
    assert key.returncode == 1
    finish_key()
    response = json.loads((check.folder / 'held-key-stdout').read_text())
    assert response['outcome'] == 'failedNoReplay' and response['enqueuedEventCount'] == 1
    assert response['cleanup'] == 'releaseEnqueuedAndDrained' and not response.get('quarantine')
    assert 'staleContext' in response['error']
    assert response['keyboard']['expectedPID'] == args.pid and response['keyboard']['validatedKeyDownCount'] == 1
    target = response['keyboard']['lastValidatedTarget']
    assert target['AXUniqueId'] == 'feature.text' and target['pid'] == args.pid and target['focused']
    after = check.state('after-key-cleanup')
    assert after['text'].startswith(before['text'])
    added = after['text'][len(before['text']):]
    assert len(added) >= 1 and set(added) == {' '}
    # A held key can repeat before release. Require that repeat has stopped
    # after the complete public cleanup receipt, rather than assuming one byte.
    assert after['counts'].get('textChanged', 0) == before['counts'].get('textChanged', 0) + len(added)
    settled_samples = []
    for index in range(4):
        time.sleep(0.25)
        settled = check.state('settled-key-' + str(index))
        assert settled['text'] == after['text'] and settled['counts'] == after['counts']
        settled_samples.append({'capturedAtUTC': datetime.now(timezone.utc).isoformat(),
                                'textLength': len(settled['text']), 'textChangedCount': settled['counts'].get('textChanged', 0)})
    controls.save(check.folder / 'settled-key-times.json', settled_samples)
    catalogue = check.catalogue('after-catalogue')
    assert catalogue['bootIdentity'] == original['bootIdentity']
    if args.mode == 'fold':
        assert change['hinge']['requestedDegrees'] == args.fold_angle
        assert catalogue['activePanel']['identity']['displayID'] != active['displayID']
    else:
        assert change['rotation']['vendorEventCount'] == 1
        assert catalogue['activePanel']['identity'] == active
        assert catalogue['activePanel']['currentOrientation'] != original['activePanel']['currentOrientation']
    check.tap(catalogue, args.pid)
    check.result.update(mode=args.mode, heldKey='Space44', originalContext=original,
                        afterContext=catalogue, realSpaceEffectCount=len(added), normalKeyDownCount=1,
                        ownedCleanup=response['cleanup'], exactKeyUpPrimitive='UNVERIFIED',
                        keyUpTimestamp='UNAVAILABLE', osPressedKeyInventory='UNVERIFIED')
except BaseException as error:
    finish_key()
    check.finish(error)
    raise
finally:
    finish_key()
check.finish()
