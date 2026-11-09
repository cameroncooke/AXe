# Agent mode reference

Numeric keyboard evidence is heuristic. It requires complete native identity metadata, one focused editable field, a verified OS keyplane, all ten digits and Delete. Docked occlusion uses the measured native keyboard ancestor, not fixed coordinates. Full keyboard signals include optional `numericKeyCount` only when that evidence is verified; alphabetic output keeps its current shape. This evidence clips planning bounds and grants no input authority.

## Output format

`--agent` returns one `axe.output.agent-result` JSON envelope by default. Use the root `--output text|json` option for its representation and the agent-only `--view` option for its content:

```bash
axe --output json describe-ui --agent --view reading --udid <UDID>
axe --output text describe-ui --agent --view navigation --udid <UDID>
axe describe-ui --agent --view full --udid <UDID>
```

Displayed labels and values keep their exact whitespace, including leading, trailing and repeated spaces. JSON escapes line breaks and tabs without changing their content. The existing row convention displays a literal pipe (`|`) as a slash (`/`); use `--read-ref --text-field label|value` for the exact original field, including delimiters. Search and selector normalization are separate from display text. Whitespace-only display changes change the screen hash; on a control they also invalidate old references.

`reading` is the default public adaptive view, with `schemaVersion: "2"`. `capture.rows` contains `ref|actions|role|label|value` rows; supported actions on the same row are comma-separated. Native-proven redundant Button child labels are omitted, but distinct text remains. IDs remain in the broker; use read-ref below to get an exact ID. If a control has no label, its displayed name can use its ID.

Reading and full views include visible image labels and values as observation rows with action `text` and role `image`. This keeps image content discoverable without adding `tap` or another input action. An image label, enabled state or frame alone does not prove activation support. Navigation omits these observation rows; use reading or full for the content.

Pass `--view navigation` on `describe-ui`, `tap`, `type`, `swipe` or `batch` when the next decision needs controls or their values. Before input, choose the view for the next task step. If the action reveals text you need to verify, pass `--view reading` on that action and check its returned capture. For more controls, page or scroll in navigation. Change to reading when you need text that navigation omits.

