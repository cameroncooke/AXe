#!/usr/bin/env python3
"""Paint a sunset on the Playground's Sketch screen (a PencilKit canvas) using only the axe CLI.

    scripts/demos/paint-sunset.py AXE UDID sim|device OUTPUT.png

It picks tools and line weights in the system tool picker by their accessibility labels, sets opacity by
dragging the picker's slider, picks colours by tapping cells of the system colour picker's grid, paints
with `axe draw` (and `axe tap` for the stars) and ends with `axe screenshot`. About 235 commands and
4.5 minutes. To film it, run `axe record-video` alongside.

The colour picker draws in another process and exposes no elements, so its grid is tapped by position.
Those positions were measured on a 402-point-wide iPhone (iPhone 18 Pro); other screen sizes need the
`grid` values in `Painter` measured again from a screenshot.
"""
import json, math, subprocess, sys, time

axe, udid, kind, out = sys.argv[1:5]
BUNDLE = 'com.cameroncooke.AxePlayground'
calls = 0

def sh(*a, check=True, timeout=120):
    r = subprocess.run(a, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode:
        raise SystemExit(f'{" ".join(a[1:6])} failed: {(r.stderr or r.stdout)[-300:]}')
    return r

def ax(*a, check=True):
    global calls; calls += 1
    return sh(axe, *a, '--udid', udid, check=check)

def tree():
    for _ in range(5):
        r = ax('describe-ui', check=False)
        if r.returncode == 0: return json.loads(r.stdout)
        time.sleep(0.5)
    raise SystemExit('describe-ui kept failing')

def nodes(t):
    out = []
    def walk(n):
        if isinstance(n, dict):
            out.append(n)
            for c in n.get('children', []): walk(c)
        elif isinstance(n, list):
            for c in n: walk(c)
    walk(t); return out

def by_id(t, i): return next((n for n in nodes(t) if n.get('AXUniqueId') == i), None)
def value(i): return (by_id(tree(), i) or {}).get('AXValue')
def centre(n): f = n['frame']; return f['x'] + f['width'] / 2, f['y'] + f['height'] / 2
def tap_xy(x, y, wait=0.5): ax('tap', '-x', f'{x:.0f}', '-y', f'{y:.0f}'); time.sleep(wait)

class Painter:
    def __init__(self):
        self.colour = {}
        t = tree()
        # PencilKit remembers the last tool; a tap on the selected tool opens its options instead.
        ink = ((by_id(t, 'sketch.tool') or {}).get('AXValue') or '').split(' ')[0]
        self.tool = {'pen': 'Pen', 'marker': 'Marker', 'pencil': 'Pencil', 'crayon': 'Crayon', 'monoline': 'Monoline',
                     'fountainpen': 'Fountain Pen', 'watercolor': 'Watercolor'}.get(ink.lower())
        f = by_id(t, 'sketch.canvas')['frame']
        self.x0, self.y0, self.w = f['x'], f['y'], f['width']
        palette = by_id(t, 'Drawing-Palette')['frame']
        if palette['width'] < 200:  # minimised: expand it
            tap_xy(*centre(by_id(t, 'Drawing-Palette')), wait=1.2)
            palette = by_id(tree(), 'Drawing-Palette')['frame']
        self.h = palette['y'] - 8 - self.y0
        screen = nodes(t)[0]['frame']
        self.sw, self.sh = screen['width'], screen['height']
        # Colour grid of the system colour picker: 12 columns, 10 rows (measured on this screen size).
        self.grid = dict(x=24 / 402 * self.sw, y=348, cw=356 / 12 / 402 * self.sw, ch=29.5, close=(44, 273))

    def P(self, u, v): return self.x0 + self.w * u, self.y0 + self.h * v

    def select(self, name):
        if self.tool != name:
            ax('tap', '--label', name, '--element-type', 'Button'); time.sleep(0.6)
            self.tool = name

    def attributes(self, name, weight=None, opacity=None):
        self.select(name)
        for attempt in range(3):   # a tap on the selected tool opens its options
            ax('tap', '--label', name, '--element-type', 'Button'); time.sleep(1.0)
            if any(str(n.get('AXUniqueId') or '').endswith('_InkAttributesPicker') for n in nodes(tree())): break
        else: raise SystemExit(f'{name} options did not open')
        if weight:
            ax('tap', '--value', weight, '--element-type', 'Button'); time.sleep(0.4)
        if opacity is not None:
            t = tree(); knob = by_id(t, 'OpacitySliderKnob'); track = by_id(t, 'Opacity')['frame']
            kx, ky = centre(knob)
            tx = track['x'] + 16 + (track['width'] - 32) * opacity
            if abs(tx - kx) > 2:
                ax('drag', '--start-x', f'{kx:.0f}', '--start-y', f'{ky:.0f}', '--end-x', f'{tx:.0f}', '--end-y', f'{ky:.0f}', '--duration', '0.4')
                time.sleep(0.4)
        tap_xy(self.sw / 2, self.y0 - 22, wait=0.7)   # outside the popover: dismiss
        return value('sketch.tool')

    def paint(self, name, col, row):
        """Give the tool `name` the colour at (col, row) of the picker's grid."""
        self.select(name)
        if self.colour.get(name) == (col, row): return
        for attempt in range(3):
            ax('tap', '--id', 'PKPalette-Multicolor-Swatch'); time.sleep(1.3)
            if by_id(tree(), 'UIColorPickerView'): break
        else: raise SystemExit('colour picker did not open')
        g = self.grid
        tap_xy(g['x'] + (col + 0.5) * g['cw'], g['y'] + (row + 0.5) * g['ch'], wait=0.5)
        tap_xy(*g['close'], wait=0.9)
        self.colour[name] = (col, row)

    def stroke(self, points, seconds=None):
        pts = [points[0]] + [p for a, p in zip(points, points[1:]) if abs(a[0] - p[0]) + abs(a[1] - p[1]) > 0.05]
        seconds = seconds or max(0.25, min(12, 0.022 * len(pts)))
        ax('draw', *[f'{x:.1f},{y:.1f}' for x, y in pts], '--duration', f'{seconds:.2f}')

    def band(self, v, u0=0.03, u1=0.97, wobble=0.0):
        n = 24
        self.stroke([self.P(u0 + (u1 - u0) * i / n, v + wobble * math.sin(i / n * 2 * math.pi * 1.5)) for i in range(n + 1)], 0.7)

    def fill_between(self, top, bottom, u0, u1, spacing):
        """One zigzag stroke filling the area between two functions of u, columns `spacing` points apart."""
        cols = max(2, min(480, int((u1 - u0) * self.w / max(spacing, 1.0))))
        pts = []
        for i in range(cols + 1):
            u = u0 + (u1 - u0) * i / cols
            a, b = self.P(u, top(u)), self.P(u, bottom(u))
            pts += [a, b] if i % 2 == 0 else [b, a]
        self.stroke(pts)

    def disc(self, u, v, r, spacing):
        cx, cy = self.P(u, v); turns = max(1.0, r / spacing); n = int(40 * turns)
        self.stroke([(cx + r * (i / n) * math.cos(i / n * turns * 2 * math.pi), cy + r * (i / n) * math.sin(i / n * turns * 2 * math.pi)) for i in range(1, n + 1)])

if kind == 'device':
    sh('xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing', '--device', udid, BUNDLE, '--launch-arg', 'screen=sketch')
else:
    sh('xcrun', 'simctl', 'launch', '--terminate-running-process', udid, BUNDLE, '--launch-arg', 'screen=sketch')
time.sleep(2.5)
started = time.monotonic()
p = Painter()
print(f'canvas {p.w:.0f}x{p.h:.0f} at {p.x0:.0f},{p.y0:.0f}', flush=True)

# 1. Sky and water: broad washes with the marker at its heaviest weight and full opacity.
marker = p.attributes('Marker', weight='Very Heavy', opacity=1.0)
print('marker:', marker, flush=True)
step = 52 / p.h          # the heaviest marker paints a band about 53 points tall
sky = [(2, 2), (3, 3), (3, 5), (4, 5), (6, 5), (7, 5)]
HORIZON = step * len(sky)
for i, c in enumerate(sky):
    p.paint('Marker', *c); p.band(step * (i + 0.5), u0=0.0, u1=1.0)
water = [(0, 4), (1, 4), (1, 3), (1, 2), (2, 2)]
for i, c in enumerate(water):
    v = HORIZON + step * (i + 0.5)
    if v - step / 2 < 0.99:
        p.paint('Marker', *c); p.band(min(v, 1 - step / 2), u0=0.0, u1=1.0)
print('sky and water done', flush=True)

# 2. Clouds: soft streaks, still with the marker.
p.attributes('Marker', weight='Medium', opacity=0.5)
p.paint('Marker', 4, 6)
for u0, u1, v in [(0.04, 0.40, 0.20), (0.52, 0.96, 0.13), (0.10, 0.34, 0.37), (0.62, 0.92, 0.30)]:
    p.stroke([p.P(u0 + (u1 - u0) * i / 16, v + 0.007 * math.sin(i * 0.9)) for i in range(17)], 0.5)

# Everything else uses Monoline: opaque, and the same width at any speed, so fills are solid.
LINE = 4.2               # column spacing that leaves no gaps at the heaviest Monoline weight
def solid(top, bottom, u0, u1, spacing=LINE): p.fill_between(top, bottom, u0, u1, spacing)
def ball(u, v, r): p.disc(u, v, r, LINE)

# 3. The sun: a soft glow, then three discs, each one spiral stroke.
print('monoline:', p.attributes('Monoline', weight='Very Heavy', opacity=0.3), flush=True)
SUN = (0.63, HORIZON - 0.075)
p.paint('Monoline', 8, 6); ball(*SUN, 0.20 * p.w)
p.attributes('Monoline', opacity=1.0)
p.paint('Monoline', 8, 5); ball(*SUN, 0.135 * p.w)
p.paint('Monoline', 9, 6); ball(*SUN, 0.105 * p.w)
p.paint('Monoline', 9, 8); ball(SUN[0] - 0.012, SUN[1] - 0.012, 0.05 * p.w)

# 4. Stars in the dark top of the sky: one tap each.
p.paint('Monoline', 0, 0)
for u, v in [(0.08, 0.03), (0.21, 0.07), (0.33, 0.02), (0.55, 0.05), (0.69, 0.025), (0.83, 0.065), (0.94, 0.03), (0.45, 0.085)]:
    tap_xy(*p.P(u, v), wait=0.15)

# 5. Mountains: a far range, then a nearer, darker one. Outline first, then one zigzag fill each.
def mountain(ridge, colour):
    p.paint('Monoline', *colour)
    p.stroke([p.P(i / 70, ridge(i / 70)) for i in range(71)], 1.5)
    solid(ridge, lambda u: HORIZON + 0.006, 0.0, 1.0)
    p.stroke([p.P(0.0, HORIZON + 0.008), p.P(1.0, HORIZON + 0.008)], 0.6)      # a clean waterline
far = lambda u: HORIZON - 0.03 - 0.075 * (0.5 + 0.5 * math.sin(u * 6.5 + 4.2)) ** 2 - 0.03 * (0.5 + 0.5 * math.sin(u * 14 + 1.0)) - 0.005 * math.sin(u * 41)
mountain(far, (2, 1))
near = lambda u: HORIZON - 0.008 - 0.085 * math.exp(-((u - 0.90) / 0.12) ** 2) - 0.05 * math.exp(-((u - 0.04) / 0.17) ** 2) - 0.004 * math.sin(u * 37)
mountain(near, (11, 0))
print('sun, stars and mountains done', flush=True)

# 6. The sun's reflection: opaque dashes, shorter as they come nearer.
for colour, rows in [((8, 5), [(0.035, 0.115), (0.085, 0.09), (0.14, 0.075), (0.20, 0.06), (0.265, 0.045), (0.335, 0.03)]),
                     ((9, 6), [(0.055, 0.10), (0.11, 0.075), (0.168, 0.062), (0.232, 0.048), (0.30, 0.035)]),
                     ((9, 8), [(0.045, 0.05), (0.098, 0.04), (0.155, 0.03)])]:
    p.paint('Monoline', *colour)
    for dv, half in rows:
        p.stroke([p.P(SUN[0] - half + 2 * half * i / 8, HORIZON + dv + 0.002 * math.sin(i * 1.7)) for i in range(9)], 0.3)

# 7. Foreground shore and a tree in silhouette.
p.paint('Monoline', 11, 0)
shore = lambda u: 0.80 + 0.19 * (u / 0.5) ** 1.6
p.stroke([p.P(0.5 * i / 30, shore(0.5 * i / 30)) for i in range(31)], 0.8)
solid(shore, lambda u: 0.99, 0.0, 0.5)
p.stroke([p.P(0.0, 0.992), p.P(0.5, 0.992)], 0.4)
trunk_left = lambda v: 0.150 + 0.05 * ((0.86 - v) / 0.40) ** 1.6
for offset in (0.0, 0.009, 0.018):
    p.stroke([p.P(trunk_left(0.86 - 0.40 * i / 12) + offset * (1 - i / 14), 0.86 - 0.40 * i / 12) for i in range(13)], 0.5)
for branch in [[(0.172, 0.63), (0.11, 0.56), (0.06, 0.53)], [(0.184, 0.57), (0.26, 0.50), (0.32, 0.485)],
               [(0.188, 0.54), (0.14, 0.46), (0.11, 0.41)], [(0.196, 0.49), (0.25, 0.42), (0.28, 0.375)],
               [(0.200, 0.46), (0.19, 0.38), (0.20, 0.33)], [(0.11, 0.56), (0.09, 0.49)], [(0.26, 0.50), (0.29, 0.44)]]:
    p.stroke([p.P(*q) for q in branch], 0.35)
p.paint('Monoline', 11, 1)
for u, v, r in [(0.06, 0.51, 0.05), (0.11, 0.40, 0.055), (0.20, 0.31, 0.06), (0.28, 0.365, 0.05), (0.32, 0.47, 0.045), (0.09, 0.47, 0.04), (0.16, 0.36, 0.05), (0.24, 0.42, 0.045)]:
    ball(u, v, r * p.w)

# 8. A sailing boat, with a finer line.
B = HORIZON + 0.16       # waterline of the boat
p.attributes('Monoline', weight='Medium'); p.paint('Monoline', 11, 0)
FINE = 2.4
solid(lambda u: B, lambda u: B + 0.03 - 0.022 * abs(u - 0.79) / 0.1, 0.69, 0.89, FINE)
p.stroke([p.P(0.69, B), p.P(0.89, B)], 0.3)
p.stroke([p.P(0.785, B), p.P(0.785, B - 0.15)], 0.3)
p.paint('Monoline', 0, 0)
solid(lambda u: B - 0.14 + (u - 0.80) * 1.45, lambda u: B - 0.018, 0.80, 0.885, FINE)
solid(lambda u: B - 0.018 - (u - 0.70) * 1.45, lambda u: B - 0.018, 0.70, 0.77, FINE)
p.attributes('Monoline', weight='Very Heavy')

# 9. Birds.
p.attributes('Monoline', weight='Medium'); p.paint('Monoline', 11, 0)
for u, v, s in [(0.38, 0.15, 1.0), (0.47, 0.11, 0.75), (0.30, 0.10, 0.6), (0.84, 0.21, 0.8), (0.76, 0.17, 0.55)]:
    wing = 0.035 * s
    pts = [p.P(u - wing + wing * i / 6, v - 0.012 * s * math.sin(i / 6 * math.pi)) for i in range(7)]
    pts += [p.P(u + wing * i / 6, v - 0.012 * s * math.sin(i / 6 * math.pi)) for i in range(1, 7)]
    p.stroke(pts, 0.3)

time.sleep(0.6)
strokes = value('sketch.strokeCount')
ax('screenshot', '--output', out)
print(f'{strokes} strokes, {calls} axe commands, {time.monotonic() - started:.0f} s; screenshot {out}')
