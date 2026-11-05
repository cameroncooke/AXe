"""Pinned CLI metadata and generic model guides; no simulator operations."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess


TOOLS = ("axe", "flowdeck", "rocketsim")
GUIDES = Path(__file__).resolve().parent / "guides"
MODES = {
    "axe": "--agent --view navigation; --view reading for visible text; --view full for base schema",
    "flowdeck": "ui simulator screen --json --interactive-elements; omit --interactive-elements for visible text",
    "rocketsim": "elements --agent --agent-mode act; nav for navigation; debug for missing semantics",
}


def _tool(tool: str) -> None:
    if tool not in TOOLS:
        raise ValueError("Unsupported benchmark tool: " + tool)


def _executable(executable: str) -> Path:
    if any(char in executable for char in ("\n", "\r", "\x00", "`")):
        raise ValueError("Executable path contains unsupported characters")
    candidate = Path(executable).expanduser()
    if not candidate.is_absolute():
        raise ValueError("An explicit absolute executable path is required")
    candidate = candidate.resolve(strict=True)
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise ValueError("Not an executable file: " + str(candidate))
    return candidate


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _axe_runtime(binary: Path) -> dict[str, object]:
    """Hash only known adjacent AXe bundles, never an arbitrary install directory."""
    files = {}
    for name in ('Frameworks', 'AXe_AXe.bundle', 'cadisplay-context'):
        component = binary.parent / name
        if not component.exists() and not component.is_symlink():
            continue
        candidates = [component]
        if component.is_dir() and not component.is_symlink():
            candidates += sorted(component.rglob('*'))
        for file in candidates:
            relative = str(file.relative_to(binary.parent))
            if file.is_symlink():
                target = file.resolve(strict=False)
                try:
                    target.relative_to(binary.parent)
                except ValueError as error:
                    raise ValueError('Bundled AXe runtime link escapes its directory: ' + str(file)) from error
                files[relative] = {'symlink': os.readlink(file)}
            elif file.is_file():
                files[relative] = {'sha256': sha256_file(file)}
    encoded = json.dumps(files, sort_keys=True, separators=(',', ':')).encode()
    return {'runtimeSHA256': hashlib.sha256(encoded).hexdigest(), 'runtimeFiles': files,
            'runtimeScope': 'Known adjacent Frameworks, AXe_AXe.bundle and cadisplay-context only'}


def _rocket_app(binary: Path, app: str | None, binary_hash: str) -> dict[str, object]:
    bundle = Path(app).expanduser().resolve(strict=True) if app else next(
        (ancestor for ancestor in binary.parents if ancestor.suffix == ".app"), None
    )
    if bundle is None:
        raise ValueError("RocketSim requires its companion .app path for version evidence")
    plist_path = bundle / "Contents/Info.plist"
    with plist_path.open("rb") as source:
        info = plistlib.load(source)
    fields = ("CFBundleShortVersionString", "CFBundleVersion", "CFBundleIdentifier", "CFBundleExecutable")
    if any(not isinstance(info.get(key), str) or not info[key] for key in fields):
        raise ValueError("RocketSim companion bundle has incomplete version metadata")
    if info["CFBundleIdentifier"] != "com.swiftLee.RocketSim":
        raise ValueError("The companion app is not RocketSim")
    helper = bundle / "Contents/Resources/CLI/rocketsim"
    if not helper.is_file() or sha256_file(helper) != binary_hash:
        raise ValueError("The supplied CLI does not match this RocketSim app's bundled CLI")
    app_binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
    return {
        "path": str(bundle), "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"], "bundleIdentifier": info["CFBundleIdentifier"],
        "executable": str(app_binary), "binarySHA256": sha256_file(app_binary),
        "infoPlistSHA256": sha256_file(plist_path), "bundledCLI": str(helper),
    }


def inspect_tool(tool: str, executable: str, app: str | None = None) -> dict[str, object]:
    """Read a pinned executable's identity. Never install, launch or update an app."""
    _tool(tool)
    binary = _executable(executable)
    binary_hash = sha256_file(binary)
    result: dict[str, object] = {
        "tool": tool, "requestedExecutable": executable, "executable": str(binary),
        "binarySHA256": binary_hash, "mode": MODES[tool], "companionApp": None,
    }
    if tool == 'axe':
        result.update(_axe_runtime(binary))
    if tool == "rocketsim":
        companion = _rocket_app(binary, app, binary_hash)
        result.update(version=companion["version"], build=companion["build"],
                      companionApp=companion, versionSource="companion Info.plist (CLI has no version command)")
    else:
        probe = subprocess.run([str(binary), "--version"], capture_output=True,
                               text=True, timeout=15, check=False)
        display = probe.stdout.strip()
        if probe.returncode or not display:
            raise ValueError("Version probe failed for " + tool + ": " + probe.stderr.strip())
        result.update(version=display, build=None, versionSource="CLI --version",
                      versionProbe={"argv": [str(binary), "--version"], "exitCode": probe.returncode,
                                    "stdout": probe.stdout, "stderr": probe.stderr})
        if tool == "flowdeck":
            match = re.fullmatch(r"([^\s]+)\s+\[([^\]]+)\]", display)
            if match:
                result.update(version=match.group(1), build=match.group(2))
    if sha256_file(binary) != binary_hash:
        raise ValueError("Executable changed during metadata collection")
    if tool == 'axe' and _axe_runtime(binary)['runtimeSHA256'] != result['runtimeSHA256']:
        raise ValueError('AXe bundled runtime changed during metadata collection')
    return result


