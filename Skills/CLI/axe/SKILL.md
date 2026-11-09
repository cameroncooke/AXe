---
name: axe
description: Drives iOS Simulator apps through the AXe CLI's agent mode. Capture the screen as compact rows with refs, then tap, type, swipe, scroll, set sliders and batch several same-screen actions in one call, and verify from the screen each action returns. Use when you need to operate, test or check an app in an iOS Simulator with AXe, for example "use AXe", "tap/type/swipe in the simulator", "fill in this form in the app", "toggle these settings", "check what is on screen" or "take a simulator screenshot", even when agent mode is not named.
---

# AXe for agents

Drive the simulator with AXe's agent mode (`--agent`). Each agent call reads the screen natively, checks that your target is still the control you saw, sends the input, and returns the settled screen as compact rows with refs. One call does the action and the re-read, and nothing is sent if the screen changed under you.

Use `--agent` for every UI read and input. Commands without it are for fixed scripts: they do not check targets, do not return the new screen, and can hit the wrong control after a layout change. Do not add `sleep`, `--pre-delay` or `--post-delay`; agent actions return once the screen has settled, so a fixed wait only adds time.

## 1. Find the simulator and look

```bash
axe list-simulators
axe describe-ui --agent --view navigation --udid <UDID>
```

Pick a booted simulator's UDID from the list. The capture in `data.capture` has a `snapshotID` and rows `ref|actions|role|label|value`, for example `e12|tap|button|Save|`. Use only the actions a row advertises (`tap`, `typeText`, `swipe`, `sliderEndpoint`, `pinchWithin`). Refs belong to that snapshot and expire after 60 seconds. After Home or switching apps, capture again; refs never carry over to another app.

Choose the view for what you need next:

- `--view navigation`: controls and their values. Use it while operating the app.
- `--view reading` (the default): adds visible text. Use it to read or verify facts.
- `--view full`: the complete base schema with IDs. Large; rarely needed.

`--view` works on `describe-ui`, `tap`, `type`, `swipe` and `batch`. Put `--view reading` on the action whose result you need to check, rather than reading again afterwards.

## 2. Act, then use the returned screen

```bash
axe tap --agent --view navigation --udid <UDID> --snapshot-id <SNAPSHOT_ID> --ref e12
```

A successful action returns the new screen in `data.capture`, with a new `snapshotID` that replaces the old one. Plan the next action from it. Do not run `describe-ui` just to see the result: the reply already is that read. Read again only when the reply has no capture, `data.cache.requiresRefresh` is true, or you need rows the capture does not show (see section 5).

## 3. Batch planned actions on one screen

Batching is the biggest speed-up, because every separate call costs a full agent turn. When you have already decided two or more taps or types on controls that are all in the current capture, and you do not need to look at the screen between them, send them in one batch. Typical cases are filling the fields of a form, toggling several switches, choosing units or options in a settings sheet, and picking several items in a list.

```bash
axe batch --agent --view navigation --udid <UDID> --steps-json '{"snapshotID":"<SNAPSHOT_ID>","steps":[{"action":"type","ref":"e7","text":"Ada","focus":true},{"action":"type","ref":"e9","text":"Lovelace","focus":true},{"action":"tap","ref":"e12"}]}'
```

- Send 1 to 8 `tap` or `type` steps, with all refs from that one snapshot.
- Add `"focus": true` to a type step to tap its field first, as `type --focus` does; its ref is the field row that advertises `tap`. Without it, a type step needs a field that is already focused and advertises `typeText`.
- A focus step's keyboard can move the screen. Later steps still run when their controls only moved; a control that changed, disappeared or is now covered stops the batch.
- The last step may leave the screen, for example Close, Save or Next. Any other step that changes the layout (a new screen or sheet) stops the later steps, which is why only same-screen steps belong together.
- The reply lists the completed steps and returns the current screen. If the batch stopped early, plan the remaining steps from that capture. Never resend a batch: completed steps are not undone and would run twice.

Use separate calls when you need to see one action's result before choosing the next. Read [batch-reference.md](references/batch-reference.md) for the full contract.

## 4. Type text

```bash
axe type 'London' --agent --view navigation --focus --udid <UDID> --snapshot-id <SNAPSHOT_ID> --ref e7
```

