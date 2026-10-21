#!/usr/bin/env python3
"""Verify one gesture or point read on the normal v6 app. No reset or input retry.

Guest window coordinates are oriented logical points. This proves observed paths,
not every HID sample, an atomic foreground lock, or physical timing accuracy.
"""
import argparse
import hashlib
import json
import math
import pathlib
import subprocess
import time
import uuid

CASES = ("point", "pad-tap", "hold", "swipe", "drag", "double-tap", "pinch", "rotate",
         "two-finger-tap", "two-finger-hold", "nested-up", "nested-down",
         "page-up", "page-down", "preset-scroll-left", "preset-scroll-right")
BUNDLE = "com.camsoft.duo-session-probe"
TOLERANCE = 0.5


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def write_json(filename, value):
    filename.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def decode(raw):
    def invalid(value):
        raise ValueError("Nonfinite JSON: " + value)
    return json.loads(raw, parse_constant=invalid)


def command(args, name, argv):
    # Keep ownership after spawn, including receipt errors and interruption. No kill.
    with (args.output / (name + ".stdout")).open("wb") as out, (args.output / (name + ".stderr")).open("wb") as err:
        child = subprocess.Popen(argv, stdout=out, stderr=err)
        failure = None
        try:
            write_json(args.output / (name + "-started.json"), {"argv": argv, "pid": child.pid})
        except BaseException as error:
            failure = error
        while True:
            try:
                code = child.wait()
                break
            except BaseException as error:
                failure = failure or error
    write_json(args.output / (name + "-process.json"), {"argv": argv, "pid": child.pid,
               "exit": code, "reaped": True, "ownerError": repr(failure) if failure else None})
    if failure is not None:
        raise failure
    require(code == 0, name + " failed; input will not be repeated")
    return (args.output / (name + ".stdout")).read_text()


def bind_state(args, name):
    raw = command(args, name, ["/usr/bin/xcrun", "simctl", "get_app_container", args.udid, BUNDLE, "data"])
    container = pathlib.Path(raw.strip()).resolve(strict=True)
    require(args.state_file.resolve(strict=True) == container / "Documents/state.json",
            "State file is not the current device/app Documents/state.json")
    processes = command(args, name + "-pid", ["/usr/bin/xcrun", "simctl", "spawn", args.udid, "launchctl", "list"])
    matches = [line.split() for line in processes.splitlines() if "UIKitApplication:" + BUNDLE + "[" in line]
    require(len(matches) == 1 and matches[0][0] == str(args.pid), "Current fixture process differs")
    return str(container)


def read_state(args, context):
    state = decode(args.state_file.read_bytes())
    require(state["fixtureVersion"] == 6, "Normal v6 app state required")
    require((state["width"], state["height"]) == (context["logicalWidth"], context["logicalHeight"])
            and state["interfaceOrientation"] == {0: 1, 90: 4, 180: 2, 270: 3}[args.rotation],
            "App geometry/orientation differs from selected context")
    require(all(math.isfinite(state[k]) for k in ("listOffsetY", "pageOffsetY", "pinchScale", "rotationRadians")), "Nonfinite fixture effect")
    return state


def walk(nodes):
    for node in nodes:
        yield node
        yield from walk(node.get("children", []))


def invoke(args, name, verb, extra, ax=False):
    argv = [str(args.axe), verb, *extra, "--udid", args.udid, "--input-mode", "selected",
            "--screen-id", str(args.screen_id), "--screen-uuid", args.screen_uuid]
    if ax:
        argv += ["--expected-pid", str(args.pid), "--ax-preparation", "existing-bridge"]
    receipt = decode(command(args, name, argv))
    write_json(args.output / (name + "-receipt.json"), receipt)
    context = receipt["context"]
    require(receipt.get("error") is None and receipt.get("cleanup") != "uncertain", "Unsuccessful receipt")
    require(context["screenID"] == args.screen_id and uuid.UUID(context["screenUUID"]) == uuid.UUID(args.screen_uuid)
            and context["rotationDegrees"] == args.rotation, "Selected display/rotation differs")
    if not ax:
        require(receipt["outcome"] == "enqueuedAndDrained" and receipt["enqueuedEventCount"] > 0,
                "Input did not complete and drain")
    return receipt


