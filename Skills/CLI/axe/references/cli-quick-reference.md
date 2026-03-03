# AXe CLI Reference

Comprehensive reference for all AXe commands. Every command requires `--udid <UDID>` unless noted.

## Simulator discovery

```bash
axe list-simulators
```

No `--udid` needed. Lists all available simulators with their UDIDs and boot state.

## Tap

```bash
# By coordinates
axe tap -x 100 -y 200 --udid <UDID>

# By accessibility identifier (preferred)
axe tap --id "SearchField" --udid <UDID>

# By accessibility label
axe tap --label "Safari" --udid <UDID>

# With timing
axe tap -x 100 -y 200 --pre-delay 1.0 --post-delay 0.5 --udid <UDID>
```

## Swipe

```bash
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --udid <UDID>

# With duration and delta
axe swipe --start-x 50 --start-y 500 --end-x 350 --end-y 500 --duration 2.0 --delta 25 --udid <UDID>

# With timing
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --pre-delay 1.0 --post-delay 0.5 --udid <UDID>
```

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
  --step "tap --label Settings" \
  --step "sleep 0.5" \
  --step "tap --id SaveButton"
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
| `--pre-delay` | 0–10s | Delay before action | tap, swipe, gesture |
| `--post-delay` | 0–10s | Delay after action | tap, swipe, gesture |
| `--duration` | 0–10s | Action duration | swipe, gesture, button, key |
| `--delay` | 0–5s | Between-item delay | key-sequence, touch |

## Best practices
- Prefer `--id` / `--label` taps over coordinates for resilience.
- Use single quotes for inline text to avoid shell expansion.
- Use `--stdin` or `--file` when input contains shell-sensitive characters.
- Keep verification (`describe-ui`, `screenshot`) separate from execution.
