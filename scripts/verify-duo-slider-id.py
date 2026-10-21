#!/usr/bin/env python3
"""Run one selected slider-ID case. Save raw evidence; never retry input."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


def read_json(file):
    return json.loads(file.read_text())


def save_json(file, value):
    file.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def run(folder, name, argv, timeout=40):
    save_json(folder / (name + '-argv.json'), argv)
    child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, stderr = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        child.terminate()
        try:
            stdout, stderr = child.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            stdout, stderr = child.communicate()
        (folder / (name + '.stdout')).write_bytes(stdout)
        (folder / (name + '.stderr')).write_bytes(stderr)
        save_json(folder / (name + '-process.json'), dict(argv=argv, exitCode=child.returncode,
                  reaped=True, timedOut=True))
        raise RuntimeError('Command timed out; do not replay input')
    (folder / (name + '.stdout')).write_bytes(stdout)
    (folder / (name + '.stderr')).write_bytes(stderr)
    record = dict(argv=argv, exitCode=child.returncode, reaped=True, timedOut=False)
    save_json(folder / (name + '-process.json'), record)
    return record, stdout


def check_pins(root):
    for pin in read_json(root / 'candidate/frozen.json')['pins']:
        assert hashlib.sha256(Path(pin['source']).read_bytes()).hexdigest() == pin['sha256'], pin['source']
        assert hashlib.sha256((root / pin['saved']).read_bytes()).hexdigest() == pin['sha256'], pin['saved']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--request', type=Path, required=True)
    parser.add_argument('--name', required=True)
    args = parser.parse_args()
    assert args.name and Path(args.name).name == args.name
    root = args.evidence.resolve()
    check_pins(root)
    binding = read_json(root / 'bindings.json')
    request = read_json(args.request)
    folder = root / ('transitions' if request['kind'] in ('rotate', 'hinge') else 'cases') / args.name
    folder.mkdir(parents=True, exist_ok=False)
    save_json(folder / 'request.json', request)
    state_file = Path(binding['container']) / 'Documents/state.json'
    before = read_json(state_file)
    assert before['pid'] == binding['pid'] and before['activeWindowTouches'] == 0
    assert before['fixtureVersion'] == 1 and before['bundleIdentifier'] == binding['bundleIdentifier']
    assert before['sliderCallbacksDropped'] == before['windowTraceDropped'] == before['unmatchedTouchEvents'] == 0
    assert not any(slider['tracking'] for slider in before['sliders'].values())
    save_json(folder / 'before.json', before)
    axe = str(root / 'runtime-exact/axe')
    base = ['--udid', binding['simulatorUDID']]
    record, raw = run(folder, 'catalogue-before', [axe, 'list-simulators', '--displays'] + base)
    assert record['exitCode'] == 0
    catalogue = json.loads(raw)
    save_json(folder / 'catalogue-before.json', catalogue)
    assert catalogue['bootIdentity'] == binding['bootIdentity']
    active = catalogue['activePanel']['identity']
    assert active['displayID'] == request['screenID'] and active['uniqueID'] == request['screenUUID']
    selected = ['--input-mode', 'selected', '--screen-id', str(request['screenID']),
                '--screen-uuid', request['screenUUID'], '--expected-pid', str(binding['pid'])]
    if request['kind'] in ('endpoint', 'tap'):
        selector = ['--' + request['selectorKind'], request['selectorValue']]
        command = [axe, 'slider' if request['kind'] == 'endpoint' else 'tap'] + base + selected + selector
        if request['kind'] == 'endpoint':
            command += ['--endpoint', request['endpoint']]
        if request.get('elementType'):
            command += ['--element-type', request['elementType']]
    elif request['kind'] == 'rotate':
        command = [axe, 'rotate', request['direction']] + base + ['--screen-id', str(request['screenID']),
            '--screen-uuid', request['screenUUID'], '--expected-boot', binding['bootIdentity']]
    elif request['kind'] == 'hinge':
        target = binding['inner']
        command = [axe, 'hinge', 'set', str(request['degrees'])] + base + [
            '--expected-boot', binding['bootIdentity'], '--wait-for-screen-id', str(target['screenID']),
            '--wait-for-screen-uuid', target['screenUUID']]
    else:
        raise ValueError('Unsupported case kind')
    command_record, response_raw = run(folder, 'command', command)
    save_json(folder / 'command.json', command_record)
    try:
        save_json(folder / 'response.json', json.loads(response_raw))
    finally:
        time.sleep(0.4)
        after = read_json(state_file)
        save_json(folder / 'after.json', after)
        assert after['pid'] == binding['pid']
        check_pins(root)
    record, raw = run(folder, 'catalogue-after', [axe, 'list-simulators', '--displays'] + base)
    assert record['exitCode'] == 0
    save_json(folder / 'catalogue-after.json', json.loads(raw))
    print(json.dumps(dict(name=args.name, exitCode=command_record['exitCode'],
        outcome=read_json(folder / 'response.json').get('outcome'),
        callbacksBefore=before['callbackSequence'], callbacksAfter=after['callbackSequence'],
        touchesBefore=len(before['windowTouchTrace']), touchesAfter=len(after['windowTouchTrace']),
        activeTouches=after['activeWindowTouches'], reaped=True)), flush=True)


if __name__ == '__main__':
    main()
