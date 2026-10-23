# Changelog

All notable changes to the AXe iOS testing framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Add standalone selected and optional agent slider percentages with current target checks, guarded retained input and bounded native value feedback. Interior values use the current measured display context and require horizontal native scrubber geometry that increases from left to right; numeric 0/100 use the existing endpoint route before input. Raw sliders and endpoint batches stay unchanged. CLI wire 34 and matching native frameworks are required. Isolated controllers checked outer portrait and inner rotation 90 only; the incremental CLI build and public simulator verification remain pending. RTL, custom and vertical Sliders remain unproved.
- Added optional `batch --agent --file` for 1...8 exact-ID tap/type steps on one app, with fresh target resolution, existing per-action input guards, ordered completion receipts and stop-on-failure without rollback or replay. Legacy and selected batches are unchanged. CLI wire 33 carries the batch request; native frameworks and RS/1 rows are unchanged. The isolated build, four guide checks and 132 existing checks in 13 suites passed across separate runs. Six outer-portrait checks proved an ordered field tap/type/Button workflow, refusals and raw/selected compatibility. One fold after a released first tap stopped the remaining steps and allowed a fresh outer reference tap. Earlier failures remain recorded; mid-action interruption and other workflows remain unverified.

- Added explicit `record-video --follow-active-display` for one-boot measured display changes, with per-frame context checks, bounded read-only transition recovery and a fixed aspect-fit canvas. Existing selected and legacy recording stay unchanged. Movie gap statistics are reported. Two low-rate Duo movies passed opening, closing and inner rotation checks, with decoded fixed-canvas frames, proportional black bars and clean SIGINT save; this does not prove smooth animation.

- Added standalone `gesture pinch --agent` for a current area reference, with fresh checks on both starting-point hits before either touch starts. Existing target/scroll actions, raw presets and selected coordinate gestures remain unchanged. The complete pinch uses existing motion bounds, context checks and both-contact release; agent batches reject. CLI wire 32 adds the request without native or RS/1 changes. The isolated build and ten scoped normal checks passed. One fold and one inner 90→180 rotation each released both contacts and allowed a fresh reference Button tap. Earlier failed runs remain recorded; other controls, positions and change combinations remain unverified.

- Added standalone `slider --agent --endpoint minimum|maximum` for current slider references, with fresh snapshot/PID/context, native target/value/domain checks and final owned-handle admission before each adjustment. Agent receipts include bounded semantic action counts and endpoint values. Existing raw percentages and selected selectors are unchanged; mixed options and agent batches reject. CLI wire 31 and matching rebuilt native frameworks are required. The 05ce8806 build, 47 existing checks and nine scoped agent subchecks passed on one v6 outer-portrait Slider. The full V2 run remains failed on a proof preparation expectation; retrospective readback supports the actual default-selected route only. Wider domains, poses, interruptions and percentages remain open.

- Added standalone `clipboard copy --stdin --udid <UUID>` to stage bounded exact UTF-8 bytes through public CoreDevice, with private exact readback and a JSON transport receipt (`inserted: false`). Shared clipboard replacement is explicit; no automatic Paste, retry, fallback or restore is added. The 8558f716 build, 11 existing checks and seven native checks passed. One v6 outer-portrait workflow inserted the exact 22-byte sample through separate key 101 and a fresh Paste Button tap with one app callback and released input. Empty-open-stdin SIGINT/SIGTERM also passed; running-child cancellation, automatic Paste and other app/menu support remain unproved.

- Added standalone `gesture double-tap --agent` for a current tap-capable reference, with fresh target/point checks, bounded timing, context checks and owned release. Coordinates, other gesture payloads and agent batch use reject. CLI wire 30 isolates the new request; native frameworks and raw/selected gesture paths are unchanged. The isolated build, 96 existing checks and seven scoped native checks passed, proving one visible Button counter change, release, refusal and selected coordinate compatibility on outer portrait. Two native keyboard suites were skipped; wider timing, role, pose and interruption proof remains open. Earlier build/proof failures remain recorded.

- Added standalone `key-sequence --agent` for complete key presses on a current focused TextField reference, with snapshot/PID/focus checks and owned key release. Inter-key delay and sequence bounds apply before input; agent batch and focus-ID overrides reject. Raw/selected behavior and native frameworks are unchanged. CLI wire 29 separates the new request kind from older brokers. The isolated build passed; existing output reported 68 tests in seven suites, with two native suites skipped. The full outer-portrait run passed eight saved checks including one setup, proving a default two-Backspace effect, three before-input refusals and raw/selected sequence compatibility. Wider keys, delays and interruption cases remain open.

