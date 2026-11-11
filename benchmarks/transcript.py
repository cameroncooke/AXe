"""Read the model's observed tool output, never its final claims or hidden full files."""

from __future__ import annotations

from dataclasses import dataclass, field
import base64
import json
from pathlib import Path
import re
import shlex


@dataclass
class Node:
    ref: str
    role: str
    label: str
    value: str = ""
    identifier: str = ""
    selected: bool = False


@dataclass
class Capture:
    call: int
    line: int
    nodes: list[Node]
    identity: str = ""
    complete: bool = True


@dataclass
class Action:
    kind: str
    label: str = ""
    value: str = ""
    executed: bool | None = None


@dataclass
class Call:
    number: int
    identity: str
    name: str
    command: str
    arguments: dict
    line: int
    result_line: int = 0
    text: str = ""
    error: bool = False
    category: str = "unknown"
    actions: list[Action] = field(default_factory=list)
    captures: list[Capture] = field(default_factory=list)
    image_count: int = 0
    image_bytes: int = 0
    executable: str = ""
    device: str = ""
    requires_device: bool = False
    argv: list[str] = field(default_factory=list)
    nested_devices: list[str] = field(default_factory=list)
    evidence_call: int = 0
    screenshot_output: str = ""
    process_completed: bool | None = None


READS = {"describe-ui", "elements", "screen", "screenshot", "get-value", "inspect", "find", "status", "list-simulators", "wait", "focused", "accessibility-audit"}
INPUTS = {"tap", "type", "swipe", "drag", "gesture", "key", "key-combo", "key-sequence", "touch", "button", "slider", "scroll", "press", "home", "activate", "long-press"}
VALUE_FLAGS = {"--udid", "--simulator", "-S", "--snapshot-id", "--ref", "--id", "--focus-id", "--label", "--screen", "--agent-mode", "--view", "--output", "--expected-pid", "--row-offset", "--point", "--geometry", "--duration", "--direction", "--distance", "--element-type", "--screen-id", "--screen-uuid", "--element", "--text"}


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(item.get("text", "") for item in value if isinstance(item, dict) and item.get("type") == "text")
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")) if value is not None else ""


def json_output(text):
    """Accept a complete JSON reply, with optional process-exit wrapper only."""
    text = re.sub(r"\x1b\[[0-9;]*m", "", text).strip()
    text = re.sub(r"^Exit code \d+\n", "", text)
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return None


def split_row(row):
    cells, cell, escaped = [], [], False
    for char in row:
        if escaped:
            cell.append({"n": "\n", "r": "\r", "t": "\t"}.get(char, char))
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == "|":
            cells.append("".join(cell))
            cell = []
        else:
            cell.append(char)
    if escaped:
        cell.append("\\")
    return cells + ["".join(cell)]


