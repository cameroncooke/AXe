"""Plays a picture on the Playground's Sketch screen (a PencilKit canvas) through the axe CLI.

A picture is the list of steps that scripts/demos/car_picture.py writes: tools, colours, fills, lines and
washes in the picture's own 0-to-1 coordinates. The player lays the picture out on the canvas above the
tool picker, picks each tool and line weight in the picker, scrolling its strip until the tool is on
screen, picks each colour from the screen's swatches and turns every fill, line and wash into `axe draw`
strokes. It works on a simulator and on a physical device: it uses only elements both list.

The caller supplies `axe(*arguments)`, which runs one axe command and raises if it fails, and `tree()`,
which returns the parsed `describe-ui` output.

Run it to paint a picture and save a screenshot (to film it, run `axe record-video` alongside):

    scripts/sketch_picture.py AXE UDID sim|device|current scripts/fixtures/sketch-car.json OUTPUT.png
"""
import json
import subprocess
import sys
import time

# The picker's tools in the order it shows them, and the ink name the app reports for each.
TOOLS = ['Pen', 'Monoline', 'Marker', 'Eraser', 'Lasso', 'Ruler', 'Pencil', 'Crayon', 'Fountain Pen', 'Reed', 'Watercolor']
INKS = {'Pen': 'pen', 'Monoline': 'monoline', 'Marker': 'marker', 'Pencil': 'pencil', 'Crayon': 'crayon',
        'Fountain Pen': 'fountainpen', 'Reed': 'reedcalligraphy', 'Watercolor': 'watercolor'}
# The Sketch screen's swatches (SketchView.swift).
COLOURS = dict(red1='4A0808', red2='7A0F0F', red3='B01717', red4='D93025', red5='F0705C', glass1='14212E', glass2='2C4A66',
               glass3='7FA6C9', cream='FFF1BF', amber='FF9F0A', grey1='121314', grey2='3A3F45', grey3='7D858C', grey4='B9C0C6',
               grey5='E3E7EA', road='555B62', shadow='1B1D20', wall='BFCBD6', white='FFFFFF', black='000000')
MAX_BOX_WIDTH = 430      # the picture's width in points on a wide canvas, so every screen paints the same strokes


class PictureFailed(Exception):
    pass


def walk(node):
    if isinstance(node, list):
        for item in node:
            yield from walk(item)
    elif isinstance(node, dict):
        yield node
        yield from walk(node.get('children') or [])


def centre(frame):
    return frame['x'] + frame['width'] / 2, frame['y'] + frame['height'] / 2


