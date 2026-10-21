#!/usr/bin/env python3
"""Validate saved idle-release proof. This starts no simulator and sends no input."""
import argparse
import hashlib
import json
from pathlib import Path


def require(value, reason):
    if not value:
        raise ValueError(reason)


def read(folder, name):
    return json.loads((folder/name).read_text())


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def walk(nodes):
    for node in nodes:
        yield node
        yield from walk(node.get('children', []))


def validate_pins(pins, current=False, copies=None):
    for pin in pins:
        snapshot = Path(copies)/pin['label'] if copies else Path(pin['snapshot'])
        require(digest(snapshot) == pin['sha256'], 'Saved pin changed: ' + pin['label'])
        if current:
            require(digest(Path(pin['original'])) == pin['sha256'], 'Current input changed: ' + pin['label'])


def fresh_tap(folder, before_name, pid):
    before = read(folder, before_name)
    after = read(folder, 'after-tap.json')
    description = read(folder, 'describe-after.stdout')
    tap = read(folder, 'fresh-tap.stdout')
    nodes = [node for node in walk(description['ax']['roots']) if node.get('AXUniqueId') == 'feature.tap']
    require(len(nodes) == 1 and nodes[0]['pid'] == pid, 'Fresh named Button/PID missing')
    require(tap['outcome'] == 'enqueuedAndDrained' and tap['enqueuedEventCount'] == 2 and
        tap.get('error') is None and tap['context'] == description['context'], 'Fresh guarded tap failed')
    require(after['counts'].get('tap',0) == before['counts'].get('tap',0)+1 and after['activeWindowTouches'] == 0, 'Fresh callback/release missing')
    trace = after['windowTouchTrace'][len(before['windowTouchTrace']):]
    require(len(trace) == 2 and trace[0]['phase'] == 'windowTouchBegan' and
        trace[1]['phase'] == 'windowTouchEnded' and trace[0]['contactID'] == trace[1]['contactID'], 'Fresh Button contact did not end')
    frame = nodes[0]['frame']
    for event in trace:
        require(abs(event['x']-frame['x']-frame['width']/2)<.5 and
            abs(event['y']-frame['y']-frame['height']/2)<.5, 'Fresh Button contact used wrong coordinates')
    require((after['width'],after['height']) == (tap['context']['logicalWidth'],tap['context']['logicalHeight']), 'Fresh app coordinate space differs')
    return tap['context']


