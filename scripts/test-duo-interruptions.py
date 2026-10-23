#!/usr/bin/env python3
"""Interrupt one public held contact, drag or pinch on an already prepared Duo.

Requires the tracked, visible DuoTapWaitProbe app and DuoExternalStateChange tool.
The caller builds, installs, launches and guards resources. This driver does not
boot, reset or restore the device. Run each fold/rotation case separately.
It reads the fixture's normal UIKit touch trace; it never writes app state.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'com.camsoft.duo-tap-wait-probe'
TERMINAL = {'ended', 'cancelled'}
TOUCH_COUNTS = {'began', 'moved', 'ended', 'cancelled'}
INTERRUPTED_BY = None


def require(value, message):
    if not value:
        raise RuntimeError(message)


def save(file, value):
    file.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def nodes(roots):
    for node in roots:
        yield node
        yield from nodes(node.get('children', []))


def distance(row, point):
    return math.hypot(row['x'] - point[0], row['y'] - point[1])


def handle_termination(signum, _frame):
    global INTERRUPTED_BY
    if INTERRUPTED_BY is None:
        INTERRUPTED_BY = signal.Signals(signum).name


def check_interruption():
    if INTERRUPTED_BY is not None:
        raise InterruptedError('Driver received ' + INTERRUPTED_BY)


def group_exists(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


def stop_owned_groups(children):
    started = time.monotonic()

    def remaining():
        for child, _ in children:
            child.poll()
        return [(child, entry) for child, entry in children if group_exists(child.pid)]

    for sig, deadline in [(signal.SIGTERM, started + 1), (signal.SIGKILL, started + 3)]:
        for child, entry in remaining():
            try:
                os.killpg(child.pid, sig)
                entry['signals'].append(sig.name)
            except ProcessLookupError:
                pass
        while remaining() and time.monotonic() < deadline:
            time.sleep(.025)
    pending = remaining()
    for child, entry in children:
        entry.update(exitCode=child.poll(), reaped=child.poll() is not None,
                     groupStopped=not group_exists(child.pid))
    return dict(boundSeconds=3, elapsedSeconds=round(time.monotonic() - started, 3),
                allGroupsStopped=not pending, remainingGroups=[child.pid for child, _ in pending])


class Check:
    def __init__(self, args):
        self.args = args
        self.out = args.out
        self.children = {}
        self.pins = {}
        self.deadline = time.monotonic() + 180
        self.env = {key: value for key, value in os.environ.items() if not key.startswith(('AXE_', 'DYLD_'))}
        self.env['AXE_ENV_FILE'] = '/dev/null'
        self.result = dict(status='RUNNING', startedAt=datetime.now(timezone.utc).isoformat(),
                           gesture=args.gesture, change=args.change, udid=args.udid, pid=args.pid,
                           expectedPanelChange=args.expect_panel_change,
                           commands=[], fingerprints=self.pins, limitations=[
                               'One starting pose and fixture process per run; no device restore.',
                               'Public cleanup status plus actual app contact readback; no OS-wide touch inventory.',
                               'File fingerprints and static linkage are recorded; loaded image paths are not observed.',
                               'Resource limits belong to the caller guard. No input replay or automatic retry.',
                               'The caller owns persistent AXe broker shutdown and simulator cleanup.',
                               'A hinge angle change does not imply a panel switch or a visual layout change.',
                           ])
        self.flush()

    def flush(self):
        save(self.out / 'result.json', self.result)

    def pin(self, label, file):
        file = file.resolve(strict=True)
        self.pins[label] = dict(file=str(file), sha256=digest(file))

    def start(self, name, argv):
        check_interruption()
        require(time.monotonic() < self.deadline, 'The case exceeded its 180-second bound')
        entry = dict(name=name, argv=[str(value) for value in argv], startedMonotonic=time.monotonic(), signals=[])
        with (self.out / (name + '.stdout')).open('xb') as stdout, (self.out / (name + '.stderr')).open('xb') as stderr:
            child = subprocess.Popen(entry['argv'], stdout=stdout, stderr=stderr,
                                     env=self.env, start_new_session=True)
        entry.update(pid=child.pid, processGroup=child.pid)
        self.children[name] = (child, entry)
        self.result['commands'].append(entry)
        self.flush()
        return child

    def finish(self, name, expected=0, timeout=30, as_json=True):
        child, entry = self.children[name]
        deadline = min(self.deadline, time.monotonic() + timeout)
        while child.poll() is None:
            check_interruption()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(entry['argv'], timeout)
            try:
                child.wait(timeout=min(.1, remaining))
            except subprocess.TimeoutExpired:
                pass
        check_interruption()
        entry.update(exitCode=child.returncode, reaped=True, finishedMonotonic=time.monotonic())
        self.flush()
        error = (self.out / (name + '.stderr')).read_text(errors='replace')
        require(expected is None or child.returncode == expected, f'{name} exited {child.returncode}: {error}')
        text = (self.out / (name + '.stdout')).read_text()
        return json.loads(text) if as_json else text

    def run(self, name, argv, as_json=True):
        self.start(name, argv)
        return self.finish(name, as_json=as_json)

    def axe(self, name, verb, extra=(), selection=()):
        return self.run(name, [self.args.cli, verb, *extra, '--udid', self.args.udid, *selection])

    def selection(self, catalogue):
        panel = catalogue['activePanel']['identity']
        return ['--input-mode', 'selected', '--screen-id', str(panel['displayID']), '--screen-uuid', panel['uniqueID']]

    def state(self):
        state = json.loads(self.state_file.read_text())
        require(state['fixtureVersion'] == 1 and state['bundleIdentifier'] == BUNDLE
                and state['pid'] == self.args.pid, 'Fixture version, app or PID changed')
        require(state['windowTraceDropped'] == 0, 'Dropped touch records prevent contact attribution')
        return state

    def await_state(self, name, predicate, child=None, timeout=10):
        deadline = min(self.deadline, time.monotonic() + timeout)
        while True:
            check_interruption()
            state = self.state()
            if predicate(state):
                save(self.out / (name + '.json'), state)
                return state
            require(child is None or child.poll() is None, name + ': input ended before the guest witness')
            require(time.monotonic() < deadline, name + ': no matching guest readback')
            time.sleep(.025)

    def catalogue(self, name):
        value = self.axe(name, 'list-simulators', ['--displays'])
        require(uuid.UUID(value['requestedSimulatorUDID']) == uuid.UUID(self.args.udid), 'Wrong display catalogue device')
        require(value['activePanel']['active'], 'No active panel')
        return value

    def prepare(self):
        self.pin('driver', Path(__file__))
        for label, file in [('cli', self.args.cli), ('helper', self.args.helper), ('operator', self.args.operator),
                            ('fixture-source', ROOT / 'scripts/fixtures/DuoTapWaitProbe.m'),
                            ('operator-source', ROOT / 'scripts/fixtures/DuoExternalStateChange.swift')]:
            self.pin(label, file)
        for name in ['FBSimulatorControl', 'FBControlCore', 'FBDeviceControl', 'XCTestBootstrap']:
            self.pin(name, self.args.cli.parent / (name + '.framework') / name)
        for label, binary in [('cli', self.args.cli), ('operator', self.args.operator)]:
            self.run(label + '-linkage', ['/usr/bin/otool', '-L', binary], as_json=False)
        inventory = self.run('device', ['/usr/bin/xcrun', 'simctl', 'list', 'devices', 'available', '-j'])
        matches = [row | {'runtime': runtime} for runtime, rows in inventory['devices'].items()
                   for row in rows if row['udid'].upper() == self.args.udid.upper()]
        require(len(matches) == 1 and matches[0]['state'] == 'Booted'
                and 'iPhone-Duo' in matches[0].get('deviceTypeIdentifier', ''), 'An explicit booted Duo is required')
        self.result['device'] = matches[0]
        self.run('xcode-version', ['/usr/bin/xcrun', 'xcodebuild', '-version'], as_json=False)
        self.run('selected-xcode', ['/usr/bin/xcode-select', '-p'], as_json=False)
        self.result['developerDirectoryOverride'] = self.env.get('DEVELOPER_DIR')
        installed = Path(self.run('fixture-app', ['/usr/bin/xcrun', 'simctl', 'get_app_container', self.args.udid,
                                                BUNDLE, 'app'], as_json=False).strip())
        info = plistlib.loads((self.args.fixture_app / 'Info.plist').read_bytes())
        require(info['CFBundleIdentifier'] == BUNDLE, 'Wrong supplied fixture app')
        for name in ['Info.plist', info['CFBundleExecutable']]:
            self.pin('fixture/' + name, self.args.fixture_app / name)
            require(digest(installed / name) == digest(self.args.fixture_app / name), 'Installed fixture differs: ' + name)
        container = self.run('fixture-data', ['/usr/bin/xcrun', 'simctl', 'get_app_container', self.args.udid,
                                            BUNDLE, 'data'], as_json=False).strip()
        self.state_file = Path(container).resolve(strict=True) / 'Documents/state.json'
        self.verify_pid('initial-pid')
        self.result['stateFile'] = str(self.state_file)
        self.before_catalogue = self.catalogue('before-displays')
        before = self.state()
        require(before['activeWindowTouches'] == 0 and before['phase'] == 'hidden'
                and not before['duplicateVisible'], 'Start with no contacts or pending/visible delayed targets')
        panel = self.before_catalogue['activePanel']
        width, height = panel['nativePixelWidth'] / panel['pointScale'], panel['nativePixelHeight'] / panel['pointScale']
        if panel['currentOrientation'] in ['rot90', 'rot270']:
            width, height = height, width
        require(abs(before['width'] - width) < 1 and abs(before['height'] - height) < 1,
                'Fixture and active display geometry disagree')
        bottom = max(row['y'] + row['height'] for row in before['geometry'].values() if not row['hidden'])
        self.center = (width / 2, (bottom + height - 40) / 2)
        require(self.center[1] > bottom + 20 and self.center[1] < height - 40 and width > 240,
                'No clear app area for bounded contact geometry')
        self.before = before
        save(self.out / 'before-state.json', before)
        self.flush()

    def verify_pid(self, name):
        text = self.run(name, ['/usr/bin/xcrun', 'simctl', 'spawn', self.args.udid, 'launchctl', 'list'], as_json=False)
        rows = [line.split() for line in text.splitlines() if 'UIKitApplication:' + BUNDLE + '[' in line]
        require(len(rows) == 1 and rows[0][0] == str(self.args.pid), 'The live fixture PID differs')

    def contacts(self, state):
        trace = state['windowTouchTrace'][len(self.before['windowTouchTrace']):]
        return sorted([[row for row in trace if row['contactID'] == identity]
                       for identity in {row['contactID'] for row in trace}], key=lambda rows: rows[0]['x'])

    def witnessed(self, state):
        contacts = self.contacts(state)
        if state['activeWindowTouches'] != len(self.starts) or len(contacts) != len(self.starts):
            return False
        for index, rows in enumerate(contacts):
            require(rows[0]['phase'] == 'began' and rows[0]['contactID'] > 0
                    and distance(rows[0], self.starts[index]) < 1, 'Contact started at an unexpected point')
            require(not any(row['phase'] in TERMINAL for row in rows), 'Contact ended before external change')
            if self.args.gesture != 'hold':
                if not any(row['phase'] == 'moved' and distance(row, self.starts[index]) > 2 for row in rows):
                    return False
                if self.args.gesture == 'pinch':
                    require((rows[-1]['x'] - rows[0]['x']) * (-1 if index == 0 else 1) > 2,
                            'Pinch contacts did not move in opposite directions')
        return True

    def exercise(self):
        cx, cy = self.center
        extra = ['--duration', '6']
        if self.args.gesture == 'hold':
            self.starts = self.ends = [(cx, cy)]
            self.planned = 2
            argv = ['touch', '-x', str(cx), '-y', str(cy), '--down', '--up', '--delay', '6']
        elif self.args.gesture == 'drag':
            self.starts, self.ends, self.planned = [(cx - 100, cy)], [(cx + 100, cy)], 122
            argv = ['drag', '--start-x', str(cx - 100), '--start-y', str(cy), '--end-x', str(cx + 100),
                    '--end-y', str(cy), '--steps', '120', *extra]
        else:
            self.starts, self.ends, self.planned = [(cx - 40, cy), (cx + 40, cy)], [(cx - 80, cy), (cx + 80, cy)], 83
            argv = ['gesture', 'pinch', '-x', str(cx), '-y', str(cy), '--radius', '40', '--scale', '2',
                    '--delta', '0.5', *extra]
        save(self.out / 'geometry.json', dict(starts=self.starts, oldEndpoints=self.ends, plannedNormalEvents=self.planned))
        child = self.start('gesture', [self.args.cli, *argv, '--udid', self.args.udid, *self.selection(self.before_catalogue)])
        witness = self.await_state('contact-before-change', self.witnessed, child=child)
        require(child.poll() is None, 'Input ended before external change')
        active = self.before_catalogue['activePanel']['identity']
        changed = self.run('external-change', [self.args.operator, self.args.change, self.before_catalogue['bootIdentity'],
                           str(active['displayID']), active['uniqueID'], str(self.args.fold_degrees),
                           self.out / 'change-marker.json', self.args.udid, self.args.helper])
        response = self.finish('gesture', expected=None, timeout=15)
        require(child.returncode != 0 and response['outcome'] == 'failedNoReplay'
                and 'staleContext' in response.get('error', ''), 'The original path was not interrupted by stale context')
        context = response['context']
        require(context['bootIdentity'] == self.before_catalogue['bootIdentity']
                and context['screenID'] == active['displayID']
                and uuid.UUID(context['screenUUID']) == uuid.UUID(active['uniqueID']),
                'The interruption receipt is not bound to the original display and boot')
        require(response['cleanup'] == 'releaseEnqueuedAndDrained' and not response.get('quarantine'),
                'Owned release was not confirmed')
        count = response['enqueuedEventCount']
        require(count == 1 if self.args.gesture == 'hold' else 2 <= count < self.planned,
                'Normal input did not stop before its final event')
        after = self.await_state('after-release', lambda state: state['activeWindowTouches'] == 0)
        contacts = self.contacts(after)
        require(len(contacts) == len(self.starts), 'Unexpected contacts during interruption')
        for index, rows in enumerate(contacts):
            require(rows[0]['contactID'] == self.contacts(witness)[index][0]['contactID']
                    and rows[-1]['phase'] in TERMINAL and not any(row['phase'] in TERMINAL for row in rows[:-1]),
                    'Original contact has no unique terminal record')
            require(rows[-1]['guestUptime'] >= changed['startedUptime'], 'Contact ended before external change')
            if self.args.gesture != 'hold':
                require(all(distance(row, self.ends[index]) > 3 for row in rows if row['phase'] == 'moved'),
                        'The interrupted contact reached its old endpoint')
        self.check_callbacks(self.before, after)
        time.sleep(.5)
        settled = self.state()
        require(settled['activeWindowTouches'] == 0 and settled['windowTouchTrace'] == after['windowTouchTrace'],
                'Late or retained touch input followed cleanup')
        save(self.out / 'settled-state.json', settled)
        fresh = self.catalogue('fresh-displays')
        require(fresh['bootIdentity'] == self.before_catalogue['bootIdentity'], 'The device rebooted')
        if self.args.change == 'fold':
            hinge = changed['hinge']
            measured = hinge['matchingSamples'][-1]['mechanicalDegrees']
            require(hinge['outcome'] == 'observedMechanicalTarget' and not hinge['wasAlreadyWithinTolerance']
                    and abs(hinge['requestedDegrees'] - self.args.fold_degrees) <= .5
                    and abs(measured - self.args.fold_degrees) <= .5
                    and abs(measured - hinge['before']['mechanicalDegrees']) > .5,
                    'The hinge did not move to the requested measured angle')
            self.result['hingeChange'] = dict(requestedDegrees=self.args.fold_degrees,
                                            beforeDegrees=hinge['before']['mechanicalDegrees'],
                                            observedDegrees=measured)
        else:
            rotation = changed['rotation']
            require(rotation['vendorEventCount'] == 1 and rotation['before']['rotation'] != rotation['after']['rotation']
                    and fresh['activePanel']['identity'] == active
                    and fresh['activePanel']['currentOrientation'] != self.before_catalogue['activePanel']['currentOrientation'],
                    'The rotation did not change the selected UI context')
        panel_changed = fresh['activePanel']['identity'] != active
        require(not self.args.expect_panel_change or panel_changed, 'The stated case required an active panel switch')
        fresh_context = self.fresh_tap(fresh, settled, context)
        self.verify_pid('final-pid')
        for pin in self.pins.values():
            require(digest(Path(pin['file'])) == pin['sha256'], 'A candidate file changed during this run: ' + pin['file'])
        self.result.update(status='PASS_BOUNDED', normalEventsSent=count, plannedNormalEvents=self.planned,
                           originalContacts=len(contacts), heldContactsAfter=0, freshButtonEffects=1,
                           cleanup=response['cleanup'], startingBoot=self.before_catalogue['bootIdentity'],
                           finalPanel=fresh['activePanel'], activePanelChanged=panel_changed,
                           originalPoseRevision=context['poseRevision'], freshPoseRevision=fresh_context['poseRevision'],
                           poseRevisionChanged=fresh_context['poseRevision'] != context['poseRevision'], inputReplayed=False)

    def fresh_tap(self, catalogue, before, original_context):
        selection = [*self.selection(catalogue), '--expected-pid', str(self.args.pid)]
        tree = self.axe('fresh-description', 'describe-ui', [], selection)
        context = tree['context']
        if self.args.change == 'fold':
            require(context['poseRevision'] != original_context['poseRevision'],
                    'Fresh selected AX did not confirm a changed hinge pose revision')
        matches = [node for node in nodes(tree.get('ax', {}).get('roots', [])) if node.get('AXUniqueId') == 'wait.fresh']
        require(len(matches) == 1 and matches[0].get('pid') == self.args.pid and matches[0].get('enabled'),
                'Fresh find did not identify the owned visible button')
        tap = self.axe('fresh-tap', 'tap', ['--id', 'wait.fresh', '--element-type', 'Button', '--tap-style', 'physical'], selection)
        require(tap['outcome'] == 'enqueuedAndDrained' and tap['enqueuedEventCount'] == 2
                and tap['cleanup'] == 'notNeeded' and not tap.get('error'), 'Fresh tap did not complete')
        after = self.await_state('fresh-tap-state', lambda state: state['activeWindowTouches'] == 0
                                 and state['counts'].get('fresh', 0) == before['counts'].get('fresh', 0) + 1)
        suffix = after['windowTouchTrace'][len(before['windowTouchTrace']):]
        require(len(suffix) == 2 and [row['phase'] for row in suffix] == ['began', 'ended']
                and suffix[0]['contactID'] == suffix[1]['contactID']
                and all(row['hitView'] == 'wait.fresh' for row in suffix), 'Fresh button did not receive a complete contact')
        validation = tap['ax']['validation']
        require(validation['expectedPID'] == validation['frontmostPID'] == validation['hitPID'] == self.args.pid
                and validation['verifiedTarget']['AXUniqueId'] == 'wait.fresh'
                and all(distance(row, (validation['pointX'], validation['pointY'])) < 1 for row in suffix),
                'Fresh contact disagrees with the current native target and point')
        self.check_callbacks(before, after, fresh_delta=1)
        return context

    def check_callbacks(self, before, after, fresh_delta=0):
        for key in set(before['counts']) | set(after['counts']):
            if key not in TOUCH_COUNTS:
                expected = before['counts'].get(key, 0) + (fresh_delta if key == 'fresh' else 0)
                require(after['counts'].get(key, 0) == expected, 'Unexpected app callback: ' + key)

    def close(self):
        # On an ordinary failure, let the original six-second gesture drain first.
        # An external interruption skips that wait so cleanup fits the guard's grace.
        drain_deadline = time.monotonic() + 8
        while INTERRUPTED_BY is None and any(child.poll() is None for child, _ in self.children.values()):
            if time.monotonic() >= drain_deadline:
                break
            time.sleep(.025)
        cleanup = stop_owned_groups(list(self.children.values()))
        self.result['ownedGroupCleanup'] = cleanup
        if INTERRUPTED_BY is not None:
            self.result.update(status='FAILED_NO_REPLAY', interruptedBy=INTERRUPTED_BY)
        self.result['allDirectChildrenReaped'] = all(child.poll() is not None for child, _ in self.children.values())
        if hasattr(self, 'state_file'):
            try:
                self.result['contactsAtExit'] = self.state()['activeWindowTouches']
            except (OSError, ValueError, KeyError, RuntimeError) as error:
                self.result['exitReadbackError'] = str(error)
        if self.result['status'] == 'PASS_BOUNDED' and (
                not cleanup['allGroupsStopped'] or not self.result['allDirectChildrenReaped']
                or self.result.get('contactsAtExit') != 0):
            self.result.update(status='FAILED_NO_REPLAY', error='Final child or actual contact cleanup was not confirmed')
        self.result['finishedAt'] = datetime.now(timezone.utc).isoformat()
        self.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['cli', 'operator', 'fixture-app', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--udid', type=uuid.UUID, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--gesture', choices=['hold', 'drag', 'pinch'], required=True)
    parser.add_argument('--change', choices=['fold', 'rotate'], required=True)
    parser.add_argument('--fold-degrees', type=float, default=0)
    parser.add_argument('--expect-panel-change', action='store_true',
                        help='Require a measured panel switch for this explicit fold setup, such as inner180 to closed0.')
    args = parser.parse_args()
    args.udid = str(args.udid)
    for name in ['cli', 'operator', 'fixture_app']:
        setattr(args, name, getattr(args, name).resolve(strict=True))
    args.helper = args.cli.with_name('cadisplay-context').resolve(strict=True)
    require(all(os.access(file, os.X_OK) for file in [args.cli, args.helper, args.operator]), 'CLI, helper and operator must be executable')
    require(args.pid > 0 and math.isfinite(args.fold_degrees) and 0 <= args.fold_degrees <= 180, 'Invalid PID or fold target')
    require(not args.expect_panel_change or args.change == 'fold', '--expect-panel-change requires a fold case')
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    check = Check(args)
    signal.signal(signal.SIGINT, handle_termination)
    signal.signal(signal.SIGTERM, handle_termination)
    try:
        check.prepare()
        check.exercise()
    except BaseException as error:
        check.result.update(status='FAILED_NO_REPLAY', error=repr(error))
    finally:
        check.close()
    print(json.dumps(check.result, sort_keys=True))
    return 0 if check.result['status'] == 'PASS_BOUNDED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
