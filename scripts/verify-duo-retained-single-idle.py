#!/usr/bin/env python3
"""Check the public retained-single owner after one external rotation, without replay."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

BUNDLE = 'com.camsoft.duo-session-probe'


def require(value, message):
    if not value:
        raise ValueError(message)


def save(file, value):
    file.write_text(json.dumps(value, indent=2) + '\n')


def walk(nodes):
    for node in nodes:
        yield node
        yield from walk(node.get('children', []))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--resource-probe', type=Path, required=True)
    parser.add_argument('--pins', type=Path, required=True)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    frozen = args.out / 'candidate'
    frozen.mkdir()
    pins = json.loads(args.pins.read_text())
    for pin in pins['files']:
        source = Path(pin['original'])
        require(hashlib.sha256(source.read_bytes()).hexdigest() == pin['sha256'], 'Candidate changed: ' + pin['label'])
        target = frozen / pin['label']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    driver = frozen / 'single-driver'
    shutil.copy2(Path(__file__), driver)
    save(args.out / 'frozen-inputs.json', dict(files=pins['files'], copies=str(frozen),
        singleDriverSHA256=hashlib.sha256(driver.read_bytes()).hexdigest(), beforeNativeLaunch=True))
    token = None
    failed = False

    def run(name, command, expected=0):
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        (args.out / (name + '.stdout')).write_text(result.stdout)
        (args.out / (name + '.stderr')).write_text(result.stderr)
        save(args.out / (name + '-process.json'), dict(command=command, exitCode=result.returncode, reaped=True))
        require(result.returncode == expected, name + ' failed; no replay')
        return result.stdout

    def displays(name):
        return json.loads(run(name, [str(args.cli), 'list-simulators', '--displays', '--udid', args.udid]))

    def selected(name, verb, extra, display, expected=0):
        identity = display['activePanel']['identity']
        command = [str(args.cli), verb, *extra, '--udid', args.udid,
            '--input-mode', 'selected', '--screen-id', str(identity['displayID']),
            '--screen-uuid', identity['uniqueID']]
        if verb in ('describe-ui', 'tap'):
            command += ['--expected-pid', str(args.pid)]
        return json.loads(run(name, command, expected))

    def target(description, identifier):
        nodes = [node for node in walk(description['ax']['roots']) if node.get('AXUniqueId') == identifier]
        require(len(nodes) == 1 and nodes[0]['pid'] == args.pid and nodes[0]['enabled'], 'Fresh owned target missing')
        return nodes[0]['frame']

    def state(name):
        value = json.loads(state_file.read_text())
        require(value['fixtureVersion'] == 6, 'Fixture v6 required')
        save(args.out / (name + '.json'), value)
        return value

    def wait_state(name, predicate):
        deadline = time.monotonic() + 5
        while True:
            value = json.loads(state_file.read_text())
            if predicate(value):
                save(args.out / (name + '.json'), value)
                return value
            require(time.monotonic() < deadline, 'Actual app state timeout: ' + name)
            time.sleep(.025)

    try:
        container = run('container', ['/usr/bin/xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']).strip()
        process_rows = run('pid', ['/usr/bin/xcrun', 'simctl', 'spawn', args.udid, 'launchctl', 'list'])
        matching = [line.split() for line in process_rows.splitlines() if 'UIKitApplication:' + BUNDLE + '[' in line]
        require(len(matching) == 1 and matching[0][0] == str(args.pid), 'Fixture PID changed')
        state_file = Path(container) / 'Documents/state.json'
        before = state('before')
        require(before['activeWindowTouches'] == 0 and not before['textFocused'], 'Fixture is not idle')
        display = displays('displays-before')
        description = selected('describe-before', 'describe-ui', [], display)
        frame = target(description, 'feature.pad')
        x, y = frame['x'] + frame['width']/2, frame['y'] + frame['height']/2
        resource = json.loads(subprocess.run([str(args.resource_probe)], capture_output=True,
            text=True, check=True, timeout=5).stdout)
        rows = resource['rows']
        app_ids = {row['pid'] for row in rows if row['name'] in ('ChatGPT', 'Codex')}
        while True:
            children = {row['pid'] for row in rows if row['ppid'] in app_ids} - app_ids
            if not children:
                break
            app_ids.update(children)
        app_gib = sum(row['footprintBytes'] for row in rows if row['pid'] in app_ids)/1073741824
        save(args.out / 'idle-resource.json', dict(appFootprintGiB=app_gib, newInputLimitGiB=7.75))
        require(app_gib < 7.75, 'Idle app limit reached; no touch')
        began = selected('began', 'touch', ['-x', str(x), '-y', str(y), '--down'], display)
        token = began.get('token')
        require(token and began['outcome'] == 'retained' and began['enqueuedEventCount'] == 1, 'Public touch did not retain')
        held = wait_state('held', lambda value:value['activeWindowTouches'] == 1)
        starts = held['windowTouchTrace'][len(before['windowTouchTrace']):]
        require(len(starts) == 1 and starts[0]['phase'] == 'windowTouchBegan', 'Actual single contact missing')
        contact_id = starts[0]['contactID']
        moved = selected('moved', 'touch', ['-x', str(x+10), '-y', str(y), '--down', '--contact-token', token], display)
        require(moved.get('token') == token and moved['outcome'] == 'moved' and moved['enqueuedEventCount'] == 1, 'Public move failed')
        actual_moved = wait_state('held-before-change', lambda value:value['activeWindowTouches'] == 1 and
            value['windowTouchTrace'][-1]['phase'] == 'windowTouchMoved' and
            abs(value['windowTouchTrace'][-1]['x']-x-10)<.5 and abs(value['windowTouchTrace'][-1]['y']-y)<.5)
        context = description['context']
        config = dict(simulatorUDID=args.udid, bootIdentity=display['bootIdentity'], screenID=context['screenID'],
            screenUUID=context['screenUUID'], helperPath=str(args.cli.with_name('cadisplay-context')),
            first=dict(x=x,y=y), second=dict(x=x+20,y=y), movedFirst=dict(x=x+10,y=y),
            movedSecond=dict(x=x+30,y=y), staleFirst=dict(x=x+15,y=y), staleSecond=dict(x=x+35,y=y),
            coordinationDirectory=str(args.out), mode='rotate', hingeDegrees=180)
        save(args.out / 'configuration.json', config)
        change = json.loads(run('external-change', [str(args.probe), 'change', str(args.out / 'configuration.json')]))
        save(args.out / 'external-change.json', change)
        time.sleep(1)
        idle = state('idle-before-next-command')
        require(idle['activeWindowTouches'] == 0, 'Public retained contact stayed held during idle')
        suffix = idle['windowTouchTrace'][len(actual_moved['windowTouchTrace']):]
        require(len(suffix) == 1 and suffix[0]['contactID'] == contact_id and suffix[0]['phase'] in ('windowTouchEnded','windowTouchCancelled'), 'Owned single release not observed')
        save(args.out / 'pre-next-command.json', dict(actualHeldContacts=0, contactID=contact_id,
            oldMoveEndCloseSent=False, idleApp=idle, publicBrokerID=began['brokerID']))
        old = selected('old-move', 'touch', ['-x', str(x+15), '-y', str(y), '--down', '--contact-token', token], display, expected=1)
        require(old['enqueuedEventCount'] == 0 and old.get('token') is None and old.get('quarantine') is None and
            'invalidToken' in old.get('error',''), 'Public owner did not clear old token cleanly')
        fresh_display = displays('displays-after')
        fresh_description = selected('describe-after', 'describe-ui', [], fresh_display)
        target(fresh_description, 'feature.tap')
        tap = selected('fresh-tap', 'tap', ['--id', 'feature.tap', '--tap-style', 'physical'], fresh_display)
        require(tap['outcome'] == 'enqueuedAndDrained' and tap['enqueuedEventCount'] == 2 and
            tap.get('quarantine') is None and tap['brokerID'] == began['brokerID'] == old['brokerID'], 'Public owner quarantined or changed broker')
        after = wait_state('after-tap', lambda value:value['activeWindowTouches'] == 0 and value['counts'].get('tap',0) == idle['counts'].get('tap',0)+1)
        after_rows = run('pid-after', ['/usr/bin/xcrun', 'simctl', 'spawn', args.udid, 'launchctl', 'list'])
        after_pid = [line.split() for line in after_rows.splitlines() if 'UIKitApplication:' + BUNDLE + '[' in line]
        require(len(after_pid) == 1 and after_pid[0][0] == str(args.pid), 'Fixture PID changed after input')
        save(args.out / 'result.json', dict(status='PASS', scope='Public CLI retained-single owner after external rotation',
            contactID=contact_id, idleHeldContacts=0, idleReleaseBeforeNextCommand=True,
            oldMoveNormalEvents=0, sameBroker=True, quarantine=False, freshNamedButtonEffects=1,
            heldTouchesAtEnd=after['activeWindowTouches']))
    except BaseException as error:
        failed = True
        save(args.out / 'failure.json', dict(error=repr(error), noReplay=True))
        raise
    finally:
        if failed and token is not None:
            try:
                old_file = args.out / 'old-move.stdout'
                if old_file.exists():
                    try:
                        old_reply = json.loads(old_file.read_text())
                        token = old_reply.get('token') or token
                    except ValueError:
                        save(args.out / 'owned-cleanup-note.json', dict(reason='Old reply was not JSON; release uses the original owned token'))
                selected('owned-cleanup-up', 'touch', ['-x', str(x), '-y', str(y), '--up', '--contact-token', token], display)
            except BaseException as cleanup_error:
                save(args.out / 'owned-cleanup-error.json', dict(error=repr(cleanup_error)))


if __name__ == '__main__':
    main()
