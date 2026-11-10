# Changelog

All notable changes to the AXe iOS testing framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added automation for connected iPhones and iPads. Find a device with `list-devices`, check it with `doctor` (pairing, Developer Mode, connection, developer disk image, lock state and screenshot service), then pass its hardware UDID to `screenshot`, `describe-ui`, taps, swipes, drags, gestures, typing, keys, buttons, batches, `rotate`, `record-video` and `stream-video` (including native `--format h264`). AXe never pairs, enables Developer Mode, mounts disk images or unlocks a device; `button lock` needs `--allow-lock`, and commands a device cannot run fail with `unsupportedOnDevice`.
- Added iPhone Duo simulator support: every input, read and capture command uses the measured active screen in any fold and orientation. `axe displays` shows each screen's role, size in points, orientation and state, and the hinge angle; `hinge read` and `hinge set <0-180|closed|tabletop|open>` read and move the hinge; `rotate left|right` turns the Duo (and physical devices).
- Added `--input-mode selected` with optional `--screen-id`/`--screen-uuid` and `--expected-pid` guards, so input refuses instead of acting on another screen or app, and selected-screen `screenshot`, `record-video` and `stream-video`. `record-video --follow-active-display` records one movie across folds and rotations.
- Added agent mode (`--agent`) on `describe-ui`, `tap`, `type`, `swipe`, `drag`, `key`, `key-combo`, `key-sequence`, `slider`, `touch`, `gesture double-tap`, `gesture pinch` and `batch`. A capture returns compact `ref|actions|role|label|value` rows (`--view navigation|reading|full`); an action names a ref, AXe checks that the target is still that control, sends the input and returns the settled screen. It adds `type --focus`, `--read-ref` for exact fields, `tap --label-contains`, `--label-regex` and `--frame`, JSON `batch --agent` steps with `"focus": true` to fill a form in one call, typed refusal codes and `AXE_TIMING` phase timing. It needs no model or API key.
- Added the experimental `axe agent "<goal>"` command, which reaches a natural-language goal with TypeSafe AI's Jev model, one checked action at a time. Base URLs must use HTTPS, except for `localhost`, `127.0.0.1` or `::1`. See [docs/agent.md](docs/agent.md).
- Added `axe settings` for simulators and connected devices (Xcode 27 or later): `show` and `set` for appearance, text size, Increase Contrast, Reduce Motion, Reduce Transparency, Show Borders, Liquid Glass, colour filters and VoiceOver; `settings location` for a simulated coordinate or named scenario; `settings status-bar` presets and overrides on simulators.
- Added `axe draw <x,y> <x,y> … [--close] [--duration s]`, which moves one finger through 2 to 1,000 points, standalone and as a batch step.
- Added coordinate gestures `pinch`, `double-tap`, `rotate`, `two-finger-tap`, `two-finger-hold` and `two-finger-swipe`, with no mode flag; `gesture pinch --scale 2` alone pinches at the screen centre. Edge presets accept `--edge-inset`.
- Added `--output text|json`: ordinary commands return one `axe.output.command-result` with a typed `data.result`, the full command path in `command`, and `error: {code, message}` from one error vocabulary exactly when `didError` is true. JSON Schema files for the envelope, every command's payload and the agent result are in [schemas/](schemas/).
- Added `shutdown --udid <UUID>` to shut down one simulator and confirm it, and `clipboard copy --stdin` to stage verified UTF-8 text in a simulator's clipboard.
- Added `slider --endpoint minimum|maximum` and native value feedback for `slider --value` on the Duo and on sliders with a stable ID, and `tap --semantic-press --id` for one native checkbox.
- Added Claude Code and Codex plugin marketplaces for the AXe skill, so a marketplace install keeps the skill updated as releases ship ([#64](https://github.com/cameroncooke/AXe/pull/64) by [@tal](https://github.com/tal)).

### Changed

- Ordinary `tap`, `swipe`, `drag`, gesture presets and complete `touch --down --up` on simulators reuse one input connection instead of opening and draining a new one per command. On iPhone 18 Pro a swipe takes about 1.2 s (v1.8.0: 1.9 s), a drag 1.7 s (2.5 s), a touch 0.25 s (1.1 s) and a preset 0.7 s (1.25 s); repeated taps about 0.15-0.2 s. Physical-style taps on this route hold for 0.1 seconds.
- Plain `describe-ui` reads the tree directly, with the accessibility bootstrap only after an empty tree or a failed point read, and reads each element's attributes in one request; a description takes about 0.3 s instead of 0.5 s. Output is unchanged.
- Commands print a short, consistent result: state commands print their state, input commands print nothing except `tap`, `slider` and `batch`, and media commands print the path. Errors print a message without Swift type descriptions; `--verbose` adds the full receipt and never changes the exit status or code. SIGINT or SIGTERM exits with 128 + the signal.
- The AXe skill that `axe init` installs is rewritten around agent mode, with references for batches, devices, settings and recording.
- AXe builds its IDB frameworks from the in-repository `Packages/IDBKit` instead of a cloned, patched IDB fork; `make build` and `make test` rebuild them only when they are stale.

### Fixed

- An uncaught Objective-C exception no longer aborts AXe with SIGABRT and a crash report; AXe prints the exception and exits with `EX_SOFTWARE` (70), and a sandbox-related ROCKit failure says to run AXe outside the sandbox ([#77](https://github.com/cameroncooke/AXe/pull/77) by [@sbadakhc](https://github.com/sbadakhc)).
- An accessibility read made in the first seconds after a simulator boots no longer breaks accessibility on that simulator until it is rebooted; reads on runtimes 27 and later wait, for up to 60 seconds, until a display reports its state ([#68](https://github.com/cameroncooke/AXe/pull/68) by [@BariBariGood](https://github.com/BariBariGood)).
- `touch --help` examples use the accepted `-x` and `-y` options ([#80](https://github.com/cameroncooke/AXe/pull/80) by [@demrom](https://github.com/demrom)).
- `axe init` installs the whole skill, including the `references/` files SKILL.md links to, and `--force` replaces the installed directory as a whole.
- `tap` with a selector that matches nothing prints its error once, instead of a `Warning:` line and then the same error.
- `stream-video` no longer sends PNG bytes as JPEG frames at the default quality and scale.
- `batch` validation errors show the step's message instead of a generic system error.

### Removed

- The `IDB_CHECKOUT_DIR`, `IDB_GIT_URL`, `IDB_GIT_REF` and `IDB_UPSTREAM_BASE_REF` build settings, and the unused `FBDeviceControl` and `XCTestBootstrap` frameworks, which are no longer built or shipped.

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
