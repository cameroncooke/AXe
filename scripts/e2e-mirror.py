#!/usr/bin/env python3
"""End-to-end check of `axe mirror` with the real AXe Mirror app.

Two simulators on this Mac play the two parts. One is the host's simulator and runs the AXe
Playground. The other runs the AXe Mirror app, which AXe itself drives: it types the pairing code,
opens the stream and taps the picture. The check then reads the Playground on the host's simulator
to see that the taps arrived, and reads the host's events for everything else.

What it proves, in order:
  1. pairing with a typed code, and that the viewer is then listed
  2. a paired viewer connects and the host streams to it
  3. taps on the picture arrive on the host's simulator, in the right place relative to each other;
     rotating from the app turns the simulator and the stream, and taps still land the right way round
  4. on a host started without --udid, the app lists the Mac's simulators; a running one opens,
     its ID can be copied, one that is shut down is booted, and a new one is created; Close goes
     back to the list and asks whether to leave the simulator running or shut it down, the list's
     Close leaves the Mac, and a simulator can be deleted
     a simulator deleted on the Mac since the list was read and then chosen is reported in plain
     words, with no tool names
     a second paired viewer connects while the first is connected, and neither takes the other's place
  5. an unpaired viewer is refused
  6. a demo host keeps its visitor inside the sample app (another app in front is replaced)

It uses its own host key and viewer list in a temporary folder, so this Mac's real pairing is not
touched, and it never contacts the public demo. It needs the internet: pairing goes through a relay.
Step 4 makes two simulators of its own and deletes them when the run ends.

Usage: scripts/e2e-mirror.py            (not part of `make e2e`; run it by hand)

Environment (all optional):
  AXE_BIN_PATH                     the axe to test (default: the SwiftPM debug build, built first)
  AXE_MIRROR_E2E_HOST_UDID         host simulator (default: "AXe E2E Mirror Host", created if missing)
  AXE_MIRROR_E2E_VIEWER_UDID       viewer simulator (default: "AXe E2E Mirror Viewer", created if missing);
                                   an iPad here shows the setup video in Picture in Picture, which an
                                   iPhone simulator does not have (see viewer-local-setup-away.png)
  AXE_MIRROR_E2E_VIEWER2_UDID      a second viewer simulator (default: "AXe E2E Mirror Viewer 2", created if missing),
                                   booted for the step with two viewers and shut down after it
  AXE_MIRROR_E2E_VIEWER_APP        a built "AXe Mirror.app" for the simulator (default: built here)
  AXE_MIRROR_E2E_PLAYGROUND_APP    a built AxePlayground.app for the simulator (default: built here)
  AXE_MIRROR_E2E_KEEP              set to 1 to keep the temporary folder with the logs
"""

import base64
import hashlib
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
SCRATCH_NAME = "AXe E2E Mirror Scratch"
CREATED_NAME = "AXe E2E Mirror Created"
GONE_NAME = "AXe E2E Mirror Gone"
results = []
children = []
scratch = []        # simulators this run made; deleted when it ends


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
    return run(["xcrun", "simctl", "create", name, *newest_iphone()]).stdout.strip()


def newest_iphone():
    """A device type and the newest iOS runtime that runs it, as `simctl create` takes them."""
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "available", "-j"]).stdout)["runtimes"]
    ios = sorted((r for r in runtimes if r.get("platform") == "iOS"), key=lambda r: [int(p) for p in r["version"].split(".")])
    if not ios:
        raise RuntimeError("no iOS simulator runtime is installed")
    types = [t["identifier"] for t in ios[-1].get("supportedDeviceTypes", []) if t.get("productFamily") == "iPhone"]
    preferred = [t for t in types if t.endswith(("iPhone-17", "iPhone-17-Pro", "iPhone-16"))] or types
    if not preferred:
        raise RuntimeError("the newest iOS runtime supports no iPhone simulator")
    return preferred[0], ios[-1]["identifier"]


def state_of(udid):
    """simctl's state for one simulator, such as Booted or Shutdown; None when there is no such simulator."""
    listing = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"]).stdout)
    return next((d["state"] for devices in listing["devices"].values() for d in devices if d["udid"] == udid), None)


def named(name):
    """The UDIDs of every simulator with this name."""
    listing = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"]).stdout)
    return [d["udid"] for devices in listing["devices"].values() for d in devices if d["name"] == name]


def delete(udid):
    run(["xcrun", "simctl", "shutdown", udid], check=False)
    run(["xcrun", "simctl", "delete", udid], check=False)


def boot(udid):
    run(["xcrun", "simctl", "boot", udid], check=False)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=300)


