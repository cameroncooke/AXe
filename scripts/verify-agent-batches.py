#!/usr/bin/env python3
"""Check public agent batch behavior on an existing warm Calculator simulator."""

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
SPEC = importlib.util.spec_from_file_location("axe_example_app_replay", REPLAY_SOURCE)
REPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPLAY)
Replay = REPLAY.Replay
ReplayFailure = REPLAY.ReplayFailure
require = REPLAY.require
write_json = REPLAY.write_json
sha256 = REPLAY.sha256

BUTTONS = {"C", "±", "%", "÷", "7", "8", "9", "×", "4", "5", "6", "-",
           "1", "2", "3", "+", "0", ".", "="}
PLAN = {
    "name": "Calculator agent batch checks",
    "precondition": "The normal Calculator is already in the foreground on one warm simulator.",
    "cases": [
        "Find all 19 Calculator buttons",
        "Clear Calculator with an inline reference batch",
        "Calculate 5 + 3 in one reference batch",
        "Reject an invalid later target before any batch input",
        "Keep the newer reference table after refusing an old batch",
        "Clear Calculator with a JSON file reference batch",
        "Check the native ID file form only when Clear exposes an ID",
    ],
    "inputRetries": 0,
    "source": "Public compact rows, explicit field reads and complete CLI results only.",
}


