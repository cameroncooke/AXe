# AXe CLI Reference

Comprehensive reference for all AXe commands. Most simulator-interaction commands require `--udid <UDID>` unless noted.

## Output format

```bash
axe --output text describe-ui --agent --udid <UDID>
axe --output json describe-ui --agent --udid <UDID>
axe --output json list-simulators
axe --output json screenshot --udid <UDID> --output shot.png
```

No format option preserves existing command output; `--agent` defaults to one JSON result. `--output text|json` chooses representation. Agent `--view reading` (default) and `--view navigation` use compact schema 2; `--view full` exposes canonical schema 1. JSON failures return one stdout result and a nonzero exit. Ordinary formatted commands keep their common command envelope. See [output fields](agent-reference.md#output-format).

Prefer the format before the command. Non-media leaf placement is accepted when unambiguous. Screenshot/movie `--output` after the command remains a path. `stream-video` rejects explicit format selection before capture. Existing command-specific `--json` flags are unchanged. Supply a real UDID; an empty value never selects a device. New output-format verification is pending.

## Simulator discovery

```bash
axe list-simulators
```

No `--udid` needed. Lists all available simulators with their UDIDs and boot state.


## Optional agent references

```bash
# Capture the current frontmost app or SpringBoard on Home.
axe describe-ui --agent --udid <UDID>
# Omit static text when only controls are needed.
axe describe-ui --agent --view navigation --udid <UDID>
# Read an exact ID or full label/value from the same snapshot, without input.
axe describe-ui --agent --snapshot-id <SNAPSHOT_ID> --read-ref <REF> --text-field id --udid <UDID>
axe describe-ui --agent --snapshot-id <SNAPSHOT_ID> --read-ref <REF> --text-field label --text-offset 0 --text-limit 1024 --udid <UDID>
# Use that capture's snapshot ID and ref; its PID stays bound.
axe tap --agent --udid <UDID> --snapshot-id <SNAPSHOT_ID> --ref <REF>
# Add a positive PID assertion only when required by the caller.
axe describe-ui --agent --udid <UDID> --expected-pid <PID>
# Agent batches use the JSON contract in agent-reference.md.
axe batch --agent --file steps.json --udid <UDID>
```

Without a PID assertion, a new capture discovers its owner from one native app/display observation. Snapshot validation and reference actions use the saved PID; an optional positive assertion must match it. Zero and negative PIDs reject. After Home, opening another app or a layout/focus change, capture again and select fresh references. No raw hierarchy read or PID lookup is required first. Input is not replayed after failure.

Follow `capture.page.nextOffset` with `--row-offset` and the same snapshot for more rows. `--row-limit 1...64` bounds one total page across targets, scrolling and text; offsets are 0...12288. Compact rows can merge actions and omit proved repeated child labels. Display cells have a limit of 160 Unicode scalars (159 plus an ellipsis when clipped); read-ref chunks preserve exact native fields and use Unicode-scalar offsets. `truncatedFields.displayScalarLength` counts the complete normalized cell, while `data.detail.totalLength` counts the exact native field; whitespace normalization can make them differ. Read `data.detail.nextOffset` for the next text chunk. Full view uses `nextRowOffset` and can contain large text.

Existing agent coordinate tap/swipe forms remain available with a current snapshot. Raw commands and explicit selected mode without `--agent` keep their existing interfaces and PID rules. Read the [agent reference](agent-reference.md) for action limits and the [agent batch contract](agent-reference.md#run-a-small-ordered-agent-batch) for its JSON file.

Native-object refs require matched CLI, broker and runtime versions. Use the actions advertised by the current ref, including eligible controls without app IDs. The UID stays internal; no caller PID/UID lookup is added. The per-device RAM table expires or is replaced and is lost on broker restart. Opaque sliders, AXPress and pinch remain unsupported. Read [native object references](agent-reference.md#native-object-references); this guidance does not claim simulator acceptance.

## Tap

```bash
# By coordinates
axe tap -x 100 -y 200 --udid <UDID>

# By accessibility identifier (preferred)
axe tap --id "SearchField" --udid <UDID>

# By accessibility label
axe tap --label "Safari" --udid <UDID>
axe tap --label "Weather Alerts" --udid <UDID>  # Auto physical touch for switches/toggles
axe tap --label "Submit" --tap-style simulator --udid <UDID>
axe tap -x 320 -y 780 --tap-style physical --udid <UDID>

# With timing
axe tap -x 100 -y 200 --pre-delay 1.0 --post-delay 0.5 --udid <UDID>
```

## Slider

```bash
# Value is a percentage from 0 to 100
axe slider --id "volume-slider" --value 75 --udid <UDID>
axe slider --label "Volume" --value 40 --element-type Slider --udid <UDID>
```

`slider` resolves the matched accessibility slider, uses its frame/current AXValue for one calibrated low-level HID drag through the same composite touch-move path as `drag`, and re-reads AXValue. Since iOS slider controls quantize values to their rendered track resolution, AXe verifies that the observed value is within tolerance rather than retrying correction gestures to chase unreachable decimals. If the observed value remains outside tolerance, the command fails clearly.

## Swipe

```bash
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --udid <UDID>

# With duration and delta
axe swipe --start-x 50 --start-y 500 --end-x 350 --end-y 500 --duration 2.0 --delta 25 --udid <UDID>

# With timing
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --pre-delay 1.0 --post-delay 0.5 --udid <UDID>
```

## Drag (low-level)

```bash
axe drag --start-x 100 --start-y 400 --end-x 300 --end-y 400 --udid <UDID>
axe drag --start-x 100 --start-y 400 --end-x 300 --end-y 400 --duration 0.4 --steps 40 --udid <UDID>
```

`drag` emits one composite low-level HID event: touch down at the start point, a sequence of explicit touch move events, then touch up at the end point.

## Touch (low-level)

```bash
axe touch -x 150 -y 250 --down --udid <UDID>                          # Touch down only
axe touch -x 150 -y 250 --up --udid <UDID>                            # Touch up only
axe touch -x 150 -y 250 --down --up --udid <UDID>                     # Tap
axe touch -x 150 -y 250 --down --up --delay 1.0 --udid <UDID>        # Long press
```

## Gesture presets

```bash
axe gesture scroll-up --udid <UDID>
axe gesture scroll-down --udid <UDID>
axe gesture scroll-left --udid <UDID>
axe gesture scroll-right --udid <UDID>
axe gesture swipe-from-left-edge --udid <UDID>
axe gesture swipe-from-right-edge --udid <UDID>
axe gesture swipe-from-top-edge --udid <UDID>
axe gesture swipe-from-bottom-edge --udid <UDID>

# With custom screen dimensions
axe gesture scroll-up --screen-width 430 --screen-height 932 --udid <UDID>

# With custom duration/delta
axe gesture scroll-up --duration 2.0 --delta 100 --udid <UDID>

# With timing
axe gesture scroll-down --pre-delay 1.0 --post-delay 0.5 --udid <UDID>
```

### Preset reference

| Preset | Description | Default Duration | Default Delta |
|---|---|---|---|
| `scroll-up` | Scroll up in centre | 0.5s | 25px |
| `scroll-down` | Scroll down in centre | 0.5s | 25px |
| `scroll-left` | Scroll left in centre | 0.5s | 25px |
| `scroll-right` | Scroll right in centre | 0.5s | 25px |
| `swipe-from-left-edge` | Left edge to right | 0.3s | 50px |
| `swipe-from-right-edge` | Right edge to left | 0.3s | 50px |
| `swipe-from-top-edge` | Top to bottom | 0.3s | 50px |
| `swipe-from-bottom-edge` | Bottom to top | 0.3s | 50px |

## Text input

```bash
# Inline (use single quotes)
axe type 'Hello World!' --udid <UDID>

# From stdin (best for automation / special characters)
echo "Complex text with any characters!" | axe type --stdin --udid <UDID>

# From file
axe type --file input.txt --udid <UDID>
```

## Clipboard staging

```bash
printf '%s' 'AXe sample' | axe clipboard copy --stdin --udid <UUID>
```

Stages 1...65536 valid UTF-8 bytes with exact private CoreDevice readback. JSON reports hash/length, `verified: true` and `inserted: false`; it does not insert text. It replaces a shared clipboard and has no agent/selected/batch options, automatic Paste, restore or retry. Preserve failures. Get fresh UI refs and verify app insertion separately. Read [Clipboard staging](clipboard-reference.md). One v6 outer-portrait product-copy plus key101/fresh Paste Button workflow passed exact 22-byte insertion, one callback and release; automatic Paste and other apps remain unproved. Empty-open-stdin signal cancellation passed; running-child cancellation remains unproved.

## Keyboard

```bash
# Single key press by HID keycode
axe key 40 --udid <UDID>                                    # Enter
axe key 42 --duration 1.0 --udid <UDID>                     # Hold Backspace

# Key sequence
axe key-sequence --keycodes 11,8,15,15,18 --udid <UDID>     # "hello"
axe key-sequence --keycodes 40,40,40 --delay 0.5 --udid <UDID>

# Key combo (modifier + key, atomic)
axe key-combo --modifiers 227 --key 4 --udid <UDID>         # Cmd+A
axe key-combo --modifiers 227 --key 6 --udid <UDID>         # Cmd+C
axe key-combo --modifiers 227 --key 25 --udid <UDID>        # Cmd+V
axe key-combo --modifiers 227,225 --key 4 --udid <UDID>     # Cmd+Shift+A
```

### Common keycodes

| Key | Code | Key | Code | Key | Code |
|---|---|---|---|---|---|
| Enter | 40 | Escape | 41 | Backspace | 42 |
| Tab | 43 | Space | 44 | a | 4 |
| LeftGUI (Cmd) | 227 | LeftShift | 225 | LeftCtrl | 224 |
| LeftAlt | 226 | F1 | 58 | F12 | 69 |

## Hardware buttons

```bash
axe button home --udid <UDID>
axe button lock --udid <UDID>
axe button lock --duration 3.0 --udid <UDID>    # Long press
axe button side-button --udid <UDID>
axe button siri --udid <UDID>
axe button apple-pay --udid <UDID>
```

Selected mode supports all five buttons with `--input-mode selected --screen-id <ID> --screen-uuid <UUID>`. Optional `--expected-boot <BOOT_ID>` must match before input. The active pair guards context; each button acts on the whole device. Omitted duration has no requested hold; explicit duration is finite, greater than zero and at most 10 seconds. The same names and options work in selected batch steps.

Home keeps its `home` result; the others return `button.kind` and typed execution/cleanup evidence. Apple Pay uses two native side-button presses (four primitives), a 0.15-second gap and half the supplied duration per hold; other buttons use two primitives. Receipts confirm transport, not Siri/payment UI, secure lock, wake or power. Do not replay uncertain input. Selected wire 28 uses a separate broker endpoint and rejects wire 27. Raw routes and defaults are unchanged. New selected Siri/Lock/Apple Pay build and native proof are pending.

## Batch (multi-step workflows)

```bash
# Inline steps
axe batch --udid <UDID> \
  --step "tap --id SearchField" \
  --step "type 'hello world'" \
  --step "key 40"

# From stdin
cat <<'EOF' | axe batch --udid <UDID> --stdin
tap --id SearchField
type 'hello world'
key 40
EOF

# From file
axe batch --udid <UDID> --file steps.txt

# With options
axe batch --udid <UDID> \
  --continue-on-error \
  --ax-cache perStep \
  --type-submission chunked \
  --type-chunk-size 150 \
  --tap-style automatic \
  --step "tap --label Settings" \
  --step "sleep 0.5" \
  --step "tap --id SaveButton"

# With element waiting (polls for elements that appear after navigation)
axe batch --udid <UDID> \
  --wait-timeout 5 \
  --step "tap --id LoginButton" \
  --step "tap --id WelcomeMessage"

# Toggle a setting switch by label
axe batch --udid <UDID> \
  --step "tap --label 'Weather Alerts'"
```

See `batch-reference.md` for full batch semantics.

## Accessibility / UI inspection

```bash
axe describe-ui --udid <UDID>                      # Full screen
axe describe-ui --point 100,200 --udid <UDID>      # Specific point
```

## Screenshot

```bash
axe screenshot --udid <UDID>                                    # Auto-named
axe screenshot --output ~/Desktop/shot.png --udid <UDID>        # Specific file
axe screenshot --output ~/Desktop/ --udid <UDID>                # Directory (auto-named)
```

## Video recording

```bash
axe record-video --udid <UDID> --fps 15 --output recording.mp4
axe record-video --udid <UDID> --fps 10 --quality 60 --scale 0.5 --output low-bw.mp4
```

Press `Ctrl+C` to stop recording. AXe finalises the MP4 before exiting.

## Video streaming

```bash
axe stream-video --udid <UDID> --fps 10 --format mjpeg > stream.mjpeg
axe stream-video --udid <UDID> --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset ultrafast output.mp4
```

## Timing parameters

| Parameter | Range | Description | Available on |
|---|---|---|---|
| `--pre-delay` | 0–10s | Delay before action | tap, swipe, drag, gesture |
| `--post-delay` | 0–10s | Delay after action | tap, swipe, drag, gesture |
| `--duration` | 0–10s | Action duration | swipe, drag, gesture, button, key |
| `--steps` | 1–1000 | Touch move event count | drag |
| `--value` | 0–100 | Target slider percentage | slider |
| `--delay` | 0–5s | Between-item delay | key-sequence, touch |

## Best practices
- Prefer `--id` / `--label` selectors over coordinates for resilience; use `slider` for selector-resolved low-level HID slider dragging with AXValue tolerance verification instead of raw swipe coordinates, and use `drag` when you specifically need raw point-to-point HID drag behavior.
- Selector taps activate a contained UIKit `UISwitch` or SwiftUI `Toggle` when the matched row or label contains exactly one switch/toggle.
- Default `--tap-style automatic` uses physical touch for matched switches/toggles and simulator `tapAt` for normal taps; use `--tap-style physical|simulator` to override.
- Use single quotes for inline text to avoid shell expansion.
- Use `--stdin` or `--file` when input contains shell-sensitive characters.
- Keep verification (`describe-ui`, `screenshot`) separate from execution.

## Selected-screen tap waiting

Use the active screen pair and expected PID. Put a selected wait on the tap or individual batch tap step; batch-level polling is unsupported. A positive wait is at most 30 seconds. Its interval is 0.05–30 seconds (default 0.25). AXe stops on device changes or any error other than an absent match.

```sh
axe tap --input-mode selected --screen-id <ID> --screen-uuid <UUID> --udid <UDID> \
  --expected-pid <PID> --id ready --wait-timeout 5
axe batch --input-mode selected --screen-id <ID> --screen-uuid <UUID> --udid <UDID> \
  --step 'tap --id ready --expected-pid <PID> --wait-timeout 5'
```
