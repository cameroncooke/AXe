# AXe agent batch reference

Use this reference when sending several taps or types in one `axe batch --agent` call.

## When to batch

Each separate call costs a full agent turn. Batch two or more actions you have already planned when:

- every target is a control in the current capture, and
- you do not need to look at the screen between them.

Filling a form's fields, toggling several switches, choosing units or options in a settings sheet and selecting several list items are typical. The last step may leave the screen, for example Close, Save or Next. Use separate calls when one action's result decides the next.

## Send a batch

Pass the steps inline:

```bash
axe batch --agent --view navigation --udid <UDID> --steps-json '{"snapshotID":"3FF70D78-26DA-4314-B37B-4CB57D2A1A85","steps":[{"action":"tap","ref":"e12"},{"action":"tap","ref":"e19"}]}'
```

or save the same JSON and pass `--file steps.json`. Choose exactly one `--file` or `--steps-json`. Both use the same JSON parser, 16384-byte limit, eight-step limit and native checks. Inline JSON is not shell step syntax and adds no retry. Replace the sample snapshot ID and refs with one real capture. Quote JSON for the calling shell; AXe preserves decoded literal text.

`--view navigation`, `reading` (the default) or `full` chooses the content of the final capture, as for other agent commands. It is a batch option, not a step field.

### Published references

First capture the screen with `axe describe-ui --agent --view navigation --udid <UDID>`. Use its snapshot ID and available refs:

```json
{"snapshotID":"3FF70D78-26DA-4314-B37B-4CB57D2A1A85","steps":[{"action":"tap","ref":"e12"},{"action":"type","ref":"e7","text":"London"}]}
```

AXe checks all refs, actions and unique native identities before the first input. Each step then reads fresh native state. App ownership, boot, active display, hinge, rotation, geometry, hierarchy and control identities must still match. Control frames, focus, enabled state and visibility must stay unchanged. Ordinary text and control values can change after input. Standalone noninteractive StaticText glyph bounds may also change; control and ancestor frames stay fixed. A changed control label or text inside a control stops later steps. No cached point authorizes input.

Use this form for controls already present in one stable layout. It does not follow a new sheet or screen layout. A plain type step requires an already focused, visible, enabled native TextField with an available `typeText` action. A focus step, below, focuses its field itself. AXe returns one replacement capture after the batch ends, not after each step. Use its new snapshot ID and refs for later input.

### Focus steps

Add `"focus": true` to a type step to make the same guarded focus tap as `type --agent --focus`, then type:

```json
{"snapshotID":"3FF70D78-26DA-4314-B37B-4CB57D2A1A85","steps":[{"action":"type","ref":"e7","text":"Ada","focus":true},{"action":"type","ref":"e9","text":"Lovelace","focus":true},{"action":"tap","ref":"e12"}]}
```

Use the field row that advertises `tap`. The field needs a unique accessibility ID, or a unique anonymous native identity, as `type --focus` does. Before the tap, AXe finds the field by the identity bound when the batch started, wherever earlier steps' typing or keyboard moved it: it must be the same control (type, ID, label, value, process and native object), enabled, shown and inside the display, and the tap still passes the native hit check. After the tap, AXe waits for that field to report focus, then types with the usual per-key focus checks. It does not clear existing text. A field that is already focused can use a plain type step in the same batch.

A focus step is a declared layout change: its keyboard can move, reorder or scroll the screen. After it completes, every later target must be the same control on the new screen, with the same type, ID, label, value and process; only its position may change. It must still be enabled, shown and inside the display. The new screen, read until two reads in a row match (at most four reads), then becomes the layout that later steps must keep; the keyboard's suggestion bar can change just after typing. A control that changed or disappeared stops the batch before the next step sends input; a control the keyboard now covers is refused by that step's native hit check, also before input. The step's receipt has kind `focusAndType` and counts the events of both the focus tap and the typing.

### Native IDs

Steps can name exact accessibility IDs instead of refs:

```json
{"steps":[{"action":"tap","id":"field"},{"action":"type","id":"field","text":"AB"}]}
```

This form discovers the frontmost app or SpringBoard in its initial capture. It resolves each exact native ID in order and requires a usable replacement snapshot after each action. A type step needs the field to be focused when that step starts. Do not add `snapshotID` to an ID document or mix `id` and `ref` steps. Optional positive `--expected-pid` must match the captured owner in either form. Use only real IDs read from a capture.

## Results and limits

Only tap and literal type steps are accepted; `focus` is allowed only on type steps. Coordinates, retained input, device actions, nested batches, delays, stdin text and continued errors are unsupported.

Failure, cancellation, a changed layout or context, or uncertain cleanup stops later steps. Earlier effects remain. If no step sent input, AXe retries the whole batch once its targets are unchanged, or are the same controls holding still after a move. A batch stopped by a step that sent no input returns the current screen; plan the remaining steps from its snapshot ID. Inspect `data.batch` for completed steps, per-step receipts and the stopped index. Nothing is rolled back or replayed. A completed action can be followed by a failed final capture. If the reply is lost, the outcome is unknown; do not submit the batch again.

After complete success with a refreshed final capture, reading and navigation batches keep `completedSteps`, ordered step `index`, `action`, `status`, input `outcome`, `enqueuedEventCount`, `cleanup`, and top-level batch `replayed: false`. They omit duplicate `totalSteps`, `rolledBack: false`, per-step request IDs and receipt `replayed: false`. Receipt `kind` is omitted only when it equals the step action; `typeText` remains distinct from `type`. Failed, partial or uncertain batches retain these diagnostic fields. Full view keeps the complete base result. Select full view before input when request IDs are required; never repeat input to expand a reply.

Use matched CLI, broker and runtime versions. Read the [agent batch contract](agent-reference.md#run-a-small-ordered-agent-batch) for native limits and output fields.
