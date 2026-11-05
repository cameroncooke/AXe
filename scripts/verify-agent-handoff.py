#!/usr/bin/env python3
"""Check completed input and failed final capture during a real Home-to-app handoff."""

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
SPEC = importlib.util.spec_from_file_location("axe_handoff_replay", REPLAY_SOURCE)
REPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPLAY)
require = REPLAY.require
write_json = REPLAY.write_json
sha256 = REPLAY.sha256
PLAN = {"name": "Keep completed app-launch input when its final capture fails", "inputRetries": 0,
        "precondition": "The owned warm simulator is already on SpringBoard after normal Home input outside this helper.",
        "steps": ["Read the chosen app icon", "Tap it once in one reference batch",
                  "Check completed input and final-read refusal", "Read the new owner without a caller PID"]}
FINAL_READ_ERRORS = {"observationFailed", "batchRefreshFailed", "missingObservation", "processEvidenceMissing"}


def check_handoff(replay, result):
    app_icon = replay.args.app_icon
    replay.active_step = f"Read the {app_icon} app icon"
    replay.observe()
    replay.all_pages()
    owner = replay.capture.get("pid")
    require(type(owner) is int and owner > 0, "The Home capture has no positive owner PID.")
    if replay.args.expected_home_pid is not None and owner != replay.args.expected_home_pid:
        result.update(status="UNPROVED", primary={"status": "UNPROVED",
                      "reason": "The captured owner differs from the independently observed Home PID."})
        return
    icons = [row for row in replay.rows if row["label"] == app_icon and "tap" in row["actions"].split(",")]
    if len(icons) != 1:
        result.update(status="UNPROVED", primary={"status": "UNPROVED",
                      "reason": f"Home did not expose one unique tap-capable {app_icon} app icon."})
        return
    icon = icons[0]
    snapshot = replay.capture["snapshotID"]
    document = {"snapshotID": snapshot, "steps": [{"action": "tap", "ref": icon["ref"]}]}
    document_file = replay.args.out / "batch.json"
    write_json(document_file, document)
    result["initialOwnerPID"] = owner
    result["observedAppIcon"] = icon
    if app_icon == "Settings":
        result["observedSettingsIcon"] = icon
    replay.active_step = f"Tap {app_icon} once and check final capture"
    previous_calls = len(replay.calls)
    refused = False
    try:
        value = replay.call(["batch", "--agent", "--steps-json",
                             json.dumps(document, ensure_ascii=False, separators=(",", ":"))], "action")
    except REPLAY.ReplayFailure:
        require(len(replay.calls) == previous_calls + 1, "The refusal has no single saved call.")
        call = replay.calls[-1]
        require(type(call.get("exitCode")) is int and call["exitCode"] > 0
                and call.get("reaped") is True and call.get("stopReason") is None
                and not call.get("timedOut") and not call.get("inputOutcomeUnknown")
                and call.get("guardExitCode", 0) in (0, 2),
                "A transport or resource failure cannot prove final-read refusal.")
        value = json.loads(Path(call["stdout"]).read_bytes())
        refused = True
    finally:
        if len(replay.calls) == previous_calls + 1:
            call = replay.calls[-1]
            call.update(batchDocument=str(document_file), batchDocumentSHA256=sha256(document_file))
            write_json(Path(call["stdout"]).parent / "call.json", call)
            replay.manifest()
    if not refused:
        result["primary"] = {"status": "UNPROVED", "reason": "The batch succeeded before a final-read failure occurred. No input was retried.",
                             "actualBatch": value.get("data", {}).get("batch")}
        result["status"] = "UNPROVED"
        return
    require(isinstance(value, dict) and value.get("schema") == "axe.output.agent-result"
            and value.get("schemaVersion") == "2" and value.get("didError") is True,
            "The complete stdout does not show an agent failure result.")
    data = value.get("data", {})
    batch = data.get("batch", {})
    require(batch.get("totalSteps") == 1 and batch.get("completedSteps") == 1
            and batch.get("replayed") is False and batch.get("rolledBack") is False,
            "The failed batch does not retain one completed input step and no-replay evidence.")
    steps = batch.get("steps")
    require(isinstance(steps, list) and len(steps) == 1, "The completed step receipt is missing.")
    step = steps[0]
    receipt = step.get("receipt", {})
    require(step.get("index") == 1 and step.get("action") == "tap" and step.get("status") == "completed"
            and step.get("error") is None and isinstance(step.get("requestID"), str)
            and receipt.get("kind") == "tap" and receipt.get("outcome") == "enqueuedAndDrained"
            and receipt.get("enqueuedEventCount") == 2 and receipt.get("cleanup") == "notNeeded"
            and receipt.get("replayed") is False and receipt.get("quarantine") is None
            and data.get("quarantine") is None, "The tap has no completed drained/released two-event receipt.")
    cache = data.get("cache", {})
    require(cache.get("status") == "invalidated" and cache.get("requiresRefresh") is True
            and data.get("capture") is None, "The failed final read left a usable capture or cache.")
    observation = data.get("observation", {})
    mismatch = (observation.get("outcome") == "processChanged"
                and observation.get("expectedPID") == owner
                and type(observation.get("observedPID")) is int
                and observation["observedPID"] > 0 and observation["observedPID"] != owner)
    code = value.get("error", {}).get("code")
    require(mismatch or code in FINAL_READ_ERRORS,
            "The failure has neither owner mismatch evidence nor a typed final-read error.")
    primary = {"status": "PASS", "appIconLabel": app_icon, "completedSteps": 1, "actualReceipt": receipt,
               "typedError": code, "ownerMismatchObserved": mismatch, "observation": observation}
    result["primary"] = primary
    replay.checks.append({"name": "Completed input survives a failed final read", "passed": True, **primary})
    call = replay.calls[-1]
    call["expectedFinalReadFailure"] = primary
    write_json(Path(call["stdout"]).parent / "call.json", call)
    replay.manifest()
    replay.active_step = "Read the new owner without a caller PID"
    try:
        replay.observe()
        replay.all_pages()
        new_owner = replay.capture.get("pid")
        require(type(new_owner) is int and new_owner > 0 and new_owner != owner and bool(replay.rows),
                "The fresh read did not establish another owner with usable UI.")
        require(replay.capture["snapshotID"] != snapshot, "The new app reused the Home reference table.")
        result["recovery"] = {"status": "PASS", "ownerPID": new_owner,
                              "snapshotID": replay.capture["snapshotID"], "rows": len(replay.rows)}
        replay.checks.append({"name": "Fresh capture finds the new app without a caller PID", "passed": True,
                              **result["recovery"]})
        result["status"] = "PASS"
    except (REPLAY.ReplayFailure, OSError, ValueError) as error:
        result["recovery"] = {"status": "UNPROVED", "reason": str(error)}
        result["status"] = "PRIMARY_PASS_RECOVERY_UNPROVED"


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--axe", type=Path, required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--guard", type=Path)
    parser.add_argument("--resource-probe", type=Path)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--max-pages", type=int, default=256)
    parser.add_argument("--app-icon", default="Settings", help="Exact observed Home app icon label (default: Settings).")
    parser.add_argument("--expected-home-pid", type=int,
                        help="Optional test precondition from an independent normal Home read; not passed to AXe.")
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
    require(args.expected_home_pid is None or args.expected_home_pid > 0,
            "An optional expected Home PID must be positive.")
    require(args.app_icon.strip() and len(args.app_icon.encode("utf-8")) <= 512,
            "The exact app icon label must be nonblank and at most512 UTF-8 bytes.")
    return args


