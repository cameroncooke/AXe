# AXe commands outside agent mode

These commands have no UI target, so they run without `--agent`. For app reads and input, use the agent commands in SKILL.md. Simulator commands require `--udid <UDID>` unless noted.

## Output format

```bash
axe --output json list-simulators
axe --output json screenshot --udid <UDID> --output shot.png
```

No format option preserves each command's existing output. `--output text|json` chooses the representation; ordinary formatted commands use the common command envelope, and JSON failures return one stdout result and a nonzero exit. Put the format before the command. Screenshot and movie `--output` after the command remains a file path. `stream-video` rejects explicit format selection before capture. See [output fields](agent-reference.md#output-format).

## Simulator discovery

```bash
axe list-simulators
```

No `--udid` needed. Lists all available simulators with their UDIDs and boot state. Supply a real UDID to other commands; an empty value never selects a device.

## Screenshot

```bash
axe screenshot --udid <UDID> --output shot.png         # Specific file
axe screenshot --udid <UDID> --output ~/Desktop/       # Directory (auto-named)
axe screenshot --udid <UDID>                           # Auto-named in the current directory
```

The command prints the PNG path. Open it to read visual facts the accessibility tree does not expose.

## Video recording

```bash
axe record-video --udid <UDID> --fps 15 --output recording.mp4
axe record-video --udid <UDID> --fps 10 --quality 60 --scale 0.5 --output low-bw.mp4
```

Press `Ctrl+C` to stop recording. AXe finalises the MP4 before exiting. Read the [recording contract](recording-reference.md) for display modes and limits.

## Video streaming

```bash
axe stream-video --udid <UDID> --fps 10 --format mjpeg > stream.mjpeg
axe stream-video --udid <UDID> --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset ultrafast output.mp4
```

## Clipboard staging

```bash
printf '%s' 'AXe sample' | axe clipboard copy --stdin --udid <UDID>
```

Stages 1...65536 valid UTF-8 bytes with exact private CoreDevice readback. JSON reports hash/length, `verified: true` and `inserted: false`; it does not insert text. It replaces a shared clipboard and has no agent/selected/batch options, automatic Paste, restore or retry. Preserve failures. Get fresh UI refs and verify app insertion separately. Read [Clipboard staging](clipboard-reference.md).

## Hardware buttons

```bash
axe button home --udid <UDID>
axe button lock --udid <UDID>
axe button lock --duration 3.0 --udid <UDID>    # Long press
axe button side-button --udid <UDID>
axe button siri --udid <UDID>
axe button apple-pay --udid <UDID>
```

A button acts on the whole device. After Home or any button that changes the foreground app, take a new agent capture before more input. Receipts confirm transport, not Siri, payment UI, secure lock, wake or power. Do not replay uncertain input. For display-selected buttons on the iPhone Duo, read [device-reference.md](device-reference.md#selected-device-buttons).

## Simulator shutdown

```bash
axe shutdown --udid <UDID>
```

Shuts down one simulator; see [device-reference.md](device-reference.md#simulator-shutdown).

## Common keycodes

Agent `key`, `key-sequence` and `key-combo` take HID keycodes on a focused field reference.

| Key | Code | Key | Code | Key | Code |
|---|---|---|---|---|---|
| Enter | 40 | Escape | 41 | Backspace | 42 |
| Tab | 43 | Space | 44 | a | 4 |
| LeftGUI (Cmd) | 227 | LeftShift | 225 | LeftCtrl | 224 |
| LeftAlt | 226 | F1 | 58 | F12 | 69 |
