#!/usr/bin/env python3
"""Verify one London search batch through public UI on an existing warm Weather simulator."""

import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sys


REPLAY_SOURCE = Path(__file__).with_name("verify-example-apps.py")
REPLAY_BYTES = REPLAY_SOURCE.read_bytes()
SPEC = importlib.util.spec_from_file_location("axe_weather_search_replay", REPLAY_SOURCE)
REPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPLAY)
require = REPLAY.require
write_json = REPLAY.write_json
sha256 = REPLAY.sha256
PLACEHOLDER = "Search for a city, airport, or country"
PLAN = {"name": "Find London with one reference typing batch", "inputRetries": 0,
        "precondition": "Weather is already in the foreground on one warm simulator.",
        "steps": ["Open Locations through visible controls", "Verify an empty focused search field",
                  "Type London once", "Verify field text and the London England result"]}


def tap(replay, label):
    replay.action({"op": "tap", "role": "button", "label": label, "scan_all": True})
    require(replay.capture is not None, "The observed tap returned no replacement capture.")


def field(replay):
    replay.all_pages()
    found = [row for row in replay.rows if row["role"] == "text-field"
             and set(row["actions"].split(",")) & {"tap", "typeText"}]
    require(len(found) == 1, "Locations must expose exactly one usable search field.")
    return found[0]


def run_checks(replay):
    replay.active_step = "Open Locations through visible controls"
    replay.observe()
    if replay.args.from_settings:
        tap(replay, "Close")
    tap(replay, replay.args.location_label)
    search = field(replay)
    if search["value"] not in ("", PLACEHOLDER):
        tap(replay, "Clear search")
        search = field(replay)
    require(search["value"] in ("", PLACEHOLDER), "The search field is not empty before focus.")
    if "typeText" not in search["actions"].split(","):
        require("tap" in search["actions"].split(","), "The search field cannot receive focus.")
        replay.action({"op": "tap", "ref": search["ref"]})
        require(replay.capture is not None, "Focusing the field returned no replacement capture.")
        replay.observe()
        search = field(replay)
    require("typeText" in search["actions"].split(","), "The search field is not focused for typing.")
    require(search["value"] in ("", PLACEHOLDER), "The focused search field is not empty.")
    replay.active_step = "Verify an empty focused search field"
    snapshot = replay.capture["snapshotID"]
    detail = replay.call(["describe-ui", "--agent", "--snapshot-id", snapshot,
                          "--read-ref", search["ref"], "--text-field", "value", "--text-limit", "256"],
                         "detail").get("data", {}).get("detail", {})
    require(detail.get("ref") == search["ref"] and detail.get("field") == "value"
            and detail.get("text") in ("", PLACEHOLDER) and detail.get("nextOffset") is None,
            "Exact native readback does not show an empty search field or its placeholder.")
    replay.checks.append({"name": "Empty focused search field", "passed": True,
                          "snapshotID": snapshot, "ref": search["ref"], "actualValue": detail["text"]})
    document = {"snapshotID": snapshot,
                "steps": [{"action": "type", "ref": search["ref"], "text": "London"}]}
    document_file = replay.args.out / "batch.json"
    write_json(document_file, document)
    replay.active_step = "Type London once"
    call_count = len(replay.calls)
    try:
        reply = replay.call(["batch", "--agent", "--steps-json",
                             json.dumps(document, ensure_ascii=False, separators=(",", ":"))], "action")
    finally:
        if len(replay.calls) == call_count + 1:
            call = replay.calls[-1]
            call.update(batchDocument=str(document_file), batchDocumentSHA256=sha256(document_file))
            write_json(Path(call["stdout"]).parent / "call.json", call)
            replay.manifest()
    data = reply.get("data", {})
    batch = data.get("batch", {})
    require(batch.get("completedSteps") == 1 and "totalSteps" not in batch
            and batch.get("stoppedAt") is None and batch.get("replayed") is False
            and "rolledBack" not in batch, "The adaptive London typing batch did not complete once.")
    steps = batch.get("steps")
    require(isinstance(steps, list) and len(steps) == 1, "The typing step has no single receipt.")
    step = steps[0]
    receipt = step.get("receipt", {})
    require(step.get("index") == 1 and step.get("action") == "type" and step.get("status") == "completed"
            and step.get("error") is None and "requestID" not in step
            and receipt.get("kind") == "typeText" and receipt.get("outcome") == "enqueuedAndDrained"
            and receipt.get("enqueuedEventCount") == 14 and receipt.get("cleanup") == "notNeeded"
            and "replayed" not in receipt and receipt.get("quarantine") is None
            and data.get("quarantine") is None, "London has no complete 14-event typing receipt without replay.")
    replay.accept_capture(reply)
    require(replay.capture["snapshotID"] != snapshot, "Typing did not replace its reference table.")
    actual = field(replay)
    require(actual["value"] == "London" and "typeText" in actual["actions"].split(","),
            "The actual focused search field does not contain London.")
    results = [row for row in replay.rows if row["role"] == "button"
               and "tap" in row["actions"].split(",") and row["label"].startswith("London, England, United Kingdom,")]
    require(len(results) == 1, "One visible London, England result was not returned.")
    replay.checks.append({"name": "Search London and read its result", "passed": True,
                          "inputSnapshotID": snapshot, "replacementSnapshotID": replay.capture["snapshotID"],
                          "receipt": receipt, "actualField": actual, "actualResult": results[0]})


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--axe", type=Path, required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--guard", type=Path)
    parser.add_argument("--resource-probe", type=Path)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--max-pages", type=int, default=256)
    parser.add_argument("--from-settings", action="store_true", help="Close the currently visible Settings sheet first.")
    parser.add_argument("--location-label", default="London", help="Exact visible main-screen location button label.")
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-fA-F-]{36}", args.udid), "An explicit simulator UUID is required.")
    args.axe = args.axe.resolve(strict=True)
    args.out = args.out.absolute()
    require(args.axe.is_file() and os.access(args.axe, os.X_OK), "AXe must be executable.")
    require(bool(args.guard) == bool(args.resource_probe), "Supply both resource tools.")
    if args.guard:
        args.guard = args.guard.resolve(strict=True)
        args.resource_probe = args.resource_probe.resolve(strict=True)
    require(math.isfinite(args.timeout) and args.timeout > 0 and args.max_pages > 0
            and args.location_label.strip(), "Timeout, page limit and location label must be valid.")
    return args


