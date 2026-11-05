#!/usr/bin/env python3
"""Replay visible example-app tasks through AXe's public agent interface."""

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time


class ReplayFailure(Exception):
    """The plan did not establish its required result."""


class PredicateNotMet(ReplayFailure):
    """A valid observation does not yet show the required state."""


def require(condition, message):
    if not condition:
        raise ReplayFailure(message)


def write_json(file, value):
    temporary = file.with_suffix(file.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    os.replace(temporary, file)


def sha256(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


class Replay:
    ACTIONS = {"tap": "tap", "type": "typeText", "swipe": "swipe",
               "touch": "tap", "hold": "tap"}

    def __init__(self, args):
        self.args = args
        self.calls = []
        self.checks = []
        self.capture = None
        self.rows = []
        self.next_offset = None
        self.visited = set()
        self.active_step = None
        self.executable_hash = sha256(args.axe)

    def manifest(self):
        write_json(self.args.out / "manifest.json", {"captures": self.calls})

    def call(self, arguments, phase, expected_schema_version="2"):
        folder = self.args.out / "raw" / f"{len(self.calls):03d}"
        command = [str(self.args.axe), *arguments, "--udid", self.args.udid]
        record = {
            "id": folder.name, "tool": "AXe", "screen": self.args.out.name,
            "version": self.executable_hash,
            "variant": "reading-default", "phase": phase, "command": command,
            "stdout": str(folder / "stdout"), "stderr": str(folder / "stderr"),
            "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "step": self.active_step, "inputAttempted": phase == "action",
            "expectedSchemaVersion": expected_schema_version,
        }
        started = time.monotonic()
        value = None
        try:
            if self.args.guard:
                guarded = [sys.executable, "-B", str(self.args.guard),
                           "--resource-probe", str(self.args.resource_probe),
                           "--owned-device", self.args.udid, "--timeout",
                           str(self.args.timeout), "--out", str(folder), "--", *command]
                completed = subprocess.run(guarded, capture_output=True, check=False,
                                           timeout=self.args.timeout + 30)
                folder.mkdir(mode=0o700, exist_ok=True)
                (folder / "guard.stdout").write_bytes(completed.stdout)
                (folder / "guard.stderr").write_bytes(completed.stderr)
                proof = json.loads((folder / "result.json").read_bytes())
                record.update(exitCode=proof.get("exitCode"),
                              guardResult=str(folder / "result.json"),
                              guardExitCode=completed.returncode,
                              stopReason=proof.get("stopReason"),
                              reaped=proof.get("reaped"))
            else:
                folder.mkdir(mode=0o700)
                try:
                    completed = subprocess.run(command, capture_output=True, check=False,
                                               timeout=self.args.timeout)
                    stdout, stderr = completed.stdout, completed.stderr
                    record.update(exitCode=completed.returncode, reaped=True)
                except subprocess.TimeoutExpired as error:
                    stdout, stderr = error.stdout or b"", error.stderr or b""
                    record.update(exitCode=None, reaped=True, timedOut=True)
                (folder / "stdout").write_bytes(stdout)
                (folder / "stderr").write_bytes(stderr)

            raw = (folder / "stdout").read_bytes()
            record.update(stdoutBytes=len(raw),
                          stderrBytes=(folder / "stderr").stat().st_size,
                          stdoutSHA256=hashlib.sha256(raw).hexdigest())
            # Decode all stdout. Extra prose or a second JSON result must fail.
            value = json.loads(raw)
            require(isinstance(value, dict), "AXe did not return one JSON object.")
            record["actualActionReceipt"] = value.get("data", {}).get("action")
            record["responseError"] = value.get("error")
            require(record.get("stopReason") is None, "The resource guard stopped this call.")
            require(record.get("reaped") is True, "The command was not reaped.")
            require(record.get("exitCode") == 0 and value.get("didError") is False,
                    "AXe refused or failed this call; inspect its saved result and action receipt.")
            require(record.get("guardExitCode", 0) == 0, "The resource guard failed.")
            require(value.get("schema") == "axe.output.agent-result"
                    and value.get("schemaVersion") == expected_schema_version,
                    f"Expected agent schema {expected_schema_version}; no output fallback is allowed.")
            return value
        except BaseException as error:
            folder.mkdir(mode=0o700, exist_ok=True)
            record["failure"] = str(error)
            if isinstance(error, subprocess.TimeoutExpired):
                record["timedOut"] = True
                (folder / "guard-timeout.stdout").write_bytes(error.stdout or b"")
                (folder / "guard-timeout.stderr").write_bytes(error.stderr or b"")
            raise
        finally:
            record["elapsedSeconds"] = round(time.monotonic() - started, 6)
            if phase == "action" and (value is None or record.get("timedOut")):
                record["inputOutcomeUnknown"] = True
            self.calls.append(record)
            write_json(folder / "call.json", record)
            self.manifest()
            print(json.dumps({"call": record["id"], "phase": phase,
                              "exitCode": record.get("exitCode")}), flush=True)

    def accept_capture(self, value):
        capture = value.get("data", {}).get("capture")
        require(isinstance(capture, dict) and isinstance(capture.get("rows"), list),
                "The result has no usable compact capture.")
        require(isinstance(capture.get("snapshotID"), str), "Missing snapshot ownership ID.")
        self.capture = capture
        self.rows = []
        self.visited = {0}
        self.append_page(capture)

    def append_page(self, capture):
        require(capture.get("snapshotID") == self.capture["snapshotID"],
                "Paging replaced the reference table.")
        for raw in capture["rows"]:
            require(isinstance(raw, str), "A compact row is not text.")
            fields = raw.split("|")
            require(len(fields) == 5, "A compact row must have five columns.")
            self.rows.append(dict(zip(("ref", "actions", "role", "label", "value"), fields)))
        self.next_offset = capture.get("page", {}).get("nextOffset")
        write_json(self.args.out / "latest-rows.json", self.rows)

    def observe(self):
        self.accept_capture(self.call(["describe-ui", "--agent"], "capture"))

    def next_page(self):
        offset = self.next_offset
        if offset is None:
            return False
        require(isinstance(offset, int) and offset > max(self.visited)
                and len(self.visited) < self.args.max_pages,
                "The page cursor did not advance or the explicit page limit was reached.")
        self.visited.add(offset)
        value = self.call(["describe-ui", "--agent", "--snapshot-id",
                           self.capture["snapshotID"], "--row-offset", str(offset)], "page")
        page = value.get("data", {}).get("capture")
        require(isinstance(page, dict) and isinstance(page.get("rows"), list),
                "The next page is not a compact capture.")
        self.append_page(page)
        return True

    def all_pages(self):
        while self.next_page():
            pass

    @staticmethod
    def matches(row, step):
        return all(key not in step or row[key] == step[key]
                   for key in ("ref", "label", "role", "value")) and (
                       "label_prefix" not in step or row["label"].startswith(step["label_prefix"]))

    def find_target(self, step, action):
        while True:
            found = [row for row in self.rows if self.matches(row, step)
                     and action in row["actions"].split(",")]
            require(len(found) <= 1, "The visible row query matches more than one control.")
            if found:
                # An explicit full scan is available when plan-level global uniqueness matters.
                if step.get("scan_all") and self.next_page():
                    continue
                return found[0]
            if not self.next_page():
                return None

    def target(self, step, action):
        row = self.find_target(step, action)
        require(row is not None, f"No visible control supports {action} for this row query.")
        return row

    def assert_read(self, step):
        op = step["op"]
        if op == "buttons":
            self.all_pages()
            labels = {row["label"] for row in self.rows
                      if row["role"] == "button" and "tap" in row["actions"].split(",")}
            missing = set(step["labels"]) - labels
            if missing:
                raise PredicateNotMet("Missing visible buttons: " + repr(sorted(missing)))
        else:
            while True:
                selected = [row for row in self.rows if self.matches(row, step)]
                if op == "expect":
                    text = "\n".join(row["label"] + " " + row["value"] for row in selected)
                    passed = all(needle in text for needle in step["contains"])
                elif op == "text_is":
                    passed = any(row["role"] == "text" and row["label"] == step["text"]
                                 for row in self.rows)
                else:
                    passed = len(selected) == 1 and selected[0]["value"] == step["equals"]
                if passed:
                    return
                if not self.next_page():
                    raise PredicateNotMet("Required visible text or row value was not observed.")

    def action(self, step, record_check=True):
        op = step["op"]
        row = self.target(step, self.ACTIONS[op])
        snapshot = self.capture["snapshotID"]
        command = ["type", step["text"]] if op == "type" else [
            "touch" if op in ("touch", "hold") else op]
        command += ["--agent", "--snapshot-id", snapshot, "--ref", row["ref"]]
        if op == "tap" and step.get("physical", False):
            command += ["--tap-style", "physical"]
        if op in ("touch", "hold"):
            command += ["--down", "--up", "--delay",
                        str(step.get("delay", 0.5 if op == "hold" else 0.05))]
        if op == "swipe":
            command += ["--direction", step["direction"], "--distance",
                        str(step.get("distance", 0.7)), "--duration",
                        str(step.get("duration", 0.4))]
        reply = self.call(command, "action")
        receipt = reply.get("data", {}).get("action")
        require(isinstance(receipt, dict) and receipt.get("replayed") is False
                and receipt.get("cleanup") != "uncertain"
                and receipt.get("outcome") == "enqueuedAndDrained",
                "The action did not establish a completed, non-replayed input receipt.")
        check = {"step": self.active_step, "op": op, "passed": True,
                 "ref": row["ref"], "snapshotID": snapshot,
                 "targetScope": "allPages" if self.next_offset is None else "queriedPages",
                 "actualActionReceipt": receipt}
        if record_check:
            self.checks.append(check)
        # Reuse the public replacement when available, as a normal agent does.
        if isinstance(reply.get("data", {}).get("capture", {}).get("rows"), list):
            self.accept_capture(reply)
        else:
            self.capture = None
        return check

    def scroll_until(self, step):
        swipes = []
        maximum = step.get("max_swipes", 5)
        for count in range(maximum + 1):
            # Each gesture gets a new public observation. A failed input is never retried.
            self.observe()
            target = self.find_target(step["target"], "tap")
            if target is not None:
                self.checks.append({"step": self.active_step, "op": "scroll_until",
                                    "passed": True, "ref": target["ref"],
                                    "snapshotID": self.capture["snapshotID"], "swipes": swipes})
                return
            require(count < maximum, "The target was not visible within the permitted swipes.")
            swipe = {**step["scroll"], "op": "swipe", "direction": step["direction"],
                     "distance": step.get("distance", 0.7),
                     "duration": step.get("duration", 0.4)}
            swipes.append(self.action(swipe, record_check=False))
            require(self.capture is not None,
                    "The completed swipe returned no usable public replacement capture.")

    def execute(self, steps):
        for index, step in enumerate(steps):
            self.active_step = index
            op = step["op"]
            if self.capture is None or step.get("refresh", False) or op == "capture":
                self.observe()
            if op in self.ACTIONS:
                self.action(step)
            elif op == "scroll_until":
                self.scroll_until(step)
            elif op == "capture":
                self.checks.append({"step": index, "op": op, "passed": True})
            else:
                deadline = time.monotonic() + step.get("timeout", 0)
                while True:
                    try:
                        self.assert_read(step)
                        break
                    except PredicateNotMet:
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(min(0.1, max(0, deadline - time.monotonic())))
                        self.observe()
                self.checks.append({"step": index, "op": op, "passed": True,
                                    "snapshotID": self.capture["snapshotID"]})


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--axe", type=Path, required=True, help="Explicit AXe executable path.")
    parser.add_argument("--udid", required=True, help="One existing, warm simulator UUID.")
    parser.add_argument("--out", type=Path, required=True, help="A new evidence directory.")
    parser.add_argument("--plan", type=Path, required=True, help="JSON steps or an object with steps.")
    parser.add_argument("--guard", type=Path, help="Optional existing resource guard Python script.")
    parser.add_argument("--resource-probe", type=Path, help="Required only with --guard.")
    parser.add_argument("--timeout", type=float, default=60, help="Seconds per CLI call.")
    parser.add_argument("--max-pages", type=int, default=256, help="Explicit page bound; fails if reached.")
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-fA-F-]{36}", args.udid), "An explicit simulator UUID is required.")
    args.axe = args.axe.resolve(strict=True)
    args.plan = args.plan.resolve(strict=True)
    args.out = args.out.absolute()
    require(args.axe.is_file() and os.access(args.axe, os.X_OK), "AXe must be executable.")
    require(bool(args.guard) == bool(args.resource_probe), "Supply both --guard and --resource-probe.")
    if args.guard:
        args.guard = args.guard.resolve(strict=True)
        args.resource_probe = args.resource_probe.resolve(strict=True)
        require(args.guard.is_file() and args.resource_probe.is_file(), "Resource tools are absent.")
    require(math.isfinite(args.timeout) and args.timeout > 0 and args.max_pages > 0,
            "Timeout and page bound must be positive and finite.")
    return args


def main():
    args = arguments()
    plan = json.loads(args.plan.read_bytes())
    steps = plan.get("steps") if isinstance(plan, dict) else plan
    require(isinstance(steps, list) and steps, "The plan needs a nonempty steps array.")
    allowed = set(Replay.ACTIONS) | {"expect", "text_is", "buttons", "value", "row_value",
                                   "capture", "scroll_until"}
    for step in steps:
        require(isinstance(step, dict) and step.get("op") in allowed, "Unknown plan operation.")
        op = step["op"]
        for flag in ("refresh", "scan_all", "physical"):
            require(flag not in step or isinstance(step[flag], bool), f"{flag} must be boolean.")
        for field in ("ref", "label", "role", "value"):
            require(field not in step or isinstance(step[field], str), f"{field} must be text.")
        if "label_prefix" in step:
            require(isinstance(step["label_prefix"], str) and step["label_prefix"].strip(),
                    "label_prefix must be nonempty text.")
        timeout = step.get("timeout", 0)
        require(isinstance(timeout, (int, float)) and math.isfinite(timeout) and timeout >= 0,
                "Plan timeout must be finite, nonnegative seconds.")
        if op in ("expect", "buttons"):
            field = "contains" if op == "expect" else "labels"
            require(isinstance(step.get(field), list) and step[field]
                    and all(isinstance(text, str) and text for text in step[field]),
                    f"{field} must be a nonempty array of nonempty text values.")
        if op in ("text_is", "type"):
            require(isinstance(step.get("text"), str), "This operation requires text.")
        if op in ("value", "row_value"):
            require(isinstance(step.get("equals"), str) and "label" in step and "role" in step,
                    "A row-value check requires label, role and equals text.")
        if op in Replay.ACTIONS:
            require(any(field in step for field in ("ref", "label", "role", "value", "label_prefix")),
                    "An action requires a visible row query.")
        if op == "scroll_until":
            maximum = step.get("max_swipes", 5)
            require(type(maximum) is int and 0 <= maximum <= 5,
                    "max_swipes must be an integer in 0...5.")
            for field in ("target", "scroll"):
                query = step.get(field)
                require(isinstance(query, dict) and any(
                    key in query for key in ("ref", "label", "role", "value", "label_prefix")),
                    f"scroll_until requires a {field} row query.")
                for key in ("ref", "label", "role", "value", "label_prefix"):
                    require(key not in query or isinstance(query[key], str),
                            f"The {field} query {key} must be text.")
                require("label_prefix" not in query or query["label_prefix"].strip(),
                        "label_prefix must be nonempty text.")
        if op in ("swipe", "scroll_until"):
            require(step.get("direction") in ("up", "down", "left", "right"),
                    "A swipe requires one supported direction.")
            for field, default, lower, upper in (("distance", 0.7, 0, 1),
                                                  ("duration", 0.4, 0, 10)):
                number = step.get(field, default)
                require(isinstance(number, (int, float)) and math.isfinite(number)
                        and lower < number <= upper, f"Invalid swipe {field}.")
        if op in ("touch", "hold"):
            delay = step.get("delay", 0.5 if op == "hold" else 0.05)
            require(isinstance(delay, (int, float)) and math.isfinite(delay) and 0 <= delay <= 10,
                    "A touch delay must be finite and in 0...10 seconds.")
    args.out.mkdir(parents=True, mode=0o700, exist_ok=False)
    (args.out / "raw").mkdir(mode=0o700)
    write_json(args.out / "plan.json", plan)
    (args.out / "helper.py").write_bytes(Path(__file__).read_bytes())
    replay = Replay(args)
    result = {"status": "FAIL_OR_UNPROVED", "plan": str(args.plan), "udid": args.udid,
              "invokedExecutable": str(args.axe), "invokedFileSHA256": replay.executable_hash,
              "inputRetries": 0, "helperSHA256": sha256(args.out / "helper.py"),
              "helperCopy": str(args.out / "helper.py"),
              "planSHA256": sha256(args.plan),
              "resourceGuardSHA256": sha256(args.guard) if args.guard else None,
              "resourceProbeSHA256": sha256(args.resource_probe) if args.resource_probe else None}
    try:
        replay.execute(steps)
        result["status"] = "PASS"
    except BaseException as error:
        last = replay.calls[-1] if replay.calls else {}
        result["failure"] = {"step": replay.active_step, "message": str(error),
                             "callID": last.get("id"),
                             "actualActionReceipt": last.get("actualActionReceipt"),
                             "responseError": last.get("responseError")}
    finally:
        result.update(checks=replay.checks, calls=len(replay.calls),
                      executableUnchanged=sha256(args.axe) == replay.executable_hash)
        if not result["executableUnchanged"]:
            result["status"] = "FAIL_OR_UNPROVED"
            result["executableChanged"] = True
        replay.manifest()
        write_json(args.out / "result.json", result)
        print(json.dumps({"status": result["status"], "checks": len(replay.checks),
                          "calls": len(replay.calls), "result": str(args.out / "result.json")}), flush=True)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ReplayFailure, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
