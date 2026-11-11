# AXe agent batch reference

Full contract for several taps or types in one `axe batch --agent` call.

## When to batch

Batch two or more planned actions when every target is in the current capture and you need not look between them (examples in SKILL.md Step 4). The last step may leave the screen (Close, Save, Next). Use separate calls when one result decides the next action.

## Send a batch

```bash
axe batch --agent --view navigation --udid <UDID> --steps-json '{"snapshotID":"<SNAPSHOT_ID>","steps":[{"action":"tap","ref":"e12"},{"action":"tap","ref":"e19"}]}'
```

- Pass the JSON with exactly one of `--steps-json` or `--file steps.json`: same parser, 16384-byte limit, 8-step limit and native checks.
- Inline JSON is not shell step syntax and adds no retry. Quote it for the calling shell; AXe keeps the decoded literal text.
- Take the snapshot ID and refs from one real capture.
- `--view navigation|reading|full` (default `reading`) sets the final capture's content. It is a batch option, not a step field.

### Published references

Capture with `axe describe-ui --agent --view navigation --udid <UDID>`, then use its snapshot ID and refs:

```json
{"snapshotID":"<SNAPSHOT_ID>","steps":[{"action":"tap","ref":"e12"},{"action":"type","ref":"e7","text":"London"}]}
```

- Before the first input, AXe checks all refs, actions and unique native identities. Each step then reads fresh native state; no cached point authorizes input.
- Must still match: app ownership, boot, active display, hinge, rotation, geometry, hierarchy, control identities.
- Must not change: control and ancestor frames, focus, enabled state, visibility.
- May change: ordinary text and control values after input; glyph bounds of standalone noninteractive StaticText.
- A changed control label or text inside a control stops later steps.
- For controls already in one stable layout; it does not follow a new sheet or screen layout.
- A plain type step needs an already focused, visible, enabled native TextField that advertises `typeText`. A focus step focuses its own field.
- One replacement capture returns when the batch ends, not per step. Use its snapshot ID and refs for later input.

### Focus steps

`"focus": true` on a type step makes the same guarded focus tap as `type --agent --focus`, then types:

```json
{"snapshotID":"<SNAPSHOT_ID>","steps":[{"action":"type","ref":"e7","text":"Ada","focus":true},{"action":"type","ref":"e9","text":"Lovelace","focus":true},{"action":"tap","ref":"e12"}]}
```

- Use the field row that advertises `tap`. As for `type --focus`, the field needs a unique accessibility ID or unique anonymous native identity.
- Before the tap, AXe finds the field by the identity bound at batch start, wherever earlier typing or the keyboard moved it. It must be the same control (type, ID, label, value, process, native object), enabled, shown, inside the display and pass the native hit check.
- After the tap, AXe waits for the field to report focus, then types with the usual per-key focus checks. Existing text is not cleared.
- An already focused field can use a plain type step in the same batch.
- A focus step is a declared layout change: its keyboard can move, reorder or scroll the screen. Every later target must then be the same control (type, ID, label, value, process), still enabled, shown and inside the display; only its position may change.
- AXe reads the new screen until two reads in a row match (at most four); that becomes the layout later steps must keep. The keyboard's suggestion bar can change just after typing.
- A changed or vanished control stops the batch before the next step's input. A control the keyboard now covers is refused by that step's native hit check, also before input.
- Receipt kind `focusAndType`; its events count the focus tap and the typing.

### Native IDs

Steps can name exact accessibility IDs instead of refs:

```json
{"steps":[{"action":"tap","id":"field"},{"action":"type","id":"field","text":"AB"}]}
```

- AXe discovers the frontmost app or SpringBoard in its initial capture, resolves each exact ID in order and needs a usable replacement snapshot after each action.
- A type step needs its field focused when the step starts.
- No `snapshotID` in an ID document; do not mix `id` and `ref` steps. Use only real IDs read from a capture.
- Optional positive `--expected-pid` must match the captured owner, in either form.

## Results and limits

- Accepted: `tap` and literal `type` steps; `focus` only on type steps. Unsupported: coordinates, retained input, device actions, nested batches, delays, stdin text, continued errors.
- Failure, cancellation, changed layout or context, or uncertain cleanup stops later steps. Earlier effects remain; nothing is rolled back or replayed.
- If no step sent input, AXe retries the whole batch when its targets are unchanged, or are the same controls holding still across two reads about 150 ms apart after a move.
- A batch stopped by a step that sent no input returns the current screen; plan the remaining steps from its snapshot ID.
- `data.batch` holds completed steps, per-step receipts and the stopped index.
- A completed action can be followed by a failed final capture.
- Lost reply: outcome unknown. Never resend the batch.

Reply fields:

- Complete success with a refreshed final capture, in `reading` or `navigation`, keeps `completedSteps`, ordered step `index`, `action`, `status`, input `outcome` and `enqueuedEventCount`, and omits `totalSteps`.
- Every compact batch omits `replayed`, `rolledBack`, per-step request IDs, cache and context, and receipt `cleanup` when it is `notNeeded`.
- Receipt `kind` is omitted only when it equals the step action; `typeText` stays distinct from `type`.
- Failed, partial or uncertain batches keep these diagnostic fields. `full` keeps the complete base result.
- Need request IDs: choose `--view full` before input. Never repeat input to expand a reply.

Use matched CLI, broker and runtime versions. Native limits and output fields: [agent batch contract](agent-reference.md#run-a-small-ordered-agent-batch).
