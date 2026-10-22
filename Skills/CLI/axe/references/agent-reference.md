# Agent mode reference

## Optional agent mode

Use `--agent` on `describe-ui`, `tap`, `type`, `swipe`, `drag`, `key` and complete reference `touch` for stateful RS/1-style JSON. Keep ordinary commands without the flag when raw accessibility output or existing coordinate semantics are required. Do not confuse the flag with the autonomous `axe agent <goal>` command; the flag needs no model key.

1. Capture with `axe describe-ui --agent --udid <UDID> --expected-pid <PID>`. Use the current PID; let capture discover the active display, or supply the explicit selected pair.
2. Read the returned snapshot ID and `ref|action|role|label|value|id` rows. Use bounded capture paging for omitted rows. A matching `--since-screen-hash` still performs a fresh read. Cache reuse also checks a separate exact native fingerprint. The compact RS/1 `screenHash` uses normalized data; a matching hash alone does not prove unchanged raw UI.
3. Pass `--snapshot-id <UUID>` with each reference or coordinate action. For example, use `axe tap --agent --udid <UDID> --expected-pid <PID> --snapshot-id <UUID> --ref <REF>`. Never reuse an ordinal ref from a different snapshot.
4. For text, first focus the field, refresh, then use `type <TEXT>` with its current ref. Retain the US keyboard mapping, 256-byte bound and per-key focus checks. For a scroll area, use `swipe --agent --udid <UDID> --expected-pid <PID> --snapshot-id <UUID> --ref <REF> --direction up --distance 0.5`; direction describes finger movement.
5. After input, use the replacement capture or read again. Treat changed UI, boot, PID, display, hinge, rotation or geometry as stale. Refresh and resolve again after changes made outside AXe as well. Do not retry uncertain input.
6. Check actual app effects separately. A transport receipt is not app-effect proof. Other commands do not yet accept `--agent`; use their existing documented interfaces.

Keep agent captures within 4096 nodes and depth 64. The same `--row-offset` and `--row-limit` values (`rowOffset` and `rowLimit` in JSON) apply separately to the `targets`, `scroll` and `text` sections, with at most 64 rows per section. Agent typing and key input limit their focused-field read to 512 nodes, depth 32 and 1 MiB of field output; its shared eight-second admission deadline remains unchanged. For nested scrolling, select the innermost scroll area that receives the gesture.

Visible controls without a unique native ID or label remain in the capture with their action marked unavailable. AXe offers `typeText` only for a currently focused native `TextField` with a unique exact ID; otherwise it offers `tap` when a unique native ID or label can resolve the field.

For agent `tap`, use `--label-contains <text>` for a case-sensitive literal substring or `--label-regex <pattern>` for Foundation regex syntax. Use anchors for a complete-label match; groups and alternation work, for example `--label-regex '^(Save|Done)$'`. Regex is case-sensitive by default; inline options apply. Choose one target only: exact ID/label/value, substring, regex, ref or coordinates. Apply an optional exact `--element-type` to explicit selectors.

Narrow any explicit selector with one `--frame 'minX=12.5,maxY=500.25'`. Use finite non-negative logical points with `minX`, `maxX`, `minY` or `maxY`; decimals work, relative fractions do not. Omitted edges use the current screen. Require the complete native frame inside that positive rectangle. Do not combine frame filters with refs or coordinates. All three new options require `--agent` and are supported only by `tap`.

Keep new queries nonblank and at most 512 UTF-8 bytes, regex patterns at most 128 bytes and frame specifications at most 256 bytes. Keep each native candidate text at most 4096 bytes and total candidate text at most 256 KiB. The existing 4096-node bound and shared 100 ms selection budget apply. Regex uses cooperative progress cancellation; compilation has a byte cap and invalid-pattern rejection, without compilation cancellation. Treat timeout, size, invalid-pattern, missing or ambiguous results as no-input failures; narrow the query. Require a fresh native-tree match and a unique exact native ID or label for guarded input. Never turn a pattern/frame result into cached coordinates. Retain snapshot freshness, PID, context, target and no-replay checks. Older brokers reject these new payloads instead of ignoring filters.