def main():
    args = arguments()
    args.out.mkdir(parents=True, mode=0o700, exist_ok=False)
    (args.out / "raw").mkdir(mode=0o700)
    write_json(args.out / "plan.json", {**PLAN, "fromSettings": args.from_settings,
                                       "locationLabel": args.location_label})
    helper_copy = args.out / Path(__file__).name
    replay_copy = args.out / REPLAY_SOURCE.name
    helper_copy.write_bytes(Path(__file__).read_bytes())
    replay_copy.write_bytes(REPLAY_BYTES)
    replay = REPLAY.Replay(args)
    result = {"status": "FAIL_OR_UNPROVED", "udid": args.udid, "inputRetries": 0,
              "invokedExecutable": str(args.axe), "invokedFileSHA256": replay.executable_hash,
              "helperCopy": str(helper_copy), "helperSHA256": sha256(helper_copy),
              "importedReplayCopy": str(replay_copy), "importedReplaySHA256": sha256(replay_copy),
              "planSHA256": sha256(args.out / "plan.json"),
              "resourceGuardSHA256": sha256(args.guard) if args.guard else None,
              "resourceProbeSHA256": sha256(args.resource_probe) if args.resource_probe else None}
    try:
        require(REPLAY_SOURCE.read_bytes() == REPLAY_BYTES, "Replay changed during loading.")
        run_checks(replay)
        result["status"] = "PASS"
    except BaseException as error:
        last = replay.calls[-1] if replay.calls else {}
        result["failure"] = {"step": replay.active_step, "message": str(error), "callID": last.get("id"),
                             "responseError": last.get("responseError")}
    finally:
        result.update(checks=replay.checks, calls=len(replay.calls),
                      executableUnchanged=sha256(args.axe) == replay.executable_hash,
                      importedReplayUnchanged=REPLAY_SOURCE.read_bytes() == REPLAY_BYTES)
        if not result["executableUnchanged"] or not result["importedReplayUnchanged"]:
            result["status"] = "FAIL_OR_UNPROVED"
        replay.manifest()
        write_json(args.out / "result.json", result)
        print(json.dumps({"status": result["status"], "calls": len(replay.calls),
                          "result": str(args.out / "result.json")}), flush=True)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (REPLAY.ReplayFailure, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
