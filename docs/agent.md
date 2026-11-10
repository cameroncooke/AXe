# Agentic iOS Simulator automation

## Provider-free agent output

For an external agent that controls AXe one CLI call at a time, use `axe describe-ui --agent --udid "$UDID"`. This flag is separate from the autonomous `axe agent <goal>` command described below and needs no model key.

The default `--view reading` uses compact public adaptive schema 2; `--view navigation` omits static text, and `--view full` exposes the canonical base schema 1. Select text or JSON with the root `--output text|json` option. Compact rows contain `ref|actions|role|label|value`; action names can be comma-separated. IDs and full native text remain available through bounded read-ref queries on the same live-validated snapshot. Neither filtering nor paging changes reference identity or weakens app, display, hinge, rotation and freshness checks.

Use the returned page cursor for omitted controls. A compact display cell is limited to 160 Unicode scalars (159 plus an ellipsis when clipped); fetch an exact `label`, `value` or `id` with `describe-ui --agent --snapshot-id <UUID> --read-ref <REF> --text-field <FIELD>`. Text offsets count Unicode scalars, with chunks of 1...4096 scalars. A scalar boundary can split a combining sequence. `capture.truncatedFields.displayScalarLength` counts the complete normalized display cell; `data.detail.totalLength` counts the exact native field. These counts can differ after whitespace normalization. Use the returned raw-field cursor for chunks. The normal raw hierarchy and coordinate commands remain available without `--agent`.

Compact top-level and batch-step error messages are limited to 1024 Unicode scalars. Clipping keeps a prefix and suffix, with `messageTruncated` and `originalScalarLength` on the error object. Use typed error codes and recovery fields instead of parsing cause strings. Full view keeps the complete message; do not repeat input to expand diagnostics. Native cleanup, quarantine and context checks remain unchanged.

