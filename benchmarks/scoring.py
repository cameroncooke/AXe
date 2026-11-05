"""Conservative automatic task evidence and cost scoring for the fixed UI tasks.

Only tool-returned structured UI facts establish correctness. Screenshots and
assistant prose cannot silently turn an incomplete text proof into a pass.
"""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import re

from transcript import read_transcript, observed_runtime, option, options

SCORER_VERSION = "1"


def check(identity, passed, evidence=(), reason="", failed=False):
    return {"id": identity, "status": "passed" if passed else "failed" if failed else "unverified",
            "evidence": list(evidence), "reason": reason}


def witness(capture, nodes):
    return {"call": capture.call, "resultLine": capture.line,
            "rows": [{"ref": n.ref, "role": n.role, "label": n.label, "value": n.value} for n in nodes]}


def matches(capture, label, value=None):
    return [n for n in capture.nodes if n.label == label and (value is None or n.value == value)]


def fact_nodes(capture, labels):
    if all(matches(capture, label) for label in labels):
        return sum([matches(capture, label) for label in labels], [])
    # Native accessibility can combine a control's title and values in one
    # comma-delimited label. Match complete components, never substrings.
    return [node for node in capture.nodes if all(label in node.label.split(", ") for label in labels)]


def find(captures, predicate):
    for capture in reversed(captures):
        nodes = predicate(capture)
        if nodes:
            return [witness(capture, nodes)]
    return []


def latest_state(captures, identity, selector, accepted):
    """A later opposite state overrides earlier successful input."""
    for capture in reversed(captures):
        nodes = selector(capture)
        if nodes:
            passed = all(accepted(node) for node in nodes)
            return check(identity, passed, [witness(capture, nodes)],
                         "Use the last observed state of this setting.", failed=not passed)
    return check(identity, False, reason="The setting state was not observed.")


def complete_views(captures):
    """Combine only pages explicitly tied to the same native capture identity."""
    groups = {}
    output = []
    for capture in captures:
        if capture.identity:
            prior = groups.get(capture.identity, {})
            for node in capture.nodes:
                prior[node.ref] = node
            if capture.complete:
                from transcript import Capture
                output.append(Capture(capture.call, capture.line, list(prior.values()), capture.identity, True))
                groups.pop(capture.identity, None)
            else:
                groups[capture.identity] = prior
        elif capture.complete:
            output.append(capture)
    return output


def action_rows(calls, after=0):
    return [(call, action) for call in calls if call.number > after for action in call.actions if action.executed is not False]


def setup_execution_denied(call):
    return call.error and re.match(r"^(?:This command requires approval|This Bash command .*requires approval|Output redirection .*needs approval)", call.text, re.S) is not None


def procedure_read_only(calls, boundary, identity, allow_labels=()):
    if boundary is None:
        return check(identity, False, reason="The verification boundary was not observed.")
    position = boundary if isinstance(boundary, tuple) else (boundary, math.inf)
    bad = []
    for call in calls:
        for index, action in enumerate(call.actions):
            if (call.number, index) <= position or action.executed is False:
                continue
            if action.kind == "observe":
                continue
            if action.kind in ("swipe", "scroll") and allow_labels:
                continue
            if action.kind == "tap" and action.label in allow_labels:
                continue
            bad.append({"call": call.number, "step": index, "kind": action.kind, "target": action.label})
    late_setup = [{"call": c.number, "kind": "setupDuringVerification"} for c in calls if c.number > position[0] and c.category == "setup" and not setup_execution_denied(c)]
    bad += late_setup
    return check(identity, not bad, bad, "No data input after the observed verification boundary." if not bad else "Input occurred during read-only verification.", failed=bool(bad))


def detail_entry(calls, captures, boundary):
    if boundary is None:
        return None
    prior = max((c.call for c in captures if c.call < boundary), default=0)
    actions = [(call.number, index, action) for call in calls if prior < call.number <= boundary
               for index, action in enumerate(call.actions) if action.executed is not False]
    entries = [(number, index) for number, index, action in actions
               if action.kind == "tap" and action.label.startswith(("PRECIP.", "Precipitation"))]
    if entries:
        return entries[0]
    # A single action followed by the detail screen proves its transition.
    # Several unlabelled actions cannot establish where read-only mode began.
    if len(actions) == 1:
        return actions[0][:2]
    return (boundary, math.inf) if not actions else None


