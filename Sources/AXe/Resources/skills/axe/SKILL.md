---
name: axe
description: Provides agent-ready AXe CLI usage guidance for iOS Simulator automation. Use when asked to "use AXe", "automate a simulator", "tap/swipe/type on simulator", "describe UI", "take a screenshot", "record video", "batch steps", or "interact with an iOS app". Covers all commands including touch, gestures, text input, keyboard, buttons, accessibility, screenshots, video, and batch workflows.
---

## Step 1: Confirm runtime context
1. Identify simulator UDID target first (`axe list-simulators`).
2. Simulator-interaction AXe commands require `--udid <UDID>`. Commands like `list-simulators` and `init` do not.
3. Run `axe describe-ui --udid <UDID>` to inspect the current screen. Use the output to discover available `--id` and `--label` values for selector taps, and to confirm coordinates for coordinate-based taps.
4. Prefer selector taps (`tap --id` / `tap --label`) over raw coordinates. Selectors are resilient to layout changes, work across device sizes, and support element waiting (`--wait-timeout`) in batch flows.

## Step 2: Choose the right command

Available commands: `init`, `tap`, `swipe`, `gesture`, `touch`, `type`, `button`, `key`, `key-sequence`, `key-combo`, `batch`, `describe-ui`, `screenshot`, `record-video`, `stream-video`, `list-simulators`. Run `axe --help` or `axe <command> --help` for full options.

Common examples:
```bash
axe tap --id <identifier> --udid <UDID>
axe tap --label <text> --udid <UDID>
axe tap -x <X> -y <Y> --udid <UDID>
axe type 'text' --udid <UDID>
axe describe-ui --udid <UDID>
axe screenshot --udid <UDID> --output screenshot.png
```

## Step 3: Understand the execution model

HID commands (`tap`, `swipe`, `type`, `key`, etc.) are fire-and-forget — AXe confirms the event was dispatched to the simulator but cannot verify the app actually processed it. A tap may land before a view is interactive, or during a transition. This means:
- Always verify outcomes separately with `describe-ui` or `screenshot`.
- Use `--wait-timeout` in batch to wait for elements to appear, and `sleep` steps or `--pre-delay` / `--post-delay` to allow animations to settle.

## Step 4: Apply timing and input best practices
- Use `--pre-delay` / `--post-delay` on tap, swipe, and gesture commands for fixed delays around actions.
- Use `--duration` to control how long a swipe, gesture, button press, or key press lasts.
- For text with shell-sensitive characters, prefer `--stdin` or `--file` over inline quotes.
- Use single quotes for inline text arguments to avoid shell expansion issues.

## Step 5: Batch vs discrete commands

**Prefer `axe batch`** for multi-step flows. Batch executes every step in a single process invocation, which means:
- One tool call and one AI turn instead of many — significantly reduces agent latency and cost.
- A single HID session is reused across all steps, lowering per-step overhead.
- Steps execute sequentially — each step runs before the next is resolved, so earlier taps can trigger navigation and later selector taps will find newly appeared elements (with `--wait-timeout`).

**Fall back to discrete commands** when:
- A step's parameters depend on runtime inspection of a previous step's result (e.g. parsing `describe-ui` JSON to choose coordinates dynamically).

**Handling animations and transitions in batch:**
- Use `--wait-timeout <seconds>` so selector taps (`--id` / `--label`) poll the accessibility tree until the element appears or the timeout expires. This is the primary mechanism for multi-screen flows.
- Use `--poll-interval <seconds>` to control polling frequency during waiting (default 0.25s).
- Use `--ax-cache perStep` when *not* using `--wait-timeout` but the UI still changes between steps — this ensures each selector tap gets a fresh accessibility snapshot rather than a stale cached one.
- Insert explicit `sleep <seconds>` steps when coordinate-based taps need the UI to be stable (selectors with `--wait-timeout` are preferred over sleep where possible).
- Keep batch output quiet by default. Add `--verbose` only when troubleshooting.
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
# or
axe screenshot --udid <UDID> --output post-state.png
```

## Step 7: Exit criteria
Before finalising guidance, verify:
- Every simulator-interaction command includes `--udid`.
- Only valid AXe commands and flags are used.
- Shell quoting is correct (single quotes for literals, `--stdin`/`--file` for complex text).
- Verification is suggested as a separate step when results matter.
