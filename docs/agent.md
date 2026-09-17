# Agentic iOS Simulator automation

`axe agent` accepts an outcome such as:

```bash
axe agent "Open Settings and turn on Airplane Mode" --udid "$UDID"
```

It observes the frontmost app, asks TypeSafe AI's Jev model for one next action, validates the response and executes that action through AXe. This is deliberately an agent loop over AXe's existing accessibility and HID primitives rather than a separate automation stack.

## Why this shape

The design adapts the `browser-use/jev-ultrafast` pattern to iOS:

1. Read the current accessibility hierarchy and reduce it to a compact, indexed set of visible controls.
2. Build a dynamic action space containing only operations AXe can execute on the current screen.
3. Ask Jev for the next operation and speculative compatible targets in one `/v1/systemone` request.
4. Validate only the target head selected by the operation head. An unused speculative answer cannot cause an action.
5. Re-read the hierarchy before acting. If its fingerprint changed while the request was in flight, discard the decision.
6. Execute one action through a cached AXe HID session and poll briefly for an observable state change.
7. Repeat until Jev selects `DONE`, `BLOCKED`, or the configured action limit is reached.

No screenshot is sent to TypeSafe. The state consists of accessibility labels, values, roles, frames, the installed-app candidates relevant to the goal and a short action history.

## Supported operations

The dynamic operation set can contain:

- `OPEN_APP` — launch an installed app with `simctl launch --terminate-running-process`.
- `TAP` — tap a visible accessibility element, including switch-aware activation points.
- `TYPE_TEXT` — focus an editable element, select all, delete and enter replacement text.
- `CLEAR_TEXT` — focus and clear an editable element.
- `PRESS_RETURN` — submit the currently focused field.
- `SCROLL_DOWN` / `SCROLL_UP` — reveal lower or higher content.
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

## Performance choices

- Accessibility trees replace screenshot capture, image upload and vision inference.
- Jev chooses the operation and speculative compatible targets in one request.
- Exact app-name matches and single available targets are resolved deterministically, avoiding unnecessary target questions.
- AXe retains one HID session for the complete run.
- Post-action observation uses short adaptive polling and returns on the first changed hierarchy.
- State is capped at 160 actionable elements and 8,000 characters of visible text.

## Fail-closed behaviour

Before execution AXe checks that:

- the selected operation and target were actually offered;
- probability keys exactly match the offered choices;
- probabilities and confidence are finite values between zero and one;
- probabilities sum to approximately one;
- the selected choice has the highest probability;
- an optional minimum selected-action probability is met; and
- the screen fingerprint is unchanged since it was observed for the model request.

Screen text is labelled as untrusted observation in every decision prompt. The original command goal is the only instruction source.

## Current limitations

- The command automates booted iOS Simulators, not physical devices.
- It is accessibility-first and has no screenshot/vision fallback, so canvas-only or poorly labelled interfaces may be blocked.
- Text entry inherits AXe's current US HID keyboard character support.
- Picker wheels, sliders, drag-and-drop and hardware-button plans are not yet exposed to Jev.
- App launch depends on `simctl listapps` metadata; hidden services and extensions are filtered but unusual system bundles may still appear.
- The integration needs simulator E2E coverage under AXe's supported Xcode 26 and Xcode 27 environments before release.

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