def weather(calls, captures):
    checks = []
    details = [c for c in captures if matches(c, "PRECIPITATION") and matches(c, "chance over the next 24 hours")]
    boundary = min((c.call for c in details), default=None)
    before = [c for c in captures if boundary is None or c.call < boundary]
    for name in ("°C", "m/s", "inHg", "km"):
        checks.append(latest_state(before, "settings." + name,
                                   lambda c: [n for n in matches(c, name) if n.role == "button"],
                                   lambda n: n.selected or n.value.lower() == "selected"))
    for label, wanted in (("Atmospheric animations", False), ("Severe weather alerts", False), ("Reduce transparency", True)):
        checks.append(latest_state(before, "settings." + label,
                                   lambda c: [n for n in matches(c, label) if n.role in ("switch", "checkbox")],
                                   lambda n: n.value.lower() in (("1", "on", "true") if wanted else ("0", "off", "false"))))
    typed = [{"call": c.number, "text": a.value} for c, a in action_rows(calls) if a.kind == "type" and a.value == "London"]
    main = [c for c in before if matches(c, "London") and (matches(c, "11°") or (matches(c, "11") and matches(c, "°")))]
    search = find(before, lambda c: [n for n in c.nodes if "London, England, United Kingdom" in n.label])
    checks.append(check("search.exactLondonAndSelection", bool(typed and main and search), typed + search,
                        "Typed text, search result and selected main city must all be observed."))
    for identity, labels in (("main.city", ("London",)), ("main.temperature", ("11", "°")),
                             ("main.precipitation", ("PRECIP.", "78%")), ("main.visibility", ("VISIBILITY", "9.7 km"))):
        def nodes(c):
            if identity == "main.temperature" and matches(c, "11°"):
                return matches(c, "11°")
            return fact_nodes(c, labels)
        evidence = find(before, nodes)
        checks.append(check(identity, bool(evidence), evidence))
    later = [c for c in captures if boundary is not None and c.call >= boundary]
    for identity, labels in (("detail.chance", ("78%", "chance over the next 24 hours")),
                             ("detail.total", ("TOTAL EXPECTED", "10.7 mm")),
                             ("detail.hours", ("HOURS OF RAIN", "6 hrs")),
                             ("detail.distance", ("14 km",)), ("detail.lightning", ("LIGHTNING", "None"))):
        evidence = find(later, lambda c: fact_nodes(c, labels))
        checks.append(check(identity, bool(evidence), evidence))
    checks.append(procedure_read_only(calls, detail_entry(calls, captures, boundary), "procedure.noInputAfterDetails"))
    return checks


def contacts(calls, captures):
    editor = [c for c in captures if matches(c, "First name") and matches(c, "Last name")]
    cards = [c for c in captures if matches(c, "Edit") and matches(c, "MCP Contact Benchmark") and not matches(c, "First name")]
    saves = [(c, a) for c, a in action_rows(calls) if a.kind == "tap" and a.label == "Done" and any(x.call < c.number for x in editor)]
    boundary = min((c.number for c, _ in saves), default=None)
    cards = [c for c in cards if boundary is not None and c.call >= boundary]
    before = [c for c in editor if boundary is None or c.call < boundary]
    checks = []
    for label, expected in (("First name", "MCP"), ("Last name", "Contact Benchmark")):
        checks.append(latest_state(before, "contact." + label,
                                   lambda c: matches(c, label), lambda n: n.value == expected))
    for identity, predicate in (
        ("saved.name", lambda n: n.label == "MCP Contact Benchmark"),
        ("saved.organization", lambda n: " ".join(n.label.split()).casefold() == "xcodebuildmcp benchmark"),
        ("saved.phone", lambda n: re.sub(r"\D", "", n.label) == "5550104242"),
        ("saved.email", lambda n: n.label == "mcp.contact.benchmark@example.com"),
    ):
        evidence = find(cards, lambda c: [n for n in c.nodes if predicate(n)])
        checks.append(check(identity, bool(evidence), evidence, "Value must be visible on the saved card, not in an editor."))
    adds = [(c, a) for c, a in action_rows(calls) if a.kind == "tap" and a.label in ("Add", "New Contact", "Create New Contact")]
    checks.append(check("creation.oneContact", len(adds) == 1 and len(saves) == 1 and bool(cards),
                        [{"call": c.number, "target": a.label} for c, a in adds + saves],
                        "One observed Add/editor/Done/saved-card flow is required; database cardinality is not inferred.", failed=len(adds) > 1 or len(saves) > 1))
    save_position = next(((c.number, index) for c in calls for index, action in enumerate(c.actions)
                          if action.executed is not False and action.kind == "tap" and action.label == "Done"
                          and any(x.call < c.number for x in editor)), None)
    checks.append(procedure_read_only(calls, save_position, "procedure.noEditAfterSave"))
    return checks


