#!/usr/bin/env python3
"""Verify one retained library pair, with no input replay or injected app state."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

BUNDLE = "com.camsoft.duo-session-probe"


def require(value, reason):
    if not value:
        raise ValueError(reason)


def save(file, value):
    file.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def walk(roots):
    for node in roots:
        yield node
        yield from walk(node.get("children", []))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--resource-probe", required=True, type=Path)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--mode", choices=("normal", "fold", "rotate"), required=True)
    parser.add_argument("--hinge", type=float, default=0)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    args.cli = args.cli.resolve(strict=True)
    args.probe = args.probe.resolve(strict=True)
    helper = args.cli.with_name("cadisplay-context")
    probe = None
    records = []

    def run(name, argv):
        with (args.out / (name + ".stdout")).open("wb") as stdout, (args.out / (name + ".stderr")).open("wb") as stderr:
            child = subprocess.Popen(argv, stdout=stdout, stderr=stderr)
            try:
                code = child.wait()
            except BaseException:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
                raise
        receipt = dict(name=name, command=argv, pid=child.pid, exitCode=code, reaped=child.poll() is not None)
        save(args.out / (name + "-process.json"), receipt)
        records.append(receipt)
        require(code == 0, name + " failed; no replay")
        return (args.out / (name + ".stdout")).read_text()

    def bind(name):
        container = run(name + "-container", ["/usr/bin/xcrun", "simctl", "get_app_container", args.udid, BUNDLE, "data"]).strip()
        processes = run(name + "-pid", ["/usr/bin/xcrun", "simctl", "spawn", args.udid, "launchctl", "list"])
        rows = [line.split() for line in processes.splitlines() if "UIKitApplication:" + BUNDLE + "[" in line]
        require(len(rows) == 1 and rows[0][0] == str(args.pid), "Fixture PID changed")
        return Path(container).resolve(strict=True) / "Documents/state.json"

    def state():
        value = json.loads(state_file.read_text())
        require(value["fixtureVersion"] == 6, "Fixture v6 required")
        return value

    def wait_state(name, predicate, seconds=8):
        deadline = time.monotonic() + seconds
        while True:
            value = state()
            if predicate(value):
                save(args.out / (name + ".json"), value)
                return value
            require(time.monotonic() < deadline, "App readback timeout: " + name)
            time.sleep(.025)

    def marker(name):
        (args.out / name).write_text("continue\n")

    def stage(name, seconds=15):
        deadline = time.monotonic() + seconds
        while True:
            text = (args.out / "probe.stdout").read_text()
            rows = [json.loads(line) for line in text.splitlines() if line.endswith("}")]
            matches = [row for row in rows if row["stage"] == name]
            if matches:
                require(len(matches) == 1, "Repeated probe stage")
                save(args.out / (name + ".json"), matches[0])
                return matches[0]
            require(probe.poll() is None, "Probe exited before " + name)
            require(time.monotonic() < deadline, "Probe stage timeout: " + name)
            time.sleep(.025)

    def discovery(name):
        return json.loads(run(name, [str(args.cli), "list-simulators", "--displays", "--udid", args.udid]))

    def selected(name, verb, extra, display):
        panel = display["activePanel"]["identity"]
        return json.loads(run(name, [str(args.cli), verb, *extra, "--udid", args.udid,
            "--input-mode", "selected", "--screen-id", str(panel["displayID"]),
            "--screen-uuid", panel["uniqueID"], "--expected-pid", str(args.pid)]))

    def target(description, identifier):
        matches = [n for n in walk(description["ax"]["roots"]) if n.get("AXUniqueId") == identifier]
        require(len(matches) == 1 and matches[0]["pid"] == args.pid and matches[0]["enabled"], "Missing or ambiguous owned target")
        return matches[0]["frame"]

    try:
        state_file = bind("before")
        before = state()
        save(args.out / "before.json", before)
        require(before["activeWindowTouches"] == 0 and not before["textFocused"], "App is not ready for pair input")
        display = discovery("displays-before")
        description = selected("describe-before", "describe-ui", [], display)
        require(description.get("error") is None, "Initial selected AX failed")
        context = description["context"]
        frame = target(description, "feature.pad")
        require(frame["width"] >= 100 and frame["height"] >= 80, "Pad is too small")
        require(frame["x"] >= 0 and frame["y"] >= 0 and frame["x"] + frame["width"] <= context["logicalWidth"] and frame["y"] + frame["height"] <= context["logicalHeight"], "Pad is clipped")
        x, y = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
        configuration = dict(simulatorUDID=args.udid, bootIdentity=display["bootIdentity"],
            screenID=context["screenID"], screenUUID=context["screenUUID"], helperPath=str(helper),
            first=dict(x=x-25,y=y), second=dict(x=x+25,y=y),
            movedFirst=dict(x=x-15,y=y), movedSecond=dict(x=x+35,y=y),
            staleFirst=dict(x=x-10,y=y), staleSecond=dict(x=x+40,y=y),
            coordinationDirectory=str(args.out.resolve()), mode=args.mode, hingeDegrees=args.hinge)
        save(args.out / "configuration.json", configuration)
        runtime = [args.cli, helper, args.probe, args.cli.parent / "FBSimulatorControl.framework/Versions/A/FBSimulatorControl"]
        save(args.out / "candidate.json", dict(files={str(file):hashlib.sha256(file.read_bytes()).hexdigest() for file in runtime}, mode=args.mode))
        resources = json.loads(subprocess.run([str(args.resource_probe)], capture_output=True, text=True, check=True, timeout=5).stdout)
        rows = resources["rows"]
        app_ids = {r["pid"] for r in rows if r["name"] in ("ChatGPT", "Codex")}
        while True:
            children = {r["pid"] for r in rows if r["ppid"] in app_ids} - app_ids
            if not children:
                break
            app_ids.update(children)
        app_gib = sum(r["footprintBytes"] for r in rows if r["pid"] in app_ids) / 1073741824
        save(args.out / "idle-resource.json", dict(source=resources["source"], appFootprintGiB=app_gib, newInputLimitGiB=7.75))
        require(app_gib < 7.75, "Idle app memory reached7.75GiB; no pair input")
        with (args.out / "probe.stdout").open("wb") as stdout, (args.out / "probe.stderr").open("wb") as stderr:
            probe = subprocess.Popen([str(args.probe), "pair", str(args.out / "configuration.json")], stdout=stdout, stderr=stderr)
        began = stage("began")
        require(began["operation"]["outcome"] == "retained" and began["operation"]["normalEventDelta"] == 1 and began["operation"]["tokenReturned"], "Pair did not retain")
        held = wait_state("held-before-move", lambda s:s["activeWindowTouches"] == 2)
        initial = held["windowTouchTrace"][len(before["windowTouchTrace"]):]
        contact_ids = {row["contactID"] for row in initial if row["phase"] == "windowTouchBegan"}
        require(len(contact_ids) == 2, "Two app contacts did not begin")
        marker("move.ready")
        moved = stage("moved")
        require(moved["operation"]["outcome"] == "moved" and moved["operation"]["normalEventDelta"] == 1 and moved["operation"]["sameOriginalToken"], "Pair move did not retain the original token")
        moved_points = [(x-15,y),(x+35,y)]
        def both_moved(value):
            if value["activeWindowTouches"] != 2:
                return False
            suffix = value["windowTouchTrace"][len(before["windowTouchTrace"]):]
            last = {cid:[e for e in suffix if e["contactID"] == cid][-1] for cid in contact_ids}
            return all(any(e["phase"] == "windowTouchMoved" and abs(e["x"]-px)<.5 and abs(e["y"]-py)<.5 for e in last.values()) for px,py in moved_points)
        moved_state = wait_state("held-before-change", both_moved)
        if args.mode == "normal":
            marker("finish.ready")
            ended = stage("ended")
            require(ended["operation"]["outcome"] == "endedAndDrained" and ended["operation"]["normalEventDelta"] == 1 and not ended["operation"]["tokenReturned"], "Normal pair did not end and clear token")
            idle = None
        else:
            change = json.loads(run("external-change", [str(args.probe), "change", str(args.out / "configuration.json")]))
            save(args.out / "external-change.json", change)
            marker("finish.ready")
            idle = stage("idleAfterChange")
            save(args.out / "idle-app.json", state())
            require("staleContext" in idle["feedValidation"], "Live provider did not see the external change")
            marker("stale-move.ready")
            first = stage("oldMove1")
            require(first["operation"]["normalEventDelta"] == 0 and "staleContext" in first["operation"]["error"], "Old coordinates were not stopped before normal input")
            cleanup = first["cleanupEvidence"]
            require(first["status"]["hasRetainedContact"] is False and first["status"]["lastCleanup"] == "releaseEnqueuedAndDrained", "Owned pair cleanup was not confirmed")
            require(len(cleanup["releases"]) == 1 and cleanup["releases"][0]["primitive"] == "TwoFingerTouch <hidden>" and cleanup["releases"][0]["returnedSuccessfully"], "Missing owned pair UP")
            require(cleanup["contextValidation"] == "releaseIdentityMatchedBeforeAndAfter" and cleanup["outcome"] == "releaseEnqueuedAndDrained" and not cleanup["timedOut"], "Cleanup target or barrier is uncertain")
            save(args.out / "after-first-rejection.json", state())
            marker("second-stale.ready")
            second = stage("oldMove2")
            require(second["operation"]["normalEventDelta"] == 0 and "invalidated" in second["operation"]["error"] and second["cleanupEvidence"] == cleanup, "Invalid old session sent or repeated input")
        closed = stage("closed")
        require(probe.wait(timeout=5) == 0, "Probe failed after lifecycle")
        save(args.out / "probe-process.json", dict(pid=probe.pid, exitCode=probe.returncode, reaped=True))
        require(not closed["status"]["hasRetainedContact"] and not closed["operation"]["tokenReturned"], "Closed session retained input or token")
        after = wait_state("after-pair", lambda s:s["activeWindowTouches"] == 0)
        suffix = after["windowTouchTrace"][len(before["windowTouchTrace"]):]
        require({e["contactID"] for e in suffix} == contact_ids, "Unexpected contact during pair")
        for cid in contact_ids:
            group = [e for e in suffix if e["contactID"] == cid]
            require(group[0]["phase"] == "windowTouchBegan" and group[-1]["phase"] in ("windowTouchEnded", "windowTouchCancelled"), "Contact did not release")
        fresh = discovery("displays-after")
        fresh_description = selected("describe-after", "describe-ui", [], fresh)
        button = target(fresh_description, "feature.tap")
        tap = selected("fresh-tap", "tap", ["--id", "feature.tap", "--tap-style", "physical"], fresh)
        require(tap.get("error") is None and tap["outcome"] == "enqueuedAndDrained" and tap["enqueuedEventCount"] == 2 and tap["context"] == fresh_description["context"], "Fresh named tap did not complete")
        final = wait_state("after-tap", lambda s:s["counts"].get("tap",0) == after["counts"].get("tap",0)+1 and s["activeWindowTouches"] == 0)
        tap_trace = final["windowTouchTrace"][len(after["windowTouchTrace"]):]
        require(len(tap_trace) == 2 and tap_trace[0]["phase"] == "windowTouchBegan" and tap_trace[-1]["phase"] == "windowTouchEnded" and tap_trace[0]["contactID"] == tap_trace[-1]["contactID"], "Fresh tap contact did not fully release")
        for event in tap_trace:
            require(abs(event["x"]-button["x"]-button["width"]/2)<.5 and abs(event["y"]-button["y"]-button["height"]/2)<.5, "Fresh tap used old coordinates")
        require(bind("after") == state_file, "App data binding changed")
        time.sleep(.3)
        require(state() == final, "App effect did not settle")
        result = dict(status="PASS", mode=args.mode, contactIDs=sorted(contact_ids), actualPairStarted=True,
            bothMovedBeforeChange=True, normalEventsAtClose=closed["status"]["normalEnqueuedEventCount"],
            tokenReturnedAtClose=False, heldTouchesAtEnd=0, freshNamedButtonEffects=1,
            automaticOwnedCleanupObserved=idle is not None and not idle["status"]["hasRetainedContact"],
            idleHasRetainedContact=idle["status"]["hasRetainedContact"] if idle else None,
            scope="Retained library pair; cleanup on stale move is separate from UIKit cancellation and idle cleanup")
        save(args.out / "result.json", result)
        print(json.dumps(result))
    except BaseException as error:
        save(args.out / "failure.json", dict(error=repr(error), noReplay=True))
        raise
    finally:
        if probe is not None and probe.poll() is None:
            marker("abort.ready")
            try:
                probe.wait(timeout=5)
            except subprocess.TimeoutExpired:
                probe.terminate()
                try:
                    probe.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    probe.kill(); probe.wait()
            save(args.out / "probe-stopped-process.json", dict(pid=probe.pid, exitCode=probe.returncode, reaped=True))


if __name__ == "__main__":
    main()
