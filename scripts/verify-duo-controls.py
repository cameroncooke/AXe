#!/usr/bin/env python3
"""Bounded native Duo control checks. Run under the coordinator resource guard.

Each invocation performs one named check. Writes are never retried. Native output,
return codes, process IDs and state copies are saved before assertions run.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import time


def save(file, value):
    file.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


class Check:
    def __init__(self, args):
        self.args = args
        self.folder = Path(args.out)
        self.folder.mkdir(parents=True, exist_ok=False)
        self.cli = str(Path(args.cli).resolve(strict=True))
        self.simctl = str(Path(os.environ['DEVELOPER_DIR']) / 'usr/bin/simctl')
        self.commands = []
        self.result = {'status': 'STARTED', 'case': args.case, 'device': args.device,
                       'cli': self.cli, 'cliSHA256': hashlib.sha256(Path(self.cli).read_bytes()).hexdigest()}
        save(self.folder / 'started.json', self.result)

    def run(self, name, command, expected=0, timeout=35, json_output=True):
        save(self.folder / (name + '-argv.json'), command)
        started = time.monotonic()
        child = None
        sent = []
        with (self.folder / (name + '-stdout')).open('xb') as stdout, (self.folder / (name + '-stderr')).open('xb') as stderr:
            # Keep client children in the outer resource guard's process group.
            child = subprocess.Popen(command, stdout=stdout, stderr=stderr)
            try:
                code = child.wait(timeout=timeout)
            except BaseException:
                for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGKILL]:
                    if child.poll() is not None:
                        break
                    child.send_signal(sig)
                    sent.append(sig.name)
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        pass
                raise
            finally:
                receipt = dict(command=command, pid=child.pid, exitCode=child.poll(),
                               reaped=child.poll() is not None, signals=sent,
                               elapsedSeconds=time.monotonic() - started)
                self.commands.append(receipt)
                save(self.folder / (name + '-process.json'), receipt)
        text = (self.folder / (name + '-stdout')).read_text()
        assert code == expected, (name, code, (self.folder / (name + '-stderr')).read_text())
        return json.loads(text) if json_output else text

    def axe(self, name, *arguments, **kwargs):
        return self.run(name, [self.cli, *arguments, '--udid', self.args.device], **kwargs)

    def catalogue(self, name):
        result = self.axe(name, 'list-simulators', '--displays')
        assert result['requestedSimulatorUDID'].upper() == self.args.device.upper()
        assert result['activePanel']['active']
        return result

    def selection(self, catalogue):
        identity = catalogue['activePanel']['identity']
        return ['--input-mode', 'selected', '--screen-id', str(identity['displayID']),
                '--screen-uuid', identity['uniqueID']]

    def container(self):
        value = self.run('data-container', [self.simctl, 'get_app_container', self.args.device,
                         'com.camsoft.duo-session-probe', 'data'], json_output=False)
        self.data = Path(value.strip()) / 'Documents/state.json'

    def state(self, name):
        raw = self.data.read_bytes()
        (self.folder / (name + '.json')).write_bytes(raw)
        state = json.loads(raw)
        assert state['fixtureVersion'] == 6
        assert state['activeWindowTouches'] == 0
        assert state['windowTraceDropped'] == 0 and state['recognizerTraceDropped'] == 0
        return state

    def description(self, name, catalogue, pid):
        result = self.axe(name, 'describe-ui', *self.selection(catalogue), '--expected-pid', str(pid))
        hits = [v for v in walk(result) if v.get('AXUniqueId') == 'feature.tap' and v.get('frame')]
        frames = {tuple(v['frame'][key] for key in ['x', 'y', 'width', 'height']) for v in hits}
        assert len(frames) == 1, frames
        frame = frames.pop()
        assert frame[2] > 0 and frame[3] > 0 and all(math.isfinite(v) for v in frame)
        return result

    def tap(self, catalogue, pid):
        self.description('fresh-description', catalogue, pid)
        before = self.state('before-tap')
        response = self.axe('fresh-tap', 'tap', '--id', 'feature.tap', '--element-type', 'Button',
                            '--tap-style', 'physical', '--expected-pid', str(pid), *self.selection(catalogue))
        assert response['outcome'] == 'enqueuedAndDrained' and response['enqueuedEventCount'] == 2
        assert response['cleanup'] == 'notNeeded' and not response.get('quarantine')
        target = response['ax']['target']
        validation = response['ax']['validation']
        assert target['AXUniqueId'] == 'feature.tap' and target['pid'] == pid and target['type'] == 'Button'
        assert validation['verifiedTarget']['AXUniqueId'] == 'feature.tap' and validation['verifiedTarget']['pid'] == pid
        assert validation['frontmostPID'] == pid and validation['confirmedHitPID'] == pid
        time.sleep(0.5)
        after = self.state('after-tap')
        assert after['counts'].get('tap', 0) == before['counts'].get('tap', 0) + 1
        trace = after['windowTouchTrace'][len(before['windowTouchTrace']):]
        assert len(trace) == 2 and trace[0]['phase'] == 'windowTouchBegan' and trace[1]['phase'] == 'windowTouchEnded'
        assert trace[0]['contactID'] == trace[1]['contactID'] and all(v['hitView'] == 'feature.tap' for v in trace)
        assert trace[-1]['activeTouches'] == 0
        point = response['ax']['point']
        assert all(abs(v['x'] - point['x']) < 0.5 and abs(v['y'] - point['y']) < 0.5 for v in trace)
        for key in set(before['counts']) | set(after['counts']):
            increase = 1 if key in ['tap', 'windowTouchBegan', 'windowTouchEnded'] else 0
            assert after['counts'].get(key, 0) == before['counts'].get(key, 0) + increase, key
        for key in ['text', 'textFocused', 'slider', 'switchOn', 'pageOffsetY', 'listOffsetY', 'pinchScale', 'rotationRadians']:
            assert before[key] == after[key], key
        context = response['context']
        assert context['bootIdentity'] == catalogue['bootIdentity']
        assert context['screenID'] == catalogue['activePanel']['identity']['displayID']
        assert context['screenUUID'].upper() == catalogue['activePanel']['identity']['uniqueID'].upper()
        self.result['freshTap'] = {'before': before['counts'].get('tap', 0), 'after': after['counts']['tap'],
                                   'contactID': trace[0]['contactID'], 'context': context}

    def prepare(self):
        value = self.run('launch', [self.simctl, 'launch', self.args.device, 'com.camsoft.duo-session-probe'], json_output=False)
        pid = int(value.strip().split(': ')[-1])
        self.container()
        catalogue = self.catalogue('catalogue')
        inner = next(p for p in catalogue['panels'] if p['identity']['displayID'] == 3)
        response = self.axe('open', 'hinge', 'set', '180', '--expected-boot', catalogue['bootIdentity'],
                            '--wait-for-screen-id', '3', '--wait-for-screen-uuid', inner['identity']['uniqueID'])
        assert response['outcome'] == 'observedMechanicalTargetAndDisplayCoherence'
        catalogue = self.catalogue('opened-catalogue')
        assert catalogue['activePanel']['identity']['displayID'] == 3
        self.description('description', catalogue, pid)
        self.state('ready-state')
        self.result.update(pid=pid, catalogue=catalogue, data=str(self.data))

    def side(self, batch=False):
        self.container()
        before = self.state('before')
        catalogue = self.catalogue('catalogue')
        if batch:
            command = ['batch', *self.selection(catalogue), '--step',
                       'button side-button --duration 0.2 --expected-boot ' + catalogue['bootIdentity'],
                       '--step', 'button side-button --duration 0',
                       '--step', 'tap --id feature.tap --expected-pid ' + str(self.args.pid)]
            raw = self.axe('side-batch', *command, expected=1, json_output=False)
            rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
            assert len(rows) == 2 and rows[0]['status'] == 'completed' and rows[1]['status'] == 'rejectedBeforeSend'
            assert rows[1].get('requestID') is None and rows[1].get('response') is None
            response = rows[0]['response']
        else:
            response = self.axe('side', 'button', 'side-button', '--duration', '0.2',
                                '--expected-boot', catalogue['bootIdentity'], *self.selection(catalogue))
        assert response['outcome'] == 'enqueuedAndDrained' and response['enqueuedEventCount'] == 2
        assert response['cleanup'] == 'notNeeded' and not response.get('quarantine')
        evidence = response['button']['execution']
        assert response['button']['kind'] == 'side-button'
        assert evidence['phase'] == 'completed' and evidence['sentPrimitiveCount'] == 2
        assert evidence['plannedPrimitiveCount'] == 2 and evidence['allInputsReleasedBeforeCleanup'] and evidence['drainCompleted']
        assert not evidence.get('interruption') and evidence['executionCleanup'] == 'notNeeded'
        cleanup = evidence['cleanupEvidence']
        assert cleanup['outcome'] == 'notNeeded' and cleanup['contextValidation'] == 'noOwnedInput'
        assert not cleanup['releases'] and not cleanup['timedOut']
        time.sleep(1)
        after = self.state('after')
        assert after['counts'] == before['counts'] and after['windowTouchTrace'] == before['windowTouchTrace']
        fresh = self.catalogue('after-catalogue')
        assert fresh['bootIdentity'] == catalogue['bootIdentity']
        identity = fresh['activePanel']['identity']
        self.axe('screen', 'screenshot', '--screen-id', str(identity['displayID']), '--screen-uuid', identity['uniqueID'],
                 '--expected-boot', fresh['bootIdentity'], '--output', str(self.folder / 'after.png'))
        self.result.update(catalogue=fresh, transport='two normal events, released and drained',
                           visual='MANUAL_REVIEW_REQUIRED', securityLock='UNVERIFIED', power='UNVERIFIED')

    def normal_return(self):
        value = self.run('launch', [self.simctl, 'launch', self.args.device, 'com.camsoft.duo-session-probe'], json_output=False)
        assert int(value.strip().split(': ')[-1]) == self.args.pid
        self.container()
        catalogue = self.catalogue('catalogue')
        self.tap(catalogue, self.args.pid)
        self.result['pid'] = self.args.pid

    def refind(self):
        self.container()
        self.tap(self.catalogue('catalogue'), self.args.pid)
        self.result['pid'] = self.args.pid

    def hinge(self):
        self.container()
        before = self.state('before')
        original = self.catalogue('before-catalogue')
        response = self.axe('hinge', 'hinge', 'set', str(self.args.degrees), '--tolerance', '0.1',
                            '--expected-boot', original['bootIdentity'])
        assert response['outcome'] == 'observedMechanicalTarget'
        receipt = response['hinge']['receipt']
        samples = receipt['matchingSamples']
        assert len(samples) == 2 and all(abs(s['mechanicalDegrees'] - self.args.degrees) <= 0.1 for s in samples)
        first = self.catalogue('after-catalogue')
        time.sleep(0.25)
        final = self.catalogue('settled-catalogue')
        assert first['bootIdentity'] == final['bootIdentity'] == original['bootIdentity']
        assert first['activePanel'] == final['activePanel']
        after = self.state('after')
        assert before['counts'] == after['counts'] and before['windowTouchTrace'] == after['windowTouchTrace']
        changed = original['activePanel']['identity'] != final['activePanel']['identity']
        if changed:
            rejected = self.axe('stale-panel-tap', 'tap', '--id', 'feature.tap', '--expected-pid', str(self.args.pid), *self.selection(original), expected=1)
            assert rejected['enqueuedEventCount'] == 0 and rejected['cleanup'] == 'notNeeded'
            assert 'inactiveSelection' in json.dumps(rejected)
            assert self.state('after-rejection') == after
            self.tap(final, self.args.pid)
        self.result.update(requestedDegrees=self.args.degrees, matchingSamples=samples,
                           beforePanel=original['activePanel'], afterPanel=final['activePanel'],
                           activePanelChanged=changed)

    def finish(self, error=None):
        self.result['status'] = 'FAILED_NO_REPLAY' if error else 'PASSED_BOUNDED'
        if error:
            self.result['error'] = repr(error)
        self.result['commands'] = self.commands
        save(self.folder / 'result.json', self.result)
        print(json.dumps(self.result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', required=True, choices=['prepare', 'side', 'batch-side', 'return', 'refind', 'hinge'])
    parser.add_argument('--cli', required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--pid', type=int)
    parser.add_argument('--degrees', type=float)
    args = parser.parse_args()
    if args.case in ['return', 'refind', 'batch-side', 'hinge'] and (args.pid is None or args.pid <= 0):
        parser.error('This check requires the actual current fixture PID')
    if args.case == 'hinge' and (args.degrees is None or not math.isfinite(args.degrees) or not 0 <= args.degrees <= 180):
        parser.error('Hinge check requires an angle in 0...180')
    check = Check(args)
    try:
        if args.case == 'prepare':
            check.prepare()
        elif args.case == 'side':
            check.side()
        elif args.case == 'batch-side':
            check.side(batch=True)
        elif args.case == 'return':
            check.normal_return()
        elif args.case == 'refind':
            check.refind()
        elif args.case == 'hinge':
            check.hinge()
    except BaseException as error:
        check.finish(error)
        raise
    check.finish()


if __name__ == '__main__':
    main()