def rect(node):
    frame = tuple(node["frame"][key] for key in ("x", "y", "width", "height"))
    require(all(math.isfinite(v) for v in frame) and min(frame[2:]) > 0, "Invalid AX frame")
    return frame


def contains(frame, point):
    x, y, w, h = frame
    return x <= point[0] <= x + w and y <= point[1] <= y + h


def exact_node(args, nodes, identifier):
    matches = [n for n in nodes if n.get("AXUniqueId") == identifier]
    require(len(matches) == 1 and matches[0].get("pid") == args.pid, "Missing/ambiguous owned " + identifier)
    require(matches[0].get("hidden") is False and matches[0].get("enabled") is True, "Unavailable " + identifier)
    return matches[0]


def geometry(args, description, before):
    nodes = list(walk(description["ax"]["roots"]))
    nested = args.case.startswith("nested-")
    identifier = "feature.list" if nested else "feature.pad"
    frame = rect(exact_node(args, nodes, identifier))
    viewport = rect(exact_node(args, nodes, "feature.mainScroll"))
    c = description["context"]
    screen = (0, 0, c["logicalWidth"], c["logicalHeight"])
    x, y, w, h = frame
    for corner in [(x, y), (x + w, y + h)]:
        require(contains(screen, corner) and contains(viewport, corner), "Target is clipped by the page/display")
    require(w >= 100 and h >= 100, "Target is too small for the full gesture")
    for control in ("feature.slider", "feature.switch", "feature.text", "feature.tap"):
        other = rect(exact_node(args, nodes, control))
        for start, end in expected_paths(args.case, x + w / 2, y + h / 2):
            require(not contains(other, start) and not contains(other, end), "Gesture overlaps another control")
    capacity = None
    if nested:
        rows = [rect(exact_node(args, nodes, "feature.row.%02d" % i)) for i in range(1, 31)]
        require(all(abs(a[1] + a[3] - b[1]) <= TOLERANCE for a, b in zip(rows, rows[1:])), "Row extent has gaps")
        capacity = rows[-1][1] + rows[-1][3] - rows[0][1] - h
        offset = before["listOffsetY"]
        require(abs(y - rows[0][1] - offset) <= TOLERANCE and 0 <= offset <= capacity, "List offset/AX rows differ")
        require((capacity - offset if args.case == "nested-up" else offset) >= 40, "Insufficient list scroll capacity")
    return (x + w / 2, y + h / 2), frame, capacity


def make_command(args, x, y):
    point = ["-x", str(x), "-y", str(y)]
    if args.case == "pad-tap":
        return "tap", point, "padTap"
    if args.case == "hold":
        return "touch", point + ["--down", "--up", "--delay", "0.7"], "longPress"
    if args.case in ("swipe", "drag", "nested-up", "nested-down"):
        nested = args.case.startswith("nested-")
        dx = 0 if nested else 40
        dy = (40 if args.case == "nested-up" else -40) if nested else 0
        command = "drag" if args.case == "drag" else "swipe"
        extra = ["--start-x", str(x - dx), "--start-y", str(y + dy),
                 "--end-x", str(x + dx), "--end-y", str(y - dy),
                 "--duration", "0.4"]
        extra += ["--steps", "8"] if command == "drag" else ["--delta", "10"]
        return command, extra, None if nested else "pan"
    if args.case == "double-tap":
        return "gesture", ["double-tap", *point], "doubleTap"
    if args.case == "pinch":
        return "gesture", ["pinch", *point, "--radius", "30", "--scale", "1.3"], "pinch"
    if args.case == "rotate":
        return "gesture", ["rotate", *point, "--radius", "25", "--degrees", "45"], "rotation"
    extra = [args.case, "-x", str(x - 30), "-y", str(y),
             "--x2", str(x + 30), "--y2", str(y)]
    if args.case == "two-finger-hold":
        return "gesture", extra + ["--hold", "0.7"], "twoFingerHold"
    return "gesture", extra, "twoFingerTap"


