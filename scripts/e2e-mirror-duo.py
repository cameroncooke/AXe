#!/usr/bin/env python3
"""End-to-end check of `axe mirror` with an iPhone Duo on both sides.

One iPhone Duo simulator hosts and runs the AXe Playground. A second iPhone Duo simulator runs the
AXe Mirror app, which AXe drives. Folding and turning the viewer is done with `axe hinge set` and
`axe rotate` on it, which the app sees as its own hinge and screen.

What it proves, in order:
  1. the host finds both of the Duo's screens, and a tap on the flat picture lands
  2. Fold turns the picture into the 3D Duo, and touches then move the Duo, not the simulator
  3. closed, a drag to the left opens it, and the host folds to an angle in between
  4. the Open button opens the host, which lights its inner screen; a couple of seconds later the
     flat picture is back, and a tap lands on the inner screen
  5. pushing the halves together closes the host on its outer screen; Done goes straight back to the
     flat picture; two fingers spread apart open it flat; the Closed button closes it
  6. the viewer's own Duo stood on a table still gives the laptop layout with the trackpad, and
     folding the viewer does not fold the host

It uses its own host key and viewer list in a temporary folder and makes two simulators of its own,
which it deletes when it ends. It needs the internet: pairing goes through a relay. It needs an
iOS runtime that supports the iPhone Duo.

Usage: scripts/e2e-mirror-duo.py        (not part of `make e2e`; run it by hand)

Environment (all optional):
  AXE_BIN_PATH                     the axe to test (default: the SwiftPM debug build, built first)
  AXE_MIRROR_E2E_VIEWER_APP        a built "AXe Mirror.app" for the simulator (default: built here)
  AXE_MIRROR_E2E_PLAYGROUND_APP    a built AxePlayground.app for the simulator (default: built here)
  AXE_MIRROR_E2E_KEEP              set to 1 to keep the simulators and the temporary folder
"""

import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("e2e_mirror", os.path.join(ROOT, "scripts", "e2e-mirror.py"))
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

DUO_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"


def duo_runtime():
    """The newest iOS runtime that can run the iPhone Duo."""
    runtimes = json.loads(e2e.run(["xcrun", "simctl", "list", "runtimes", "available", "-j"]).stdout)["runtimes"]
    able = [r for r in runtimes if r.get("platform") == "iOS" and any(t.get("identifier") == DUO_TYPE for t in r.get("supportedDeviceTypes", []))]
    if not able:
        raise RuntimeError("no installed iOS runtime supports the iPhone Duo")
    return sorted(able, key=lambda r: [int(p) for p in r["version"].split(".")])[-1]["identifier"]


def displays(axe, udid):
    done = e2e.run([axe, "--output", "json", "displays", "--udid", udid], check=False)
    try:
        return json.loads(done.stdout)["data"]["result"]
    except (ValueError, KeyError):
        return {}


