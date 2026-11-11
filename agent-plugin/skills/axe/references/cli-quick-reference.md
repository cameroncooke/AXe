# AXe commands outside agent mode

No UI target, so no `--agent`; app reads and input use the agent commands in SKILL.md. Simulator commands need `--udid <UDID>` unless noted.

## Contents

- [Output format](#output-format)
- [Simulator discovery](#simulator-discovery)
- [Screens](#screens)
- [Device settings](#device-settings)
- [Screenshot](#screenshot)
- [Video recording](#video-recording)
- [Video streaming](#video-streaming)
- [Clipboard staging](#clipboard-staging)
- [Gestures and drawing](#gestures-and-drawing)
- [Hardware buttons](#hardware-buttons)
- [Simulator shutdown](#simulator-shutdown)
- [Common keycodes](#common-keycodes)

## Output format

```bash
axe --output json list-simulators
axe --output json screenshot --udid <UDID> --output shot.png
```

- Format goes before the command; `--output` after `screenshot` or `record-video` is a file path.
- No format: state commands print a few lines of state; input commands print nothing (`tap`, `slider`, `batch` print a `✓` line); media commands print the path; failures print `Error: <message>` to stderr.
- `--output json`: one envelope, also on failure (nonzero exit). `--verbose` adds detail, never changes exit status or code.
- `stream-video` rejects explicit format selection before capture.
- [Output fields](agent-reference.md#output-format).

## Simulator discovery

```bash
axe list-simulators
```

- No `--udid`. Lists available simulators with UDID and boot state.
- Pass a real UDID elsewhere; an empty value never selects a device.

## Screens

```bash
axe displays --udid <UDID>
```

- Waits for a fold or rotation to finish, then lists each screen: active or not, role (`outer`, `inner`, `main`), size in logical points (use for coordinates), scale, orientation, and hinge angle on iPhone Duo.
- Pass the active screen's `id` and `uuid` to `--screen-id` and `--screen-uuid` to make a command refuse any other screen.
- Fields: [device-reference.md](device-reference.md#screens-hinge-and-rotation).

## Device settings

```bash
axe settings show --udid <UDID>
axe settings set --udid <UDID> --appearance dark
```

- Simulators and physical devices. Also text size, accessibility display settings, VoiceOver, location, status bar: [settings-reference.md](settings-reference.md).

## Screenshot

```bash
axe screenshot --udid <UDID> --output shot.png     # file
axe screenshot --udid <UDID> --output ~/Desktop/   # directory, auto-named
axe screenshot --udid <UDID>                       # auto-named in the current directory
```

- Prints the PNG path; open it for visual facts the accessibility tree lacks.

## Video recording

```bash
axe record-video --udid <UDID> --fps 15 --output recording.mp4
axe record-video --udid <UDID> --fps 10 --quality 60 --scale 0.5 --output low-bw.mp4
```

- `Ctrl+C` stops; AXe finalises the MP4 before exiting. Modes and limits: [recording-reference.md](recording-reference.md).

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

- Stages 1...65536 valid UTF-8 bytes, with exact private CoreDevice readback. JSON: hash/length, `verified: true`, `inserted: false`; it never inserts text.
- Replaces a shared clipboard. No agent/selected/batch options, automatic Paste, restore or retry.
- Preserve failures. Get fresh UI refs and verify app insertion separately. [clipboard-reference.md](clipboard-reference.md).

## Gestures and drawing

Only for gestures with no agent form. Taps, long presses, double taps, drags, scrolls and pinches on a control use the agent commands in SKILL.md.

```bash
axe draw 100,400 300,400 --udid <UDID>                                 # line
axe draw 200,300 300,480 100,480 --close --duration 1.5 --udid <UDID>  # triangle
axe gesture pinch --scale 2 --udid <UDID>                              # zoom in at screen centre
axe gesture pinch -x 200 -y 400 --radius 60 --scale 0.5 --udid <UDID>  # zoom out
```

- Logical points, current orientation.
- `draw`: 2 to 1,000 `x,y` points, one finger, `--duration` 1 s default, 30 max. A point off screen fails with `invalidArguments` before input.
- `pinch`: no `-x/-y` = screen centre; no `--radius` = a quarter of the shorter side, reduced so both ends stay 16 points inside the screen.
- Edge and corner presets (`swipe-from-left|right|top|bottom-edge`, `swipe-from-top-right-corner` for Control Centre) use the measured screen; a simulator without DTUHID assumes 390×844 unless given `--screen-width`/`--screen-height`.
- `rotate`, `two-finger-tap`, `two-finger-hold`, `two-finger-swipe` take explicit points: `axe gesture --help`.
- None returns a capture or proves the app recognised the gesture; capture again.

## Hardware buttons

```bash
axe button home --udid <UDID>
axe button lock --udid <UDID>
axe button lock --duration 3.0 --udid <UDID>    # long press
axe button side-button --udid <UDID>
axe button siri --udid <UDID>
axe button apple-pay --udid <UDID>
```

- Acts on the whole device. After Home or any button that changes the foreground app, take a new agent capture before more input.
- Receipts confirm transport, not Siri, payment UI, secure lock, wake or power. Never replay uncertain input.
- Display-selected buttons on iPhone Duo: [device-reference.md](device-reference.md#selected-device-buttons).

## Simulator shutdown

```bash
axe shutdown --udid <UDID>
```

- Shuts down one simulator; see [device-reference.md](device-reference.md#simulator-shutdown).

## Common keycodes

Agent `key`, `key-sequence` and `key-combo` take HID keycodes on a focused field reference.

| Key | Code | Key | Code | Key | Code |
|---|---|---|---|---|---|
| Enter | 40 | Escape | 41 | Backspace | 42 |
| Tab | 43 | Space | 44 | a | 4 |
| LeftGUI (Cmd) | 227 | LeftShift | 225 | LeftCtrl | 224 |
| LeftAlt | 226 | F1 | 58 | F12 | 69 |
