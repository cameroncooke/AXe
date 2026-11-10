# Physical iPhone and iPad

Run `axe list-devices` and use the hardware UDID from that list. Each command below uses the same target.

```bash
axe list-devices
axe doctor --udid "$DEVICE_UDID"
axe screenshot --udid "$DEVICE_UDID" --output screen.png
axe describe-ui --udid "$DEVICE_UDID"
```

Pair the device in Xcode, enable Developer Mode and unlock the device. Resolve the checks reported by
`doctor` before continuing. Use `axe --output json doctor --udid "$DEVICE_UDID"` for structured checks.
Open the saved screenshot to verify what is visible.

## Input and readback

Use logical points in the current orientation. A PNG contains pixels. Use a fresh device tree
for exact IDs, labels or values. AXe checks that the selector resolves to one visible target and
that the target still owns the tap point. Re-read the screen after input to check its effect.

```bash
axe describe-ui --udid "$DEVICE_UDID" --point 160,240
axe tap --udid "$DEVICE_UDID" --id "$ELEMENT_ID"
axe tap --udid "$DEVICE_UDID" --id "$ELEMENT_ID" --wait-timeout 15 --poll-interval 0.25
axe tap --udid "$DEVICE_UDID" --semantic-press --id "$CHECKBOX_ID"
```

Semantic press requires an exact ID for a visible native checkbox. AXe checks the native reply
and the changed Boolean value, then prints `Switch <id>: off -> on`; JSON is `{identifier, before,
after}` and `--verbose` prints the full receipt. If the outcome is uncertain, read the screen before
any more input.
If a modal alert blocks the tree, close the alert on the phone and read again.

Coordinate taps, swipes, drags, draws, gestures, touch, rotation, typing, key commands, buttons and batches
use the same hardware UDID. Focus the field before typing; `type` sends up to 256 UTF-8 bytes per
command with the US key layout. Standalone touch requires both
`--down` and `--up`. A physical batch can hold a contact across steps and releases it on exit.
The lock button requires `--allow-lock` and a person to unlock the device again. A batch refuses
input after its own lock step, and checks the lock again after a quiet gap of 25 seconds or more.
CoreDevice reports a device without a passcode as unlocked.

Physical devices do not accept agent snapshots, selected simulator display options, side button,
Apple Pay, the right-edge swipe preset, `displays`, `shutdown`, `hinge`, `clipboard` or `slider`; each
returns `unsupportedOnDevice`. The bottom-edge preset is unavailable in landscape with the camera on the
right, and the left-edge preset upside down.

Input, reads, video and `rotate` work on iPhone and iPad in every orientation. `rotate` needs
Orientation Lock off and otherwise returns `rotationLocked`. If `rotate` returns
`rotationUnconfirmed` or a touch returns `displayOrientationMismatch`, the device's display state
lagged behind the interface or the app does not support that orientation. No input was sent. Rotate
again, then read the screen before more input.

## Stream or record the screen

```bash
axe stream-video --udid "$DEVICE_UDID" --format raw --fps 3 --scale 0.5 > frames.bin
axe record-video --udid "$DEVICE_UDID" --fps 3 --scale 0.5 --output device.mp4
axe stream-video --udid "$DEVICE_UDID" --format h264 > device.h264
```

The screenshot stream supports `mjpeg`, `raw`, `ffmpeg` and `bgra`. The requested FPS is an upper
limit. Recording writes an H.264 MP4 after a clean stop. Native `h264` writes Annex B to stdout and
uses the device's encoding settings. Leave out `--fps`, `--quality` and `--scale` in this format.
Native frames keep the display's native orientation. When they need turning, as on an iPad in
portrait, stderr names the clockwise rotation that shows the interface upright at the start of the
stream, or says it could not confirm the orientation.
Press Ctrl+C to stop. Native shutdown waits for AXe's session to disappear from device status.
This can take about 20 seconds on the tested iPhone.

The device sends one native display stream at a time. Native `h264` and Xcode Device Hub's screen
view replace each other's stream; AXe then exits with `deviceStreamReplaced`. Close Device Hub's
screen view before a native stream, or use the screenshot stream, which works alongside it.
