#!/usr/bin/env python3
"""Read the parallel regression evidence. Does not run the CLI or simulator."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve(strict=True)
repo = Path(sys.argv[2]).resolve(strict=True)
pins = json.loads((root / "regression-native-tool-pins-v2.json").read_text())
for name, expected in pins["files"].items():
    assert hashlib.sha256((repo / name).read_bytes()).hexdigest() == expected, name


def read(folder, name):
    return json.loads((folder / name).read_text())


def walk(roots):
    for node in roots:
        yield node
        yield from walk(node.get("children", []))


accepted = []
for device in ("iphone", "ipad"):
    for mode in ("legacy", "selected"):
        for action in ("tap", "swipe", "focus", "type", "return"):
            name = "regression-" + device + "-" + mode + "-" + action
            if (device, mode, action) == ("iphone", "legacy", "swipe"):
                name += "-v2"
            folder = root / name
            result = read(folder, "result.json")
            candidate = read(folder, "candidate.json")
            before = read(folder, "before.json")
            after = read(folder, "after.json")
            assert result["status"] == "PASS" and result["realEffect"]
            assert candidate["cliSHA256"] == pins["files"][".build/out/Products/Debug/axe"]
            assert result["mode"] == mode and result["case"] == action
            assert before["activeWindowTouches"] == after["activeWindowTouches"] == 0
            assert before["interfaceOrientation"] == after["interfaceOrientation"] == 1
            assert (before["width"], before["height"]) == (after["width"], after["height"])
            assert before["slider"] == after["slider"] and before["switchOn"] == after["switchOn"]
            assert before["windowTraceDropped"] == after["windowTraceDropped"]
            trace = after["windowTouchTrace"]
            count = len(before["windowTouchTrace"])
            assert trace[:count] == before["windowTouchTrace"]
            contacts = trace[count:]
            description = read(folder, "describe-before.stdout")
            roots = description["ax"]["roots"] if mode == "selected" else description
            identifier = "feature.pad" if action == "swipe" else "feature.tap" if action == "tap" else "feature.text"
            matches = [n for n in walk(roots) if n.get("AXUniqueId") == identifier]
            assert len(matches) == 1 and matches[0]["pid"] == result["pid"]
            if action in ("tap", "swipe", "focus"):
                assert contacts[0]["phase"] == "windowTouchBegan" and contacts[-1]["phase"] == "windowTouchEnded"
                assert len({c["contactID"] for c in contacts}) == 1 and contacts[-1]["activeTouches"] == 0
                frame = matches[0]["frame"]
                x, y = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
                points = [(x - 40, y), (x + 40, y)] if action == "swipe" else [(x, y), (x, y)]
                for actual, expected in zip([contacts[0], contacts[-1]], points):
                    assert abs(actual["x"] - expected[0]) < .5 and abs(actual["y"] - expected[1]) < .5
            else:
                assert contacts == []
            if action in ("tap", "swipe"):
                key = "tap" if action == "tap" else "pan"
                assert after["counts"].get(key, 0) == before["counts"].get(key, 0) + 1
            if action == "swipe":
                pan = [r for r in after["recognizerTrace"][len(before["recognizerTrace"]):] if r["name"] == "pan"]
                assert pan[0]["state"] == 1 and pan[-1]["state"] == 3
                assert sum(r["state"] == 3 for r in pan) == 1
                assert abs(after["panX"] - pan[-1]["x"] + pan[0]["x"]) < 1
                assert abs(after["panY"] - pan[-1]["y"] + pan[0]["y"]) < 1
            if action == "focus":
                assert not before["textFocused"] and after["textFocused"]
            if action == "type":
                assert after["text"] == before["text"] + ("a" if mode == "legacy" else "b")
                assert after["counts"].get("textChanged", 0) == before["counts"].get("textChanged", 0) + 1
            if action == "return":
                assert before["textFocused"] and not after["textFocused"]
                assert after["counts"].get("returnKey", 0) == before["counts"].get("returnKey", 0) + 1
            for process in folder.glob("*-process.json"):
                receipt = json.loads(process.read_text())
                assert receipt["reaped"] and receipt["exitCode"] == 0
            if mode == "selected":
                receipt = read(folder, "input-receipt.json")
                final = read(folder, "describe-after.stdout")
                assert receipt["context"] == description["context"] == final["context"]
                assert receipt["outcome"] == "enqueuedAndDrained" and receipt["enqueuedEventCount"] > 0
                assert receipt.get("error") is None and receipt.get("quarantine") is None and receipt.get("token") is None
                assert receipt["cleanup"] in ("notNeeded", "releaseEnqueuedAndDrained")
            accepted.append(dict(folder=name, mode=mode, action=action, device=device, pid=result["pid"]))

for device in ("iphone", "ipad"):
    receipt = read(root / ("regression-" + device + "-shutdown"), "result.json")
    assert receipt["exitCode"] == 0 and receipt["reaped"] and receipt["stopReason"] is None

catalogue = read(root / "regression-final-owned-state", "stdout")
booted = {device["udid"] for devices in catalogue["devices"].values() for device in devices}
assert not booted.intersection({"098FE01B-F022-4F1F-A00A-2D398BB77346", "36B2A185-B110-4FFF-95EE-9357846E39DF"})

guards = []
for folder in root.iterdir():
    if not folder.name.startswith("regression-") or not (folder / "result.json").exists():
        continue
    receipt = read(folder, "result.json")
    if "stopReason" not in receipt:
        continue
    assert receipt["reaped"] and receipt["stopReason"] is None and not receipt["signalsSent"]
    if receipt["exitCode"] != 0:
        assert folder.name == "regression-iphone-legacy-remaining-guard" and receipt["exitCode"] == 1
    guards.append(receipt)

host = read(root / "regression-public-boundaries", "result.json")
assert len(host["cases"]) == 10 and all(c["passed"] for c in host["cases"])
build = read(root / "regression-focused-checks", "result.json")
assert build["exitCode"] == 0
assert "Test run with 111 tests in 14 suites passed" in (root / "regression-focused-checks/stdout").read_text()
result = dict(status="BOUNDED_ORDINARY_REGRESSION_PASSED", acceptedCases=len(accepted), cases=accepted, ownedGuestsShutDown=True,
              cliSHA256=pins["files"][".build/out/Products/Debug/axe"], nativeContacts=12, heldTouchesAtEnd=0,
              focusedTests=111, focusedSuites=14, hostCases=10, guardCommands=len(guards),
              sampledPeaks={group:max(g["peaks"][group] for g in guards) for group in ("app", "simulator", "command")},
              scope="Two ordinary portrait devices, legacy and selected tap/swipe/focus/literal/Return; no complete device matrix or native held-key inventory",
              preservedFailedAttempt="regression-iphone-legacy-swipe: driver required full80-point UIPan translation; corrected path and recognizer proof used a separate new attempt",
              securityScan="UNVERIFIED", releaseValidation="NOT_PERFORMED")
(root / "regression-main-result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result))