def expected_paths(case, x, y):
    if case in ("swipe", "drag"):
        return [((x - 40, y), (x + 40, y))]
    if case.startswith("nested-"):
        d = 40 if case == "nested-up" else -40
        return [((x, y + d), (x, y - d))]
    if case == "rotate":
        r = 25 / math.sqrt(2)
        return [((x + 25, y), (x + r, y + r)), ((x - 25, y), (x - r, y - r))]
    if case in ("pinch", "two-finger-tap", "two-finger-hold"):
        end = 39 if case == "pinch" else 30
        return [((x - 30, y), (x - end, y)), ((x + 30, y), (x + end, y))]
    return [((x, y), (x, y))] * (2 if case == "double-tap" else 1)


def suffix(before, after, key, dropped):
    require(after[dropped] == before[dropped] and after[key][:len(before[key])] == before[key],
            "Trace was truncated, reset or replaced: " + key)
    return after[key][len(before[key]):]


def near(actual, expected):
    return all(math.isfinite(a) and abs(a - b) <= TOLERANCE for a, b in zip(actual, expected))


def grade(args, before, after, counter, center, frame, capacity):
    require(after["sequence"] > before["sequence"] and after["activeWindowTouches"] == 0, "No fresh released app effect")
    for key in ("slider", "switchOn", "text", "textFocused"):
        require(after[key] == before[key], "Other control changed: " + key)
    for key in ("tap", "sliderChanged", "switchChanged", "textChanged", "textFocused", "returnKey"):
        require(after["counts"].get(key, 0) == before["counts"].get(key, 0), "Other callback changed: " + key)
    require(abs(after["pageOffsetY"] - before["pageOffsetY"]) <= TOLERANCE, "Page moved")
    if counter:
        require(after["counts"].get(counter, 0) == before["counts"].get(counter, 0) + 1, "Expected exactly one recognizer effect")
        require(abs(after["listOffsetY"] - before["listOffsetY"]) <= TOLERANCE, "Nested list moved during pad gesture")
    else:
        direction = 1 if args.case == "nested-up" else -1
        require(direction * (after["listOffsetY"] - before["listOffsetY"]) > 20
                and 0 <= after["listOffsetY"] <= capacity, "No settled in-range list scroll")
        for key in ("padTap", "doubleTap", "longPress", "twoFingerTap", "twoFingerHold", "pan", "pinch", "rotation",
                    "touchBegan", "touchMoved", "touchEnded", "touchCancelled"):
            require(after["counts"].get(key, 0) == before["counts"].get(key, 0), "Pad received nested-list input")
    events = suffix(before, after, "windowTouchTrace", "windowTraceDropped")
    recognizers = suffix(before, after, "recognizerTrace", "recognizerTraceDropped")
    previous_ids = {e["contactID"] for e in before["windowTouchTrace"]}
    paths = expected_paths(args.case, *center)
    ids = list(dict.fromkeys(e["contactID"] for e in events))
    require(len(ids) == len(paths) and not previous_ids.intersection(ids) and all(i > 0 for i in ids), "Wrong new contact count/identity")
    last_time = before["windowTouchTrace"][-1]["timestamp"] if before["windowTouchTrace"] else 0
    active = set()
    for e in events:
        require(math.isfinite(e["timestamp"]) and e["timestamp"] >= last_time, "Contact time regressed")
        last_time = e["timestamp"]
        phase, cid = e["phase"], e["contactID"]
        require(phase in ("windowTouchBegan", "windowTouchMoved", "windowTouchEnded"), "Cancelled/unknown contact")
        if phase == "windowTouchBegan":
            require(cid not in active, "Duplicate BEGIN")
            active.add(cid)
        else:
            require(cid in active, "Contact has no active BEGIN")
            if phase == "windowTouchEnded":
                active.remove(cid)
        require(e["activeTouches"] == len(active) and contains(frame, (e["x"], e["y"])), "Contact left target or active count differs")
    require(not active, "Contact did not end")
    groups = [[e for e in events if e["contactID"] == cid] for cid in ids]
    if args.case != "double-tap":
        groups.sort(key=lambda g: math.dist((g[0]["x"], g[0]["y"]), paths[0][0]))
    for group, (start, end) in zip(groups, paths):
        require(group[0]["phase"] == "windowTouchBegan" and group[-1]["phase"] == "windowTouchEnded"
                and sum(e["phase"] == "windowTouchBegan" for e in group) == 1, "Incomplete contact")
        require(near((group[0]["x"], group[0]["y"]), start) and near((group[-1]["x"], group[-1]["y"]), end), "Contact endpoint differs")
        progress = -TOLERANCE
        for e in group:
            px, py = e["x"], e["y"]
            if args.case == "rotate":
                sign = 1 if start[0] > center[0] else -1
                angle = math.atan2(sign * (py - center[1]), sign * (px - center[0]))
                require(abs(math.hypot(px - center[0], py - center[1]) - 25) <= TOLERANCE
                        and -0.03 <= angle <= math.pi / 4 + 0.03 and angle >= progress - 0.03, "Rotation path differs")
                progress = angle
            else:
                length = math.dist(start, end)
                if length == 0:
                    require(near((px, py), start), "Stationary contact moved")
                else:
                    dx, dy = (end[0] - start[0]) / length, (end[1] - start[1]) / length
                    distance = (px - start[0]) * dx + (py - start[1]) * dy
                    require(abs((px - start[0]) * dy - (py - start[1]) * dx) <= TOLERANCE
                            and -TOLERANCE <= distance <= length + TOLERANCE and distance >= progress - TOLERANCE, "Contact path differs")
                    progress = distance
        if start != end:
            require(any(e["phase"] == "windowTouchMoved" for e in group), "Moving contact has no MOVE")
        if args.case in ("hold", "two-finger-hold"):
            require(group[-1]["timestamp"] - group[0]["timestamp"] >= 0.5, "Hold ended too early")
    if len(groups) == 2:
        require((groups[0][-1]["timestamp"] < groups[1][0]["timestamp"]) if args.case == "double-tap" else
                max(g[0]["timestamp"] for g in groups) < min(g[-1]["timestamp"] for g in groups), "Contact overlap/order differs")
    for phase in ("windowTouchBegan", "windowTouchMoved", "windowTouchEnded", "windowTouchCancelled"):
        require(after["counts"].get(phase, 0) - before["counts"].get(phase, 0) == sum(e["phase"] == phase for e in events), "Trace/counter mismatch")
    last_recognizer_time = before["recognizerTrace"][-1]["timestamp"] if before["recognizerTrace"] else 0
    for r in recognizers:
        require(math.isfinite(r["timestamp"]) and r["timestamp"] >= max(last_recognizer_time, events[0]["timestamp"]), "Recognizer time regressed or predates input")
        last_recognizer_time = r["timestamp"]
    relevant = [r for r in recognizers if r["name"] == counter]
    if counter:
        require(relevant and relevant[-1]["state"] == 3 and sum(r["state"] == 3 for r in relevant) == 1 and all(r["state"] in (1, 2, 3) for r in relevant), "Recognizer did not complete")
        require(relevant[0]["state"] == (3 if counter in ("padTap", "doubleTap", "twoFingerTap") else 1), "Recognizer start missing")
    else:
        require(not recognizers, "Pad recognizer fired during list scroll")
    if args.case == "pinch":
        require(1.1 < after["pinchScale"] < 1.5, "Pinch scale differs")
    if args.case == "rotate":
        require(math.isfinite(after["rotationRadians"]) and abs(after["rotationRadians"] - math.pi / 4) <= 0.15, "Rotation effect differs")