def captures(value, call, line):
    output = []
    if not isinstance(value, dict):
        return output
    if value.get("schema") == "axe.output.agent-result":
        data = value.get("data", {})
        raw = data.get("capture")
        cache = data.get("cache", {})
        # A refusal before input may carry the current screen. A full reply marks it as a refreshed table.
        # A compact reply omits the cache object unless a refresh is required, and its capture is then current.
        refreshed = cache.get("status") == "refreshed" or "cache" not in data
        if not isinstance(raw, dict) or cache.get("requiresRefresh") or (value.get("didError") and not refreshed):
            return output
        rows = raw.get("rows")
        if rows is None:
            rows = sum([raw.get(key, []) for key in ("targets", "scroll", "text")], [])
        nodes = []
        for row in rows:
            cells = split_row(row) if isinstance(row, str) else []
            if len(cells) >= 5 and not cells[0].startswith("!"):
                nodes.append(Node(cells[0], cells[2].lower(), cells[3], cells[4], cells[5] if len(cells) > 5 else "", cells[4] == "selected"))
        if nodes:
            identity = [str(raw.get(k, "")) for k in ("snapshotID", "screenHash", "seq")]
            key = ":".join(identity) if any(identity) else ""
            output.append(Capture(call, line, nodes, key, not raw.get("page", {}).get("nextOffset") and not raw.get("nextRowOffset")))
    elif value.get("rs") in ("1", 1) and value.get("ok", True):
        raw = value.get("data", {})
        nodes = []
        for row in raw.get("rows", []):
            cells = split_row(row) if isinstance(row, str) else []
            if len(cells) >= 4 and not cells[0].startswith("!"):
                nodes.append(Node(cells[0], cells[1].lower(), cells[2], cells[3], selected="selected" in cells[4:]))
        if nodes:
            key = str(raw.get("screen", "")) + ":" + str(raw.get("seq", "")) if raw.get("screen") else ""
            output.append(Capture(call, line, nodes, key, not raw.get("truncated", False)))
        if not nodes and isinstance(raw.get("steps"), list):
            for step in raw["steps"]:
                if isinstance(step, dict) and step.get("kind") != "error" and isinstance(step.get("result"), dict):
                    output.extend(captures({"rs": "1", "ok": True, "data": step["result"]}, call, line))
    elif value.get("schema") == "flowdeck.ui" or "accessibility" in value:
        raw = value.get("accessibility", {})
        nodes = []

        def walk(items):
            for item in items if isinstance(items, list) else []:
                if not isinstance(item, dict):
                    continue
                if item.get("visible", True):
                    nodes.append(Node(str(item.get("ref", "")), str(item.get("role", item.get("type", ""))).lower(),
                                      str(item.get("label", "")), str(item.get("value", "")), str(item.get("id", "")), bool(item.get("selected", False))))
                walk(item.get("children", []))
        walk(raw.get("tree", []))
        if nodes:
            output.append(Capture(call, line, nodes, str(raw.get("screen_hash", "")), not raw.get("truncated", False)))
    # Action responses can wrap a current screen. Never traverse previous/disappeared/debug fields.
    if not output:
        for key in ("screen", "snapshot", "result", "final"):
            nested = value.get(key)
            if isinstance(nested, dict):
                output.extend(captures(nested, call, line))
    return output


def option(args, name):
    for index, token in enumerate(args):
        if token == name and index + 1 < len(args):
            return args[index + 1]
        if token.startswith(name + "="):
            return token[len(name) + 1:]
    return None


def options(args, name):
    return [args[index + 1] for index, token in enumerate(args[:-1]) if token == name] + [token[len(name) + 1:] for token in args if token.startswith(name + "=")]


def positional(args):
    result = []
    skip = False
    for item in args:
        if skip:
            skip = False
        elif item in VALUE_FLAGS:
            skip = True
        elif not item.startswith("-"):
            result.append(item)
    return result


def resolve(args, previous, kind, step=None):
    step = step or {}
    reference = step.get("ref") or option(args, "--ref")
    identifier = step.get("id") or option(args, "--id") or option(args, "--focus-id")
    label = step.get("label") or option(args, "--label")
    if reference or identifier:
        matches = [n for n in previous if n.ref == str(reference or identifier) or (identifier and n.identifier == identifier)]
        if len(matches) == 1:
            return matches[0].label
    if label:
        return str(label)
    pos = positional(args)
    return pos[0] if pos and kind in ("tap", "press") else ""


def action_receipt(value, error):
    if isinstance(value, dict) and value.get("schema") == "axe.output.agent-result":
        data = value.get("data", {})
        action = data.get("action") or {}
        if action.get("enqueuedEventCount", 0) > 0:
            return True
        batch = data.get("batch") or {}
        if batch:
            return batch.get("completedSteps", 0) > 0
        if value.get("didError"):
            return False
        return True
    if isinstance(value, dict):
        for field in ("ok", "success"):
            if field in value:
                return bool(value[field])
    return False if error else True


def has_unquoted_newline(command):
    """Permit multiline text arguments, not newline-separated shell commands."""
    quote, escaped = None, False
    for char in command:
        if char == "\n" and quote is None:
            return True
        if escaped:
            escaped = False
        elif char == "\\" and quote != "'":
            escaped = True
        elif quote:
            if char == quote:
                quote = None
        elif char in ("'", '"'):
            quote = char
    return False


