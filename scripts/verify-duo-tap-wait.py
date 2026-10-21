#!/usr/bin/env python3
"""Run one approved native selected-tap wait case under guard-duo-command.py.

This tool does not build, install, launch, boot, or reset the app. State changes
use visible UIKit buttons. Application state is read-only evidence. A failed or
uncertain input is never retried. Run the saved verifier as a separate command.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import time
import uuid

BUNDLE = "com.camsoft.duo-tap-wait-probe"
CASES = ("immediate", "delayed-id", "delayed-label", "delayed-value", "timeout", "cancel-int", "cancel-term", "fold", "rotate", "duplicate")


def require(value, reason):
    if not value:
        raise ValueError(reason)


def save(file, value):
    file.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def walk(roots):
    for node in roots:
        yield node
        yield from walk(node.get("children", []))


class Check:
    def __init__(self, args):
        self.args = args
        self.out = args.out
        self.out.mkdir(parents=True, exist_ok=False)
        self.children = {}
        self.processes = {}
        self.phase = "freeze"
        self.state_file = None
        self.selection = self.selected(args.screen_id, args.screen_uuid)
        self.config = {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()}
        self.config.update(bundleIdentifier=BUNDLE, startedHostMonotonic=time.monotonic(), securityScan="UNVERIFIED")
        save(self.out / "configuration.json", self.config)

    def selected(self, screen, screen_uuid):
        return ["--udid", self.args.udid, "--input-mode", "selected", "--screen-id", str(screen),
                "--screen-uuid", screen_uuid, "--expected-pid", str(self.args.pid)]

    def freeze(self):
        plist = plistlib.loads((self.args.fixture_app / "Info.plist").read_bytes())
        require(plist["CFBundleIdentifier"] == BUNDLE, "Wrong fixture app bundle ID")
        frozen = self.out / "candidate"
        frozen.mkdir()
        sources = [("cli", self.args.cli), ("helper", self.args.helper), ("operator", self.args.operator),
                   ("driver", Path(__file__).resolve())]
        for name in ("FBSimulatorControl", "FBControlCore", "FBDeviceControl", "XCTestBootstrap"):
            sources.append((name, self.args.cli.parent / (name + ".framework/Versions/A/" + name)))
        for name in ("Sources/AXe/Commands/Tap.swift", "Sources/AXe/Commands/Batch.swift",
                     "Sources/AXe/Utilities/SelectedAXProtocol.swift", "Sources/AXe/Utilities/SelectedAXOperation.swift",
                     "Sources/AXe/Utilities/SelectedAXOptions.swift", "Sources/AXe/Utilities/SelectedHIDProtocol.swift",
                     "Sources/AXe/Utilities/SelectedAXWait.swift", "Sources/AXe/Utilities/SelectedHIDClientLifetime.swift",
                     "Sources/AXe/Utilities/SelectedHIDBroker.swift", "Sources/AXe/Utilities/SelectedHIDOwner.swift",
                     "Sources/AXe/Utilities/Batch/SelectedBatch.swift", "scripts/fixtures/DuoTapWaitProbe.m",
                     "scripts/fixtures/DuoExternalStateChange.swift", "patches/idb-duo-foundation.patch",
                     "patches/idb-duo-foundation.sha256"):
            sources.append(("source/" + name, self.args.source_root / name))
        files = []
        for label, original in sources:
            original = original.resolve(strict=True)
            copy = frozen / label
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, copy)
            files.append(dict(label=label, original=str(original), snapshot=str(copy.relative_to(self.out)), sha256=digest(copy)))
        fixture = frozen / "DuoTapWaitProbe.app"
        shutil.copytree(self.args.fixture_app, fixture, symlinks=True)
        for original in sorted(self.args.fixture_app.rglob("*")):
            if original.is_file():
                relative = original.relative_to(self.args.fixture_app)
                files.append(dict(label="fixture/" + str(relative), original=str(original.resolve()),
                                  snapshot=str((fixture / relative).relative_to(self.out)), sha256=digest(fixture / relative)))
        self.pins = files
        save(self.out / "frozen-inputs.json", dict(beforeInput=True, savedVerifierIncluded=False, files=files))

    def start(self, name, argv):
        require(name not in self.children, "Command name reused: " + name)
        save(self.out / (name + "-argv.json"), argv)
        with (self.out / (name + ".stdout")).open("xb") as stdout, (self.out / (name + ".stderr")).open("xb") as stderr:
            child = subprocess.Popen(argv, stdout=stdout, stderr=stderr)
        self.children[name] = child
        self.processes[name] = dict(command=argv, pid=child.pid, startedHostMonotonic=time.monotonic(), signals=[])
        save(self.out / (name + "-started.json"), self.processes[name])
        return child

    def finish(self, name, timeout=30, expected=None, as_json=True):
        child = self.children[name]
        try:
            child.wait(timeout=timeout)
        except BaseException:
            self.stop(name)
            raise
        record = self.processes[name]
        record.update(exitCode=child.returncode, reaped=child.poll() is not None, finishedHostMonotonic=time.monotonic())
        save(self.out / (name + "-process.json"), record)
        if expected is not None:
            require(child.returncode == expected, name + " exited " + str(child.returncode) + "; no replay")
        text = (self.out / (name + ".stdout")).read_text()
        return json.loads(text) if as_json else text

    def stop(self, name):
        child = self.children[name]
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
            if child.poll() is not None:
                break
            child.send_signal(sig)
            self.processes[name]["signals"].append(sig.name)
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
        self.processes[name].update(exitCode=child.poll(), reaped=child.poll() is not None,
                                    finishedHostMonotonic=time.monotonic())
        save(self.out / (name + "-process.json"), self.processes[name])

    def run(self, name, argv, expected=0, as_json=True):
        self.start(name, argv)
        return self.finish(name, expected=expected, as_json=as_json)

    def axe(self, name, verb, extra=(), selection=None, expected=0):
        return self.run(name, [str(self.args.cli), verb, *extra, *(selection or self.selection)], expected=expected)

    def bind(self, name):
        container = self.run(name + "-container", ["/usr/bin/xcrun", "simctl", "get_app_container", self.args.udid, BUNDLE, "data"], as_json=False).strip()
        text = self.run(name + "-pid", ["/usr/bin/xcrun", "simctl", "spawn", self.args.udid, "launchctl", "list"], as_json=False)
        rows = [line.split() for line in text.splitlines() if "UIKitApplication:" + BUNDLE + "[" in line]
        require(len(rows) == 1 and rows[0][0] == str(self.args.pid), "The live fixture PID differs")
        filename = Path(container).resolve(strict=True) / "Documents/state.json"
        save(self.out / (name + "-binding.json"), dict(bundleIdentifier=BUNDLE, pid=self.args.pid, stateFile=str(filename)))
        return filename

    def state(self):
        value = json.loads(self.state_file.read_text())
        require(value["fixtureVersion"] == 1 and value["bundleIdentifier"] == BUNDLE and value["pid"] == self.args.pid,
                "Wrong application state binding")
        require(value["windowTraceDropped"] == 0, "Contact overflow prevents attribution")
        return value

    def snapshot(self, name):
        value = self.state()
        save(self.out / (name + ".json"), value)
        return value

    def await_state(self, name, predicate, seconds=5):
        deadline = time.monotonic() + seconds
        while True:
            value = self.state()
            if predicate(value):
                save(self.out / (name + ".json"), value)
                return value
            require(time.monotonic() < deadline, "State readback timeout: " + name)
            time.sleep(.025)

    def catalogue(self, name, expected_selection=True):
        value = self.run(name, [str(self.args.cli), "list-simulators", "--displays", "--udid", self.args.udid])
        require(value["requestedSimulatorUDID"].upper() == self.args.udid.upper(), "Wrong simulator catalogue")
        require(value["bootIdentity"] == self.args.boot, "Boot identity changed")
        panel = value["activePanel"]
        require(panel["active"], "No active panel")
        if expected_selection:
            require(panel["identity"]["displayID"] == self.args.screen_id and
                    uuid.UUID(panel["identity"]["uniqueID"]) == uuid.UUID(self.args.screen_uuid), "Selected panel differs")
        return value

    def describe(self, name, identifier, selection=None):
        value = self.axe(name, "describe-ui", ["--ax-preparation", "automation-session"], selection)
        matches = [node for node in walk(value.get("ax", {}).get("roots", [])) if node.get("AXUniqueId") == identifier]
        require(len(matches) == 1 and matches[0].get("pid") == self.args.pid and matches[0].get("enabled"),
                "A visible owned button is not unique: " + identifier)
        return value

    def button(self, name, identifier, count, selection=None):
        self.describe(name + "-describe", identifier, selection)
        before = self.snapshot(name + "-before")
        response = self.axe(name, "tap", ["--id", identifier, "--element-type", "Button", "--tap-style", "physical"], selection)
        require(response.get("error") is None and response["outcome"] == "enqueuedAndDrained" and
                response["enqueuedEventCount"] == 2 and response["cleanup"] == "notNeeded", "Visible button input failed")
        after = self.await_state(name + "-after", lambda state: state["counts"].get(count, 0) == before["counts"].get(count, 0) + 1
                                 and state["activeWindowTouches"] == 0)
        self.contact_delta(before, after, [identifier])
        return after

    def contact_delta(self, before, after, identifiers):
        suffix = after["windowTouchTrace"][len(before["windowTouchTrace"]):]
        require(len(suffix) == len(identifiers) * 2, "Unexpected contact record count")
        for offset, identifier in enumerate(identifiers):
            began, ended = suffix[offset * 2:offset * 2 + 2]
            require(began["phase"] == "began" and ended["phase"] == "ended" and began["contactID"] > 0 and
                    began["contactID"] == ended["contactID"] and all(row["hitView"] == identifier for row in (began, ended)),
                    "Button contact did not begin and end on the owned control")
        require(after["activeWindowTouches"] == 0, "Contact remains held")

    def target_command(self):
        selector = ["--label", "Delayed target"] if self.args.case == "delayed-label" else ["--id", "wait.target"]
        if self.args.case == "delayed-value":
            selector = ["--value", "ready"]
        wait = 0 if self.args.case == "immediate" else self.args.wait_timeout
        arguments = [*selector, "--element-type", "Button", "--wait-timeout", str(wait),
                     "--poll-interval", str(self.args.poll_interval), "--expected-pid", str(self.args.pid)]
        if self.args.batch:
            steps = ["tap " + shlex.join(arguments),
                     "tap --id wait.sentinel --element-type Button --expected-pid " + str(self.args.pid)]
            batch_selection = self.selection[:-2]
            return [str(self.args.cli), "batch", *batch_selection, "--step", steps[0], "--step", steps[1]]
        return [str(self.args.cli), "tap", *arguments, *self.selection[:-2]]

    def busy_witness(self):
        time.sleep(.1)
        deadline = time.monotonic() + 2
        attempts = []
        while True:
            require(self.children["target"].poll() is None, "Wait client exited before the owner witness")
            name = "owner-witness-" + str(len(attempts) + 1)
            value = self.axe(name, "describe-ui", ["--ax-preparation", "existing-bridge"], expected=None)
            attempts.append(name)
            save(self.out / "owner-witness.json", dict(attempts=attempts, matched=None))
            state = self.snapshot(name + "-state")
            require(not state["targetVisible"] and state["activeWindowTouches"] == 0, "Target appeared before the owner witness")
            busy = value["outcome"] == "rejectedBeforeInput" and "busy" in json.dumps(value).lower()
            require(value["enqueuedEventCount"] == 0, "Read-only witness reported input")
            if busy:
                require(self.processes[name]["exitCode"] == 1, "Busy read returned an unexpected exit")
                self.busy_name = name
                save(self.out / "at-owner-busy.json", state)
                save(self.out / "owner-witness.json", dict(attempts=attempts, matched=name, brokerID=value["brokerID"]))
                return
            require(value["outcome"] == "ready" and self.processes[name]["exitCode"] == 0 and not value.get("error"),
                    "Owner witness failed for a reason other than pre-admission ordering")
            require(time.monotonic() < deadline, "No owner-active witness within two seconds")
            time.sleep(.05)

    def observe_until(self, deadline):
        observed_visible = False
        with (self.out / "observations.jsonl").open("x") as output:
            while True:
                state = self.state()
                observed_visible |= state["targetVisible"]
                row = dict(hostMonotonic=time.monotonic(), sequence=state["sequence"], targetVisible=state["targetVisible"],
                           activeWindowTouches=state["activeWindowTouches"], counts=state["counts"],
                           traceCount=len(state["windowTouchTrace"]), traceDropped=state["windowTraceDropped"])
                output.write(json.dumps(row, allow_nan=False) + "\n")
                output.flush()
                if row["hostMonotonic"] >= deadline:
                    break
                time.sleep(.05)
        return observed_visible

    def response(self, text):
        rows = [json.loads(line) for line in text.splitlines() if line.strip()]
        if self.args.batch:
            save(self.out / "target-rows.json", rows)
            require(rows and rows[0]["index"] == 1, "Missing first batch receipt")
            return rows[0].get("response"), rows
        require(len(rows) == 1, "Expected one standalone receipt")
        return rows[0], rows

    def verify_case(self):
        self.freeze()
        self.phase = "bind"
        self.state_file = self.bind("before")
        self.catalogue("catalogue-before")
        self.phase = "visible-setup"
        self.button("hide", "wait.hide", "hide")
        if self.args.case in ("immediate", "duplicate"):
            self.button("show", "wait.show", "show")
            if self.args.case == "duplicate":
                self.button("duplicate", "wait.duplicateControl", "duplicateControl")
        elif self.args.case != "timeout":
            seconds = 3 if self.args.case in ("delayed-id", "delayed-label", "delayed-value") else 8
            self.button("schedule", "wait.start" + str(seconds), "start" + str(seconds))
        before = self.snapshot("before-wait")
        require(before["activeWindowTouches"] == 0, "Setup left held input")
        self.phase = "target-request"
        self.start("target", self.target_command())
        started = self.processes["target"]["startedHostMonotonic"]
        if self.args.case not in ("immediate", "duplicate"):
            self.busy_witness()
        observation_deadline = started + self.args.wait_timeout + 1
        if self.args.case in ("cancel-int", "cancel-term", "fold", "rotate"):
            # Include the existing eight-second final-target budget. This bound
            # deliberately exceeds the original polling window after the witness.
            observation_deadline = self.processes[self.busy_name]["finishedHostMonotonic"] + self.args.wait_timeout + 9
            save(self.out / "observation-bound.json", dict(deadlineHostMonotonic=observation_deadline,
                 ownerWitnessHostMonotonic=self.processes[self.busy_name]["finishedHostMonotonic"],
                 pollingBudgetSeconds=self.args.wait_timeout, existingTargetBudgetSeconds=8, settleSeconds=1))
        if self.args.case.startswith("cancel-"):
            self.phase = "cancel"
            sig = signal.SIGINT if self.args.case == "cancel-int" else signal.SIGTERM
            self.children["target"].send_signal(sig)
            self.processes["target"]["signals"].append(sig.name)
            save(self.out / "cancellation.json", dict(signal=sig.name, sentHostMonotonic=time.monotonic(),
                                                      observationDeadlineHostMonotonic=observation_deadline))
        if self.args.case in ("fold", "rotate"):
            self.phase = "external-change"
            self.run("external-change", [str(self.args.operator), self.args.case, self.args.boot, str(self.args.screen_id),
                self.args.screen_uuid, str(self.args.fold_degrees), str(self.out / "change-marker.json"), self.args.udid, str(self.args.helper)])
        self.phase = "await-target-client"
        text = self.finish("target", timeout=40 if not self.args.case.startswith("cancel-") else 5, as_json=False)
        positive = self.args.case in ("immediate", "delayed-id", "delayed-label", "delayed-value")
        code = self.children["target"].returncode
        require(code == 0 if positive else code != 0, "Unexpected target exit; no replay")
        if not self.args.case.startswith("cancel-"):
            response, rows = self.response(text)
            require(response is not None, "A broker response is required")
            if positive:
                require(response.get("error") is None and response["outcome"] == "enqueuedAndDrained" and
                        response["enqueuedEventCount"] == 2 and response["cleanup"] == "notNeeded", "Target tap did not complete")
                if self.args.case != "immediate":
                    require(response["ax"]["wait"]["outcome"] == "matched" and response["ax"]["wait"]["attempts"] >= 2,
                            "Delayed target did not require repeated fresh probes")
                require(len(rows) == (2 if self.args.batch else 1), "Missing or extra success receipt")
            else:
                require(response["enqueuedEventCount"] == 0 and response["cleanup"] == "notNeeded" and response.get("error"),
                        "Negative case sent input or has uncertain cleanup")
                if self.args.case == "timeout":
                    require(response["ax"]["wait"]["outcome"] == "timedOut", "Absent target did not time out")
                require(len(rows) == 1, "A later batch step ran after failure")
        self.phase = "observe-no-late-input"
        if self.args.case in ("fold", "rotate", "cancel-int", "cancel-term"):
            require(self.observe_until(observation_deadline), "The delayed target never appeared after interruption")
        elif not positive:
            self.observe_until(time.monotonic() + .5)
        expected = ["wait.target"] + (["wait.sentinel"] if self.args.batch else []) if positive else []
        after = self.await_state("after-wait", lambda state: state["activeWindowTouches"] == 0 and
                                 (not positive or (state["counts"].get("target", 0) == before["counts"].get("target", 0) + 1 and
                                  (not self.args.batch or state["counts"].get("sentinel", 0) == before["counts"].get("sentinel", 0) + 1))))
        self.contact_delta(before, after, expected)
        for key in set(before["counts"]) | set(after["counts"]):
            increase = 1 if positive and (key == "target" or (self.args.batch and key == "sentinel")) else 0
            if key in ("began", "ended"):
                increase = len(expected)
            if key == "appeared" and self.args.case not in ("immediate", "timeout", "duplicate"):
                increase = 1
            require(after["counts"].get(key, 0) == before["counts"].get(key, 0) + increase, "Unexpected callback: " + key)
        if self.args.case in ("cancel-int", "cancel-term", "timeout", "duplicate"):
            self.phase = "owner-released"
            self.describe("owner-ready", "wait.fresh")
        if self.args.case in ("fold", "rotate", "cancel-int", "cancel-term"):
            self.phase = "fresh-selection"
            fresh = self.catalogue("catalogue-after", expected_selection=False)
            identity = fresh["activePanel"]["identity"]
            selection = self.selected(identity["displayID"], identity["uniqueID"])
            self.button("fresh", "wait.target", "target", selection)
        self.phase = "final-binding"
        require(self.bind("after") == self.state_file, "App data container changed")
        self.snapshot("final-state")
        for pin in self.pins:
            require(digest(Path(pin["original"])) == pin["sha256"], "A frozen native input changed: " + pin["label"])
        return dict(status="PASS_BOUNDED", case=self.args.case, batch=self.args.batch, nativeInputReplayed=False,
                    securityScan="UNVERIFIED", scope="One explicit candidate, fixture process, boot and selected starting pose")

    def close(self):
        for name, child in self.children.items():
            if child.poll() is None:
                self.stop(name)
        save(self.out / "all-processes.json", self.processes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES, required=True)
    parser.add_argument("--batch", action="store_true")
    for name in ("cli", "helper", "operator", "fixture-app", "source-root", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("udid", "boot", "screen-uuid"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--screen-id", type=int, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--wait-timeout", type=float, default=12)
    parser.add_argument("--poll-interval", type=float, default=.25)
    parser.add_argument("--fold-degrees", type=float, default=0)
    args = parser.parse_args()
    for name in ("cli", "helper", "operator", "fixture_app", "source_root"):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    args.out = args.out.resolve()
    uuid.UUID(args.udid)
    uuid.UUID(args.screen_uuid)
    require(args.helper == args.cli.with_name("cadisplay-context").resolve(strict=True), "Helper must be the CLI's sibling")
    require(args.pid > 0 and args.screen_id > 0, "PID and screen ID must be positive")
    require(math.isfinite(args.wait_timeout) and 0 < args.wait_timeout <= 30, "Wait timeout must be in (0, 30]")
    require(math.isfinite(args.poll_interval) and .05 <= args.poll_interval <= 30, "Poll interval must be in [0.05, 30]")
    require(math.isfinite(args.fold_degrees) and 0 <= args.fold_degrees <= 180, "Fold angle must be in [0, 180]")
    if args.case in ("cancel-int", "cancel-term", "fold", "rotate"):
        require(args.wait_timeout >= 10, "Interrupted cases need a timeout of at least ten seconds")
    check = Check(args)
    try:
        result = check.verify_case()
        check.close()
        save(check.out / "result.json", result)
        print(json.dumps(result))
    except BaseException as error:
        check.close()
        save(check.out / "failure.json", dict(status="FAILED_NO_REPLAY", phase=check.phase, error=repr(error)))
        raise


if __name__ == "__main__":
    main()