def verify_point(args, description, before, container):
    context = description["context"]
    nodes = list(walk(description["ax"]["roots"]))
    frame = rect(exact_node(args, nodes, "feature.tap"))
    viewport = rect(exact_node(args, nodes, "feature.mainScroll"))
    x, y, width, height = frame
    screen = (0, 0, context["logicalWidth"], context["logicalHeight"])
    for corner in ((x, y), (x + width, y + height)):
        require(contains(viewport, corner) and contains(screen, corner), "Point target is clipped")
    point = (x + width / 2, y + height / 2)
    receipt = invoke(args, "point", "describe-ui", ["--point", f"{point[0]},{point[1]}"], ax=True)
    require(receipt["context"] == context and receipt["outcome"] == "ready"
            and receipt["enqueuedEventCount"] == 0 and receipt["ax"]["kind"] == "describePoint",
            "Point read changed context or reported input")
    roots = receipt["ax"]["roots"]
    require(len(roots) == 1 and len(receipt["ax"]["acquisition"]["attempts"]) == 1,
            "Expected one bounded point result")
    hit = roots[0]
    require(hit.get("pid") == args.pid and hit.get("type") == "StaticText"
            and hit.get("AXLabel") == "Tap counter" and hit.get("enabled") is True
            and hit.get("hidden") is False, "Point did not read the known button text child")
    actual = rect(hit)
    left, top, child_width, child_height = actual
    require(contains(frame, (left, top))
            and contains(frame, (left + child_width, top + child_height))
            and contains(actual, point), "Point child is outside the known button")
    after = read_state(args, context)
    write_json(args.output / "state-after.json", after)
    require(after == before, "Read-only point query changed app state")
    final = invoke(args, "describe-after", "describe-ui", [], ax=True)
    require(final["context"] == context and bind_state(args, "container-after") == container,
            "Final selected context/app binding changed")
    require(read_state(args, context) == before, "App state changed during final readback")
    final_nodes = list(walk(final["ax"]["roots"]))
    require(rect(exact_node(args, final_nodes, "feature.tap")) == frame, "Final target frame changed")
    result = {"result": "PASS", "case": "point", "context": context, "pid": args.pid,
              "point": point, "buttonIdentifier": "feature.tap", "hitType": hit["type"],
              "hitLabel": hit["AXLabel"], "enqueuedHIDEvents": 0,
              "appStateUnchanged": True}
    write_json(args.output / "result.json", result)
    print(json.dumps(result, sort_keys=True))



