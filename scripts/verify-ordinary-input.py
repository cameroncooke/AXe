#!/usr/bin/env python3
"""Verify one real ordinary-device input effect without retry or injected state."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import time
import uuid

BUNDLE = "com.camsoft.duo-session-probe"


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def save(file, value):
    file.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def command(args, name, argv):
    with (args.out / (name + ".stdout")).open("wb") as stdout, (args.out / (name + ".stderr")).open("wb") as stderr:
        child = subprocess.Popen(argv, stdout=stdout, stderr=stderr)
        try:
            code = child.wait()
        except BaseException:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            raise
        save(args.out / (name + "-started.json"), dict(command=argv, pid=child.pid))
    save(args.out / (name + "-process.json"), dict(command=argv, exitCode=code, reaped=child.poll() is not None))
    require(code == 0, name + " failed; no input retry")
    return (args.out / (name + ".stdout")).read_text()


def walk(roots):
    for node in roots:
        yield node
        yield from walk(node.get("children", []))


def state(args):
    value = json.loads(args.state_file.read_text())
    require(value.get("fixtureVersion") == 6, "Fixture v6 is required")
    return value


def binding(args, phase):
    container = command(args, phase + "-container", ["/usr/bin/xcrun", "simctl", "get_app_container", args.udid, BUNDLE, "data"]).strip()
    require(args.state_file.resolve(strict=True) == Path(container).resolve(strict=True) / "Documents/state.json", "Wrong app data binding")
    processes = command(args, phase + "-pid", ["/usr/bin/xcrun", "simctl", "spawn", args.udid, "launchctl", "list"])
    matches = [line.split() for line in processes.splitlines() if "UIKitApplication:" + BUNDLE + "[" in line]
    require(len(matches) == 1 and matches[0][0] == str(args.pid), "Wrong fixture process")


def invoke(args, name, verb, extra, ax=False):
    argv = [str(args.cli), verb, *extra, "--udid", args.udid, "--input-mode", args.mode]
    if args.mode == "selected":
        argv += ["--screen-id", str(args.screen_id), "--screen-uuid", args.screen_uuid]
        if ax:
            argv += ["--expected-pid", str(args.pid)]
    raw = command(args, name, argv)
    if args.mode == "legacy":
        return json.loads(raw) if ax else None
    receipt = json.loads(raw)
    save(args.out / (name + "-receipt.json"), receipt)
    require(receipt.get("error") is None and receipt.get("quarantine") is None, "Selected operation failed")
    context = receipt["context"]
    require(context["screenID"] == args.screen_id and uuid.UUID(context["screenUUID"]) == uuid.UUID(args.screen_uuid), "Wrong selected display")
    if verb != "describe-ui":
        require(receipt["outcome"] == "enqueuedAndDrained" and receipt["enqueuedEventCount"] > 0 and receipt.get("token") is None, "Selected input did not complete")
        require(receipt["cleanup"] in ("notNeeded", "releaseEnqueuedAndDrained"), "Selected cleanup is uncertain")
    return receipt


def verify(args):
    args.out.mkdir(parents=True, exist_ok=False)
    save(args.out / "candidate.json", dict(cli=str(args.cli), cliSHA256=hashlib.sha256(args.cli.read_bytes()).hexdigest(), mode=args.mode, case=args.case))
    binding(args, "before")
    before = state(args)
    require(before.get("activeWindowTouches") == 0, "App has held input before the check")
    require(before.get("interfaceOrientation") == args.orientation, "Unexpected starting interface orientation")
    save(args.out / "before.json", before)
    time.sleep(0.25)
    require(state(args) == before, "App is not idle")
    description = invoke(args, "describe-before", "describe-ui", [], ax=True)
    roots = description["ax"]["roots"] if args.mode == "selected" else description
    nodes = list(walk(roots if isinstance(roots, list) else [roots]))
    identifier = "feature.pad" if args.case == "swipe" else "feature.text" if args.case in ("focus", "type", "return") else "feature.tap"
    matches = [node for node in nodes if node.get("AXUniqueId") == identifier]
    require(len(matches) == 1 and matches[0].get("pid") == args.pid and matches[0].get("enabled") is True, "Missing or ambiguous owned target")
    frame = matches[0]["frame"]
    require(all(math.isfinite(frame[k]) for k in ("x", "y", "width", "height")) and frame["width"] > 0 and frame["height"] > 0, "Invalid target frame")
    x, y = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
    expected_points = [(x, y), (x, y)]
    if args.case in ("tap", "focus"):
        extra = ["--id", identifier, "--tap-style", "physical"]
        receipt = invoke(args, "input", "tap", extra, ax=args.mode == "selected")
    elif args.case == "swipe":
        require(frame["width"] >= 100 and frame["height"] >= 80 and not before["textFocused"], "Swipe target is clipped or keyboard is open")
        expected_points = [(x - 40, y), (x + 40, y)]
        receipt = invoke(args, "input", "swipe", ["--start-x", str(x - 40), "--start-y", str(y), "--end-x", str(x + 40), "--end-y", str(y), "--duration", "0.4", "--delta", "10"])
    else:
        require(before["textFocused"], "TextField must already be focused")
        extra = [args.text] if args.case == "type" else ["40"]
        if args.mode == "selected":
            extra += ["--expected-pid", str(args.pid), "--focus-id", "feature.text"]
        receipt = invoke(args, "input", "type" if args.case == "type" else "key", extra)

    def effect(value):
        if args.case == "tap":
            return value["counts"].get("tap", 0) == before["counts"].get("tap", 0) + 1
        if args.case == "swipe":
            return value["counts"].get("pan", 0) == before["counts"].get("pan", 0) + 1
        if args.case == "focus":
            return not before["textFocused"] and value["textFocused"]
        if args.case == "type":
            return value["text"] == before["text"] + args.text and value["counts"].get("textChanged", 0) == before["counts"].get("textChanged", 0) + len(args.text)
        return not value["textFocused"]

    deadline = time.monotonic() + 5
    while True:
        after = state(args)
        if effect(after) and after.get("activeWindowTouches") == 0:
            break
        require(time.monotonic() < deadline, "No actual app effect; no input retry")
        time.sleep(0.05)
    time.sleep(0.3)
    require(state(args) == after, "Effect has not settled")
    save(args.out / "after.json", after)
    require(after["width"] == before["width"] and after["height"] == before["height"] and after["interfaceOrientation"] == before["interfaceOrientation"], "Device layout changed")
    require(after["slider"] == before["slider"] and after["switchOn"] == before["switchOn"], "Unrelated control changed")
    require(after["windowTraceDropped"] == before["windowTraceDropped"], "Touch trace dropped events")
    require(after["windowTouchTrace"][:len(before["windowTouchTrace"])] == before["windowTouchTrace"], "Touch history changed")
    contacts = after["windowTouchTrace"][len(before["windowTouchTrace"]):]
    if args.case in ("type", "return"):
        require(not contacts, "Keyboard operation sent a touch")
    else:
        require(len(contacts) >= 2 and contacts[0]["phase"] == "windowTouchBegan" and contacts[-1]["phase"] == "windowTouchEnded", "No complete touch path")
        require(len({item["contactID"] for item in contacts}) == 1 and contacts[-1]["activeTouches"] == 0, "Contact was not released")
        for actual, expected in zip([contacts[0], contacts[-1]], expected_points):
            require(abs(actual["x"] - expected[0]) < 0.5 and abs(actual["y"] - expected[1]) < 0.5, "Input point differs from fresh AX geometry")
    if args.case == "swipe":
        require(after["recognizerTraceDropped"] == before["recognizerTraceDropped"], "Recognizer trace dropped events")
        require(after["recognizerTrace"][:len(before["recognizerTrace"])] == before["recognizerTrace"], "Recognizer history changed")
        pan = [item for item in after["recognizerTrace"][len(before["recognizerTrace"]):] if item["name"] == "pan"]
        require(pan and pan[0]["state"] == 1 and pan[-1]["state"] == 3 and sum(item["state"] == 3 for item in pan) == 1, "Pan recognizer did not complete once")
        require(abs(after["panX"] - (pan[-1]["x"] - pan[0]["x"])) < 1 and abs(after["panY"] - (pan[-1]["y"] - pan[0]["y"])) < 1, "Recognizer translation differs from its observed path")
    binding(args, "after")
    final = invoke(args, "describe-after", "describe-ui", [], ax=True)
    if args.mode == "selected":
        require(final["context"] == description["context"] == receipt["context"], "Selected context changed")
        require(after["width"] == receipt["context"]["logicalWidth"] and after["height"] == receipt["context"]["logicalHeight"], "Selected space differs from app")
    require(state(args) == after, "App changed during readback")
    result = dict(status="PASS", mode=args.mode, case=args.case, udid=args.udid, pid=args.pid, contacts=len({item["contactID"] for item in contacts}), heldTouches=0, realEffect=True, scope="One ordinary input action in the recorded orientation; no native held-key inventory proof")
    save(args.out / "result.json", result)
    print(json.dumps(result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--state-file", required=True, type=Path)
    parser.add_argument("--mode", choices=("legacy", "selected"), required=True)
    parser.add_argument("--case", choices=("tap", "swipe", "focus", "type", "return"), required=True)
    parser.add_argument("--text", default="a")
    parser.add_argument("--orientation", type=int, choices=(1, 2, 3, 4), default=1)
    parser.add_argument("--screen-id", type=int)
    parser.add_argument("--screen-uuid")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    uuid.UUID(args.udid)
    args.cli = args.cli.resolve(strict=True)
    require(args.pid > 0, "Positive PID required")
    if args.mode == "selected":
        require(args.screen_id is not None and args.screen_uuid is not None, "Selected identity is required")
        uuid.UUID(args.screen_uuid)
    require(args.text.isascii() and 1 <= len(args.text) <= 4, "Use one to four ASCII characters")
    try:
        verify(args)
    except BaseException as error:
        if args.out.exists():
            save(args.out / "failure.json", dict(error=repr(error), noReplay=True))
        raise


if __name__ == "__main__":
    main()
