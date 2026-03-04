# Changelog

All notable changes to the AXe iOS testing framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added `batch` command for executing ordered multi-step interaction workflows in a single invocation with a shared simulator session. Supports all interaction commands (`tap`, `swipe`, `gesture`, `touch`, `type`, `button`, `key`, `key-sequence`, `key-combo`), explicit `sleep` delays between steps, accessibility caching (`--ax-cache`), configurable text submission strategies (`--type-submission`), and element polling for multi-screen flows (`--wait-timeout`, `--poll-interval`). See [BATCHING.md](BATCHING.md).
- Added `axe init` command to install, uninstall, or print the AXe skill for AI clients (`claude`, `agents`) or a custom destination.

### Fixed

- Fixed `axe batch` noisy stderr output by default; added `--verbose` for opt-in troubleshooting logs.
- Fixed `tap --label` resolution to prefer actionable elements (for example, buttons) when a label is shared with read-only elements.
- Fixed selector ambiguity guidance for `tap --label` collisions by clarifying when to fall back to coordinates if no `AXUniqueId` values are exposed.
- Fixed Homebrew installation failing on Intel Macs ([#27](https://github.com/cameroncooke/AXe/pull/27), [#21](https://github.com/cameroncooke/AXe/issues/21))

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