def extension_geometry(args, description, before):
    nodes = list(walk(description["ax"]["roots"]))
    ids = ("mainScroll", "tap", "pad", "slider", "switch", "switchLabel", "text", "scrollHelp", "list")
    selected = {key: exact_node(args, nodes, "feature." + key) for key in ids}
    frames = {key: rect(node) for key, node in selected.items()}
    viewport = frames["mainScroll"]
    context = description["context"]
    screen = (0, 0, context["logicalWidth"], context["logicalHeight"])
    page = args.case.startswith("page-")
    target = frames["switchLabel" if page else "pad"]
    for frame, outer in ((viewport, screen), (target, viewport)):
        x, y, w, h = frame
        require(contains(outer, (x, y)) and contains(outer, (x + w, y + h)), "Full target/viewport is clipped")
    require(selected["mainScroll"].get("type") == "ScrollArea" and selected["list"].get("type") == "ScrollArea",
            "Normal page/list AX types differ")
    capacity = None
    if page:
        require(selected["switchLabel"].get("type") == "StaticText"
                and selected["switchLabel"].get("AXLabel") == "Switch control", "Page start is not the normal label")
        x, y, w, h = target
        start = (x + w / 2, y + h / 2)
        end = (start[0], start[1] + (-60 if args.case == "page-up" else 60))
        capacity = frames["list"][1] + frames["list"][3] - frames["tap"][1] - viewport[3]
        offset = before["pageOffsetY"]
        require(math.isfinite(capacity) and capacity > 0 and 0 <= offset <= capacity
                and abs(viewport[1] - frames["tap"][1] - offset) <= TOLERANCE,
                "NO_SCROLLABLE_CONTENT: invalid page extent/offset")
        require((capacity - offset if args.case == "page-up" else offset) >= 60,
                "NO_SCROLLABLE_CONTENT: less than 60 points of page capacity")
        require(max(start[1], end[1]) + 2 < frames["list"][1], "Page path reaches nested list")
        for key in ("tap", "pad", "slider", "switch", "text", "list"):
            x, y, w, h = frames[key]
            require(not contains((x - 2, y - 2, w + 4, h + 4), start), "Page BEGIN overlaps " + key)
        # The captured contact may cross a control after BEGIN; all actions must stay unchanged.
        bounds = viewport
    else:
        require(selected["pad"].get("type") == "GenericElement", "Normal gesture pad type differs")
        x, y = context["logicalWidth"] / 2, context["logicalHeight"] / 2
        direction = -1 if args.case == "preset-scroll-left" else 1
        start, end = (x - 100 * direction, y), (x + 100 * direction, y)
        bounds = target
        for key in ("tap", "slider", "switch", "text", "list"):
            left, top, width, height = frames[key]
            require(y < top - 2 or y > top + height + 2 or max(start[0], end[0]) < left - 2
                    or min(start[0], end[0]) > left + width + 2, "Preset path overlaps " + key)
    x, y, w, h = bounds
    require(all(x + 2 < p[0] < x + w - 2 and y + 2 < p[1] < y + h - 2 for p in (start, end)),
            "Full path does not fit visible target; no retarget")
    return {"page": page, "start": start, "end": end, "bounds": bounds, "frames": frames, "capacity": capacity}


