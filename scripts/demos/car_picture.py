#!/usr/bin/env python3
"""Builds the picture the Sketch checks paint: a shaded 3D car.

A low-polygon coupe is lit by one light, projected through a perspective camera and broken into flat
faces, far faces first. Each face becomes a `fill` in one of five tones of red, so the shading comes
from the geometry. Watercolour washes make the wall, floor and cast shadow, crayon and pencil add
texture and hatching, and a fountain pen and a pen add the outlines and details.

The output is a list of steps in the picture's own coordinates (0 to 1 across and down a 4:3 box):

    {"op": "tool", "name": "Monoline", "weight": "Very Heavy"}   weight is omitted for tools without one
    {"op": "colour", "name": "red3"}                             a swatch of the Sketch screen
    {"op": "fill", "points": [[u, v], ...], "spacing": 4.2}      a convex polygon, filled solid
    {"op": "line", "points": [[u, v], ...], "seconds": 0.4}      one stroke
    {"op": "wash", "rect": [u0, v0, u1, v1], "band": 34}         horizontal bands, `band` points apart

Run it to write scripts/fixtures/sketch-car.json. scripts/sketch_picture.py plays that file, for a demo
and in the simulator and device suites.
"""
import json
import math
import sys
from pathlib import Path

CAMERA, TARGET = (5.4, 2.5, 6.4), (0.05, 0.55, 0.0)
LIGHT = (0.50, 0.85, 0.62)
TONES = [(0.44, 'red1'), (0.58, 'red2'), (0.72, 'red3'), (0.85, 'red4'), (9, 'red5')]


def sub(a, b): return tuple(x - y for x, y in zip(a, b))
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def unit(a): n = math.sqrt(dot(a, a)); return tuple(x / n for x in a)


FORWARD = unit(sub(TARGET, CAMERA))
RIGHT = unit(cross(FORWARD, (0, 1, 0)))
UP = cross(RIGHT, FORWARD)


def project(p):
    d = sub(p, CAMERA)
    depth = dot(d, FORWARD)
    return dot(d, RIGHT) / depth, dot(d, UP) / depth, depth


class Scene:
    def __init__(self):
        self.faces = []      # (depth, colour, projected points)
        self.steps = []

    def face(self, points, colour=None, two_sided=False):
        """A flat polygon. Without a colour it is body paint, toned by its angle to the light."""
        normal = unit(cross(sub(points[1], points[0]), sub(points[2], points[0])))
        centre = tuple(sum(p[i] for p in points) / len(points) for i in range(3))
        if dot(normal, sub(CAMERA, centre)) <= 0:
            if not two_sided:
                return
            normal = tuple(-n for n in normal)
        if colour is None:
            intensity = 0.25 + 0.75 * max(0.0, dot(normal, unit(LIGHT)))
            colour = next(name for limit, name in TONES if intensity < limit)
        flat = [project(p) for p in points]
        self.faces.append((sum(p[2] for p in flat) / len(flat), colour, [(x, y) for x, y, _ in flat]))

    def flush(self, tool='Monoline', weight='Very Heavy', spacing=4.2):
        """Emits the collected faces far to near."""
        self.steps.append(dict(op='tool', name=tool, weight=weight))
        current = None
        for _, colour, points in sorted(self.faces, key=lambda f: -f[0]):
            if colour != current:
                self.steps.append(dict(op='colour', name=colour)); current = colour
            self.steps.append(dict(op='fill', points=points, spacing=spacing))
        self.faces = []

    def tool(self, name, weight=None, colour=None):
        step = dict(op='tool', name=name)
        if weight: step['weight'] = weight
        self.steps.append(step)
        if colour: self.colour(colour)

    def colour(self, name): self.steps.append(dict(op='colour', name=name))
    def line(self, points, seconds=0.4): self.steps.append(dict(op='line', points=[project(p)[:2] for p in points], seconds=seconds))
    def fill(self, points, spacing=4.2): self.steps.append(dict(op='fill', points=[project(p)[:2] for p in points], spacing=spacing))