`--focus` taps the field, checks that it took focus and types, in one call. Without `--focus`, the field must already be focused. To fill several fields on one screen, use one batch of focus steps instead (section 3). Typing does not clear existing text. Text is limited to 256 UTF-8 bytes per call and uses the US keyboard mapping. For Return, Backspace and shortcuts on a focused field, use `key 40`, `key 42`, `key-sequence --keycodes ...` or `key-combo` with `--agent --snapshot-id <SNAPSHOT_ID> --ref <FIELD_REF>`; [cli-quick-reference.md](references/cli-quick-reference.md#common-keycodes) lists common HID codes.

Before a Save or Done that leaves a form, complete every field the task needs. An app's Done can commit the form, so do not tap it just to hide the keyboard.

## 5. Scroll, page and read exact text

- **Scroll** by swiping a scroll-area ref, a row that advertises `swipe` (compact captures can also list some under `capture.areas`): `axe swipe --agent --view navigation --udid <UDID> --snapshot-id <SNAPSHOT_ID> --ref e30 --direction up --distance 0.6`. Direction is finger motion, so `up` reveals content further down. The reply carries the settled screen. Swipe the innermost scroll area that holds your target.
- **Page** when a control or fact you need is missing and `capture.page.nextOffset` is present: `axe describe-ui --agent --view <VIEW> --snapshot-id <SNAPSHOT_ID> --row-offset <NEXT_OFFSET> --udid <UDID>`. Copy the offset; never compute it from row counts. No `nextOffset` means there are no more rows.
- **Read exact fields** when a cell is clipped (cells show at most 160 characters) or you need an ID: `axe describe-ui --agent --snapshot-id <SNAPSHOT_ID> --read-ref e12 --text-field label --udid <UDID>`. `--text-field` also takes `value` and `id`.
- **Switch the current snapshot to reading** without a new capture: `axe describe-ui --agent --view reading --snapshot-id <SNAPSHOT_ID> --row-offset 0 --udid <UDID>`.
- **Check for a change** without fetching rows again: `axe describe-ui --agent --since-screen-hash <SCREEN_HASH> --udid <UDID>` returns `unchanged: true` while the screen matches that capture's `screenHash`.

## 6. Choose targets that survive movement

Refs are exact. Use them on a stable screen and for anonymous or duplicate controls. For a named button that may move, such as one in a scrolling list or after an animation, a selector finds it on the current screen instead:

```bash
axe tap --agent --view navigation --udid <UDID> --label 'Save' --element-type Button
```

Selectors are exact `--id`, `--label` or `--value`, or `--label-contains` and `--label-regex '^(Save|Done)$'`, optionally narrowed with `--element-type` and `--frame 'minY=400'`. A selector must match exactly one control. Use only IDs and labels you have seen in a capture.

## 7. When AXe refuses

A refusal sent nothing: the reply has no `action`, or `action.outcome` is `failedBeforeInput` with `enqueuedEventCount: 0`. The reply usually carries the current screen; plan from it. AXe has already re-read and retried inside the call (`action.retried: true`), so sending the identical command again gets the same answer. Change something first:

- **The screen or target changed** (`screenChanged`, `targetChanged`, `snapshotMissing`, `unsupportedReference`): use the refs from the returned capture, or capture again if there is none.
- **The keyboard covers the control** (`keyboardCovered`): a tap there would press a key. Scroll the form until the control is above the keyboard (the message names its scroll area), or dismiss the keyboard with a control the app shows for that, then tap its new ref. Never use the form's Cancel, Close or Done buttons to hide the keyboard: they can discard or save the form.
- **The control cannot be hit for another reason** (`nativeActionFailed`), such as an overlay or a sheet still presenting: use the returned capture to find what is in the way.
- **A selector matched nothing or several controls** (`targetMissing`): narrow it, or use a ref.

After an action that changes screens (Save, Done, Back, opening an item), the returned capture can show the screen mid-transition: a list can appear for a moment before the item you opened slides in. If the capture is not the screen you expected, run `describe-ui` before tapping anything.

Never repeat input whose outcome is uncertain or that reports delivered events: a `failedNoReplay` outcome, a lost reply, or a batch that stopped after completed steps. Read the screen and decide from what actually happened.

## 8. Verify from the screen

A successful reply proves the input was delivered, not that the app did what you wanted. Check the effect in the returned capture or a reading view. When a task makes verification read-only, verify with `describe-ui` and screenshots only, with no taps.

For visual facts the accessibility tree does not expose, take a screenshot and open the PNG it writes: `axe screenshot --udid <UDID> --output shot.png`.

## 9. Fallback: coordinates

If a control you can see has no usable ref or selector, for example a custom-drawn view without an accessibility element, tap it by position with the current snapshot:

```bash
axe tap --agent --udid <UDID> --snapshot-id <SNAPSHOT_ID> -x 201 -y 640
```

Use logical points, not screenshot pixels: `capture.screen` is `[screenID, width, height, rotation]`. Measure from a fresh screenshot of the same screen, and take a new capture and screenshot after any layout change. Coordinates skip the target check, so use them only as a deliberate choice for that control, never as an automatic retry for a refused ref. Coordinate swipes take `--start-x`, `--start-y`, `--end-x` and `--end-y` with `--agent --snapshot-id`.

## More agent actions

Each takes `--agent --udid <UDID> --snapshot-id <SNAPSHOT_ID> --ref <REF>`:

- Slider to an end: `slider ... --endpoint minimum` or `maximum`, on rows that advertise `sliderEndpoint`. For a percentage, read [slider-reference.md](references/slider-reference.md).
- Long press: `touch ... --down --up --delay 0.7`.
- Drag a control: `drag ... --end-x <X> --end-y <Y>`.
- Double tap: `gesture double-tap ...`. Pinch: `gesture pinch ... --radius 24 --scale 1.5`, on rows that advertise `pinchWithin`.

Read [agent-reference.md](references/agent-reference.md) for exact limits, receipts and output fields.

## Outside agent mode

Commands with no UI target run without `--agent`: `list-simulators`, `displays`, `screenshot`, `record-video`, `stream-video`, `button`, `shutdown` and `clipboard copy`. See [cli-quick-reference.md](references/cli-quick-reference.md), [recording-reference.md](references/recording-reference.md) and [clipboard-reference.md](references/clipboard-reference.md). `axe displays --udid <UDID>` shows which screen is active, its size in points and its orientation, and the hinge angle on iPhone Duo. For iPhone Duo hinge and rotation, and for input or capture on one explicitly selected display, read [device-reference.md](references/device-reference.md).