def grade_extension(args, before, after, expected):
    page, start, end = expected["page"], expected["start"], expected["end"]
    require(after["sequence"] > before["sequence"] and after["activeWindowTouches"] == 0, "No fresh released effect")
    for key in ("slider", "switchOn", "text", "textFocused", "listOffsetY", "pinchScale", "rotationRadians"):
        require(after[key] == before[key], "Unrelated state changed: " + key)
    events = suffix(before, after, "windowTouchTrace", "windowTraceDropped")
    recognizers = suffix(before, after, "recognizerTrace", "recognizerTraceDropped")
    phases = [e["phase"] for e in events]
    ids = {e["contactID"] for e in events}
    require(len(ids) == 1 and next(iter(ids)) > 0 and not ids.intersection(e["contactID"] for e in before["windowTouchTrace"]),
            "Wrong new contact identity/count")
    require(phases[0] == "windowTouchBegan" and phases[-1] == "windowTouchEnded"
            and phases.count("windowTouchBegan") == phases.count("windowTouchEnded") == 1
            and "windowTouchMoved" in phases and all(p == "windowTouchMoved" for p in phases[1:-1]),
            "Incomplete or cancelled contact")
    require(near((events[0]["x"], events[0]["y"]), start) and near((events[-1]["x"], events[-1]["y"]), end), "Endpoint differs")
    length = math.dist(start, end)
    dx, dy = (end[0] - start[0]) / length, (end[1] - start[1]) / length
    last_time = before["windowTouchTrace"][-1]["timestamp"] if before["windowTouchTrace"] else 0
    progress = -TOLERANCE
    for index, event in enumerate(events):
        x, y, stamp = event["x"], event["y"], event["timestamp"]
        distance = (x - start[0]) * dx + (y - start[1]) * dy
        require(all(math.isfinite(v) for v in (x, y, stamp)) and stamp >= last_time
                and contains(expected["bounds"], (x, y)) and event["activeTouches"] == (0 if index == len(events) - 1 else 1)
                and abs((x - start[0]) * dy - (y - start[1]) * dx) <= TOLERANCE
                and -TOLERANCE <= distance <= length + TOLERANCE and distance >= progress - TOLERANCE, "Trace path/time/active count differs")
        last_time, progress = stamp, distance
    window_keys = ("windowTouchBegan", "windowTouchMoved", "windowTouchEnded", "windowTouchCancelled")
    changes = {key: after["counts"].get(key, 0) - before["counts"].get(key, 0)
               for key in set(before["counts"]) | set(after["counts"]) | set(window_keys)}
    require(all(changes[key] == phases.count(key) for key in window_keys), "Window trace/counters differ")
    if page:
        require(not recognizers and all(value == 0 for key, value in changes.items() if key not in window_keys),
                "Page input caused control/pad callback")
        require(all(after[key] == before[key] for key in ("panX", "panY", "touchX", "touchY")), "Page input changed pad state")
        direction = 1 if args.case == "page-up" else -1
        require(direction * (after["pageOffsetY"] - before["pageOffsetY"]) > 10
                and 0 <= after["pageOffsetY"] <= expected["capacity"], "No settled in-range page movement")
    else:
        require(events[0].get("hitView") == "feature.pad" and after["pageOffsetY"] == before["pageOffsetY"], "Preset missed pad or moved page")
        allowed = set(window_keys) | {"pan", "touchBegan", "touchMoved", "touchEnded"}
        require(all(value == 0 for key, value in changes.items() if key not in allowed)
                and changes.get("pan", 0) == 1 and changes.get("touchBegan", 0) == 1
                and changes.get("touchEnded", 0) == 1 and changes.get("touchMoved", 0) > 0, "Preset control/pad callbacks differ")
        states = [r["state"] for r in recognizers]
        require(states and states[0] == 1 and states[-1] == 3 and states.count(1) == states.count(3) == 1
                and all(s == 2 for s in states[1:-1]), "Pan did not complete once")
        last_time = max(events[0]["timestamp"], before["recognizerTrace"][-1]["timestamp"] if before["recognizerTrace"] else 0)
        for r in recognizers:
            require(r["name"] == "pan" and all(math.isfinite(r[k]) for k in ("x", "y", "timestamp"))
                    and r["timestamp"] >= last_time and contains(expected["bounds"], (r["x"], r["y"])), "Wrong recognizer or stale position/time")
            last_time = r["timestamp"]
        translation = (recognizers[-1]["x"] - recognizers[0]["x"], recognizers[-1]["y"] - recognizers[0]["y"])
        require(near((after["panX"], after["panY"]), translation) and dx * after["panX"] > 20
                and abs(after["panY"]) <= TOLERANCE, "Pan translation differs from completed recognizer")


