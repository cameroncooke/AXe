#!/usr/bin/env python3
"""Physical-device end-to-end checks for AXe against the installed AXe Playground.

Run through scripts/run-e2e-devices.sh (make e2e-devices), which builds AXe and the Playground,
installs the Playground and compiles the marker checker. Every check reads its result back from the
device: Tap Test's recorded location, the text field's value, the Capture Markers phase, or decoded
video frames. A check fails on any mismatch; nothing is retried except tree reads and app launches.
"""
import argparse
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

BUNDLE = 'com.cameroncooke.AxePlayground'


class CheckFailed(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CheckFailed(message)


class Runner:
    def __init__(self, axe, checker, output):
        self.axe, self.checker, self.output = str(axe), str(checker), output
        self.log = open(output / 'commands.log', 'a')
        self.tree_retries = 0

    def log_start(self, command):
        """Logs a long-running command started with Popen; its result is checked by the caller."""
        self.log.write(json.dumps(dict(command=command, started=True)) + '\n')
        self.log.flush()

    def run(self, command, timeout=90):
        started = time.monotonic()
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        self.log.write(json.dumps(dict(command=command, rc=result.returncode, seconds=round(time.monotonic() - started, 2),
            stdout=result.stdout[-2000:], stderr=result.stderr[-2000:])) + '\n')
        self.log.flush()
        return result

    def axe_json(self, udid, *args, timeout=90):
        """Runs an AXe command with JSON output; returns (data, error code or None)."""
        result = self.run([self.axe, '--output', 'json', *args, '--udid', udid], timeout=timeout)
        try:
            envelope = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise CheckFailed(f'axe {" ".join(args)} returned no JSON (rc {result.returncode}): {result.stderr.strip()[:200]}')
        error = envelope.get('error') if envelope.get('didError') else None
        return envelope.get('data'), (error or {}).get('code') if error else None

    def axe_ok(self, udid, *args, timeout=90):
        data, error = self.axe_json(udid, *args, timeout=timeout)
        require(error is None, f'axe {" ".join(args)} failed with {error}')
        return data

    def tree(self, udid, attempts=3):
        last = None
        for attempt in range(attempts):
            result = self.run([self.axe, 'describe-ui', '--udid', udid])
            if result.returncode == 0:
                return json.loads(result.stdout)
            last = result.stderr.strip()
            self.tree_retries += 1
            time.sleep(1)
        raise CheckFailed(f'describe-ui failed {attempts} times: {last[:200]}')

    def launch(self, udid, screen, marker):
        for attempt in range(2):
            result = self.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing',
                '--device', udid, BUNDLE, '--launch-arg', f'screen={screen}'], timeout=60)
            if result.returncode == 0:
                break
        else:
            raise CheckFailed(f'Could not launch Playground screen {screen}: {result.stderr.strip()[-200:]}')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            # Reads fail while the app launches; these are not counted as retries.
            result = self.run([self.axe, 'describe-ui', '--udid', udid])
            if result.returncode == 0:
                tree = json.loads(result.stdout)
                if element(tree, marker):
                    return tree
            time.sleep(0.5)
        raise CheckFailed(f'Playground screen {screen} did not show {marker}')

    def markers(self, path):
        result = self.run([self.checker, str(path)], timeout=300)
        require(result.returncode == 0, f'Marker check failed on {path.name}: {result.stderr.strip()[:200]}')
        return json.loads(result.stdout)


def walk(node):
    if isinstance(node, list):
        for item in node:
            yield from walk(item)
    elif isinstance(node, dict):
        yield node
        yield from walk(node.get('children') or [])


def element(tree, identifier):
    return next((node for node in walk(tree) if node.get('AXUniqueId') == identifier), None)


def application_size(tree):
    app = next((node for node in walk(tree) if node.get('type') == 'Application'), None)
    require(app and app.get('frame'), 'The tree has no application frame')
    return app['frame']['width'], app['frame']['height']


def tap_location(tree):
    node = next((n for n in walk(tree) if str(n.get('AXLabel', '')).startswith('Tap Location')), None)
    if not node:
        return None
    match = re.fullmatch(r'x:([\d,]+),y:([\d,]+)', str(node.get('AXValue')))
    return (int(match.group(1).replace(',', '')), int(match.group(2).replace(',', ''))) if match else None


