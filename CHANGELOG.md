# Changelog

All notable changes to the AXe iOS testing framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `axe serve --udid <UDID>` keeps one process open and runs one command per standard input line, answering each with the JSON line `axe --output json` prints. Setup happens once, and serve keeps the input broker running between commands, so reading the screen and tapping took about 176 ms instead of 290 ms on an iPhone 17 Pro simulator (146 ms with `--minimal-keys`). Based on the serve mode proposed in [#70](https://github.com/cameroncooke/AXe/pull/70) by [@alex-hall](https://github.com/alex-hall) and [@dphurley](https://github.com/dphurley).
- `describe-ui --minimal-keys` reads only label, identifier, value, frame, role, role description, type and enabled state, about 30 ms faster on a Settings screen ([#70](https://github.com/cameroncooke/AXe/pull/70) by [@alex-hall](https://github.com/alex-hall)).
- `axe type --layout de|auto` types into simulators with a German hardware keyboard; `auto` reads the simulator's active keyboard ([#95](https://github.com/cameroncooke/AXe/pull/95) by [@scriptease](https://github.com/scriptease))

### Changed
- `axe --output json describe-ui` now takes as long as plain `describe-ui`, about 45 ms less on a Settings screen, with the same output.

## [v2.0.0]

### Physical iPhone and iPad support

AXe now automates connected iPhones and iPads as well as simulators. Pass a device's hardware UDID to the same commands you use on a simulator: screenshots, accessibility reads, taps (by point or by `--id`, `--label` or `--value`), swipes, drags, `draw`, gestures, typing, keys, buttons, batches, `rotate`, `settings`, `record-video` and `stream-video`, including native H.264 with `--format h264`.

```bash
axe list-devices
axe doctor --udid "$DEVICE_UDID"     # pairing, Developer Mode, disk image, lock state
axe describe-ui --udid "$DEVICE_UDID"
axe tap --id "$ELEMENT_ID" --wait-timeout 15 --udid "$DEVICE_UDID"
```

Pair the device in Xcode, turn on Developer Mode and keep it unlocked; AXe never does any of these for you. `button lock` needs `--allow-lock`, and a command a device cannot run fails with `unsupportedOnDevice`. Reading a device's screen takes about 1 second plus 44 ms per element. See [Physical iPhone and iPad](README.md#physical-iphone-and-ipad) and [docs/device-support.md](docs/device-support.md).

### iPhone Duo support

Every input, read and capture command works on the dual-screen iPhone Duo simulator, on whichever screen is active, in any fold and orientation. New commands show the screens and move the hinge:

```bash
axe displays --udid "$UDID"               # each screen's role, size, orientation and the hinge angle
axe hinge set tabletop --udid "$UDID"     # 0...180, or closed, tabletop, open
axe rotate left --udid "$UDID"            # also works on physical devices
```

`--input-mode selected` with `--screen-id` and `--screen-uuid` refuses to act if a different screen becomes active, and `record-video --follow-active-display` records one movie through folds and rotations. See [Displays, hinge and rotation](README.md#displays-hinge-and-rotation) and the [device reference](agent-plugin/skills/axe/references/device-reference.md).

### Agent mode

Add `--agent` to `describe-ui`, `tap`, `type`, `swipe`, `drag`, the key commands, `slider`, `touch`, `gesture double-tap`, `gesture pinch` and `batch` so an AI agent can drive the UI with every action checked. A capture returns compact rows with a ref for each control. An action names a ref, AXe checks the control is still there, sends the input and returns the new screen, so an agent needs no separate read after each action.

```bash
axe describe-ui --agent --view navigation --udid "$UDID"
axe tap --agent --snapshot-id "$SNAPSHOT_ID" --ref e9 --udid "$UDID"
axe type 'Ada' --agent --focus --snapshot-id "$SNAPSHOT_ID" --ref e18 --udid "$UDID"
```

`batch --agent` fills a form in one call, and a refusal sends no input and carries a typed code. Agent mode needs no model or API key. See [Agent mode](README.md#agent-mode) and the [agent reference](agent-plugin/skills/axe/references/agent-reference.md).

### Structured output and error codes

Put `--output json` before a command to get one JSON result with a typed payload, or a typed error code instead of a message to parse. Simulators and devices share one set of error codes, and JSON Schema files describe every result.

```
$ axe --output json tap --id no-such-element --udid "$UDID"
{"command":"tap","data":{},"didError":true,"error":{"code":"elementNotFound","message":"No accessibility element matched --id 'no-such-element'. …"},…}
```

Text output is shorter and consistent too: state commands print their state, input commands print nothing except `tap`, `slider` and `batch`, and errors read as plain sentences. `--verbose` adds the full detail without changing the exit status. See [Output and errors](README.md#output-and-errors) and [schemas/](schemas/).

### Added

- Added `axe settings` for simulators and devices to change appearance, text size, accessibility settings, VoiceOver, simulated location and the simulator status bar (Xcode 27 or later). See [Settings](README.md#settings).
- Added `axe draw` to move one finger through up to 1,000 points. See [Swipes, gestures and drawing](README.md#swipes-gestures-and-drawing).
- Added long press, double tap and two-finger tap to `tap` (`--hold`, `--count 2`, `--touches 2`), on a point or an element. See [Taps, typing and keys](README.md#taps-typing-and-keys).
- Added `--until-id` and `--until-label` to scroll presets and `swipe`, which scroll until an element is on screen, plus `--distance`, `--inside-id` and `--inside-label` for scroll presets.
- Added the `pinch`, `double-tap`, `rotate`, `two-finger-tap`, `two-finger-hold` and `two-finger-swipe` gestures, a `swipe-from-top-right-corner` preset that opens Control Centre, and `--edge-inset` for edge swipes.
- Added `drag --hold` to rest the finger before moving, for reordering a list.
- Added `slider --endpoint minimum|maximum`.
- Added `shutdown` for one simulator and `clipboard copy --stdin` to put text in a simulator's clipboard. See [Simulator shutdown and clipboard](README.md#simulator-shutdown-and-clipboard).
- Added the experimental `axe agent "<goal>"` command, which works towards a plain-language goal one checked action at a time using TypeSafe AI's Jev model. See [docs/agent.md](docs/agent.md).
- Added Claude Code and Codex plugin marketplaces, so the AXe skill stays updated as releases ship ([#64](https://github.com/cameroncooke/AXe/pull/64) by [@tal](https://github.com/tal)). See [AI skill](README.md#ai-skill).

### Changed

- Simulator input and screen reads are much faster than in v1.8.0 (measured on an iPhone 18 Pro simulator): a tap takes about 0.08 s instead of about 1 s, a drag 0.9 s instead of 2.5 s, and `describe-ui` 0.3 s instead of 1.1 to 1.9 s.
- Every command's `--help` is rewritten with a short description, examples and one-line option help, and help that was wrong is corrected.
- The AXe skill that `axe init` installs is rewritten around agent mode.

### Fixed

- Fixed a command sent straight after `button home` on Xcode 27.2 failing with `DTUHID guest barrier timed out`.
- Fixed a command intermittently failing with `setsockopt(SO_RCVTIMEO) failed: Invalid argument`.
- Fixed `touch` leaving a finger held down after a `--delay` over 10 seconds, or after `touch --down` was left without `--up`.
- Fixed an uncaught Objective-C exception crashing AXe; it now prints the exception and exits with 70 ([#77](https://github.com/cameroncooke/AXe/pull/77) by [@sbadakhc](https://github.com/sbadakhc)).
- Fixed an accessibility read in the first seconds after boot breaking accessibility until the simulator was rebooted ([#68](https://github.com/cameroncooke/AXe/pull/68)).
- Fixed gesture presets on iPads and large iPhones acting on a 390×844 corner of the screen instead of the whole screen.
- Fixed `stream-video` sending PNG data as JPEG frames, and MJPEG streams whose frame boundaries did not match their header.
- Fixed `axe init` leaving out the skill's reference files.
- Fixed `tap` printing its error twice when a selector matched nothing, and `batch` hiding a step's validation message.
- Fixed `touch --help` examples using options that do not exist ([#80](https://github.com/cameroncooke/AXe/pull/80) by [@demrom](https://github.com/demrom)).

Various other internal improvements to stability, performance, and code quality.

### Removed

- Building from source no longer clones IDB: its frameworks are in `Packages/IDBKit`, and the `IDB_CHECKOUT_DIR`, `IDB_GIT_URL`, `IDB_GIT_REF` and `IDB_UPSTREAM_BASE_REF` build settings are gone.

## [v1.8.0] - 2026-07-20

### Added

- Added Xcode 27 and iOS 27 simulator automation through Device Hub without requiring Simulator.app, while retaining Xcode 26 support ([#60](https://github.com/cameroncooke/AXe/pull/60) by [@jkaunert](https://github.com/jkaunert)). See [Xcode compatibility](README.md#xcode-compatibility).

### Changed

- Strengthened release supply-chain integrity with immutable, verified IDB sources and stricter validation of release inputs and signing identities.

### Fixed

- Fixed BGRA video streams ignoring the requested `--fps` value and running at an uncapped frame rate.
- Fixed release archives failing strict Gatekeeper verification because of embedded filesystem metadata.
- Fixed commands exposing low-level simulator errors instead of actionable failure messages.

Various other internal improvements to stability, performance, and code quality.

## [v1.7.1] - 2026-06-02

### Added

- Added AxePlayground alert, sheet, context menu, modal navigation, and long-scroll fixtures for UI automation regression coverage.

## [v1.7.0] - 2026-05-11

### Added

- Added `axe slider --id/--label --value 0...100` for selector-based slider setting with orientation-aware HID dragging and AXValue tolerance verification/failure reporting.
- Added `axe drag --start-x/--start-y --end-x/--end-y` for raw point-to-point low-level HID drag validation using explicit touch move events.

### Changed

- Changed `axe slider` to use the shared composite low-level HID drag path with AXValue tolerance verification instead of retrying with correction gestures.

### Fixed

- Fixed `describe-ui` and selector-based `tap --label` exposing and activating real SwiftUI `TabView` tab items, navigation search fields, toolbar segmented picker items, and generated navigation back buttons from the CoreSimulator accessibility bridge. Also fixed selector decoding when the accessibility tree contains numeric `AXValue` fields such as sliders.
- Fixed `tap`, `touch`, `swipe`, and matching batch steps dispatching logical UI coordinates directly to FBSimulatorHIDEvent without landscape rotation or letterbox correction, causing interactions to land in the wrong location in rotated landscape simulators and portrait-hardware landscape-only apps. AXe now detects the simulator UI orientation automatically instead of requiring callers to pass landscape flags ([#5](https://github.com/cameroncooke/AXe/issues/5) by [@Nitewriter](https://github.com/Nitewriter))
- Fixed selector-based `tap` and batch tap steps so UIKit `UISwitch` and SwiftUI `Toggle` controls can be activated reliably, including when a matched row or label contains a single switch/toggle control. Added `--tap-style` so switch/toggle taps can use physical touch automatically while normal taps keep the simulator `tapAt` path by default ([#46](https://github.com/cameroncooke/AXe/pull/46)).
- Fixed element comparison in `AccessibilityTargetResolver` to prevent distinct elements with the same type and frame but lacking labels/values from being incorrectly identified as identical during ancestor tree traversal.

## [v1.6.0] - 2026-04-05

### Added

- Added `--value` targeting for `tap`, allowing elements to be matched by their accessibility value in addition to `--id` and `--label`. Added `--element-type` filtering to narrow matches by element type (e.g., button, text field) ([#40](https://github.com/cameroncooke/AXe/pull/40) by [@andresdefi](https://github.com/andresdefi)).
- Added `--wait-timeout` and `--poll-interval` options to `tap` for waiting until a matching element appears before tapping ([#40](https://github.com/cameroncooke/AXe/pull/40) by [@andresdefi](https://github.com/andresdefi)).

### Fixed

- Fixed `describe-ui` to expose and implement the documented `--point` option in command help and runtime behavior ([#38](https://github.com/cameroncooke/AXe/issues/38))

## [v1.5.0] - 2026-03-04

### Added

- Added `batch` command for executing ordered multi-step interaction workflows in a single invocation, with sequential execution that supports multi-screen flows, built-in `sleep` delays, accessibility caching, and configurable text submission strategies ([#25](https://github.com/cameroncooke/AXe/pull/25)). See [BATCHING.md](BATCHING.md).
- Added `axe init` command to install, uninstall, or print the AXe skill for AI clients (`claude`, `agents`) or a custom destination ([#25](https://github.com/cameroncooke/AXe/pull/25)).

### Fixed

- Fixed Homebrew installation on Intel Macs by producing architecture-specific release artifacts ([#27](https://github.com/cameroncooke/AXe/pull/27), [#21](https://github.com/cameroncooke/AXe/issues/21))
- Fixed `tap --label` resolving ambiguous matches by preferring actionable elements over read-only ones ([#28](https://github.com/cameroncooke/AXe/pull/28))

## [v1.4.0] - 2026-02-08

### Added

- AxePlayground Touch Control now shows long-press count and last long-press coordinates, making gesture automation easier to validate.

### Fixed

- Improved long-press reliability for `axe touch`: `--down --up --delay` now consistently behaves like a real press-and-hold gesture.

## [v1.3.0] - 2026-01-28

- Add `key-combo` command for atomic modifier+key presses (e.g., Cmd+A, Cmd+Shift+Z) Thanks to @jpsim for the contribution!

## [v1.2.0] - 2025-12-19

-Add support for screenshot capture to PNG
-Add tap by label or accessibility id in addition to existing x/y coordinates
-Fix FBProcess duplication warnings

Special thanks to @aliceisjustplaying and @onevcat for their execellent contributions!

## [v1.1.1] - 2025-09-22

-Pin IDB version to address access control issues on new versions


## [v1.1.0] - 2025-09-21

- Add support for streaming and video capture (thanks to @pepicrft for the contribution!)


## [v1.0.0] - 2025-06-01

- Initial release of AXe
- Complete CLI tool for iOS Simulator automation
- Support for tap, swipe, type, key, touch, button, and gesture commands
- Built on Meta's idb frameworks with Swift async/await
- Comprehensive test suite with AxePlaygroundApp
- Gesture presets and timing controls
- Accessibility API integration

## [v0.1.1] - 2025-09-21
- README updates

## [v0.1.0] - 2025-05-27

- Initial release of AXe