def verify_extension(args, description, before, container):
    context = description["context"]
    expected = extension_geometry(args, description, before)
    write_json(args.output / "expected-geometry.json", expected)
    if expected["page"]:
        start, end = expected["start"], expected["end"]
        verb, extra = "swipe", ["--start-x", str(start[0]), "--start-y", str(start[1]),
                                "--end-x", str(end[0]), "--end-y", str(end[1]), "--duration", "0.5", "--delta", "10"]
    else:
        verb, extra = "gesture", [args.case.removeprefix("preset-")]
    receipt = invoke(args, args.case, verb, extra)
    require(receipt["context"] == context and receipt["enqueuedEventCount"] == (8 if expected["page"] else 10),
            "Context or complete public event count differs")
    deadline, anchor, stable_since, samples = time.monotonic() + 5, None, None, []
    while True:
        after = read_state(args, context)
        now = time.monotonic()
        effect = abs(after["pageOffsetY"] - before["pageOffsetY"]) > 10 if expected["page"] else after["counts"].get("pan", 0) > before["counts"].get("pan", 0)
        samples.append({"monotonic": now, "sequence": after["sequence"], "page": after["pageOffsetY"], "active": after["activeWindowTouches"]})
        if effect and after["activeWindowTouches"] == 0:
            if anchor != after:
                anchor, stable_since = after, now
            if now - stable_since >= 1 and now < deadline:
                break
        else:
            anchor, stable_since = None, None
        if now >= deadline:
            write_json(args.output / "state-after.json", after)
            write_json(args.output / "settling.json", samples)
            raise ValueError("No settled page/preset effect; input will not be repeated")
        time.sleep(0.05)
    write_json(args.output / "state-after.json", after)
    write_json(args.output / "settling.json", samples)
    grade_extension(args, before, after, expected)
    final = invoke(args, "describe-after", "describe-ui", [], ax=True)
    require(final["context"] == context and bind_state(args, "container-after") == container, "Final context/app binding changed")
    require(read_state(args, context) == after, "State changed during final readback")
    final_nodes = list(walk(final["ax"]["roots"]))
    shift = after["pageOffsetY"] - before["pageOffsetY"] if expected["page"] else 0
    for key, frame in expected["frames"].items():
        actual = rect(exact_node(args, final_nodes, "feature." + key))
        wanted = (frame[0], frame[1] - (shift if key != "mainScroll" else 0), frame[2], frame[3])
        require(actual[0] == wanted[0] and actual[2:] == wanted[2:] and abs(actual[1] - wanted[1]) <= TOLERANCE,
                "Final AX displacement differs: " + key)
    result = {"result": "PASS", "case": args.case, "context": context, "pid": args.pid,
              "observedContacts": 1, "activeWindowTouches": 0, "pageOffsetBefore": before["pageOffsetY"],
              "pageOffsetAfter": after["pageOffsetY"], "panX": after["panX"], "panY": after["panY"],
              "scope": "Settled page displacement" if expected["page"] else "Default preset path and completed pad pan; not horizontal scroll"}
    write_json(args.output / "result.json", result)
    print(json.dumps(result, sort_keys=True))