- Added selected Siri, Lock and Apple Pay button commands and batch steps with measured context, optional boot checks and typed release evidence. Apple Pay keeps the native two-side-press adaptation and four-event receipt. CLI wire 28 separates these capabilities from wire 27 brokers; native frameworks and raw button routes are unchanged. The isolated build, 153 existing checks and scoped native delivery/release checks passed. Selected Siri UI, Wallet UI and wider button checks remain open.

- Added standalone `key-combo --agent` for complete modifier shortcuts on a current focused TextField reference, with snapshot/PID/focus checks and owned key release. Raw and selected combinations remain unchanged; agent batch and focus-ID overrides reject. The isolated build, 42 existing checks and 15 scoped native subchecks passed. A later older selected-path timeout and a separate startup failure remain recorded.

- Added standalone `key --agent` for one default key down/up on a current focused TextField reference, with snapshot/PID/focus checks and owned release. Duration, focus-ID overrides and batch use reject; raw and selected key behavior is unchanged. Focused Backspace, stale/wrong-app/unfocused rejection and raw/selected compatibility passed on the isolated Duo outer-portrait candidate.

- Added complete `touch --agent --ref` presses and timed holds with fresh native target/hit checks, owned release and snapshot refresh. Coordinate touch behavior is unchanged; partial contacts, retained tokens and batch agent use reject. Build and native verification remain pending.

- Added `shutdown --udid <UUID>` for one simulator through public `simctl`, with confirmed Shutdown state, distinct `alreadyShutdown` output and no all-device alias. This is simulator lifecycle control, not guest lock or power-button input.

- Added optional `drag --agent` from an existing snapshot target/scroll reference to an explicit logical endpoint. The start uses fresh native target and hit validation; existing owned drag limits, context checks and release remain. Raw drag is unchanged, and batch use rejects. Scoped native checks passed for inner-landscape reference drags and fold release/fresh-tap recovery; a later restoration failure remains recorded.
- Added standalone selected `gesture two-finger-swipe` with independent straight start/end paths, shared duration/spacing and existing measured input/cleanup. Either finger may stay still. Simultaneous coincident contacts reject before input, including between samples. Batch and agent mode remain unsupported. Selected wire 27 rejects old wire 26 requests. Native checks passed for inner-landscape paths, one stationary finger, zero-input bounds/collision rejection and fold release/fresh-tap recovery; existing pinch and rotation compatibility also passed.

- Added `hinge set closed|tabletop|open` as names for 0, 90 and 180 degrees. Numeric angles, options, JSON output, measured mechanical completion and separate screen readiness checks remain unchanged.
- Added agent-only `tap --label-contains`, `--label-regex` with Foundation regex syntax, and logical-point `--frame` filters for explicit selectors. Queries use bounded fresh native-tree resolution, reject ambiguity and retain exact native target/context checks before input. Existing exact/ref routes and no-flag behavior remain. Older brokers reject new selector payloads rather than ignore filters.
- Added optional agent-capture software-keyboard evidence from the existing selected app accessibility read, with separate signal counts and `likelyVisible` or `unknown` state. Missing evidence never reports the keyboard as hidden; raw no-flag output is unchanged.

- Added opt-in `--agent` snapshots and guarded reference actions on `describe-ui`, `tap`, `type` and `swipe`, with compact RS/1-style output, bounded broker state, immutable snapshot IDs and fresh context/target validation. Existing commands without the flag retain their raw output and coordinate route. Selected wire 23 rejects old wire 22 requests.

- Added bounded wait/poll options for ordinary selected ID, label and value taps and individual batch tap steps. Only absent matches retry; device changes and disconnected clients stop the wait before a late tap. Selected wire 22 rejects old wire 21 requests.

