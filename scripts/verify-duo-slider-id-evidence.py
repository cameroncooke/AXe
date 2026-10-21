#!/usr/bin/env python3
"""Check saved exact-ID slider evidence. This tool starts no process or input."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import uuid

BUNDLE = "com.camsoft.duo-slider-value-probe"
BASE = "24cca0ef26ed2b52084ee82ac8e55d77b14d142a"
DOMAINS = {"unit": (0, 1), "shifted": (-20, 80), "duplicate": (0, 1)}
FRAMEWORKS = ("FBSimulatorControl", "FBControlCore", "FBDeviceControl", "XCTestBootstrap")
SPECS = {
    "outer0-unit-max": ("endpoint", "id", "slider.unit", "maximum", "unit", 1),
    "outer0-shifted-min": ("endpoint", "id", "slider.shifted", "minimum", "shifted", -20),
    "outer0-prefix": ("endpoint", "id", "slider.uni", "maximum", None, None),
    "outer0-wrong-role": ("endpoint", "id", "slider.unitState", "maximum", None, None),
    "outer0-wrong-type": ("endpoint", "id", "slider.unit", "maximum", None, None),
    "outer0-duplicate-show": ("tap", "id", "slider.duplicateControl", None, "duplicateVisibility", True),
    "outer0-duplicate-id": ("endpoint", "id", "slider.unit", "maximum", None, None),
    "outer0-duplicate-label": ("endpoint", "label", "Unit range slider", "maximum", None, None),
    "outer0-duplicate-hide": ("tap", "id", "slider.duplicateControl", None, "duplicateVisibility", False),
    "outer270-unit-min": ("endpoint", "id", "slider.unit", "minimum", "unit", 0),
    "inner-unit-max": ("endpoint", "id", "slider.unit", "maximum", "unit", 1),
    "inner-prefix": ("endpoint", "id", "slider.uni", "maximum", None, None),
    "inner-fresh": ("tap", "id", "slider.fresh", None, "fresh", None),
}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def read(folder, name):
    return json.loads((folder / name).read_text())


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def same_uuid(left, right):
    return uuid.UUID(str(left)) == uuid.UUID(str(right))


def pinned(folder, entries, key, current=False):
    require(isinstance(entries, list) and entries, "No frozen input pins")
    sources, copies = set(), set()
    for entry in entries:
        source = Path(entry["source"])
        saved = Path(entry[key])
        require(source.is_absolute() and not saved.is_absolute(), "Invalid frozen input path")
        require(str(source) not in sources and str(saved) not in copies, "Duplicate frozen input")
        sources.add(str(source)); copies.add(str(saved))
        copy = (folder / saved).resolve(strict=True)
        require(copy.is_relative_to(folder.resolve()) and copy.is_file(), "Frozen input leaves evidence root")
        require(re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]) is not None, "Invalid frozen digest")
        require(hashlib.sha256(copy.read_bytes()).hexdigest() == entry["sha256"], "Frozen input hash differs: " + str(saved))
        if current:
            require(hashlib.sha256(source.read_bytes()).hexdigest() == entry["sha256"], "Current source differs: " + str(source))
    return sources


def state(folder, name, pid):
    value = read(folder, name + ".json")
    require(value["fixtureVersion"] == 1 and value["bundleIdentifier"] == BUNDLE and value["pid"] == pid, "Wrong fixture binding")
    for key in ("activeWindowTouches", "windowTraceDropped", "sliderCallbacksDropped", "unmatchedTouchEvents"):
        require(value[key] == 0, "Incomplete native observation: " + key)
    require(value["windowTraceLimit"] == 4096 and value["sliderCallbackLimit"] == 1024, "Wrong trace limits")
    require(value["callbackSequence"] == len(value["sliderCallbackTrace"]), "Missing callback records")
    require(number(value["publishedGuestUptime"]) and value["sequence"] > 0, "Invalid publication metadata")
    require(all(number(value[key]) and value[key] > 0 for key in ("width", "height")), "Invalid window bounds")
    for key, (minimum, maximum) in DOMAINS.items():
        slider = value["sliders"][key]
        require(slider["minimum"] == minimum and slider["maximum"] == maximum, "Native slider domain changed")
        require(number(slider["value"]) and minimum <= slider["value"] <= maximum, "Native value outside domain")
        require(slider["enabled"] and not slider["tracking"], "Slider disabled or still tracking")
        require(slider["identifier"] == ("slider.shifted" if key == "shifted" else "slider.unit"), "Wrong native slider identity")
        require(slider["hidden"] == (key == "duplicate" and not value["duplicateVisible"]), "Wrong native slider visibility")
    return value


def semantic(value):
    return {key: value[key] for key in ("sliders", "duplicateVisible", "counts", "callbackSequence", "sliderCallbackTrace", "windowTouchTrace")}


def counts(before, after, changes):
    for key in set(before["counts"]) | set(after["counts"]) | set(changes):
        require(after["counts"].get(key, 0) - before["counts"].get(key, 0) == changes.get(key, 0), "Wrong native callback count: " + key)


def suffix(before, after, key):
    initial, final = before[key], after[key]
    require(final[:len(initial)] == initial, "Native history changed: " + key)
    return final[len(initial):]


def command(folder, verb, binding, positionals=()):
    value = read(folder, "command.json")
    require(value["reaped"] is True and isinstance(value["exitCode"], int) and not value["timedOut"], "Command was not reaped or timed out")
    argv = value["argv"]
    require(isinstance(argv, list) and all(isinstance(item, str) for item in argv) and len(argv) >= 2, "Invalid saved command")
    require(argv[0] == binding["_cli"] and argv[1] == verb and argv[2:2 + len(positionals)] == list(positionals), "Wrong command boundary")
    require(read(folder, "command-process.json") == value and read(folder, "command-argv.json") == argv, "Saved command envelope differs")
    require(json.loads((folder / "command.stdout").read_text()) == read(folder, "response.json"), "Raw command response differs")
    options = {}
    for index in range(2 + len(positionals), len(argv), 2):
        require(index + 1 < len(argv) and argv[index].startswith("--") and argv[index] not in options, "Invalid or repeated command option")
        options[argv[index]] = argv[index + 1]
    require(same_uuid(options["--udid"], binding["simulatorUDID"]), "Command device differs")
    return value, options


def response(folder, successful):
    value = read(folder, "response.json")
    require(value["version"] == 22 and value["cleanup"] == "notNeeded" and not value.get("quarantine"), "Wrong wire or uncertain cleanup")
    require((value.get("error") is None) == successful, "Command error disagrees with required outcome")
    return value


def check_context(value, binding, panel, rotation, degrees):
    require(value["bootIdentity"] == binding["bootIdentity"] and value["screenID"] == panel["screenID"] and
            same_uuid(value["screenUUID"], panel["screenUUID"]), "Selected context differs")
    require(value["rotationDegrees"] == rotation, "Selected rotation differs")
    match = re.fullmatch(r"mechanicalDegrees=([0-9.]+);range=0\.0\.\.\.180\.0", value["poseRevision"])
    require(match and float(match[1]) == degrees, "Selected hinge pose differs")


def check_endpoint(before, after, receipt, target, endpoint, native):
    slider = receipt["ax"]["slider"]
    require(receipt["outcome"] == "endpointObserved" and receipt["enqueuedEventCount"] == 0, "Endpoint transport differs")
    require(slider["outcome"] == "endpointObserved" and slider["delivery"] == "valueObserved" and
            slider["endpoint"] == endpoint and not slider.get("reason"), "Endpoint receipt did not complete")
    count = slider["actionsReturned"]
    require(isinstance(count, int) and 0 < count <= 20 and slider["actionAttempts"] == count == len(slider["actions"]), "Wrong semantic action count")
    minimum, maximum = DOMAINS[target]
    tolerance = (maximum - minimum) * .0007
    require(abs(after["sliders"][target]["value"] - native) <= tolerance, "Native target value was not reached")
    require(abs(before["sliders"][target]["value"] - native) > tolerance, "Positive case started at the endpoint")
    callbacks = suffix(before, after, "sliderCallbackTrace")
    require(len(callbacks) == count and after["callbackSequence"] - before["callbackSequence"] == count, "Real callbacks differ from actions")
    previous = before["sliders"][target]["value"]
    direction = 1 if endpoint == "maximum" else -1
    for index, (callback, action) in enumerate(zip(callbacks, slider["actions"])):
        require(callback["sequence"] == before["callbackSequence"] + index + 1 and callback["control"] == target and
                callback["identifier"] == after["sliders"][target]["identifier"], "Wrong callback target or sequence")
        require(callback["minimum"] == minimum and callback["maximum"] == maximum and number(callback["value"]) and
                minimum <= callback["value"] <= maximum, "Wrong callback domain/value")
        require(direction * (callback["value"] - previous) > 0, "Callback made no progress or moved the wrong way")
        require(action["action"] == ("increment" if direction == 1 else "decrement") and action["guestAcknowledged"] is False and action["elementType"] == "Slider" and
                number(action["valueBeforeAction"]) and abs(action["valueBeforeAction"] - previous) <= tolerance, "Action evidence differs from real values")
        require(before["publishedGuestUptime"] <= callback["guestUptime"] <= after["publishedGuestUptime"], "Callback outside state bracket")
        previous = callback["value"]
    require(abs(previous - native) <= tolerance, "Last real callback did not reach target")
    samples = slider["samples"]
    require(len(samples) == count + 3 and samples[0]["phase"] == "initial" and
            [sample["phase"] for sample in samples[-2:]] == ["settled-0.6", "settled-5.0"], "Missing settled native observations")
    for sample in samples:
        require(sample["minimum"] == minimum and sample["maximum"] == maximum and sample["tolerance"] == tolerance and sample["elementType"] == "Slider" and
                number(sample["value"]) and minimum <= sample["value"] <= maximum, "Wrong native sample range")
    require(abs(samples[0]["value"] - before["sliders"][target]["value"]) <= tolerance and
            all(abs(sample["value"] - native) <= tolerance for sample in samples[-2:]), "Initial/final native samples differ")
    for index, callback in enumerate(callbacks):
        require(samples[index + 1]["phase"] == "after-action-" + str(index + 1) and
                abs(samples[index + 1]["value"] - callback["value"]) <= tolerance, "Per-action sample differs from callback")
    expected = semantic(before)
    expected["sliders"] = dict(before["sliders"])
    expected["sliders"][target] = dict(before["sliders"][target], value=after["sliders"][target]["value"])
    expected["counts"] = after["counts"]; expected["callbackSequence"] = after["callbackSequence"]
    expected["sliderCallbackTrace"] = after["sliderCallbackTrace"]
    require(semantic(after) == expected and before["geometry"] == after["geometry"], "Endpoint changed another control or sent contacts")
    counts(before, after, {target + "Changed": count})


def check_rejection(before, after, receipt):
    require(receipt["outcome"] in ("failed", "failedBeforeInput", "rejectedBeforeInput") and receipt["enqueuedEventCount"] == 0, "Rejection delivery is not definite")
    slider = receipt["ax"]["slider"]
    require(slider["outcome"] == "failed" and slider["reason"] == "invalidSelection" and slider["delivery"] == "notDispatched" and
            slider["actionAttempts"] == slider["actionsReturned"] == 0 and not slider["actions"], "Rejection was not the intended target gate")
    require(semantic(before) == semantic(after) and before["geometry"] == after["geometry"], "Rejected request changed native state")


def check_tap(before, after, receipt, identifier, effect, visible):
    require(receipt["outcome"] == "enqueuedAndDrained" and receipt["enqueuedEventCount"] == 2, "Tap did not drain exactly two events")
    require(before["sliderCallbackTrace"] == after["sliderCallbackTrace"] and before["callbackSequence"] == after["callbackSequence"], "Button tap changed slider callbacks")
    contacts = suffix(before, after, "windowTouchTrace")
    require(len(contacts) == 2, "Tap needs one complete contact pair")
    began, ended = contacts
    require(began["phase"] == "began" and ended["phase"] == "ended" and
            began["contactID"] == ended["contactID"] > 0 and began["activeTouches"] == 1 and ended["activeTouches"] == 0, "Tap contact did not release")
    require(began["contactID"] > max((row["contactID"] for row in before["windowTouchTrace"]), default=0), "Tap reused an old contact ID")
    ax = receipt["ax"]
    require(ax["target"]["AXUniqueId"] == identifier and ax["target"]["pid"] == before["pid"] and
            ax["validation"]["expectedPID"] == ax["validation"]["frontmostPID"] == before["pid"] and
            ax["validation"]["verifiedTarget"]["AXUniqueId"] == identifier, "Tap target admission differs")
    frame = before["geometry"][identifier]
    for contact in contacts:
        require(contact["hitView"] == contact["control"] == identifier and all(number(contact[key]) for key in ("x", "y", "guestUptime")), "Wrong button contact")
        require(frame["x"] <= contact["x"] <= frame["x"] + frame["width"] and
                frame["y"] <= contact["y"] <= frame["y"] + frame["height"], "Contact outside actual button")
        require(abs(contact["x"] - ax["point"]["x"]) < .5 and abs(contact["y"] - ax["point"]["y"]) < .5, "Contact differs from admitted point")
    require(before["publishedGuestUptime"] <= began["guestUptime"] <= ended["guestUptime"] <= after["publishedGuestUptime"], "Tap outside state bracket")
    counter = "duplicateControl" if effect == "duplicateVisibility" else "fresh"
    counts(before, after, {counter: 1, "began": 1, "ended": 1})
    expected_sliders = dict(before["sliders"])
    if effect == "duplicateVisibility":
        require(bool(before["duplicateVisible"]) != visible and bool(after["duplicateVisible"]) == visible, "Duplicate toggle had no required effect")
        expected_sliders["duplicate"] = dict(before["sliders"]["duplicate"], hidden=not visible)
    else:
        require(before["duplicateVisible"] == after["duplicateVisible"], "Fresh tap changed duplicate visibility")
    require(after["sliders"] == expected_sliders, "Button tap changed slider values or properties")
    for key in before["geometry"]:
        if effect != "duplicateVisibility" or key not in ("duplicate", "slider.duplicateState"):
            require(before["geometry"][key] == after["geometry"][key], "Button tap changed unrelated geometry")


def case(folder, name, binding, inner_rotation):
    kind, selector, value, endpoint, target, native = SPECS[name]
    successful = target is not None
    request = read(folder, "request.json")
    require((request["kind"], request["selectorKind"], request["selectorValue"], request.get("endpoint")) ==
            (kind, selector, value, endpoint), "Case selector/operation differs: " + name)
    require(request["expectedOutcome"] == ("success" if successful else "rejection"), "Case required outcome was changed")
    if kind == "endpoint" and successful:
        require(request["expectedSlider"] == target and request["expectedNativeValue"] == native, "Case required native target was changed")
    if kind == "tap":
        require(request["expectedButton"] == target, "Case required button effect was changed")
    require(request["expectedPID"] == binding["pid"], "Case PID differs")
    panel = binding["inner" if name.startswith("inner-") else "outer"]
    rotation = inner_rotation if name.startswith("inner-") else 270 if name.startswith("outer270-") else 0
    require(request["screenID"] == panel["screenID"] and same_uuid(request["screenUUID"], panel["screenUUID"]), "Request selected panel differs")
    process, options = command(folder, "slider" if kind == "endpoint" else "tap", binding)
    require((process["exitCode"] == 0) == successful, "Case exit differs from required outcome")
    require(options["--" + selector] == value and options["--input-mode"] == "selected" and
            int(options["--screen-id"]) == panel["screenID"] and same_uuid(options["--screen-uuid"], panel["screenUUID"]) and
            int(options["--expected-pid"]) == binding["pid"], "Saved command selection differs")
    require(("--id" in options) != ("--label" in options), "Command mixed selectors")
    allowed = {"--udid", "--input-mode", "--screen-id", "--screen-uuid", "--expected-pid", "--" + selector}
    if request.get("elementType"):
        allowed.add("--element-type")
        require(options["--element-type"] == request["elementType"], "Command type filter differs")
    if kind == "endpoint":
        allowed.add("--endpoint")
        require(options["--endpoint"] == endpoint and "--value" not in options, "Command is not the required endpoint operation")
    require(set(options) == allowed, "Command carried an unexpected input option")
    if name == "outer0-wrong-type":
        require(request["elementType"] == options["--element-type"] == "Button", "Missing wrong-type check")
    receipt = response(folder, successful)
    require(receipt["ax"]["kind"] == ("sliderEndpoint" if kind == "endpoint" else "tap") and
            receipt["ax"]["expectedPID"] == binding["pid"], "Response operation/PID differs")
    check_context(receipt["context"], binding, panel, rotation, 180 if name.startswith("inner-") else 0)
    before, after = (state(folder, label, binding["pid"]) for label in ("before", "after"))
    require(after["sequence"] > before["sequence"] and after["publishedGuestUptime"] > before["publishedGuestUptime"], "Missing fresh native readback")
    require(before["width"] == after["width"] and before["height"] == after["height"] and
            before["interfaceOrientation"] == after["interfaceOrientation"], "Layout changed during case")
    catalogues(folder, binding, panel, panel, "rot" + str(rotation), "rot" + str(rotation))
    if not successful:
        check_rejection(before, after, receipt)
    elif kind == "endpoint":
        check_endpoint(before, after, receipt, target, endpoint, native)
    else:
        check_tap(before, after, receipt, value, target, native)
    return before, after


def catalogue(value, binding, panel, orientation=None):
    require(value["bootIdentity"] == binding["bootIdentity"] and same_uuid(value["requestedSimulatorUDID"], binding["simulatorUDID"]), "Catalogue binding differs")
    active = value["activePanel"]
    require(active["active"] and active["identity"]["displayID"] == panel["screenID"] and
            same_uuid(active["identity"]["uniqueID"], panel["screenUUID"]), "Catalogue active panel differs")
    require(sum(bool(row["active"]) for row in value["panels"]) == 1, "Catalogue has ambiguous active panels")
    if orientation:
        require(active["currentOrientation"] == orientation, "Catalogue rotation differs")


def catalogues(folder, binding, before_panel, after_panel, before_rotation, after_rotation):
    for label, panel, rotation in (("before", before_panel, before_rotation), ("after", after_panel, after_rotation)):
        name = "catalogue-" + label
        process = read(folder, name + "-process.json")
        argv = [binding["_cli"], "list-simulators", "--displays", "--udid", binding["simulatorUDID"]]
        require(process["argv"] == read(folder, name + "-argv.json") == argv and process["exitCode"] == 0 and
                process["reaped"] is True and not process["timedOut"], "Catalogue child did not complete")
        value = read(folder, name + ".json")
        require(json.loads((folder / (name + ".stdout")).read_text()) == value, "Saved catalogue differs from stdout")
        catalogue(value, binding, panel, rotation)


def transition(folder, name, binding):
    rotation = name == "outer-rotate"
    request = read(folder, "request.json")
    require(request["kind"] == ("rotate" if rotation else "hinge") and request["screenID"] == binding["outer"]["screenID"] and
            same_uuid(request["screenUUID"], binding["outer"]["screenUUID"]), "Transition request differs")
    require(request["direction"] == "left" if rotation else request["degrees"] == 180, "Transition target differs")
    process, options = command(folder, "rotate" if rotation else "hinge", binding, ("left",) if rotation else ("set", str(request["degrees"])))
    require(process["exitCode"] == 0 and options["--expected-boot"] == binding["bootIdentity"], "Transition command did not complete")
    before, after = (state(folder, label, binding["pid"]) for label in ("before", "after"))
    require(semantic(before) == semantic(after) and after["publishedGuestUptime"] > before["publishedGuestUptime"], "Transition sent input or changed controls")
    catalogues(folder, binding, binding["outer"], binding["outer"] if rotation else binding["inner"], "rot0" if rotation else "rot270", "rot270" if rotation else None)
    receipt = response(folder, True)
    require(receipt["enqueuedEventCount"] == 0, "Transition sent touch input")
    if rotation:
        require(int(options["--screen-id"]) == binding["outer"]["screenID"] and
                same_uuid(options["--screen-uuid"], binding["outer"]["screenUUID"]), "Rotation targeted a different screen")
        require(receipt["outcome"] == "observedRotation" and not receipt["rotation"].get("failure"), "Rotation failed")
        result = receipt["rotation"]["receipt"]
        require(result["direction"] == "left" and result["vendorEventCount"] == 1 and result["matchingObservationCount"] >= 2, "Rotation lacks bounded native proof")
        for label, degrees in (("before", 0), ("after", 270)):
            observation = result[label]
            require(observation["bootIdentity"] == binding["bootIdentity"] and observation["screenID"] == binding["outer"]["screenID"] and
                    same_uuid(observation["screenUniqueID"], binding["outer"]["screenUUID"]) and observation["rotation"] == degrees, "Native rotation binding differs")
        check_context(receipt["context"], binding, binding["outer"], 270, 0)
        return before, after, 270
    require(receipt["outcome"] == "observedMechanicalTargetAndDisplayCoherence", "Open did not prove display readiness")
    hinge = receipt["hinge"]
    require(hinge["kind"] == "set" and hinge["activeDisplayCompletion"] == "coherentObserved" and not hinge.get("failure"), "Open typed result failed")
    mechanical, readiness = hinge["receipt"], hinge["readiness"]
    require(int(options["--wait-for-screen-id"]) == binding["inner"]["screenID"] and
            same_uuid(options["--wait-for-screen-uuid"], binding["inner"]["screenUUID"]), "Open readiness targeted a different screen")
    require(mechanical["requestedDegrees"] == 180 and mechanical["expectedBootIdentity"] == binding["bootIdentity"] and
            not mechanical["wasAlreadyWithinTolerance"] and mechanical["before"]["mechanicalDegrees"] == 0 and
            0 <= mechanical["toleranceDegrees"] <= 1 and len(mechanical["matchingSamples"]) >= 2, "Open lacks mechanical change proof")
    require(all(abs(row["mechanicalDegrees"] - 180) <= mechanical["toleranceDegrees"] for row in mechanical["matchingSamples"]), "Mechanical target differs")
    require(readiness["outcome"] == "coherent" and readiness["cleanup"] == "confirmed" and not readiness.get("failure") and
            readiness["expectedBootIdentity"] == binding["bootIdentity"] and len(readiness["coherentObservations"]) >= 2, "Missing coherent display observations")
    inner_rotation = readiness["coherentObservations"][-1]["rotation"]
    for observation in readiness["coherentObservations"]:
        require(observation["bootIdentity"] == binding["bootIdentity"] and observation["screenID"] == binding["inner"]["screenID"] and
                same_uuid(observation["screenUUID"], binding["inner"]["screenUUID"]) and observation["rotation"] == inner_rotation and
                abs(observation["mechanicalBefore"] - 180) <= 1 and abs(observation["mechanicalAfter"] - 180) <= 1, "Inner readiness binding differs")
    return before, after, inner_rotation


def raw_setter(folder, key):
    pinned(folder, read(folder, "frozen-before-input.json"), "copy")
    before_data = read(folder, "before.json")
    before, after = (state(folder, label, before_data["pid"]) for label in ("before", "after"))
    process, result, probe = (read(folder, name) for name in ("process.json", "result.json", "probe.json"))
    require(process["exitCode"] == 0 and process["reaped"] is True, "Raw setter child was not reaped")
    require(after["sequence"] > before["sequence"] and after["publishedGuestUptime"] > before["publishedGuestUptime"], "Raw setter lacks fresh periodic native readback")
    require(result["productionReady"] is False and probe["productionReady"] is False and
            probe["outcome"] == "nativeValueObservedNoAppAcknowledgement", "Raw setter was admitted as support")
    require(before["sliders"][key]["value"] != after["sliders"][key]["value"] and
            before["counts"] == after["counts"] and before["callbackSequence"] == after["callbackSequence"] and
            before["sliderCallbackTrace"] == after["sliderCallbackTrace"] and before["windowTouchTrace"] == after["windowTouchTrace"], "Raw setter distinction is not proved")
    expected = dict(before["sliders"])
    expected[key] = dict(before["sliders"][key], value=after["sliders"][key]["value"])
    require(after["sliders"] == expected and before["geometry"] == after["geometry"], "Raw setter changed another control")
    minimum, maximum = DOMAINS[key]
    target = minimum + (maximum - minimum) * probe["args"]["percent"] / 100
    require(result["nativeWriteIntents"] == 1 and probe["args"]["percent"] == 63.25 and
            probe["args"]["identifier"] == before["sliders"][key]["identifier"] and probe["args"]["pid"] == before["pid"] and
            probe["ownedRootBefore"]["AXValue"] == before["sliders"][key]["value"] and
            probe["ownedRootFinal"]["pid"] == after["pid"], "Raw setter request/target binding differs")
    require(abs(after["sliders"][key]["value"] - target) <= (maximum - minimum) * .0007 and
            probe["ownedRootFinal"]["AXUniqueId"] == after["sliders"][key]["identifier"] and
            abs(probe["ownedRootFinal"]["AXValue"] - target) <= (maximum - minimum) * .0007, "Raw setter native readback differs")


def check(folder, current):
    binding = read(folder, "bindings.json")
    require(binding["schemaVersion"] == 1 and binding["bundleIdentifier"] == BUNDLE and binding["pid"] > 0 and
            binding["outer"]["screenID"] != binding["inner"]["screenID"], "Invalid native bindings")
    frozen = read(folder, "candidate/frozen.json")
    require(frozen["schemaVersion"] == 1 and frozen["baseCommit"] == BASE, "Wrong candidate base")
    correction = read(folder, "verification-correction.json")
    prior = read(folder, "candidate/frozen-before-verifier-correction.json")
    require(correction["reason"] == "Left rotation from outer0 is270; proof label incorrectly expected90" and
            prior["baseCommit"] == frozen["baseCommit"], "Wrong verifier correction")
    pinned(folder, prior["pins"], "saved")
    old_entries = {entry["source"]: entry for entry in prior["pins"]}
    require(set(old_entries) == {entry["source"] for entry in frozen["pins"]}, "Correction changed input set")
    changed = [entry for entry in frozen["pins"] if entry != old_entries[entry["source"]]]
    require(len(changed) == 1 and changed[0]["source"].endswith("/scripts/verify-duo-slider-id-evidence.py") and
            old_entries[changed[0]["source"]]["sha256"] == "21f1769bc83bea281010b4d714cbe12fb2be1830e7a40642069327fda1704da1" and
            changed[0]["sha256"] == correction["correctedVerifierSHA256"], "Correction changed executed product or driver")
    sources = pinned(folder, frozen["pins"], "saved", current)
    cli = [source for source in sources if source.endswith("/runtime-exact/axe")]
    require(len(cli) == 1, "Missing unique exact-ID CLI pin")
    binding["_cli"] = cli[0]
    required = ["/runtime-exact/axe", "/runtime-exact/cadisplay-context", "/DuoSliderValueProbe.app/DuoSliderValueProbe",
                "/DuoSliderValueProbe.app/Info.plist", "/scripts/fixtures/DuoSliderValueProbe.m"]
    required += ["/runtime-exact/" + name + ".framework/Versions/A/" + name for name in FRAMEWORKS]
    required += ["/" + name for name in ("FBAccessibilityElement.swift", "FBSimulatorSlider.swift", "FBSimulatorAXSnapshot.swift")]
    required += ["/patches/idb-duo-foundation.patch", "/patches/idb-duo-foundation.sha256", "/scripts/fixtures/DuoSliderSetterProbe.swift",
                 "/verify-duo-slider-id.py", "/verify-duo-slider-id-evidence.py"]
    require(all(any(source.endswith(ending) for source in sources) for ending in required), "Missing required runtime/source pins")
    require({item.name for item in (folder / "cases").iterdir() if item.is_dir()} == set(SPECS), "Missing or unreviewed extra native cases")
    require({item.name for item in (folder / "transitions").iterdir() if item.is_dir()} == {"outer-rotate", "open-inner"}, "Missing or extra transitions")
    rotated_before, rotated_after, _ = transition(folder / "transitions/outer-rotate", "outer-rotate", binding)
    opened_before, opened_after, inner_rotation = transition(folder / "transitions/open-inner", "open-inner", binding)
    states = {name: case(folder / "cases" / name, name, binding, inner_rotation) for name in SPECS}
    chain = list(states.values())
    chain.insert(9, (rotated_before, rotated_after)); chain.insert(11, (opened_before, opened_after))
    for previous, following in zip(chain, chain[1:]):
        require(semantic(previous[1]) == semantic(following[0]) and
                following[0]["publishedGuestUptime"] >= previous[1]["publishedGuestUptime"], "Unrecorded native control change between cases")
    for name, key in (("unit-02", "unit"), ("shifted-01", "shifted")):
        raw_setter(folder / "lab" / name, key)
    return {"outcome": "PASS_BOUNDED_EXACT_ID", "cases": len(SPECS), "transitions": 2,
            "rejectedRawSetters": 2, "currentSourcesChecked": current,
            "scope": "Selected semantic slider endpoints and named taps on one Duo; percentage input remains unsupported"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--current", action="store_true", help="Also compare the current pinned source files")
    args = parser.parse_args()
    print(json.dumps(check(args.evidence.resolve(strict=True), args.current), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