def render_guide(tool: str, executable: str, udid: str) -> str:
    """Render one generic skill. Scenarios and navigation routes are not embedded."""
    _tool(tool)
    binary = _executable(executable)
    if not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", udid):
        raise ValueError("A simulator UUID is required")
    source = (GUIDES / (tool + ".md")).read_text(encoding="utf-8")
    return source.replace("{{EXECUTABLE}}", shlex.quote(str(binary))).replace("{{UDID}}", udid)


def _prefixes(executable: str) -> list[str]:
    binary = str(_executable(executable))
    # Match the ordinary path and shell-quoted forms in raw Bash transcripts.
    return list(dict.fromkeys((binary, shlex.quote(binary), '"' + binary.replace('"', '\\"') + '"')))


def allowed_tools(tool: str, executable: str) -> list[str]:
    _tool(tool)
    return ["Read", "Write"] + ["Bash(" + prefix + " *)" for prefix in _prefixes(executable)]


def tool_matchers(tool: str, executable: str) -> list[dict[str, object]]:
    """XcodeBuildMCP benchmark ToolAnalysisConfig matcher shape."""
    _tool(tool)
    verbs = {
        "axe": ("describe-ui", "tap", "type", "swipe", "drag", "scroll", "batch", "screenshot",
                "key", "key-combo", "key-sequence", "button", "gesture", "touch", "slider"),
        "flowdeck": ("ui simulator screen", "ui simulator tap", "ui simulator type", "ui simulator swipe",
                     "ui simulator scroll", "ui simulator drag", "ui simulator batch", "ui simulator press"),
        "rocketsim": ("elements", "interact", "do", "wait", "screen", "screenshot", "snapshot"),
    }[tool]
    matchers = []
    for prefix in _prefixes(executable):
        for verb in verbs:
            variants = ("", " --output text", " --output json") if tool == "axe" else ("",)
            for variant in variants:
                matchers.append({"kind": "bashCommand", "commandPrefix": prefix + variant + " " + verb,
                                 "shortName": tool + "." + verb.replace("ui simulator ", ""),
                                 "uiAutomation": True})
        if tool == "flowdeck":
            matchers.append({"kind": "bashCommand", "commandPrefix": prefix + " ui simulator",
                             "shortName": "flowdeck.ui", "uiAutomation": True})
        matchers.append({"kind": "bashCommand", "commandPrefix": prefix,
                         "shortName": tool + ".other", "uiAutomation": False})
    return sorted(matchers, key=lambda item: len(str(item["commandPrefix"])), reverse=True)