Read the [agent output and readback contract](../Skills/CLI/axe/references/agent-reference.md#output-format) before parsing or acting on these results.

## Autonomous model command

`axe agent` accepts an outcome such as:

```bash
axe agent "Open Settings and turn on Airplane Mode" --udid "$UDID"
```

It observes the frontmost app, asks TypeSafe AI's Jev model for one next action, validates the response and executes that action through AXe.

## How it works

Each run:

1. Read the current accessibility hierarchy and normalise it into an rs/1 runtime snapshot (see below).
2. Build a dynamic action space containing only operations AXe can execute on the current screen.
3. Ask Jev for the next operation and speculative compatible targets in one `/v1/systemone` request.
4. Validate only the target head selected by the operation head. An unused speculative answer cannot cause an action.
5. Re-read the hierarchy while Jev decides and check the decision is still valid (see [Freshness](#freshness)).
6. Execute one action through a cached AXe HID session, then read the screen once for the next request.
7. Repeat until Jev selects `DONE`, `BLOCKED`, or the configured action limit is reached.

No screenshot is sent to TypeSafe. The state consists of compact rs/1 rows, the installed-app candidates relevant to the goal and a short action history.

## rs/1 runtime snapshots

The screen model is a Swift port of XcodeBuildMCP's rs/1 runtime snapshot (`Sources/AXeCore/RuntimeSnapshot.swift`):

- Every accessibility node gets a ref (`e1`, `e2`, ...), a normalised role (`button`, `text-field`, `switch`, `cell`, `scroll-view`, ...) and derived actions (`tap`, `typeText`, `swipeWithin`, ...).
- Elements outside the viewport lose their actions. Activation points near the bottom edge move inside the element, and switches activate near their trailing edge.
- Scroll areas are inferred from containers whose descendants overflow them.
- Jev receives three capped lists of `ref|action|role|label|value|id` rows instead of per-element JSON: up to 64 `targets` in rs/1 priority order, 32 `scroll` areas and 64 visible `text` rows.

```text
e19|tap|button|Add||add-plus-button
e36|swipe|scroll-view|||
e96|text|text|Sunday – 16 Aug 2026||current-day
```

Target questions use refs as choice keys and rows as criteria.

Unlike XcodeBuildMCP's rs/1, the screen hash ignores the traversal order of elements.

## Observation and freshness

A screen read serializes the frontmost application's accessibility hierarchy. It is the main cost of each step, from about 130 ms on a small screen to 400-700 ms on a sheet with the keyboard showing, so the loop keeps reads to two per step:

1. **Post-action read.** After an action, AXe waits 300 ms (a UIKit transition takes about 350 ms) and reads once. Reads reuse the cached frontmost-application handle; acquiring a new one costs 250-700 ms on large screens. A handle whose application lost focus serializes empty and is refreshed automatically, and a screen that looks unchanged is re-read with a new handle in case a system alert took focus. After `OPEN_APP`, AXe reads with new handles until the launched application is frontmost.
2. **Freshness read.** The next Jev request and a second read run concurrently, so the read costs little beyond Jev's own latency. It is compared with the screen Jev saw.

A read that lands mid-transition is caught by the freshness check, which discards the decision and uses the second read as the next observation. Only two stale decisions in a row trigger a full settle: reads until two consecutive screen hashes match, for up to 2.5 seconds. Start-up also settles.

### Freshness

A changed screen hash alone does not discard a decision, because frames of animating or hidden elements change without affecting what Jev saw. The decision is checked in tiers, recorded as `freshness` in the trace:

| Result | When | Operations |
|---|---|---|
| `unchanged` | Screen hash is identical | All |
| `sameCompactRows` | The ref-independent rs/1 rows Jev saw are unchanged. `DONE`, `BLOCKED` and `PRESS_RETURN` also require unchanged target frames, because during a navigation push both screens are in the hierarchy with identical rows. | All |
| `targetResolved` | Only text rows changed, and the chosen element is found again by role and a unique identifier, label or value (rs/1 semantic selector order), or an identical frame. New or removed targets, such as a presenting sheet, make the decision stale. | `TAP`, `TYPE_TEXT`, `CLEAR_TEXT`, `SCROLL_*` |
| `screenIndependent` | The operation does not depend on screen content | `OPEN_APP`, `WAIT`, viewport scrolls with an unchanged viewport |
| `stale` | None of the above; the decision is discarded | All |

Resolved targets execute against the fresh element. If its frame moved, one more read must show the same frame before AXe taps it, so an animating control is not tapped mid-flight.

## Supported operations

The dynamic operation set can contain:

- `OPEN_APP` — launch an installed app in-process through CoreSimulator. A running app is brought to the foreground with its state intact.
- `TAP` — tap a visible accessibility element, including switch-aware activation points.
- `TYPE_TEXT` — focus an editable element, select all and delete any existing value, then enter the text.
- `CLEAR_TEXT` — focus and clear an editable element.
- `PRESS_RETURN` — submit the currently focused field.
- `SCROLL_DOWN` / `SCROLL_UP` — reveal lower or higher content by swiping within an rs/1 scroll area, or the viewport when none is inferred.
- `WAIT` — wait briefly for a real transition or loading state.
- `DONE` — all requested outcomes are visibly satisfied.
- `BLOCKED` — no offered action can progress without guessing.

Target choices are operation-specific. A text field offered to `TYPE_TEXT` cannot accidentally be used as an app-launch target, for example.

## Setup

A TypeSafe API key is required:

```bash
export TYPESAFE_API_KEY=<TYPE_SAFE_API_KEY>
```

Optional TypeSafe settings:

```bash
export TYPESAFE_BASE_URL=https://api.typesafe.ai
export TYPESAFE_MODEL=jev-latest
# TYPESAFE_DEFAULT_MODEL is also supported.
```

The command defaults to `jev-latest` and sends requests to `https://api.typesafe.ai/v1/systemone`.

## Text values

Jev chooses operations and bounded targets; it does not generate arbitrary field content. AXe uses two paths for `TYPE_TEXT`:

1. Literal values explicitly present in the goal, preferably quoted, are reused directly. This keeps common tasks to one TypeSafe request per step.
2. When the value is not explicit, an optional small OpenAI-compatible model receives the original goal, selected field and current screen context. It must return exactly `{"text":"..."}`.

Configure the helper with either the `AXE_`-prefixed or generic environment variables:

```bash
export AXE_TEXT_MODEL_API_KEY=<API_KEY>
export AXE_TEXT_MODEL_BASE_URL=https://api.deepseek.com/v1
export AXE_TEXT_MODEL=deepseek-chat
```

Equivalent names are `TEXT_MODEL_API_KEY`, `TEXT_MODEL_BASE_URL` and `TEXT_MODEL`. When only a key is supplied, the defaults match the Jev ultrafast example: DeepSeek's OpenAI-compatible endpoint and `deepseek-chat`.

Both API keys are sent with every request, so `--base-url`, `TYPESAFE_BASE_URL` and the text-model base URL must use `https`. Plain `http` is accepted only for a server on this Mac (`localhost`, `127.0.0.1` or `::1`).

The executor never invents a missing value. Without an explicit value or configured helper, `TYPE_TEXT` fails before typing.

## Command options

```text
axe agent <goal> --udid <UDID>
  --max-steps <1...200>                 Default: 40
  --model <name>                        Override the Jev model
  --base-url <url>                      Override the TypeSafe API root
  --minimum-action-probability <0...1> Refuse low-probability executable actions
  --trace <path>                        Write the decision trace as JSON
  --json                                Print only the final result as JSON
```

A trace contains request state, model answers, selected actions and entered values. Treat it as potentially sensitive and do not commit it by default.

## Timing

Each progress line shows Jev latency and the whole step, and the run ends with a breakdown. `loop` starts at the first Jev request; `setup` covers listing apps, the first settled observation and opening the TypeSafe connection.

```text
2. TAP → Add [p=0.770, Jev 229 ms, step 1400 ms]
Time: setup 1091 ms, loop 6359 ms (Jev 1241 ms, 10 screen reads 4076 ms, actions 1167 ms)
```

Trace events include per-step `timing`: Jev latency, the freshness read, the action, the post-action observation and the step total.

## Usage and cost

When a run finishes, AXe prints Jev token usage and an estimated cost:

```text
Jev usage: 14 calls, 96812 input tokens, 6104 output tokens, estimated cost $0.004066 (input $0.042 per MTok, output free)
```

The totals come from the `usage` object in each `/v1/systemone` response and include calls whose decisions were discarded as stale, because those requests are still billed. The summary is also printed to stderr when a run fails with an error after at least one Jev call. With `--json`, the same totals appear in the result's `usage` object.

The estimate uses the published [Jev pricing](https://docs.typesafe.ai/models): $0.042 per million input tokens, with output tokens free. It is an estimate, not a billing record. Override the input rate when pricing changes or when using a different model:

```bash
export TYPESAFE_INPUT_USD_PER_MTOK=0.042
```

## Examples

```bash
# Launch and navigate a system app
axe agent "Open Settings, open General, then open About" --udid "$UDID"

# Use an explicit field value without a text-helper request
axe agent "Open Safari and search for 'AXe iOS simulator CLI'" --udid "$UDID"

# Save a machine-readable run and a full decision trace
axe agent "Open Notes and create a note saying 'Buy milk'" \
  --udid "$UDID" \
  --json \
  --trace ./axe-agent-trace.json

# Fail closed unless the selected executable operation has at least 0.65 probability
axe agent "Open Settings and enable Airplane Mode" \
  --udid "$UDID" \
  --minimum-action-probability 0.65
```

## Fail-closed behaviour

Before execution AXe checks that:

- the selected operation and target were actually offered;
- probability keys exactly match the offered choices;
- probabilities and confidence are finite values between zero and one;
- probabilities sum to approximately one;
- the selected choice has the highest probability;
- an optional minimum selected-action probability is met; and
- the decision is still fresh: the screen is unchanged, the rows Jev saw are unchanged, or the chosen target resolves uniquely on the current screen.

Screen text is labelled as untrusted observation in every decision prompt. The original command goal is the only instruction source.

## Current limitations

- The command automates booted iOS Simulators, not physical devices.
- It is accessibility-first and has no screenshot/vision fallback, so canvas-only or poorly labelled interfaces may be blocked.
- rs/1 rows omit frames. Unlabelled scroll areas are indistinguishable to Jev, and targets beyond the 64-row cap are not offered until the screen changes.
- Text entry inherits AXe's current US HID keyboard character support.
- Picker wheels, sliders, drag-and-drop and hardware-button plans are not yet exposed to Jev.
- App launch depends on CoreSimulator's installed-app metadata; hidden services and extensions are filtered but unusual system bundles may still appear.
- Reads reuse the frontmost-application handle between actions, so a system alert that appears while the app's own screen also changes may not be observed until the next refresh.

## Environment summary

| Variable | Purpose | Default |
|---|---|---|
| `TYPESAFE_API_KEY` | Required Jev API key | none |
| `TYPESAFE_BASE_URL` | TypeSafe API root | `https://api.typesafe.ai` |
| `TYPESAFE_MODEL` / `TYPESAFE_DEFAULT_MODEL` | Jev model | `jev-latest` |
| `TYPESAFE_INPUT_USD_PER_MTOK` | Input price used for the cost estimate | `0.042` |
| `AXE_TEXT_MODEL_API_KEY` / `TEXT_MODEL_API_KEY` | Optional text helper key | none |
| `AXE_TEXT_MODEL_BASE_URL` / `TEXT_MODEL_BASE_URL` | Text helper API root | `https://api.deepseek.com/v1` |
| `AXE_TEXT_MODEL` / `TEXT_MODEL` | Text helper model | `deepseek-chat` |