- Added `rotate left|right` for the verified Duo profile, with explicit active-screen and boot checks, one device-wide request, stable rotation readback and the common input lock. Selected wire 21 rejects old wire 20 requests. App layout readiness requires a fresh UI read.
- Added local arm64 Duo display selection, measured coordinate transforms, guarded HID sessions, complete multi-touch gestures, native slider endpoints and hinge read/set with display readiness.
- Added selected text and key input with an explicit field/PID check before each key down and owned key release on interruption.
- Added `list-simulators --displays --udid` for measured display discovery and explicit `tap --semantic-press --id` for one native CheckBox on the inspected host framework image, with no mouse or HID fallback.
- Added selected `describe-ui --point` with oriented coordinates, exact foreground/result PID checks and one bounded point read.
- Added active-panel PNG screenshots with paired `--screen-id`/`--screen-uuid`, optional `--expected-boot`, context checks and a JSON receipt. Selected capture does not replace existing output files or fall back to another display; surface identity and frame presentation time remain unavailable.
- Added batch-level selected display input for complete tap, swipe, gesture, touch and keyboard steps, with fresh per-step guards, structured receipts and stop-on-failure behavior. Unsupported steps reject without legacy fallback; legacy batches remain unchanged.
- Added explicit `gesture --edge-inset` for the start of the four edge presets in legacy and selected routes, including batch steps. The opposite 20-point endpoint and existing defaults are unchanged. Explicit legacy insets require a path span of at least the effective delta; navigation effects still require separate verification.
- Added explicit selected-screen `record-video` with per-frame context checks, awaited signal stop and publication of completed MP4 files without replacing existing output. Selected clips require one fixed pose; recording across rotation or folding remains incomplete.
- Added fixed-pose selected `stream-video` for multipart JPEG, length-prefixed JPEG, concatenated JPEG and packed BGRA. The route shares validated capture ownership with selected recording, reports metadata on stderr and stops on context or output failure; legacy streaming is unchanged.
- Added selected batch `drag` steps through the existing guarded drag route, with standalone options and defaults, per-step fresh bounds and stop-on-failure receipts. Legacy batch drag remains unsupported.
- Added selected batch slider endpoint steps with exact ID/PID selection and semantic value-readback completion, including an already-at-endpoint result with no action. Unsupported options and failed receipts stop later steps; legacy batch slider remains unsupported.
- Added standalone selected `button home` with active-display context and optional exact boot guards, preserved hold durations and typed transport execution/cleanup evidence. Home remains a device-wide action.
- Added selected batch `button home` through the existing guarded Home request, with optional per-step boot and duration checks and typed release completion. Other buttons remain unsupported; a failed receipt stops later steps without replay.
- Added matched `bootIdentity` and a host-monotonic `readInterval` to `list-simulators --displays --udid` JSON, preserving its existing fields. This read evidence does not replace fresh input/capture checks or change default legacy capture.
- Added exact, case-sensitive `--element-type` filtering for ordinary selected ID/label taps and their batch steps, before uniqueness and final target validation. Selected protocol versioning prevents older brokers from ignoring the filter; legacy taps are unchanged.
- Added ordinary selected `tap --value` and matching batch steps, with legacy scalar text conversion, trimmed case-sensitive matching, optional exact type and strict fresh target checks. Coordinate-selector combinations and value-based semantic press remain unsupported.
- Added explicit `--tap-style physical` for ordinary selected coordinate and ID/label/value taps, including tap steps in selected batches, through the existing guarded touch path. Omitted style and legacy behavior are unchanged; semantic press rejects every explicit style.
- Added explicit `--tap-style simulator` for ordinary selected coordinate and ID/label/value taps and their batch steps. It uses the real `tapAt` down/up sequence without an inserted hold, while retaining target/context/cleanup guards and pre/post delays. Omitted/physical style and legacy behavior remain unchanged. Selected wire 16 carries the typed style and rejects old wire 15 requests; exact timing parity is not guaranteed.

- Added explicit `--tap-style automatic` for ordinary selected taps and their batch steps. Coordinates use simulator `tapAt`; selectors use the existing switch/toggle classification on the resolved target and recheck the style choice before the first down. Target/context/cleanup guards remain strict, with no legacy redirection or retry after failure. Selected wire 17 rejects old wire 16; omitted, physical and simulator behavior remain unchanged. This does not establish full switch support or exact timing parity.

- Added selected batch `sleep` as a cancellable host wait for finite non-negative durations, with typed wait receipts, no input lease and fresh guards on the next input step. Legacy sleep behavior is unchanged.
- Added optional exact, case-sensitive `--element-type` filtering for selected slider ID endpoints and their batch steps. Global ID uniqueness and native Slider role, value-domain and fresh-target checks remain required. Selected wire 18 rejects old wire 17 requests; legacy slider behavior is unchanged.

- Added exact-label selection for selected slider endpoints and their batch steps. Labels match case-sensitively after whitespace/newline trimming, with duplicate matches rejected before the optional type filter. A native Slider can be selected without an ID; PID, context, frame, domain and fresh owned-target checks remain required. Selected wire 19 rejects old wire 18 requests. ID selection and legacy behavior are unchanged.