def classify(call, tool, previous, batch_files=None, run_directory=None):
    if call.name == "Read":
        return
    if call.name != "Bash":
        return
    if call.arguments.get("run_in_background"):
        return
    # A benchmark invocation is one command. Do not mistake an embedded second
    # command or shell substitution for a read-only call.
    if has_unquoted_newline(call.command) or "`" in call.command or "$(" in call.command:
        return
    try:
        lexer = shlex.shlex(call.command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        args = list(lexer)
    except ValueError:
        return
    if run_directory and len(args) > 3 and Path(args[0]).name == "rocketsim" and args[1] == "screenshot" and args[-2] == ">":
        try:
            target = Path(args[-1]).resolve()
            target.relative_to(Path(run_directory).resolve())
            if target.suffix.lower() == ".png":
                call.screenshot_output = str(target)
                args = args[:-2]
        except ValueError:
            pass
    if any(token and all(char in ";&|<>()" for char in token) for token in args):
        return
    if args and Path(args[0]).name == "env":
        args = args[1:]
        while args and "=" in args[0]:
            args = args[1:]
    if not args:
        return
    call.argv = args
    call.executable = args[0]
    exe = Path(args[0]).name.lower()
    if exe == "xcodebuild" or (exe == "xcrun" and "xcodebuild" in args):
        call.category = "setup"
        destination = option(args, "-destination") or ""
        matched = re.search(r"(?:^|,)id=([^,]+)", destination)
        call.device = matched.group(1) if matched else ""
        call.requires_device = True
        return
    if exe == "xcrun" and len(args) > 2 and args[1] == "simctl" and args[2] in ("launch", "install"):
        call.category = "setup"
        call.device = next((arg for arg in args[3:] if re.fullmatch(r"[0-9a-fA-F-]{36}", arg)), "")
        call.requires_device = True
        return
    if exe not in ("axe", "flowdeck", "rocketsim") or exe != tool:
        return
    if "--help" in args or "-h" in args or "--version" in args or (tool == "flowdeck" and ("--examples" in args or "-e" in args)):
        call.category = "help"
        return
    commands = READS | INPUTS | {"batch", "do"}
    found = next((i for i in range(1, len(args)) if args[i] in commands), None)
    if found is None:
        return
    verb, tail = args[found], args[found + 1:]
    call.category = "ui"
    call.requires_device = verb != "list-simulators"
    if tool == "rocketsim" and (verb == "status" or args[1:3] == ["simulator", "focused"] or (verb == "wait" and tail[:1] == ["time"])):
        call.requires_device = False
    call.device = option(args, "--udid") or option(args, "--simulator") or option(args, "-S") or ""
    if verb in READS:
        return
    value = json_output(call.text)
    executed = action_receipt(value, call.error)
    if verb == "do" and tool == "rocketsim":
        steps = options(tail, "--step")
        results = value.get("data", {}).get("steps", []) if isinstance(value, dict) else []
        for index, step in enumerate(steps):
            result = results[index] if index < len(results) else {}
            child = Call(call.number, call.identity, "Bash", shlex.quote(call.executable) + " " + step, {}, call.line)
            child.text = json.dumps({"rs": "1", "ok": bool(result and result.get("kind") != "error"), "data": result.get("result", {})})
            classify(child, tool, previous, batch_files, run_directory)
            if child.category != "ui" or "do" in child.argv[1:]:
                call.category = "unknown"
                return
            call.nested_devices.append(child.device or call.device)
            # A failed step can have partial input; absence of a result proves no execution.
            for action in child.actions:
                action.executed = True if result and result.get("kind") != "error" else None if result else False
            call.actions.extend(child.actions or [Action("observe", executed=bool(result))])
        if not steps:
            call.category = "unknown"
        return
    if verb == "batch":
        body = option(tail, "--steps-json") or option(tail, "--steps") or option(tail, "--actions")
        batch_path = option(tail, "--file")
        if batch_path and batch_files and str(Path(batch_path).resolve()) in batch_files:
            writer = batch_files[str(Path(batch_path).resolve())]
            body = writer.arguments.get("content")
            writer.category = "batchPayload"
        try:
            parsed = json.loads(body or "")
            steps = parsed.get("steps", []) if isinstance(parsed, dict) else parsed
            if not isinstance(steps, list):
                raise ValueError("Batch is not a list")
        except (ValueError, TypeError):
            if executed:
                call.actions.append(Action("unknown", executed=None))
            return
        completed = None
        receipts = []
        if isinstance(value, dict) and value.get("schema") == "axe.output.agent-result":
            batch = value.get("data", {}).get("batch") or {}
            completed = batch.get("completedSteps")
            receipts = batch.get("steps", [])
        for index, step in enumerate(steps):
            if not isinstance(step, dict):
                call.actions.append(Action("unknown", executed=None))
                continue
            kind = str(step.get("action", "unknown"))
            sent = index < completed if isinstance(completed, int) else executed
            receipt = next((r.get("receipt") for r in receipts if r.get("index") == index + 1), None)
            if isinstance(receipt, dict) and receipt.get("enqueuedEventCount", 0) > 0:
                sent = True
            call.actions.append(Action(kind, resolve([], previous, kind, step), str(step.get("text", "")), sent))
    else:
        pos = positional(tail)
        typed = option(tail, "--text") or (pos[0] if verb == "type" and pos else "")
        call.actions.append(Action("tap" if verb == "activate" else verb, resolve(tail, previous, verb), typed, executed))


def returned_paths(call):
    """Only explicit public artifact paths authorize later Read calls."""
    wrapper_header = call.text.split("\n\nPreview", 1)[0]
    paths = set(re.findall(r"Full output saved to:\s*([^\n]+)", wrapper_header)) if call.text.startswith("<persisted-output>") else set()
    if call.screenshot_output and not call.error:
        paths.add(call.screenshot_output)
    value = json_output(call.text)
    screenshot = "screenshot" in call.argv
    plain = re.sub(r"\x1b\[[0-9;]*m", "", call.text)
    if not call.error and (screenshot or "--screenshot" in call.argv) and plain.startswith("✓ Screen captured\n"):
        for artifact in re.findall(r"^\s*Screenshot:\s*(/[^\n]+)\s*$", plain, re.M):
            if Path(artifact.strip()).suffix.lower() == ".png":
                paths.add(artifact.strip())
    # AXe's plain screenshot prints "Screenshot saved to PATH" and then the path. Accept it only
    # when it names the file the command was asked to write.
    if not call.error and screenshot and "--output" in call.argv[:-1]:
        requested = call.argv[call.argv.index("--output") + 1]
        saved = re.findall(r"^Screenshot saved to (/[^\n]+?)\s*$", plain, re.M)
        if Path(requested).is_absolute() and Path(requested).suffix.lower() == ".png" and requested in saved:
            paths.add(requested)
    def walk(item, screenshot_context=False):
        if isinstance(item, dict):
            for key, child in item.items():
                if key == "screenshot" and isinstance(child, dict):
                    walk(child, screenshot_context=child.get("captured", True) is True)
                elif key in ("screenshot_path", "screenshotPath", "output_file", "outputFile") or ((screenshot or screenshot_context) and key in ("path", "file", "filePath", "file_path")):
                    if isinstance(child, str) and Path(child).is_absolute():
                        paths.add(child)
                elif isinstance(child, (dict, list)):
                    walk(child, screenshot_context)
        elif isinstance(item, list):
            for child in item:
                walk(child, screenshot_context)
    walk(value)
    return {str(Path(path.strip()).resolve()) for path in paths if Path(path.strip()).is_absolute()}


def plain_file_read(call):
    """The one absolute file a plain `tail`, `head` or `cat` reads, or None.

    Only line or byte counts are accepted; following, several files and any shell
    operator (refused by classify, which then leaves argv empty) are not plain reads."""
    if call.name != "Bash" or not call.argv or Path(call.argv[0]).name not in ("tail", "head", "cat"):
        return None
    counted = Path(call.argv[0]).name != "cat"
    paths, index, args = [], 1, call.argv
    while index < len(args):
        arg = args[index]
        if counted and arg in ("-n", "-c") and index + 1 < len(args) and re.fullmatch(r"\+?\d+", args[index + 1]):
            index += 2
            continue
        if counted and re.fullmatch(r"-(?:[nc]\+?\d+|\d+)", arg):
            index += 1
            continue
        if arg.startswith("-"):
            return None
        paths.append(arg)
        index += 1
    if len(paths) != 1 or not Path(paths[0]).is_absolute():
        return None
    return str(Path(paths[0]).resolve())


def read_output(text):
    # Read adds line numbers and an optional standard safety footer. Keep raw
    # text for token accounting, remove only these wrappers for JSON decoding.
    text = text.split("\n<system-reminder>", 1)[0]
    return "\n".join(re.sub(r"^\s*\d+(?:→|\t)", "", line) for line in text.splitlines())


def read_transcript(file, tool, run_directory=None):
    calls, by_id, errors = [], {}, []
    previous = []
    public_files, batch_files = {}, {}
    skill_root = None
    for number, line in enumerate(Path(file).read_text().splitlines(), 1):
        try:
            event = json.loads(line)
        except ValueError:
            errors.append(f"Malformed JSONL at line {number}")
            continue
        if isinstance(event, dict) and isinstance(event.get("cwd"), str) and event["cwd"]:
            # The harness installs the run's skills under its isolated working directory.
            skill_root = Path(event["cwd"]).resolve() / ".claude" / "skills"
        message = event.get("message", {}) if isinstance(event, dict) else {}
        content = message.get("content", []) if isinstance(message, dict) else []
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                identity = block.get("id")
                if not identity or identity in by_id:
                    errors.append(f"Duplicate or absent tool ID at line {number}")
                    continue
                arguments = block.get("input", {})
                call = Call(len(calls) + 1, identity, block.get("name", ""), arguments.get("command", ""), arguments, number)
                calls.append(call)
                by_id[identity] = call
            elif block.get("type") == "tool_result":
                call = by_id.get(block.get("tool_use_id"))
                if call is None or call.result_line:
                    errors.append(f"Unpaired or repeated result at line {number}")
                    continue
                call.result_line = number
                call.text = text_content(block.get("content"))
                call.error = bool(block.get("is_error")) or bool(re.match(r"^Exit code [1-9]\d*\n", call.text))
                receipt = event.get("tool_use_result")
                if call.name == "Bash" and isinstance(receipt, dict):
                    background = any(value for key, value in receipt.items()
                                     if "background" in key.lower() or key.lower() in ("async", "shellid", "taskid", "task_id"))
                    interrupted = receipt.get("interrupted")
                    if interrupted is True or background or call.arguments.get("run_in_background"):
                        call.process_completed = False
                    elif interrupted is False and block.get("is_error") is False and not call.error:
                        call.process_completed = True
                blocks = block.get("content", [])
                for item in blocks if isinstance(blocks, list) else []:
                    if isinstance(item, dict) and item.get("type") == "image":
                        call.image_count += 1
                        source = item.get("source", {})
                        if source.get("type") == "base64":
                            try:
                                call.image_bytes += len(base64.b64decode(source.get("data", ""), validate=True))
                            except ValueError:
                                errors.append(f"Malformed image payload at line {number}")
                        else:
                            errors.append(f"Image byte count is unavailable at line {number}")
                classify(call, tool, previous, batch_files, run_directory)
                file_name = call.arguments.get("file_path", "")
                resolved = str(Path(file_name).resolve()) if file_name else ""
                if call.name == "Write" and run_directory and resolved and not call.error:
                    try:
                        relative = Path(resolved).relative_to(Path(run_directory).resolve())
                        if relative.suffix == ".json" and "DerivedData" not in relative.parts:
                            json.loads(call.arguments.get("content", ""))
                            batch_files[resolved] = call
                    except (ValueError, TypeError):
                        pass
                shell_read = plain_file_read(call)
                if call.name == "Read" and resolved in public_files:
                    origin = public_files[resolved]
                    call.category = "image" if call.image_count else "publicOutput"
                    call.evidence_call = origin.number
                elif call.category == "unknown" and shell_read in public_files:
                    # A tail, head or cat of a saved public output reads the same file as Read.
                    call.category = "publicOutput"
                    call.evidence_call = public_files[shell_read].number
                elif (call.name == "Read" and resolved and skill_root is not None
                        and Path(resolved).is_relative_to(skill_root)):
                    call.category = "help"  # Reading the installed skill, like a --help call.
                evidence_text = read_output(call.text) if call.category == "publicOutput" else call.text
                call.captures = captures(json_output(evidence_text), call.evidence_call or call.number, number) if call.category in ("ui", "publicOutput") else []
                if call.captures:
                    previous = call.captures[-1].nodes
                if call.category in ("ui", "setup", "help", "publicOutput"):
                    for path in returned_paths(call):
                        public_files[path] = call
    for call in calls:
        if not call.result_line:
            errors.append(f"Missing result for call {call.number}")
    return calls, errors


def observed_runtime(run_dir):
    """Read actual Claude init metadata; requested aliases are not version proof."""
    initializations, models = [], set()
    for line in (Path(run_dir) / "claude.jsonl").read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "system" and event.get("subtype") == "init":
            initializations.append(event)
        message = event.get("message")
        if isinstance(message, dict) and message.get("model"):
            models.add(message["model"])
    init = initializations[0] if len(initializations) == 1 else {}
    return {"model": init.get("model"), "claudeVersion": init.get("claude_code_version"),
            "modelsObserved": sorted(models), "initializationCount": len(initializations)}