class SketchPlayer:
    def __init__(self, axe, tree, log=lambda text: None):
        self.axe, self.tree, self.log = axe, tree, log
        self.strokes = 0
        self.inks = []
        self.tool = self.weight = self.colour = None
        current = self.tree()
        if len(self.tool_frames(current)) < 3:
            # A narrow screen shows the picker as one round button, the selected tool, until it is tapped.
            shown = self.tool_frames(current)
            if not shown:
                raise PictureFailed('the tool picker is missing from the tree')
            self.tap(next(iter(shown.values())))
            current = self.wait('the tool picker to expand', lambda tree: len(self.tool_frames(tree)) >= 3)
        screen = next(node for node in walk(current) if node.get('type') == 'Application')['frame']
        self.screen_width = screen['width']
        left, top, width, height = (float(v) for v in self.value(current, 'sketch.drawable').split(','))
        strip_top = min(frame['y'] for frame in self.tool_frames(current).values())
        height = min(height, strip_top - 16 - top)
        if width < 150 or height < 120:
            raise PictureFailed(f'no room to paint: {width:.0f}x{height:.0f}')
        self.canvas = (left, top, width, height)
        # A tap on this label closes a tool's options. On a device the options hide it from the tree.
        self.outside = self.find(current, 'sketch.strokeCount')['frame']
        self.selected = (self.value(current, 'sketch.tool') or '').split(' ')[0]
        # The swatches do not move, so each is tapped at its place: finding it by identifier reads the
        # whole screen first, which takes two to three seconds on a physical device.
        self.swatches = {str(node['AXUniqueId'])[len('sketch.colour.'):]: node['frame'] for node in walk(current)
                         if str(node.get('AXUniqueId') or '').startswith('sketch.colour.') and node.get('frame')}

    # Reading the screen
    @staticmethod
    def find(tree, identifier):
        return next((node for node in walk(tree) if node.get('AXUniqueId') == identifier), None)

    def value(self, tree, identifier):
        return str((self.find(tree, identifier) or {}).get('AXValue'))

    @staticmethod
    def buttons(tree, label):
        return [node for node in walk(tree) if node.get('type') == 'Button' and node.get('AXLabel') == label and node.get('frame')]

    def tool_frames(self, tree):
        return {name: self.buttons(tree, name)[0]['frame'] for name in TOOLS if self.buttons(tree, name)}

    def wait(self, description, matches, timeout=12):
        deadline = time.monotonic() + timeout
        while True:
            tree = self.tree()
            if matches(tree):
                return tree
            if time.monotonic() > deadline:
                raise PictureFailed(f'timed out waiting for {description}')
            time.sleep(0.3)

    def tap(self, frame):
        x, y = centre(frame)
        self.axe('tap', '-x', f'{x:.0f}', '-y', f'{y:.0f}')

    # The tool picker
    def reveal(self, name):
        """Scrolls the picker's strip until the tool can be tapped, and returns its frame."""
        tree = self.tree()
        frames = self.tool_frames(tree)
        on_screen = sorted((frame for frame in frames.values() if 0 < centre(frame)[0] < self.screen_width), key=lambda f: f['x'])
        y = centre(on_screen[0])[1]
        near, far = centre(on_screen[0])[0] + 10, centre(on_screen[min(3, len(on_screen) - 1)])[0]
        # Later tools are to the right: dragging the strip left brings them in.
        shown = [TOOLS.index(tool) for tool, frame in frames.items() if frame in on_screen[:4]]
        forwards = TOOLS.index(name) > (sum(shown) / len(shown) if shown else 0)
        for start, end in ((far, near), (near, far)) if forwards else ((near, far), (far, near)):
            try:
                # axe repeats the swipe until the tool is on screen, and stops when the strip reaches its end.
                self.axe('swipe', '--start-x', f'{start:.0f}', '--start-y', f'{y:.0f}', '--end-x', f'{end:.0f}', '--end-y', f'{y:.0f}',
                         '--duration', '0.4', '--until-label', name, '--max-swipes', '8')
                return self.tool_frames(self.tree())[name]
            except Exception as error:      # not that way: try the other
                last = error
        raise PictureFailed(f'the picker has no {name} tool: {last}')

    def use(self, name, weight=None):
        """Selects a tool, and with a weight opens its options with a second tap and picks it."""
        if (name, weight) == (self.tool, self.weight):
            return      # already in hand, with its colour
        ink = INKS[name]
        frame = self.reveal(name)
        if self.selected != ink:
            self.tap(frame)
            self.wait(f'{name} to be selected', lambda tree: self.value(tree, 'sketch.tool').startswith(ink + ' '))
            self.selected = ink
        if weight:
            self.tap(frame)      # a tap on the selected tool opens its options
            tree = self.wait(f'{name} options', lambda tree: self.buttons(tree, 'Weight'))
            choice = next((node for node in self.buttons(tree, 'Weight') if node.get('AXValue') == weight), None)
            if not choice:
                raise PictureFailed(f'{name} has no {weight} weight')
            self.tap(choice['frame'])
            self.tap(self.outside)
            self.wait(f'{name} options to close', lambda tree: not self.buttons(tree, 'Weight'))
        self.tool, self.weight = name, weight
        self.colour = None      # the picker gives the canvas its own colour again

    def paint(self, colour):
        if colour == self.colour:
            return
        if colour not in self.swatches:
            raise PictureFailed(f'the Sketch screen has no {colour} swatch')
        try:
            self.tap(self.swatches[colour])
        except Exception:
            # A device can fail to answer in time. Tapping a swatch twice changes nothing, so try once more.
            time.sleep(1)
            self.tap(self.swatches[colour])
        self.colour = colour

    # Strokes
    def draw(self, points, seconds=None):
        left, top, width, height = self.canvas
        arguments = []
        for x, y in points:
            point = f'{min(max(x, left + 1), left + width - 1):.1f},{min(max(y, top + 1), top + height - 1):.1f}'
            if not arguments or arguments[-1] != point:      # draw refuses a point that repeats the one before it
                arguments.append(point)
        if len(arguments) < 2:
            return
        seconds = seconds or max(0.25, min(12, 0.022 * len(arguments)))
        self.axe('draw', *arguments, '--duration', f'{seconds:.2f}')
        self.strokes += 1
        ink = f'{INKS[self.tool]} #{COLOURS[self.colour]}'
        if ink not in self.inks:
            self.inks.append(ink)

    @staticmethod
    def columns(polygon, spacing):
        """One zigzag down and up the columns of a convex polygon, `spacing` points apart."""
        xs = [x for x, _ in polygon]
        low, high = min(xs), max(xs)
        count = max(1, min(480, int((high - low) / spacing)))
        points = []
        for index in range(count + 1):
            x = min(max(low + (high - low) * index / count, low + 0.01), high - 0.01)
            ys = []
            for (ax, ay), (bx, by) in zip(polygon, polygon[1:] + polygon[:1]):
                if ax != bx and min(ax, bx) <= x <= max(ax, bx):
                    ys.append(ay + (x - ax) / (bx - ax) * (by - ay))
            if ys:
                ends = [(x, min(ys)), (x, max(ys))]
                points += ends if index % 2 == 0 else ends[::-1]
        return points

    def play(self, picture):
        left, top, width, height = self.canvas
        across, down = picture['aspect']
        box_width = min(width, MAX_BOX_WIDTH, height * across / down)
        box_height = box_width * down / across
        origin_x, origin_y = left + (width - box_width) / 2, top + (height - box_height) / 2
        place = lambda u, v: (origin_x + box_width * u, origin_y + box_height * v)
        for step in picture['steps']:
            if step['op'] == 'tool':
                self.use(step['name'], step.get('weight'))
                self.log(f"{step['name']} {step.get('weight', '')}".strip())
            elif step['op'] == 'colour':
                self.paint(step['name'])
            elif step['op'] == 'line':
                self.draw([place(u, v) for u, v in step['points']], step.get('seconds'))
            elif step['op'] == 'fill':
                polygon = [place(u, v) for u, v in step['points']]
                if step['spacing'] <= 8:      # a narrow tool: outline first, so the edges are crisp
                    self.draw(polygon + polygon[:1], max(0.3, 0.05 * len(polygon)))
                self.draw(self.columns(polygon, step['spacing']))
            elif step['op'] == 'wash':
                u0, v0, u1, v1 = step['rect']
                (x0, y0), (x1, y1) = place(u0, v0), place(u1, v1)
                rows = max(1, round((y1 - y0) / step['band']))
                for row in range(rows):
                    y = y0 + (y1 - y0) * (row + 0.5) / rows
                    self.draw([(x0, y), (x1, y)] if row % 2 == 0 else [(x1, y), (x0, y)], 0.45)
        return self.strokes

    def check(self):
        """Fails unless the app recorded every stroke and exactly the inks that were used."""
        tree = self.wait(f'{self.strokes} ink strokes', lambda tree: self.value(tree, 'sketch.strokeCount') == str(self.strokes), timeout=20)
        used = self.value(tree, 'sketch.inks')
        if used != ', '.join(self.inks):
            raise PictureFailed(f"inks used: {used}; expected {', '.join(self.inks)}")