Compact replies keep only what an agent acts on. They omit request echoes (the view, a single action's `kind`, read-ref `ref`/`field`/`offset`), constants (`replayed: false`), `cleanup` when it is `notNeeded`, `keyboard` when it is `unknown`, `nextSteps` when empty, and `data.cache` unless `requiresRefresh` is true: without a cache object the capture's snapshot ID is current. Failed replies without a capture report `data.screen` instead of the device context; observation evidence keeps `outcome` and `observedPID`; slider receipts keep the outcome, delivery, endpoint, action count and final value. Batch steps keep `index`, `action`, `status`, `receipt` and `error`. Full view keeps every field, including `seq`, request IDs, timings and context.

`navigation` uses the same schema and control references but omits the observation section. This is an explicit content choice, not proof that the screen has no text. Sliders, switches, scroll areas and gesture areas remain available through the capture and its pages. Both compact views report `capture.screen` as `[screenID, logicalWidth, logicalHeight, rotationDegrees]`, and `capture.keyboard` as the evidence state. The broker retains the full boot, screen UUID, geometry, hinge, app and keyboard evidence for input checks.

`full` returns the canonical base schema, `schemaVersion: "1"`, with the original detailed capture fields, context, keyboard evidence and six-column `ref|action|role|label|value|id` rows. Full view can contain large text; prefer bounded read-ref chunks when only one full field is needed. All views use the same immutable snapshot and references. Changing view does not change input authority or renew expiry.

Compact unchanged replies contain `snapshotID`, integer `expiresInSeconds` and `unchanged: true`. Keep the screen hash from the matching capture; its UI/context/native fingerprint were rechecked. Expiry is rounded down for display and is not renewed. `--since-screen-hash` is the low-output poll path; snapshot validation/paging can return rows again. When an action returns a replacement capture, use its snapshot ID before the next action. A fresh capture with a new ID replaces the previous ID even when the screen hash matches. Input admission compares visible labels, values, frames and controls plus the exact target; hidden nodes, nodes wholly off the display and empty inert groups do not refuse input. Ordinary text (a leaf StaticText outside any control) is compared by its place only: a clock, progress or status label that changes its text or glyph bounds does not refuse input, as in reference batches. Text inside controls stays bound. A read-ref of a field whose text changed is still refused with `screenChanged`, and a validated page of an unchanged snapshot shows the text as it was captured.

JSON failures write one result to stdout and exit nonzero, without a second plain error. Error, cleanup, quarantine and no-replay evidence remains. Inspect any completed action receipt before deciding what to do next. A quarantine blocks all input on that simulator until you check the device and delete the file at `quarantine.recordPath`; nothing is replayed. Compact output is a CLI projection; it does not alter the broker's canonical evidence.

Reading/navigation views cap top-level and batch-step `error.message` at 1024 Unicode scalars. A clipped message keeps its prefix and suffix with an omission separator, plus `messageTruncated: true` and `originalScalarLength` on the error object. Use the typed error code, action receipt and recovery fields; do not parse causes from message text. Native cleanup, quarantine, context and recovery evidence is unchanged. Full view preserves the complete message. Select full view before an operation when that detail is needed; do not repeat input to expand a diagnostic.

Ordinary commands opt into `axe.output.command-result` with `--output json`. Its fields are `schema`, `schemaVersion: "1"`, `command` (the full path, such as `hinge set`), `didError`, `data` and `nextSteps`; a failure adds `error.code` and `error.message`. `data.result` holds the command's typed result, described per command in `schemas/axe.output.command-payloads.v1.schema.json`; `data.messages` holds text. Input commands return `{outcome: "completed"}`; media commands return `{path, pixelWidth, pixelHeight, frames?}`. Branch on `error.code` (`invalidArguments`, `targetNotFound`, `notBooted`, `busy`, `timeout`, `interrupted`, `rejectedBeforeInput`, `inputFailed`, `cleanupUncertain`, `elementNotFound`, `screenChanged`, …), never on the message. `--verbose` adds the full receipt in place of the result and never changes the code. No-format ordinary output and existing command-specific `--json` flags are unchanged.

### Refusal codes

Branch on `error.code`. A refusal that sent no input (`enqueuedEventCount` 0, no `cleanup: "uncertain"`, no quarantine) carries the current screen in `capture` whenever AXe could read it; choose the next action from that capture without another `describe-ui`.

| Code | Cause | Next step |
| --- | --- | --- |
| `screenChanged`, `targetChanged` | The screen or the target changed after the snapshot. AXe already retried inside the call when the target was the same control. | Act from the capture. |
| `targetCovered` | Another control is at the target's point: an overlay, a sheet or the target scrolled under something. Not retried. | Scroll it into view or close what covers it, then act from the capture. |
| `keyboardCovered` | The keyboard covers the tap point. | Follow the message: scroll the form or dismiss the keyboard with an app control. |
| `busy` | Another input on this simulator was still running. | Wait for it to finish, then act from a current capture. |
| `observationFailed` | AXe could not read the app's accessibility tree. | Run `describe-ui --agent` again; the app may still be launching. |
| `displayChanged` | The display or screen changed as the input began. | Act from the capture. |
| `waitTimedOut`, `waitCancelled` | The control did not become ready, or the wait was cancelled. | Check the capture for the control, then act again. |
| `unsupportedReference`, `targetMissing`, `targetAmbiguous` | The ref or selector names no single current control offering the action. | Choose again from the capture. |
| `snapshotMissing`, `snapshotExpired` | The snapshot ID is no longer current. | Use your latest capture, or run `describe-ui --agent`. |
| `inputIncomplete` | Input started but did not finish. | Do not repeat it. Read the screen and check `enqueuedEventCount`. |
| `cleanupUncertain` | AXe could not confirm the touch or key was released. | Send no input until you have followed the quarantine recovery steps. |
| `responseTooLarge` | The reply was too large, and input may have been sent. | Read the screen; do not repeat the input. |
| `nativeActionFailed` | Any other native failure. | Check the action receipt; do not repeat input that reports sent events. |

Gesture and path guards use their own typed codes (for example `swipeHitChanged`, `dragStartChanged`, `opaqueFrameTapRejected`); they also send no input and carry the current screen.

Prefer `axe --output json <command> ...`. Non-media leaf placement is accepted when unambiguous. Screenshot/movie `--output` after the command remains a destination path. Explicit formatted streaming rejects before capture. A real `--udid` is required; no implicit simulator is selected. Native-object refs require matched CLI, broker and runtime versions.

## Optional agent mode

Keep the normal IDB accessibility-readiness check for selected captures and physical target checks. There is no new preparation option or retained preparation layer.

Use `--agent` on `describe-ui`, `tap`, `type`, `swipe`, `drag`, `key`, `key-combo`, `key-sequence`, `slider`, `gesture double-tap`, `gesture pinch` and complete reference `touch` for stateful RS/1-style JSON. Keep ordinary commands without the flag when raw accessibility output or existing coordinate semantics are required. Do not confuse the flag with the autonomous `axe agent <goal>` command; the flag needs no model key.

1. Capture with `axe describe-ui --agent --udid <UDID>`. Let capture discover the frontmost app or SpringBoard and active display from the same native observation, or supply the explicit selected pair. No raw hierarchy read or PID lookup is required first.
2. Read the snapshot ID and rows for the selected view. Use the returned page cursor when a required control or fact is missing; get exact IDs or full fields with read-ref. When other rows changed after the snapshot, read-ref reads the same control from the current screen if that control is unchanged, and sets `cache.requiresRefresh: true` because the snapshot is stale for input; a control that changed is refused with `screenChanged`. A matching `--since-screen-hash` still performs a fresh read. Cache reuse also checks the exact native fingerprint; the compact hash alone does not prove unchanged raw UI.
3. Pass `--snapshot-id <UUID>` with each reference or coordinate action. Use `axe tap --agent --view navigation --udid <UDID> --snapshot-id <UUID> --ref <REF>` when you next need controls or their values. Use `axe tap --agent --view reading --udid <UDID> --snapshot-id <UUID> --ref <REF>` when you next need visible text. Never reuse an ordinal ref from a different snapshot.
4. For an already focused field, use `type <TEXT>` with its current `typeText` ref. For a current tap-capable TextField, use `type <TEXT> --agent --focus --snapshot-id <UUID> --ref <REF>` to focus and type in one command. It does not clear existing text. Inspect both phase receipts and use the replacement capture. Retain the US keyboard mapping, 256-byte bound and per-key focus checks. For a scroll area, use `swipe --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --direction up --distance 0.5`; direction describes finger movement. Agent swipes, by ref or coordinates, slow to rest before lift-off, so the content moves about that distance without a fling and the reply carries the settled screen. Raw swipes keep their linear release.
5. After input, use the replacement capture or read again. Treat changed UI, boot, PID, display, hinge, rotation or geometry as stale. Refresh and resolve again after changes made outside AXe as well. A refusal before input that carries a capture is already the fresh read: choose the next action from it. `action.retried: true` means the action ran after such a refresh inside the same call, which AXe does for `screenChanged`, `targetChanged` and any refusal after which the screen moved on, while the target is the same control (the same native object whenever both reads report one); selector actions (`--id`, `--label`, `--value`) run again on the fresh read the same way. A refusal on an unchanged screen, such as `targetCovered` or `busy`, is not retried. Do not retry uncertain input, and never resubmit a failure that reports delivered events (`failedNoReplay`).
6. Check actual app effects separately. A transport receipt is not app-effect proof. Other commands do not yet accept `--agent`; use their existing documented interfaces.

When `--expected-pid` is omitted, a new agent capture selects the frontmost app, or SpringBoard on Home, from the same native app/display observation. A reference action uses the PID saved in its snapshot. Optional `--expected-pid <PID>` adds an assertion that must be positive and match that owner; zero and negative values reject. It does not launch an app or retarget an old reference.

Snapshot validation and reuse also use the saved PID when the option is omitted. After Home or opening another app, take a new capture; never transfer an old reference to the new owner. App, layout and field-focus changes keep their existing refusal rules. Coordinate tap/swipe forms remain available with a current snapshot. Raw commands and public selected mode without `--agent` keep their current behavior.

For an explicit visible-point tap, keep agent mode:

```bash
axe tap --agent --udid "$SIM_UUID" --snapshot-id "$SNAPSHOT_ID" -x X -y Y
```

Replace `X` and `Y` with finite non-negative logical UI points from a fresh screenshot of the same display and layout, not unconverted screenshot pixels. Use the current selected-display size and rotation. Get a new capture and screenshot after an app, layout, fold or rotation change; use that capture's snapshot ID. Read-ref returns field text, not tap geometry.

A coordinate tap is a separate caller choice. It does not resolve an element ref. Do not use it as an automatic fallback for a hidden, disabled or unsupported ref, and never replay completed or uncertain input.

Use matched CLI, broker and runtime versions for native-object refs.

Keep agent captures within 4096 nodes and depth 64. One global row page spans targets, scrolling and text, with at most 64 source rows; use the explicit cursor rather than the displayed row count. Agent typing and key input limit their focused-field read to 512 nodes, depth 32 and 1 MiB of field output; its shared eight-second admission deadline remains unchanged. For nested scrolling, select the innermost scroll area that receives the gesture.

Use only actions advertised by the current reference. Rows do not repeat the gestures every tap target supports: a `tap` row also accepts a reference hold (`touch --agent`), `gesture double-tap` and `drag`, and a `swipe` scroll row also accepts `drag`. A tap-only alias of a duplicated native object accepts only `tap`. Eligible native controls without a unique ID or label can use broker-owned native object identity when a complete native read proves it unique. The native tree and object UID remain internal; `read-ref --text-field id` still returns only the app's real accessibility ID and can be empty. Typing still requires an already focused, enabled, visible native `TextField` with `typeText`. Opaque identity does not add slider, AXPress or pinch support, and a Group alone does not prove a scroll area.

For a named Button in a moving list or after scrolling, prefer a fresh exact selector from a unique ID or label already observed in the UI. This resolves current native state instead of relying on an earlier layout. Keep refs for anonymous, duplicate or exact captured targets; use a fresh capture when their snapshot is stale. If the intended app owner must stay fixed, retain the snapshot ref or assert its captured PID with `--expected-pid`. A fresh selector is a separate current query; it does not transfer an old reference to a new app or replay failed input.

For agent `tap`, use `--label-contains <text>` for a case-sensitive literal substring or `--label-regex <pattern>` for Foundation regex syntax. Use anchors for a complete-label match; groups and alternation work, for example `--label-regex '^(Save|Done)$'`. Regex is case-sensitive by default; inline options apply. Choose one target only: exact ID/label/value, substring, regex, ref or coordinates. Apply an optional exact `--element-type` to explicit selectors.

Narrow any explicit selector with one `--frame 'minX=12.5,maxY=500.25'`. Use finite non-negative logical points with `minX`, `maxX`, `minY` or `maxY`; decimals work, relative fractions do not. Omitted edges use the current screen. Require the complete native frame inside that positive rectangle. Do not combine frame filters with refs or coordinates. All three new options require `--agent` and are supported only by `tap`.

Keep new queries nonblank and at most 512 UTF-8 bytes, regex patterns at most 128 bytes and frame specifications at most 256 bytes. Keep each native candidate text at most 4096 bytes and total candidate text at most 256 KiB. The existing 4096-node bound and shared 100 ms selection budget apply. Regex uses cooperative progress cancellation; compilation has a byte cap and invalid-pattern rejection, without compilation cancellation. Treat timeout, size, invalid-pattern, missing or ambiguous results as no-input failures; narrow the query. Require a fresh native-tree match and a unique exact native ID or label for guarded input. Never turn a pattern/frame result into cached coordinates. Retain snapshot freshness, PID, context, target and no-replay checks. Older brokers reject these new payloads instead of ignoring filters.

## Native object references

A control need not expose an app accessibility ID to have an available ref. A complete native read can prove one exact native process/object UID for an eligible control. The full tree and exact UID remain private to the broker and native input code. Callers use the same snapshot ID and `eN` ref; there is no UID argument and no new PID lookup. `read-ref --text-field id` returns the real app ID, which can remain empty.

The broker retains one table in RAM per device/user/Xcode/protocol endpoint across separate CLI calls. It does not persist that table. A new capture replaces it; successful input normally supplies the replacement capture. The original 60-second expiry is not renewed by validation, paging or reads. Other callers share this table. App, native object, display, fold/rotation/layout changes, expiry or broker restart can invalidate refs. Refresh when required and use the new refs; never replay completed or uncertain input.

Use only the row's advertised actions. Opaque input requires a fresh complete tree, one occurrence of the exact object, current state and the existing native hit/context checks. Identity mode is fixed at publication. A failed opaque check does not retry with semantic selectors or coordinates. Incomplete identity traversal preserves existing semantic controls; affected refs can be unavailable with `capture.unavailableReferences[ref]: "nativeIdentityIncomplete"`. A displayed frame or path never substitutes for native identity.

A `typeText` ref still requires an already focused, enabled, visible native `TextField`. An anonymous field can use its unique native object; a present duplicated or malformed field ID retains its current refusal. Before each key DOWN, AXe reads the exact current field and checks focus; UP/cleanup still release owned keys after interruption. No implicit focus or atomic OS recipient guarantee is added. Public selected `--focus-id` remains exact-ID only.

Opaque identity does not authorize slider adjustments, AXPress or pinch. A Group alone does not prove scrolling; use an advertised scroll ref with the existing fresh hit/ancestry checks. Native-ID batch steps need real app IDs, never object UIDs. Use matched CLI, broker and runtime versions.

An opaque `tap --tap-style physical` can use its fresh frame when successful point reads return an unmapped representation. It requires stable complete trees, a unique target, no competing tap/text control, stable point evidence and unchanged device context. Numeric and compound native values refuse this route. Automatic/simulator styles, holds, double taps and gestures keep strict point checks. This is one planned input path, with no retry or AXPress fallback. Delivery/release receipts do not prove the app effect; an overlay missing from every tree can intercept a touch. Inspect the replacement capture.

## Read custom-action names

Reading and navigation captures can include `capture.customActionGroups`: an array of `{ "refs": ["e2", "e7"], "names": ["Delete"] }` groups. A group assigns the same ordered read-only name preview to each listed ref. Arrays group only when all name bytes and their order match. Names and duplicates are preserved; a group does not make its refs the same control. Groups and refs follow first published row order. Every metadata ref appears once and belongs to a row in this page. There is one adaptive form, including singleton groups; adaptive captures do not return the `customActions` map. This is the first released optional metadata contract in the public adaptive schema, version 2.

Full canonical captures retain the `capture.customActions` ref-to-preview map in base schema version 1. Both forms have at most four names per preview and at most 96 Unicode scalars per name. A clipped name ends with an ellipsis. `capture.truncatedCustomActionRefs` identifies refs with omitted or clipped names. Identical clipped previews do not prove identical complete lists. Full view has the same preview bound; it does not return an unbounded name list. Adaptive groups share the 16 KiB capture budget. Follow the normal row cursor for later controls.

Grouping reduces repeated names without removing child refs. Text output uses the same groups.

Names are information, not input actions. A name such as `Delete` does not add `tap`, does not permit named execution, and does not bypass identity, focus or hit checks. Use only the row's advertised input actions. The separate raw legacy hierarchy output is unchanged.

To read every exact name, use the current snapshot and ref:

```bash
axe describe-ui --agent --udid <UDID> --snapshot-id <UUID> \
  --read-ref <REF> --text-field custom-actions --text-offset 0 --text-limit 1024
```

Concatenate `data.detail.text` chunks in cursor order, then decode the result as a JSON string array. Offsets count Unicode scalars in this JSON text, including its punctuation and escapes. Preserve names, order and duplicates; do not split a preview on separators. A ref with no custom names returns `[]`. The existing fresh app, tree, display and expiry checks apply to every chunk. A name change invalidates the snapshot for input even if the controls did not move. Readback does not renew expiry or grant input authority. This metadata requires a matched CLI, broker and native frameworks.

## Change view on the current snapshot

When the current screen is unchanged and you need visible text, request reading on the same snapshot.

```bash
axe describe-ui --agent --view reading --snapshot-id <CURRENT_UUID> --row-offset 0 --udid <UDID>
```

This performs a fresh native check. After validation, the snapshot ID, references and original expiry stay the same. If the screen changed, the reply is a `screenChanged` refusal whose capture is a new snapshot starting at its first row: discard rows from the old snapshot, never combine its refs with the new one, and page the new snapshot from there. A plain describe that returns a new snapshot ID replaces the previous table.

## Read complete fields and page controls

The compact reading and navigation views limit displayed cells to 160 Unicode scalars. A clipped cell contains 159 scalars followed by an ellipsis and has a `capture.truncatedFields` entry with its reference and field. `displayScalarLength` is the scalar count of the complete display cell; it is not a raw-field cursor. This does not shorten the native label, value or ID used for matching. Read the exact field through the same snapshot:

```bash
axe describe-ui --agent --udid <UDID> --snapshot-id <UUID> \
  --read-ref <REF> --text-field id
axe describe-ui --agent --udid <UDID> --snapshot-id <UUID> \
  --read-ref <REF> --text-field label --text-offset 0 --text-limit 1024
```

`--text-field` accepts `label` (default), `value`, `id` or `custom-actions`. Offsets count Unicode scalars, not UTF-8 bytes or displayed characters. `--text-offset` is non-negative; `--text-limit` is 1...4096 and defaults to 1024. `data.detail` contains the exact raw text chunk, `totalLength`, the requested `offset`, and `nextOffset` when more text remains. It also returns the native frame and actions. Use the returned cursor for the next chunk; do not calculate it from a displayed ellipsis. Raw whitespace and pipe characters are preserved in field readback. `data.detail.totalLength` counts scalars in the exact native field and can differ from `capture.truncatedFields.displayScalarLength` when the row uses the pipe display convention. Scalar boundaries can split combining sequences; follow the returned raw-field cursor rather than a displayed-character count.

A read requires `--snapshot-id` and `--read-ref`, without hash polling, row paging, an action ref or coordinates. It performs a fresh app, native-tree and selected-display check. Expired, replaced or changed snapshots reject without input. Reading does not renew the snapshot's 60-second lifetime. A field can be read even when it has no unique selector for input; readback does not authorize a tap.

If the current page contains the required control or fact, use it. If a required row is missing, reuse the snapshot, the current view and the returned `page.nextOffset` in `--row-offset`. The full view calls this cursor `nextRowOffset`. One global page contains at most `--row-limit` rows (1...64, default 64), in target, scroll and text order. `--row-offset` is in 0...12288. Compact filtering and row merging can return fewer displayed rows; do not derive a cursor by counting them. The compact capture has a 16 KiB JSON budget, which can end a page early. Action, error, batch and recovery fields add to the whole result; 16 KiB is the capture budget. If the required row is still missing, follow the next explicit cursor when one is present. Navigation omits a continuation when only observation text remains; reading/full keep it. Without a cursor, an initial compact page omits native `offset` and `total`; a terminal reply to an explicit nonzero offset keeps that offset for request correlation and omits `total`. A continued compact page keeps its native offset, total and next cursor. Native totals are not displayed-row counts. When the default-size reading view has room, AXe can fill it from one more canonical page of the same snapshot, with no extra read. Explicit page requests still validate the current UI. A compact capture can omit `page` when no page metadata is needed. Full view keeps the base row offsets and totals. Refs keep their original snapshot identity; filtering and paging do not renumber them.

When the first canonical page contains no scroll rows but the same stored snapshot has scroll areas, compact views can add `capture.areas`: `preview: true`, at most four distinct RS1 rows in `rows`, and `hasMore`. These are read-only discovery rows from the existing snapshot, not another page or a complete area list. Their refs use the same snapshot and normal action checks. The preview uses only unused space within the existing 16 KiB capture budget. It does not replace or reorder canonical rows, change their cursor, or perform another accessibility read. Use `page.nextOffset` if you still need a canonical row. A false `areas.hasMore` applies to the area preview. Full/base and legacy output omit the preview.

## Drag a control by its agent reference

Use `axe drag --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --end-x <X> --end-y <Y>`. Choose an available reference from the current `targets` or `scroll` rows; page the capture if needed. This action does not accept `sliderEndpoint` rows or add pad references. The runtime resolves the exact identity chosen for that ref and derives the start from its fresh frame centre. It checks the native point hit and target ancestry again before DOWN. Never supply cached start coordinates.

Use decimal logical points for the explicit endpoint. It can leave the original frame, but both endpoints must be inside the selected display. This proves the start target, not an endpoint recipient or app effect. If the start is inside a nested scroll area, select that area. No reference, identity or hit failure falls back to coordinate input.

Keep the existing defaults: 0.6-second movement, 60 steps, and 0.05-second initial/final holds. Use finite duration in (0,10], 1...1000 steps, pre/post delays of 0...10 seconds and at most 20 seconds of total requested delay including holds. Admission shares the existing eight-second deadline and 4096-node/depth-64 tree bounds. Reject start coordinates, explicit selectors, mixed payloads and batch use. Retain context checks during input, owned release and no automatic replay. Refresh after failure or use the replacement capture after success. Use a matched CLI/broker; an older broker rejects the new drag action kind.

## Press and hold a control by its agent reference

Use `axe touch --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --down --up --delay 0.7`. Choose a current visible, enabled target reference that supports a complete hold. AXe reads its current target and activation point, then validates the point hit, app, screen and target again before touch down. It sends one complete physical touch.

Omit `--delay` for the existing 0.1-second physical press. An explicit delay must be finite and in (0,10] seconds. A delay requests contact duration; the app decides whether it is a long press. This action does not accept `sliderEndpoint` rows or add pad references. Coordinates, partial down/up, contact tokens and batch use reject. This does not add retained agent touches.

Keep the existing context-change detection, owned release, cache invalidation and no-replay rules. If folding or rotation interrupts input, read again and select the current reference. A changed layout is not permission to reuse the old point. Use the replacement capture after success, or refresh when it is unavailable. Check the real app effect separately. Older brokers reject the new hold action kind.

## Focus a field and type in one command

Use `axe type 'Hello' --agent --focus --udid <UDID> --snapshot-id <UUID> --ref <REF>` for a current tap-capable native TextField. The field must have a unique typed field ID or complete unique anonymous native identity usable by the keyboard path. This explicit option makes one guarded physical focus tap, reads the same field's actual focus and new value/frame baseline, then types. It can open the keyboard and move the insertion point. It does not clear or replace text and does not promise to append it. Default agent `type`, `--focus-id`, raw typing and immutable reference batches keep their existing focus requirements.

All text is checked before the tap: existing US mapping, 1...256 UTF-8 bytes and a complete bounded key sequence. The original snapshot, owner, display, pose, fresh target and point-hit guards still apply before focus. The explicit focus transition permits the same field's frame to change when the keyboard appears; the new frame must be finite, positive and inside the same display. The tap can change the value or selection normally; its actual post-focus value becomes the exact baseline before typing. Other identity/state facts stay bound. The broker retains the chosen semantic or opaque authority. No label/coordinate fallback or tap-only alias typing is allowed. Duplicated or malformed field IDs still refuse. Sibling index and parent-container changes do not change field identity during this explicit focus transition. The chosen field authority, observed field object ID/PID, type, actual focus, uniqueness and full display context remain bound; parent paths or container object IDs are not typing-recipient authority.

One response uses the existing batch receipt shape for two phases, tap then type. Check both steps and the replacement capture. If focus completes but typing fails, focus is still an input effect. A failed final observation retains completed receipts and requires refresh. Do not resubmit either completed or uncertain phase; there is no rollback or input replay. Native key cleanup and quarantine are unchanged.

Observed native object ID/PID evidence is retained across the fresh pre-tap and post-focus/full rebaseline reads when available. Later semantic per-key reads keep the existing exact typed ID, owner, focus and context checks; they do not report or assert the incidental object ID. Anonymous fields keep native per-key identity checks. One broker reservation spans the command, but native input leases remain per phase. This is not atomic OS recipient control. Requires a matched CLI and broker.

## Press one key on a focused field reference

Use `axe key 42 --agent --udid <UDID> --snapshot-id <UUID> --ref <REF>` for Backspace. Choose a current `typeText` reference for an already focused, enabled, visible native TextField. AXe does not focus the field. Keycodes remain HID codes in 0...255, not Unicode characters.

This sends one complete default key down/up without an added hold. Explicit `--duration`, `--focus-id`, other targets and batch use reject. This single-key command does not add retained keys or key sequences; modifier shortcuts use `key-combo` below. Raw and selected key commands keep their existing behavior.

The runtime checks the snapshot, app, display and field again, then uses the existing keyboard owner. It checks focus/PID and current context before key down; key up and cleanup can still release after focus loss. Focus reads and HID input are separate OS operations, not an atomic recipient guarantee. The shared eight-second admission budget and focused-field read bounds remain. A stale reference sends no input. Refresh after failure; use the replacement capture after success. Never replay uncertain input. Older brokers reject the new keyPress action kind.


Keyboard input keeps the exact observed field target before the first owned key. During the same keyboard operation, its value and editing frame may change, for example when a clear button appears. Before each later key down, AXe reads the current uniquely identified, focused TextField and requires the same chosen field identity, type, label and PID, explicit enabled/non-hidden focus state, and positive finite bounds inside the selected display. Boot, display, hinge and rotation checks remain. This keyboard-only rule supplies no coordinates and does not change tap, drag or slider target checks. Partial input is never replayed.

## Send a modifier shortcut to a focused field reference

Use `axe key-combo --modifiers 225 --key 4 --agent --udid <UDID> --snapshot-id <UUID> --ref <REF>` for Shift+A. Choose a current `typeText` reference for an already focused, enabled, visible native TextField. The command does not focus it.

Supply 1...8 distinct modifier HID codes in 224...231 and one different key in 0...255. AXe presses modifiers in the given order, presses and releases the target key, then releases modifiers in reverse order. This is one complete sequence with no added delay. Duplicate modifiers, a target already held as a modifier, mixed targets, focus-ID override, timing override and agent batch use reject. Raw and selected key combinations keep their existing behavior.

The separate `keyCombo` request kind leaves the strict single-key `keyPress` contract unchanged. Use a matched CLI and broker; older brokers reject it. Snapshot, target, PID, display and per-key focus checks use the existing keyboard owner and unchanged eight-second admission budget. Owned key-up cleanup can release after focus loss or context change. Focus reads and input are separate OS operations; do not assume atomic recipient control. Refresh after failure or use the replacement capture after success. Never replay uncertain input.

## Send a key sequence to a focused field reference

Use `axe key-sequence --keycodes 42,42 --agent --udid <UDID> --snapshot-id <UUID> --ref <REF>` for two Backspaces. Choose a current `typeText` reference for an already focused, enabled, visible native TextField. The command does not focus it.

Supply 1...100 HID codes in 0...255. Each key is pressed and released before the next. Optional `--delay` is finite in 0...5 seconds, defaults to 0.1, and applies only between keys. Total requested delay cannot exceed 20 seconds; the existing 1024-event bound and eight-second admission budget remain. This command does not hold modifiers across keys; use `key-combo` for shortcuts. Focus-ID overrides, other targets, retained keys and agent batch use reject. Raw and selected sequences keep their behavior.

The separate `keySequence` kind uses a versioned broker endpoint; older requests reject. Native frameworks and strict single-key/shortcut contracts are unchanged. Snapshot, target, PID, display and per-key focus checks use the existing keyboard owner. Key-up cleanup can release after focus loss or context change. Focus reads and input are separate OS operations, not atomic recipient control. Refresh after failure or use the replacement capture after success. Never replay uncertain input.

## Move a slider to its minimum or maximum

Use `axe slider --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --endpoint minimum` or `--endpoint maximum`. Choose a current `sliderEndpoint` target row. Only visible, enabled native Sliders with a positive finite frame and a unique exact ID or label receive that row. The row does not prove native domain or adjustment support; the request checks both before an action.

The native worker checks the cached screen, current app/display context, slider identity, label, frame, value and readiness before the first adjustment. Each fresh full tree checks the slider identity and inherited visibility through the same snapshot rules used for target rows. Every read and adjustment also checks the owned native slider again. Only an adjustment returned by this operation permits the original cached value to change; the next action still checks its expected current value and original numeric domain. There is no fallback to a coordinate drag. The existing limits remain 20 actions within 15 seconds, with settled endpoint reads at 0.6 and 5 seconds.

Read `action.slider` for the semantic action count, delivery, endpoint and bounded numeric samples. Zero HID events does not mean zero semantic adjustments. An already reached endpoint can complete with zero actions. Verify the app value and callback separately; native adjustment and the app response are separate operations. Refresh after failure or use the replacement capture after success. Never replay an uncertain action.

Selectors, type overrides, non-default polling and agent batch use reject. For standalone percentages through the same row, read [slider percentage control](slider-reference.md). Raw percentage sliders and selected selector endpoints keep their behavior. Slider rows do not add tap, drag or hold support. Use a matched CLI and broker with the required native frameworks. Older brokers reject this kind.

## Double-tap a control by its agent reference

Use `axe gesture double-tap --agent --udid <UDID> --snapshot-id <UUID> --ref <REF>`. Choose a current visible, enabled target with an available `tap` action. AXe resolves the fresh native activation point and checks the target and point hit before the first touch down.

Defaults are `--hold 0.06` per tap and `--interval 0.1` from release to the next down. Each must be finite and in (0,10] seconds. Pre/post delays default to zero and must be finite in 0...10; total delay, including both holds and the interval, is at most 20 seconds. The existing target admission budget remains unchanged. Coordinates, other geometry, dimension overrides, duration/delta and batch use reject. Pinch has its separate contract below.

The existing selected double-tap builder, context checks and owned release send two complete taps. The target is checked before input; the app can still change between taps. Do not claim a fixed recipient or double-tap recognition from delivery alone. Check the app callback or visible effect separately. Use the replacement capture or refresh after input; never replay uncertain input. Raw presets and selected coordinate gestures are unchanged. Use a matched CLI and broker.

## Pinch inside an area by its agent reference

Use `axe gesture pinch --agent --udid <UDID> --snapshot-id <UUID> --ref <REF> --radius 24 --scale 1.5`. Choose a visible, enabled Other, ScrollView or List area with a unique native ID or label and a positive finite frame. New eligible areas appear as `pinchWithin` target rows; existing target and scroll rows keep their actions. Eligible area references from those rows can also pinch. A row does not prove that the app has a pinch recognizer. A pinch row does not advertise another action; existing action checks still apply.

AXe derives the centre from the fresh area frame. Both horizontal starts are centre X plus/minus radius; both ends use radius times scale. Radius is in logical points. Radius and scale must be finite and positive; scale 1 rejects. Keep both complete paths inside the area and current display. Default duration is 0.6 seconds and delta 5 logical points. Duration is finite in (0,10], delta in (0,200], each pre/post delay in [0,10], total at most 20 seconds, with at most 500 movement segments and 1024 events. Coordinates, second references, other gesture options, dimension overrides, retained contacts and both batch forms reject.

The current snapshot, PID, target and device context must match. In one shared eight-second admission budget, AXe reads both native starting-point hits, one fresh full tree and both confirmed hits. Each hit must belong to the same current area; a nested scroll area requires its own reference. The actual first two-contact DOWN must match both checked coordinates. No DOWN occurs if either check fails. Existing swipe and drag admission use the same hierarchy rules.

During motion, existing boot, display, hinge, rotation and geometry checks stop stale input and release both owned contacts. Current app PID is checked before input, not throughout motion. Sequential reads and input do not provide an atomic recipient guarantee. Verify the app callback separately; requested physical scale does not guarantee the same recognizer scale. Refresh after failure or use the replacement capture; never replay uncertain input. Raw presets and selected coordinate pinch remain unchanged. Use a matched CLI and broker.

## Run a small ordered agent batch

Use `axe batch --agent --udid <UDID> --file steps.json`, or pass the same document with `--steps-json '<JSON>'`. Choose exactly one source. The file must be regular UTF-8 JSON; inline JSON needs no file. Both forms use the same parser and accept 1...8 tap/type steps with at most 16384 UTF-8 bytes. Inline JSON is not interpreted as shell steps and adds no retry. Choose native IDs or one published reference table for the whole document.

For refs, capture the screen first and copy its snapshot ID and refs:

```json
{"snapshotID":"3FF70D78-26DA-4314-B37B-4CB57D2A1A85","steps":[{"action":"tap","ref":"e12"},{"action":"tap","ref":"e19"}]}
```

The example UUID and refs are placeholders for one real capture. Before input, AXe validates the complete document, all refs, their actions and each target's chosen exact identity. Each step reads fresh native state and resolves its original target again. The saved app PID and complete boot/display/hinge/rotation/geometry context must match. Native hierarchy, control identities, frames, focus, enabled state and visibility remain bound. Hidden nodes, nodes wholly off the display and empty inert groups are not part of that layout, as for single-action admission. Ordinary leaf StaticText outside controls may change its text and glyph bounds; control values may also change. Control and ancestor frames, control labels and descendant text inside controls remain identity evidence. A layout change stops later input. Refs never become cached coordinate authority.

Use reference batches for actions on controls already present in one stable layout. A plain type ref must identify an already focused native TextField with an available `typeText` action. A type step with `"focus": true` instead takes the field's `tap` ref and makes the guarded focus tap of [`type --focus`](#focus-a-field-and-type-in-one-command) before typing; the field needs a unique typed field ID or unique anonymous native identity, and is found by that identity wherever earlier steps moved it, with only its position changed. A completed focus step is a declared layout change: every later target must be the same control on the new screen (type, ID, label, value, process and any native identity) with only its position changed, still enabled, shown and inside the display, and that screen, read until two reads in a row match (at most four), becomes the layout later steps must keep. Its receipt has kind `focusAndType` and counts both phases' events. A new sheet, navigation layout or app requires a separate inspection. All initial refs are checked before the first step, so an invalid later ref does not allow earlier input. One replacement capture is published at the end. Use its new snapshot ID and refs after success.

The existing native ID form remains:

```json
{"steps":[{"action":"tap","id":"field"},{"action":"type","id":"field","text":"AB"},{"action":"tap","id":"save"}]}
```

It discovers the frontmost app or SpringBoard in its initial capture. It resolves each exact ID from the current snapshot and requires a usable replacement after each action before the next step. Optional positive `--expected-pid` asserts the same captured owner for either form. IDs must be exact, nonblank and at most 4096 UTF-8 bytes. A type step needs the field to be focused when it starts. Type text keeps the existing US mapping, 1...256-byte bound and complete keyboard limits.

Every step has exactly one `id` or `ref`. Ref documents require `snapshotID`; ID documents reject it. Mixed forms and unknown JSON fields reject. Type requires literal `text` and accepts an optional Boolean `focus`; tap rejects both. Coordinates, arbitrary selectors, retained input, device actions, nested batches, text file/stdin, delays and continued errors are unsupported in this JSON contract. Ordinary and selected line-based batches retain their syntax and coordinate behavior.

When no step sent input, a reference batch retries on a new table once every target is unchanged, or is the same control holding still across two reads about 150 ms apart after a move, as a single refused action does. A batch stopped by a step that sent no input returns the current screen as a capture with the step receipts; choose the remaining steps from its snapshot ID. One broker reservation spans the batch; native input ownership remains per action. This is not a transaction or exclusive OS control. Failure, cancellation, uncertain cleanup, missing final capture or changed context stops later steps. Earlier input remains. The base `data.batch` records total/completed counts, ordered step index/status/request ID/action receipt, stopped index, and `replayed: false`/`rolledBack: false`; compact success uses the smaller contract below. A completed action can be followed by failed capture. Inspect its receipt; do not repeat it. If the reply is lost, the outcome is unknown. Do not resubmit the batch. Existing disconnect cancellation and owned release do not undo input.

Each operation keeps its native deadline. The reply wait allows up to 120 seconds per step plus one capture, at most 1080 seconds for eight steps. This is a transport wait bound, not a retry or longer native timeout. Use matched CLI, broker and runtime versions.

After complete success with a refreshed final capture, reading/navigation batches keep `completedSteps` and ordered step `index`, `action`, `status`, input `outcome` and `enqueuedEventCount`, and omit `totalSteps`. Every compact batch, complete or stopped, omits per-step request IDs, cache and context, `replayed`/`rolledBack` and the default `cleanup`; a stopped batch keeps `totalSteps` and `stoppedAt`. Receipt `kind` is omitted only when it equals the step action; `typeText` and `focusAndType` remain distinct from `type`. Use the top-level `data.cache` and capture. Full view keeps the complete base result. Select full view before input when request IDs are required; never repeat input to expand a reply.