class BatchChecks:
    def __init__(self, replay):
        self.replay = replay

    def start(self, index):
        self.replay.active_step = index

    def passed(self, **evidence):
        self.replay.checks.append({"step": self.replay.active_step,
                                   "name": PLAN["cases"][self.replay.active_step],
                                   "status": "PASS", "passed": True, **evidence})

    def button(self, label):
        return self.replay.target({"role": "button", "label": label, "scan_all": True}, "tap")

    def display(self, text):
        self.replay.assert_read({"op": "text_is", "text": text})

    def document(self, labels):
        steps = [{"action": "tap", "ref": self.button(label)["ref"]} for label in labels]
        return {"snapshotID": self.replay.capture["snapshotID"], "steps": steps}

    def submit(self, document, source="inline"):
        path = self.replay.args.out / "documents" / f"case-{self.replay.active_step}-{source}.json"
        write_json(path, document)
        if source == "inline":
            arguments = ["batch", "--agent", "--steps-json",
                         json.dumps(document, ensure_ascii=False, separators=(",", ":"))]
        else:
            arguments = ["batch", "--agent", "--file", str(path)]
        call_count = len(self.replay.calls)
        try:
            return self.replay.call(arguments, "action")
        finally:
            if len(self.replay.calls) == call_count + 1:
                call = self.replay.calls[-1]
                call.update(batchInputSource=source, batchDocument=str(path), batchDocumentSHA256=sha256(path))
                write_json(Path(call["stdout"]).parent / "call.json", call)
                self.replay.manifest()

    @staticmethod
    def completed(value, count):
        data = value.get("data", {})
        batch = data.get("batch")
        require(isinstance(batch, dict), "The batch returned no completion receipt.")
        require(batch.get("completedSteps") == count and "totalSteps" not in batch
                and batch.get("stoppedAt") is None and batch.get("replayed") is False
                and "rolledBack" not in batch,
                "The adaptive batch did not complete every planned step without replay.")
        steps = batch.get("steps")
        require(isinstance(steps, list) and len(steps) == count,
                "A completed batch is missing ordered step receipts.")
        for index, step in enumerate(steps, 1):
            receipt = step.get("receipt")
            require(step.get("index") == index and step.get("action") == "tap"
                    and step.get("status") == "completed" and step.get("error") is None
                    and "requestID" not in step and isinstance(receipt, dict),
                    "A planned Calculator tap has no completed ordered receipt.")
            require("kind" not in receipt and receipt.get("outcome") == "enqueuedAndDrained"
                    and "replayed" not in receipt and receipt.get("cleanup") == "notNeeded"
                    and receipt.get("quarantine") is None
                    and receipt.get("enqueuedEventCount") == 2,
                    "A Calculator tap did not prove one completed down/up pair without replay.")
        return batch

    def expect_refusal(self, document, code):
        previous_calls = len(self.replay.calls)
        try:
            self.submit(document)
        except ReplayFailure:
            require(len(self.replay.calls) == previous_calls + 1,
                    "The expected refusal has no single saved CLI call.")
            call = self.replay.calls[-1]
            require(isinstance(call.get("exitCode"), int) and call["exitCode"] > 0
                    and call.get("reaped") is True and call.get("stopReason") is None
                    and not call.get("timedOut") and not call.get("inputOutcomeUnknown"),
                    "A transport/resource failure cannot count as the expected refusal.")
            require(call.get("guardExitCode", 0) in (0, 2),
                    "The resource guard did not report its normal success or completed-child-error exit.")
            value = json.loads(Path(call["stdout"]).read_bytes())
            require(isinstance(value, dict) and value.get("schema") == "axe.output.agent-result"
                    and value.get("schemaVersion") == "2" and value.get("didError") is True
                    and value.get("error", {}).get("code") == code,
                    "The complete actual JSON does not contain the expected typed refusal.")
            data = value.get("data", {})
            batch = data.get("batch")
            require(isinstance(batch, dict) and batch.get("totalSteps") == len(document["steps"])
                    and batch.get("completedSteps") == 0 and batch.get("steps") == []
                    and batch.get("stoppedAt") == 1
                    and batch.get("replayed") is False and batch.get("rolledBack") is False
                    and data.get("action") is None and data.get("quarantine") is None,
                    "The refusal does not establish prevalidation before any input step.")
            # Preserve the original failure record; add the exact reason this refusal is expected.
            call["expectedRefusal"] = {"code": code, "validated": True,
                                       "completedSteps": 0, "actionReceiptCount": 0}
            write_json(Path(call["stdout"]).parent / "call.json", call)
            self.replay.manifest()
            return {"callID": call["id"], "code": code, "completedSteps": 0,
                    "actionReceiptCount": 0, "enqueuedEventsInReceipts": 0,
                    "inputEvidence": "Typed prevalidation refusal before the first step; no action receipt. This is not an OS event inventory."}
        raise ReplayFailure("The batch succeeded when the expected refusal was required.")

    def run(self):
        self.start(0)
        self.replay.observe()
        self.replay.all_pages()
        buttons = [row for row in self.replay.rows
                   if row["role"] == "button" and "tap" in row["actions"].split(",")]
        require(len(buttons) == 19 and {row["label"] for row in buttons} == BUTTONS,
                "The foreground screen is not the normal Calculator with all 19 controls.")
        self.passed(buttonCount=19, snapshotID=self.replay.capture["snapshotID"])

        self.start(1)
        clear = self.document(["C"])
        reply = self.submit(clear)
        batch = self.completed(reply, 1)
        self.replay.accept_capture(reply)
        require(self.replay.capture["snapshotID"] != clear["snapshotID"],
                "A completed batch did not replace its published reference table.")
        self.display("0")
        self.passed(display="0", completedSteps=batch["completedSteps"],
                    inputSnapshotID=clear["snapshotID"], replacementSnapshotID=self.replay.capture["snapshotID"])

        self.start(2)
        self.replay.observe()
        arithmetic = self.document(["5", "+", "3", "="])
        reply = self.submit(arithmetic)
        batch = self.completed(reply, 4)
        self.replay.accept_capture(reply)
        self.display("8")
        self.display("5 + 3 =")
        self.passed(display="8", expression="5 + 3 =", completedSteps=batch["completedSteps"],
                    oneOriginalSnapshotID=arithmetic["snapshotID"], batchCalls=1)

        self.start(3)
        self.replay.observe()
        self.display("8")
        invalid = self.document(["C"])
        invalid["steps"].append({"action": "tap", "ref": "e9999999"})
        refusal = self.expect_refusal(invalid, "unsupportedReference")
        self.replay.observe()
        self.display("8")
        self.passed(displayUnchanged="8", refusal=refusal)

        self.start(4)
        self.replay.observe()
        old = self.document(["C"])
        self.replay.observe()
        new_snapshot = self.replay.capture["snapshotID"]
        require(new_snapshot != old["snapshotID"], "A second capture did not replace table A.")
        button = self.button("7")
        refusal = self.expect_refusal(old, "snapshotMissing")
        read = self.replay.call(["describe-ui", "--agent", "--snapshot-id", new_snapshot,
                                 "--read-ref", button["ref"], "--text-field", "label", "--text-limit", "64"], "detail")
        detail = read.get("data", {}).get("detail")
        require(isinstance(detail, dict) and detail.get("ref") == button["ref"]
                and detail.get("field") == "label" and detail.get("text") == "7",
                "The old batch erased or changed the newer table's reference read.")
        page = self.replay.call(["describe-ui", "--agent", "--snapshot-id", new_snapshot,
                                 "--row-offset", "0"], "page")
        require(page.get("data", {}).get("capture", {}).get("snapshotID") == new_snapshot,
                "The old batch erased or replaced table B during paging.")
        self.replay.accept_capture(page)
        self.display("8")
        self.passed(oldSnapshotID=old["snapshotID"], newerSnapshotID=new_snapshot,
                    readRefSurvived=True, pagingSurvived=True, displayUnchanged="8", refusal=refusal)

        self.start(5)
        self.replay.observe()
        file_clear = self.document(["C"])
        reply = self.submit(file_clear, source="file")
        batch = self.completed(reply, 1)
        self.replay.accept_capture(reply)
        self.display("0")
        self.passed(display="0", completedSteps=batch["completedSteps"], inputSource="JSON file")

        self.start(6)
        clear_button = self.button("C")
        read = self.replay.call(["describe-ui", "--agent", "--snapshot-id", self.replay.capture["snapshotID"],
                                 "--read-ref", clear_button["ref"], "--text-field", "id", "--text-limit", "4096"], "detail")
        detail = read.get("data", {}).get("detail")
        require(isinstance(detail, dict) and detail.get("ref") == clear_button["ref"]
                and detail.get("field") == "id" and isinstance(detail.get("text"), str)
                and detail.get("nextOffset") is None,
                "The native ID check did not return the complete Clear ID.")
        identifier = detail["text"]
        if not identifier:
            self.replay.checks.append({"step": 6, "name": PLAN["cases"][6], "status": "SKIPPED",
                                       "reason": "Calculator Clear exposes no native ID. No ID was invented or replaced with a label."})
            return
        reply = self.submit({"steps": [{"action": "tap", "id": identifier}]}, source="file")
        batch = self.completed(reply, 1)
        self.replay.accept_capture(reply)
        self.display("0")
        self.passed(display="0", completedSteps=batch["completedSteps"], inputSource="native ID JSON file")


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--axe", type=Path, required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--guard", type=Path)
    parser.add_argument("--resource-probe", type=Path)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--max-pages", type=int, default=256)
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-fA-F-]{36}", args.udid), "An explicit simulator UUID is required.")
    args.axe = args.axe.resolve(strict=True)
    args.out = args.out.absolute()
    require(args.axe.is_file() and os.access(args.axe, os.X_OK), "AXe must be executable.")
    require(bool(args.guard) == bool(args.resource_probe), "Supply both resource monitoring arguments.")
    if args.guard:
        args.guard = args.guard.resolve(strict=True)
        args.resource_probe = args.resource_probe.resolve(strict=True)
        require(args.guard.is_file() and args.resource_probe.is_file(), "Resource tools are absent.")
    require(math.isfinite(args.timeout) and args.timeout > 0 and args.max_pages > 0,
            "Timeout and page limit must be positive and finite.")
    return args


