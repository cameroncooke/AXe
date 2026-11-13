---
name: axe
description: Official skill for the AXe CLI, which gives agents eyes and hands on iOS apps. Sees and operates app UI, takes screenshots and changes device settings on iOS Simulators and physical iPhones and iPads. Use when checking, testing or validating an iOS app after building or changing it, or whenever an iOS app's screen needs to be seen or driven.
---

# AXe

Use agent mode (`--agent`) for every app read and input. An agent call checks the target is still the control you saw, sends the input and returns the settled screen; if the screen changed, it sends nothing. The same commands without `--agent` are for scripts written by people: no target check, no returned screen. Never add `sleep`, `--pre-delay` or `--post-delay`.

## Step 1: Ensure AXe exists

```bash
axe describe-ui --help | grep -- --agent
```

- Not found: `brew install cameroncooke/axe/axe`.
- Found but no `--agent` (older than AXe 2.0): `brew upgrade cameroncooke/axe/axe`.
- Ask the user first if you may not install software. AXe needs macOS with Xcode.

## Step 2: Find the simulator and capture

```bash
axe list-simulators
axe describe-ui --agent --view navigation --udid <UDID>
```

- Use a booted simulator's UDID.
- `data.capture` has a `snapshotID` and rows `ref|actions|role|label|value`, for example `e12|tap|button|Save|`.
- Use only the actions a row advertises: `tap`, `typeText`, `swipe`, `sliderEndpoint`, `pinchWithin`.
- Refs belong to one snapshot and expire after 60 seconds. After Home or an app switch, capture again; refs never carry over to another app.
- `--view navigation`: controls and values, for operating the app. `--view reading` (default): adds visible text, for reading or verifying. `--view full`: complete schema with IDs; large, rarely needed.
- `--view` works on `describe-ui`, `tap`, `type`, `swipe` and `batch`. Put `--view reading` on the action whose result you will check instead of reading again.

## Step 3: Act and use the returned screen

```bash
axe tap --agent --view navigation --udid <UDID> --snapshot-id <SNAPSHOT_ID> --ref e12
```

- Success returns the new screen in `data.capture` with a new `snapshotID`. Plan the next action from it; do not run `describe-ui` to see the result.
- Read again only when the reply has no capture, `data.cache.requiresRefresh` is true, or you need rows it does not show (Step 6).

## Step 4: Batch same-screen actions

Every call costs a turn, so batch. When you have decided two or more taps or types on controls in the current capture and need not look between them (form fields, several switches, options in a settings sheet, several list items), send one batch:

```bash
axe batch --agent --view navigation --udid <UDID> --steps-json '{"snapshotID":"<SNAPSHOT_ID>","steps":[{"action":"type","ref":"e7","text":"Ada","focus":true},{"action":"type","ref":"e9","text":"Lovelace","focus":true},{"action":"tap","ref":"e12"}]}'
```

- 1 to 8 `tap` or `type` steps, all refs from that snapshot.
- `"focus": true` taps a type step's field first, as `type --focus` does; its ref is the field row that advertises `tap`. Without it, the field must already be focused and advertise `typeText`.
- Steps whose controls only moved (for example under a keyboard) still run; a control that changed, disappeared or is covered stops the batch.
- Only the last step may leave the screen (Close, Save, Next). Any other layout change stops the later steps.
- The reply lists completed steps and the current screen. If it stopped early, plan the rest from that capture. Never resend a batch: completed steps would run twice.
- Use separate calls when you must see one result before choosing the next action. Full contract: [batch-reference.md](references/batch-reference.md).

## Step 5: Type

```bash
axe type 'London' --agent --view navigation --focus --udid <UDID> --snapshot-id <SNAPSHOT_ID> --ref e7
```

