#!/usr/bin/env python3
"""Check saved tap-wait evidence. This tool starts no process and sends no input."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shlex
import uuid

BUNDLE = "com.camsoft.duo-tap-wait-probe"


def require(value, reason):
    if not value:
        raise ValueError(reason)


def read(folder, name):
    return json.loads((folder / name).read_text())


def state(folder, name, config):
    value = read(folder, name + ".json")
    require(value["fixtureVersion"] == 1 and value["bundleIdentifier"] == BUNDLE and value["pid"] == config["pid"], "Wrong fixture binding")
    require(value["windowTraceDropped"] == 0 and value["activeWindowTouches"] == 0, "Held or missing contact evidence")
    return value


def contacts(before, after, identifiers):
    require(after["windowTouchTrace"][:len(before["windowTouchTrace"])] == before["windowTouchTrace"], "Contact history changed")
    suffix = after["windowTouchTrace"][len(before["windowTouchTrace"]):]
    require(len(suffix) == len(identifiers) * 2, "Unexpected contact delta")
    ids = set()
    for index, identifier in enumerate(identifiers):
        began, ended = suffix[index * 2:index * 2 + 2]
        require(began["phase"] == "began" and ended["phase"] == "ended" and began["contactID"] == ended["contactID"]
                and began["contactID"] > 0 and began["contactID"] not in ids, "Incomplete or reused contact")
        require(began["activeTouches"] == 1 and ended["activeTouches"] == 0, "Wrong contact release state")
        require(all(row["hitView"] == identifier and math.isfinite(row["x"]) and math.isfinite(row["y"]) for row in (began, ended)), "Wrong contact hit or point")
        require(ended["guestUptime"] >= began["guestUptime"], "Guest contact time moved backwards")
        ids.add(began["contactID"])
    return suffix


def tap(response, identifier, config, trace):
    require(response.get("error") is None and response["outcome"] == "enqueuedAndDrained" and
            response["enqueuedEventCount"] == 2 and response["cleanup"] == "notNeeded" and not response.get("quarantine"), "Tap transport did not complete")
    context = response["context"]
    require(context["bootIdentity"] == config["boot"], "Tap boot differs")
    ax = response["ax"]
    validation = ax["validation"]
    require(ax["target"]["AXUniqueId"] == identifier and ax["target"]["pid"] == config["pid"] and
            validation["expectedPID"] == validation["frontmostPID"] == config["pid"] and
            validation["verifiedTarget"]["AXUniqueId"] == identifier and validation["verifiedTarget"]["pid"] == config["pid"], "Tap ownership evidence differs")
    require(all(abs(row["x"] - ax["point"]["x"]) < .5 and abs(row["y"] - ax["point"]["y"]) < .5 for row in trace), "App contact differs from the validated target point")


def check(folder):
    config = read(folder, "configuration.json")
    manifest = read(folder, "frozen-inputs.json")
    require(manifest["beforeInput"] and manifest["savedVerifierIncluded"] is False, "Invalid pre-input manifest scope")
    labels = set()
    for entry in manifest["files"]:
        require(entry["label"] not in labels, "Duplicate frozen label")
        labels.add(entry["label"])
        file = (folder / entry["snapshot"]).resolve(strict=True)
        require(file.is_relative_to(folder.resolve()), "Frozen copy leaves evidence directory")
        require(hashlib.sha256(file.read_bytes()).hexdigest() == entry["sha256"], "Frozen hash differs: " + entry["label"])
    require({"cli", "helper", "operator", "driver", "FBSimulatorControl", "FBControlCore", "FBDeviceControl", "XCTestBootstrap"} <= labels, "Missing runtime pins")
    require(any(label.startswith("fixture/") for label in labels), "Missing fixture pins")
    processes = read(folder, "all-processes.json")
    require(processes and all(row["reaped"] and row["exitCode"] is not None for row in processes.values()), "An owned child was not reaped")
    for name, row in processes.items():
        require(read(folder, name + "-argv.json") == row["command"], "Saved command differs")
        require(row["finishedHostMonotonic"] >= row["startedHostMonotonic"], "Host process time moved backwards")
        if name != "target" and not name.startswith("owner-witness-"):
            require(row["exitCode"] == 0 and not row["signals"], "Setup/read command failed or required termination: " + name)
    binding = read(folder, "before-binding.json")
    require(binding == read(folder, "after-binding.json") and binding["pid"] == config["pid"] and binding["bundleIdentifier"] == BUNDLE, "Native app binding changed")
    for name in ("before", "after"):
        container = (folder / (name + "-container.stdout")).read_text().strip()
        require(str(Path(container) / "Documents/state.json") == binding["stateFile"], "Saved container binding differs")
        lines = (folder / (name + "-pid.stdout")).read_text().splitlines()
        rows = [line.split() for line in lines if "UIKitApplication:" + BUNDLE + "[" in line]
        require(len(rows) == 1 and rows[0][0] == str(config["pid"]), "Saved native PID differs")
    selection = ["--udid", config["udid"], "--input-mode", "selected", "--screen-id", str(config["screen_id"]),
                 "--screen-uuid", config["screen_uuid"]]
    selector = ["--label", "Delayed target"] if config["case"] == "delayed-label" else ["--id", "wait.target"]
    if config["case"] == "delayed-value":
        selector = ["--value", "ready"]
    budget = 0 if config["case"] == "immediate" else config["wait_timeout"]
    arguments = [*selector, "--element-type", "Button", "--wait-timeout", str(budget), "--poll-interval", str(config["poll_interval"]),
                 "--expected-pid", str(config["pid"])]
    command = [config["cli"], "tap", *arguments, *selection]
    if config["batch"]:
        command = [config["cli"], "batch", *selection, "--step", "tap " + shlex.join(arguments), "--step",
                   "tap --id wait.sentinel --element-type Button --expected-pid " + str(config["pid"])]
    require(processes["target"]["command"] == command, "Target policy or selected command differs")
    before = state(folder, "before-wait", config)
    after = state(folder, "after-wait", config)
    final = state(folder, "final-state", config)
    positive = config["case"] in ("immediate", "delayed-id", "delayed-label", "delayed-value")
    interrupted = config["case"] in ("cancel-int", "cancel-term", "fold", "rotate")
    identifiers = ["wait.target"] + (["wait.sentinel"] if config["batch"] else []) if positive else []
    trace = contacts(before, after, identifiers)
    require((processes["target"]["exitCode"] == 0) == positive, "Wrong target exit")
    if config["case"] != "immediate":
        require(not before["targetVisible"] if config["case"] != "duplicate" else before["duplicateVisible"] and before["targetVisible"], "Wrong starting target visibility")
    if config["case"] not in ("immediate", "duplicate"):
        witness_record = read(folder, "owner-witness.json")
        names = witness_record["attempts"]
        require(names and witness_record["matched"] == names[-1] and
                names == ["owner-witness-" + str(index + 1) for index in range(len(names))], "Missing witness attempts")
        busy_name = witness_record["matched"]
        for name in names:
            attempt = read(folder, name + ".stdout")
            attempt_state = state(folder, name + "-state", config)
            require(not attempt_state["targetVisible"] and attempt_state["windowTouchTrace"] == before["windowTouchTrace"], "Appearance or input preceded a witness attempt")
            require(attempt["enqueuedEventCount"] == 0 and not processes[name]["signals"], "Witness sent input or required termination")
            if name != busy_name:
                require(attempt["outcome"] == "ready" and not attempt.get("error") and processes[name]["exitCode"] == 0,
                        "An earlier read-only witness did not complete normally")
        busy = read(folder, busy_name + ".stdout")
        require(processes[busy_name]["exitCode"] != 0 and busy["outcome"] == "rejectedBeforeInput" and
                busy["enqueuedEventCount"] == 0 and "busy" in json.dumps(busy).lower(), "No owner-active witness")
        require(witness_record["brokerID"] == busy["brokerID"], "Witness owner differs")
        witness = state(folder, "at-owner-busy", config)
        require(not witness["targetVisible"] and witness["windowTouchTrace"] == before["windowTouchTrace"], "Input or appearance preceded the witness")
    if not config["case"].startswith("cancel-"):
        rows = [json.loads(line) for line in (folder / "target.stdout").read_text().splitlines() if line.strip()]
        require(len(rows) == (2 if positive and config["batch"] else 1), "Wrong number of batch/standalone receipts")
        if config["batch"]:
            require(rows[0]["index"] == 1 and rows[0]["totalSteps"] == 2 and rows[0]["command"] == "tap", "Wrong first batch step")
            response = rows[0]["response"]
        else:
            response = rows[0]
        if positive:
            tap(response, "wait.target", config, trace[:2])
            require(response["context"]["screenID"] == config["screen_id"] and
                    uuid.UUID(response["context"]["screenUUID"]) == uuid.UUID(config["screen_uuid"]), "Tap selection differs")
            if config["case"] != "immediate":
                waiting = response["ax"]["wait"]
                require(waiting["outcome"] == "matched" and waiting["attempts"] >= 2 and
                        0 <= waiting["elapsedSeconds"] <= config["wait_timeout"] + 1, "Missing repeated bounded polling")
            if config["batch"]:
                require(all(row["status"] == "completed" for row in rows) and rows[1]["index"] == 2, "Batch did not complete both steps")
                tap(rows[1]["response"], "wait.sentinel", config, trace[2:])
        else:
            require(response["enqueuedEventCount"] == 0 and response["cleanup"] == "notNeeded" and response.get("error") and not response.get("quarantine"), "Failure has possible input")
            if config["case"] == "timeout":
                require(response["ax"]["wait"]["outcome"] == "timedOut" and response["ax"]["failure"] == "waitTimedOut", "Wrong timeout evidence")
                elapsed = response["ax"]["wait"]["elapsedSeconds"]
                require(config["wait_timeout"] - .1 <= elapsed <= config["wait_timeout"] + 1, "Timeout receipt exceeded its bounded polling window")
    for key in set(before["counts"]) | set(after["counts"]):
        delta = 1 if positive and (key == "target" or (config["batch"] and key == "sentinel")) else 0
        if key in ("began", "ended"):
            delta = len(identifiers)
        if key == "appeared" and config["case"] not in ("immediate", "timeout", "duplicate"):
            delta = 1
        require(after["counts"].get(key, 0) - before["counts"].get(key, 0) == delta, "Unexpected app callback: " + key)
    if interrupted:
        samples = [json.loads(line) for line in (folder / "observations.jsonl").read_text().splitlines()]
        require(samples and any(row["targetVisible"] for row in samples), "No observed appearance after interruption")
        bound = read(folder, "observation-bound.json")
        deadline = bound["deadlineHostMonotonic"]
        require(deadline == processes[busy_name]["finishedHostMonotonic"] + config["wait_timeout"] + 9,
                "Observation bound omits the polling, target or settle budget")
        require(samples[-1]["hostMonotonic"] >= deadline, "Observation ended before the complete wait bound")
        require(all(row["activeWindowTouches"] == 0 and row["traceDropped"] == 0 and
                    row["traceCount"] == len(before["windowTouchTrace"]) for row in samples), "Input occurred after interruption")
        if config["case"].startswith("cancel-"):
            cancellation = read(folder, "cancellation.json")
            expected = "SIGINT" if config["case"] == "cancel-int" else "SIGTERM"
            require(cancellation["signal"] == expected and processes["target"]["signals"] == [expected] and
                    processes["target"]["finishedHostMonotonic"] - cancellation["sentHostMonotonic"] <= 5 and
                    cancellation["observationDeadlineHostMonotonic"] == deadline, "Client cancellation was not bounded")
        else:
            change = read(folder, "external-change.stdout")
            if config["case"] == "fold":
                require(change["hinge"]["outcome"] == "observedMechanicalTarget" and
                        change["hinge"]["before"]["mechanicalDegrees"] != change["hinge"]["requestedDegrees"], "No actual fold change")
            else:
                require(change["rotation"]["vendorEventCount"] == 1 and
                        change["rotation"]["before"]["rotation"] != change["rotation"]["after"]["rotation"], "No actual rotation change")
        fresh_before = state(folder, "fresh-before", config)
        fresh_after = state(folder, "fresh-after", config)
        require(fresh_before["windowTouchTrace"] == after["windowTouchTrace"], "Input appeared before the fresh selection")
        fresh_trace = contacts(fresh_before, fresh_after, ["wait.target"])
        tap(read(folder, "fresh.stdout"), "wait.target", config, fresh_trace)
        require(fresh_after["counts"].get("target", 0) == fresh_before["counts"].get("target", 0) + 1, "Missing fresh callback")
        require(final["windowTouchTrace"] == fresh_after["windowTouchTrace"], "Late input followed the fresh tap")
    if not interrupted:
        require(final["windowTouchTrace"] == after["windowTouchTrace"] and final["counts"] == after["counts"], "Final state has extra input")
    if config["case"] in ("cancel-int", "cancel-term", "timeout", "duplicate"):
        ready = read(folder, "owner-ready.stdout")
        require(ready["outcome"] == "ready" and ready["enqueuedEventCount"] == 0 and not ready.get("error"), "Owner did not accept a later read-only command")
        if config["case"].startswith("cancel-"):
            require(ready["brokerID"] == read(folder, busy_name + ".stdout")["brokerID"], "The waiting owner was replaced before the release check")
    return dict(status="SAVED_EVIDENCE_PASS_BOUNDED", case=config["case"], batch=config["batch"],
                frozenFiles=len(manifest["files"]), processes=len(processes), nativeActionsStarted=False,
                securityScan="UNVERIFIED", scope="Saved raw commands, receipts, bindings, callbacks and contacts for one candidate case")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    result = check(args.folder.resolve(strict=True))
    with args.out.open("x") as output:
        json.dump(result, output, indent=2, sort_keys=True, allow_nan=False)
        output.write("\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
