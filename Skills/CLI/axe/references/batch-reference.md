# AXe Batch Reference

Use this reference when generating or reviewing `axe batch` commands.

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
- `--file <path>`: read one step per line from file.
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