def reminders(calls, captures):
    desired = {"Buy milk benchmark": "Completed", "File report benchmark": "Incomplete", "Call team benchmark": "Completed"}
    named = [c for c in captures if any(n.label == "MCP Benchmark List" or n.identifier == "MCP Benchmark List" for n in c.nodes)]
    checks = [check("list.exactName", bool(named), find(named, lambda c: [n for n in c.nodes if n.label == "MCP Benchmark List" or n.identifier == "MCP Benchmark List"]))]
    final = []
    last_states = {}
    duplicate_records = []
    for capture in complete_views(named):
        states = {}
        records = []
        for node in capture.nodes:
            match = re.fullmatch(r"(.+), (Completed|Incomplete)", node.label)
            if match:
                records.append(node)
                states[match.group(1)] = match.group(2)
        if len(records) != len(states):
            duplicate_records.append(witness(capture, records))
        if states == desired and len(records) == 3:
            final.append(capture)
        if states:
            last_states = states
    for title, state in desired.items():
        evidence = find(final, lambda c: matches(c, title + ", " + state))
        checks.append(check("reminder." + title, bool(evidence), evidence))
    checks.append(check("list.exactlyThreeStates", bool(final) and last_states == desired and not duplicate_records, duplicate_records or find(final, lambda c: [n for n in c.nodes if re.fullmatch(r"(.+), (Completed|Incomplete)", n.label)]),
                        "A complete returned list must contain exactly the required three named states.",
                        failed=bool(duplicate_records) or any(title not in desired for title in last_states)))
    list_types = [(c, a) for c, a in action_rows(calls) if a.kind == "type" and a.value == "MCP Benchmark List"]
    adds = [(c, a) for c, a in action_rows(calls) if a.kind == "tap" and a.label == "Add List"]
    checks.append(check("creation.oneList", len(list_types) == 1 and len(adds) == 1,
                        [{"call": c.number, "target": a.label, "text": a.value} for c, a in list_types + adds],
                        "Exactly one observed Add List/name flow is required.", failed=len(adds) > 1))
    forbidden = [(c, a) for c, a in action_rows(calls) if a.kind in ("delete", "rename") or a.label in ("Delete", "Delete List", "Clear", "Rename List", "Edit Title")]
    checks.append(check("procedure.noCleanupOrRename", not forbidden, [{"call": c.number, "target": a.label} for c, a in forbidden], failed=bool(forbidden)))
    boundary = min((c.call for c in named if matches(c, "2 Completed")), default=min((c.call for c in final), default=None))
    checks.append(procedure_read_only(calls, boundary, "procedure.observeSavedListOnly", ("More", "Show Completed", "Hide Completed")))
    return checks


def token_totals(calls):
    text_bytes = sum(len(c.text.encode("utf-8")) for c in calls if c.result_line)
    try:
        import tiktoken
        import tiktoken.load
        original = tiktoken.load.read_file
        def deny_network(_):
            raise OSError("o200k_base data is not cached; run benchmark setup first")
        try:
            tiktoken.load.read_file = deny_network
            encoding = tiktoken.get_encoding("o200k_base")
        finally:
            tiktoken.load.read_file = original
        return {"returnedTextTokens": sum(len(encoding.encode(c.text, disallowed_special=())) for c in calls if c.result_line),
                "returnedTextBytes": text_bytes, "tokenStatus": "measured", "tokenizer": "o200k_base",
                "tokenizerVersion": importlib.metadata.version("tiktoken")}
    except (ImportError, OSError, ValueError, importlib.metadata.PackageNotFoundError) as error:
        return {"returnedTextTokens": None, "returnedTextBytes": text_bytes, "tokenStatus": "unavailable", "tokenizer": "o200k_base", "tokenError": str(error)}


