# Benchmarks

This directory contains the benchmark application: runner, grading, task
rules, tool adapters, token counting, baseline comparison and saved history.
It runs the original Weather, Contacts and Reminders tasks with AXe, FlowDeck
and RocketSim. The model runner and Weather app are included in this repository.
A separate XcodeBuildMCP checkout is not required.

## Commands

From the AXe repository:

```sh
./benchmarks/run setup
# Edit benchmarks/config.local.json for this Mac.
./benchmarks/run doctor
./benchmarks/run
./benchmarks/run history
```

The default run builds the current source, then tests the tools against all
three apps, one job at a time. FlowDeck and RocketSim change only when their
version changes, so a default run reuses their saved history when the current
version already has a measured run for every selected app. It prints a
`reuse-history` line with those run IDs and measures AXe. Name the tools with
`--tools`, or add `--rerun-competitors`, to measure them again. Reports compare
with the saved history and accepted baselines. For a smaller run or repeated
measurements:

```sh
./benchmarks/run --scenarios weather          # AXe; reuses competitors at the same version
./benchmarks/run --rerun-competitors          # measure FlowDeck and RocketSim again
./benchmarks/run --tools axe flowdeck rocketsim --scenarios weather --repeat 3
./benchmarks/run --axe /path/to/release/axe   # measure a specific build instead
./benchmarks/run history --json
./benchmarks/run compare benchmarks/history/RUN_ID/report.json
./benchmarks/run accept benchmarks/history/RUN_ID/report.json
./benchmarks/run test
```

`accept` is explicit. Running a benchmark never replaces a baseline on its own.
Use `./benchmarks/run --help` or `./benchmarks/run run --help` for options.
The entry point also works by absolute path from another working directory.

## Setup

Use Python 3.9 or later, Node.js with npm, Xcode and Claude Code signed in.
The required iOS runtime must be installed. Select an existing booted simulator;
the suite does not create, boot, erase or delete devices. Open and unlock the Mac.
FlowDeck and RocketSim need working licences and their required permissions.

`setup` installs dependencies only under `benchmarks/.venv` and the bundled
runner's `node_modules`. Python requirements and the npm lockfile are retained
in Git. The token counter is tiktoken 0.12.0 with o200k_base. Setup downloads
and caches its encoding before a measured run. No global CLI is installed or
replaced. Setup preserves an existing local configuration.

Edit [config.local.json](config.local.json), created from
[config.example.json](config.example.json):

- Set the Xcode developer directory and exact simulator UUID.
- Set explicit paths to FlowDeck and RocketSim. There is no implicit PATH selection.
- AXe needs no path. Each run builds the current source with `scripts/build.sh`
  and uses that build for the AXe cases and for common preparation. The CLI is
  always rebuilt; the frameworks only when `Packages/IDBKit`, Xcode or the
  architectures changed since their last build, as for `make build`. The exact binary, frameworks and resources are copied to
  `artifacts/RUN-axe/` beside the run's results, so a later build cannot change
  what a report measured. `--axe PATH` measures a given executable instead; keep
  its frameworks beside it. `doctor` checks the current build.
- Record the observed screen size and existing Contacts/Reminders row inventory.
- Enable `allowTestRecordCleanup` only when deletion of those exact benchmark
  records is authorized. The example defaults to false.

The wrapper supplies the bundled model runner and Weather project paths when
these fields are omitted. Optional explicit `xcodebuildmcp` and
`weatherProject` paths can select a different copy; its hash is recorded.
Local paths and record inventories stay in ignored `config.local.json`.

Open RocketSim before its scenarios. The suite checks its public status before
starting a model job. An absent host, unavailable connection or usage quota is a
comparison limit, not a successful performance result. Resolve it outside the
measured job. The suite continues other tools when a case cannot start.

## What goes into source control

| Path | Purpose |
| --- | --- |
| `run`, `cli.py`, `benchmark.py` | Stable commands and serial runner |
| `scoring.py`, `transcript.py` | Task grading and returned-token measurements |
| `adapters.py`, `suite.py`, `guides/` | Equivalent tool modes and model instructions; AXe runs use the shipped skill in `Skills/CLI/axe/` |
| `tasks/`, `shared-rules.md` | Original task requirements and allowed actions |
| `preparation.py`, `environment.py`, `monitor.py`, `processes.py` | Starting-state checks, identity, resource samples and cleanup |
| `baselines.py`, `baselines.json` | Explicit best-baseline selection and accepted results |
| `history.py`, `history/` | Immutable result history and an index |
| `vendor/xcodebuildmcp/` | Pinned model-runner source, dependency lock and provenance |
| `apps/Weather/` | Original app source and Xcode project |
| `test_*.py` | Benchmark application checks |

Ignored local files are `.venv/`, `.cache/`, `config.local.json`,
`artifacts/`, and the vendor's `node_modules/` and `out.nosync/`.
These are dependencies, local settings, transcripts, images and build outputs.
The application code, grading rules, app fixture, reports and baseline registry
are not stored under `build_products`.

## Results and history