def verify(args):
    args.output.mkdir(parents=True, exist_ok=False)
    write_json(args.output / "candidate.json", {"axe": str(args.axe), "sha256": hashlib.sha256(args.axe.read_bytes()).hexdigest(), "case": args.case})
    container = bind_state(args, "container-before")
    description = invoke(args, "describe", "describe-ui", [], ax=True)
    context = description["context"]
    before = read_state(args, context)
    write_json(args.output / "state-before.json", before)
    require(before["activeWindowTouches"] == 0 and not before["textFocused"], "Release input and dismiss keyboard")
    time.sleep(0.25)
    require(read_state(args, context) == before, "App is not idle before input")
    if args.case == "point":
        verify_point(args, description, before, container)
        return
    if args.case in ("page-up", "page-down", "preset-scroll-left", "preset-scroll-right"):
        verify_extension(args, description, before, container)
        return
    center, frame, capacity = geometry(args, description, before)
    for start, end in expected_paths(args.case, *center):
        require(contains(frame, start) and contains(frame, end), "Gesture path is clipped")
    verb, extra, counter = make_command(args, *center)
    receipt = invoke(args, args.case, verb, extra)
    require(receipt["context"] == context, "Context changed between lookup and action")
    deadline, stable_since, anchor = time.monotonic() + 5, None, None
    samples = []
    while True:
        after = read_state(args, context)
        now = time.monotonic()
        effect = (after["counts"].get(counter, 0) > before["counts"].get(counter, 0)) if counter else abs(after["listOffsetY"] - before["listOffsetY"]) > 20
        current = (after["listOffsetY"], after["pageOffsetY"], after["sequence"])
        samples.append({"monotonic": now, "list": current[0], "page": current[1], "sequence": current[2], "active": after["activeWindowTouches"]})
        if after["activeWindowTouches"] == 0 and effect:
            if current != anchor:
                stable_since, anchor = now, current
            if now - stable_since >= 1:
                break
        else:
            stable_since, anchor = None, None
        if now >= deadline:
            write_json(args.output / "state-after.json", after)
            write_json(args.output / "settling.json", samples)
            raise ValueError("No settled app effect; input will not be repeated")
        time.sleep(0.05)
    write_json(args.output / "state-after.json", after)
    write_json(args.output / "settling.json", samples)
    grade(args, before, after, counter, center, frame, capacity)
    final_ax = invoke(args, "describe-after", "describe-ui", [], ax=True)
    require(final_ax["context"] == context and bind_state(args, "container-after") == container, "Final context/app container changed")
    final = read_state(args, context)
    require(final == after, "Guest state changed during final readback")
    identifier = "feature.list" if args.case.startswith("nested-") else "feature.pad"
    final_nodes = list(walk(final_ax["ax"]["roots"]))
    require(rect(exact_node(args, final_nodes, identifier)) == frame, "Target frame changed")
    initial_nodes = list(walk(description["ax"]["roots"]))
    for control in ("feature.mainScroll", "feature.slider", "feature.switch", "feature.text", "feature.tap"):
        require(rect(exact_node(args, final_nodes, control)) == rect(exact_node(args, initial_nodes, control)), "Control/viewport frame changed")
    if capacity is not None:
        shift = after["listOffsetY"] - before["listOffsetY"]
        for i in range(1, 31):
            key = "feature.row.%02d" % i
            a, b = rect(exact_node(args, initial_nodes, key)), rect(exact_node(args, final_nodes, key))
            require(near((b[0], b[1]), (a[0], a[1] - shift)) and b[2:] == a[2:], "List offset/visible AX displacement differs")
    result = {"result": "PASS", "case": args.case, "context": context, "pid": args.pid,
              "stateFile": str(args.state_file), "activeWindowTouches": 0, "observedContacts": len(expected_paths(args.case, *center)),
              "counter": counter, "before": before["counts"].get(counter, 0) if counter else before["listOffsetY"],
              "after": after["counts"].get(counter, 0) if counter else after["listOffsetY"]}
    write_json(args.output / "result.json", result)
    print(json.dumps(result, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--axe", type=pathlib.Path, required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--screen-id", type=int, required=True)
    parser.add_argument("--screen-uuid", required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--rotation", type=int, choices=(0, 90, 180, 270), required=True)
    parser.add_argument("--state-file", type=pathlib.Path, required=True)
    parser.add_argument("--case", choices=CASES, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    uuid.UUID(args.udid)
    uuid.UUID(args.screen_uuid)
    args.axe = args.axe.resolve(strict=True)
    if args.pid <= 0 or args.screen_id <= 0:
        parser.error("PID and screen ID must be positive")
    try:
        verify(args)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f"FAIL: {error}\n")


if __name__ == "__main__":
    main()
