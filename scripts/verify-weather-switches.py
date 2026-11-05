#!/usr/bin/env python3
"""Check two Weather switches through one public reference batch on a warm simulator."""

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
SPEC = importlib.util.spec_from_file_location("axe_weather_replay", REPLAY_SOURCE)
REPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPLAY)
require = REPLAY.require
write_json = REPLAY.write_json
sha256 = REPLAY.sha256
LABELS = ("Atmospheric animations", "Severe weather alerts")
PLAN = {
    "name": "Turn off both Weather settings in one reference batch",
    "precondition": "Weather Settings is already open on one warm simulator; both switches are on.",
    "steps": ["Read both on switches", "Tap both references in one batch", "Read both off values from the final full capture"],
    "inputRetries": 0,
    "batchView": "full",
}


def switches(replay):
    replay.all_pages()
    rows = [replay.target({"role": "switch", "label": label}, "tap") for label in LABELS]
    require(len({row["ref"] for row in rows}) == 2, "The two settings do not have distinct references.")
    require(all(row["value"] in ("0", "1") for row in rows), "A switch has no Boolean value.")
    return rows


def run_checks(replay, prepare_on):
    replay.active_step = "Read both on switches"
    replay.observe()
    rows = switches(replay)
    if prepare_on:
        for label in LABELS:
            row = next(row for row in switches(replay) if row["label"] == label)
            if row["value"] == "0":
                replay.active_step = "Prepare on: " + label
                replay.action({"op": "tap", "role": "switch", "label": label}, record_check=False)
                require(replay.capture is not None, "Preparation returned no replacement capture.")
                replay.assert_read({"op": "row_value", "role": "switch", "label": label, "equals": "1"})
        # Get one fresh table immediately before the measured batch.
        replay.observe()
        rows = switches(replay)
    require(all(row["value"] == "1" for row in rows), "Both Weather switches must be on before the batch.")
    snapshot = replay.capture["snapshotID"]
    replay.checks.append({"name": "Read both on switches", "passed": True,
                          "snapshotID": snapshot, "switches": rows})
    document = {"snapshotID": snapshot,
                "steps": [{"action": "tap", "ref": row["ref"]} for row in rows]}
    document_file = replay.args.out / "batch.json"
    write_json(document_file, document)
    replay.active_step = "Tap both references in one batch"
    call_count = len(replay.calls)
    try:
        reply = replay.call(["batch", "--agent", "--view", "full", "--steps-json",
                             json.dumps(document, ensure_ascii=False, separators=(",", ":"))],
                            "action", expected_schema_version="1")
    finally:
        if len(replay.calls) == call_count + 1:
            call = replay.calls[-1]
            call.update(batchDocument=str(document_file), batchDocumentSHA256=sha256(document_file))
            write_json(Path(call["stdout"]).parent / "call.json", call)
            replay.manifest()
    data = reply.get("data", {})
    batch = data.get("batch", {})
    require(batch.get("totalSteps") == 2 and batch.get("completedSteps") == 2
            and batch.get("stoppedAt") is None and batch.get("replayed") is False
            and batch.get("rolledBack") is False, "Both switch steps did not complete without replay.")
    receipts = batch.get("steps")
    require(isinstance(receipts, list) and len(receipts) == 2, "The batch has no two ordered receipts.")
    for index, step in enumerate(receipts, 1):
        receipt = step.get("receipt", {})
        require(step.get("index") == index and step.get("action") == "tap"
                and step.get("status") == "completed" and step.get("error") is None
                and isinstance(step.get("requestID"), str)
                and receipt.get("kind") == "tap" and receipt.get("outcome") == "enqueuedAndDrained"
                and receipt.get("enqueuedEventCount") == 2 and receipt.get("cleanup") == "notNeeded"
                and receipt.get("replayed") is False and receipt.get("quarantine") is None,
                "A switch lacks one complete, non-replayed down/up receipt.")
    require(data.get("quarantine") is None, "The batch has unresolved input quarantine.")
    capture = data.get("capture", {})
    require(capture.get("type") == "runtime-snapshot" and isinstance(capture.get("snapshotID"), str)
            and capture.get("snapshotID") != snapshot
            and isinstance(capture.get("targets"), list), "No replacement full capture was returned.")
    targets = []
    for raw in capture["targets"]:
        require(isinstance(raw, str) and len(raw.split("|")) == 6, "A full target row has the wrong shape.")
        targets.append(dict(zip(("ref", "action", "role", "label", "value", "id"), raw.split("|"))))
    observed = []
    for label in LABELS:
        matched = [row for row in targets if row["role"] == "switch" and row["label"] == label
                   and row["action"] == "tap"]
        require(len(matched) == 1 and matched[0]["value"] == "0",
                "The final full capture does not prove the switch is off: " + label)
        observed.append(matched[0])
    replay.checks.append({"name": "Turn off both switches and read both final values", "passed": True,
                          "batchCalls": 1, "completedSteps": 2, "receipts": receipts,
                          "inputSnapshotID": snapshot, "replacementSnapshotID": capture["snapshotID"],
                          "switches": observed})


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--axe", type=Path, required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--guard", type=Path)
    parser.add_argument("--resource-probe", type=Path)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--max-pages", type=int, default=256)
    parser.add_argument("--prepare-on", action="store_true", help="Turn each off switch on once, through an observed public tap.")
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-fA-F-]{36}", args.udid), "An explicit simulator UUID is required.")
    args.axe = args.axe.resolve(strict=True)
    args.out = args.out.absolute()
    require(args.axe.is_file() and os.access(args.axe, os.X_OK), "AXe must be executable.")
    require(bool(args.guard) == bool(args.resource_probe), "Supply both resource tools.")
    if args.guard:
        args.guard = args.guard.resolve(strict=True)
        args.resource_probe = args.resource_probe.resolve(strict=True)
    require(math.isfinite(args.timeout) and args.timeout > 0 and args.max_pages > 0,
            "Timeout and page limit must be positive and finite.")
    return args


def main():
    args = arguments()
    args.out.mkdir(parents=True, mode=0o700, exist_ok=False)
    (args.out / "raw").mkdir(mode=0o700)
    write_json(args.out / "plan.json", {**PLAN, "prepareOn": args.prepare_on})
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
        run_checks(replay, args.prepare_on)
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
