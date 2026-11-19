#!/usr/bin/env python3
"""End-to-end check of `axe mirror` with the real AXe Mirror app.

Two simulators on this Mac play the two parts. One is the host's simulator and runs the AXe
Playground. The other runs the AXe Mirror app, which AXe itself drives: it types the pairing code,
opens the stream and taps the picture. The check then reads the Playground on the host's simulator
to see that the taps arrived, and reads the host's events for everything else.

What it proves, in order:
  1. pairing with a typed code, and that the viewer is then listed
  2. a paired viewer connects and the host streams to it
  3. taps on the picture arrive on the host's simulator, in the right place relative to each other
  4. an unpaired viewer is refused
  5. a demo host keeps its visitor inside the sample app (another app in front is replaced)

It uses its own host key and viewer list in a temporary folder, so this Mac's real pairing is not
touched, and it never contacts the public demo. It needs the internet: pairing goes through a relay.

Usage: scripts/e2e-mirror.py            (not part of `make e2e`; run it by hand)

Environment (all optional):
  AXE_BIN_PATH                     the axe to test (default: the SwiftPM debug build, built first)
  AXE_MIRROR_E2E_HOST_UDID         host simulator (default: "AXe E2E Mirror Host", created if missing)
  AXE_MIRROR_E2E_VIEWER_UDID       viewer simulator (default: "AXe E2E Mirror Viewer", created if missing)
  AXE_MIRROR_E2E_VIEWER_APP        a built "AXe Mirror.app" for the simulator (default: built here)
  AXE_MIRROR_E2E_PLAYGROUND_APP    a built AxePlayground.app for the simulator (default: built here)
  AXE_MIRROR_E2E_KEEP              set to 1 to keep the temporary folder with the logs
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VIEWER_BUNDLE = "com.cameroncooke.axemirror"
PLAYGROUND_BUNDLE = "com.cameroncooke.AxePlayground"
MAC_NAME = "E2E Mac"
results = []
children = []


def run(args, check=True, timeout=600, **kwargs):
    done = subprocess.run(args, capture_output=True, text=True, timeout=timeout, **kwargs)
    if check and done.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:6])} failed ({done.returncode}): {done.stderr.strip()[-600:]}")
    return done


def passed(name, detail=""):
    results.append((True, name))
    print(f"PASS  {name}" + (f" ({detail})" if detail else ""), flush=True)


def failed(name, detail=""):
    results.append((False, name))
    print(f"FAIL  {name}" + (f": {detail}" if detail else ""), flush=True)


def check(name, condition, detail=""):
    (passed if condition else failed)(name, detail)
    return condition


def wait_for(description, probe, seconds=30.0, every=0.25):
    """Calls `probe` until it returns something true; raises when the time is up."""
    end = time.time() + seconds
    while time.time() < end:
        value = probe()
        if value:
            return value
        time.sleep(every)
    raise TimeoutError(f"timed out after {seconds:.0f} s waiting for {description}")


def events(path):
    found = []
    try:
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if line.startswith("{"):
                    try:
                        found.append(json.loads(line))
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return found


def event(path, name, after=0):
    return next((item for item in events(path)[after:] if item.get("event") == name), None)


def text_of(path):
    try:
        with open(path, errors="replace") as handle:
            return handle.read()
    except FileNotFoundError:
        return ""


# MARK: Simulators and apps

def simulator(name, env):
    """The UDID in `env`, or of the simulator called `name`, which is created when missing."""
    if os.environ.get(env):
        return os.environ[env]
    listing = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"]).stdout)
    for devices in listing["devices"].values():
        for device in devices:
            if device["name"] == name:
                return device["udid"]
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "available", "-j"]).stdout)["runtimes"]
    ios = sorted((r for r in runtimes if r.get("platform") == "iOS"), key=lambda r: [int(p) for p in r["version"].split(".")])
    if not ios:
        raise RuntimeError("no iOS simulator runtime is installed")
    types = [t["identifier"] for t in ios[-1].get("supportedDeviceTypes", []) if t.get("productFamily") == "iPhone"]
    preferred = [t for t in types if t.endswith(("iPhone-17", "iPhone-17-Pro", "iPhone-16"))] or types
    if not preferred:
        raise RuntimeError("the newest iOS runtime supports no iPhone simulator")
    return run(["xcrun", "simctl", "create", name, preferred[0], ios[-1]["identifier"]]).stdout.strip()


def boot(udid):
    run(["xcrun", "simctl", "boot", udid], check=False)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=300)


def build_app(spec_folder, scheme, product, work):
    """Generates the Xcode project from its XcodeGen spec and builds it for the simulator."""
    project = os.path.join(work, scheme + "-project")
    os.makedirs(project, exist_ok=True)
    run(["xcodegen", "generate", "--spec", os.path.join(ROOT, spec_folder, "project.yml"), "--project", project])
    derived = os.path.join(work, scheme + "-build")
    run(["xcodebuild", "-project", os.path.join(project, scheme + ".xcodeproj"), "-scheme", scheme, "-configuration", "Debug",
         "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO", "build"], timeout=1800)
    app = os.path.join(derived, "Build/Products/Debug-iphonesimulator", product)
    if not os.path.isdir(app):
        raise RuntimeError(f"{product} was not built")
    return app


# MARK: Reading and driving a simulator with AXe

class Simulator:
    def __init__(self, axe, udid):
        self.axe, self.udid = axe, udid

    def axe_run(self, *args, check=True):
        return run([self.axe, *args, "--udid", self.udid], check=check, timeout=60)

    def tree(self):
        done = self.axe_run("describe-ui", check=False)
        try:
            return json.loads(done.stdout)
        except ValueError:
            return []

    def find(self, identifier=None, label=None):
        def walk(node):
            if isinstance(node, list):
                for child in node:
                    hit = walk(child)
                    if hit:
                        return hit
                return None
            if identifier and node.get("AXUniqueId") == identifier:
                return node
            if label and label in (node.get("AXLabel") or ""):
                return node
            return walk(node.get("children") or [])
        return walk(self.tree())

    def value(self, identifier):
        node = self.find(identifier=identifier)
        return None if node is None else node.get("AXValue")

    def tap_id(self, identifier, seconds=20):
        wait_for(f"the control {identifier}", lambda: self.find(identifier=identifier), seconds)
        self.axe_run("tap", "--id", identifier)

    def tap_label(self, label, seconds=20):
        wait_for(f"the control labelled {label}", lambda: self.find(label=label), seconds)
        self.axe_run("tap", "--label", label)

    def screen(self):
        tree = self.tree()
        root = tree[0] if isinstance(tree, list) and tree else tree
        frame = root.get("frame") or {}
        return float(frame.get("width", 0)), float(frame.get("height", 0))


def start(args, out, err):
    child = subprocess.Popen(args, stdout=open(out, "w"), stderr=open(err, "w"))
    children.append(child)
    return child


def stop(child, seconds=10):
    if child.poll() is None:
        child.send_signal(signal.SIGINT)
        try:
            child.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            child.kill()
    return child.returncode


def tap_count(host):
    """The Playground's "Tap Count: 3" as a number. The screen's own identifier covers its children
    in the tree, so the readouts are found by their text."""
    node = host.find(label="Tap Count:")
    return int(node["AXLabel"].split(":")[1]) if node else 0


def last_tap(host):
    """The Playground's "Tap Location: (120, 340)" as a pair of numbers."""
    node = host.find(label="Tap Location:")
    inside = node["AXLabel"].split("(")[1].rstrip(")")
    x, y = (float(part) for part in inside.split(","))
    return x, y


