# Repeatable agent benchmarks — 5 November 2026

The [repository suite](../../benchmarks/README.md) runs the original
Weather, Reminders and Contacts tasks with AXe, FlowDeck and RocketSim. It uses
the existing XcodeBuildMCP model runner. It separates task correctness from
process completion and cost. The installed AXe CLI was not changed.

## Permanent benchmark application

The application now lives under `benchmarks/`, including the runner, task and
grading logic, tool adapters, token counter integration, baseline selection and
history manager. The model-runner source and its pinned npm dependencies are
vendored locally with license and provenance. The original Weather app and Xcode
project are included without source changes; the copied app hash matches the
original. A separate XcodeBuildMCP checkout is no longer required.

From the repository, run:

```sh
./benchmarks/run setup
./benchmarks/run doctor
./benchmarks/run
./benchmarks/run history
```

Local setup is already configured on this Mac. Use
`./benchmarks/run --tools axe --scenarios weather` for one task and
`./benchmarks/run compare benchmarks/history/RUN_ID/report.json` for a saved
comparison. The [README](../../benchmarks/README.md) explains all commands.

Reports are retained byte-for-byte under `benchmarks/history/`; accepted
baseline paths are portable. Fifteen prior selected/accepted reports were
migrated with unchanged hashes. Their original contracts and results remain
intact. No old run is relabelled as a pass from the newly packaged runner.
Future reports are retained automatically after each suite process exits.
Large raw evidence, dependencies and machine-specific settings remain ignored.
The former dated `build_products` launcher is no longer the supported entry point.

The permanent commands passed all 171 application checks. A real run through
`./benchmarks/run --tools axe --scenarios weather` passed all task checks with
19 calls / 226.68 seconds / 7,668 text tokens and no errors or images. It saved
one parseable stdout JSON result and retained its report automatically. Explicit
acceptance and comparison used the retained report. All owned workers exited;
the globally installed AXe hash remained unchanged. This packaging proof is a
new comparison group because the local harness and complete source hash changed.
It does not replace or alter the earlier 16-call Weather result. See
[packaging verification](../../benchmarks/verification.json) and
[retained report](../../benchmarks/history/axe-bench-weather-axe-402988b378f6/report.json).

## Versions tested

| Tool | Version | Identity |
| --- | --- | --- |
| AXe | v1.8.0-185-g76e83a4b-dirty | Private accepted wire-83 executable; SHA-256 eead5e0172c289657bb9fa7891c8505cfdc367af5300390521be88a577ab51a0 |
| FlowDeck | 1.34.0, build 815522 | SHA-256 45d8f09ce59ec816424cc2d8762a4da4d9343cb2885abdc0e6d7168791917fd6 |
| RocketSim | 16.8.0, build 339 | Bundled CLI SHA-256 a3452ce017bff17225d2fbdd8e068c8155ecbf333f636c9421b01506d7d189bc |

Every run records its own versions and hashes. AXe records adjacent runtime
files. RocketSim records both the companion app and bundled CLI. Tool versions
can change without changing the task contract.

The measured environment was Claude Code 2.1.281 with claude-opus-4-7, a warm
iPhone 18 Pro at 402 × 874 points, iOS 27.2 (24B5110a), Xcode 27.2
(27B5038j), and macOS 26.6.2 (25G83) on arm64. No simulator was created or erased.

## Final runner results

| Task | Tool | Status | Calls | Seconds | Returned text tokens | Images |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Weather | AXe | Passed | 16 | 205.87 | 7,182 | 0 |
| Weather | RocketSim | Passed | 37 | 197.23 | 17,122 | 0 |
| Weather | FlowDeck | Unverified: task facts passed, command rules did not | 98 | 772.03 | 47,705 | 9 |
| Contacts | AXe | Passed | 12 | 167.79 | 8,954 | 0 |
| Contacts | FlowDeck | Unverified: screenshot evidence | 41 | 252.73 | 4,364 | 9 |
| Contacts | RocketSim | Unverified: service/quota failures | 78 | 513.37 | 14,873 | 0 |
| Reminders | AXe | Passed | 23 | 312.09 | 10,018 | 0 |
| Reminders | FlowDeck | Unverified: screenshot evidence | 65 | 420.13 | 6,662 | 17 |
| Reminders | RocketSim | Blocked before measurement; retry limited by quota | — | — | — | — |

All three AXe tasks passed with the final runner and were accepted as current
baselines. The earlier Contacts pass used 11 calls / 144.11 s / 8,431 tokens
under an older runner contract; it remains recorded in that group.
RocketSim Contacts did not complete a valid run. Its agent quota reached 3/3;
Reminders was not retried after that refusal. These are comparison limits, not
successful competitor scores.

The Weather AXe/RocketSim pair has matching comparison conditions. AXe used
21 fewer calls and 9,940 fewer text tokens, but took 8.64 seconds longer in this
single pair. These trials do not establish a stable speed difference. FlowDeck
Weather supplied all 17 facts but used commands outside the allowed surface,
including a pipe. It is excluded from successful-task ranking.

