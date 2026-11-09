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
        self.expected_generation = None
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
        result = self.axe(name, 'displays', '--verbose')
        assert result['requestedSimulatorUDID'].upper() == self.args.device.upper()
        assert result['activePanel']['active']
        return result

    def selection(self, catalogue):
        identity = catalogue['activePanel']['identity']
        # --verbose prints the full JSON receipt these checks parse.
        return ['--input-mode', 'selected', '--screen-id', str(identity['displayID']),
                '--screen-uuid', identity['uniqueID'], '--verbose']

    def container(self):
        value = self.run('data-container', [self.simctl, 'get_app_container', self.args.device,
                         'com.cameroncooke.AxePlayground', 'data'], json_output=False)
        self.data = Path(value.strip()) / 'Documents/state.json'

    def state(self, name):
        raw = self.data.read_bytes()
        (self.folder / (name + '.json')).write_bytes(raw)
        state = json.loads(raw)
        assert state['fixtureVersion'] == 6
        assert state['pid'] == self.args.pid
        if self.expected_generation is None:
            self.expected_generation = state['generation']
        assert state['generation'] == self.expected_generation
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
        shown = self.axe('show-pad', 'tap', '--id', 'feature.showPad', '--element-type', 'Button',
                         '--tap-style', 'physical', '--expected-pid', str(pid), *self.selection(catalogue))
        assert shown['outcome'] == 'enqueuedAndDrained' and shown['enqueuedEventCount'] == 2
        assert shown['cleanup'] == 'notNeeded' and not shown.get('quarantine')
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
        assert validation['frontmostPID'] == pid and validation['hitPID'] == pid
        assert validation.get('confirmedHitPID') in [None, pid]
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

    def refind(self):
        self.container()
        self.tap(self.catalogue('catalogue'), self.args.pid)
        self.result['pid'] = self.args.pid

    def finish(self, error=None):
        self.result['status'] = 'FAILED_NO_REPLAY' if error else 'PASSED_BOUNDED'
        if error:
            self.result['error'] = repr(error)
        self.result['commands'] = self.commands
        save(self.folder / 'result.json', self.result)
        print(json.dumps(self.result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', required=True, choices=['refind'])
    parser.add_argument('--cli', required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--pid', type=int, required=True)
    args = parser.parse_args()
    if args.pid <= 0:
        parser.error('This check requires the actual current Playground PID')
    check = Check(args)
    try:
        check.refind()
    except BaseException as error:
        check.finish(error)
        raise
    check.finish()


if __name__ == '__main__':
    main()