def phase(tree):
    node = element(tree, 'media-pattern-phase')
    require(node and str(node.get('AXValue')).isdigit(), 'Capture Markers did not expose its phase')
    return int(node['AXValue'])


def check_video(summary, start, minimum_frames, label, rotation=0):
    """Frames decode, every frame shows the pattern after turning it `rotation` degrees clockwise,
    and the phase advances from start."""
    frames = summary['frames']
    require(summary['rotations'] == [rotation], f'{label}: frames needed rotations {summary["rotations"]}, expected [{rotation}]')
    require(frames >= minimum_frames, f'{label}: {frames} frames, expected at least {minimum_frames}')
    require(summary['noPhase'] == 0 and summary['edgeFailures'] == 0,
        f'{label}: {summary["noPhase"]} frames without the pattern, {summary["edgeFailures"]} with wrong edges')
    # Notification banners can cover a square for a few frames.
    require(summary['squareFailures'] <= max(2, frames // 20), f'{label}: {summary["squareFailures"]} frames failed the squares')
    require(summary['decodeFailures'] <= max(2, frames // 50), f'{label}: {summary["decodeFailures"]} pictures failed to decode')
    order = [entry[0] for entry in summary['phases']]
    expected = [(start + offset) % 4 for offset in range(len(order))]
    require(order == expected and len(order) >= 2, f'{label}: phases {order}, expected consecutive phases from {start}')
    return order


def announced_rotation(stderr_path):
    """The clockwise rotation AXe reports for native H.264 frames; 0 when they are upright."""
    match = re.search(r'Rotate them (\d+)° clockwise', stderr_path.read_text())
    return int(match.group(1)) if match else 0


def stream(runner, udid, command, path, taps, total, label):
    """Runs a capture command, taps the next marker at each offset, then stops it with SIGINT."""
    log = open(runner.output / f'{label}.stderr', 'w')
    with open(path, 'wb') if command[0] == 'stream-video' else open(runner.output / f'{label}.stdout', 'wb') as out:
        runner.log_start([runner.axe, *command, '--udid', udid])
        process = subprocess.Popen([runner.axe, *command, '--udid', udid], stdout=out, stderr=log,
            stdin=subprocess.DEVNULL)
        started = time.monotonic()
        for offset in taps:
            time.sleep(max(0, started + offset - time.monotonic()))
            runner.axe_ok(udid, 'tap', '--id', 'media-pattern-next')
        time.sleep(max(0, started + total - time.monotonic()))
        stopping = time.monotonic()
        process.send_signal(signal.SIGINT)
        try:
            rc = process.wait(timeout=40)
        except subprocess.TimeoutExpired:
            process.kill()
            raise CheckFailed(f'{label}: did not stop within 40 seconds of SIGINT')
    require(rc == 0, f'{label}: exited {rc}: {(runner.output / f"{label}.stderr").read_text().strip()[-200:]}')
    return round(time.monotonic() - stopping, 2)


class Device:
    def __init__(self, runner, udid, name, skip_rotation):
        self.runner, self.udid, self.name, self.skip_rotation = runner, udid, name, skip_rotation
        self.folder = runner.output / udid
        self.folder.mkdir()
        self.results = []

    def record(self, check, function):
        started = time.monotonic()
        try:
            detail = function()
            self.results.append(dict(device=self.udid, check=check, ok=True, detail=detail,
                seconds=round(time.monotonic() - started, 1)))
            print(f'  PASS {check}: {detail}', flush=True)
        except (CheckFailed, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            self.results.append(dict(device=self.udid, check=check, ok=False, detail=str(error),
                seconds=round(time.monotonic() - started, 1)))
            print(f'  FAIL {check}: {error}', flush=True)

    def run(self):
        print(f'{self.name} ({self.udid})', flush=True)
        self.record('doctor', self.doctor)
        if not self.results[-1]['ok']:
            return self.results
        self.record('coordinate taps', self.taps)
        self.record('typing and keys', self.typing)
        self.record('element tap and point lookup', self.markers)
        self.record('screenshot', self.screenshot)
        self.record('raw stream', self.raw_stream)
        self.record('MP4 recording', self.recording)
        self.record('native H.264 over 20 seconds', self.native)
        if not self.skip_rotation:
            self.record('rotation with taps', self.rotation)
        return self.results

    def doctor(self):
        data = self.runner.axe_ok(self.udid, 'doctor')
        report = data.get('result', data)
        require(report.get('ready') is True, f'not ready: {report}')
        return 'ready'

    def tap_and_read(self, x, y):
        self.runner.axe_ok(self.udid, 'tap', '-x', str(x), '-y', str(y))
        return tap_location(self.runner.tree(self.udid))

    def taps(self):
        tree = self.runner.launch(self.udid, 'tap-test', 'tap-test-screen')
        width, height = application_size(tree)
        points = [(int(width * 0.3), int(height * 0.25)), (int(width * 0.7), int(height * 0.6))]
        for point in points:
            location = self.tap_and_read(*point)
            require(location == point, f'tap at {point} landed at {location}')
        return f'{len(points)} taps exact in a {width:g}x{height:g} point screen'

    def typing(self):
        self.runner.launch(self.udid, 'text-input', 'text-input-field')
        deadline = time.monotonic() + 10
        while not element(self.runner.tree(self.udid), 'typing-active-indicator'):
            require(time.monotonic() < deadline, 'The text field did not take focus')
            time.sleep(0.5)
        self.runner.axe_ok(self.udid, 'type', 'axe e2e')
        value = element(self.runner.tree(self.udid), 'text-input-field').get('AXValue')
        require(value == 'axe e2e', f'typed value is {value!r}')
        self.runner.axe_ok(self.udid, 'key', '42')
        value = element(self.runner.tree(self.udid), 'text-input-field').get('AXValue')
        require(value == 'axe e2', f'value after backspace is {value!r}')
        return 'typed "axe e2e" and deleted one character'

    def markers(self):
        tree = self.runner.launch(self.udid, 'media-pattern', 'media-pattern-next')
        button = element(tree, 'media-pattern-next')
        require(button and button.get('frame'), 'media-pattern-next is missing')
        frame = button['frame']
        centre = (int(frame['x'] + frame['width'] / 2), int(frame['y'] + frame['height'] / 2))
        hit = self.runner.run([self.runner.axe, 'describe-ui', '--point', f'{centre[0]},{centre[1]}', '--udid', self.udid])
        require(hit.returncode == 0 and 'media-pattern-next' in hit.stdout, f'point lookup at {centre} missed the button')
        before = phase(tree)
        self.runner.axe_ok(self.udid, 'tap', '--id', 'media-pattern-next')
        after = phase(self.runner.tree(self.udid))
        require(after == (before + 1) % 4, f'phase {before} became {after}')
        return f'phase {before} -> {after}'

    def screenshot(self):
        path = self.folder / 'screenshot.png'
        self.runner.axe_ok(self.udid, 'screenshot', '--output', str(path))
        summary = self.runner.markers(path)
        require(summary['frames'] == 1 and summary['noPhase'] == 0 and summary['squareFailures'] == 0
            and summary['edgeFailures'] == 0, f'screenshot failed the marker check: {summary}')
        require(summary['rotations'] == [0], f'screenshot was not upright: it needed {summary["rotations"]}° to read')
        current = phase(self.runner.tree(self.udid))
        require(summary['phases'][0][0] == current, f'screenshot phase {summary["phases"]} but app phase {current}')
        return f'{summary["sizes"][0]} upright, phase {current}'

    def raw_stream(self):
        start = phase(self.runner.tree(self.udid))
        path = self.folder / 'stream.raw'
        stop = stream(self.runner, self.udid, ['stream-video', '--format', 'raw', '--fps', '3', '--scale', '0.5'],
            path, [3], 11, f'{self.udid}/raw')
        order = check_video(self.runner.markers(path), start, 8, 'raw stream')
        return f'phases {order}, stopped in {stop}s'

    def recording(self):
        start = phase(self.runner.tree(self.udid))
        path = self.folder / 'recording.mp4'
        stop = stream(self.runner, self.udid, ['record-video', '--fps', '3', '--scale', '0.5', '--output', str(path)],
            path, [3], 11, f'{self.udid}/record')
        order = check_video(self.runner.markers(path), start, 8, 'recording')
        return f'phases {order}, stopped in {stop}s'

    def native(self):
        # The second change comes after the negotiated 20-second RTCP timeout.
        start = phase(self.runner.tree(self.udid))
        path = self.folder / 'native.h264'
        stop = stream(self.runner, self.udid, ['stream-video', '--format', 'h264'], path, [4, 28], 32,
            f'{self.udid}/native')
        summary = self.runner.markers(path)
        rotation = announced_rotation(self.runner.output / self.udid / 'native.stderr')
        order = check_video(summary, start, 30, 'native H.264', rotation)
        require(len(order) >= 3, f'native H.264 phases {order}: the stream stopped before the second change')
        return f'{summary["frames"]} frames {summary["sizes"]} turned {rotation}°, phases {order}, stopped in {stop}s'

    def rotation(self):
        """Four right turns. A confirmed turn must swap the app frame and place the next tap exactly. An
        unconfirmed turn (an iPad display that lags, or an iPhone that will not turn upside down) is followed
        by a tap that either refuses with no effect or lands exactly; the two outcomes are counted apart."""
        size = application_size(self.runner.launch(self.udid, 'tap-test', 'tap-test-screen'))
        confirmed = lagged = refused = landed = 0
        previous_confirmed = True
        for turn in range(4):
            _, error = self.runner.axe_json(self.udid, 'rotate', 'right')
            require(error in (None, 'rotationUnconfirmed'), f'turn {turn + 1} failed with {error}')
            outcome, new_size = self.check_tap_after_rotation(turn + 1, refused_allowed=error is not None)
            if error is None:
                confirmed += 1
                # Consecutive confirmed quarter turns always swap the frame. After an unconfirmed turn the
                # interface may already be in the other landscape, so only the exact tap is checked.
                if previous_confirmed:
                    require(new_size == (size[1], size[0]),
                            f'turn {turn + 1} was confirmed but the app frame went from {size} to {new_size}')
            else:
                lagged += 1
                refused += outcome == 'refused'
                landed += outcome == 'landed'
            size = new_size
            previous_confirmed = error is None
        # Four turns return the device orientation to the start; settle a lagging display.
        for _ in range(2):
            tree = self.runner.tree(self.udid)
            width, height = application_size(tree)
            point = (int(width * 0.4), int(height * 0.3))
            _, error = self.runner.axe_json(self.udid, 'tap', '-x', str(point[0]), '-y', str(point[1]))
            if error is None:
                break
            self.runner.axe_json(self.udid, 'rotate', 'left')
            self.runner.axe_json(self.udid, 'rotate', 'right')
        require(confirmed >= 2, f'only {confirmed} of 4 turns confirmed')
        return (f'{confirmed} turns confirmed with exact taps; {lagged} unconfirmed, after which '
                f'{refused} taps refused with no effect and {landed} landed exactly')

    def check_tap_after_rotation(self, turn, refused_allowed):
        tree = self.runner.tree(self.udid)
        before = tap_location(tree)
        width, height = application_size(tree)
        point = (int(width * (0.2 + 0.1 * turn)), int(height * (0.15 + 0.1 * turn)))
        _, error = self.runner.axe_json(self.udid, 'tap', '-x', str(point[0]), '-y', str(point[1]))
        after = tap_location(self.runner.tree(self.udid))
        if error is None:
            require(after == point, f'turn {turn}: tap at {point} landed at {after}')
            return 'landed', (width, height)
        require(refused_allowed and error == 'displayOrientationMismatch', f'turn {turn}: tap failed with {error}')
        require(after == before, f'turn {turn}: a refused tap still changed the location to {after}')
        return 'refused', (width, height)


def concurrent(runner, devices):
    """Parallel screenshots and native streams on every device, on Capture Markers."""
    results = []
    print('All devices at once', flush=True)
    try:
        starts = {d.udid: phase(runner.launch(d.udid, 'media-pattern', 'media-pattern-next')) for d in devices}
        processes = {d.udid: subprocess.Popen([runner.axe, 'screenshot', '--udid', d.udid, '--output',
            str(d.folder / 'parallel.png')], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) for d in devices}
        for udid, process in processes.items():
            require(process.wait(timeout=60) == 0, f'{udid}: parallel screenshot failed')
            summary = runner.markers(runner.output / udid / 'parallel.png')
            require(summary['frames'] == 1 and summary['noPhase'] == 0 and summary['rotations'] == [0]
                    and summary['phases'][0][0] == starts[udid], f'{udid}: parallel screenshot failed the marker check')
        streams = {}
        for d in devices:
            out = open(d.folder / 'parallel.h264', 'wb')
            runner.log_start([runner.axe, 'stream-video', '--format', 'h264', '--udid', d.udid])
            streams[d.udid] = (subprocess.Popen([runner.axe, 'stream-video', '--format', 'h264', '--udid', d.udid],
                stdout=out, stderr=open(d.folder / 'parallel.stderr', 'w'), stdin=subprocess.DEVNULL), out)
        time.sleep(5)
        for d in devices:
            runner.axe_ok(d.udid, 'tap', '--id', 'media-pattern-next')
        time.sleep(5)
        for udid, (process, out) in streams.items():
            process.send_signal(signal.SIGINT)
        for udid, (process, out) in streams.items():
            rc = process.wait(timeout=40)
            out.close()
            require(rc == 0, f'{udid}: parallel native stream exited {rc}')
            check_video(runner.markers(runner.output / udid / 'parallel.h264'), starts[udid], 30,
                f'{udid} parallel native H.264', announced_rotation(runner.output / udid / 'parallel.stderr'))
        detail = f'{len(devices)} devices: parallel screenshots and native streams passed'
        results.append(dict(device='all', check='concurrent capture and input', ok=True, detail=detail))
        print(f'  PASS concurrent capture and input: {detail}', flush=True)
    except (CheckFailed, subprocess.TimeoutExpired) as error:
        results.append(dict(device='all', check='concurrent capture and input', ok=False, detail=str(error)))
        print(f'  FAIL concurrent capture and input: {error}', flush=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--axe', type=Path, required=True, help='Built AXe CLI with its runtime frameworks.')
    parser.add_argument('--checker', type=Path, required=True, help='Compiled scripts/fixtures/MediaPatternCheck.swift.')
    parser.add_argument('--output', type=Path, required=True, help='New result directory.')
    parser.add_argument('--device', action='append', default=[], help='Hardware UDID to test (repeatable). Default: all.')
    parser.add_argument('--skip-rotation', action='store_true', help='Leave the device orientation unchanged.')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    runner = Runner(args.axe, args.checker, args.output)

    data = runner.run([str(args.axe), '--output', 'json', 'list-devices'])
    listed = json.loads(data.stdout)['data']['result']['devices']
    if args.device:
        missing = set(args.device) - {d['udid'] for d in listed}
        if missing:
            sys.exit(f'Not connected: {", ".join(sorted(missing))}')
        listed = [d for d in listed if d['udid'] in args.device]
    if not listed:
        sys.exit('No physical iPhone or iPad is connected. Connect and unlock one, then run make e2e-devices again.')

    devices = [Device(runner, d['udid'], d.get('name') or d['udid'], args.skip_rotation) for d in listed]
    results = [result for device in devices for result in device.run()]
    ready = [d for d in devices if d.results and d.results[0]['ok']]
    if len(ready) >= 2:
        results += concurrent(runner, ready)

    (args.output / 'results.json').write_text(json.dumps(dict(checks=results, treeRetries=runner.tree_retries),
                                                          indent=2) + '\n')
    if runner.tree_retries:
        print(f'{runner.tree_retries} tree reads were retried after a failure')
    failed = [r for r in results if not r['ok']]
    print(f'{len(results) - len(failed)} of {len(results)} checks passed on {len(devices)} device(s). Results: {args.output}')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
