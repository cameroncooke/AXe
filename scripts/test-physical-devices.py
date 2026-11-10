#!/usr/bin/env python3
"""Physical-device end-to-end checks for AXe against the installed AXe Playground.

Run through scripts/run-e2e-devices.sh (make e2e-devices), which builds AXe and the Playground,
installs the Playground and compiles the marker checker. Every check reads its result back from the
device: Tap Test's recorded location, the text field's value, the Capture Markers phase, or decoded
video frames. A check fails on any mismatch; nothing is retried except tree reads and app launches.
"""
import argparse
import json
import math
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


def stop(process):
    """Sends SIGINT and waits up to 40 seconds; kills the process and returns None when it does not stop.
    A capture left running would keep the device's only display stream from the next check."""
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
    try:
        return process.wait(timeout=40)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        return None


def stream(runner, udid, command, path, taps, total, label):
    """Runs a capture command, taps the next marker at each offset, then stops it with SIGINT."""
    output = path if command[0] == 'stream-video' else runner.output / f'{label}.stdout'
    with open(runner.output / f'{label}.stderr', 'w') as log, open(output, 'wb') as out:
        runner.log_start([runner.axe, *command, '--udid', udid])
        process = subprocess.Popen([runner.axe, *command, '--udid', udid], stdout=out, stderr=log,
            stdin=subprocess.DEVNULL)
        stopping = None
        try:
            started = time.monotonic()
            for offset in taps:
                time.sleep(max(0, started + offset - time.monotonic()))
                runner.axe_ok(udid, 'tap', '--id', 'media-pattern-next')
            time.sleep(max(0, started + total - time.monotonic()))
            stopping = time.monotonic()
        finally:
            rc = stop(process)
    require(rc is not None, f'{label}: did not stop within 40 seconds of SIGINT')
    require(rc == 0, f'{label}: exited {rc}: {(runner.output / f"{label}.stderr").read_text().strip()[-200:]}')
    return round(time.monotonic() - stopping, 2)


ROTATION = 'rotation with taps'
CONCURRENT = 'concurrent capture and input'