- `--focus` taps the field, checks it took focus and types. Without it, the field must already be focused. Several fields on one screen: one batch of focus steps.
- Typing does not clear existing text. At most 256 UTF-8 bytes per call.
- AXe picks the keys from the simulator's own keyboard layout (German, French, British and so on), so pass the text as it should read. A character that keyboard has no key for fails before anything is typed. If text arrives as other characters, the app was already typing when the simulator's keyboard changed: relaunch the app, or name the layout with `--layout <name>` on a non-agent `type`. `--layout us` sends US key positions.
- Return, Backspace and shortcuts on a focused field: `key 40`, `key 42`, `key-sequence --keycodes ...` or `key-combo`, with `--agent --snapshot-id <SNAPSHOT_ID> --ref <FIELD_REF>`. Codes: [cli-quick-reference.md](references/cli-quick-reference.md#common-keycodes).
- Fill every field the task needs before Save or Done. Never tap Done just to hide the keyboard: it can commit the form.

## Step 6: Scroll, page and read exact text

- Scroll: swipe a row that advertises `swipe` (also listed under `capture.areas`): `axe swipe --agent --view navigation --udid <UDID> --snapshot-id <SNAPSHOT_ID> --ref e30 --direction up --distance 0.6`. Direction is finger motion, so `up` reveals content below. Swipe the innermost scroll area that holds the target.
- Page when something you need is missing and `capture.page.nextOffset` is present: `axe describe-ui --agent --view <VIEW> --snapshot-id <SNAPSHOT_ID> --row-offset <NEXT_OFFSET> --udid <UDID>`. Copy the offset; never compute it. No `nextOffset` means no more rows.
- Clipped cells (160 characters at most) or IDs: `axe describe-ui --agent --snapshot-id <SNAPSHOT_ID> --read-ref e12 --text-field label --udid <UDID>`; `--text-field` also takes `value` and `id`.
- Reading view of the current snapshot without a new capture: `axe describe-ui --agent --view reading --snapshot-id <SNAPSHOT_ID> --row-offset 0 --udid <UDID>`.
- Check for a change: `axe describe-ui --agent --since-screen-hash <SCREEN_HASH> --udid <UDID>` returns `unchanged: true` while the screen matches that capture's `screenHash`.

## Step 7: Targets that survive movement

- Refs are exact. Use them on a stable screen and for anonymous or duplicate controls.
- For a named control that may move (a scrolling list, after an animation), use a selector, which finds it on the current screen: `axe tap --agent --view navigation --udid <UDID> --label 'Save' --element-type Button`.
- Selectors: exact `--id`, `--label` or `--value`, or `--label-contains` and `--label-regex '^(Save|Done)$'`, narrowed with `--element-type` and `--frame 'minY=400'`. A selector must match exactly one control. Use only IDs and labels seen in a capture.

## Step 8: Handle refusals

A refusal sent nothing: the reply has no `action`, or `action.outcome` is `failedBeforeInput` with `enqueuedEventCount: 0`. Plan from the capture it usually carries. If the screen or target changed but it is still the same control, AXe already re-read and retried (`action.retried: true`); `targetCovered` and `busy` are not retried. The identical command gets the same answer, so change something first:

- `screenChanged`, `targetChanged`, `snapshotMissing`, `unsupportedReference`: use refs from the returned capture, or capture again.
- `keyboardCovered`: a tap would press a key. Scroll the control above the keyboard (the message names the scroll area) or dismiss the keyboard with the app's control for that. Never use the form's Cancel, Close or Done to hide it.
- `targetCovered`: an overlay or a presenting sheet is in the way; find it in the capture.
- `busy`: act again from a current capture once the other input has finished.
- `targetMissing`: the selector matched none or several; narrow it or use a ref.

Also:

- After Save, Done, Back or opening an item, the capture can show the screen mid-transition. If it is not what you expected, run `describe-ui` before tapping.
- Never repeat input whose outcome is uncertain or that delivered events: `failedNoReplay`, a lost reply, or a batch that stopped after completed steps. Read the screen and decide from what happened.

## Step 9: Verify

- Success proves delivery, not the app effect. Check the effect in the returned capture or a reading view.
- When verification must be read-only, use `describe-ui` and screenshots only, no taps.
- For visual facts the accessibility tree lacks: `axe screenshot --udid <UDID> --output shot.png`, then open the PNG.

## Coordinates (fallback)

For a visible control with no usable ref or selector, such as a custom-drawn view:

```bash
axe tap --agent --udid <UDID> --snapshot-id <SNAPSHOT_ID> -x 201 -y 640
```

- Logical points, not screenshot pixels: `capture.screen` is `[screenID, width, height, rotation]`. Measure from a fresh screenshot of the same screen; capture and screenshot again after any layout change.
- Coordinates skip the target check. Use them deliberately for that control, never as an automatic retry for a refused ref.
- Coordinate swipes take `--start-x`, `--start-y`, `--end-x` and `--end-y` with `--agent --snapshot-id`.
- No agent form: drawing a path (`axe draw 100,400 300,400 300,600 --close --udid <UDID>`) and pinching where no row advertises `pinchWithin` (`axe gesture pinch --scale 2 --udid <UDID>`; `--scale 0.5` zooms out). They return no capture, so capture again. See [cli-quick-reference.md](references/cli-quick-reference.md#gestures-and-drawing).

## More agent actions

Each takes `--agent --udid <UDID> --snapshot-id <SNAPSHOT_ID> --ref <REF>`:

- Slider to an end: `slider --endpoint minimum` or `maximum`, on `sliderEndpoint` rows. Percentages: [slider-reference.md](references/slider-reference.md).
- Long press: `touch --down --up --delay 0.7`.
- Drag a control: `drag --end-x <X> --end-y <Y>`.
- Double tap: `gesture double-tap`. Pinch: `gesture pinch --radius 24 --scale 1.5`, on `pinchWithin` rows.

## References

Agent mode covers app reads and input on every simulator, including the iPhone Duo.

| Open when you need to... | Read |
|---|---|
| check exact agent limits, receipts, output fields or refusal codes | [agent-reference.md](references/agent-reference.md) |
| check the full batch contract | [batch-reference.md](references/batch-reference.md) |
| set a slider to a percentage | [slider-reference.md](references/slider-reference.md) |
| work on a physical iPhone or iPad (no agent mode) | [physical-device-reference.md](references/physical-device-reference.md) |
| use iPhone Duo screens, hinge and rotation, or pin capture or input to one display | [device-reference.md](references/device-reference.md) |
| set dark mode, text size, accessibility display settings, VoiceOver, location or status bar | [settings-reference.md](references/settings-reference.md) |
| run a command with no UI target (`list-simulators`, `displays`, `screenshot`, `button`, `shutdown`) or a gesture with no agent form | [cli-quick-reference.md](references/cli-quick-reference.md) |
| record or stream video | [recording-reference.md](references/recording-reference.md) |
| stage text on the clipboard | [clipboard-reference.md](references/clipboard-reference.md) |