def disc(x, y, z, radius, sides=18):
    """A wheel-shaped polygon in the plane z = const, wound to face +z."""
    return [(x + radius * math.cos(-2 * math.pi * i / sides), y + radius * math.sin(-2 * math.pi * i / sides), z) for i in range(sides)]


def build():
    s = Scene()
    # Body stations from tail to nose: x, belt height, half width.
    stations = [(-2.25, 0.93, 0.80), (-1.75, 1.00, 0.90), (-1.00, 1.02, 0.93), (0.00, 1.00, 0.94),
                (0.95, 0.97, 0.93), (1.55, 0.88, 0.91), (2.00, 0.78, 0.86), (2.25, 0.64, 0.74)]
    floor, waist, crown = 0.30, 0.62, 0.05

    # Ground shadow first: two soft watercolour layers under the car.
    s.tool('Watercolor', colour='shadow')
    for grow in (0.0, -0.16):
        s.fill([(-2.45 - grow, 0, -1.0 - grow), (2.5 + grow, 0, -1.0 - grow), (2.5 + grow, 0, 1.18 + grow), (-2.45 - grow, 0, 1.18 + grow)], spacing=14)
    # The contact shadow, darkest where the body is closest to the floor.
    s.fill([(-2.1, 0, 0.2), (2.2, 0, 0.2), (2.2, 0, 0.95), (-2.1, 0, 0.95)], spacing=14)

    # Far-side wheels, seen under the body.
    s.tool('Monoline', 'Very Heavy', 'grey1')
    for x in (-1.45, 1.45):
        s.fill([(px, py, -pz) for px, py, pz in reversed(disc(x, 0.34, 0.9, 0.34))])

    # The body: sides in two strips, a crowned bonnet and boot, the nose and the cabin.
    for (x0, belt0, w0), (x1, belt1, w1) in zip(stations, stations[1:]):
        s.face([(x0, floor, w0 * 0.95), (x1, floor, w1 * 0.95), (x1, waist, w1), (x0, waist, w0)])
        s.face([(x0, waist, w0), (x1, waist, w1), (x1, belt1, w1 * 0.97), (x0, belt0, w0 * 0.97)])
        cabin = -1.0 <= x0 and x1 <= 0.95
        if not cabin:
            # A crowned top: the centre line is higher, so the two halves catch the light differently.
            s.face([(x0, belt0, w0 * 0.97), (x1, belt1, w1 * 0.97), (x1, belt1 + crown, 0), (x0, belt0 + crown, 0)])
            s.face([(x0, belt0 + crown, 0), (x1, belt1 + crown, 0), (x1, belt1, -w1 * 0.97), (x0, belt0, -w0 * 0.97)])
    nose_x, nose_belt, nose_w = stations[-1]
    s.face([(nose_x, floor, nose_w * 0.95), (nose_x, floor, -nose_w * 0.95), (nose_x, nose_belt, -nose_w * 0.97), (nose_x, nose_belt, nose_w * 0.97)])
    s.face([(nose_x, nose_belt, nose_w * 0.97), (nose_x, nose_belt, -nose_w * 0.97), (nose_x, nose_belt + crown, 0)])

    # Cabin: the base sits on the belt, the roof is narrower.
    base_w, roof_w, roof_y = 0.86, 0.64, 1.43
    front, rear, roof_front, roof_rear = 0.95, -1.0, 0.22, -0.55
    front_y, rear_y = 0.97, 1.02
    s.face([(front, front_y, base_w), (roof_front, roof_y, roof_w), (roof_rear, roof_y, roof_w), (rear, rear_y, base_w)])          # near side
    s.face([(roof_front, roof_y, roof_w), (roof_front, roof_y, -roof_w), (roof_rear, roof_y, -roof_w), (roof_rear, roof_y, roof_w)])  # roof
    s.face([(front, front_y, base_w), (front, front_y, -base_w), (roof_front, roof_y, -roof_w), (roof_front, roof_y, roof_w)], 'glass2')  # windscreen
    s.face([(rear, rear_y, -base_w), (rear, rear_y, base_w), (roof_rear, roof_y, roof_w), (roof_rear, roof_y, -roof_w)], 'glass1')        # rear window
    s.flush()

    # Glass on the near side, set into the cabin, with a pillar between the two panes.
    def side(x, t):   # a point on the cabin side: t = 0 at the belt, 1 at the roof
        if x >= roof_front:
            k = (front - x) / (front - roof_front); top = front_y + (roof_y - front_y) * k; width = base_w + (roof_w - base_w) * k
            return (x, front_y + (top - front_y) * t + 0.0, base_w + (width - base_w) * t + 0.004)
        if x <= roof_rear:
            k = (x - rear) / (roof_rear - rear); top = rear_y + (roof_y - rear_y) * k; width = base_w + (roof_w - base_w) * k
            return (x, rear_y + (top - rear_y) * t, base_w + (width - base_w) * t + 0.004)
        return (x, 1.0 + (roof_y - 1.0) * t, base_w + (roof_w - base_w) * t + 0.004)
    s.tool('Monoline', 'Very Heavy', 'glass1')
    s.fill([side(0.72, 0.12), side(0.30, 0.86), side(-0.08, 0.86), side(-0.08, 0.12)])
    s.fill([side(-0.18, 0.12), side(-0.18, 0.86), side(-0.52, 0.86), side(-0.80, 0.12)])
    # Reflections: a lighter band across the windscreen and each side pane.
    s.colour('glass3')
    s.fill([(0.80, 1.07, 0.55), (0.80, 1.07, 0.15), (0.40, 1.32, 0.12), (0.40, 1.32, 0.48)])
    s.fill([side(0.50, 0.50), side(0.34, 0.80), side(0.18, 0.80), side(0.34, 0.50)])

    # Lights and grille on the nose.
    front_face = nose_x + 0.004
    s.colour('grey1')
    s.fill([(front_face, 0.34, 0.50), (front_face, 0.34, -0.50), (front_face, 0.47, -0.50), (front_face, 0.47, 0.50)])
    s.colour('cream')
    for sign in (1, -1):
        s.fill([(front_face, 0.50, sign * 0.68), (front_face, 0.50, sign * 0.40), (front_face, 0.61, sign * 0.40), (front_face, 0.61, sign * 0.68)][::sign])
    s.colour('grey5')
    s.fill([(front_face + 0.002, 0.37, 0.17), (front_face + 0.002, 0.37, -0.17), (front_face + 0.002, 0.44, -0.17), (front_face + 0.002, 0.44, 0.17)])
    s.colour('amber')
    s.fill([(2.02, 0.56, 0.872), (2.20, 0.52, 0.775), (2.20, 0.60, 0.775), (2.02, 0.64, 0.872)])

    # Near-side wheels: a dark arch, the tyre's depth, then the rim and hub.
    for x in (-1.45, 1.45):
        s.colour('shadow'); s.fill(disc(x, 0.37, 0.935 if x > 0 else 0.93, 0.43))
        s.colour('grey1')
        for z in (0.72, 0.80, 0.88, 0.955):
            s.fill(disc(x, 0.34, z, 0.34))
        s.colour('grey3'); s.fill(disc(x, 0.34, 0.96, 0.225, 14))
        s.colour('grey2'); s.fill(disc(x, 0.34, 0.962, 0.15, 10))
        s.colour('grey5')
        for spoke in range(5):
            angle = 2 * math.pi * spoke / 5 + 0.3
            s.line([(x, 0.34, 0.965), (x + 0.215 * math.cos(angle), 0.34 + 0.215 * math.sin(angle), 0.965)], 0.25)
        s.colour('grey4'); s.fill(disc(x, 0.34, 0.967, 0.05, 8))

    # A door mirror.
    s.colour('red2')
    s.fill([(0.86, 1.00, 0.90), (0.72, 1.00, 0.90), (0.70, 1.09, 1.04), (0.84, 1.09, 1.04)])

    # Crisp lines with the fountain pen: door shut lines, the sill and the wheel arches' upper edges.
    def body(x, y):   # a point on the near side of the body at this height
        for (x0, _, w0), (x1, _, w1) in zip(stations, stations[1:]):
            if x0 <= x <= x1:
                w = w0 + (w1 - w0) * (x - x0) / (x1 - x0)
                return (x, y, w * (0.95 + 0.05 * min(1, (y - floor) / (waist - floor))) + 0.004)
        raise ValueError(x)
    s.tool('Fountain Pen', 'Medium', 'red1')
    s.line([body(0.62, 0.36), body(0.62, 0.62), body(0.66, 0.95)], 0.5)
    s.line([body(-0.72, 0.36), body(-0.72, 0.62), body(-0.80, 0.98)], 0.5)
    s.line([body(x / 10, 0.33) for x in range(-9, 10, 3)], 0.5)
    s.colour('black')
    s.line([body(0.20, 0.80), body(0.42, 0.80)], 0.25)      # door handle
    # Highlights along the shoulder and across the bonnet.
    s.tool('Monoline', 'Medium', 'white')
    s.line([body(x / 10, 0.92 if x < 10 else 0.89) for x in range(-17, 15, 4)], 0.7)
    s.line([(1.05, 1.005, 0.50), (1.60, 0.925, 0.47), (2.05, 0.81, 0.40)], 0.5)
    s.line([(0.15, roof_y + 0.004, 0.52), (-0.45, roof_y + 0.004, 0.52)], 0.3)
    # Pencil hatching along the near edge of the shadow.
    s.tool('Pencil', colour='grey1')
    for i in range(16):
        x = -2.35 + i * 0.3
        s.line([(x, 0, 0.98), (x + 0.16, 0, 1.36)], 0.2)
    return s.steps