def main():
    args = arguments()
    require(REPLAY_SOURCE.read_bytes() == REPLAY_BYTES, "The imported Replay source changed during loading.")
    args.out.mkdir(parents=True, mode=0o700, exist_ok=False)
    (args.out / "raw").mkdir(mode=0o700)
    (args.out / "documents").mkdir(mode=0o700)
    write_json(args.out / "plan.json", PLAN)
    helper_copy = args.out / "verify-agent-batches.py"
    imported_copy = args.out / "verify-example-apps.py"
    helper_copy.write_bytes(Path(__file__).read_bytes())
    imported_copy.write_bytes(REPLAY_BYTES)
    replay = Replay(args)
    result = {"status": "FAIL_OR_UNPROVED", "udid": args.udid,
              "invokedExecutable": str(args.axe), "invokedFileSHA256": replay.executable_hash,
              "inputRetries": 0, "helperCopy": str(helper_copy), "helperSHA256": sha256(helper_copy),
              "importedReplayCopy": str(imported_copy), "importedReplaySHA256": sha256(imported_copy),
              "planSHA256": sha256(args.out / "plan.json"),
              "resourceGuardSHA256": sha256(args.guard) if args.guard else None,
              "resourceProbeSHA256": sha256(args.resource_probe) if args.resource_probe else None}
    try:
        BatchChecks(replay).run()
        result["status"] = "PASS_WITH_SKIPS" if any(check["status"] == "SKIPPED" for check in replay.checks) else "PASS"
    except BaseException as error:
        last = replay.calls[-1] if replay.calls else {}
        result["failure"] = {"step": replay.active_step, "message": str(error), "callID": last.get("id"),
                             "actualActionReceipt": last.get("actualActionReceipt"), "responseError": last.get("responseError")}
    finally:
        result.update(checks=replay.checks, calls=len(replay.calls),
                      executableUnchanged=sha256(args.axe) == replay.executable_hash,
                      importedReplayUnchanged=REPLAY_SOURCE.read_bytes() == REPLAY_BYTES)
        if not result["executableUnchanged"] or not result["importedReplayUnchanged"]:
            result["status"] = "FAIL_OR_UNPROVED"
        replay.manifest()
        write_json(args.out / "result.json", result)
        print(json.dumps({"status": result["status"], "checks": len(replay.checks),
                          "calls": len(replay.calls), "result": str(args.out / "result.json")}), flush=True)
    return 0 if result["status"] in ("PASS", "PASS_WITH_SKIPS") else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ReplayFailure, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