def main():
    axe_path, udid, kind, picture_path, output = sys.argv[1:6]
    bundle = 'com.cameroncooke.AxePlayground'
    calls = [0]

    def run(*arguments):
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise RuntimeError(f"{' '.join(arguments[1:6])} failed: {(result.stderr or result.stdout).strip()[-300:]}")
        return result.stdout

    def axe(*arguments):
        calls[0] += 1
        return run(axe_path, *arguments, '--udid', udid)

    def tree():
        for attempt in range(6):
            try:
                return json.loads(axe('describe-ui'))
            except RuntimeError:
                time.sleep(0.5)
        raise PictureFailed('describe-ui kept failing')

    if kind == 'device':
        run('xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing', '--device', udid, bundle,
            '--launch-arg', 'screen=sketch')
        time.sleep(3)
    elif kind == 'sim':
        run('xcrun', 'simctl', 'launch', '--terminate-running-process', udid, bundle, '--launch-arg', 'screen=sketch')
        time.sleep(3)
    # "current" paints on the Sketch screen that is already open.
    started = time.monotonic()
    player = SketchPlayer(axe, tree, log=lambda text: print(f'  {text}', flush=True))
    with open(picture_path) as file:
        strokes = player.play(json.load(file))
    player.check()
    axe('screenshot', '--output', output)
    tools = sorted({ink.split(' ')[0] for ink in player.inks})
    print(f"PAINTED strokes={strokes} inks={len(player.inks)} tools={','.join(tools)} commands={calls[0]} "
          f"seconds={time.monotonic() - started:.0f} picture={output}")


if __name__ == '__main__':
    try:
        main()
    except (PictureFailed, RuntimeError) as error:
        sys.exit(f'The picture was not painted: {error}')
