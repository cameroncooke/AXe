# AXe Batch Reference

Use this reference when generating or reviewing `axe batch` commands.

## Output format

Use `axe --output json batch ...` for one JSON command result, or `axe --output text batch ...` for text. Agent batches keep the agent result envelope; ordinary batches opt into the common command envelope. Without a format option, existing batch output remains. Format selection is a host CLI option, not a batch step or JSON step field. Input is not replayed. See [output fields](agent-reference.md#output-format).

With explicit formatting, selected batches collect step receipts and write one final result, not per-step stdout. Inspect the step receipts and failure fields. A final stdout write failure is detected after the batch; earlier input remains and is not replayed. Without `--output`, per-step write failures keep their existing stop behavior.

## Supported step commands
- `tap`
- `swipe`
- `gesture`
- `touch`
- `type`
- `button`
- `key`
- `key-sequence`
- `key-combo`
- `sleep <seconds>` (batch pseudo-step)

## Batch flags
- `--udid <UDID>`: required simulator target.
- `--step "..."`: repeatable inline step source.
- `--file <path>`: read one step per line, or agent JSON with `--agent`.
- `--steps-json <json>`: agent-only inline JSON instead of `--file`.
- `--stdin`: read one step per line from stdin.
- `--continue-on-error`: keep running after a failed step; report failures at end.
- `--ax-cache perBatch|perStep|none`: selector tap AX snapshot reuse policy.
- `--type-submission chunked|composite`: submission mode for `type` steps.
- `--type-chunk-size <n>`: chunk size when using chunked submission.
- `--tap-style automatic|simulator|physical`: default tap event style for tap steps.
- `--wait-timeout <seconds>`: maximum seconds to poll for selector-based elements before failing (0 = no waiting, default).
- `--poll-interval <seconds>`: seconds between accessibility tree polls when `--wait-timeout` is active (default 0.25).
- `--verbose`: enable detailed stderr logs for troubleshooting (default quiet output).

## Input rules
For ordinary and selected line-based batches:

- Use exactly one source: `--step` OR `--file` OR `--stdin`.
- Empty lines are ignored.
- `#` comment lines are ignored in file/stdin input.
- Do not pass `--udid` inside step lines; keep it at batch command level.

## Example: inline steps
```bash
axe batch --udid SIMULATOR_UDID \
  --step "tap --id EmailField" \
  --step "type 'cam@example.com'" \
  --step "key 43" \
  --step "type 'super-secret'" \
  --step "key 40"
```

## Example: stdin steps
```bash
cat <<'EOF' | axe batch --udid SIMULATOR_UDID --stdin
tap --id EmailField
type 'cam@example.com'
key 43
type 'super-secret'
key 40
EOF
```

## Example: file steps
`login.steps`
```text
# login flow
tap --id EmailField
type 'cam@example.com'
key 43
type 'super-secret'
key 40
```

Run:
```bash
axe batch --udid SIMULATOR_UDID --file login.steps
```

## Example: explicit timing and policy
```bash
axe batch --udid SIMULATOR_UDID \
  --ax-cache perStep \
  --type-submission chunked \
  --type-chunk-size 150 \
  --continue-on-error \
  --step "tap --label Settings" \
  --step "sleep 0.5" \
  --step "tap --id SaveButton"
```

## Example: legacy multi-screen flow with element waiting
```bash
axe batch --udid SIMULATOR_UDID \
  --wait-timeout 5 \
  --step "tap --id LoginButton" \
  --step "tap --id WelcomeMessage"
```

The second step polls for up to 5 seconds for `WelcomeMessage` to appear after the login tap triggers navigation.

## Example: toggling a setting switch
```bash
axe batch --udid SIMULATOR_UDID \
  --step "tap --label 'Weather Alerts'"
```

Batch selector taps share direct `axe tap` behavior. If the matched row or label contains exactly one UIKit `UISwitch` or SwiftUI `Toggle`/switch control, AXe taps that control's activation point. With default `--tap-style automatic`, switch/toggle activations use physical touch down/up and normal taps use simulator `tapAt`.

If label selectors are ambiguous and AXe reports no `AXUniqueId` values for matches, switch that step to coordinates (`tap -x/-y`). For coordinate taps that need physical touch, use `tap -x/-y --tap-style physical` or batch-level `--tap-style physical`.

## Selected-screen tap waiting

Put `--wait-timeout` and optional `--poll-interval` inside an ordinary selected ID, label or value tap step. Use the active batch screen pair and a positive expected PID. The timeout must be greater than zero through 30 seconds. The interval is 0.05–30 seconds (default 0.25); a non-default interval needs a positive wait. Batch-level polling is rejected. Only an absent match retries. Cancellation, changed device state or any other failure stops later steps without replay.

```sh
axe batch --input-mode selected --screen-id <ID> --screen-uuid <UUID> --udid <UDID> \
  --step 'tap --id ready --expected-pid <PID> --wait-timeout 5' \
  --step 'tap --id continue --expected-pid <PID>'
```

## Optional agent batch

Use `axe batch --agent --file steps.json --udid <UDID>` for 1...8 ordered tap/type steps. The file must be regular UTF-8 JSON, with at most 16384 bytes. Choose one target form for the whole document.

Use inline JSON when a separate file is not needed:

```bash
axe batch --agent --udid <UDID> --steps-json '{"snapshotID":"3FF70D78-26DA-4314-B37B-4CB57D2A1A85","steps":[{"action":"tap","ref":"e12"},{"action":"tap","ref":"e19"}]}'
```

Choose exactly one `--file` or `--steps-json`. Both use the same JSON parser, 16384-byte limit, eight-step limit and native checks. Inline JSON is not shell step syntax; it adds no retry. Replace the sample snapshot ID and refs with one real capture. Quote JSON for the calling shell; AXe preserves decoded literal text.


### Published references

First run `axe describe-ui --agent --udid <UDID>`. Use its snapshot ID and available refs:

```json
{"snapshotID":"3FF70D78-26DA-4314-B37B-4CB57D2A1A85","steps":[{"action":"tap","ref":"e12"},{"action":"tap","ref":"e19"}]}
```

Replace the example UUID and refs with values from the same capture. AXe checks all refs, actions and unique native identities before the first input. Each step then reads fresh native state. App ownership, boot, active display, hinge, rotation, geometry, hierarchy and control identities must still match. Control frames, focus, enabled state and visibility must stay unchanged. Ordinary text and control values can change after input. Standalone noninteractive StaticText glyph bounds may also change; control and ancestor frames stay fixed. A changed control label or text inside a control stops later steps. No cached point authorizes input.

Use this form for controls already present in one stable layout. It does not follow a new sheet, keyboard or screen layout. A type step requires an already focused, visible, enabled native TextField with an available `typeText` action. Use a separate focus action and capture first. AXe returns one replacement capture after the reference batch ends, not after each step. Use its new snapshot ID and refs for later input. Eligible anonymous refs keep their original private native identity; all refs are checked before the first input. Native-ID documents still need real app IDs, never object UIDs.

### Native IDs

The existing ID form remains:

```json
{"steps":[{"action":"tap","id":"field"},{"action":"type","id":"field","text":"AB"}]}
```

This form discovers the frontmost app or SpringBoard in its initial capture. It resolves each exact native ID in order and requires a usable replacement snapshot after each action. A type step needs the field to be focused when that step starts. Do not add `snapshotID` to an ID document or mix `id` and `ref` steps. Optional positive `--expected-pid` must match the captured owner in either form; no PID lookup is required first.

### Results and limits

Only tap and literal type steps are accepted. Coordinates, retained input, device actions, nested batches, delays, stdin text and continued errors are unsupported in agent JSON. Ordinary line-based batches and their coordinate behavior are unchanged.

Failure, cancellation, changed layout/context or uncertain cleanup stops later steps. Earlier effects remain. Inspect `data.batch` for completed steps, per-step receipts and the stopped index. Nothing is rolled back or replayed. A completed action can be followed by failed final capture. If the reply is lost, the outcome is unknown; do not submit the batch again.

Agent `--view reading` is the default. `--view navigation` omits final static-text rows; `--view full` returns canonical detail. Reading/navigation use public adaptive schema 2; full uses base schema 1. The view requires `--agent` and is a batch output option, not a step field. Use matched CLI, broker and runtime versions. Read the [agent batch contract](agent-reference.md#run-a-small-ordered-agent-batch) for native limits and output fields.

After complete success with a refreshed final capture, reading/navigation batches keep `completedSteps`, ordered step `index`, `action`, `status`, input `outcome`, `enqueuedEventCount`, `cleanup`, and top-level batch `replayed: false`. They omit duplicate `totalSteps`, `rolledBack: false`, per-step request IDs and receipt `replayed: false`. Receipt `kind` is omitted only when it equals the step action; `typeText` remains distinct from `type`. The exact intermediate `batchInProgress` cache is also omitted; use final `data.cache`. Failed, partial or uncertain batches retain these diagnostic fields. Full view keeps the complete base result. Select full view before input when request IDs are required; never repeat input to expand a reply.
