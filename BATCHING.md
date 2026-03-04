# AXe Batch Guide

This guide explains `axe batch` in simple, behavior-first terms.

## What `axe batch` does

`axe batch` runs multiple interaction steps in order in a single command.

Why this matters:
- Lower overhead than launching a new AXe process for every step.
- Better latency for automation flows.
- Easier scripting for multi-step interactions.

## Quick example

```bash
axe batch --udid SIMULATOR_UDID \
  --step "tap --id SearchField" \
  --step "type 'hello world'" \
  --step "key 40"
```

What this does:
1. Taps the element with accessibility id `SearchField`.
2. Types `hello world`.
3. Presses keycode `40` (Enter/Return).

## Supported step commands

You can use these inside `--step` lines or step files:
- `tap`
- `swipe`
- `gesture`
- `touch`
- `type`
- `button`
- `key`
- `key-sequence`
- `key-combo`

Batch-only pseudo-step:
- `sleep <seconds>`

Example:
```bash
axe batch --udid SIMULATOR_UDID \
  --step "tap -x 180 -y 360" \
  --step "sleep 0.5" \
  --step "tap -x 220 -y 420"
```

## Input source rules

Batch accepts exactly one input source per run:
- `--step` (repeatable inline steps)
- `--file` (one step per line)
- `--stdin` (one step per line)

If you combine sources in one command, batch fails validation.

## Arguments and behavior

### `--udid <udid>`
Required. The simulator to target.

### `--step "..."`
Adds one step inline. Repeat for multiple steps.

Example:
```bash
--step "tap --id LoginButton" --step "type 'cam@example.com'"
```

### `--file <path>`
Reads steps from a file (one step per line).

Rules:
- Empty lines are ignored.
- Lines that start with `#` are treated as comments.

Example file:
```text
# login flow
tap --id EmailField
type 'cam@example.com'
key 43
type 'super-secret'
key 40
```

### `--stdin`
Reads steps from stdin (one step per line).

Example:
```bash
cat steps.txt | axe batch --stdin --udid SIMULATOR_UDID
```

### `--ax-cache <perBatch|perStep|none>`
Controls how accessibility snapshots are reused for selector-based taps (`tap --id` / `tap --label`).

- `perBatch` (default): fetch once, reuse during the whole batch.
  - Fastest.
- `perStep`: fetch again for each selector step.
  - Better if UI changes a lot between steps.
- `none`: same behavior as per-step (no cache kept).

### `--type-submission <chunked|composite>`
Controls how `type` events are submitted.

- `chunked` (default): splits typing HID events into chunks.
  - Safer for very long text.
- `composite`: sends all typing HID events together.
  - Fewer submissions, can be faster for moderate text sizes.

### `--type-chunk-size <n>`
Used when `--type-submission chunked`.

Default: `200`

Larger value:
- fewer submissions
- potentially faster

Smaller value:
- more submissions
- potentially more stable for very large text payloads

### `--wait-timeout <seconds>`
Maximum time to poll for selector-based elements (`tap --id` / `tap --label`) before failing.

Default: `0` (no waiting — fail immediately if the element is not found).

When set to a positive value, batch polls the accessibility tree at regular intervals until the element appears or the timeout expires. This is useful for multi-screen flows where a tap triggers navigation and the next tap targets an element on the new screen.

Example:
```bash
axe batch --udid SIMULATOR_UDID --wait-timeout 5 \
  --step "tap --id LoginButton" \
  --step "tap --id WelcomeMessage"
```

The second step polls for up to 5 seconds for `WelcomeMessage` to appear after the login tap triggers navigation.

Only `.notFound` errors are retried. If the selector matches multiple elements or the matched element has an invalid frame, the step fails immediately without retrying.

### `--poll-interval <seconds>`
How frequently the accessibility tree is re-fetched when `--wait-timeout` is active.

Default: `0.25`

Lower values poll more aggressively (faster detection, more overhead). Higher values reduce overhead but increase detection latency.

### `--verbose`
Enables detailed stderr logging for troubleshooting.

Default: disabled (quiet output, success/failure summary only).

Use this when debugging selector resolution, setup, or retries.

### `--continue-on-error`
Controls failure policy.

Default behavior (without this flag):
- Fail fast.
- Batch stops at first failing step.

With this flag:
- Batch keeps running later steps even if one step fails.
- At the end, it reports all failed steps.

Use carefully, because later steps might run in an unexpected UI state.

## Step-level options

Each step command keeps its normal options and validation.

Examples:
- `tap --id BackButton`
- `tap -x 200 -y 400 --pre-delay 0.2 --post-delay 0.2`
- `gesture scroll-down --duration 1.0`
- `touch -x 150 -y 300 --down --up --delay 1.0`

One important rule:
- Do not include `--udid` inside a step. Use the batch-level `--udid` only.

## Verification strategy

Batch is execution-focused. It does not do built-in assertions.

Recommended pattern:
1. Run `axe batch ...`
2. Verify with `axe describe-ui ...` or `axe screenshot ...`

## Real-world example: login flow

```bash
axe batch --udid SIMULATOR_UDID --file login.steps
```

`login.steps`:
```text
tap --id EmailField
type 'cam@example.com'
key 43
type 'super-secret'
key 40
```

Then verify:
```bash
axe describe-ui --udid SIMULATOR_UDID > post-login-ui.json
```

## Real-world example: navigation flow

```bash
axe batch --udid SIMULATOR_UDID \
  --step "gesture scroll-down" \
  --step "tap --label Settings" \
  --step "sleep 0.5" \
  --step "tap --id SaveButton"
```

## Real-world example: multi-screen flow with element waiting

```bash
axe batch --udid SIMULATOR_UDID --wait-timeout 5 \
  --step "tap --id LoginButton" \
  --step "tap --id DashboardTitle" \
  --step "tap --label Profile"
```

Each selector tap polls for up to 5 seconds, so if `LoginButton` triggers a screen transition, `DashboardTitle` will be found once the new screen loads.

## Troubleshooting

- Error: multiple input sources
  - Use only one of: `--step`, `--file`, or `--stdin`.

- Error: no element matched in `tap --id` / `tap --label`
  - Confirm current screen.
  - Run `axe describe-ui --udid ...` to refresh selectors.
  - Use `--wait-timeout <seconds>` if the element appears after a previous step triggers navigation.
  - Consider `--ax-cache perStep` if your UI changes between steps.

- Error: multiple elements matched for `--label`
  - Labels are not guaranteed to be unique.
  - AXe prefers actionable matches first (for example, `Button`) when a label is shared with read-only text, but it still fails if multiple actionable matches remain.
  - Prefer `--id` when available.
  - If AXe reports that none of the matches expose `AXUniqueId`, use coordinate taps (`tap -x/-y`) for that step.

- Output is too noisy
  - Keep default quiet mode for normal runs.
  - Add `--verbose` only when you need troubleshooting details.

- Steps succeed but final state is wrong
  - Add `sleep` between navigation-heavy steps.
  - Verify after batch with `describe-ui` / `screenshot`.
  - Avoid `--continue-on-error` unless you really want best-effort execution.
