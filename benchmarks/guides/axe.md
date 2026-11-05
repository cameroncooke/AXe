---
name: axe-benchmark
description: Use when running an assigned UI benchmark through the pinned AXe CLI on the existing simulator.
---

# AXe benchmark

Use only the assigned CLI for UI reads and input. Ground each target in public UI output.
Do not read source, app storage, defaults, databases or hidden hooks to answer UI checks.
Build source may be used only for the requested build. Do not change app or tool source.
Use normal app controls. Do not infer an app effect from transport success.
Do not replay completed or uncertain input. Inspect action, cleanup and cache results.
Choose the best valid workflow; no route, call sequence or call count is required.
One Bash call must run one CLI command. Do not use pipes, loops, substitutions,
background work or joined commands. Public AXe batches are allowed. Use Write only
for batch payloads under the run directory. Read can inspect a returned screenshot.

The assigned CLI is `{{EXECUTABLE}}`. Do not use the installed alias.
The existing simulator is `{{UDID}}`.
Use `--agent` for supported UI reads and input. No caller PID or raw hierarchy setup
is required. Help may explain supported arguments. Keep all actions on this device.

## Observe and reuse

Pass `--view navigation` when the next decision needs controls or their values.
It applies to describe-ui, tap, type, swipe and batch. For example, use
`describe-ui --agent --view navigation --udid <UDID>` to find controls.
Pass `--view reading` when you need visible text or facts, including final checks.
Before input, choose the view for the next task step. If the action reveals text
you need to verify, pass `--view reading` on that action and check its returned
capture. Use navigation when the next step only needs controls or their values. `--view full` uses the base schema.
A compact row is `ref|actions|role|label|value`; use only an advertised action.
Navigation preserves control rows. If you need more controls, use its returned
page cursor or scroll the relevant area. Use reading or full when you need text
that navigation omits. Use exact-field reads or a screenshot when needed.

After an action returns `data.capture` and `data.cache.requiresRefresh` is false,
use its snapshot ID and refs. Do not repeat describe solely for those rows.
A new snapshot ID replaces the previous one even when the screen hash matches.
To change the current capture to reading, use `describe-ui --agent --view reading
--snapshot-id <CURRENT_UUID> --row-offset 0 --udid <UDID>`. On validation, this
keeps its ID, refs and expiry. If validation fails, refresh and use the new refs.
Refresh when no capture is returned, the cache requires it, the app or layout changes,
references expire, or a later condition must be observed. Keep failures in the record.
For an unchanged poll, use `describe-ui --agent --since-screen-hash <hash> --udid <UDID>`.
This checks the current UI and does not extend reference expiry.

If the current page contains the required control or fact, use it. A cursor
only means that more rows are available. If a required control or fact is still
missing, use `describe-ui --agent --view <CURRENT_VIEW> --snapshot-id <UUID>
--row-offset <NEXT_OFFSET> --udid <UDID>`.
Copy `capture.page.nextOffset` (full view: `nextRowOffset`); never calculate it from
row count. For exact field text, use `describe-ui --agent --snapshot-id <UUID>
--read-ref <REF> --text-field label --udid <UDID>`. Choose value or id instead for that field.
Follow `data.detail.nextOffset` with `--text-offset` for another bounded chunk.
If no row cursor is returned, stop paging; a native total or displayed row count is
not a request for another read. An absent cursor does not override a refresh warning.
A row page can omit whole sections. In full view, an empty page-local `scroll` array
does not mean no scroll area exists when `scrollCount` is positive. Follow the
returned `nextRowOffset` with `--row-offset` before concluding that a needed area
is absent. Reading/navigation use `capture.page.nextOffset`; do not invent offsets.

Labels and values preserve spaces and newlines. Do not trim them when checking or completing text. After partial typing, use a guarded --read-ref value read when the exact current text is unclear; do not guess or replay the whole input.

## Act on current controls

For a named Button that can move after a swipe or animation, prefer a fresh selector
from an observed unique ID or label: `tap --agent --view navigation --label <EXACT_LABEL>
--element-type Button --udid <UDID>`. Exact `--id` or `--value`, label substring
`--label-contains`, and `--label-regex` are separate target choices. A selector reads
current native state and must resolve uniquely; narrow it with type or the documented
logical-point frame filter. Do not invent IDs, labels or cached coordinates.

For stable, anonymous, duplicate or exact captured targets, choose the tap view:
- Controls next: `tap --agent --view navigation --snapshot-id <UUID> --ref <REF> --udid <UDID>`.
- Visible text next: `tap --agent --view reading --snapshot-id <UUID> --ref <REF> --udid <UDID>`.

Keep refs when the same captured app/object
identity is required; refresh after a stale-ref refusal. A fresh selector is a new
query, not permission to transfer an old ref across apps or replay input. Inspect
the returned cache and input receipts for either route.

For an already focused TextField with typeText, use `type <TEXT> --agent --view navigation
--snapshot-id <UUID> --ref <REF> --udid <UDID>`. For a current tap-capable TextField,
`type <TEXT> --agent --view navigation --focus --snapshot-id <UUID> --ref <REF> --udid <UDID>` makes
one guarded focus tap, then checks the same field and types. It does not clear or
replace existing text. Inspect both phase receipts; completed focus remains an effect
if typing fails. Default type does not focus. Use fresh refs after keyboard changes.

Compact captures can include `capture.areas` with `preview: true`, `hasMore` and
up to four scroll-area rows. Use an area that advertises swipe. A canonical row
for the same ref can advertise pinch only; that does not remove swipe from its
area preview. Keep the returned snapshot ID. This preview does not replace the
canonical rows or their page cursor. Follow the real cursor when more areas or
controls are needed; do not infer that an omitted area is absent.

Swipe a returned area with `swipe --agent --view navigation --snapshot-id <UUID> --ref <REF>
--direction up --distance 0.8 --udid <UDID>`. Direction means finger motion.
Use the relevant inner scroll area. Observe whether the expected content moved.

A reference batch takes one snapshot and 1 to 8 complete tap/type steps:
`{"snapshotID":"<UUID>","steps":[{"action":"tap","ref":"<REF>"}]}`.
Use inline `batch --agent --view navigation --steps-json <JSON> --udid <UDID>` for a short payload
without a separate Write call; use `--file <PATH>` for a saved payload.
Use refs from one stable layout. Batch compatible taps while later targets stay valid;
a final tap can leave that layout, subject to the task's observation rules.
A type step needs an already focused typeText field.
A new keyboard, sheet or screen can stop later steps. Native-ID batches take real
observed IDs in their separate documented form and resolve each step afresh; do not
mix IDs with refs. Read completed steps and the replacement capture before continuing.
Earlier effects are not rolled back and no failed batch is replayed.

Before a final Save, Done or Submit action that leaves a form, complete every field
the task requires on that form. An app Save/Done can commit data; do not use it only
to hide the keyboard when that commit is not yet permitted. Use a distinct observed
keyboard-dismiss control when available, or inspect returned pages for the relevant
scroll area. Keep the task's save and read-only verification rules; do not enter Edit
or change saved data when the task forbids it.

Coordinates remain an explicit agent option with a current snapshot and logical UI
points derived from a fresh screenshot of the same display/layout. Do not use them
as an automatic fallback for unavailable refs, and do not replay an action.

If a screenshot is needed, use the assigned tool's supported screenshot command and Read the image file path it returns. Use its native image format and location. Do not copy, convert, rename or move an image to meet a benchmark path. You may Read the assigned tool's returned screenshots and Bash/tool-output overflow text files that contain its public output. This does not permit reading app source, app storage or unrelated data.