FlowDeck Reminders returned empty application nodes in its two structured reads.
The final screenshot visibly shows the correct list and three required states.
The automatic scorer cannot prove its creation and read-only verification steps
from image presence or coordinate actions alone. No command-rule violation was
recorded. Its 6,662 text tokens exclude the 17 images (2,936,389 bytes).

FlowDeck Contacts also used screenshots after empty structured reads. Manual
review of the editor and saved card confirmed the required name, organization,
phone and email. Only screenshot/read calls followed Save. Its automatic status
remains unverified; 4,364 text tokens exclude nine images (2,078,087 bytes).

AXe Reminders recovered from five errors: a changed screen before input, partial
typing, input setup failure before input, one accessibility read timeout, and a
batch stopped after the first completion moved the remaining row. The agent
read current state and continued. The trace does not establish the root cause
of each native-service error. An earlier accepted run used 20 calls / 195.36 s /
8,591 tokens under an older runner contract. Both remain recorded; no speed
improvement is claimed.

## Measurement and baseline rules

- Original task files are exact copies of the XcodeBuildMCP prompts. Task, app
  source, shared rules, guides, harness, runner and scorer hashes are recorded.
- Original build, installation and launch calls remain inside the task clock.
  Skill activation and approved initial cleanup remain outside it. Each Weather
  run gets a new DerivedData directory.
- Total calls, UI calls, setup calls, help calls, errors, elapsed time, returned
  text tokens and image bytes are separate fields. Text uses o200k_base with
  tiktoken 0.12.0. This is not a provider billing total.
- The best baseline is one successful AXe run: fewest calls, then lowest time,
  then fewest text tokens. The suite does not combine minima from separate runs.
- Comparison requires matching task and environment conditions. Runner or scorer
  changes create separate groups. Older valid passes remain valid in their own
  groups. Failed isolated runs are not accepted-build regressions.
- Rescoring verifies archived evidence hashes and retains original measurements.
  It does not rerun input or convert a model's completion claim into proof.

The historical XcodeBuildMCP 14-call / approximately 100-second result remains a
reference. Its full conditions are unavailable. This suite uses its runner and
tasks; it does not claim a newly measured XcodeBuildMCP tool result.

## Verification and recovery

All 139 suite checks passed, including the optional local process cleanup
check. Separate live checks proved cancellation cleanup and a RocketSim PNG
capture/read through the scoped permission rule. All three guide syntax checks
passed. The external security scan remains unverified as Cam requested.

One heavy job ran at a time. CPU, process RSS and lock state were sampled.
Cancellation tracks only identified benchmark processes, including detached
workers, and verifies PID start time before signalling them. Cleanup must
complete before the next case starts. Unrelated processes are not stopped.
The final measured jobs recorded 562 samples, no locked or missed samples, and
a maximum observed process RSS of 974,553,088 bytes (0.91 GiB). CPU peaked at
246.7% for one process across cores. All eight measured-job cleanup receipts
were complete, and the final process check found no benchmark worker.

Contacts restored an ordinary saved card during preparation. Back, then Home,
then termination and relaunch preserved the six original contact rows. This
normal navigation changed no contact data. The preparation helper still stops
on unknown or partial records; it deletes only the exact approved benchmark
records after their fields match.

Earlier runner failures remain in the evidence: one missed resource sample,
a detached worker, absent RocketSim host, and screenshot permission refusal.
Those were corrected or excluded before the current comparison. A frozen audit
simulator was recovered with normal Lock, Home and unlock controls, without
restart or erase. RocketSim quota exhaustion was not bypassed.

The source-binding check compared 858 accepted files. The only difference was
the intentional benchmark changelog entry; 857 accepted source files matched.
The installed CLI SHA-256 remains
`0b6617829414cb990654421d7dca3ea4b1e0602d260bc8e000f7b62f16e519aa`.
No production AXe code, target app, installed CLI, published release or remote
branch changed in this task.

## Evidence

Local evidence root:
`build_products/verification/repeatable-agent-benchmark-20261105/`.

- `release-suite/`: final runner Weather trials and RocketSim limit.
- `rescored-uniform-final/`: current scorer applied to immutable saved trials.
- `remaining-suite/`: final AXe and FlowDeck Reminders trials.
- `contacts-final/`: Contacts retry after normal navigation recovery.
- `current-weather-comparison.json`: strict AXe/RocketSim comparison.
- `final-comparison.json`: compact machine-readable nine-case summary.
- `final-resource-cleanup-summary.json`: resource maxima and cleanup receipts.
- `suite-validation.json`: commands, results, original-task hashes and check paths.
- `offline-tests-final.log`: offline checks (138 passed, one opt-in skip).
- `offline-tests-with-process-proof.log`: all 139 checks passed, no skips.
- `screenshot-permission-proof.json` and `cancellation-proof/`: live runner checks.
