---
name: axe-cli
description: Provides agent-ready AXe CLI usage guidance for iOS Simulator automation. Use when asked to "use AXe", "automate a simulator", "tap/swipe/type on simulator", "describe UI", "take a screenshot", "record video", "batch steps", or "interact with an iOS app". Covers all commands including touch, gestures, text input, keyboard, buttons, accessibility, screenshots, video, and batch workflows.
---

## Step 1: Confirm runtime context
1. Identify simulator UDID target first (`axe list-simulators`).
2. Every AXe command requires `--udid <UDID>`.
3. Prefer resilient selectors (`tap --id` / `tap --label`) over raw coordinates where possible.

## Step 2: Choose the right command

Read `<skill-directory>/references/cli-quick-reference.md` for the full command list, flags, and examples.

| Need | Command |
|---|---|
| Tap at coordinates | `axe tap -x <X> -y <Y>` |
| Tap by accessibility element | `axe tap --id <identifier>` or `axe tap --label <text>` |
| Swipe gesture | `axe swipe --start-x ... --end-x ...` |
| Scroll / edge swipe preset | `axe gesture <preset-name>` |
| Low-level touch down/up | `axe touch -x <X> -y <Y> --down --up` |
| Type text | `axe type 'text'` or `echo "text" \| axe type --stdin` |
| Press a key by keycode | `axe key <keycode>` |
| Key sequence | `axe key-sequence --keycodes <codes>` |
| Modifier+key combo | `axe key-combo --modifiers <mod> --key <key>` |
| Hardware button | `axe button <name>` |
| Multi-step workflow | `axe batch --step "..." --step "..."` |
| Inspect UI tree | `axe describe-ui` |
| Capture screenshot | `axe screenshot` |
| Record video | `axe record-video` |
| Stream video | `axe stream-video` |
| List simulators | `axe list-simulators` |

## Step 3: Apply timing and input best practices
- Use `--pre-delay` / `--post-delay` on tap, swipe, and gesture commands when waiting is needed.
- Use `--duration` to control how long a swipe, gesture, button press, or key press lasts.
- For text with shell-sensitive characters, prefer `--stdin` or `--file` over inline quotes.
- Use single quotes for inline text arguments to avoid shell expansion issues.

## Step 4: Batch vs discrete commands

**Prefer `axe batch`** when all interactions are known in advance and the UI state between steps is predictable. Batch executes every step in a single process invocation, which means:
- One tool call and one AI turn instead of many — significantly reduces agent latency and cost.
- A single HID session is reused across all steps, lowering per-step overhead.

**Fall back to discrete commands** when:
- A step's parameters depend on the result of a previous step (e.g. reading `describe-ui` output to decide where to tap next).
- An interaction triggers an animation, network load, or navigation that must complete before the next step can succeed — batch has **no element-waiting or retry logic**; selector taps (`--id` / `--label`) query the accessibility tree once and fail immediately if the element is not present.

**Handling animations and transitions in batch:**
- Insert explicit `sleep <seconds>` steps to wait for animations or screen transitions to settle.
- Use `--ax-cache perStep` (instead of the default `perBatch`) so each selector tap gets a fresh accessibility snapshot, which is important when the UI changes between steps.
- When timing is uncertain, prefer discrete commands with `describe-ui` checks between them.

Read `<skill-directory>/references/batch-reference.md` for complete batch argument semantics and examples.

Key rules:
- Use exactly one step source per run: `--step`, `--file`, or `--stdin`.
- Steps run in order; default is fail-fast.
- Add `--continue-on-error` for best-effort execution.
- Do not pass `--udid` inside step lines; keep it at batch level.

## Step 5: Verify outcomes
Batch and individual commands are execution-focused, not assertion-focused. Always suggest verification when outcomes matter:

```bash
axe describe-ui --udid <UDID>
# or
axe screenshot --udid <UDID> --output post-state.png
```

## Step 6: Exit criteria
Before finalising guidance, verify:
- Every command includes `--udid`.
- Only valid AXe commands and flags are used.
- Shell quoting is correct (single quotes for literals, `--stdin`/`--file` for complex text).
- Verification is suggested as a separate step when results matter.