def main():
    work = tempfile.mkdtemp(prefix="axe-mirror-e2e.")
    print(f"Working folder: {work}", flush=True)
    axe = os.environ.get("AXE_BIN_PATH")
    if not axe:
        run(["swift", "build"], cwd=ROOT, timeout=3600)
        axe = os.path.join(run(["swift", "build", "--show-bin-path"], cwd=ROOT).stdout.strip(), "axe")
    viewer_app = os.environ.get("AXE_MIRROR_E2E_VIEWER_APP") or build_app("AXeMirror", "AXeMirror", "AXe Mirror.app", work)
    playground_app = os.environ.get("AXE_MIRROR_E2E_PLAYGROUND_APP") or build_app("AxePlaygroundApp", "AxePlayground", "AxePlayground.app", work)

    host_udid = simulator("AXe E2E Mirror Host", "AXE_MIRROR_E2E_HOST_UDID")
    viewer_udid = simulator("AXe E2E Mirror Viewer", "AXE_MIRROR_E2E_VIEWER_UDID")
    for udid in (host_udid, viewer_udid):
        boot(udid)
    host, viewer = Simulator(axe, host_udid), Simulator(axe, viewer_udid)
    run(["xcrun", "simctl", "install", host_udid, playground_app])
    # A fresh copy of the viewer has no identity and no paired Macs.
    run(["xcrun", "simctl", "uninstall", viewer_udid, VIEWER_BUNDLE], check=False)
    run(["xcrun", "simctl", "install", viewer_udid, viewer_app])
    run(["xcrun", "simctl", "launch", "--terminate-running-process", host_udid, PLAYGROUND_BUNDLE, "--launch-arg", "screen=tap-test"])
    run(["xcrun", "simctl", "launch", "--terminate-running-process", viewer_udid, VIEWER_BUNDLE])

    key, viewers = os.path.join(work, "host.key"), os.path.join(work, "viewers.json")
    identity = ["--key-file", key, "--viewers-file", viewers]

    # 1. Pairing with a typed code.
    pair_log = os.path.join(work, "pair.log")
    pairing = start([axe, "mirror", "pair", "--json", "--name", MAC_NAME, *identity], pair_log, os.path.join(work, "pair.err"))
    code = wait_for("the pairing code", lambda: event(pair_log, "code"), 40)["code"]
    viewer.tap_id("home.pair")
    viewer.tap_id("pair.code")
    viewer.axe_run("type", code)
    viewer.tap_id("pair.submit")
    paired = wait_for("the viewer to pair", lambda: event(pair_log, "paired"), 40)
    pairing.wait(timeout=15)
    listed = json.loads(run([axe, "mirror", "viewers", "--json", "--viewers-file", viewers]).stdout)["viewers"]
    check("a viewer pairs with a typed code and is listed", len(listed) == 1 and listed[0]["id"] == paired["viewer"], paired.get("name", ""))
    viewer.tap_label("Done")

    # 2. The paired viewer connects and the host streams.
    host_log, host_err = os.path.join(work, "host.log"), os.path.join(work, "host.err")
    hosting = start([axe, "mirror", "--udid", host_udid, *identity], host_log, host_err)
    ready = wait_for("the host to be ready", lambda: event(host_log, "ready"), 60)
    viewer.tap_label(MAC_NAME)
    wait_for("the viewer to connect", lambda: event(host_log, "viewerConnected"), 40)
    streaming = wait_for("the stream to start", lambda: event(host_log, "streaming"), 40)
    path = wait_for("a path event", lambda: event(host_log, "path"), 20)
    check("a paired viewer connects and the host streams", int(streaming["width"]) > 0 and int(streaming["height"]) > 0,
          f"{streaming['width']}x{streaming['height']}, {path['kind']} path")
    time.sleep(1.0)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-arrival.png")], check=False)

    # 3. Taps on the picture arrive on the host's simulator. The picture's exact place in the app is
    # not needed: two taps a known distance apart must arrive the same way apart, scaled.
    time.sleep(2.0)     # the first picture
    width, height = viewer.screen()
    first, second = (width / 2 - 30, height / 2), (width / 2 + 30, height / 2 + 80)
    before = tap_count(host)
    viewer.axe_run("tap", "-x", str(first[0]), "-y", str(first[1]))
    wait_for("the first tap to arrive", lambda: tap_count(host) == before + 1, 15)
    a = last_tap(host)
    viewer.axe_run("tap", "-x", str(second[0]), "-y", str(second[1]))
    wait_for("the second tap to arrive", lambda: tap_count(host) == before + 2, 15)
    b = last_tap(host)
    dx, dy = b[0] - a[0], b[1] - a[1]
    ratio = dy / dx if dx else 0
    check("taps on the picture arrive on the host's simulator, in proportion", dx > 20 and dy > 20 and 1.0 < ratio < 1.75,
          f"host saw ({a[0]:.0f}, {a[1]:.0f}) then ({b[0]:.0f}, {b[1]:.0f}); moved {dx:.0f}, {dy:.0f} for 60, 80 in the app")

    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-live.png")], check=False)

    # 3b. A viewer that connects again has its first touch taken. The app numbers its gestures from
    # one on every connection, and a host that remembered the last connection's numbers dropped them.
    viewer.tap_id("stream.close")
    wait_for("the list of Macs", lambda: viewer.find(label="Your Macs"), 15)
    time.sleep(1.0)     # the stream screen is still sliding away
    seen = len(events(host_log))
    viewer.tap_label(MAC_NAME)
    wait_for("the viewer to connect again", lambda: event(host_log, "streaming", after=seen), 40)
    time.sleep(2.0)     # the first picture
    before = tap_count(host)
    viewer.axe_run("tap", "-x", str(first[0]), "-y", str(first[1]))
    arrived = True
    try:
        wait_for("the first tap after connecting again", lambda: tap_count(host) == before + 1, 10)
    except Exception:
        arrived = False
    check("the first tap after connecting again arrives", arrived, f"tap count {tap_count(host)}, was {before}")

    # 4. An unpaired viewer is refused.
    run([axe, "mirror", "unpair", paired["viewer"][:12], "--viewers-file", viewers])
    viewer.tap_id("stream.close")
    wait_for("the list of Macs", lambda: viewer.find(label="Your Macs"), 15)
    time.sleep(1.0)     # the stream screen is still sliding away
    seen = len(events(host_log))
    viewer.tap_label(MAC_NAME)
    refused = wait_for("the refusal", lambda: event(host_log, "refused", after=seen), 40)
    check("an unpaired viewer is refused", refused.get("viewer") == paired["viewer"], refused.get("reason", ""))
    told = wait_for("the app to say it is no longer paired", lambda: viewer.find(label="no longer paired"), 15)
    check("the app tells an unpaired viewer to pair again", told is not None)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-refused.png")], check=False)
    viewer.tap_id("stream.close")
    code_of_exit = stop(hosting)
    check("the host stops cleanly on Ctrl+C", code_of_exit == 0 and event(host_log, "stopped") is not None, f"exit {code_of_exit}")

    # 5. A demo host keeps its visitor inside the sample app.
    demo_log, demo_err = os.path.join(work, "demo.log"), os.path.join(work, "demo.err")
    demo = start([axe, "mirror", "--udid", host_udid, "--demo", "--demo-app", PLAYGROUND_BUNDLE, "--key-file", os.path.join(work, "demo.key")],
                 demo_log, demo_err)
    demo_ready = wait_for("the demo host to be ready", lambda: event(demo_log, "ready"), 60)
    demo_id = event(demo_log, "endpoint")["hostID"]
    run(["xcrun", "simctl", "launch", "--terminate-running-process", viewer_udid, VIEWER_BUNDLE,
         "-MirrorDemoHost", demo_id, "-MirrorDemoRelay", demo_ready["relay"]])
    viewer.tap_id("home.demo")
    wait_for("the demo to stream", lambda: event(demo_log, "streaming"), 60)
    time.sleep(3.0)     # the sample app has been started afresh and seen in front
    menu = wait_for("the sample app's demo menu", lambda: host.find(label="Gesture Presets"), 20)
    check("a demo visitor gets the sample app's demo mode", menu is not None and host.find(label="Text Input") is None)
    run(["xcrun", "simctl", "launch", host_udid, "com.apple.mobilesafari"])
    wait_for("the lock to notice Safari", lambda: "another app is in front" in text_of(demo_err), 20)
    wait_for("the sample app to come back", lambda: "the sample app is in front again" in text_of(demo_err), 20)
    back = wait_for("the sample app on screen", lambda: host.find(label="Gesture Presets"), 20)
    check("another app in front of a demo is replaced by the sample app", back is not None)
    viewer.tap_id("stream.close")
    stop(demo)

    if os.environ.get("AXE_MIRROR_E2E_KEEP") != "1" and all(ok for ok, _ in results):
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"Logs kept in {work}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:      # a step that could not finish is a failure with its reason
        failed("the run stopped early", str(error))
    finally:
        for child in children:
            stop(child, seconds=5)
    bad = [name for ok, name in results if not ok]
    print(f"{len(results) - len(bad)} passed, {len(bad)} failed.")
    sys.exit(1 if bad or not results else 0)
