---
name: flowdeck-benchmark
description: Use when running the assigned UI benchmark with flowdeck CLI. Drive normal UI controls and inspect public output.
---

# flowdeck benchmark

Use only the assigned CLI for simulator UI reads and input. Use its public help when needed.
Ground each target in normal UI output. You can request more detail, pages or screenshots when needed.
Use normal app controls. Do not read source code, app storage, app defaults, private databases or test hooks
to answer UI assertions. Do not edit the app, change its state outside normal UI actions, or use another
automation tool. Do not replay input with an uncertain outcome. Read the UI before deciding what to do.
Choose your own valid workflow; there is no required action sequence or target call count.
One Bash invocation must contain one CLI invocation. Do not use shell loops, pipes, command substitution,
background jobs or multiple commands to conceal calls. Native public batch commands are allowed.
Use Read for files and Write for batch payloads inside the run directory. Do not change global tool settings.

Use `{{EXECUTABLE}}`. The app and license are already prepared.
Use the `ui simulator` commands for UI reads and input. Discover current options through public --help
if needed. Select the assigned simulator {{UDID}} explicitly with --simulator; never change
saved configuration. Use the current compact/interactive agent output when it preserves the information
needed for the next action. Request more detail or a screenshot when the compact output is insufficient.
For control discovery, use `ui simulator screen --json --interactive-elements --simulator {{UDID}}`.
For visible text and task facts, omit `--interactive-elements` to read the complete hierarchy.
`--optimize` changes screenshots, not the hierarchy output.
Use returned node identifiers or unique public selectors. Treat cached nodes as snapshot-bound and follow
the tool's stale-reference recovery instructions. Use `ui simulator batch` when useful; separate CLI calls
stay separate calls. Build/install/launch use the common Apple commands
from the benchmark task context so setup is measured on the same boundary across CLI tools.
Do not run FlowDeck config set/reset, update, tool installation, simulator lifecycle or license commands during this benchmark.