def pair_case(root, name, framework, current):
    folder = root/name
    frozen = read(folder, 'frozen-inputs.json')
    validate_pins(frozen['files'], current)
    before = read(folder, 'before.json')
    held = read(folder, 'held-before-move.json')
    moved = read(folder, 'held-before-change.json')
    config = read(folder, 'configuration.json')
    require(before['activeWindowTouches'] == 0 and held['activeWindowTouches'] == moved['activeWindowTouches'] == 2, 'Both actual contacts were not held')
    starts = held['windowTouchTrace'][len(before['windowTouchTrace']):]
    ids = {event['contactID'] for event in starts if event['phase'] == 'windowTouchBegan'}
    require(len(starts) == len(ids) == 2, 'Two distinct actual begins missing')
    for key in ('first','second'):
        require(any(abs(event['x']-config[key]['x'])<.5 and abs(event['y']-config[key]['y'])<.5 for event in starts), 'Actual begin coordinates differ')
    suffix = moved['windowTouchTrace'][len(before['windowTouchTrace']):]
    latest = [[event for event in suffix if event['contactID'] == cid][-1] for cid in ids]
    for key in ('movedFirst','movedSecond'):
        require(any(event['phase'] == 'windowTouchMoved' and abs(event['x']-config[key]['x'])<.5 and abs(event['y']-config[key]['y'])<.5 for event in latest), 'Both contacts did not move before change')
    for stage, outcome in (('began','retained'),('moved','moved')):
        receipt = read(folder, stage+'.json')
        require(receipt['frameworkPath'] == framework and receipt['operation']['outcome'] == outcome and
            receipt['operation']['normalEventDelta'] == 1 and receipt['operation']['sameOriginalToken'], 'Wrong library/token in actual pair')
    if name.endswith('normal'):
        ended = read(folder, 'ended.json')
        require(ended['operation']['outcome'] == 'endedAndDrained' and not ended['operation']['tokenReturned'], 'Normal end retained token')
        expected_count = 3
    else:
        idle = read(folder, 'idleAfterChange.json')
        idle_app = read(folder, 'idle-app.json')
        checkpoint = read(folder, 'pre-next-command.json')
        cleanup = idle['cleanupEvidence']
        require(checkpoint['library'] == idle and checkpoint['app'] == idle_app and not checkpoint['oldMoveEndCloseSent'], 'Pre-next-command checkpoint differs')
        require(idle['status']['state'] == 'invalidated' and not idle['status']['hasRetainedContact'] and
            idle['status']['normalEnqueuedEventCount'] == 2 and idle_app['activeWindowTouches'] == 0, 'Owned input remained during idle')
        releases = cleanup['releases']
        require(cleanup['outcome'] == 'releaseEnqueuedAndDrained' and cleanup['contextValidation'] == 'releaseIdentityMatchedBeforeAndAfter' and
            not cleanup['timedOut'] and cleanup['trigger'] == 'staleContext' and cleanup['finishedUptime'] <= idle['uptime'], 'Idle cleanup is incomplete/uncertain')
        require(len(releases) == 1 and releases[0]['primitive'] == 'TwoFingerTouch <hidden>' and releases[0]['returnedSuccessfully'], 'Missing source-bound paired UP')
        transport = releases[0]['transport']
        require(transport['messageType'] == 'IndigoDigitizerEvent' and
            transport['startedUptime'] <= transport['hostEnqueueCompletedUptime'] <= transport['guestBarrierStartedUptime'] <=
            transport['guestBarrierCompletedUptime'] <= releases[0]['finishedUptime'] <= cleanup['drainStartedUptime'] <= cleanup['drainCompletedUptime'], 'Idle release barrier/drain not confirmed')
        original = read(folder,'describe-before.stdout')['context']
        for identity in (cleanup['identityBefore'],cleanup['identityAfter']):
            for key in ('bootIdentity','screenID','screenUUID','nativePixelWidth','nativePixelHeight','scale'):
                require(identity[key] == original[key], 'Owned idle release migrated target/space: '+key)
        ends = idle_app['windowTouchTrace'][len(moved['windowTouchTrace']):]
        require(len(ends) == 2 and {event['contactID'] for event in ends} == ids and
            all(event['phase'] in ('windowTouchEnded','windowTouchCancelled') for event in ends), 'Both actual contacts were not released before next command')
        for stage in ('oldMove1','oldMove2'):
            old = read(folder,stage+'.json')
            require(old['uptime'] > idle['uptime'] and old['operation']['normalEventDelta'] == 0 and
                'invalidated' in old['operation']['error'] and old['cleanupEvidence'] == cleanup, 'Old request sent or repeated input')
        expected_count = 2
    closed = read(folder,'closed.json')
    require(closed['status']['state'] == 'closed' and not closed['status']['hasRetainedContact'] and
        not closed['operation']['tokenReturned'] and closed['status']['normalEnqueuedEventCount'] == expected_count, 'Closed pair state/token incomplete')
    require(read(folder,'idle-resource.json')['appFootprintGiB'] < 7.75, 'Input started above approved app threshold')
    context = fresh_tap(folder, 'after-pair.json', frozen['fixturePID'])
    return dict(case=name, contactIDs=sorted(ids), newContext=context)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--current', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    baseline = read(root,'pairs-idle-pins.json')
    validate_pins(baseline['files'],args.current)
    source = next(Path(pin['snapshot']).read_text() for pin in baseline['files'] if pin['label'] == 'session-source')
    require('releases.append(Self.event(contacts, direction: .up))' in source and
        'case let .pair(first, second): return .twoFingerTouch(direction: direction, finger1: first, finger2: second)' in source and
        'contacts = nil\n    token = nil' in source, 'Pinned cleanup does not bind paired UP/token clear')
    framework = str(Path(next(pin['original'] for pin in baseline['files'] if pin['label'] == 'cli')).parent/'FBSimulatorControl.framework')
    pairs = [pair_case(root,'pairs-idle-'+name,framework,args.current) for name in ('normal','fold','rotate')]
    folder = root/'pairs-idle-public-single-v3'
    frozen = read(folder,'frozen-inputs.json')
    validate_pins(frozen['files'],args.current,frozen['copies'])
    tool = read(root,'pairs-idle-single-tool-pin-v2.json')
    require(digest(Path(tool['snapshot'])) == tool['sha256'] == frozen['singleDriverSHA256'] == digest(folder/'candidate/single-driver'), 'Frozen public driver changed')
    if args.current:
        require(digest(Path(tool['original'])) == tool['sha256'], 'Current public driver changed')
    before = read(folder,'before.json')
    moved = read(folder,'held-before-change.json')
    checkpoint = read(folder,'pre-next-command.json')
    idle = read(folder,'idle-before-next-command.json')
    require(before['activeWindowTouches'] == 0 and moved['activeWindowTouches'] == 1 and idle['activeWindowTouches'] == 0 and
        checkpoint['idleApp'] == idle and not checkpoint['oldMoveEndCloseSent'], 'Public idle release checkpoint missing')
    starts = moved['windowTouchTrace'][len(before['windowTouchTrace']):]
    require(len(starts) == 2 and starts[0]['phase'] == 'windowTouchBegan' and starts[1]['phase'] == 'windowTouchMoved' and
        starts[0]['contactID'] == starts[1]['contactID'] == checkpoint['contactID'], 'Actual public begin/move missing')
    ends = idle['windowTouchTrace'][len(moved['windowTouchTrace']):]
    require(len(ends) == 1 and ends[0]['contactID'] == checkpoint['contactID'] and ends[0]['phase'] in ('windowTouchEnded','windowTouchCancelled'), 'Public contact did not release before next input')
    began = read(folder,'began.stdout')
    old = read(folder,'old-move.stdout')
    tap = read(folder,'fresh-tap.stdout')
    require(old['enqueuedEventCount'] == 0 and old.get('token') is None and old.get('quarantine') is None and
        'invalidToken' in old['error'] and began['brokerID'] == old['brokerID'] == tap['brokerID'] and tap.get('quarantine') is None, 'Public owner did not clear token cleanly')
    pid_lines = [line.split() for line in (folder/'pid-after.stdout').read_text().splitlines() if 'UIKitApplication:com.camsoft.duo-session-probe[' in line]
    require(len(pid_lines) == 1, 'Final public fixture PID missing')
    public_context = fresh_tap(folder,'idle-before-next-command.json',int(pid_lines[0][0]))
    require(read(folder,'result.json')['status'] == 'PASS' and read(folder,'idle-resource.json')['appFootprintGiB'] < 7.75, 'Public result/input resource gate failed')
    ready = read(root/'pairs-idle-cpu-readiness','result.json')
    require(ready['status'] == 'READY' and ready['observation']['stableSeconds'] >= 10 and ready['observation']['simulatorCPUPercent'] < 200, 'Bounded readiness did not complete')
    ax_ready = read(root/'pairs-idle-readiness-ax','stdout')
    require(ax_ready['outcome'] == 'ready' and ax_ready['enqueuedEventCount'] == 0, 'Read-only AX readiness failed')
    first = root/'pairs-idle-public-single'
    require("Unknown option '--expected-pid'" in (first/'began.stderr').read_text() and
        not (first/'held.json').exists(), 'Original parser failure changed')
    second = root/'pairs-idle-public-single-v2'
    failure = read(second,'describe-before.stdout')
    require(failure['outcome'] == 'failedBeforeInput' and failure['enqueuedEventCount'] == 0 and not (second/'began.stdout').exists(), 'Original bootstrap failure changed')
    log = (root/'pairs-idle-library-tests-v1/stdout').read_text()
    require('Test run with 17 tests in 2 suites passed' in log and 'Executed 9 tests, with 0 failures' in log, 'Focused and existing related checks did not run')
    guards = []
    expected_failures = {'pairs-idle-probe-compile-v1','pairs-idle-probe-compile-v2','pairs-idle-probe-compile-v3','pairs-idle-public-single-guard','pairs-idle-public-single-v2-guard'}
    for file in root.glob('pairs-idle-*/result.json'):
        receipt = json.loads(file.read_text())
        if 'stopReason' not in receipt:
            continue
        require(receipt['reaped'] and receipt['stopReason'] is None and not receipt['signalsSent'] and
            receipt['exitCode'] == (1 if file.parent.name in expected_failures else 0), 'Guard/exit changed: '+file.parent.name)
        guards.append(receipt)
    require(read(root/'pairs-idle-single-shutdown-v3','result.json')['exitCode'] == 0, 'Assigned guest shutdown failed')
    result = dict(status='RETAINED_IDLE_FIX_BOUNDED_NATIVE_VERIFIED', pairCases=pairs,
        ownedIdlePairChanges=2, oldPairRequests=4, oldPairNormalEvents=0,
        publicSingle=dict(contactID=checkpoint['contactID'],PID=int(pid_lines[0][0]),sameBroker=True,
            oldMoveNormalEvents=0,quarantine=False,freshCoordinateErrorBelowPoints=.5,newContext=public_context),
        freshNamedButtonEffects=4, allFinalContactsReleased=True, focusedSwiftFunctions=17,
        focusedSwiftArgumentCases=22, existingXCTestCases=9, productionScope='Library retained-input idle observation only',
        preservedFailures=['parser before public touch','cold accessibility bootstrap before public touch','two held compiler preflights','probe framework path'],
        sampledPeaks={key:max(receipt['peaks'][key] for receipt in guards) for key in ('app','simulator','command')},
        nativeGuardCount=len(guards), securityScan='UNVERIFIED', releaseUniversal='UNVERIFIED')
    (root/'pairs-idle-main-result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
