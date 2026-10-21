#!/usr/bin/env python3
"""Interrupt a public two-finger rotation; verify release and a fresh named tap."""
import argparse
import json
import math
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--out', required=True)
parser.add_argument('--mode', choices=['fold', 'rotate'], required=True)
parser.add_argument('--angle', default='0')
parser.add_argument('--degrees', type=float, required=True)
parser.add_argument('--evidence-root', type=Path, required=True)
parser.add_argument('--device', required=True)
args = parser.parse_args()
base = args.evidence_root.resolve()
root = Path('/Volumes/Developer/AXe')
out = Path(args.out)
context = json.loads((base / 'context.json').read_text())
cli = str(root / '.build/out/Products/Debug/axe')
device = args.device
assert device == '3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463', 'The copied external-state tool is bound to the audit Duo'
state_file = Path(context['stateFile'])
children = []
radius = 40
radians = math.radians(args.degrees)
spacing = 0.5
planned_events = math.ceil(abs(radians) * radius / spacing) + 3
pad = context['padFrame']
cx, cy = pad['x'] + pad['width']/2, pad['y'] + pad['height']/2
assert radius + 10 < min(pad['width'], pad['height'])/2
assert args.degrees in [-90, 90]
selection = ['--udid', device, '--input-mode', 'selected', '--screen-id', str(context['screenID']), '--screen-uuid', context['uuid']]

def save(name, value):
    (out / name).write_text(json.dumps(value, indent=2) + '\n')

def state(name):
    value = json.loads(state_file.read_text())
    save(name, value)
    return value

def start(name, command):
    save(name + '-command.json', command)
    with (out / (name + '-stdout')).open('x') as stdout, (out / (name + '-stderr')).open('x') as stderr:
        child = subprocess.Popen(command, stdout=stdout, stderr=stderr)
    children.append(child)
    return child

def run(name, command):
    child = start(name, command)
    code = child.wait(timeout=30)
    assert code == 0, (name, code, (out / (name + '-stderr')).read_text())
    return json.loads((out / (name + '-stdout')).read_text())

def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)

def moved_contacts(trace):
    ids = {row['contactID'] for row in trace}
    if len(ids) != 2:
        return None
    contacts = sorted([[row for row in trace if row['contactID'] == contact] for contact in ids], key=lambda rows: rows[0]['x'])
    for index, rows in enumerate(contacts):
        sign = -1 if index == 0 else 1
        assert rows[0]['phase'] == 'windowTouchBegan' and rows[0]['hitView'] == 'feature.pad'
        assert math.hypot(rows[0]['x'] - (cx + sign * radius), rows[0]['y'] - cy) < 0.5
        if len(rows) < 3 or math.hypot(rows[-1]['x'] - rows[0]['x'], rows[-1]['y'] - rows[0]['y']) <= 2:
            return None
        angles = []
        for row in rows:
            dx, dy = (row['x'] - cx) * sign, (row['y'] - cy) * sign
            assert abs(math.hypot(dx, dy) - radius) < 0.75
            angles.append(math.atan2(dy, dx))
        direction = 1 if radians > 0 else -1
        assert angles[-1] * direction > 0
        assert all((after - before) * direction >= -0.015 for before, after in zip(angles, angles[1:]))
        assert abs(angles[-1]) < abs(radians)
    return contacts

