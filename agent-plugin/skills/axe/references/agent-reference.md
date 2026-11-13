# Agent mode reference

## Contents

- [Output format](#output-format)
- [Agent mode workflow](#agent-mode-workflow)
- [Selectors](#selectors)
- [Coordinate taps](#coordinate-taps)
- [Native object references](#native-object-references)
- [Read custom-action names](#read-custom-action-names)
- [Change view on the current snapshot](#change-view-on-the-current-snapshot)
- [Read complete fields and page controls](#read-complete-fields-and-page-controls)
- [Drag a control](#drag-a-control)
- [Press and hold a control](#press-and-hold-a-control)
- [Focus a field and type in one command](#focus-a-field-and-type-in-one-command)
- [Keys on a focused field](#keys-on-a-focused-field)
- [Move a slider to its minimum or maximum](#move-a-slider-to-its-minimum-or-maximum)
- [Double-tap a control](#double-tap-a-control)
- [Pinch inside an area](#pinch-inside-an-area)
- [Run a small ordered agent batch](#run-a-small-ordered-agent-batch)

## Output format

`--agent` returns one `axe.output.agent-result` JSON envelope by default. Root `--output text|json` sets its representation; agent-only `--view` sets its content.

```bash
axe --output json describe-ui --agent --view reading --udid <UDID>
axe --output text describe-ui --agent --view navigation --udid <UDID>
axe describe-ui --agent --view full --udid <UDID>
```

- Prefer `axe --output json <command> ...`. `--output` on a non-media leaf command is accepted when unambiguous. Screenshot and movie `--output` after the command is a destination path. Explicit formatted streaming rejects before capture.
- A real `--udid` is required; no simulator is selected implicitly.

### Views

| View | `schemaVersion` | Rows | Content |
| --- | --- | --- | --- |
| `reading` (default) | `"2"` | `ref\|actions\|role\|label\|value` | Controls plus observation rows (visible text and images). |
| `navigation` | `"2"` | same schema and refs | Omits the observation section. Not proof the screen has no text. Sliders, switches, scroll areas and gesture areas stay available in the capture and its pages. |
| `full` | `"1"` (canonical base) | `ref\|action\|role\|label\|value\|id` | Original detailed capture fields, context, keyboard evidence, every reply field (`seq`, request IDs, timings, context) and the complete error message. Can be large; prefer bounded read-ref chunks when you need one full field. |

- Actions on one row are comma-separated.
- Native-proven redundant Button child labels are omitted; distinct text remains.
- Compact views keep IDs in the broker; get an exact ID with read-ref. A control with no label can display its ID as its name.
- Reading and full show visible image labels and values as observation rows with action `text` and role `image`. These add no `tap` or other input action. An image label, enabled state or frame alone does not prove activation support.
- Compact views report `capture.screen` as `[screenID, logicalWidth, logicalHeight, rotationDegrees]` and `capture.keyboard` as the keyboard evidence state. The broker keeps the full boot, screen UUID, geometry, hinge, app and keyboard evidence for input checks.
- All views share one immutable snapshot and its refs. Changing view does not change input authority or renew expiry.

Choosing a view:

- `--view` works on `describe-ui`, `tap`, `type`, `swipe` and `batch`.
- Before input, choose the view for the next task step: `navigation` when the next decision needs controls or their values; `--view reading` on the action itself when it reveals text you must verify, then check its returned capture.
- For more controls, page or scroll in navigation. Switch to reading for text navigation omits.

### Display text

- Labels and values keep exact whitespace (leading, trailing, repeated). JSON escapes line breaks and tabs without changing content.
- A literal pipe (`|`) displays as a slash (`/`). For the exact original field, including delimiters, use `--read-ref --text-field label|value`.
- Search and selector normalization are separate from display text.
- A whitespace-only display change changes the screen hash; on a control it also invalidates old refs.

### Keyboard evidence

- Numeric keyboard detection is heuristic. It requires complete native identity metadata, one focused editable field, a verified OS keyplane, all ten digits and Delete.
- Docked keyboard occlusion uses the measured native keyboard ancestor, not fixed coordinates.
- Full keyboard signals include optional `numericKeyCount` only when that evidence is verified; alphabetic output keeps its shape.
- Keyboard evidence clips planning bounds and grants no input authority.

### Compact replies

Reading and navigation omit:

- Request echoes: the view, a single action's `kind`, read-ref `ref`/`field`/`offset`.
- Constants: `replayed: false`.
- `cleanup` when `notNeeded`; `keyboard` when `unknown`; `nextSteps` when empty.
- `data.cache` unless `requiresRefresh` is true. No cache object means the capture's snapshot ID is current.

They keep:

- Failed replies without a capture: `data.screen` instead of the device context.
- Observation evidence: `outcome` and `observedPID`.
- Slider receipts: outcome, delivery, endpoint, action count and final value.
- Batch steps: `index`, `action`, `status`, `receipt` and `error`.

Compact output is a CLI projection; the broker's canonical evidence is unchanged.

### Unchanged replies and snapshot freshness

- A compact unchanged reply has `snapshotID`, integer `expiresInSeconds` and `unchanged: true`. Keep the screen hash from the matching capture; its UI, context and native fingerprint were rechecked. Expiry is rounded down for display and not renewed.
- `--since-screen-hash` is the low-output poll. Snapshot validation or paging can return rows again.
- When an action returns a replacement capture, use its snapshot ID for the next action. A fresh capture with a new ID replaces the previous ID even when the screen hash matches.

Input admission compares visible labels, values, frames and controls plus the exact target:

- Ignored: hidden nodes, nodes wholly off the display, empty inert groups.
- Ordinary text (a leaf StaticText outside any control) is compared by its place only. A clock, progress or status label that changes its text or glyph bounds does not refuse input (same as in reference batches).
- Text inside controls stays bound.
- A read-ref of a field whose text changed is refused with `screenChanged`. A validated page of an unchanged snapshot shows the text as captured.

### Errors

- A JSON failure writes one result to stdout and exits nonzero, with no second plain error. Error, cleanup, quarantine and no-replay evidence is kept.
- Inspect any completed action receipt before deciding the next step.
- A quarantine blocks all input on that simulator until you check the device and delete the file at `quarantine.recordPath`. Nothing is replayed.
- Reading and navigation cap top-level and batch-step `error.message` at 1024 Unicode scalars. A clipped message keeps its prefix and suffix around an omission separator, and the error object gets `messageTruncated: true` and `originalScalarLength`. Native cleanup, quarantine, context and recovery evidence is not clipped.
- Branch on the typed error code, action receipt and recovery fields; never parse causes from message text.
- Full view keeps the complete message. Select it before the operation when you need that detail; never repeat input to expand a diagnostic.

### Ordinary command JSON

Commands run without `--agent` opt into `axe.output.command-result` with `--output json`:

- Fields: `schema`, `schemaVersion: "1"`, `command` (full path, such as `hinge set`), `didError`, `data`, `nextSteps`. `error: {code, message}` is present exactly when `didError` is true.
- `data.result`: the command's typed result, per command in `schemas/axe.output.command-payloads.v1.schema.json`. `data.messages`: text.
- Input commands return `{outcome: "completed"}`; media commands return `{path, pixelWidth, pixelHeight, frames?}`.
- Branch on `error.code` (`invalidArguments`, `targetNotFound`, `notBooted`, `busy`, `timeout`, `interrupted`, `rejectedBeforeInput`, `inputFailed`, `cleanupUncertain`, `elementNotFound`, `screenChanged`, …), never on the message.
- `--verbose` puts the full receipt in place of the result and never changes the code.
- Output without a format, and command-specific `--json` flags, are unchanged.

### Refusal codes

Branch on `error.code`. A refusal that sent no input (`enqueuedEventCount` 0, no `cleanup: "uncertain"`, no quarantine) carries the current screen in `capture` whenever AXe could read it; plan the next action from that capture without another `describe-ui`.

| Code | Cause | Next step |
| --- | --- | --- |
| `screenChanged`, `targetChanged` | Screen or target changed after the snapshot. AXe already retried inside the call when the target was the same control. | Act from the capture. |
| `targetCovered` | Another control is at the target's point: an overlay, a sheet, or the target scrolled under something. Not retried. | Scroll it into view or close what covers it, then act from the capture. |
| `keyboardCovered` | The keyboard covers the tap point. | Follow the message: scroll the form or dismiss the keyboard with an app control. |
| `busy` | Another input on this simulator was still running. | Wait for it to finish, then act from a current capture. |
| `observationFailed` | AXe could not read the app's accessibility tree. | Run `describe-ui --agent` again; the app may still be launching. |
| `displayChanged` | The display or screen changed as the input began. | Act from the capture. |
| `waitTimedOut`, `waitCancelled` | The control did not become ready, or the wait was cancelled. | Check the capture for the control, then act again. |
| `unsupportedReference`, `targetMissing`, `targetAmbiguous` | The ref or selector names no single current control offering the action. | Choose again from the capture. |
| `snapshotMissing`, `snapshotExpired` | The snapshot ID is no longer current. | Use your latest capture, or run `describe-ui --agent`. |
| `inputIncomplete` | Input started but did not finish. | Do not repeat it. Read the screen and check `enqueuedEventCount`. |
| `cleanupUncertain` | AXe could not confirm the touch or key was released. | Send no input until you have followed the quarantine recovery steps. |
| `responseTooLarge` | The reply was too large; input may have been sent. | Read the screen; do not repeat the input. |
| `notBooted`, `targetNotFound` | The simulator is shut down, or no simulator has the UDID. | Boot it or fix the UDID. Agent mode does not run on physical devices. |
| `invalidExpectedPID` | `--expected-pid` was zero or negative. | Omit it, or pass the positive PID from a capture. |
| `nativeActionFailed` | Any other, untyped native failure. | Check the action receipt; do not repeat input that reports sent events. |

Gesture and path guards have their own typed codes (for example `swipeHitChanged`, `dragStartChanged`, `opaqueFrameTapRejected`). They also send no input and carry the current screen.

## Agent mode workflow

`--agent` works on `describe-ui`, `tap`, `type`, `swipe`, `drag`, `key`, `key-combo`, `key-sequence`, `slider`, `gesture double-tap`, `gesture pinch`, complete reference `touch` and `batch`, and returns stateful RS/1-style JSON. Use it for every app read and input. It is not the autonomous `axe agent <goal>` command and needs no model key. Commands without `--agent` are listed under References in [SKILL.md](../SKILL.md#references).

1. Capture: `axe describe-ui --agent --udid <UDID>`. Capture finds the frontmost app (or SpringBoard) and active display from one native observation, or takes the explicit selected screen pair. No raw hierarchy read or PID lookup is needed first.
2. Read the snapshot ID and rows for the view.
   - A required control or fact is missing: follow the returned page cursor.
   - Exact IDs or full fields: read-ref.
   - When other rows changed after the snapshot, read-ref reads the same control from the current screen if that control is unchanged and sets `cache.requiresRefresh: true` (the snapshot is stale for input). A changed control is refused with `screenChanged`.
   - A matching `--since-screen-hash` still performs a fresh read. Cache reuse also checks the exact native fingerprint; the compact hash alone does not prove unchanged raw UI.
3. Pass `--snapshot-id <UUID>` with every ref or coordinate action. Never reuse an ordinal ref from another snapshot.
   ```bash
   axe tap --agent --view navigation --udid <UDID> --snapshot-id <UUID> --ref <REF>   # next step needs controls or values
   axe tap --agent --view reading --udid <UDID> --snapshot-id <UUID> --ref <REF>      # next step needs visible text
   ```
4. Type and scroll:
   - Already focused field: `type <TEXT>` with its current `typeText` ref.
   - Current tap-capable TextField: `type <TEXT> --agent --focus --snapshot-id <UUID> --ref <REF>` focuses and types in one command. Inspect both phase receipts and use the replacement capture.
   - Typing does not clear existing text. The keys come from the simulator's keyboard layout (`type --layout`, `auto` by default); the 256-byte bound and per-key focus checks apply.
   - Scroll area: `swipe --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --direction up --distance 0.5`. Direction is finger movement. Agent swipes (ref or coordinates) slow to rest before lift-off, so the content moves about that distance without a fling; the reply carries the settled screen.
5. After input, use the replacement capture or read again.
   - Treat changed UI, boot, PID, display, hinge, rotation or geometry as stale, including changes made outside AXe; refresh and resolve again.
   - A refusal before input that carries a capture is already the fresh read; plan from it.
   - `action.retried: true`: the action ran after such a refresh inside the same call. AXe does this for `screenChanged`, `targetChanged` and any refusal after which the screen moved on, while the target is the same control (the same native object whenever both reads report one). Selector actions (`--id`, `--label`, `--value`) rerun on the fresh read the same way.
   - A refusal on an unchanged screen (`targetCovered`, `busy`) is not retried.
   - Never retry uncertain input or resubmit a failure that reports delivered events (`failedNoReplay`).

### Rules for every agent input

- Delivery and release receipts do not prove the app effect. Verify the app value, callback or visible effect separately.
- After success, use the replacement capture; after failure, or when there is no replacement, read again.
- Never replay completed, partial or uncertain input. Nothing is replayed or rolled back automatically.
- Boot, display, hinge, rotation and geometry checks run during input; owned touches and keys are released when input is interrupted.
- A ref, identity or hit failure never falls back to coordinates, semantic selectors or AXPress.
- Reads and input are separate OS operations: there is no atomic recipient guarantee.
- Only `tap` and `type` run inside `batch`; every other agent action rejects batch use.

### App owner (PID)

- Without `--expected-pid`, a new capture selects the frontmost app, or SpringBoard on Home, from the same native app/display observation.
- A ref action, snapshot validation and snapshot reuse use the PID saved in the snapshot.
- `--expected-pid <PID>` adds an assertion: it must be positive and match that owner; zero and negative reject. It does not launch an app or retarget an old ref.
- After Home or opening another app, capture again. Never transfer an old ref to the new owner. App, layout and field-focus changes keep their refusal rules.

### Limits

| Item | Limit |
| --- | --- |
| Agent capture | 4096 nodes, depth 64 |
| Row page | One global page across targets, scrolling and text; at most 64 source rows. Use the explicit cursor, not the displayed row count. |
| Typing and key input focused-field read | 512 nodes, depth 32, 1 MiB field output |
| Input admission deadline | 8 seconds, shared |

For nested scrolling, use the innermost scroll area that receives the gesture.

### Advertised actions

- Use only actions the current ref advertises.
- Rows do not repeat implied gestures: a `tap` row also accepts a ref hold (`touch --agent`), `gesture double-tap` and `drag`; a `swipe` scroll row also accepts `drag`.
- A tap-only alias of a duplicated native object accepts only `tap`.
- Typing needs an already focused, enabled, visible native `TextField` with `typeText` (or `--focus`).
- A Group alone does not prove a scroll area.

### Versions

Use matched CLI, broker, runtime and native framework versions; native-object refs and custom-action metadata require them. Older brokers reject newer action kinds instead of ignoring them: drag, hold, `keyPress`, `keyCombo`, slider endpoint and selector/frame payloads. `keySequence` uses a versioned broker endpoint; older requests reject.

## Selectors

- For a named Button in a moving list or after scrolling, prefer a fresh exact selector built from a unique ID or label already seen in the UI. It resolves current native state instead of an earlier layout.
- Keep refs for anonymous, duplicate or exact captured targets; capture again when their snapshot is stale.
- To keep the app owner fixed, keep the snapshot ref or assert its captured PID with `--expected-pid`.
- A fresh selector is a separate current query. It does not transfer an old ref to a new app or replay failed input.

Choose exactly one target: exact `--id`/`--label`/`--value`, substring, regex, ref or coordinates.

```bash
axe tap --agent --udid <UDID> --label-regex '^(Save|Done)$' --element-type Button --frame 'minY=400'
```

| Option | Meaning |
| --- | --- |
| `--label-contains <text>` | Case-sensitive literal substring. |
| `--label-regex <pattern>` | Foundation regex. Case-sensitive by default; inline options apply. Anchor it for a complete-label match; groups and alternation work. |
| `--element-type <type>` | Optional exact type filter on explicit selectors. |
| `--frame 'minX=12.5,maxY=500.25'` | One per command. Keys `minX`, `maxX`, `minY`, `maxY` in finite non-negative logical points; decimals work, relative fractions do not. Omitted edges use the current screen. The complete native frame must lie inside the positive rectangle. Not with refs or coordinates. |

`--label-contains`, `--label-regex` and `--frame` require `--agent` and work only on `tap`.

| Limit | Value |
| --- | --- |
| Query | Nonblank, at most 512 UTF-8 bytes |
| Regex pattern | At most 128 bytes |
| Frame specification | At most 256 bytes |
| Each native candidate text | At most 4096 bytes |
| Total candidate text | At most 256 KiB |
| Tree | 4096 nodes |
| Selection budget | 100 ms, shared |

- Regex matching cancels cooperatively on progress. Compilation has a byte cap and rejects invalid patterns but cannot be cancelled.
- Timeout, size, invalid-pattern, missing and ambiguous results are no-input failures; narrow the query.
- Guarded input requires a fresh native-tree match and a unique exact native ID or label.
- Never turn a pattern or frame result into cached coordinates. Snapshot freshness, PID, context, target and no-replay checks still apply.

## Coordinate taps

```bash
axe tap --agent --udid "$SIM_UUID" --snapshot-id "$SNAPSHOT_ID" -x X -y Y
```

- `X` and `Y` are finite non-negative logical UI points measured from a fresh screenshot of the same display and layout, not unconverted screenshot pixels. Use the current selected-display size and rotation.
- After an app, layout, fold or rotation change, take a new capture and screenshot and use that capture's snapshot ID.
- Read-ref returns field text, not tap geometry.
- Coordinate tap and swipe forms need a current snapshot.
- A coordinate tap is a separate, deliberate choice and does not resolve a ref. Never use it as an automatic fallback for a hidden, disabled or unsupported ref, and never replay completed or uncertain input.

## Native object references

A control with no app accessibility ID, or no unique ID or label, can still get a ref:

- A complete native read can prove one exact native process/object UID for an eligible control. The native tree and UID stay private to the broker and native input code.
- Use the same snapshot ID and `eN` ref. There is no UID argument and no new PID lookup.
- `read-ref --text-field id` returns only the app's real accessibility ID, which can be empty.

Ref table lifetime:

- The broker keeps one table in RAM per device/user/Xcode/protocol endpoint across CLI calls, not persisted. Other callers share it.
- A new capture replaces it; successful input normally supplies the replacement capture.
- The 60-second expiry is not renewed by validation, paging or reads.
- App, native object, display, fold, rotation or layout changes, expiry or broker restart can invalidate refs. Refresh and use the new refs; never replay completed or uncertain input.

Opaque (native identity) input:

- Requires a fresh complete tree, one occurrence of the exact object, current state and the native hit/context checks.
- Identity mode is fixed at publication. A failed opaque check does not retry with semantic selectors or coordinates.
- Incomplete identity traversal keeps semantic controls; affected refs can be unavailable with `capture.unavailableReferences[ref]: "nativeIdentityIncomplete"`.
- A displayed frame or path never substitutes for native identity.
- Does not authorize slider adjustments, AXPress or pinch. Scrolling needs an advertised scroll ref with fresh hit/ancestry checks.
- Native-ID batch steps need real app IDs, never object UIDs.
- Typing: an anonymous focused field can use its unique native object; a present duplicated or malformed field ID keeps its refusal. Before each key DOWN, AXe reads the exact current field and checks focus. No implicit focus is added. `--focus-id` is exact-ID only.

Opaque `tap --tap-style physical`:

- Can use the fresh frame when successful point reads return an unmapped representation.
- Requires stable complete trees, a unique target, no competing tap or text control, stable point evidence and unchanged device context.
- Numeric and compound native values refuse this route. Automatic and simulator styles, holds, double taps and gestures keep strict point checks.
- One planned input path: no retry, no AXPress fallback.
- An overlay missing from every tree can intercept the touch; inspect the replacement capture.

## Read custom-action names

Reading and navigation captures can include `capture.customActionGroups`:

```json
[{ "refs": ["e2", "e7"], "names": ["Delete"] }]
```

- A group gives the same ordered, read-only name preview to each listed ref. Refs group only when all name bytes and their order match.
- Names and duplicates are preserved. A group does not make its refs the same control and removes no child refs.
- Groups and refs follow first published row order. Every metadata ref appears once and belongs to a row in this page.
- One adaptive form, including singleton groups; adaptive captures do not return the `customActions` map. This is the first optional metadata contract in adaptive schema 2. Text output uses the same groups.
- Full view (schema 1) returns the `capture.customActions` ref-to-preview map instead.
- Both forms: at most four names per preview, at most 96 Unicode scalars per name; a clipped name ends with an ellipsis. Full view has the same bound, not an unbounded list.
- `capture.truncatedCustomActionRefs` lists refs with omitted or clipped names. Identical clipped previews do not prove identical complete lists.
- Adaptive groups share the 16 KiB capture budget. Follow the normal row cursor for later controls.
- Names are information, not input. A name such as `Delete` does not add `tap`, does not permit named execution and does not bypass identity, focus or hit checks. Use only the row's advertised actions.

Read every exact name with the current snapshot and ref:

```bash
axe describe-ui --agent --udid <UDID> --snapshot-id <UUID> \
  --read-ref <REF> --text-field custom-actions --text-offset 0 --text-limit 1024
```

- Concatenate `data.detail.text` chunks in cursor order, then decode the result as a JSON string array. Offsets count Unicode scalars in this JSON text, including punctuation and escapes.
- Preserve names, order and duplicates; do not split a preview on separators. A ref with no custom names returns `[]`.
- Every chunk gets the fresh app, tree, display and expiry checks. A name change invalidates the snapshot for input even if no control moved.
- Readback does not renew expiry or grant input authority.

## Change view on the current snapshot

When the screen is unchanged and you need visible text, request reading on the same snapshot:

```bash
axe describe-ui --agent --view reading --snapshot-id <CURRENT_UUID> --row-offset 0 --udid <UDID>
```

- AXe performs a fresh native check. After validation the snapshot ID, refs and original expiry stay the same.
- If the screen changed, the reply is a `screenChanged` refusal whose capture is a new snapshot starting at its first row. Discard the old rows, never combine old refs with new ones, and page the new snapshot from there.
- A plain describe that returns a new snapshot ID replaces the previous table.

## Read complete fields and page controls

### Clipped cells

- Compact views cap displayed cells at 160 Unicode scalars. A clipped cell has 159 scalars plus an ellipsis and a `capture.truncatedFields` entry with its ref and field.
- `displayScalarLength` is the scalar count of the complete display cell, not a raw-field cursor.
- Clipping does not shorten the native label, value or ID used for matching.

### Read one field

```bash
axe describe-ui --agent --udid <UDID> --snapshot-id <UUID> \
  --read-ref <REF> --text-field id
axe describe-ui --agent --udid <UDID> --snapshot-id <UUID> \
  --read-ref <REF> --text-field label --text-offset 0 --text-limit 1024
```

| Option | Values | Default |
| --- | --- | --- |
| `--text-field` | `label`, `value`, `id`, `custom-actions` | `label` |
| `--text-offset` | Non-negative, in Unicode scalars | 0 |
| `--text-limit` | 1...4096 Unicode scalars | 1024 |

- Offsets count Unicode scalars, not UTF-8 bytes or displayed characters. Scalar boundaries can split combining sequences.
- `data.detail` has the exact raw text chunk, `totalLength`, the requested `offset`, `nextOffset` when more text remains, and the native frame and actions.
- Use the returned `nextOffset`; never calculate it from a displayed ellipsis or character count.
- Raw whitespace and pipe characters are preserved. `data.detail.totalLength` counts scalars in the exact native field and can differ from `capture.truncatedFields.displayScalarLength` when the row uses the pipe display convention.
- A read requires `--snapshot-id` and `--read-ref`, with no hash polling, row paging, action ref or coordinates.
- Each read performs a fresh app, native-tree and selected-display check. Expired, replaced or changed snapshots reject without input. Reading does not renew the 60-second lifetime.
- A field can be read even when it has no unique selector for input. Readback does not authorize a tap.

### Page rows

If the current page has the control or fact you need, use it. Otherwise reuse the snapshot and current view, and pass the returned `page.nextOffset` (full view: `nextRowOffset`) as `--row-offset`.

| Option | Range | Default |
| --- | --- | --- |
| `--row-limit` | 1...64 rows | 64 |
| `--row-offset` | 0...12288 | |

- One global page, in target, scroll, text order.
- Compact filtering and row merging can return fewer displayed rows; never derive a cursor by counting them. Native totals are not displayed-row counts.
- The compact capture has a 16 KiB JSON budget, which can end a page early. Action, error, batch and recovery fields add to the whole result outside that budget.
- If the row is still missing, follow the next cursor when one is present.
- Navigation omits the continuation when only observation text remains; reading and full keep it.
- Without a cursor, an initial compact page omits native `offset` and `total`. A terminal reply to an explicit nonzero offset keeps that offset and omits `total`. A continued compact page keeps its native offset, total and next cursor.
- When the default-size reading view has room, AXe can fill it from one more canonical page of the same snapshot, with no extra read.
- Explicit page requests still validate the current UI.
- A compact capture can omit `page` when no page metadata is needed. Full view keeps the base row offsets and totals.
- Filtering and paging never renumber refs; refs keep their original snapshot identity.

### Scroll-area preview

When the first canonical page has no scroll rows but the snapshot has scroll areas, compact views can add `capture.areas`:

- `preview: true`, at most four distinct RS1 rows in `rows`, and `hasMore`. A false `hasMore` applies to the preview only.
- Read-only discovery rows from the existing snapshot, not another page or a complete area list. Their refs use the same snapshot and normal action checks.
- Uses only unused space in the 16 KiB capture budget. It does not replace or reorder canonical rows, change their cursor, or perform another accessibility read. Use `page.nextOffset` for canonical rows.
- Full view and legacy output omit the preview.

## Drag a control

```bash
axe drag --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --end-x <X> --end-y <Y>
```

- Use a ref from the current `targets` or `scroll` rows; page if needed. Not on `sliderEndpoint` rows; adds no pad refs.
- AXe resolves the exact identity chosen for the ref, starts at its fresh frame centre, and checks the native point hit and target ancestry again before DOWN. Never supply cached start coordinates.
- The endpoint is in decimal logical points. It can leave the original frame, but both endpoints must be inside the selected display.
- This proves the start target, not the endpoint recipient.
- If the start is inside a nested scroll area, use that area's ref.

| Option | Range | Default |
| --- | --- | --- |
| `--duration` | Finite, (0, 10] s | 0.6 s |
| `--steps` | 1...1000 | 60 |
| Initial and final holds | | 0.05 s |
| `--pre-delay`, `--post-delay` | 0...10 s | |
| Total requested delay, including holds | At most 20 s | |

- Admission shares the 8-second deadline and 4096-node, depth-64 tree bounds.
- Rejects start coordinates, explicit selectors and mixed payloads.

## Press and hold a control

```bash
axe touch --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --down --up --delay 0.7
```

- Use a current visible, enabled target ref that supports a complete hold. AXe reads its current target and activation point, then validates the point hit, app, screen and target again before touch down, and sends one complete physical touch.
- Omit `--delay` for a 0.1-second press. An explicit delay is finite, in (0, 10] s. It sets contact duration; the app decides whether it is a long press.
- Not on `sliderEndpoint` rows; adds no pad refs.
- Rejects coordinates, partial down/up and contact tokens. No retained agent touches.
- Context changes invalidate the cache. If folding or rotation interrupts input, read again and use the current ref; a changed layout never permits reusing the old point.

## Focus a field and type in one command

```bash
axe type 'Hello' --agent --focus --udid <UDID> --snapshot-id <UUID> --ref <REF>
```

Use on a current tap-capable native TextField with a unique typed field ID or complete unique anonymous native identity usable by the keyboard path. Without `--focus`, agent `type`, `--focus-id` and batch type steps without `"focus": true` need the field already focused.

- One guarded physical focus tap, a read of the same field's actual focus and new value/frame baseline, then typing.
- The keyboard can take a second or two to report focus after the tap (seen with a search field in a sheet). A typing phase refused for that sent no key; AXe reads and sends it again up to three more times before failing.
- Can open the keyboard and move the insertion point. Does not clear or replace text, and does not promise to append.
- Before the tap: all text is checked (a key for every character on the simulator's keyboard layout, 1...256 UTF-8 bytes, a complete bounded key sequence), plus the snapshot, owner, display, pose, fresh target and point-hit guards.
- The field's frame may change when the keyboard appears; the new frame must be finite, positive and inside the same display. The tap may change value or selection; the actual post-focus value becomes the exact typing baseline.
- Sibling index and parent-container changes do not change field identity; parent paths and container object IDs are not typing-recipient authority. Still bound: the chosen field authority (semantic or opaque, kept by the broker), observed field object ID/PID, type, actual focus, uniqueness, full display context and other identity/state facts.
- No label or coordinate fallback, no typing through a tap-only alias. Duplicated or malformed field IDs refuse.
- Native object ID/PID evidence is kept across the pre-tap and post-focus (full rebaseline) reads when available. Later semantic per-key reads check the exact typed ID, owner, focus and context but not the incidental object ID; anonymous fields keep native per-key identity checks.
- One broker reservation spans the command; native input leases are per phase.
- Reply: the batch receipt shape with two phases, tap then type. Check both and the replacement capture. If typing failed after focus, the focus tap is still an input effect. A failed final observation keeps completed receipts and requires a refresh. Never resubmit either phase. Key cleanup and quarantine apply as usual.

## Keys on a focused field

All three commands take a current `typeText` ref for an already focused, enabled, visible native TextField and do not focus it. Keycodes are HID codes in 0...255, not Unicode characters ([common keycodes](cli-quick-reference.md#common-keycodes)).

```bash
axe key 42 --agent --udid <UDID> --snapshot-id <UUID> --ref <REF>                        # Backspace
axe key-combo --modifiers 225 --key 4 --agent --udid <UDID> --snapshot-id <UUID> --ref <REF>   # Shift+A
axe key-sequence --keycodes 42,42 --agent --udid <UDID> --snapshot-id <UUID> --ref <REF>       # two Backspaces
```

| Command | Input | Timing | Rejects |
| --- | --- | --- | --- |
| `key` | One key: one complete default down/up | No added hold | Explicit `--duration`, `--focus-id`, other targets |
| `key-combo` | 1...8 distinct modifier codes in 224...231 (`--modifiers`), one different key (`--key`). Modifiers press in the given order, the key presses and releases, modifiers release in reverse. | One complete sequence, no added delay | Duplicate modifiers, a key already held as a modifier, mixed targets, focus-ID override, timing override |
| `key-sequence` | 1...100 codes (`--keycodes`), each pressed and released before the next | `--delay` finite 0...5 s, default 0.1, between keys only; total requested delay at most 20 s; at most 1024 events | Focus-ID overrides, other targets, retained keys |

- `key` adds no retained keys or sequences. `key-sequence` holds no modifiers across keys. Use `key-combo` for shortcuts.
- AXe rechecks the snapshot, app, display and field, then checks focus, PID and context before key down through the keyboard owner, within the 8-second admission budget and focused-field read bounds. A stale ref sends no input.
- The exact observed field is the target before the first owned key. Its value and editing frame may change during one keyboard operation (for example when a clear button appears). Before each later key down, AXe reads the current uniquely identified, focused TextField and requires the same chosen field identity, type, label and PID, explicit enabled, non-hidden focus state, and positive finite bounds inside the selected display. This rule supplies no coordinates and does not change tap, drag or slider checks.
- Key up and cleanup can still release owned keys after focus loss or a context change.

## Move a slider to its minimum or maximum

```bash
axe slider --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --endpoint minimum   # or maximum
```

- Use a current `sliderEndpoint` row. Only visible, enabled native Sliders with a positive finite frame and a unique exact ID or label get one.
- The row does not prove native domain or adjustment support; the request checks both before acting.
- Before the first adjustment the native worker checks the cached screen, current app/display context, slider identity, label, frame, value and readiness. Each fresh full tree checks slider identity and inherited visibility by the same snapshot rules as target rows. Every read and adjustment rechecks the owned native slider.
- Only an adjustment returned by this operation may change the original cached value; the next action still checks its expected current value and the original numeric domain.
- No fallback to a coordinate drag.
- Limits: 20 actions within 15 seconds; settled endpoint reads at 0.6 and 5 seconds.
- `action.slider` reports the semantic action count, delivery, endpoint and bounded numeric samples. Zero HID events does not mean zero semantic adjustments. An endpoint already reached can complete with zero actions.
- Native adjustment and the app response are separate; verify the app value and callback.
- Rejects selectors, type overrides and non-default polling.
- Slider rows do not add tap, drag or hold support.
- Percentages through the same row: [slider percentage control](slider-reference.md).

## Double-tap a control

```bash
axe gesture double-tap --agent --udid <UDID> --snapshot-id <UUID> --ref <REF>
```

- Use a current visible, enabled target with an available `tap` action. AXe resolves the fresh native activation point and checks the target and point hit before the first touch down.

| Option | Range | Default |
| --- | --- | --- |
| `--hold` (per tap) | Finite, (0, 10] s | 0.06 s |
| `--interval` (release to next down) | Finite, (0, 10] s | 0.1 s |
| `--pre-delay`, `--post-delay` | Finite, 0...10 s | 0 |
| Total delay, both holds and interval included | At most 20 s | |

- Rejects coordinates, other geometry, dimension overrides and duration/delta.
- Sends two complete taps. The target is checked before input; the app can still change between taps. Delivery does not prove a fixed recipient or double-tap recognition.

## Pinch inside an area

```bash
axe gesture pinch --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --radius 24 --scale 1.5
```

Eligible area: visible, enabled Other, ScrollView or List with a unique native ID or label and a positive finite frame.

- New eligible areas appear as `pinchWithin` target rows. Existing target and scroll rows keep their actions; eligible area refs from those rows can also pinch.
- A row does not prove the app has a pinch recognizer. A pinch row advertises no other action; normal action checks apply.

Geometry:

- Centre comes from the fresh area frame. The two horizontal starts are centre X ± radius; both ends use radius × scale. Radius is in logical points.
- Both complete paths must stay inside the area and the current display.

| Option | Range | Default |
| --- | --- | --- |
| `--radius` | Finite, positive | |
| `--scale` | Finite, positive, not 1 | |
| `--duration` | Finite, (0, 10] s | 0.6 s |
| `--delta` | (0, 200] logical points | 5 |
| `--pre-delay`, `--post-delay` | Each [0, 10] s | |
| Total time | At most 20 s | |
| Movement | At most 500 segments, 1024 events | |

- Rejects coordinates, second refs, other gesture options, dimension overrides, retained contacts and both batch forms.

Admission:

- Snapshot, PID, target and device context must match.
- Within one shared 8-second admission budget, AXe reads both native starting-point hits, one fresh full tree and both confirmed hits. Each hit must belong to the same current area; a nested scroll area needs its own ref. Swipe and drag admission use the same hierarchy rules.
- The first two-contact DOWN must match both checked coordinates. If either check fails, no DOWN is sent.

During motion, boot, display, hinge, rotation and geometry checks stop stale input and release both contacts. The app PID is checked before input, not during motion. Requested physical scale does not guarantee the same recognizer scale.

## Run a small ordered agent batch

```bash
axe batch --agent --udid <UDID> --file steps.json
axe batch --agent --udid <UDID> --steps-json '<JSON>'
```

- Exactly one source. The file must be regular UTF-8 JSON; inline JSON needs no file. Both use the same parser.
- 1...8 `tap`/`type` steps, at most 16384 UTF-8 bytes.
- Inline JSON is not interpreted as shell steps and adds no retry.
- Use native IDs or one published ref table for the whole document.

### Ref form

Capture first and copy its snapshot ID and refs (the values below are placeholders):

```json
{"snapshotID":"3FF70D78-26DA-4314-B37B-4CB57D2A1A85","steps":[{"action":"tap","ref":"e12"},{"action":"tap","ref":"e19"}]}
```

- Use for actions on controls already present in one stable layout.
- Before any input, AXe validates the whole document, all refs, their actions and each target's chosen exact identity. An invalid later ref therefore prevents earlier input.
- Each step reads fresh native state and resolves its original target again. The saved app PID and the complete boot/display/hinge/rotation/geometry context must match.
- Bound: native hierarchy, control identities, frames, focus, enabled state, visibility. Control and ancestor frames, control labels and descendant text inside controls are identity evidence.
- Not part of the layout: hidden nodes, nodes wholly off the display, empty inert groups (as for single actions).
- Allowed to change: ordinary leaf StaticText outside controls (text and glyph bounds), and control values.
- A layout change stops later input. Refs never become cached coordinates.
- One replacement capture is published at the end; use its new snapshot ID and refs after success.

Type steps in the ref form:

- Plain `type`: the ref must be an already focused native TextField with `typeText`.
- `"focus": true`: the ref is the field's `tap` ref, and the step makes the guarded focus tap of [`type --focus`](#focus-a-field-and-type-in-one-command) before typing. The field needs a unique typed field ID or unique anonymous native identity, and is found by that identity wherever earlier steps moved it, with only its position changed.
- A completed focus step is a declared layout change. Every later target must be the same control on the new screen (type, ID, label, value, process and any native identity) with only its position changed, still enabled, shown and inside the display. That screen, read until two reads in a row match (at most four reads), becomes the layout later steps must keep.
- Its receipt has kind `focusAndType` and counts both phases' events.
- A new sheet, navigation layout or app needs a separate inspection.

### ID form

```json
{"steps":[{"action":"tap","id":"field"},{"action":"type","id":"field","text":"AB"},{"action":"tap","id":"save"}]}
```

- Discovers the frontmost app or SpringBoard in its initial capture, resolves each exact ID from the current snapshot, and requires a usable replacement capture after each action before the next step.
- IDs are exact, nonblank, at most 4096 UTF-8 bytes.
- A type step needs the field focused when it starts.

### Document rules

- Optional positive `--expected-pid` asserts the same captured owner for either form.
- Each step has exactly one `id` or `ref`. Ref documents require `snapshotID`; ID documents reject it. Mixed forms and unknown JSON fields reject.
- `type` requires literal `text` and accepts optional Boolean `focus`; `tap` rejects both.
- Type text: typed on the simulator's own keyboard layout (batch steps take no `--layout`), 1...256 UTF-8 bytes, keyboard limits as for `type`.
- Unsupported: coordinates, arbitrary selectors, retained input, device actions, nested batches, text file or stdin, delays, continuing after errors.

### Retries, stops and recovery

- When no step has sent input, a ref batch retries on a new table once every target is unchanged, or is the same control holding still across two reads about 150 ms apart after a move, as a single refused action does.
- A batch stopped by a step that sent no input returns the current screen as a capture with the step receipts. Plan the remaining steps from its snapshot ID.
- Failure, cancellation, uncertain cleanup, a missing final capture or changed context stops later steps. Earlier input remains.
- A completed action can be followed by a failed capture. Inspect its receipt; never repeat it.
- If the reply is lost, the outcome is unknown. Never resubmit the batch. Disconnect cancellation and owned release do not undo input.
- One broker reservation spans the batch; native input ownership is per action. Not a transaction or exclusive OS control.
- Each operation keeps its native deadline. The reply wait allows up to 120 seconds per step plus one capture, at most 1080 seconds for eight steps. This is a transport wait bound, not a retry or a longer native timeout.

### Batch output

- Full view (base `data.batch`): total and completed counts; ordered steps with index, status, request ID and action receipt; stopped index; `replayed: false` and `rolledBack: false`.
- Compact, complete success with a refreshed final capture: `completedSteps` and ordered step `index`, `action`, `status`, input `outcome` and `enqueuedEventCount`; `totalSteps` omitted.
- Compact, stopped: also keeps `totalSteps` and `stoppedAt`.
- Every compact batch omits per-step request IDs, cache and context, `replayed`/`rolledBack` and the default `cleanup`. Use the top-level `data.cache` and capture.
- Receipt `kind` is omitted only when it equals the step action; `typeText` and `focusAndType` stay distinct from `type`.
- Select full view before input when you need request IDs; never repeat input to expand a reply.