def identity_checks(calls, expected_executable, expected_udid):
    selected = [c for c in calls if c.category in ("ui", "help")]
    wrong_binary, unknown_binary, wrong_device, unknown_device = [], [], [], []
    for call in selected:
        if not expected_executable or not Path(call.executable).is_absolute():
            unknown_binary.append({"call": call.number, "executable": call.executable})
        elif Path(call.executable).resolve() != Path(expected_executable).resolve():
            wrong_binary.append({"call": call.number, "executable": call.executable})
    for call in calls:
        if not call.requires_device:
            continue
        if not expected_udid or not call.device:
            unknown_device.append({"call": call.number})
        else:
            for device in [call.device] + call.nested_devices:
                if device.casefold() != expected_udid.casefold():
                    wrong_device.append({"call": call.number, "device": device})
    return [check("identity.candidate", bool(expected_executable and selected) and not wrong_binary and not unknown_binary,
                  wrong_binary + unknown_binary, "Every UI/help invocation must use the recorded absolute executable.", failed=bool(wrong_binary)),
            check("identity.simulator", bool(expected_udid and selected) and not wrong_device and not unknown_device,
                  wrong_device + unknown_device, "Every device command must explicitly name the recorded simulator.", failed=bool(wrong_device))]


def setup_checks(calls, scenario, expected):
    required = ("bundleId", "udid", "runDirectory", "developerDir") + (("project", "scheme") if scenario == "weather" else ())
    if not expected or any(not expected.get(key) for key in required):
        return [check("setup.contract", False, reason="The runner must bind the measured setup commands to the app and simulator.")]
    first_ui = min((call.number for call in calls if call.category == "ui"), default=math.inf)
    derived = str(Path(expected["runDirectory"]) / "DerivedData")
    build_exe = str(Path(expected["developerDir"]) / "usr/bin/xcodebuild")
    app_path = str(Path(derived) / "Build/Products/Debug-iphonesimulator/Weather.app")
    received, wrong = {"build": [], "install": [], "launch": []}, []
    for call in calls:
        if call.category != "setup":
            continue
        if setup_execution_denied(call):
            continue
        args = call.argv
        kind, valid = "unknown", False
        if args and Path(args[0]).name == "xcodebuild":
            kind = "build"
            fields = {"-project": expected.get("project"), "-scheme": expected.get("scheme"),
                      "-configuration": "Debug", "-sdk": "iphonesimulator", "-derivedDataPath": derived, "-jobs": "1"}
            valid = scenario == "weather" and args[0] == build_exe and all(options(args, key) == [value] for key, value in fields.items())
            destination = option(args, "-destination") or ""
            valid = valid and len(options(args, "-destination")) == 1 and re.search(r"(?:^|,)id=" + re.escape(expected["udid"]) + r"(?:,|$)", destination, re.I) is not None
            # This is the supplied build contract. Extra build settings can alter
            # app behaviour and are not an equivalent benchmark setup.
            remaining = args[1:]
            for key in list(fields) + ["-destination"]:
                if key in remaining:
                    index = remaining.index(key)
                    remaining = remaining[:index] + remaining[index + 2:]
            valid = valid and remaining == ["build"]
        elif len(args) >= 3 and args[:2] == ["/usr/bin/xcrun", "simctl"]:
            kind = args[2]
            if kind == "install":
                valid = scenario == "weather" and args == ["/usr/bin/xcrun", "simctl", "install", expected["udid"], app_path]
            elif kind == "launch":
                valid = args == ["/usr/bin/xcrun", "simctl", "launch", expected["udid"], expected["bundleId"]]
        if not valid or (kind != "launch" and call.number >= first_ui):
            wrong.append({"call": call.number, "kind": kind, "reason": "Wrong setup arguments or build/install occurred after UI work started."})
            continue
        proof = call.text + "\n" + "\n".join(other.text for other in calls if other.category == "publicOutput" and other.evidence_call == call.number)
        successful = bool(call.result_line) and not call.error and call.process_completed is not False and "** BUILD FAILED **" not in proof
        verified = call.process_completed is True or (kind == "build" and "** BUILD SUCCEEDED **" in proof)
        if kind == "launch":
            successful = successful and re.search(r"(?:^|\n)" + re.escape(expected["bundleId"]) + r": [1-9]\d*(?:\n|$)", call.text) is not None
            verified = verified or successful
        if successful and call.number < first_ui:
            received[kind].append((call.number, verified))
    checks = [check("setup.contract", not wrong, wrong, "Use supplied setup commands. Matching-app launch recovery is allowed before the task's read-only verification; denied commands do not prove execution.", failed=bool(wrong))]
    kinds = ("build", "install", "launch") if scenario == "weather" else ("launch",)
    previous = 0
    for kind in kinds:
        item = next(((number, verified) for number, verified in received[kind] if number > previous), None)
        number, verified = item if item else (None, False)
        checks.append(check("setup." + kind, number is not None and verified, [{"call": number}] if number else [],
                            "Measured setup must use the expected app, fresh run build directory and device in order, with a completed foreground process receipt or terminal output proof.", failed=number is None))
        previous = number if number is not None else math.inf
    return checks


