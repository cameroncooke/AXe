#!/usr/bin/env python3
"""Check public host boundaries without starting a simulator or sending input."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def run_case(output, name, command, expected_exit, expected_text, environment):
    started = time.monotonic()
    child = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment
    )
    try:
        stdout, stderr = child.communicate(timeout=15)
    except BaseException:
        child.kill()
        child.communicate()
        raise
    (output / (name + ".stdout")).write_bytes(stdout)
    (output / (name + ".stderr")).write_bytes(stderr)
    text = (stdout + stderr).decode("utf-8", errors="replace")
    receipt = dict(
        name=name,
        command=command,
        exitCode=child.returncode,
        reaped=child.poll() is not None,
        elapsedSeconds=round(time.monotonic() - started, 6),
        expectedExit=expected_exit,
        expectedText=expected_text,
        passed=child.returncode == expected_exit and expected_text in text,
    )
    (output / (name + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
    if not receipt["passed"]:
        raise AssertionError(name + " did not meet its public boundary contract")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    repository = args.repo.resolve(strict=True)
    cli = args.cli.resolve(strict=True)
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)

    sources = [
        "Package.swift",
        "Sources/AXe/Commands/Tap.swift",
        "Sources/AXe/Commands/Slider.swift",
        "Sources/AXe/Commands/Batch.swift",
        "Sources/AXe/Commands/AgentCommand.swift",
        "Sources/AXe/Utilities/SelectedAXProtocol.swift",
        "Sources/AXe/Utilities/SelectedAXOperation.swift",
        "scripts/build.sh",
    ]
    before = {name: digest(repository / name) for name in sources}
    cli_hash = digest(cli)
    head = subprocess.run(
        ["/usr/bin/git", "-C", str(repository), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True, timeout=10,
    ).stdout.strip()
    environment = dict(os.environ, AXE_ENV_FILE="/dev/null")
    selection = [
        "--input-mode", "selected", "--screen-id", "1",
        "--screen-uuid", "00000000-0000-0000-0000-000000000001",
        "--udid", "00000000-0000-0000-0000-000000000002",
    ]
    cases = []
    try:
        for command in ["tap", "slider", "batch", "agent"]:
            cases.append(run_case(
                output, command + "-help", [str(cli), command, "--help"], 0,
                "USAGE:", environment,
            ))
        for name, options, expected in [
            ("tap-wait-over-cap-rejected", ["--wait-timeout", "31"], "Selected --wait-timeout must be finite and in 0...30 seconds"),
            ("tap-inactive-poll-rejected", ["--poll-interval", "0.5"], "requires a positive --wait-timeout"),
            ("tap-fast-poll-rejected", ["--wait-timeout", "1", "--poll-interval", "0.01"], "Selected --poll-interval must be finite and in 0.05...30 seconds"),
        ]:
            cases.append(run_case(
                output, name,
                [str(cli), "tap", *selection, "--expected-pid", "1", "--id", "missing", *options],
                64, expected, environment,
            ))
        cases.append(run_case(
            output, "coordinate-wait-rejected",
            [str(cli), "tap", *selection, "-x", "1", "-y", "2", "--wait-timeout", "1"],
            64, "do not support polling options", environment,
        ))
        cases.append(run_case(
            output, "slider-value-rejected",
            [str(cli), "slider", *selection, "--expected-pid", "1", "--id", "missing", "--value", "33"],
            64, "--value and polling options are not supported", environment,
        ))
        cases.append(run_case(
            output, "batch-poll-rejected",
            [str(cli), "batch", *selection, "--wait-timeout", "0.1", "--step", "sleep 0"],
            64, "does not use legacy cache, type chunk, tap-style or polling settings", environment,
        ))
        cases.append(run_case(
            output, "agent-selection-rejected",
            [str(cli), "agent", "Find the button", *selection],
            64, "Unknown option '--input-mode'", environment,
        ))
        universal_environment = dict(environment, AXE_BUILD_ARCHS="arm64 x86_64")
        cases.append(run_case(
            output, "universal-build-rejected",
            ["/bin/bash", str(repository / "scripts/build.sh"), "frameworks"],
            1, "Universal release is not admitted", universal_environment,
        ))
        after = {name: digest(repository / name) for name in sources}
        if before != after or cli_hash != digest(cli):
            raise AssertionError("A verification input changed")
        result = dict(
            status="PUBLIC_BOUNDARIES_VERIFIED_GAPS_OPEN", repository=str(repository),
            head=head, cli=str(cli), cliSHA256=cli_hash, sourcePins=before,
            cases=cases, simulatorStarted=False, inputSent=False,
            scope="Host parser/help and architecture guard only; no native feature acceptance",
            securityScan="UNVERIFIED", releaseValidation="NOT_PERFORMED",
        )
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result))
    except BaseException as error:
        (output / "failure.json").write_text(json.dumps(dict(
            error=repr(error), completedCases=cases, head=head, cliSHA256=cli_hash,
        ), indent=2) + "\n")
        raise


if __name__ == "__main__":
    main()