Each run creates a unique directory under `benchmarks/artifacts/`. Use
`--output NEW_DIRECTORY` to choose another location. It writes a JSON
`summary.json`, one `report.json` per case, raw evidence and resource samples.
Model build/output files are under the bundled runner's ignored `out.nosync/`.

After the runner exits, reports are automatically copied byte-for-byte into
`benchmarks/history/RUN_ID/report.json`. Passes, failures, unverified results
and blocked cases are retained. Each record has a manifest with the report
hash and external evidence location/hash. `history/index.json` supplies a
machine-readable index. Existing run IDs cannot be overwritten with changed
report bytes. Listing and comparing saved results do not require old build
folders or raw transcripts. Review and commit history changes with the code.

Raw evidence is **not** included in Git history. Keep or archive it separately
when you need screenshots, detailed diagnosis or rescoring. A retained report
is a record of the original checks, not a fresh verification of missing raw
files. Absolute paths inside original reports are preserved as provenance;
portable report links in the registry are relative to `benchmarks/`.

Import an older report or complete suite directory with:

```sh
./benchmarks/run history import /path/to/report.json
./benchmarks/run history import /path/to/suite-directory
```

Successful matching runs compare with AXe's best accepted run: fewest total
calls, then least elapsed time, then fewest text tokens. This is one actual run,
not combined minima. All three costs remain visible. Only a complete passing
AXe result can become its baseline. Acceptance first retains its report in
history. An older valid result stays valid for its original test conditions.

## Fixed conditions and grading

The task files are exact copies of XcodeBuildMCP's original Weather, Contacts
and Reminders prompts. Weather requires seven settings, London and the required
main/detail facts. Contacts requires one exact saved contact. Reminders requires
one list with three exact reminders and their required completion states.
Original save and read-only verification rules remain unchanged.

AXe uses agent reading/navigation/full views. FlowDeck uses compact interactive
JSON and a full view when needed. RocketSim uses its agent modes. AXe runs load
the skill that `axe init` installs, `Skills/CLI/axe/` with its references, so the
benchmark measures what users get; the run prompt tells the agent to run the
assigned binary where the skill writes `axe`. FlowDeck and RocketSim keep generic
guides in `guides/`. Skills and guides contain tool instructions, not app routes
or answers. Reading the installed skill's files counts as a help call. No target
app changes or app-specific production workarounds are part of this suite.

Each result records tool version, binary/runtime hashes, actual model and Claude
version, task/app/guide/runner/grader hashes, Xcode, host OS, device runtime and
screen geometry. Matching conditions are required for ranked comparisons. Tool
versions can differ; changes to the task, runner, grader or environment create a
separate comparison group.

Build, installation and launch calls required by the task remain inside its
clock. Skill activation and approved preparation remain outside it. Each Weather
run uses fresh DerivedData. Model choices vary; use repeated runs before claiming
a stable speed improvement. This suite uses its original tasks and model runner, not a new XcodeBuildMCP tool
comparison.

The grader checks returned UI facts and procedure rules. A zero process exit or
the model's final claim is not proof. Screenshot-only facts remain unverified by
the automatic grader; retain images for human review. Returned text tokens use
o200k_base and exclude image tokens, provider input/cache/thinking usage and
unread files. Image count and bytes are reported separately. This is not a
provider billing total.

## Preparation, resources and interruption

Preparation uses normal UI and waits up to ten seconds for the launched app and
its PID. Authorized cleanup removes only the exact completed benchmark record
after matching fields. Unknown or partial records stop that case. If Contacts
restores an ordinary saved card, use Back, then Home and relaunch outside a run
to save its list position. Do not change the ordinary contact.

One heavy job runs at a time. CPU, process RSS and lock state are sampled.
Identified benchmark processes must finish cleanup before the next case starts.
Normal Ctrl+C/SIGTERM forwards to the owned runner and waits for its cleanup.
If cleanup does not finish within the wrapper's wait, it reports the PID and
retains configuration; check that worker before another run. SIGKILL cannot run
cleanup. Unrelated apps are not stopped.

The model keeps normal permissions. A narrow PNG rule supports stdout screenshot
capture only within its assigned run directory. It does not grant general file
write access.

Stdout is JSON for run, doctor, compare and accept. Progress and automatic history
receipts go to stderr. `history` prints a table by default; add `--json` to parse it.
Run exits 0 only if every selected case passes, 1 for failed/blocked/unverified
cases, and 2 for configuration errors. Normal interruption uses 130 or 143.

## Verification and rescoring

`./benchmarks/run test` runs the benchmark application's offline checks. Use
`AXE_PROCESS_HELPER_TEST=1 ./benchmarks/run test` to include the short-lived
Python process cleanup check. These checks do not replace a real simulator run.

To apply the grader to retained raw evidence without replaying input:

```sh
benchmarks/.venv/bin/python benchmarks/rescore.py /path/to/report.json \
  --output /path/to/new-rescored-report.json
```

Rescoring requires original raw evidence, verifies its hashes and preserves
original measurements. If the evidence has moved since the run, pass its new
directory with `--evidence /path/to/evidence`; the same hash checks apply. It
creates a new report and comparison group. It cannot repair incomplete
execution. Import the new report into history explicitly.
