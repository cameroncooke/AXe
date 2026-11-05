---
name: rocketsim-benchmark
description: Use when running the assigned UI benchmark with rocketsim CLI. Drive normal UI controls and inspect public output.
---

# rocketsim benchmark

Use only the assigned CLI for simulator UI reads and input. Use its public help when needed.
Ground each target in normal UI output. You can request more detail, pages or screenshots when needed.
Use normal app controls. Do not read source code, app storage, app defaults, private databases or test hooks
to answer UI assertions. Do not edit the app, change its state outside normal UI actions, or use another
automation tool. Do not replay input with an uncertain outcome. Read the UI before deciding what to do.
Choose your own valid workflow; there is no required action sequence or target call count.
One Bash invocation must contain one CLI invocation. Do not use shell loops, pipes, command substitution,
background jobs or multiple commands to conceal calls. Native public batch commands are allowed.
Use Read for files and Write for batch payloads inside the run directory. Do not change global tool settings.

Use `{{EXECUTABLE}}` and target UDID {{UDID}} on every simulator read/input.
The companion app is prepared by the root. Do not restart it or run doctor for routine navigation.
Read compact output with `elements --agent --agent-mode act --udid {{UDID}}`; nav helps screen-level navigation.
Read the rs/1 envelope and branch on ok. Selectors prefer label plus type; use a returned ID for ambiguity.
Use `interact ... --screen latest --udid {{UDID}}` to anchor to the current server snapshot.
Use public `do --refresh-policy smart --step "..."` for known sequential actions when useful. Its server
refreshes and checks each step. Read interact deltas before choosing whether another observation is needed.
Do not wait for another screen change after every action; wait only for a required app condition.
`interact type` takes positional text, not --text. Toggles expose their value; verify the value changed.
Use public help for exact batch/global option placement, debug mode for missing semantics, and screenshots
when pixels are needed. Do not assume a compact reply contains every fact required by the task.