def main():
    work = tempfile.mkdtemp(prefix="axe-mirror-duo-e2e.")
    print(f"Working folder: {work}", flush=True)
    axe = os.environ.get("AXE_BIN_PATH")
    if not axe:
        e2e.run(["swift", "build"], cwd=ROOT, timeout=3600)
        axe = os.path.join(e2e.run(["swift", "build", "--show-bin-path"], cwd=ROOT).stdout.strip(), "axe")
    viewer_app = os.environ.get("AXE_MIRROR_E2E_VIEWER_APP") or e2e.build_app("AXeMirror", "AXeMirror", "AXe Mirror.app", work)
    playground_app = os.environ.get("AXE_MIRROR_E2E_PLAYGROUND_APP") or e2e.build_app("AxePlaygroundApp", "AxePlayground", "AxePlayground.app", work)

    runtime = duo_runtime()
    host_udid = e2e.run(["xcrun", "simctl", "create", "AXe E2E Mirror Duo Host", DUO_TYPE, runtime]).stdout.strip()
    # With AXE_E2E_RECORD the viewer is an iPhone: the simulator's recorder cannot record a Duo, and
    # AXe's own holds the simulator's input while it records. The steps after the recording, which
    # fold the viewer itself, then fail.
    viewer_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" if os.environ.get("AXE_E2E_RECORD") else DUO_TYPE
    viewer_udid = e2e.run(["xcrun", "simctl", "create", "AXe E2E Mirror Duo Viewer", viewer_type, runtime]).stdout.strip()
    e2e.scratch.extend([host_udid, viewer_udid])
    for udid in (host_udid, viewer_udid):
        e2e.boot(udid)
    # A display read in the first seconds after boot can wedge the Duo's accessibility for that boot.
    time.sleep(15)
    host, viewer = e2e.Simulator(axe, host_udid), e2e.Simulator(axe, viewer_udid)

    def host_is(role, orientation):
        active = displays(axe, host_udid).get("activeScreen") or {}
        return active.get("role") == role and active.get("orientation") == orientation

    def host_state():
        found = displays(axe, host_udid)
        active = found.get("activeScreen") or {}
        return f"{active.get('role')} {active.get('orientation')}, hinge {(found.get('hinge') or {}).get('degrees')}"

    def viewer_hinge(value):
        e2e.run([axe, "hinge", "set", str(value), "--udid", viewer_udid], check=False)

    def shot(name):
        e2e.run([axe, "screenshot", "--udid", viewer_udid, "--output", os.path.join(work, f"viewer-{name}.png")], check=False)

    taps = [0]

    def tap_picture(label):
        width, height = viewer.screen()
        # Each tap at a fresh point: the Playground's marker by a tap takes a later tap on it.
        x, y = width * (0.42 + 0.03 * taps[0]), height * (0.30 + 0.02 * taps[0])
        taps[0] += 1
        before = e2e.tap_count(host)
        viewer.axe_run("tap", "-x", f"{x:.0f}", "-y", f"{y:.0f}")
        try:
            e2e.wait_for(f"the tap ({label})", lambda: e2e.tap_count(host) > before, 10)
            e2e.passed(f"a tap on the picture lands ({label})", f"host {e2e.last_tap(host)}")
        except TimeoutError:
            e2e.failed(f"a tap on the picture lands ({label})", f"tap count stayed {before}")

    e2e.run(["xcrun", "simctl", "install", host_udid, playground_app])
    e2e.run(["xcrun", "simctl", "install", viewer_udid, viewer_app])
    e2e.run(["xcrun", "simctl", "launch", host_udid, e2e.PLAYGROUND_BUNDLE, "--launch-arg", "screen=tap-test"])
    viewer_hinge("open")
    e2e.run(["xcrun", "simctl", "launch", viewer_udid, e2e.VIEWER_BUNDLE])
    time.sleep(3)
    # A screen's rotation settles a moment after it lights; the viewer starts upright.
    for _ in range(5):
        active = displays(axe, viewer_udid).get("activeScreen") or {}
        if active.get("orientation") == "portrait":
            time.sleep(2)
            if (displays(axe, viewer_udid).get("activeScreen") or {}).get("orientation") == "portrait":
                break
            continue
        e2e.run([axe, "rotate", "left" if active.get("rotation") == 90 else "right", "--udid", viewer_udid], check=False)
        time.sleep(2)

    key, viewers = os.path.join(work, "host.key"), os.path.join(work, "viewers.json")
    identity = ["--key-file", key, "--viewers-file", viewers]
    pair_log = os.path.join(work, "pair.log")
    pairing = e2e.start([axe, "mirror", "pair", "--json", "--name", "Duo E2E Mac", *identity], pair_log, os.path.join(work, "pair.err"))
    code = e2e.wait_for("the pairing code", lambda: e2e.event(pair_log, "code"), 40)["code"]
    viewer.tap_id("home.pair")
    viewer.tap_id("pair.code")
    viewer.axe_run("type", code)
    viewer.tap_id("pair.submit")
    e2e.wait_for("the viewer to pair", lambda: e2e.event(pair_log, "paired"), 40)
    pairing.wait(timeout=15)
    viewer.tap_label("Done")

    host_log, host_err = os.path.join(work, "host.log"), os.path.join(work, "host.err")
    e2e.start([axe, "mirror", "--udid", host_udid, "--no-builds", *identity], host_log, host_err)
    e2e.wait_for("the host to be ready", lambda: e2e.event(host_log, "ready"), 60)
    viewer.tap_id("home.connect")
    e2e.wait_for("the stream to start", lambda: e2e.event(host_log, "streaming"), 40)
    time.sleep(4)

    # 1. Both screens; the flat picture takes touches.
    e2e.check("the host finds both of the Duo's screens", "two screens" in e2e.text_of(host_err))
    viewer_hinge("open")
    time.sleep(3)
    tap_picture("flat picture")

    def picture_frame():
        node = viewer.find(identifier="stream.picture") or viewer.find(label="Simulator screen") or {}
        frame = node.get("frame") or {}
        return float(frame.get("x", 0)), float(frame.get("y", 0)), float(frame.get("width", 0)), float(frame.get("height", 0))

    def folded_after(seen, posture=None):
        return next((e for e in e2e.events(host_log)[seen:] if e.get("event") == "folded" and (posture is None or e.get("posture") == posture)), None)

    def drag(x0, y0, x1, y1):
        # A swipe must stay on the viewer's screen; one that ends past its edge is refused.
        width, height = viewer.screen()
        x0, x1 = (max(8, min(width - 8, v)) for v in (x0, x1))
        y0, y1 = (max(8, min(height - 8, v)) for v in (y0, y1))
        # A loaded Mac can make the viewer's input refuse a swipe now and then; it is tried again.
        for attempt in range(3):
            try:
                viewer.axe_run("swipe", "--start-x", f"{x0:.0f}", "--start-y", f"{y0:.0f}", "--end-x", f"{x1:.0f}", "--end-y", f"{y1:.0f}", "--duration", "0.6")
                return
            except RuntimeError as error:
                if attempt == 2 or "refused" not in str(error):
                    raise
                time.sleep(2)

    def enter_fold():
        """Shows the 3D Duo, unless it is up already: it goes back to the picture by itself."""
        if viewer.find(identifier="stream.foldModel") is None:
            viewer.tap_id("stream.fold")
            e2e.wait_for("the 3D Duo", lambda: viewer.find(identifier="stream.foldModel"), 10)
            time.sleep(1)

    def tap_fold_button(identifier):
        """Taps one of the buttons under the 3D Duo. The Duo goes back to the picture a second and
        a half after the last touch, which can be between looking for it and tapping: once more."""
        for attempt in range(3):
            enter_fold()
            try:
                viewer.tap_id(identifier)
                return
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(1)

    def back_to_picture(seconds=20):
        e2e.wait_for("the flat picture to come back", lambda: viewer.find(identifier="stream.foldModel") is None, seconds)
        time.sleep(2)

    def expect_fold(name, posture, seen, lit=None):
        """Waits for the host to finish a fold to `posture` and, with `lit`, to light that screen."""
        try:
            e2e.wait_for(f"the host to fold ({posture})", lambda: folded_after(seen, posture), 40)
            if lit:
                e2e.wait_for(f"the {lit} screen", lambda: host_is(lit, "landscape") or host_is(lit, "portrait"), 30)
            e2e.passed(name, host_state())
        except TimeoutError:
            e2e.failed(name, host_state())

    # The host starts closed, as a new Duo simulator boots.
    seen = len(e2e.events(host_log))
    e2e.run([axe, "hinge", "set", "closed", "--udid", host_udid], check=False)
    e2e.wait_for("the host closed", lambda: host_is("outer", "portrait") or host_is("outer", "landscape"), 30)
    time.sleep(3)

    # 2. Fold mode: the 3D Duo, and touches move it.
    x, y, w, h = picture_frame()
    enter_fold()
    shot("fold-mode-closed")
    e2e.passed("Fold turns the picture into the 3D Duo")
    before = e2e.tap_count(host)
    # Beside the Duo, on what was the picture's room: a tap on the closed Duo itself would open it.
    viewer.axe_run("tap", "-x", f"{max(12, x - 30):.0f}", "-y", f"{y + h * 0.5:.0f}")
    time.sleep(2)
    e2e.check("while folding, a touch moves the Duo and does not reach the simulator", e2e.tap_count(host) == before)

    # 3. Closed, a drag either way opens it: this one goes to the left, which a book's cover would not.
    seen = len(e2e.events(host_log))
    drag(x + w * 0.5, y + h * 0.5, x + w * 0.5 - w * 0.25, y + h * 0.5)
    shot("folding-part-open")
    # Shown with its hinge upright, the Duo is folded like a book: half open, its inner screen lit and wide.
    e2e.wait_for("the host to fold like a book", lambda: folded_after(seen, "book"), 60)
    time.sleep(2)
    degrees = (displays(axe, host_udid).get("hinge") or {}).get("degrees", 0)
    e2e.check("closed, a drag to the left opens the host part way, its inner screen lit", 20 <= degrees <= 170 and host_is("inner", "landscape"), host_state())
    shot("part-open-lit")

    # 3b. The 3D Duo rests only where a screen is in use: closed, or open from 90 degrees. Below 90
    # iOS lights the outer screen, facing away (22 November 2026). Let go between, it goes to the
    # nearer: about 50 to 75 degrees goes on to half open, with the host's inner screen lit, and a
    # quarter of the width is about 90. The host is never left part open on its outer screen.
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.0")
    expect_fold("the Closed button closes the host", "closed", seen, lit="outer")
    time.sleep(2)
    enter_fold()
    seen = len(e2e.events(host_log))
    drag(x + w * 0.5, y + h * 0.5, x + w * 0.5 - w * 0.22, y + h * 0.5)
    time.sleep(0.5)
    print(f"note: the 3D Duo after the short drag: {(viewer.find(identifier='stream.foldModel') or {}).get('AXValue')}", flush=True)
    try:
        e2e.wait_for("the host to fold like a book", lambda: folded_after(seen, "book"), 60)
        e2e.wait_for("the inner screen", lambda: host_is("inner", "landscape"), 15)
        degrees = (displays(axe, host_udid).get("hinge") or {}).get("degrees", 0)
        e2e.check("closed, a short drag opens the host to half open, its inner screen lit", 88 <= degrees <= 170, host_state())
    except TimeoutError:
        e2e.failed("closed, a short drag opens the host to half open, its inner screen lit", host_state())

    # 4. The Open button; the simulator's inner screen is on the 3D Duo before it goes back to the picture.
    enter_fold()
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.180")
    expect_fold("the Open button opens the host, which lights its inner screen", "open", seen, lit="inner")
    shot("opened-by-button")
    back_to_picture()
    e2e.passed("the flat picture comes back by itself after folding")
    # The simulator is turned to fit the viewer's room as part of the fold, not a moment after
    # the picture is back: nothing turns once the picture is there.
    seen = len(e2e.events(host_log))
    time.sleep(8)
    late = [e for e in e2e.events(host_log)[seen:] if e.get("event") == "rotated"]
    x, y, w, h = picture_frame()
    width, height = viewer.screen()
    e2e.check("opened flat, the simulator already fits the room: nothing turns after the picture is back",
              not late and (w > h) == (width > height), f"{host_state()}; picture {w:.0f}x{h:.0f} in {width:.0f}x{height:.0f}")
    tap_picture("open, inner screen")
    said = (viewer.find(identifier="stream.screen") or {}).get("AXLabel") or ""
    e2e.check("the app says which screen is lit and that it is open", "Inner" in said and "Open" in said, said)

    # 4b. Folded part way down from flat, the Duo still ends where a screen is in use.
    x, y, w, h = picture_frame()
    enter_fold()
    seen = len(e2e.events(host_log))
    if w >= h:
        drag(x + w * 0.85, y + h * 0.5, x + w * 0.52, y + h * 0.5)
    else:
        drag(x + w * 0.5, y + h * 0.15, x + w * 0.5, y + h * 0.45)
    time.sleep(0.5)
    print(f"note: the 3D Duo after folding part way down: {(viewer.find(identifier='stream.foldModel') or {}).get('AXValue')}", flush=True)
    try:
        e2e.wait_for("the host to fold", lambda: folded_after(seen), 40)
        time.sleep(4)
        found = displays(axe, host_udid)
        role = (found.get("activeScreen") or {}).get("role")
        degrees = (found.get("hinge") or {}).get("degrees", 0)
        usable = (role == "outer" and degrees <= 5) or (role == "inner" and degrees >= 88)
        e2e.check("folded part way down, the host ends closed or open on its inner screen, never part open on its outer one", usable, host_state())
    except TimeoutError:
        e2e.failed("folded part way down, the host ends closed or open on its inner screen, never part open on its outer one", host_state())
    enter_fold()
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.180")
    expect_fold("and the Open button opens it flat again", "open", seen, lit="inner")
    back_to_picture()

    # 5. Pushing the halves together closes it; Done goes back at once.
    x, y, w, h = picture_frame()
    enter_fold()
    seen = len(e2e.events(host_log))
    # The halves are side by side when the picture is wide, and one above the other when it is tall.
    if w >= h:
        drag(x + w * 0.85, y + h * 0.5, x + w * 0.40, y + h * 0.5)
    else:
        drag(x + w * 0.5, y + h * 0.15, x + w * 0.5, y + h * 0.60)
    expect_fold("pushing the halves together closes the host on its outer screen", "closed", seen, lit="outer")
    shot("folded-closed")
    back_to_picture()
    tap_picture("closed, outer screen")
    said = (viewer.find(identifier="stream.screen") or {}).get("AXLabel") or ""
    e2e.check("and that it is closed, on its outer screen", "Outer" in said and "Closed" in said, said)
    shot("closed-flat")
    enter_fold()
    viewer.tap_id("stream.fold")
    try:
        e2e.wait_for("Done to put the flat picture back", lambda: viewer.find(identifier="stream.foldModel") is None, 5)
        e2e.passed("Done goes straight back to the flat picture")
    except TimeoutError:
        e2e.failed("Done goes straight back to the flat picture", "the 3D Duo stayed")

    # 5b. Two fingers spread apart open it the whole way; the Closed button closes it.
    enter_fold()
    seen = len(e2e.events(host_log))
    width, height = viewer.screen()
    for attempt in range(3):
        done = viewer.axe_run("gesture", "pinch", "--scale", "3", "-x", f"{width / 2:.0f}", "-y", f"{height / 2:.0f}", "--radius", "60", check=False)
        if done.returncode == 0:
            break
        time.sleep(2)
    expect_fold("spreading two fingers opens it flat, and the host lights its inner screen", "open", seen, lit="inner")
    # With AXE_E2E_RECORD set to a file, the viewer's screen is recorded from here to the end of
    # this step, to look at how the 3D Duo moves between its buttons.
    recording = None
    if os.environ.get("AXE_E2E_RECORD"):
        recording = subprocess.Popen(["xcrun", "simctl", "io", viewer_udid, "recordVideo", "--codec", "h264", "--force", os.environ["AXE_E2E_RECORD"]],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
    enter_fold()
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.0")
    expect_fold("the Closed button closes the host", "closed", seen, lit="outer")
    enter_fold()
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.180")
    expect_fold("and the Open button opens it again", "open", seen, lit="inner")
    # Shut after standing half open, iOS often leaves the inner screen lit and the outer one dark
    # (32 of 40 tries, 21 November 2026); the host must light the outer one all the same.
    enter_fold()
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.90")
    e2e.wait_for("the host to fold half open", lambda: folded_after(seen), 40)
    # Folded down from flat to 90 degrees iOS can light the outer screen; the host lights the inner.
    try:
        e2e.wait_for("the inner screen", lambda: host_is("inner", "landscape") or host_is("inner", "portrait"), 15)
        e2e.passed("Half open from flat lights the host's inner screen", host_state())
    except TimeoutError:
        e2e.failed("Half open from flat lights the host's inner screen", host_state())
    time.sleep(2.5)
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.0")
    expect_fold("shut from half open, the host lights its outer screen", "closed", seen, lit="outer")
    enter_fold()
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.180")
    expect_fold("and it opens flat again from there", "open", seen, lit="inner")
    back_to_picture()
    if recording:
        recording.send_signal(signal.SIGINT)
        recording.wait(timeout=30)

    # 5c. A Duo shut by something else, with its inner screen left lit, is put right by the host.
    # It is shut here with `axe hinge`, after standing half open, as an agent might.
    def active_role():
        return (displays(axe, host_udid).get("activeScreen") or {}).get("role")
    # iOS does not leave the inner screen lit every time, so it is tried up to five times; the
    # screens are read a third of a second after the hinge shuts, before the host has acted. It
    # did so on the home screen in 27 of 27 tries and with an app in front in none of 5, so the
    # home screen is brought up first.
    e2e.run([axe, "button", "home", "--udid", host_udid], check=False)
    time.sleep(2)
    left_lit = None
    for attempt in range(5):
        e2e.run([axe, "hinge", "set", "100", "--udid", host_udid], check=False)
        time.sleep(1.5)
        e2e.run([axe, "hinge", "set", "0", "--no-wait", "--udid", host_udid], check=False)
        time.sleep(0.35)
        left_lit = active_role()
        if left_lit == "inner":
            break
        time.sleep(1.5)
    try:
        e2e.wait_for("the host to light the outer screen", lambda: active_role() == "outer", 10)
        mended = any("shut with its inner screen lit" in line for line in open(os.path.join(work, "host.err"), errors="replace"))
        e2e.passed("shut from outside, the outer screen is lit", f"iOS left the {left_lit} screen lit after {attempt + 1} tries; the host {'put it right' if mended else 'had nothing to do'}")
    except TimeoutError:
        e2e.failed("shut from outside, the outer screen is lit", host_state())
    # The app switcher, closed: a look at what the viewer shows.
    time.sleep(1.5)
    try:
        viewer.tap_label("App switcher")
        time.sleep(2)
        shot("closed-switcher")
        e2e.check("closed, the app switcher leaves the outer screen lit", active_role() == "outer", host_state())
        e2e.run([axe, "button", "home", "--udid", host_udid], check=False)
        time.sleep(1.5)
    except Exception as error:
        e2e.failed("closed, the app switcher leaves the outer screen lit", str(error))
    enter_fold()
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.180")
    expect_fold("and it opens from there", "open", seen, lit="inner")
    back_to_picture()

    # 5d. Part open on its outer screen, a Duo keeps it lit when opened further, up to about 150
    # degrees (22 November 2026). Folded down to 60 here, as an agent might, Half open still lights
    # the inner screen.
    e2e.run([axe, "hinge", "set", "60", "--udid", host_udid], check=False)
    try:
        e2e.wait_for("the outer screen at 60 degrees", lambda: active_role() == "outer", 15)
    except TimeoutError:
        print(f"note: folded to 60 degrees, the host kept its {active_role()} screen lit", flush=True)
    time.sleep(2)
    enter_fold()
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.90")
    try:
        e2e.wait_for("the host to fold half open", lambda: folded_after(seen), 40)
        e2e.wait_for("the inner screen", lambda: active_role() == "inner", 15)
        e2e.passed("part open on its outer screen, Half open lights the inner one", host_state())
    except TimeoutError:
        e2e.failed("part open on its outer screen, Half open lights the inner one", host_state())
    enter_fold()
    seen = len(e2e.events(host_log))
    tap_fold_button("stream.fold.180")
    expect_fold("and it opens flat from there", "open", seen, lit="inner")
    back_to_picture()

    # 6. The viewer's own fold lays out the app; it does not fold the host.
    before_hinge = (displays(axe, host_udid).get("hinge") or {}).get("degrees")
    viewer_hinge("tabletop")
    time.sleep(4)
    shot("viewer-tabletop")
    e2e.check("the viewer stood on a table shows the trackpad", viewer.find(label="Trackpad") is not None)
    # The 3D Duo in the half of the screen the picture has there, for a look at it.
    try:
        enter_fold()
        shot("viewer-tabletop-fold")
        viewer.tap_id("stream.fold")
        back_to_picture()
    except Exception as error:
        print(f"note: could not show the 3D Duo on the tabletop viewer: {error}", flush=True)
    after_hinge = (displays(axe, host_udid).get("hinge") or {}).get("degrees")
    e2e.check("folding the viewer does not fold the host", before_hinge is not None and after_hinge is not None and abs(after_hinge - before_hinge) < 5,
              f"{before_hinge} then {after_hinge}")

    # 7. On the viewer's small outer screen the fold buttons stay clear of the 3D Duo.
    viewer_hinge("closed")
    time.sleep(6)
    try:
        enter_fold()
        time.sleep(1)
        shot("fold-mode-small")
        e2e.check("the fold buttons are there on a small screen", viewer.find(identifier="stream.fold.180") is not None)
    except Exception as error:
        e2e.failed("the fold buttons are there on a small screen", str(error))

    for child in list(e2e.children):
        e2e.stop(child)
    e2e.children.clear()
    keep = os.environ.get("AXE_MIRROR_E2E_KEEP") == "1"
    if keep:
        print(f"Kept {host_udid}, {viewer_udid} and {work}", flush=True)
    else:
        for udid in e2e.scratch:
            e2e.delete(udid)
        shutil.rmtree(work, ignore_errors=True)
    passed = sum(1 for ok, _ in e2e.results if ok)
    print(f"\n{passed} of {len(e2e.results)} checks passed", flush=True)
    return 0 if passed == len(e2e.results) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:      # a step that could not run: report it, clean up, fail
        print(f"FAIL  {error}", flush=True)
        for child in list(e2e.children):
            e2e.stop(child)
        if os.environ.get("AXE_MIRROR_E2E_KEEP") != "1":
            for udid in e2e.scratch:
                e2e.delete(udid)
        sys.exit(1)
