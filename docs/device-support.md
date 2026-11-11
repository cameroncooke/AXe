# Physical device support

How AXe drives a connected iPhone or iPad, what it supports and where it stops. Wire formats are in [device-protocols.md](device-protocols.md); usage is in the [physical device reference](../agent-plugin/skills/axe/references/physical-device-reference.md).

## Rules

- Devices use the same commands, options and error codes as simulators. `--udid` decides the target: AXe looks the UDID up in the simulator set first, then in CoreDevice's device list, and `targetNotFound` names both.
- AXe never pairs a device, enables Developer Mode, mounts a developer disk image or unlocks the device. `doctor` detects each of these and prints the fix.
- AXe uses the connection that Xcode's CoreDevice manages. It does not create its own tunnel.
- Anything a device cannot do fails with `unsupportedOnDevice` before any work.
- Protocol code is written from [device-protocols.md](device-protocols.md) and AXe's own captures, never ported from GPL code (pymobiledevice3).
- `devicectl` output is read only through its JSON file output, accepting both the current `properties` shape and the older `connectionProperties`/`deviceProperties` shape.

## How a command reaches a device

1. CoreDevice (`devicectl device info details`) gives the tunnel address and the pairing, Developer Mode, connection, disk image and lock state. An idle network tunnel is reconnected by this call; `list-devices` reports it as unchecked rather than blocked.
2. AXe finds the device's service directory (RSD) port on that tunnel, connects, and checks the device's `UniqueDeviceID` against the hardware UDID before opening any service.
3. A per-device broker process holds the RSD session, the HID connection and the accessibility channel across commands, so a warm command opens no connection. A broker from a different AXe build is refused (`deviceBrokerMismatch`) until it exits on its idle timeout.
4. A command reads the device's readiness and lock state from CoreDevice when it starts: two `devicectl` runs, about 0.5 s together. It skips them when the broker sent input to the device in the last 25 seconds, because that input went through a working connection to an unlocked device and restarted its auto-lock timer. A failed operation or `button lock` ends that, so the next command reads again. A batch checks the lock state before input that follows a quiet gap of 25 seconds or more, and refuses input after its own `button lock` step. CoreDevice reports a device without a passcode as unlocked, even on the lock screen.
5. A read of the accessibility tree is a new request to the device each time. The device answers in about 1 s plus 44 ms per element, in two parts; the identifiers come in the second. A read may take 20 seconds, which is about 330 elements; beyond that it fails with `treeUnavailable`. `tap --id`, `--label` or `--value` taps from one read. Only a target that appeared while `--wait-timeout` was polling is read a second time, and the tap is refused with `targetChanged` if it moved.

| Capability | Service |
| --- | --- |
| Screenshots, screenshot streams and recordings | `com.apple.coredevice.screencaptureservice` |
| Display size and orientation | `com.apple.coredevice.deviceinfo` (`displayinfo`) |
| Touch, keyboard and buttons | `com.apple.coredevice.hid.indigo` |
| `rotate` | `com.apple.coredevice.devicecontrol` |
| Accessibility trees, point lookups, semantic press | `com.apple.accessibility.axAuditDaemon.remoteAXService` (DTX) |
| Native H.264 (`stream-video --format h264`) | `com.apple.coredevice.displayservice` |
| `settings` | `xcrun devicectl` |

## Supported and refused

Supported: `list-devices`, `doctor`, `screenshot`, `describe-ui` (including `--point`), `tap` by coordinates or `--id`/`--label`/`--value` with polling, `tap --semantic-press` on a native checkbox, `swipe`, `drag`, `draw`, `gesture` presets and coordinate gestures, `touch --down --up`, `type`, `key`, `key-sequence`, `key-combo`, `button home|lock|siri`, `batch` (which can hold a contact across steps and releases it on exit), `rotate`, `stream-video` (`mjpeg`, `raw`, `ffmpeg`, `bgra`, `h264`), `record-video` and `settings` apart from the status bar.

Refused with `unsupportedOnDevice`: agent mode, `--input-mode selected` and the screen options, `displays`, `shutdown`, `hinge`, `clipboard`, `slider`, `button side-button` and `apple-pay`, the `swipe-from-right-edge` preset, and a standalone `touch` without both `--down` and `--up`. `settings status-bar` fails with `settingUnsupported`. The bottom-edge preset is unavailable in landscape with the camera on the right, and the left-edge preset upside down.

## Orientation

The digitizer takes points normalized to the device-portrait frame: the display's current mode size, with its axes swapped when the native orientation is `rot90` or `rot270`, divided by the UI scale. The interface rotation is `(currentOrientation + nativeOrientation) mod 360`; on an iPhone (native `rot0`) that is `currentOrientation` alone. On panels whose native orientation is not `rot0`, such as the iPad Pro's `rot270`, every touch, point lookup and screenshot video first compares the device's reported orientation with the display and returns `displayOrientationMismatch` without input when they disagree, because an iPad can keep reporting its previous display orientation after a software rotation. `rotate` needs Orientation Lock off (otherwise `rotationLocked`) and succeeds only when the display reaches the orientation the device reports; it returns `rotationUnconfirmed` once the display has stood still for 2.5 seconds without reaching it, for example when an iPhone is asked to turn upside down.

## Known limitations

- The device sends one native display stream at a time. Native H.264 and Xcode Device Hub's screen view replace each other's stream, and AXe then exits with `deviceStreamReplaced`. Screenshots, screenshot streams, recording, reads and input work alongside Device Hub.
- Native H.264 frames keep the panel's native orientation. AXe passes them through and states on stderr how many degrees clockwise to rotate them. Stopping waits for the session to disappear, which can take about 20 seconds.
- Status bar overrides are simulator-only.
- Devices with native `rot90` or `rot180` panels follow the orientation rule but are untested.
- The lock button needs `--allow-lock`, and a person must unlock the device again.
- If a modal alert blocks the accessibility tree, close it on the device and read again.
- `type` sends up to 256 UTF-8 bytes per command with the US key layout; focus the field on the device first.

## Device test suite

```sh
DEVELOPER_DIR=/absolute/path/to/Xcode.app/Contents/Developer make e2e-devices
```

The suite is opt-in and exits 1 before building when no physical iPhone or iPad is paired. It installs the Playground on each device and reads every result back from the device; see [Playground testing](playground-testing.md#physical-devices) for the checks, environment variables and what it does not cover. Unit tests in `Tests/PhysicalDeviceFixtureTests.swift` cover both CoreDevice JSON shapes, readiness states, the RemoteXPC codec and the orientation rule without hardware.