def build_app(spec_folder, scheme, product, work):
    """Generates the Xcode project from its XcodeGen spec and builds it for the simulator. The
    project goes beside its spec, as the README has it (it is ignored by git): generated anywhere
    else, it looks for Info.plist beside itself and the build fails."""
    project = os.path.join(ROOT, spec_folder)
    run(["xcodegen", "generate", "--spec", os.path.join(project, "project.yml")])
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

    def scroll_to(self, identifier, swipes=20):
        """Brings a control of a long list onto the screen, swiping the list up until it is well
        inside it. A row far below is not in the tree at all, and one just below the screen is in
        the tree but cannot be tapped, so being found is not enough."""
        width, height = self.screen()

        def swipe(share):
            self.axe_run("swipe", "--start-x", str(width / 2), "--start-y", str(height * 0.7),
                         "--end-x", str(width / 2), "--end-y", str(height * (0.7 - share)))
            time.sleep(1.2)     # the list coasts on after the finger lifts

        last = None
        for _ in range(swipes):
            node = self.find(identifier=identifier)
            if node is None:
                swipe(0.35)
                continue
            frame = node.get("frame") or {}
            middle = float(frame.get("y", 0)) + float(frame.get("height", 0)) / 2
            # Well inside the screen, or the list's last row: a swipe no longer moves it.
            if middle < height * 0.8 or (last is not None and abs(middle - last) < 2):
                return node
            last = middle
            swipe(0.15)
        return None

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


def open_simulators(viewer):
    """From the Mac's menu, through its Simulators door."""
    wait_for("the Mac's menu", lambda: viewer.find(identifier="hub.simulators"), 40)
    viewer.tap_id("hub.simulators")