- Added selected batch `type --stdin` through the existing bounded text loader and keyboard guards. Text is read at its ordered step; invalid input stops later steps. The synchronous EOF read has no deadline or cancellation while blocked; use batch `--step` or `--file` so stdin remains available for text.

- Added selected `button side-button` and matching batch steps with active-context and optional boot guards, preserved duration, and typed transport execution/cleanup evidence. Wire 20 rejects old wire 19 requests. This does not prove lock, wake, power or security state; Home and legacy routes are unchanged.

### Changed

- Build IDB from a tracked patch against the exact fork base without discarding unexpected source changes. Local Duo builds currently require `AXE_BUILD_ARCHS=arm64`; universal release validation remains open.
- Added `scripts/build.sh debug-helper` to stage the signed simulator helper beside the SwiftPM debug executable.

### Fixed

- Fixed release extraction failing on framework links whose targets are absent. Metadata cleanup now acts on the links. Local arm64 package extraction, all seven strict signatures, relocated startup and bundled skill access passed; universal builds and distribution installation remain unverified.

- Fixed selected `tap --semantic-press` treating a true native reply as switch success. It now requires fresh Boolean value change on the same target within the original budget, preserves native reply/delivery evidence and rejects older reply-only success at the caller. No action is retried; physical taps are unchanged. The isolated library/CLI build, 92 existing checks and three off-to-on Duo cases passed. The no-change refusal branch has no live proof.

- Fixed ordinary batch validation errors showing a generic system error instead of the command message. Cleanup and input receipts are unchanged.

- Fixed ordinary Duo standalone typing to use the existing measured owned session, including startup readiness, context checks, signal cancellation and key cleanup. Literal/file/stdin loading, US mapping, plain output and other-device routes are preserved.

- Fixed ordinary Duo batches to use one measured input owner, preserving ordered touch/key state, typing chunks and repeated modifier events. Changed context or input failure stops later input; blocked step stdin is cancellable, and owned input closes before exit.

- Fixed ordinary iPhone Duo `touch` routing to use the measured active display and owned contact stream. A down starts or moves one contact; up ends at its supplied point without an added move. Successful downs remain owned for up to 60 idle seconds; an orphan up sends zero HID events. Explicit selected tokens and other-device routes remain separate. Selected wire 26 rejects old wire 25 requests.

- Fixed no-flag iPhone Duo swipes and drags missing the inner display in landscape. Both now use measured display context and their existing event factories, with host pre/post waits, logical coordinates and normal output. A Duo-only limit rejects paths above 100,000 movement steps before allocation; drag retains its 1...1,000-step limit. Selected wire 25 rejects old wire 24 requests.

- Fixed no-flag iPhone Duo taps missing the inner display in landscape by using measured active-display context. Logical coordinates, legacy selectors/styles, waits/delays and plain text output remain; other-device routes are unchanged. Selected wire 24 rejects old wire 23 requests.

- Fixed Homebrew installations omitting the selected-screen helper. The formula now installs and signs `cadisplay-context`; release checks require the helper in the package.

- Fixed selected slider ID requests failing when an earlier element had a longer ID with the same prefix. Native handle lookup now uses exact, unique ID matching; duplicate and wrong-role requests still reject before action.
- Fixed live library retained touches staying held while the caller is idle after folding or rotation. Single and paired contacts now release on the original connection; `close()` waits for owned automatic cleanup and preserves uncertain-release failures.
- Fixed selected input holding contacts through fold or rotation changes during long delays and between retained-touch commands. The owner releases on the original connection, rejects old tokens and keeps uncertain cleanup blocked.
- Fixed selected exact-ID physical taps on UIKit switches whose point hit is an unnamed child. Native identity, screen and parent checks now validate that child before input; bounded Duo fold/rotation checks passed.
- Fixed selected display discovery and input admission for iPad mini (A17 Pro) simulator profile 405.
- Fixed compressed video streams returning PNG bytes as JPEG at default quality and scale. Invalid or incomplete image data is now rejected.
- Handle `SIGINT` and `SIGTERM` during selected PNG capture by cancelling and awaiting the operation. Accepted early cancellation publishes no PNG; unconfirmed cleanup remains an error.
- Fixed finite positive legacy swipes shorter than the effective delta producing non-finite coordinates by using at least one step.
- Fixed the build artifact check rejecting AXe-owned accessibility type names. It now matches complete private identifiers while retaining required module and fork-feature checks.

- Fixed selected slider reads accepting a matching descendant in place of the owned target. ID and label reads now require the owned root itself to match before each action and final read.

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
