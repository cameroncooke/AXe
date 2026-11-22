#!/usr/bin/env python3
"""End-to-end check of `axe mirror` with a simulator that stops answering.

A throwaway iPhone simulator is opened from the AXe Mirror app on a host started without --udid,
then frozen on purpose: every process under the simulator's own launchd is paused. It proves:
  1. the host notices that the simulator is not answering, and prints `unresponsive`
  2. the app shows that it is not responding, with a Restart button
  3. Restart shuts the simulator down, by force, boots it and opens it again
  4. the banner goes once the simulator answers again

It uses its own host key and viewer list in a temporary folder, the "AXe E2E Mirror Viewer"
simulator as the viewer (made if missing), and a throwaway host simulator that it deletes when it
ends. It needs the internet: pairing goes through a relay.

Usage: scripts/e2e-mirror-frozen.py     (not part of `make e2e`; run it by hand)

Environment (all optional):
  AXE_BIN_PATH                     the axe to test (default: the SwiftPM debug build, built first)
  AXE_MIRROR_E2E_VIEWER_UDID       viewer simulator (default: "AXe E2E Mirror Viewer")
  AXE_MIRROR_E2E_VIEWER_APP        a built "AXe Mirror.app" for the simulator (default: built here)
  AXE_MIRROR_E2E_PLAYGROUND_APP    a built AxePlayground.app for the simulator (default: built here)
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


def tree(udid):
    """The simulator's own launchd and every process under it, from one `ps` listing."""
    found = subprocess.run(["pgrep", "-f", f"CoreSimulator/Devices/{udid}/data/var/run/launchd_bootstrap.plist"],
                           capture_output=True, text=True).stdout
    children = {}
    for line in subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    result, todo = [], [int(pid) for pid in found.split()]
    while todo:
        pid = todo.pop()
        result.append(pid)
        todo.extend(children.get(pid, []))
    return result


def signal_all(pids, which):
    for pid in pids:
        try:
            os.kill(pid, which)
        except ProcessLookupError:
            pass


def main():
    work = tempfile.mkdtemp(prefix="axe-mirror-frozen-e2e.")
    print(f"Working folder: {work}", flush=True)
    axe = os.environ.get("AXE_BIN_PATH")
    if not axe:
        e2e.run(["swift", "build"], cwd=ROOT, timeout=3600)
        axe = os.path.join(e2e.run(["swift", "build", "--show-bin-path"], cwd=ROOT).stdout.strip(), "axe")
    viewer_app = os.environ.get("AXE_MIRROR_E2E_VIEWER_APP") or e2e.build_app("AXeMirror", "AXeMirror", "AXe Mirror.app", work)
    playground_app = os.environ.get("AXE_MIRROR_E2E_PLAYGROUND_APP") or e2e.build_app("AxePlaygroundApp", "AxePlayground", "AxePlayground.app", work)

    viewer_udid = e2e.simulator("AXe E2E Mirror Viewer", "AXE_MIRROR_E2E_VIEWER_UDID")
    # The host is a fresh simulator made for this run; one left by a run that crashed is deleted first.
    for leftover in e2e.named("AXe E2E Mirror Frozen"):
        e2e.delete(leftover)
    host_udid = e2e.simulator("AXe E2E Mirror Frozen", "")
    e2e.scratch.append(host_udid)
    e2e.boot(viewer_udid)
    e2e.boot(host_udid)
    time.sleep(10)
    viewer, host = e2e.Simulator(axe, viewer_udid), e2e.Simulator(axe, host_udid)
    e2e.run(["xcrun", "simctl", "install", host_udid, playground_app])
    e2e.run(["xcrun", "simctl", "launch", host_udid, e2e.PLAYGROUND_BUNDLE, "--launch-arg", "screen=tap-test"])
    e2e.run(["xcrun", "simctl", "uninstall", viewer_udid, e2e.VIEWER_BUNDLE], check=False)
    e2e.run(["xcrun", "simctl", "install", viewer_udid, viewer_app])
    e2e.run(["xcrun", "simctl", "launch", viewer_udid, e2e.VIEWER_BUNDLE])

    key, viewers = os.path.join(work, "host.key"), os.path.join(work, "viewers.json")
    identity = ["--key-file", key, "--viewers-file", viewers]
    pair_log = os.path.join(work, "pair.log")
    pairing = e2e.start([axe, "mirror", "pair", "--json", "--name", "Frozen E2E Mac", *identity], pair_log, os.path.join(work, "pair.err"))
    code = e2e.wait_for("the pairing code", lambda: e2e.event(pair_log, "code"), 40)["code"]
    viewer.tap_id("home.pair")
    viewer.tap_id("pair.code")
    viewer.axe_run("type", code)
    viewer.tap_id("pair.submit")
    e2e.wait_for("the viewer to pair", lambda: e2e.event(pair_log, "paired"), 40)
    pairing.wait(timeout=15)
    viewer.tap_label("Done")

    host_log, host_err = os.path.join(work, "host.log"), os.path.join(work, "host.err")
    e2e.start([axe, "mirror", "--no-builds", *identity], host_log, host_err)
    e2e.wait_for("the host to be ready", lambda: e2e.event(host_log, "ready"), 60)
    viewer.tap_id("home.connect")
    e2e.open_simulators(viewer)
    e2e.wait_for("the list of simulators", lambda: viewer.find(identifier="chooser.new"), 40)
    viewer.scroll_to("chooser.simulator." + host_udid)
    viewer.axe_run("tap", "--id", "chooser.simulator." + host_udid)
    e2e.wait_for("the stream to start", lambda: e2e.event(host_log, "streaming"), 60)
    time.sleep(4)

    paused = tree(host_udid)
    signal_all(paused, signal.SIGSTOP)
    started = time.time()
    seen = e2e.wait_for("the host to say it is not answering", lambda: e2e.event(host_log, "unresponsive"), 90, every=1.0)
    e2e.passed("the host notices a simulator that stops answering", f"{time.time() - started:.0f} s after {len(paused)} processes paused: {seen.get('reason')}")
    e2e.wait_for("the banner", lambda: viewer.find(identifier="stream.restart"), 20)
    e2e.passed("the app shows that it is not responding, with Restart")

    seen_events = len(e2e.events(host_log))
    started = time.time()
    viewer.tap_id("stream.restart")
    e2e.wait_for("the restart", lambda: e2e.event(host_log, "simulatorRestarting", after=seen_events), 120, every=1.0)
    e2e.wait_for("the simulator to be opened again", lambda: e2e.event(host_log, "simulatorSelected", after=seen_events), 300, every=1.0)
    e2e.wait_for("its stream", lambda: e2e.event(host_log, "streaming", after=seen_events), 60)
    time.sleep(4)
    e2e.check("Restart in the app brings a frozen simulator back", e2e.state_of(host_udid) == "Booted", f"{time.time() - started:.0f} s")
    e2e.check("the banner goes once the simulator answers again", viewer.find(identifier="stream.notResponding") is None)

    for child in list(e2e.children):
        e2e.stop(child)
    e2e.children.clear()
    for udid in e2e.scratch:
        signal_all(tree(udid), signal.SIGCONT)
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
        for udid in e2e.scratch:
            signal_all(tree(udid), signal.SIGCONT)
            e2e.delete(udid)
        sys.exit(1)
