# Changelog

All notable changes to the AXe iOS testing framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added new `batch` command to execute ordered interaction steps (`tap`, `swipe`, `gesture`, `touch`, `type`, `button`, `key`, `key-sequence`, `key-combo`) in one invocation with a shared simulator/HID session.
- Added `sleep <seconds>` pseudo-step for explicit per-step delays in batch flows.
- Added batch options for accessibility caching (`--ax-cache`) and type submission strategy (`--type-submission chunked|composite`, `--type-chunk-size`).
- Added `--wait-timeout` and `--poll-interval` options to `batch` for polling selector-based elements that appear after earlier steps execute (e.g., multi-screen flows).
- Added `axe init` command to install, uninstall, or print the AXe skill for detected AI clients (`claude`, `agents`) or a custom destination.

### Changed

- Batch now executes steps sequentially (parse-one-execute-one) instead of pre-resolving all selectors upfront, enabling multi-screen flows where earlier taps trigger navigation.

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