def go_back(viewer):
    """Taps the navigation bar's Back button."""
    viewer.axe_run("tap", "--id", "BackButton")
    time.sleep(0.8)     # the screen is still sliding away


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
    wait_for("the list of Macs", lambda: viewer.find(label="Your Macs"), 15)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-home.png")], check=False)

    # 2. The paired viewer connects and the host streams.
    host_log, host_err = os.path.join(work, "host.log"), os.path.join(work, "host.err")
    # The host offers the builds in this folder to install; it is empty until step 3d.
    builds_dir = os.path.join(work, "builds")
    os.makedirs(builds_dir)
    install_identity = os.path.join(work, "install-identity")
    hosting = start([axe, "mirror", "--udid", host_udid, "--builds", builds_dir, "--install-identity", install_identity, *identity], host_log, host_err)
    ready = wait_for("the host to be ready", lambda: event(host_log, "ready"), 60)
    viewer.tap_id("home.connect")
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
    # The Playground draws a marker by each tap, and a marker takes a later tap that lands on it:
    # that tap is not counted. So no tap of this run lands where an earlier one did.
    third, fourth = (width / 2 - 30, height / 2 + 180), (width / 2 + 40, height / 2 + 260)
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
    viewer.tap_id("home.connect")
    wait_for("the viewer to connect again", lambda: event(host_log, "streaming", after=seen), 40)
    time.sleep(2.0)     # the first picture
    before = tap_count(host)
    viewer.axe_run("tap", "-x", str(third[0]), "-y", str(third[1]))
    arrived = True
    try:
        wait_for("the first tap after connecting again", lambda: tap_count(host) == before + 1, 10)
    except Exception:
        arrived = False
    check("the first tap after connecting again arrives", arrived, f"tap count {tap_count(host)}, was {before}")

    # 3c. Rotate from the app. The host sees the screen turn, streams it upright and landscape, and
    # turns touches back: two taps a known distance apart arrive the same way apart.
    seen = len(events(host_log))
    viewer.tap_id("stream.rotate")
    turned = wait_for("the host to see the screen turn", lambda: event(host_log, "rotated", after=seen), 20)
    wide = wait_for("a landscape stream", lambda: next((e for e in events(host_log)[seen:] if e.get("event") == "streaming"
                                                         and int(e["width"]) > int(e["height"])), None), 20)
    time.sleep(2.0)     # the first landscape picture, and the screen's own rotation animation
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-landscape.png")], check=False)
    width, height = viewer.screen()
    before = tap_count(host)
    viewer.axe_run("tap", "-x", str(width / 2 - 60), "-y", str(height / 2 - 20))
    wait_for("the first landscape tap", lambda: tap_count(host) == before + 1, 15)
    a = last_tap(host)
    viewer.axe_run("tap", "-x", str(width / 2 + 60), "-y", str(height / 2 + 20))
    wait_for("the second landscape tap", lambda: tap_count(host) == before + 2, 15)
    b = last_tap(host)
    dx, dy = b[0] - a[0], b[1] - a[1]
    check("rotating in the app turns the stream to landscape, and taps land the right way round",
          turned.get("orientation", "").startswith("landscape") and dx > 40 and dy > 10 and 2.0 < dx / dy < 4.5,
          f"{turned.get('orientation')}, {wide['width']}x{wide['height']}; host saw ({a[0]:.0f}, {a[1]:.0f}) then ({b[0]:.0f}, {b[1]:.0f}) for 120, 40 in the app")
    # Two more quarter turns to the left bring an iPhone back to portrait: it skips upside down.
    for turn in range(2):
        seen = len(events(host_log))
        viewer.tap_id("stream.rotate")
        wait_for("the screen to turn again", lambda: event(host_log, "rotated", after=seen), 20)
        time.sleep(1.0)
    upright = [e for e in events(host_log) if e.get("event") == "rotated"][-1]
    check("rotating on brings an iPhone back to portrait, skipping upside down", upright.get("orientation") == "portrait",
          ", ".join(e.get("orientation", "") for e in events(host_log) if e.get("event") == "rotated"))
    time.sleep(1.5)     # the portrait picture

    # 3d. A build published while the viewer is connected is offered in the app, with Install. It
    # goes to the viewer over the connection, and the viewer serves it to iOS from the device. That
    # needs the host's certificate trusted on the device, once: Install before then opens the setup
    # for it, which a person follows in Settings and this does with simctl, and the setup then
    # offers the build again. The simulator installs nothing, so the check ends where iOS is handed
    # the build: by then it has been fetched whole and its digest has matched.
    seen = len(events(host_log))
    package = os.urandom(700_000)
    held = "0123456789abcdef0123456789abcdef"
    os.makedirs(os.path.join(builds_dir, "com.example.held", held))
    with open(os.path.join(builds_dir, "com.example.held", held, "app.ipa"), "wb") as handle:
        handle.write(package)
    with open(os.path.join(builds_dir, "com.example.held", held, "metadata.json"), "w") as handle:
        json.dump({"schema_version": 1, "build_id": held, "bundle_id": "com.example.held", "name": "Held App", "version": "2.0", "build_number": "5",
                   "minimum_os": "17.5", "expires_at": "2099-01-01T00:00:00Z", "device_count": 1, "sha256": hashlib.sha256(package).hexdigest(),
                   "published_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "size_bytes": len(package), "notes": "Fixes the login screen."}, handle)
    try:
        wait_for("the build notice", lambda: viewer.find(identifier="builds.notice"), 20)
        changed = event(host_log, "buildsChanged", after=seen)
        check("a build published while connected is offered in the app", viewer.find(label="Held App 2.0 (5)") is not None or changed is not None,
              (changed or {}).get("newest", ""))
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-build-notice.png")], check=False)
        wait_for("the host to make its certificate", lambda: os.path.exists(os.path.join(install_identity, "identity.json")), 30)
        with open(os.path.join(install_identity, "identity.json")) as handle:
            authority = base64.b64decode(json.load(handle)["authority"])
        certificate = os.path.join(work, "authority.cer")
        with open(certificate, "wb") as handle:
            handle.write(authority)
        time.sleep(1.5)     # the certificate reaches the app a moment after the builds
        viewer.tap_id("builds.notice.install")
        wait_for("the setup to open", lambda: viewer.find(identifier="local.setup.check"), 20)
        check("Install before the device is set up opens the setup", event(host_log, "installRequested", after=seen) is None)
        try:
            # The steps as a video, which iOS floats over Safari and Settings on a real device.
            wait_for("the video", lambda: viewer.find(identifier="local.setup.video"), 10)
            check("the setup screen shows the steps as a video", True)
        except TimeoutError:
            with open(os.path.join(work, "viewer-local-setup-tree.json"), "w") as handle:
                json.dump(viewer.tree(), handle, indent=1)
            failed("the setup screen shows the steps as a video", "no element local.setup.video; the tree is kept")
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-local-setup.png")], check=False)
        # A person leaves the app here, for Safari and Settings, and comes back: the screen and the
        # connection must still be there. The picture of the Home Screen is kept to look at, since
        # whether the video floats there depends on the simulator.
        viewer.axe_run("button", "home", check=False)
        time.sleep(3.0)
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-local-setup-away.png")], check=False)
        # The video must go on floating, not show for a moment and go: a second picture, later.
        time.sleep(6.0)
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-local-setup-away-later.png")], check=False)
        run(["xcrun", "simctl", "launch", viewer_udid, VIEWER_BUNDLE])
        wait_for("the setup screen after coming back", lambda: viewer.find(identifier="local.setup.check"), 20)
        check("the setup screen is still there after leaving the app and coming back", True)
        time.sleep(2.0)     # a floating video goes back to its place
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-local-setup-back.png")], check=False)
        run(["xcrun", "simctl", "keychain", viewer_udid, "add-root-cert", certificate])
        viewer.tap_id("local.setup.check")
        wait_for("the app to find its own server trusted", lambda: viewer.find(identifier="local.setup.ready"), 30)
        offer = viewer.find(identifier="local.setup.done") or {}
        check("with the certificate trusted, the setup offers the build that was asked for", "Held App 2.0 (5)" in (offer.get("AXLabel") or ""),
              offer.get("AXLabel") or "")
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-local-ready.png")], check=False)
        viewer.tap_id("local.setup.done")
        asked = wait_for("the build to be fetched and handed to iOS", lambda: event(host_log, "installRequested", after=seen), 40)
        sent = "to the viewer over the connection" in text_of(host_err)
        check("the build travels over the connection and is handed to iOS from the device", asked.get("bundleID") == "com.example.held" and sent,
              f"{asked.get('name')} {asked.get('version')} ({asked.get('build')})")
        wait_for("the Builds list", lambda: viewer.find(identifier=f"builds.row.{held}"), 15)
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-builds.png")], check=False)
        # Set up, Install needs no more than opening the build and the tap. With builds of one app
        # only, the list is that app's builds: there is no row for the app to go through.
        check("with one app, its builds are listed straight away, under its name",
              viewer.find(identifier="builds.app.com.example.held") is None and viewer.find(identifier="builds.app.header") is not None)
        seen = len(events(host_log))
        viewer.tap_id(f"builds.row.{held}")
        wait_for("the build's own screen", lambda: viewer.find(identifier="builds.detail.install"), 15)
        time.sleep(1.0)     # the screen is still sliding in
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-build-in-sheet.png")], check=False)
        viewer.tap_id("builds.detail.install")
        again = wait_for("the second install", lambda: event(host_log, "installRequested", after=seen), 30)
        check("once set up, Install goes straight to iOS", again.get("bundleID") == "com.example.held")
        time.sleep(1.5)
        go_back(viewer)
        viewer.tap_id("builds.done")
        time.sleep(1.0)
    except (TimeoutError, RuntimeError) as error:
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-builds-failed.png")], check=False)
        failed("a build is installed from the device itself", str(error))

    viewer.tap_id("stream.close")
    wait_for("the list of Macs", lambda: viewer.find(label="Your Macs"), 15)
    code_of_exit = stop(hosting)
    check("the host stops cleanly on Ctrl+C", code_of_exit == 0 and event(host_log, "stopped") is not None, f"exit {code_of_exit}")

    # 4. A host started without --udid: the viewer chooses, boots and creates simulators.
    for leftover in named(SCRATCH_NAME) + named(CREATED_NAME):
        delete(leftover)        # from a run that was stopped before it could tidy up
    # The simulator to boot is made like the host's, which is known to work on this Mac.
    by_runtime = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"]).stdout)["devices"]
    runtime, device_type = next((key, d["deviceTypeIdentifier"]) for key, devices in by_runtime.items() for d in devices if d["udid"] == host_udid)
    shut_down = run(["xcrun", "simctl", "create", SCRATCH_NAME, device_type, runtime]).stdout.strip()
    scratch.append(shut_down)
    # A second, newer build of the same app, so the app's row has builds to choose between, and a
    # build of another app, so there are apps to list.
    newer, other = "fedcba9876543210fedcba9876543210", "00112233445566778899aabbccddeeff"
    for bundle, ident, name, version, number, notes in [("com.example.held", newer, "Held App", "2.1", "6", "Newer."),
                                                        ("com.example.other", other, "Other App", "1.0", "1", "Another app.")]:
        os.makedirs(os.path.join(builds_dir, bundle, ident))
        with open(os.path.join(builds_dir, bundle, ident, "app.ipa"), "wb") as handle:
            handle.write(package)
        with open(os.path.join(builds_dir, bundle, ident, "metadata.json"), "w") as handle:
            json.dump({"schema_version": 1, "build_id": ident, "bundle_id": bundle, "name": name, "version": version, "build_number": number,
                       "minimum_os": "17.5", "expires_at": "2099-01-01T00:00:00Z", "device_count": 1, "sha256": hashlib.sha256(package).hexdigest(),
                       "published_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "size_bytes": len(package), "notes": notes}, handle)
    choose_log, choose_err = os.path.join(work, "choose.log"), os.path.join(work, "choose.err")
    choosing = start([axe, "mirror", "--builds", builds_dir, "--install-identity", install_identity, *identity], choose_log, choose_err)
    chooser_ready = wait_for("the choosing host to be ready", lambda: event(choose_log, "ready"), 60)
    check("a host started without --udid is ready and names no simulator", "udid" not in chooser_ready)
    time.sleep(1.0)     # the stream screen is still sliding away
    viewer.tap_id("home.connect")
    # The Mac's menu comes first: its name, how it is reached, and a door each for simulators and builds.
    wait_for("the Mac's menu", lambda: viewer.find(identifier="hub.builds"), 40)
    time.sleep(1.5)     # the route is known a moment after connecting
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-hub.png")], check=False)
    check("a Mac that lets its viewer choose opens on a menu: Simulators and Builds",
          viewer.find(identifier="hub.simulators") is not None and viewer.find(label="E2E Mac") is not None)
    # 4-two. A second paired viewer connects while the first is connected. Each has a session of
    # its own on the host, so neither takes the other's place: before that, the newcomer displaced
    # the first, which came back by itself and displaced the newcomer, and so on without end.
    second_udid = simulator("AXe E2E Mirror Viewer 2", "AXE_MIRROR_E2E_VIEWER2_UDID")
    try:
        boot(second_udid)
        second = Simulator(axe, second_udid)
        run(["xcrun", "simctl", "uninstall", second_udid, VIEWER_BUNDLE], check=False)
        run(["xcrun", "simctl", "install", second_udid, viewer_app])
        run(["xcrun", "simctl", "launch", "--terminate-running-process", second_udid, VIEWER_BUNDLE])
        pair2_log = os.path.join(work, "pair2.log")
        pairing2 = start([axe, "mirror", "pair", "--json", "--name", MAC_NAME, *identity], pair2_log, os.path.join(work, "pair2.err"))
        code2 = wait_for("the second pairing code", lambda: event(pair2_log, "code"), 40)["code"]
        second.tap_id("home.pair")
        second.tap_id("pair.code")
        second.axe_run("type", code2)
        second.tap_id("pair.submit")
        paired2 = wait_for("the second viewer to pair", lambda: event(pair2_log, "paired"), 40)
        pairing2.wait(timeout=15)
        second.tap_label("Done")
        seen = len(events(choose_log))
        second.tap_id("home.connect")
        wait_for("the second viewer's menu", lambda: second.find(identifier="hub.builds"), 40)
        time.sleep(10)      # a displaced viewer comes back within a few seconds
        since = [e for e in events(choose_log)[seen:] if e.get("event") in ("viewerConnected", "viewerDisconnected")]
        run(["xcrun", "simctl", "io", second_udid, "screenshot", os.path.join(work, "viewer2-hub.png")], check=False)
        check("a second paired viewer connects without taking the first one's place",
              [e["event"] for e in since] == ["viewerConnected"] and viewer.find(identifier="hub.builds") is not None
              and second.find(identifier="hub.builds") is not None, f"{len(since)} connection events")
        check("an event says which viewer it is about",
              bool(since) and since[0].get("viewer") == paired2.get("viewer") and since[0].get("viewerName") == paired2.get("name"),
              since[0].get("viewerName", "") if since else "")
        seen = len(events(choose_log))
        run(["xcrun", "simctl", "terminate", second_udid, VIEWER_BUNDLE], check=False)
        gone = wait_for("the second viewer to be gone", lambda: event(choose_log, "viewerDisconnected", after=seen), 40)
        check("a viewer that leaves takes no other with it", gone.get("viewer") == paired2.get("viewer") and viewer.find(identifier="hub.builds") is not None)
    except (TimeoutError, RuntimeError) as error:
        failed("two viewers are connected at once", str(error))
    finally:
        run(["xcrun", "simctl", "terminate", second_udid, VIEWER_BUNDLE], check=False)
        run(["xcrun", "simctl", "shutdown", second_udid], check=False)
    # Apps: they are listed on the menu itself, under their heading, which is folded to begin
    # with; then everything about one build, and Install from there.
    try:
        seen = len(events(choose_log))
        chip = viewer.find(identifier="hub.connection") or {}
        folded = viewer.find(identifier="builds.app.com.example.held") is None
        viewer.tap_id("hub.builds")
        wait_for("the app on the menu", lambda: viewer.find(identifier="builds.app.com.example.held"), 20)
        check("the menu says how the Mac is reached, and lists its apps when Apps is tapped",
              folded and "Connected" in (chip.get("AXLabel") or ""), chip.get("AXLabel") or "")
        # On a narrow screen Apps is a heading that folds the apps away again and brings them
        # back. On a wide one it chooses what is beside the menu, and there is nothing to fold.
        if viewer.screen()[0] < 700:
            viewer.tap_id("hub.builds")
            time.sleep(1.0)
            folded = viewer.find(identifier="builds.app.com.example.held") is None
            viewer.tap_id("hub.builds")
            wait_for("the apps to come back", lambda: viewer.find(identifier="builds.app.com.example.held"), 10)
            check("the Apps heading folds the list away and brings it back", folded)
            time.sleep(0.6)
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-builds-list.png")], check=False)
        check("with several apps, builds are listed by app: one row for an app with two builds",
              viewer.find(identifier=f"builds.row.{held}") is None and viewer.find(label="Held App, 2 builds") is not None
              and viewer.find(identifier="builds.app.com.example.other") is not None)
        # Held down, an app offers its newest build without opening anything.
        frame = viewer.find(identifier="builds.app.com.example.held")["frame"]
        viewer.axe_run("touch", "-x", str(float(frame["x"]) + float(frame["width"]) / 2), "-y", str(float(frame["y"]) + float(frame["height"]) / 2),
                       "--down", "--up", "--delay", "1.0")
        viewer.tap_label("Install Latest Build, 2.1 (6)")      # the menu says which build that is
        latest = wait_for("the install from the app's menu", lambda: event(choose_log, "installRequested", after=seen), 40)
        check("holding an app down installs its newest build", latest.get("bundleID") == "com.example.held" and latest.get("build") == "6",
              f"{latest.get('version')} ({latest.get('build')})")
        # That iOS has the build is said in passing, and does not stay on the screen.
        said = wait_for("the install note", lambda: viewer.find(identifier="builds.started"), 5)
        time.sleep(7.0)
        check("the note that iOS has the build goes by itself", "Held App 2.1 (6)" in (said.get("AXLabel") or "") and viewer.find(identifier="builds.started") is None,
              said.get("AXLabel") or "")
        seen = len(events(choose_log))
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-builds-held.png")], check=False)
        viewer.tap_id("builds.app.com.example.held")
        # The app's builds are a list, newest first. On a narrow screen a row opens the build; on
        # a wide one the chosen build is beside the list already.
        wait_for("the app's builds", lambda: viewer.find(identifier=f"builds.row.{newer}"), 20)
        time.sleep(0.8)
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-builds-app.png")], check=False)
        older, newest = viewer.find(identifier=f"builds.row.{held}"), viewer.find(identifier=f"builds.row.{newer}")
        check("an app's builds are listed newest first", older is not None and float(newest["frame"]["y"]) < float(older["frame"]["y"]))
        viewer.tap_id(f"builds.row.{held}")
        wait_for("the build's own screen", lambda: viewer.find(identifier="builds.detail.install"), 15)
        time.sleep(0.8)
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-build-detail.png")], check=False)
        tree = json.dumps(viewer.tree())
        check("a build opens on a screen of its own with its notes and its facts",
              ("Fixes the login screen." in tree or "Newer." in tree) and "Requires" in tree and "Installable until" in tree)
        viewer.tap_id("builds.detail.install")
        asked = wait_for("the install from the build's screen", lambda: event(choose_log, "installRequested", after=seen), 40)
        check("Install works from the build's own screen", asked.get("bundleID") == "com.example.held")
        time.sleep(1.5)
        for _ in range(4):      # one screen back on a wide screen, where the build is beside the list; three otherwise
            if viewer.find(identifier="hub.simulators") is not None:
                break
            go_back(viewer)
    except (TimeoutError, RuntimeError) as error:
        failed("builds have a list and a screen for each", str(error))
    open_simulators(viewer)
    wait_for("the list of simulators", lambda: viewer.find(identifier="chooser.simulator." + host_udid), 40)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-chooser.png")], check=False)
    # The first screen has the running simulators and the recent ones; one that has never run is
    # under All simulators.
    check("the app lists the running simulator first, and not one that has never run",
          viewer.find(identifier="chooser.simulator." + shut_down) is None and event(choose_log, "streaming") is None)

    # 4a. A running simulator opens, takes touches, and its ID can be copied.
    viewer.tap_id("chooser.simulator." + host_udid)
    selected = wait_for("the choice", lambda: event(choose_log, "simulatorSelected"), 40)
    wait_for("the stream of the chosen simulator", lambda: event(choose_log, "streaming"), 40)
    time.sleep(2.0)     # the first picture
    before = tap_count(host)
    viewer.axe_run("tap", "-x", str(fourth[0]), "-y", str(fourth[1]))
    arrived = True
    try:
        wait_for("a tap on the chosen simulator", lambda: tap_count(host) == before + 1, 15)
    except Exception:
        arrived = False
    check("a running simulator chosen in the app is streamed and takes touches", selected["udid"] == host_udid and arrived)
    run(["xcrun", "simctl", "pbcopy", viewer_udid], input="nothing yet")
    viewer.tap_id("stream.copyID")
    wait_for("the ID on the clipboard", lambda: run(["xcrun", "simctl", "pbpaste", viewer_udid]).stdout.strip() != "nothing yet", 10)
    copied = run(["xcrun", "simctl", "pbpaste", viewer_udid]).stdout.strip()
    check("the app copies the simulator's ID", copied == host_udid, copied)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-chosen.png")], check=False)

    # 4b. Close goes back to the list, leaving the first one running; a simulator that is shut down is booted and shown.
    viewer.tap_id("stream.close")
    wait_for("the question about leaving", lambda: viewer.find(label="Leave it running"), 10)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-leave.png")], check=False)
    viewer.tap_label("Leave it running")
    released = wait_for("the simulator to be let go", lambda: event(choose_log, "simulatorReleased"), 15)
    check("a simulator left running stays booted", state_of(host_udid) == "Booted" and event(choose_log, "simulatorShutDown") is None)
    seen = len(events(choose_log))
    wait_for("the list of simulators", lambda: viewer.find(identifier="chooser.new"), 20)
    check("the rest of the simulators are one row away", viewer.scroll_to("chooser.all") is not None)
    viewer.axe_run("tap", "--id", "chooser.all")
    wait_for("all the simulators", lambda: viewer.find(identifier="chooser.allList") or viewer.find(label="All simulators"), 15)
    time.sleep(0.8)     # the list is still sliding in
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-all.png")], check=False)
    check("the simulator that is shut down is found under All simulators", viewer.scroll_to("chooser.simulator." + shut_down) is not None)
    viewer.axe_run("tap", "--id", "chooser.simulator." + shut_down)
    wait_for("the app to say it is starting the simulator", lambda: viewer.find(identifier="chooser.progress"), 15)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-booting.png")], check=False)
    booted = wait_for("the shut-down simulator to be booted and chosen", lambda: event(choose_log, "simulatorSelected", after=seen), 330, every=1.0)
    wait_for("its stream", lambda: event(choose_log, "streaming", after=seen), 60)
    check("a simulator that was shut down is booted and streamed",
          released["udid"] == host_udid and booted["udid"] == shut_down and state_of(shut_down) == "Booted")

    # 4c. Leaving it this time shuts it down. Then a new simulator is created with a name, booted
    # and shown, and the host prints its ID.
    viewer.tap_id("stream.close")
    viewer.tap_label("Shut it down")
    stopped = wait_for("the simulator to be shut down", lambda: event(choose_log, "simulatorShutDown"), 90, every=1.0)
    wait_for("simctl to agree", lambda: state_of(shut_down) == "Shutdown", 30)
    check("leaving with Shut it down shuts the simulator down", stopped["udid"] == shut_down)
    seen = len(events(choose_log))
    viewer.tap_id("chooser.new")
    viewer.tap_id("new.name")
    viewer.axe_run("type", CREATED_NAME)
    viewer.tap_id("new.create")
    created = wait_for("the new simulator", lambda: event(choose_log, "simulatorCreated", after=seen), 150, every=1.0)
    scratch.append(created["udid"])
    wait_for("the new simulator to be booted and chosen", lambda: event(choose_log, "simulatorSelected", after=seen), 330, every=1.0)
    wait_for("its stream", lambda: event(choose_log, "streaming", after=seen), 60)
    check("a simulator created in the app is named, booted and streamed",
          created["name"] == CREATED_NAME and named(CREATED_NAME) == [created["udid"]] and state_of(created["udid"]) == "Booted",
          f"{created['model']}, {created['os']}")
    time.sleep(2.0)     # the first picture
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-created.png")], check=False)

    # 4d. Close with Shut it down stops the simulator and goes back to the list; Back goes to the
    # Mac's menu, whose Close leaves the Mac. Then the simulator is deleted.
    seen = len(events(choose_log))
    viewer.tap_id("stream.close")
    viewer.tap_label("Shut it down")
    wait_for("the new simulator to be shut down", lambda: event(choose_log, "simulatorShutDown", after=seen), 90, every=1.0)
    wait_for("the list of simulators", lambda: viewer.find(identifier="chooser.new"), 30)
    go_back(viewer)
    wait_for("the Mac's menu", lambda: viewer.find(identifier="hub.simulators"), 15)
    viewer.tap_id("stream.close")
    wait_for("the list of Macs", lambda: viewer.find(label="Your Macs"), 30)
    check("Close with Shut it down stops the simulator and goes back to the list; Back and the menu's Close leave the Mac",
          state_of(created["udid"]) == "Shutdown")
    time.sleep(1.0)     # the stream screen is still sliding away
    # For 4e: a simulator the list will offer and that is then deleted behind the app's back.
    for leftover in named(GONE_NAME):
        delete(leftover)
    gone = run(["xcrun", "simctl", "create", GONE_NAME, *newest_iphone()]).stdout.strip()
    scratch.append(gone)
    viewer.tap_id("home.connect")
    open_simulators(viewer)
    wait_for("the list of simulators", lambda: viewer.find(identifier="chooser.new"), 40)
    # It was running a moment ago, so it is the first of the recent ones. A swipe shows Delete.
    wait_for("the simulator among the recent ones", lambda: viewer.find(identifier="chooser.simulator." + created["udid"]), 15)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-recent.png")], check=False)
    # Other simulators running on this Mac can push it down under the search bar at the bottom.
    row = viewer.scroll_to("chooser.simulator." + created["udid"])
    frame = row["frame"]
    middle = float(frame["y"]) + float(frame["height"]) / 2
    viewer.axe_run("swipe", "--start-x", str(float(frame["x"]) + float(frame["width"]) - 30), "--start-y", str(middle),
                   "--end-x", str(float(frame["x"]) + 40), "--end-y", str(middle))
    wait_for("the row's Delete action", lambda: viewer.find(label="Delete"), 10)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-manage.png")], check=False)
    viewer.tap_label("Delete")
    wait_for("the question about deleting", lambda: viewer.find(label="Delete simulator"), 10)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-delete.png")], check=False)
    check("nothing is deleted before the question is answered", named(CREATED_NAME) == [created["udid"]])
    viewer.tap_label("Delete simulator")
    deleted = wait_for("the simulator to be deleted", lambda: event(choose_log, "simulatorDeleted"), 120, every=1.0)
    check("a simulator deleted in the app, after confirming, is gone from the Mac", deleted["udid"] == created["udid"] and named(CREATED_NAME) == [])
    wait_for("the list without it", lambda: viewer.find(identifier="chooser.simulator." + created["udid"]) is None, 20)

    # 4e. Something the Mac cannot do is said in plain words, with nothing of the Mac's own tools
    # in it: a simulator deleted on the Mac since the list was read is chosen in the app.
    viewer.scroll_to("chooser.all")
    viewer.axe_run("tap", "--id", "chooser.all")
    wait_for("all the simulators", lambda: viewer.find(identifier="chooser.allList") or viewer.find(label="All simulators"), 15)
    viewer.scroll_to("chooser.simulator." + gone)
    run(["xcrun", "simctl", "delete", gone])
    viewer.axe_run("tap", "--id", "chooser.simulator." + gone)
    try:
        wait_for("the problem", lambda: viewer.find(identifier="chooser.problem"), 30)
        run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-problem.png")], check=False)
        plain = viewer.find(label="no longer on your Mac") is not None
        raw = any(viewer.find(label=word) is not None for word in ("simctl", "xcrun", "xcode-select"))
        check("a failure on the Mac is said in plain words, without its tools' names", plain and not raw)
        wait_for("the list without the deleted simulator", lambda: viewer.find(identifier="chooser.simulator." + gone) is None, 20)
        viewer.tap_label("Dismiss")
        wait_for("the problem to go", lambda: viewer.find(identifier="chooser.problem") is None, 10)
    except TimeoutError as error:
        failed("a failure on the Mac is said in plain words, without its tools' names", str(error))
    for _ in range(3):      # from All simulators, by way of the list, to the Mac's menu
        if viewer.find(identifier="hub.simulators") is not None:
            break
        go_back(viewer)
    wait_for("the Mac's menu", lambda: viewer.find(identifier="hub.simulators"), 15)
    viewer.tap_id("stream.close")
    wait_for("the list of Macs", lambda: viewer.find(label="Your Macs"), 15)
    check("the choosing host stops cleanly", stop(choosing) == 0 and event(choose_log, "stopped") is not None)

    # 5. An unpaired viewer is refused.
    host_log, host_err = os.path.join(work, "host-again.log"), os.path.join(work, "host-again.err")
    hosting = start([axe, "mirror", "--udid", host_udid, "--no-builds", *identity], host_log, host_err)
    wait_for("the host to be ready again", lambda: event(host_log, "ready"), 60)
    run([axe, "mirror", "unpair", paired["viewer"][:12], "--viewers-file", viewers])
    time.sleep(1.0)     # the stream screen is still sliding away
    seen = len(events(host_log))
    viewer.tap_id("home.connect")
    refused = wait_for("the refusal", lambda: event(host_log, "refused", after=seen), 40)
    check("an unpaired viewer is refused", refused.get("viewer") == paired["viewer"], refused.get("reason", ""))
    told = wait_for("the app to say it is no longer paired", lambda: viewer.find(label="no longer paired"), 15)
    check("the app tells an unpaired viewer to pair again", told is not None)
    run(["xcrun", "simctl", "io", viewer_udid, "screenshot", os.path.join(work, "viewer-refused.png")], check=False)
    viewer.tap_id("stream.close")
    stop(hosting)

    # 6. A demo host keeps its visitor inside the sample app.
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
        for udid in scratch:
            delete(udid)
    bad = [name for ok, name in results if not ok]
    print(f"{len(results) - len(bad)} passed, {len(bad)} failed.")
    sys.exit(1 if bad or not results else 0)