try:
    save('input-context.json', context)
    save('geometry.json', dict(centerX=cx, centerY=cy, radius=radius, degrees=args.degrees,
        spacing=spacing, duration=6, plannedNormalEvents=planned_events))
    before = state('before.json')
    assert before['activeWindowTouches'] == 0
    gesture = start('gesture', [cli, 'gesture', 'rotate', '-x', str(cx), '-y', str(cy),
        '--radius', str(radius), '--degrees=' + str(args.degrees), '--duration', '6', '--delta', str(spacing)] + selection)
    started = time.monotonic()
    deadline = started + 15
    while True:
        observed = json.loads(state_file.read_text())
        trace = observed['windowTouchTrace'][len(before['windowTouchTrace']):]
        if observed['activeWindowTouches'] == 2 and moved_contacts(trace):
            break
        assert gesture.poll() is None and time.monotonic() < deadline, 'Both contacts did not move before interruption'
        time.sleep(0.02)
    save('moving-before-change.json', observed)
    change = start('change', [str(base / 'external-change'), args.mode, context['boot'],
        str(context['screenID']), context['uuid'], args.angle, str(out / 'change-marker.json')])
    finished = None
    samples = []
    deadline = time.monotonic() + 20
    while gesture.poll() is None or change.poll() is None:
        observed = json.loads(state_file.read_text())
        if gesture.poll() is not None and finished is None:
            finished = time.monotonic()
        samples.append(dict(driverClockSeconds=time.monotonic(), sequence=observed['sequence'],
            activeTouches=observed['activeWindowTouches'], traceCount=len(observed['windowTouchTrace'])))
        assert time.monotonic() < deadline, 'Owned check exceeded its bound'
        time.sleep(0.02)
    save('samples.json', samples)
    elapsed = (finished or time.monotonic()) - started
    save('processes.json', dict(gestureExit=gesture.wait(), changeExit=change.wait(), bothReaped=True, gestureElapsedSeconds=elapsed))
    assert change.returncode == 0, (out / 'change-stderr').read_text()
    assert gesture.returncode != 0, 'Old-layout rotation gesture completed'
    receipt = json.loads((out / 'gesture-stdout').read_text())
    changed = json.loads((out / 'change-stdout').read_text())
    assert receipt['outcome'] == 'failedNoReplay' and 'staleContext' in receipt['error']
    assert receipt['cleanup'] == 'releaseEnqueuedAndDrained' and 'quarantine' not in receipt
    assert 3 <= receipt['enqueuedEventCount'] < planned_events
    assert elapsed < 4, 'Rotation gesture waited for its full six-second path'
    after = state('after-interruption.json')
    assert after['activeWindowTouches'] == 0
    trace = after['windowTouchTrace'][len(before['windowTouchTrace']):]
    contacts = {row['contactID'] for row in trace}
    assert len(contacts) == 2
    for contact in contacts:
        rows = [row for row in trace if row['contactID'] == contact]
        assert rows[0]['phase'] == 'windowTouchBegan'
        assert rows[-1]['phase'] in ['windowTouchEnded', 'windowTouchCancelled']
        assert all(row['phase'] not in ['windowTouchEnded', 'windowTouchCancelled'] for row in rows[:-1])
        sign = -1 if rows[0]['x'] < cx else 1
        endpoint = (cx + sign * radius * math.cos(radians), cy + sign * radius * math.sin(radians))
        assert math.hypot(rows[-1]['x'] - endpoint[0], rows[-1]['y'] - endpoint[1]) > 5
    release_delay = max(row['timestamp'] for row in trace) - changed['startedUptime']
    assert 0 <= release_delay < 2
    if args.mode == 'fold':
        assert changed['hinge']['outcome'] == 'observedMechanicalTarget'
        assert changed['hinge']['before']['mechanicalDegrees'] != changed['hinge']['requestedDegrees']
    else:
        assert changed['rotation']['vendorEventCount'] == 1
        assert changed['rotation']['before']['rotation'] != changed['rotation']['after']['rotation']
    time.sleep(0.5)
    settled = state('settled.json')
    assert settled['activeWindowTouches'] == 0 and settled['windowTouchTrace'] == after['windowTouchTrace']
    fresh = run('fresh-displays', [cli, 'list-simulators', '--displays', '--udid', device])
    assert fresh['bootIdentity'] == context['boot']
    active = fresh['activePanel']['identity']
    if args.mode == 'fold':
        assert active['displayID'] != context['screenID']
    else:
        assert active['displayID'] == context['screenID'] and int(fresh['activePanel']['currentOrientation'][3:]) != context['rotation']
    next_selection = ['--udid', device, '--input-mode', 'selected', '--screen-id', str(active['displayID']), '--screen-uuid', active['uniqueID']]
    description = run('fresh-description', [cli, 'describe-ui'] + next_selection + ['--expected-pid', str(context['pid']), '--ax-preparation', 'automation-session'])
    assert any(n.get('AXUniqueId') == 'feature.tap' for n in nodes(description))
    tap = run('fresh-tap', [cli, 'tap', '--id', 'feature.tap'] + next_selection + ['--expected-pid', str(context['pid']), '--ax-preparation', 'automation-session'])
    final = state('after-tap.json')
    assert tap['outcome'] == 'enqueuedAndDrained' and tap['enqueuedEventCount'] == 2 and tap['cleanup'] == 'notNeeded'
    assert 'error' not in tap and 'quarantine' not in tap
    assert final['counts'].get('tap', 0) == settled['counts'].get('tap', 0) + 1 and final['activeWindowTouches'] == 0
    validation = tap['ax']['validation']
    assert validation['expectedPID'] == validation['frontmostPID'] == validation['hitPID'] == context['pid']
    assert validation['verifiedTarget']['AXUniqueId'] == 'feature.tap'
    tap_trace = final['windowTouchTrace'][len(settled['windowTouchTrace']):]
    assert [row['phase'] for row in tap_trace] == ['windowTouchBegan', 'windowTouchEnded']
    assert tap_trace[0]['contactID'] == tap_trace[1]['contactID']
    assert all(row['hitView'] == 'feature.tap' and math.hypot(row['x'] - validation['pointX'], row['y'] - validation['pointY']) < 0.5 for row in tap_trace)
    frames = {tuple(n['frame'][k] for k in ['x', 'y', 'width', 'height']) for n in nodes(description) if n.get('AXUniqueId') == 'feature.pad' and 'frame' in n}
    assert len(frames) == 1
    x, y, width, height = frames.pop()
    next_context = dict(stateFile=str(state_file), padFrame=dict(x=x, y=y, width=width, height=height),
        boot=context['boot'], pid=context['pid'], screenID=active['displayID'], uuid=active['uniqueID'], rotation=int(fresh['activePanel']['currentOrientation'][3:]))
    save('next-context.json', next_context)
    (base / 'context.json').write_text(json.dumps(next_context, indent=2) + '\n')
    summary = dict(status='MOVING_ROTATION_INTERRUPTION_AND_REFIND_PASSED', mode=args.mode, degrees=args.degrees,
        normalEventsSent=receipt['enqueuedEventCount'], plannedNormalEvents=planned_events, bothMovedBeforeChange=True,
        confirmedCleanup=receipt['cleanup'], appContactReleaseAfterChangeStartSeconds=release_delay,
        newScreen=active['displayID'], newRotation=fresh['activePanel']['currentOrientation'], freshButtonEffects=1, heldTouches=0)
    save('case-result.json', summary)
    print(json.dumps(summary))
finally:
    for child in children:
        if child.poll() is None:
            # Let a dispatched complete gesture drain while the outer guard still runs.
            try:
                child.wait(timeout=8)
                continue
            except subprocess.TimeoutExpired:
                pass
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=3)