## Drag a control by its agent reference

Use `axe drag --agent --udid <UDID> --expected-pid <PID> --snapshot-id <UUID> --ref <REF> --end-x <X> --end-y <Y>`. Choose an available reference from the current `targets` or `scroll` rows; page the capture if needed. This extension does not add pad or slider references. The runtime resolves an exact unique native ID or label and derives the start from its fresh frame centre. It checks the native point hit and target ancestry again before DOWN. Never supply cached start coordinates.

Use decimal logical points for the explicit endpoint. It can leave the original frame, but both endpoints must be inside the selected display. This proves the start target, not an endpoint recipient or app effect. If the start is inside a nested scroll area, select that area. No reference, identity or hit failure falls back to coordinate input.

Keep the existing defaults: 0.6-second movement, 60 steps, and 0.05-second initial/final holds. Use finite duration in (0,10], 1...1000 steps, pre/post delays of 0...10 seconds and at most 20 seconds of total requested delay including holds. Admission shares the existing eight-second deadline and 4096-node/depth-64 tree bounds. Reject start coordinates, explicit selectors, AX preparation, mixed payloads and batch use. Retain context checks during input, owned release and no automatic replay. Refresh after failure or use the replacement capture after success. Use a matched CLI/broker; an older broker rejects the new drag action kind. Recorded reference drags, rejections and fold release/fresh tap passed. Other lifecycle checks remain open.

## Press and hold a control by its agent reference

Use `axe touch --agent --udid <UDID> --expected-pid <PID> --snapshot-id <UUID> --ref <REF> --down --up --delay 0.7`. Choose a visible, enabled reference with a unique native ID or label. AXe reads its current target and activation point, then validates the point hit, app, screen and target again before touch down. It sends one complete physical touch.

Omit `--delay` for the existing 0.1-second physical press. An explicit delay must be finite and in (0,10] seconds. A delay requests contact duration; the app decides whether it is a long press. No new pad or slider references are exposed. Coordinates, partial down/up, contact tokens, AX preparation and batch use reject. This does not add retained agent touches.

Keep the existing context-change detection, owned release, cache invalidation and no-replay rules. If folding or rotation interrupts input, read again and select the current reference. A changed layout is not permission to reuse the old point. Use the replacement capture after success, or refresh when it is unavailable. Check the real app effect separately. Older brokers reject the new hold action kind. Recorded default press, timed field hold, rejection and coordinate-compatibility checks passed. Normal folding released the held touch and a fresh outer-screen reference tap passed. Other roles, positions and interruptions remain open.

## Press one key on a focused field reference

Use `axe key 42 --agent --udid <UDID> --expected-pid <PID> --snapshot-id <UUID> --ref <REF>` for Backspace. Choose a current `typeText` reference for an already focused, enabled, visible native TextField with a unique exact ID. AXe does not focus the field. Keycodes remain HID codes in 0...255, not Unicode characters.

This sends one complete default key down/up without an added hold. Explicit `--duration`, `--focus-id`, other targets and batch use reject. Retained keys, key sequences and key combinations are not added to agent mode. Raw and selected key commands keep their existing behavior.

The runtime checks the snapshot, app, display and field again, then uses the existing keyboard owner. It checks focus/PID and current context before key down; key up and cleanup can still release after focus loss. Focus reads and HID input are separate OS operations, not an atomic recipient guarantee. The shared eight-second admission budget and focused-field read bounds remain. A stale reference sends no input. Refresh after failure; use the replacement capture after success. Never replay uncertain input. Older brokers reject the new keyPress action kind. The isolated arm64 candidate passed 42 existing checks. On Duo outer portrait, Backspace changed AB to A, then A to empty after a fresh lookup; stale, wrong-app and unfocused references rejected without input. Raw and selected key routes also passed. Other keys, fields, orientations and transitions remain unverified.