class Device:
    def __init__(self, runner, udid, name, skip_rotation, only=()):
        self.runner, self.udid, self.name, self.skip_rotation = runner, udid, name, skip_rotation
        self.only = set(only)
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
        for check, function in self.checks().items():
            if (not self.only or check in self.only) and not (check == ROTATION and self.skip_rotation):
                self.record(check, function)
        return self.results

    def checks(self):
        """Every check after the doctor, by the name it reports under, in run order."""
        return {'coordinate taps': self.taps, 'typing and keys': self.typing,
                'draw a closed triangle': self.drawing, 'PencilKit ink and tool picker': self.sketch,
                'long press and other touch gestures': self.touch_gestures,   # no comma: AXE_E2E_CHECKS splits on it
                'scroll distance and scroll until': self.scrolling,
                'pinch in and out': self.pinch,
                'element tap and point lookup': self.markers, 'screenshot': self.screenshot,
                'raw stream': self.raw_stream, 'MP4 recording': self.recording,
                'native H.264 over 20 seconds': self.native, ROTATION: self.rotation}

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

    def wait_for(self, description, matches, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            tree = self.runner.tree(self.udid)
            if matches(tree):
                return tree
            require(time.monotonic() < deadline, f'timed out waiting for {description}')
            time.sleep(0.3)

    def drawing(self):
        tree = self.runner.launch(self.udid, 'drawing', 'drawing.canvas')
        frame = element(tree, 'drawing.canvas')['frame']
        corners = [(round(frame['x'] + frame['width'] * x), round(frame['y'] + frame['height'] * y))
                   for x, y in [(0.5, 0.2), (0.8, 0.8), (0.2, 0.8)]]
        self.runner.axe_ok(self.udid, 'draw', *[f'{x},{y}' for x, y in corners], '--close')
        value = lambda tree, name: str(element(tree, name).get('AXValue'))
        tree = self.wait_for('one completed stroke', lambda tree: value(tree, 'drawing.strokeCount') == '1'
                             and value(tree, 'drawing.active') == 'false')
        start = tuple(float(v) for v in value(tree, 'drawing.last.start').split(','))
        end = tuple(float(v) for v in value(tree, 'drawing.last.end').split(','))
        bounds = [float(v) for v in value(tree, 'drawing.last.bounds').split(',')]
        expected = [min(x for x, _ in corners), min(y for _, y in corners), max(x for x, _ in corners), max(y for _, y in corners)]
        near = lambda a, b: all(abs(p - q) <= 2 for p, q in zip(a, b))
        require(near(start, corners[0]) and near(end, corners[0]), f'stroke went {start} to {end}, expected {corners[0]} both ways')
        require(near(bounds, expected), f'stroke bounds {bounds}, expected {expected}')
        require(value(tree, 'drawing.last.maxTouches') == '1' and value(tree, 'drawing.last.cancelled') == 'false',
                f'stroke had {value(tree, "drawing.last.maxTouches")} contacts, cancelled {value(tree, "drawing.last.cancelled")}')
        return f'triangle {corners}: bounds {bounds}, duration {value(tree, "drawing.last.duration")} s'

    def sketch(self):
        """Paints a picture on a PencilKit canvas: sky and grass in marker washes, a sun with rays, a house,
        a tree and two birds, with three tools, three line weights and nine colours."""
        # A device lists real elements only: the status labels and the picker's buttons, not the canvas view.
        tree = self.runner.launch(self.udid, 'sketch', 'sketch.strokeCount')
        value = lambda tree, name: str((element(tree, name) or {}).get('AXValue'))
        centre = lambda frame: (round(frame['x'] + frame['width'] / 2), round(frame['y'] + frame['height'] / 2))
        buttons = lambda tree, label: [node for node in walk(tree) if node.get('type') == 'Button'
                                       and node.get('AXLabel') == label and node.get('frame')]
        tools = lambda tree: {name: buttons(tree, name)[0]['frame'] for name in ('Pen', 'Monoline', 'Marker') if buttons(tree, name)}
        tap = lambda frame: self.runner.axe_ok(self.udid, 'tap', '-x', str(centre(frame)[0]), '-y', str(centre(frame)[1]))
        if len(tools(tree)) < 3:
            # A narrow screen shows the picker as one round button, the selected tool, until it is tapped.
            require(tools(tree), 'the tool picker is missing from the tree')
            tap(next(iter(tools(tree).values())))
            tree = self.wait_for('the tool picker to expand', lambda tree: len(tools(tree)) == 3)
        left, top, width, height = (float(v) for v in value(tree, 'sketch.drawable').split(','))
        height = min(height, min(frame['y'] for frame in tools(tree).values()) - 16 - top)
        require(width > 100 and height > 100, f'no room to draw: {width}x{height}')
        P = lambda u, v: (left + width * u, top + height * v)
        state = dict(strokes=0)

        def draw(points, seconds=None):
            seconds = seconds or max(0.3, min(10, 0.022 * len(points)))
            self.runner.axe_ok(self.udid, 'draw', *[f'{x:.1f},{y:.1f}' for x, y in points], '--duration', f'{seconds:.2f}')
            state['strokes'] += 1

        def use(tool, weight):
            """Select the tool, open its options with a second tap, pick the weight and close the options."""
            tree = self.runner.tree(self.udid)
            if not value(tree, 'sketch.tool').startswith(tool.lower() + ' '):
                tap(tools(tree)[tool])
                tree = self.wait_for(f'{tool} to be selected', lambda tree: value(tree, 'sketch.tool').startswith(tool.lower() + ' '))
            tap(tools(tree)[tool])
            tree = self.wait_for(f'{tool} options', lambda tree: buttons(tree, 'Weight'))
            choice = next((node for node in buttons(tree, 'Weight') if node.get('AXValue') == weight), None)
            require(choice, f'{tool} has no {weight} weight')
            tap(choice['frame'])
            tap(element(tree, 'sketch.strokeCount')['frame'])      # outside the options: closes them
            self.wait_for(f'{tool} options to close', lambda tree: not buttons(tree, 'Weight'))

        colour = lambda name: self.runner.axe_ok(self.udid, 'tap', '--id', 'sketch.colour.' + name)

        def disc(u, v, radius, spacing=4.2):
            cx, cy = P(u, v); turns = max(1, radius / spacing); count = int(28 * turns)
            return [(cx + radius * (i / count) * math.cos(i / count * turns * 2 * math.pi),
                     cy + radius * (i / count) * math.sin(i / count * turns * 2 * math.pi)) for i in range(1, count + 1)]

        def fill(u0, u1, upper, lower, spacing=4.2):
            columns = max(2, int((u1 - u0) * width / spacing)); points = []
            for column in range(columns + 1):
                u = u0 + (u1 - u0) * column / columns
                ends = [P(u, upper(u)), P(u, lower(u))]
                points += ends if column % 2 == 0 else ends[::-1]
            return points

        use('Marker', 'Very Heavy')
        band = 52 / height; row = band / 2
        colour('sky')
        while row + band / 2 <= 0.62:
            draw([P(0.01, row), P(0.99, row)], 0.4); row += band
        horizon = row - band / 2
        colour('grass')
        while row - band / 2 < 0.97:
            draw([P(0.01, min(row, 1 - band / 2)), P(0.99, min(row, 1 - band / 2))], 0.4); row += band
        use('Monoline', 'Very Heavy')
        sun, radius = (0.80, 0.16), 0.07 * width
        colour('sun'); draw(disc(*sun, radius))
        colour('orange')
        for ray in range(6):
            angle = ray / 6 * 2 * math.pi + 0.3; cx, cy = P(*sun)
            draw([(cx + radius * k * math.cos(angle), cy + radius * k * math.sin(angle)) for k in (1.5, 2.3)], 0.3)
        colour('red'); draw(fill(0.14, 0.42, lambda u: horizon - 0.10, lambda u: horizon + 0.14))
        colour('wood'); draw(fill(0.10, 0.46, lambda u: horizon - 0.22 + abs(u - 0.28) / 0.18 * 0.12, lambda u: horizon - 0.10))
        draw(fill(0.70, 0.74, lambda u: horizon - 0.12, lambda u: horizon + 0.12))
        colour('white'); draw(fill(0.25, 0.31, lambda u: horizon + 0.02, lambda u: horizon + 0.14))
        colour('leaf'); draw(disc(0.72, horizon - 0.20, 0.10 * width))
        use('Pen', 'Medium')
        colour('black')
        for u, v in ((0.30, 0.12), (0.47, 0.22)):
            draw([P(u - 0.04, v), P(u - 0.02, v - 0.015), P(u, v), P(u + 0.02, v - 0.015), P(u + 0.04, v)], 0.3)

        tree = self.wait_for(f"{state['strokes']} ink strokes", lambda tree: value(tree, 'sketch.strokeCount') == str(state['strokes']), timeout=20)
        expected = ('marker #6EC6FF, marker #34C759, monoline #FFD60A, monoline #FF9500, monoline #D62828, '
                    'monoline #8B5A2B, monoline #FFFFFF, monoline #1E7D32, pen #000000')
        require(value(tree, 'sketch.inks') == expected, f"inks used: {value(tree, 'sketch.inks')}")
        picture = self.folder / 'sketch-picture.png'
        self.runner.axe_ok(self.udid, 'screenshot', '--output', str(picture))
        return f"{state['strokes']} strokes, 3 tools, 9 colours; picture {picture}"

    def stroke(self, count):
        """The Drawing screen's last stroke once it has recorded `count` completed strokes."""
        value = lambda tree, name: str(element(tree, name).get('AXValue'))
        tree = self.wait_for(f'{count} completed strokes', lambda tree: value(tree, 'drawing.strokeCount') == str(count)
                             and value(tree, 'drawing.active') == 'false')
        return dict(duration=float(value(tree, 'drawing.last.duration')), length=float(value(tree, 'drawing.last.length')),
                    touches=int(value(tree, 'drawing.last.maxTouches')))

    def touch_gestures(self):
        """tap --hold, --count 2 and --touches 2 on an element, and drag --hold, read back as recorded strokes."""
        tree = self.runner.launch(self.udid, 'drawing', 'drawing.canvas')
        frame = element(tree, 'drawing.canvas')['frame']
        x, top = round(frame['x'] + frame['width'] / 2), round(frame['y'] + frame['height'] * 0.3)
        self.runner.axe_ok(self.udid, 'tap', '--id', 'drawing.canvas', '--hold', '1')
        held = self.stroke(1)
        require(held['touches'] == 1 and 0.8 <= held['duration'] <= 1.6, f'long press recorded {held}')
        self.runner.axe_ok(self.udid, 'tap', '--id', 'drawing.canvas', '--count', '2')
        double = self.stroke(3)
        require(double['duration'] < 0.5, f'double tap recorded {double}')
        self.runner.axe_ok(self.udid, 'tap', '--id', 'drawing.canvas', '--touches', '2')
        two = self.stroke(4)
        require(two['touches'] == 2, f'two-finger tap recorded {two}')
        line = ['--start-x', str(x), '--start-y', str(top), '--end-x', str(x), '--end-y', str(top + 200), '--duration', '0.5']
        self.runner.axe_ok(self.udid, 'drag', *line)
        plain = self.stroke(5)
        self.runner.axe_ok(self.udid, 'drag', *line, '--hold', '0.7')
        rested = self.stroke(6)
        require(abs(rested['length'] - 200) <= 6 and 0.45 <= rested['duration'] - plain['duration'] <= 1.1,
                f'drag {plain}, with --hold 0.7 {rested}')
        return (f"hold {held['duration']} s, double tap, two fingers, "
                f"drag {plain['duration']} s and {rested['duration']} s with --hold 0.7")

    def scrolling(self):
        """A scroll preset's --distance, and --until-id on the long list."""
        tree = self.runner.launch(self.udid, 'drawing', 'drawing.canvas')
        _, height = application_size(tree)
        self.runner.axe_ok(self.udid, 'gesture', 'scroll-down', '--distance', '0.4')
        length = self.stroke(1)['length']
        require(abs(length - height * 0.4) <= 12, f'scroll of 0.4 moved {length} on a {height}-point screen')
        tree = self.runner.launch(self.udid, 'long-scroll-test', 'long-scroll-test-state')
        rows = [int(str(node.get('AXUniqueId')).rsplit('-', 1)[1]) for node in walk(tree)
                if str(node.get('AXUniqueId') or '').startswith('long-scroll-test-row-')]
        require(rows, 'the long list shows no rows')
        target = f'long-scroll-test-row-{max(rows) + 12}'
        found = self.runner.axe_ok(self.udid, 'gesture', 'scroll-up', '--distance', '0.4', '--until-id', target,
                                   '--max-swipes', '20')
        tree = self.runner.tree(self.udid)
        require(element(tree, target) is not None, f'{target} is not in the tree after scrolling')
        again = self.runner.axe_ok(self.udid, 'gesture', 'scroll-up', '--until-id', target)
        require('after 0 scrolls' in ' '.join(again.get('messages', [])), f'a second run scrolled: {again}')
        _, error = self.runner.axe_json(self.udid, 'gesture', 'scroll-down', '--until-id', 'no-such-element',
                                        '--max-swipes', '2')
        require(error == 'elementNotFound', f'a missing element gave {error}')
        return f"0.4 of the screen moved {length} points; {' '.join(found.get('messages', []))[-60:]}"

    def pinch(self):
        self.runner.launch(self.udid, 'zoom', 'zoom.surface')
        value = lambda tree, name: str(element(tree, name).get('AXValue'))
        self.runner.axe_ok(self.udid, 'gesture', 'pinch', '--scale', '2')
        tree = self.wait_for('one zoom in', lambda tree: value(tree, 'zoom.events') == '1' and value(tree, 'zoom.last') == 'in')
        zoomed = float(value(tree, 'zoom.scale'))
        require(zoomed > 1.3, f'pinch out to scale 2 zoomed only to {zoomed}')
        self.runner.axe_ok(self.udid, 'gesture', 'pinch', '--scale', '0.5')
        tree = self.wait_for('one zoom out', lambda tree: value(tree, 'zoom.events') == '2' and value(tree, 'zoom.last') == 'out')
        back = float(value(tree, 'zoom.scale'))
        require(back < zoomed - 0.3, f'pinch in to scale 0.5 went from {zoomed} to {back}')
        return f'scale 1.00 -> {zoomed} -> {back}'

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
    streams = {}
    try:
        starts = {d.udid: phase(runner.launch(d.udid, 'media-pattern', 'media-pattern-next')) for d in devices}
        processes = {d.udid: subprocess.Popen([runner.axe, 'screenshot', '--udid', d.udid, '--output',
            str(d.folder / 'parallel.png')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for d in devices}
        try:
            for udid, process in processes.items():
                require(process.wait(timeout=60) == 0, f'{udid}: parallel screenshot failed')
        finally:
            for process in processes.values():
                if process.poll() is None:
                    process.kill()
                    process.wait()
        for udid in processes:
            summary = runner.markers(runner.output / udid / 'parallel.png')
            require(summary['frames'] == 1 and summary['noPhase'] == 0 and summary['rotations'] == [0]
                    and summary['phases'][0][0] == starts[udid], f'{udid}: parallel screenshot failed the marker check')
        for d in devices:
            out = open(d.folder / 'parallel.h264', 'wb')
            log = open(d.folder / 'parallel.stderr', 'w')
            runner.log_start([runner.axe, 'stream-video', '--format', 'h264', '--udid', d.udid])
            streams[d.udid] = (subprocess.Popen([runner.axe, 'stream-video', '--format', 'h264', '--udid', d.udid],
                stdout=out, stderr=log, stdin=subprocess.DEVNULL), out, log)
        time.sleep(5)
        for d in devices:
            runner.axe_ok(d.udid, 'tap', '--id', 'media-pattern-next')
        time.sleep(5)
        for process, _, _ in streams.values():
            process.send_signal(signal.SIGINT)
        codes = {udid: stop(process) for udid, (process, _, _) in streams.items()}
        for udid, rc in codes.items():
            require(rc == 0, f'{udid}: parallel native stream exited {rc}')
            check_video(runner.markers(runner.output / udid / 'parallel.h264'), starts[udid], 30,
                f'{udid} parallel native H.264', announced_rotation(runner.output / udid / 'parallel.stderr'))
        detail = f'{len(devices)} devices: parallel screenshots and native streams passed'
        results.append(dict(device='all', check='concurrent capture and input', ok=True, detail=detail))
        print(f'  PASS concurrent capture and input: {detail}', flush=True)
    except (CheckFailed, subprocess.TimeoutExpired) as error:
        results.append(dict(device='all', check='concurrent capture and input', ok=False, detail=str(error)))
        print(f'  FAIL concurrent capture and input: {error}', flush=True)
    finally:
        for process, out, log in streams.values():
            stop(process)
            out.close()
            log.close()
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--axe', type=Path, required=True, help='Built AXe CLI with its runtime frameworks.')
    parser.add_argument('--checker', type=Path, required=True, help='Compiled scripts/fixtures/MediaPatternCheck.swift.')
    parser.add_argument('--output', type=Path, required=True, help='New result directory.')
    parser.add_argument('--device', action='append', default=[], help='Hardware UDID to test (repeatable). Default: all.')
    parser.add_argument('--skip-rotation', action='store_true', help='Leave the device orientation unchanged.')
    parser.add_argument('--check', action='append', default=[], metavar='NAME',
                        help='Run only this check, by the name it reports under (repeatable). The doctor always runs.')
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

    devices = [Device(runner, d['udid'], d.get('name') or d['udid'], args.skip_rotation, args.check) for d in listed]
    unknown = set(args.check) - set(devices[0].checks()) - {CONCURRENT}
    if unknown:
        sys.exit(f'No such check: {", ".join(sorted(unknown))}. Checks: {", ".join([*devices[0].checks(), CONCURRENT])}')
    results = [result for device in devices for result in device.run()]
    ready = [d for d in devices if d.results and d.results[0]['ok']]
    if len(ready) >= 2 and (not args.check or CONCURRENT in args.check):
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
