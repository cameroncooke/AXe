---
name: axe
description: Provides agent-ready AXe CLI usage guidance for iOS Simulator automation. Use when asked to "use AXe", "automate a simulator", "tap/swipe/type on simulator", "set a slider", "describe UI", "take a screenshot", "record video", "batch steps", or "interact with an iOS app". Covers all commands including touch, gestures, sliders, text input, keyboard, buttons, accessibility, screenshots, video, and batch workflows.
---

## Step 1: Confirm runtime context
1. Identify simulator UDID target first (`axe list-simulators`).
2. Simulator-interaction AXe commands require `--udid <UDID>`. Commands like `list-simulators` and `init` do not.
3. Run `axe describe-ui --udid <UDID>` to inspect the full current screen. Use `axe describe-ui --point <X,Y> --udid <UDID>` to inspect the element at a specific coordinate. Use the output to discover available `--id` and `--label` values for selector taps and slider setting, and to confirm coordinates for coordinate-based taps.
4. Prefer selectors (`tap --id` / `tap --label`, `slider --id` / `slider --label`) over raw coordinates. Selectors are resilient to layout changes, work across device sizes, and support element waiting where documented. For UIKit `UISwitch` and SwiftUI `Toggle` rows, selector taps activate the contained switch/toggle when the match contains exactly one such control. Default tap style is `automatic`: switches/toggles use physical touch down/up, while normal taps use simulator `tapAt`.

## Step 2: Choose the right command

Available commands: `init`, `tap`, `slider`, `swipe`, `drag`, `gesture`, `touch`, `type`, `button`, `key`, `key-sequence`, `key-combo`, `batch`, `describe-ui`, `screenshot`, `record-video`, `stream-video`, `list-simulators`. Run `axe --help` or `axe <command> --help` for full options.

Common examples:
```bash
axe tap --id <identifier> --udid <UDID>
axe tap --label <text> --udid <UDID>
axe tap --label 'Weather Alerts' --udid <UDID>
axe slider --id <identifier> --value 75 --udid <UDID>
axe slider --label <text> --value 40 --element-type Slider --udid <UDID>
axe drag --start-x <X1> --start-y <Y1> --end-x <X2> --end-y <Y2> --udid <UDID>
axe tap -x <X> -y <Y> --tap-style physical --udid <UDID>
axe tap -x <X> -y <Y> --udid <UDID>
axe type 'text' --udid <UDID>
axe describe-ui --udid <UDID>
axe describe-ui --point <X,Y> --udid <UDID>
axe screenshot --udid <UDID> --output screenshot.png
```

## Step 3: Understand the execution model

Most HID commands (`tap`, `swipe`, `drag`, `type`, `key`, etc.) are fire-and-forget — AXe confirms the event was dispatched to the simulator but cannot verify the app actually processed it. A tap may land before a view is interactive, or during a transition. `slider` is the exception: it performs one selector-resolved low-level HID drag, re-reads the matched slider AXValue, and fails if the observed 0-100 value is outside tolerance. iOS slider controls quantize values to their rendered track resolution, so AXe does not retry correction gestures to chase unreachable decimals. This means:
- Always verify outcomes separately with `describe-ui` or `screenshot` when app behavior matters beyond the direct command result.
- Use `--wait-timeout` in batch to wait for tap elements to appear, and `sleep` steps or `--pre-delay` / `--post-delay` to allow animations to settle.

## Step 4: Apply timing and input best practices
- Use `--pre-delay` / `--post-delay` on tap, swipe, and gesture commands for fixed delays around actions.
- Use `--duration` to control how long a swipe, gesture, button press, or key press lasts.
- Coordinate-based `tap`, `swipe`, `drag`, and `touch` accept coordinates from `describe-ui` directly; AXe detects rotated landscape simulator orientation and letterboxed landscape-only app layouts automatically.
- Use `axe slider --id <identifier> --value <0-100>` for sliders instead of approximating with raw swipe coordinates; it uses one calibrated low-level HID drag from the resolved slider frame/current AXValue, through the same composite touch-move path as `drag`, verifies the result within tolerance, and fails clearly if the observed AXValue remains outside tolerance.
- For text with shell-sensitive characters, prefer `--stdin` or `--file` over inline quotes.
- Use single quotes for inline text arguments to avoid shell expansion issues.

## Step 5: Batch vs discrete commands

**Prefer `axe batch`** for multi-step flows. Batch executes every step in a single process invocation, which means:
- One tool call and one AI turn instead of many — significantly reduces agent latency and cost.
- A single HID session is reused across all steps, lowering per-step overhead.
- Steps execute sequentially — each step runs before the next is resolved, so earlier taps can trigger navigation and later selector taps will find newly appeared elements (with `--wait-timeout`).

**Fall back to discrete commands** when:
- A step's parameters depend on runtime inspection of a previous step's result (e.g. parsing `describe-ui` JSON to choose coordinates dynamically).
- Using `slider`; batch steps do not support slider verification.

**Handling animations and transitions in batch:**
- Use `--wait-timeout <seconds>` so selector taps (`--id` / `--label`) poll the accessibility tree until the element appears or the timeout expires. This is the primary mechanism for multi-screen flows.
- Use `--poll-interval <seconds>` to control polling frequency during waiting (default 0.25s).
- Use `--ax-cache perStep` when *not* using `--wait-timeout` but the UI still changes between steps — this ensures each selector tap gets a fresh accessibility snapshot rather than a stale cached one.
- Insert explicit `sleep <seconds>` steps when coordinate-based taps need the UI to be stable (selectors with `--wait-timeout` are preferred over sleep where possible).
- Keep batch output quiet by default. Add `--verbose` only when troubleshooting.
- Selector taps in batch share direct `tap` semantics, including switch/toggle activation-point handling and `--tap-style automatic` behavior. Use batch-level `--tap-style physical|simulator` as the default for tap steps, or step-level `tap --tap-style ...` to override one step.
- If `tap --label` reports multiple matches and no `AXUniqueId` values are exposed, fall back to `tap -x/-y` for that step.

Key rules:
- Use exactly one step source per run: `--step`, `--file`, or `--stdin`.
- Steps run in order; default is fail-fast.
- Add `--continue-on-error` for best-effort execution.
- Do not pass `--udid` inside step lines; keep it at batch level.

## Step 6: Verify outcomes
Batch and individual commands are execution-focused, not assertion-focused. Always suggest verification when outcomes matter:

```bash
axe describe-ui --udid <UDID>
axe describe-ui --point <X,Y> --udid <UDID>
# or
axe screenshot --udid <UDID> --output post-state.png
```

## Step 7: Exit criteria
Before finalising guidance, verify:
- Every command includes `--udid`.
- Only valid AXe commands and flags are used.
- Shell quoting is correct (single quotes for literals, `--stdin`/`--file` for complex text).
- Verification is suggested as a separate step when results matter.
