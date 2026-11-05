"""Versioned benchmark results and explicit, evidence-only AXe baseline selection.

A baseline is one complete successful run, ordered by calls, time, then text
tokens. It is never a synthetic set of the best numbers from different runs.
Tool versions are recorded but deliberately excluded from the comparison key.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import tempfile
from datetime import datetime, timezone


RESULT_SCHEMA = "axe.agent-benchmark.result"
REGISTRY_SCHEMA = "axe.agent-benchmark.baselines"
SCHEMA_VERSION = 1
TOOLS = {"axe", "flowdeck", "rocketsim"}
STATUSES = {"passed", "failed", "unverified", "blocked"}
HASH_FIELDS = (
    "taskSHA256", "sharedRulesSHA256", "appSourceSHA256", "guideSetSHA256",
    "harnessSHA256", "scorerSHA256",
)
TEXT_FIELDS = (
    "model", "modelVersion", "claudeVersion", "deviceType", "runtimeVersion",
    "setupPolicy", "tokenizer", "tokenScope",
)
CONTRACT_FIELDS = HASH_FIELDS + TEXT_FIELDS + ("screenWidth", "screenHeight")
METRIC_FIELDS = ("totalCalls", "elapsedSeconds", "returnedTextTokens", "imageCount", "imageBytes")
RANK_FIELDS = ("totalCalls", "elapsedSeconds", "returnedTextTokens")


def _json_bytes(value: dict) -> bytes:
    return (json.dumps(value, sort_keys=True, ensure_ascii=False, indent=2,
                       allow_nan=False) + "\n").encode("utf-8")


def _decode(raw: bytes) -> dict:
    def bad_number(value: str):
        raise ValueError(f"Non-finite JSON number: {value}")

    value = json.loads(raw, parse_constant=bad_number)
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object")
    return value


def _number(value, *, integral: bool = False, positive: bool = False) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    return (math.isfinite(value) and value >= 0 and
            (not positive or value > 0) and
            (not integral or isinstance(value, int)))


def _text(value) -> bool:
    return isinstance(value, str) and bool(value.strip())


def validate_result(result: dict) -> None:
    """Validate a result envelope. Incomplete runs can retain null observations."""
    if (not isinstance(result, dict) or result.get("schema") != RESULT_SCHEMA or
            type(result.get("schemaVersion")) is not int or result["schemaVersion"] != SCHEMA_VERSION):
        raise ValueError("Unsupported benchmark result schema")
    if not _text(result.get("runId")) or result.get("scenario") not in {"weather", "reminders", "contacts"}:
        raise ValueError("A result needs a runId and a known scenario")
    if result.get("status") not in STATUSES:
        raise ValueError("Unknown benchmark status")
    tool = result.get("tool")
    if not isinstance(tool, dict) or tool.get("name") not in TOOLS:
        raise ValueError("A result needs its tool identity")
    if not isinstance(result.get("contract"), dict) or not isinstance(result.get("metrics"), dict):
        raise ValueError("A result needs contract and metrics objects")
    correctness = result.get("correctness")
    if not isinstance(correctness, dict) or correctness.get("status") not in STATUSES:
        raise ValueError("A result needs an explicit correctness status")
    checks = correctness.get("checks")
    if not isinstance(checks, list):
        raise ValueError("Correctness checks must be an array")
    ids = set()
    for check in checks:
        if not isinstance(check, dict) or not _text(check.get("id")) or check.get("status") not in STATUSES:
            raise ValueError("Invalid correctness check")
        if check["id"] in ids:
            raise ValueError(f"Duplicate correctness check: {check['id']}")
        ids.add(check["id"])
    for field in METRIC_FIELDS:
        value = result["metrics"].get(field)
        if value is not None and not _number(value, integral=field != "elapsedSeconds"):
            raise ValueError(f"Invalid metric: {field}")
    # Passing results must never conceal missing measurements or failed checks.
    if result["status"] == "passed":
        problems = _eligibility_problems(result)
        if problems:
            raise ValueError("Invalid passing result: " + "; ".join(problems))


def _contract_problems(contract: dict) -> list[str]:
    problems = []
    for field in HASH_FIELDS:
        value = contract.get(field)
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
            problems.append(f"missing or invalid contract.{field}")
    for field in TEXT_FIELDS:
        if not _text(contract.get(field)):
            problems.append(f"missing contract.{field}")
    for field in ("screenWidth", "screenHeight"):
        if not _number(contract.get(field), positive=True):
            problems.append(f"missing or invalid contract.{field}")
    return problems


def _eligibility_problems(result: dict) -> list[str]:
    problems = _contract_problems(result["contract"])
    if result.get("status") != "passed":
        problems.append("task is not passed")
    correctness = result["correctness"]
    if (correctness.get("status") != "passed" or not correctness.get("checks") or
            any(check.get("status") != "passed" for check in correctness["checks"])):
        problems.append("task checks are not all verified")
    tool = result["tool"]
    if not _text(tool.get("version")):
        problems.append("tool version is missing")
    if not isinstance(tool.get("binarySHA256"), str) or re.fullmatch(r"[0-9a-f]{64}", tool["binarySHA256"]) is None:
        problems.append("tool binary hash is missing")
    metrics = result["metrics"]
    for field in METRIC_FIELDS:
        if not _number(metrics.get(field), integral=field != "elapsedSeconds"):
            problems.append(f"metric {field} is missing")
    if metrics.get("tokenStatus") != "measured":
        problems.append("returned text tokens were not measured")
    return problems


def comparison_key(result: dict) -> str:
    """Identify a fixed task/environment contract, independent of tool version."""
    validate_result(result)
    problems = _contract_problems(result["contract"])
    if problems:
        raise ValueError("Incomplete comparison contract: " + "; ".join(problems))
    identity = {"scenario": result["scenario"], "contract": result["contract"]}
    return hashlib.sha256(_json_bytes(identity)).hexdigest()


def read_result(result_path: str | Path) -> dict:
    result = _decode(Path(result_path).read_bytes())
    validate_result(result)
    return result


def compare_results(candidate: dict, baseline: dict) -> dict:
    """Return observable deltas only for successful, contract-matched runs."""
    validate_result(candidate)
    validate_result(baseline)
    differences = []
    if candidate["scenario"] != baseline["scenario"]:
        differences.append({"field": "scenario", "candidate": candidate["scenario"], "baseline": baseline["scenario"]})
    for field in sorted(set(candidate["contract"]) | set(baseline["contract"])):
        left, right = candidate["contract"].get(field), baseline["contract"].get(field)
        if left != right:
            differences.append({"field": "contract." + field, "candidate": left, "baseline": right})
    incomplete = _contract_problems(candidate["contract"]) + _contract_problems(baseline["contract"])
    eligibility = _eligibility_problems(candidate) + _eligibility_problems(baseline)
    matched = not differences and not incomplete
    comparable = matched and not eligibility
    metrics = {}
    if comparable:
        for field in METRIC_FIELDS:
            new, old = candidate["metrics"][field], baseline["metrics"][field]
            metrics[field] = {"candidate": new, "baseline": old, "delta": new - old,
                              "percentDelta": ((new - old) / old * 100) if old != 0 else None}
    return {
        "schema": "axe.agent-benchmark.comparison", "schemaVersion": 1,
        "comparable": comparable, "contractMatches": matched,
        "differences": differences,
        "reasons": sorted(set(eligibility + (["comparison contract differs"] if differences else []))),
        "candidate": {"runId": candidate["runId"], "status": candidate["status"], "tool": candidate["tool"], "metrics": candidate["metrics"]},
        "baseline": {"runId": baseline["runId"], "status": baseline["status"], "tool": baseline["tool"], "metrics": baseline["metrics"]},
        "deltas": metrics,
        "ranking": {"order": list(RANK_FIELDS), "candidateBetter": _rank(candidate) < _rank(baseline)} if comparable else None,
    }


def _rank(result: dict) -> tuple:
    return tuple(result["metrics"][field] for field in RANK_FIELDS)


def _empty_registry() -> dict:
    return {"schema": REGISTRY_SCHEMA, "schemaVersion": 1, "selectionOrder": list(RANK_FIELDS),
            "baselines": {}, "history": []}


def _read_registry(registry_path: Path) -> dict:
    if registry_path.is_symlink():
        raise ValueError("A baseline registry must not be a symlink")
    if not registry_path.exists():
        return _empty_registry()
    registry = _decode(registry_path.read_bytes())
    if (registry.get("schema") != REGISTRY_SCHEMA or registry.get("schemaVersion") != 1 or
            registry.get("selectionOrder") != list(RANK_FIELDS) or
            not isinstance(registry.get("baselines"), dict) or not isinstance(registry.get("history"), list)):
        raise ValueError("Unsupported or invalid baseline registry")
    for key, entry in registry["baselines"].items():
        if not isinstance(entry, dict) or not isinstance(entry.get("result"), dict):
            raise ValueError("Invalid baseline entry")
        result = entry["result"]
        validate_result(result)
        if (result["tool"]["name"] != "axe" or _eligibility_problems(result) or comparison_key(result) != key or
                entry.get("resultContentSHA256") != hashlib.sha256(_json_bytes(result)).hexdigest()):
            raise ValueError("Invalid accepted baseline")
    for event in registry["history"]:
        if (not isinstance(event, dict) or not _text(event.get("runId")) or
                not isinstance(event.get("resultSHA256"), str) or
                re.fullmatch(r"[0-9a-f]{64}", event["resultSHA256"]) is None or
                event.get("key") not in registry["baselines"]):
            raise ValueError("Invalid baseline history")
    return registry


def _atomic_write(file: Path, value: dict) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=file.parent, prefix="." + file.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), 0o600)
            stream.write(_json_bytes(value))
            stream.flush()
            os.fsync(stream.fileno())
        if file.is_symlink():
            raise ValueError("A baseline registry must not be a symlink")
        os.replace(temporary, file)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def accept_baseline(registry_path: str | Path, result_path: str | Path) -> dict:
    """Explicitly submit a proven AXe run; retain the best actual run per cohort."""
    file = Path(result_path).resolve()
    raw = file.read_bytes()
    result = _decode(raw)
    validate_result(result)
    problems = _eligibility_problems(result)
    if result["tool"]["name"] != "axe":
        problems.append("only AXe runs can become its baseline")
    if problems:
        raise ValueError("Baseline not accepted: " + "; ".join(problems))
    key = comparison_key(result)
    result_sha = hashlib.sha256(raw).hexdigest()
    registry_path = Path(registry_path).absolute()
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        stored_path = str(file.relative_to(registry_path.parent.resolve()))
    except ValueError:
        stored_path = str(file)
    lock_path = registry_path.with_name(registry_path.name + ".lock")
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("Invalid registry lock file")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        registry = _read_registry(registry_path)
        for prior in registry["history"]:
            if prior["runId"] == result["runId"]:
                if prior["resultSHA256"] != result_sha:
                    raise ValueError("A previously recorded runId has different result bytes")
                return {"status": "already-recorded", "key": key, "baselineRunId": registry["baselines"][key]["result"]["runId"]}
        previous = registry["baselines"].get(key)
        promoted = previous is None or _rank(result) < _rank(previous["result"])
        entry = {"resultPath": stored_path, "resultSHA256": result_sha,
                 "resultContentSHA256": hashlib.sha256(_json_bytes(result)).hexdigest(), "result": result}
        if promoted:
            registry["baselines"][key] = entry
        event = {"at": datetime.now(timezone.utc).isoformat(), "key": key,
                 "runId": result["runId"], "resultPath": stored_path, "resultSHA256": result_sha,
                 "tool": result["tool"], "scenario": result["scenario"], "metrics": result["metrics"],
                 "promoted": promoted, "rank": list(_rank(result)),
                 "previousBaselineRunId": previous["result"]["runId"] if previous else None}
        registry["history"].append(event)
        _atomic_write(registry_path, registry)
        return {"status": "promoted" if promoted else "kept-best", "key": key,
                "baselineRunId": registry["baselines"][key]["result"]["runId"], "event": event}
    finally:
        os.close(descriptor)


def compare_registry(result: dict, registry_path: str | Path) -> dict:
    """Compare AXe or a competitor to the accepted AXe run for this contract."""
    validate_result(result)
    registry = _read_registry(Path(registry_path))
    try:
        key = comparison_key(result)
    except ValueError as error:
        return {"comparable": False, "reason": str(error), "baseline": None}
    entry = registry["baselines"].get(key)
    if entry is not None:
        return compare_results(result, entry["result"])
    alternatives = []
    for other_key, other in registry["baselines"].items():
        if other["result"]["scenario"] == result["scenario"]:
            comparison = compare_results(result, other["result"])
            alternatives.append({"key": other_key, "runId": other["result"]["runId"],
                                 "differences": comparison["differences"]})
    return {"comparable": False, "reason": "No accepted AXe baseline for this exact contract",
            "key": key, "baseline": None, "otherContracts": alternatives}