def main():
    args = arguments()
    args.out.mkdir(parents=True, mode=0o700, exist_ok=False)
    (args.out / "raw").mkdir(mode=0o700)
    write_json(args.out / "plan.json", {**PLAN, "name": f"Home-to-{args.app_icon} completed-input/final-read check",
                                       "appIconLabel": args.app_icon,
                                       "steps": [f"Read the {args.app_icon} app icon", f"Tap {args.app_icon} once in one reference batch", *PLAN["steps"][2:]],
                                       "expectedHomePIDAssertion": args.expected_home_pid})
    helper_copy = args.out / Path(__file__).name
    replay_copy = args.out / REPLAY_SOURCE.name
    helper_copy.write_bytes(Path(__file__).read_bytes())
    replay_copy.write_bytes(REPLAY_BYTES)
    replay = REPLAY.Replay(args)
    result = {"status": "FAIL_OR_UNPROVED", "udid": args.udid, "inputRetries": 0, "appIconLabel": args.app_icon,
              "invokedExecutable": str(args.axe), "invokedFileSHA256": replay.executable_hash,
              "helperCopy": str(helper_copy), "helperSHA256": sha256(helper_copy),
              "importedReplayCopy": str(replay_copy), "importedReplaySHA256": sha256(replay_copy),
              "planSHA256": sha256(args.out / "plan.json"),
              "resourceGuardSHA256": sha256(args.guard) if args.guard else None,
              "resourceProbeSHA256": sha256(args.resource_probe) if args.resource_probe else None}
    try:
        require(REPLAY_SOURCE.read_bytes() == REPLAY_BYTES, "Replay changed during loading.")
        check_handoff(replay, result)
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