def score_run(run_dir, scenario, tool, expected_executable=None, expected_udid=None, expected_setup=None):
    if scenario not in ("weather", "reminders", "contacts") or tool not in ("axe", "flowdeck", "rocketsim"):
        raise ValueError("Unsupported benchmark scenario or tool")
    root = Path(run_dir)
    calls, errors = read_transcript(root / "claude.jsonl", tool, (expected_setup or {}).get("runDirectory"))
    try:
        harness = json.loads((root / "result.json").read_text())
    except (OSError, ValueError):
        harness = {}
    captured = [capture for call in calls for capture in call.captures]
    checks = globals()[scenario](calls, captured)
    checks += identity_checks(calls, expected_executable, expected_udid)
    checks += setup_checks(calls, scenario, expected_setup)
    unknown = [c.number for c in calls if c.category == "unknown"]
    checks += [check("transcript.complete", not errors, reason="; ".join(errors)),
               check("procedure.allowedToolSurface", not unknown, [{"call": n} for n in unknown], "Unknown command or non-image file read requires review." if unknown else "Only recorded tool surface, setup and screenshots were used.")]
    run = harness.get("run", {})
    process_ok = run.get("claudeExitCode") == 0 and run.get("parserExitCode") == 0
    checks.append(check("process.completed", process_ok, reason="Process completion is separate from task correctness.", failed=bool(run) and not process_ok))
    elapsed = run.get("wallClockSeconds")
    if not isinstance(elapsed, (int, float)) or not math.isfinite(elapsed) or elapsed < 0:
        elapsed = None
    metrics = {"totalCalls": len(calls), "uiCalls": sum(c.category == "ui" for c in calls),
               "setupCalls": sum(c.category == "setup" for c in calls), "helpCalls": sum(c.category == "help" for c in calls),
               "elapsedSeconds": elapsed, **token_totals(calls), "imageCount": sum(c.image_count for c in calls),
               "imageBytes": sum(c.image_bytes for c in calls), "errorCalls": sum(c.error for c in calls)}
    checks.append(check("measurement.complete", metrics["tokenStatus"] == "measured" and elapsed is not None,
                        reason="Exact text-token count and measured task clock are required."))
    status = "failed" if any(c["status"] == "failed" for c in checks) else "unverified" if any(c["status"] != "passed" for c in checks) else "passed"
    return {"schema": "axe.agent-benchmark.score", "schemaVersion": 1, "scorerVersion": SCORER_VERSION,
            "scenario": scenario, "tool": tool, "status": status, "correctness": {"status": status, "checks": checks},
            "observedRuntime": observed_runtime(root),
            "metrics": metrics, "transcriptSHA256": hashlib.sha256((root / "claude.jsonl").read_bytes()).hexdigest(),
            "warnings": ["Screenshot-only facts remain unverified; final assistant claims are not task proof.",
                         "Text tokens exclude images, provider input/cache/thinking usage, and unread persisted files.",
                         "Exact creation counts require the runner's clean-state preflight in addition to observed UI flows."]}