def fit(steps):
    """Scales the projected picture into the unit box, centred, leaving room for the wall above."""
    points = [p for step in steps if 'points' in step for p in step['points']]
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    width, height = max(xs) - min(xs), max(ys) - min(ys)
    scale = min(0.90 / width, 0.62 / (height * 4 / 3))       # the box is 4:3, so v spans 3/4 of u
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    for step in steps:
        if 'points' in step:
            step['points'] = [[round(0.5 + (x - cx) * scale, 4), round(0.58 - (y - cy) * scale * 4 / 3, 4)] for x, y in step['points']]
    return steps


def picture():
    car = fit(build())
    horizon = 0.34      # where the wall meets the floor, behind the far edge of the shadow
    background = [
        dict(op='tool', name='Watercolor'), dict(op='colour', name='wall'),
        dict(op='wash', rect=[0.0, 0.0, 1.0, horizon], band=30),
        dict(op='wash', rect=[0.0, 0.0, 1.0, 0.14], band=30),          # a second layer darkens the top
        dict(op='tool', name='Crayon', weight='Medium'), dict(op='colour', name='road'),
        dict(op='wash', rect=[0.0, horizon + 0.02, 1.0, 1.0], band=30),
        dict(op='tool', name='Fountain Pen', weight='Medium'), dict(op='colour', name='grey2'),
        dict(op='line', points=[[0.0, horizon], [1.0, horizon]], seconds=0.5),
    ]
    return dict(aspect=[4, 3], steps=background + car)


if __name__ == '__main__':
    target = Path(__file__).resolve().parent.parent / 'fixtures/sketch-car.json'
    spec = picture()
    target.write_text(json.dumps(spec, separators=(',', ':')) + '\n')
    ops = [step['op'] for step in spec['steps']]
    print(f'{target}: {len(ops)} steps:', {op: ops.count(op) for op in sorted(set(ops))}, file=sys.stderr)
