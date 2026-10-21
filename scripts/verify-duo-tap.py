#!/usr/bin/env python3
"""Verify one selected HID tap against the existing DuoSessionProbe v6 app.

Run once in each measured pose. This does not change pose or repeat input after
failure. The state file is read-only application evidence, never input to AXe.
"""

import argparse
import json
import pathlib
import subprocess
import time
import uuid


def read_state(filename):
    state = json.loads(filename.read_text())
    if state.get("fixtureVersion") != 6:
        raise ValueError("This check requires the existing DuoSessionProbe v6 app")
    return state


def write_json(filename, value):
    filename.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def invoke(args, command, extra, output):
    invocation = [str(args.axe), command, "--udid", args.udid,
                  "--input-mode", "selected", "--screen-id", str(args.screen_id),
                  "--screen-uuid", args.screen_uuid, "--expected-pid", str(args.pid), *extra]
    result = subprocess.run(invocation, capture_output=True, text=True, check=False)
    write_json(output / (command + "-process.json"),
               {"argv": invocation, "exit": result.returncode, "stderr": result.stderr})
    (output / (command + ".json")).write_text(result.stdout)
    if result.returncode != 0:
        raise ValueError(f"{command} exited {result.returncode}; input will not be repeated")
    receipt = json.loads(result.stdout)
    if receipt.get("error") is not None:
        raise ValueError(f"{command} returned an error receipt")
    context = receipt.get("context", {})
    if context.get("screenID") != args.screen_id:
        raise ValueError("The receipt selected a different display ID")
    if uuid.UUID(context.get("screenUUID", "")) != uuid.UUID(args.screen_uuid):
        raise ValueError("The receipt selected a different display UUID")
    return receipt


def walk(roots):
    for node in roots:
        yield node
        yield from walk(node.get("children", []))


def verify(args):
    args.output.mkdir(parents=True, exist_ok=False)
    before = read_state(args.state_file)
    write_json(args.output / "state-before.json", before)
    if before.get("activeWindowTouches") != 0:
        raise ValueError("The app has held input before the check")
    description = invoke(args, "describe-ui", [], args.output)
    matches = [node for node in walk(description.get("ax", {}).get("roots", []))
               if node.get("AXUniqueId") == "feature.tap"]
    if len(matches) != 1 or matches[0].get("pid") != args.pid:
        raise ValueError("The selected AX tree must contain one owned feature.tap button")
    tap = invoke(args, "tap", ["--id", "feature.tap"], args.output)
    context = tap["context"]
    if context != description["context"]:
        raise ValueError("The selected context changed between lookup and tap")
    if tap.get("enqueuedEventCount", 0) <= 0 or tap.get("cleanup") == "uncertain":
        raise ValueError("The tap did not report known HID delivery and cleanup")
    expected_count = before.get("counts", {}).get("tap", 0) + 1
    deadline = time.monotonic() + 5
    while True:
        after = read_state(args.state_file)
        if (after.get("counts", {}).get("tap", 0) >= expected_count
                and after.get("activeWindowTouches") == 0):
            break
        if time.monotonic() >= deadline:
            write_json(args.output / "state-after.json", after)
            raise ValueError("The app did not observe a released tap; input will not be repeated")
        time.sleep(0.05)
    write_json(args.output / "state-after.json", after)
    if after["counts"]["tap"] != expected_count or after["sequence"] <= before["sequence"]:
        raise ValueError("The application effect must be exactly one new tap")
    if after["width"] != context["logicalWidth"] or after["height"] != context["logicalHeight"]:
        raise ValueError("The app dimensions differ from the selected coordinate space")
    if args.orientation is not None and after["interfaceOrientation"] != args.orientation:
        raise ValueError("The app is not in the required interface orientation")
    result = {"result": "PASS", "screenID": args.screen_id, "context": context,
              "interfaceOrientation": after["interfaceOrientation"],
              "tapBefore": expected_count - 1, "tapAfter": expected_count,
              "activeWindowTouches": after["activeWindowTouches"]}
    write_json(args.output / "result.json", result)
    print(json.dumps(result, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--axe", type=pathlib.Path, required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--screen-id", type=int, required=True)
    parser.add_argument("--screen-uuid", required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--state-file", type=pathlib.Path, required=True)
    parser.add_argument("--orientation", type=int, choices=[1, 2, 3, 4])
    parser.add_argument("--output", type=pathlib.Path, required=True,
                        help="A new directory for the CLI receipts and app state")
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
