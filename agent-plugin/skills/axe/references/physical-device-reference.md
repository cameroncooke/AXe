# Physical iPhone and iPad

No agent mode. Every command takes the hardware UDID from `axe list-devices`.

## Readiness

```bash
axe list-devices
axe doctor --udid "$DEVICE_UDID"
axe screenshot --udid "$DEVICE_UDID" --output screen.png
axe describe-ui --udid "$DEVICE_UDID"
```

- Pair in Xcode, enable Developer Mode, unlock. AXe does none of these.
- Resolve every `doctor` check before continuing. A failure ends `Error: <name> is not ready.` with the check's ID as code: `notPaired`, `developerModeDisabled`, `deviceNotConnected`, `developerDiskImageUnavailable`, `deviceLocked`, `screenshotServiceUnavailable`.
- Structured checks: `axe --output json doctor --udid "$DEVICE_UDID"`.
- Open the saved screenshot to verify what is visible.
- Error codes match simulators: `busy` (another command on the device), `timeout` (deadline), `cleanupUncertain` (a touch or key may be held); CoreDevice failure is `xcodeUnavailable`, `readFailed` or `timeout`. A failed batch step keeps the step's code.

## Input and readback

```bash
axe describe-ui --udid "$DEVICE_UDID" --point 160,240
axe tap --udid "$DEVICE_UDID" --id "$ELEMENT_ID"
axe tap --udid "$DEVICE_UDID" --id "$ELEMENT_ID" --wait-timeout 15 --poll-interval 0.25
axe tap --udid "$DEVICE_UDID" --semantic-press --id "$CHECKBOX_ID"
```

- Logical points in the current orientation; a PNG has pixels.
- Exact IDs, labels or values come from a fresh device tree.
- AXe checks the selector resolves to one visible target that still owns the tap point. Re-read the screen to check the effect.
- A modal alert blocks the tree: close it on the phone, read again.
- `--semantic-press`: exact ID of a visible native checkbox. AXe checks the native reply and the changed Boolean, then prints `Switch <id>: off -> on`; JSON `{identifier, before, after}`; `--verbose` prints the full receipt. Uncertain outcome: read the screen before any more input.
- Coordinate taps, swipes, drags, draws, gestures, touch, rotation, typing, key commands, buttons, batches and `settings` (except status bar overrides) use the same hardware UDID.
- `type`: focus the field first. Up to 256 UTF-8 bytes per command, US key layout; other characters fail with `invalidArguments`.
- Standalone `touch` needs both `--down` and `--up`. A batch can hold a contact across steps and releases it on exit.
- Lock button needs `--allow-lock`, and a person to unlock the device again. A batch refuses input after its own lock step and re-checks the lock after a quiet gap of 25 s or more.
- CoreDevice reports a device without a passcode as unlocked.

## Unsupported and orientation

- `unsupportedOnDevice`: agent snapshots, selected simulator display options, side button, Apple Pay, right-edge swipe preset, `displays`, `shutdown`, `hinge`, `clipboard`, `slider`.
- Bottom-edge preset: unavailable in landscape with the camera on the right. Left-edge preset: unavailable upside down.
- Input, reads, video and `rotate` work on iPhone and iPad in every orientation.
- `rotate` needs Orientation Lock off, else `rotationLocked`.
- `rotationUnconfirmed` (rotate) or `displayOrientationMismatch` (touch): display state lagged the interface, or the app does not support that orientation. No input was sent. Rotate again, then read the screen before more input.

## Stream or record the screen

```bash
axe stream-video --udid "$DEVICE_UDID" --format raw --fps 3 --scale 0.5 > frames.bin
axe record-video --udid "$DEVICE_UDID" --fps 3 --scale 0.5 --output device.mp4
axe stream-video --udid "$DEVICE_UDID" --format h264 > device.h264
```

- Screenshot stream: `mjpeg`, `raw`, `ffmpeg`, `bgra`. FPS is an upper limit.
- Recording writes an H.264 MP4 after a clean stop and prints its path; JSON `{path, pixelWidth, pixelHeight, frames}`; `--verbose` prints the full receipt.
- Native `h264`: Annex B to stdout, device's encoding settings. Omit `--fps`, `--quality`, `--scale`.
- Native frames keep the display's native orientation. When they need turning (iPad in portrait), stderr names the clockwise rotation that shows the interface upright at stream start, or says it could not confirm it.
- Ctrl+C stops. Native shutdown waits for AXe's session to leave device status: about 20 s on the tested iPhone.
- One native display stream at a time. Native `h264` and Xcode Device Hub's screen view replace each other's stream; AXe exits with `deviceStreamReplaced`. Close Device Hub's screen view first, or use the screenshot stream, which works alongside it.
