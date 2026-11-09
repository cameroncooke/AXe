#!/usr/bin/env python3
"""Quick A/B timing of AXe CLI commands on one simulator or physical device.

For iteration, not the release gate (benchmarks/ stays the release check). It runs the same direct
commands with a baseline and a candidate `axe` payload on the Playground's Tap Test screen, which taps
cannot leave, and reports whether the candidate is slower:

    scripts/bench-quick.py --baseline BASE/axe --candidate NEW/axe --udid UDID

Both binaries must be payloads (axe with Frameworks beside it); a debug build in .build/ loads the
frameworks of the current tree, so a baseline copied from it would not stay fixed.

Each pair runs one block per build, alternating which goes first. Before each block every AXe broker
for the target is stopped and its exit awaited, so a broker from any other build cannot serve the
block and device brokers never refuse the other build. A block times the first `describe-ui` after the
broker starts (cold), then repeats each command (warm), then checks that the last tap landed.

A command is reported slower only when the candidate's block median is slower in every pair (at least
five pairs; a chance result is then about 3% per command) and the median difference exceeds the
resolution: twice the median absolute deviation of that command's warm samples, and at least 3% of the
baseline median, below which a few samples cannot separate builds. Otherwise it prints "no difference"
with that resolution. Exit status: 0 no
regression, 1 regression, 2 inconclusive (failed commands).
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

BUNDLE = 'com.cameroncooke.AxePlayground'
ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / 'e2e-results' / 'bench-quick'


class CommandFailed(Exception):
    pass


def execute(command, env=None, timeout=90):
    started = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL,
                            env=env)
    seconds = time.monotonic() - started
    if result.returncode != 0:
        raise CommandFailed(f'{" ".join(command[1:])} exited {result.returncode}: {result.stderr.strip()[-300:]}')
    return seconds, result.stdout


def simulator_info(udid):
    result = subprocess.run(['xcrun', 'simctl', 'list', '-j', 'devices'], capture_output=True, text=True)
    for runtime, devices in (json.loads(result.stdout).get('devices', {}) if result.returncode == 0 else {}).items():
        for device in devices:
            if device.get('udid') == udid:
                return dict(name=device.get('name'), runtime=runtime.rsplit('.', 1)[-1], state=device.get('state'))
    return None


def device_info(binary, udid):
    try:
        _, output = execute([binary, '--output', 'json', 'list-devices'])
        for device in json.loads(output)['data']['result']['devices']:
            if device['udid'] == udid:
                return dict(name=device.get('name'), model=device.get('model'), os=device.get('osVersion'),
                            transport=device.get('transport'))
    except (CommandFailed, KeyError, ValueError):
        pass
    return None


def stop_brokers(udid):
    """Stops every AXe broker serving this target, from any build, and waits for each to exit."""
    listing = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
    pids = []
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(' ')
        arguments = command.split()
        if len(arguments) >= 3 and arguments[1] in ('hid-broker', 'physical-device-broker') \
                and udid.lower() in (a.lower() for a in arguments):
            pids.append(int(pid))
    for pid in pids:
        subprocess.run(['kill', '-TERM', str(pid)], capture_output=True)
    deadline = time.monotonic() + 5
    while pids and time.monotonic() < deadline:
        pids = [pid for pid in pids if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode == 0]
        time.sleep(0.05)
    for pid in pids:
        subprocess.run(['kill', '-KILL', str(pid)], capture_output=True)


def tree(binary, udid):
    _, output = execute([binary, 'describe-ui', '--udid', udid])
    return json.loads(output)


def walk(node):
    if isinstance(node, list):
        for item in node:
            yield from walk(item)
    elif isinstance(node, dict):
        yield node
        yield from walk(node.get('children') or [])


def tap_location(nodes):
    for node in walk(nodes):
        if str(node.get('AXLabel', '')).startswith('Tap Location'):
            value = str(node.get('AXValue', '')).replace('x:', '').replace('y:', '')
            parts = value.rsplit(',', 1)
            try:
                return int(parts[0].replace(',', '')), int(parts[1].replace(',', ''))
            except (IndexError, ValueError):
                return None
    return None


def launch_tap_test(binary, udid, simulator):
    if simulator:
        subprocess.run(['xcrun', 'simctl', 'terminate', udid, BUNDLE], capture_output=True)
        launched = subprocess.run(['xcrun', 'simctl', 'launch', udid, BUNDLE, '--launch-arg', 'screen=tap-test'],
                                  capture_output=True, text=True)
    else:
        # CoreDevice occasionally reports that the launched process exited (error 10004); retry once.
        for _ in range(2):
            launched = subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing',
                                       '--device', udid, BUNDLE, '--launch-arg', 'screen=tap-test'],
                                      capture_output=True, text=True)
            if launched.returncode == 0:
                break
            time.sleep(1)
    if launched.returncode != 0:
        sys.exit(f'Could not launch the Playground Tap Test screen: {launched.stderr.strip()[-300:]}')
    deadline = time.monotonic() + 20
    seen = 'nothing'
    while time.monotonic() < deadline:
        try:
            nodes = tree(binary, udid)
            labels = [n.get('AXLabel') for n in walk(nodes) if n.get('AXLabel')]
            if 'Tap Test' in labels:
                return nodes
            seen = ', '.join(str(label) for label in labels[:6])
        except (CommandFailed, ValueError) as error:
            seen = str(error)
        time.sleep(0.5)
    sys.exit(f'The Playground Tap Test screen did not appear (last read: {seen}). Install the Playground, '
             'unlock the target and dismiss any alert, then run again.')


def commands_for(simulator, full, width, height):
    """Commands per route. Tap points stay inside the Tap Test area, away from the title card."""
    raw_point = (int(width * 0.4), int(height * 0.55))
    selected_point = (int(width * 0.6), int(height * 0.65))
    commands = {}
    if simulator:
        commands['selected describe-ui'] = ['describe-ui', '--input-mode', 'selected']
        commands['selected tap'] = ['tap', '-x', str(selected_point[0]), '-y', str(selected_point[1]),
                                    '--input-mode', 'selected']
        commands['agent describe-ui'] = ['describe-ui', '--agent']
    # The raw tap runs last in each repeat, so the block's landing check reads its point: Tap Test's
    # "Tap Location" label does not record selected taps.
    commands['describe-ui'] = ['describe-ui']
    commands['key'] = ['key', '80']
    commands['tap'] = ['tap', '-x', str(raw_point[0]), '-y', str(raw_point[1])]
    last_point = raw_point
    if not simulator and full:
        step = f'tap -x {raw_point[0]} -y {raw_point[1]}'
        commands['tap --id'] = ['tap', '--id', 'tap-test-area']
        commands['batch 3 taps'] = ['batch', '--step', step, '--step', step, '--step', step]
        commands['screenshot'] = ['screenshot', '--output', str(Path(tempfile.mkdtemp()) / 'screen.png')]
    return commands, last_point


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git_state():
    head = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--short', 'HEAD'], capture_output=True, text=True)
    dirty = subprocess.run(['git', '-C', str(ROOT), 'status', '--porcelain'], capture_output=True, text=True)
    return dict(head=head.stdout.strip(), dirty=bool(dirty.stdout.strip()))


def verdict(base_blocks, cand_blocks, resolution, tolerance):
    """A difference counts when all but `tolerance` pairs agree and the median exceeds the resolution."""
    diffs = [statistics.median(c) - statistics.median(b) for b, c in zip(base_blocks, cand_blocks) if b and c]
    if not diffs:
        return None, 'no samples'
    median_diff = statistics.median(diffs)
    slower = sum(d > 0 for d in diffs)
    faster = sum(d < 0 for d in diffs)
    if slower >= len(diffs) - tolerance and median_diff > resolution:
        return median_diff, f'SLOWER in {slower} of {len(diffs)} pairs'
    if faster >= len(diffs) - tolerance and -median_diff > resolution:
        return median_diff, f'faster in {faster} of {len(diffs)} pairs'
    return median_diff, f'no difference ({slower} of {len(diffs)} pairs slower)'


# The target UDID, once known, so brokers are stopped on every exit path.
udid_holder = []


def main():
    try:
        run_main()
    finally:
        if udid_holder:
            stop_brokers(udid_holder[0])


def run_main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--baseline', required=True, help='baseline axe payload binary')
    parser.add_argument('--candidate', help='candidate axe payload binary (default: the baseline, with --self-check)')
    parser.add_argument('--udid', required=True, help='simulator UDID or physical device hardware UDID')
    parser.add_argument('--pairs', type=int, default=5, help='alternating pairs (default 5; 7 before deciding)')
    parser.add_argument('--repeats', type=int, default=3, help='warm repeats of each command per block (default 3)')
    parser.add_argument('--full', action='store_true', help='devices: also time tap --id, a 3-tap batch and a screenshot')
    parser.add_argument('--self-check', action='store_true', help='compare the baseline with itself to show the noise floor')
    parser.add_argument('--phases', action='store_true', help='record AXE_TIMING spans for the candidate agent commands')
    parser.add_argument('--accept', metavar='NAME', help='after a run without regression, copy the candidate payload to '
                        'e2e-results/bench-quick/baselines/NAME')
    args = parser.parse_args()
    if args.self_check:
        args.candidate = args.baseline
    if args.pairs < 5:
        print('note: fewer than 5 pairs cannot report a regression reliably; treat SLOWER as a hint', flush=True)
    if not args.candidate:
        parser.error('--candidate is required unless --self-check is set')
    binaries = {'baseline': str(Path(args.baseline).resolve()), 'candidate': str(Path(args.candidate).resolve())}
    for label, path in binaries.items():
        if not os.access(path, os.X_OK):
            sys.exit(f'{label} is not executable: {path}')

    udid_holder.append(args.udid)
    simulator = simulator_info(args.udid)
    target = simulator or device_info(binaries['candidate'], args.udid)
    if not target:
        sys.exit(f'No simulator or connected physical device has UDID {args.udid}.')
    if simulator and simulator.get('state') != 'Booted':
        sys.exit(f'Boot the simulator first: {args.udid}')
    stop_brokers(args.udid)
    nodes = launch_tap_test(binaries['candidate'], args.udid, bool(simulator))
    root = next((n for n in walk(nodes) if n.get('frame')), {})
    width, height = root.get('frame', {}).get('width', 400), root.get('frame', {}).get('height', 800)
    commands, last_point = commands_for(bool(simulator), args.full, width, height)
    names = ['cold describe-ui'] + list(commands)
    blocks = {label: {name: [] for name in names} for label in binaries}
    output_bytes = {}
    failures = []
    started = datetime.datetime.now(datetime.timezone.utc)
    RESULTS.mkdir(parents=True, exist_ok=True)
    stamp = started.strftime('%Y%m%dT%H%M%SZ')
    timing_file = RESULTS / f'{stamp}-phases.jsonl'
    load = os.getloadavg()[0]
    print(f'{"simulator" if simulator else "device"} {target.get("name")} ({args.udid}), '
          f'{args.pairs} pairs x {args.repeats} warm repeats, load {load:.1f}', flush=True)
    if load > os.cpu_count() / 2:
        print('warning: the Mac is busy; results may be noisy', flush=True)

    # Untimed warm-up per build, which also reconnects an idle device tunnel.
    for binary in binaries.values():
        stop_brokers(args.udid)
        try:
            execute([binary, 'describe-ui', '--udid', args.udid])
        except CommandFailed as error:
            sys.exit(f'Warm-up failed: {error}')

    def run_block(label, binary):
        samples = {name: [] for name in names}
        stop_brokers(args.udid)
        seconds, _ = execute([binary, 'describe-ui', '--udid', args.udid])
        samples['cold describe-ui'].append(seconds)
        for _ in range(args.repeats):
            for name, command in commands.items():
                env = None
                if args.phases and label == 'candidate' and '--agent' in command:
                    env = dict(os.environ, AXE_TIMING=str(timing_file))
                seconds, out = execute([binary, *command, '--udid', args.udid], env=env)
                samples[name].append(seconds)
                if '--agent' in command:
                    output_bytes[label] = len(out.encode())
        landed = tap_location(tree(binary, args.udid))
        if landed != last_point:
            raise CommandFailed(f'the last tap landed at {landed}, expected {last_point}')
        return samples

    def run_pairs(count, offset):
        for pair in range(offset, offset + count):
            order = list(binaries) if pair % 2 == 0 else list(reversed(binaries))
            for label in order:
                samples = {name: [] for name in names}
                for attempt in range(2):
                    try:
                        samples = run_block(label, binaries[label])
                        break
                    except (CommandFailed, ValueError, subprocess.TimeoutExpired) as error:
                        if attempt == 1:
                            failures.append(f'pair {pair + 1} {label}: {error}')
                for name in names:
                    blocks[label][name].append(samples[name])
            print(f'  pair {pair + 1} of {offset + count} done', flush=True)
        stop_brokers(args.udid)

    def evaluate(tolerance):
        rows = {}
        for name in names:
            base = [s for block in blocks['baseline'][name] for s in block]
            cand = [s for block in blocks['candidate'][name] for s in block]
            if not base or not cand:
                continue
            warm_name = 'describe-ui' if name == 'cold describe-ui' else name
            spread = []
            for label in binaries:
                for block in blocks[label][warm_name]:
                    if block:
                        centre = statistics.median(block)
                        spread += [abs(sample - centre) for sample in block]
            resolution = max(2 * statistics.median(spread) if spread else 0, 0.03 * statistics.median(base))
            diff, text = verdict(blocks['baseline'][name], blocks['candidate'][name], resolution, tolerance)
            rows[name] = dict(baseline=statistics.median(base), candidate=statistics.median(cand), diff=diff,
                              resolution=resolution, verdict=text, baselineBlocks=blocks['baseline'][name],
                              candidateBlocks=blocks['candidate'][name])
        return rows

    # Several commands are judged at once, so a chance "slower" is common. Confirm any flagged
    # result with as many pairs again; it then stands only if all but one combined pair agree.
    run_pairs(args.pairs, 0)
    rows = evaluate(tolerance=0)
    flagged = [name for name, row in rows.items() if row['verdict'].startswith('SLOWER')]
    confirmed = False
    if flagged and not failures:
        print(f'confirming {", ".join(flagged)} with {args.pairs} more pairs', flush=True)
        run_pairs(args.pairs, args.pairs)
        rows = evaluate(tolerance=1)
        confirmed = True
    regressions = [name for name, row in rows.items() if row['verdict'].startswith('SLOWER')]
    print(f'\n{"command":<22}{"baseline":>10}{"candidate":>11}{"diff":>9}{"resolution":>12}  verdict')
    for name in names:
        if name not in rows:
            print(f'{name:<22}  no samples')
            continue
        row = rows[name]
        print(f'{name:<22}{row["baseline"]:>9.3f}s{row["candidate"]:>10.3f}s'
              f'{(row["diff"] or 0) * 1000:>+7.0f}ms{row["resolution"] * 1000:>10.0f}ms  {row["verdict"]}')
    if output_bytes:
        print(f'agent describe-ui output: baseline {output_bytes.get("baseline")} bytes, '
              f'candidate {output_bytes.get("candidate")} bytes')
    if args.phases and timing_file.exists():
        print(f'candidate phase spans: {timing_file}')
    for failure in failures:
        print(f'FAILED {failure}')

    report = dict(started=started.isoformat(), target=dict(udid=args.udid, simulator=bool(simulator), **target),
                  load=load, git=git_state(), pairs=args.pairs, confirmed=confirmed, repeats=args.repeats, failures=failures,
                  binaries={label: dict(path=path, sha256=sha256(path),
                                        version=subprocess.run([path, '--version'], capture_output=True,
                                                               text=True).stdout.strip())
                            for label, path in binaries.items()},
                  outputBytes=output_bytes, commands=rows)
    report_path = RESULTS / f'{stamp}.json'
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(f'\nReport: {report_path}')
    if failures:
        sys.exit(2)
    if regressions:
        sys.exit(f'Slower than baseline: {", ".join(regressions)}')
    if args.accept:
        destination = RESULTS / 'baselines' / args.accept
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(Path(binaries['candidate']).parent, destination / 'payload', symlinks=True)
        print(f'Accepted the candidate as baseline {args.accept}: {destination / "payload" / "axe"}')
    print('No regression.')


if __name__ == '__main__':
    main()
