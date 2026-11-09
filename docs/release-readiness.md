# v2 release readiness

Working log for the production audit of the `v2` branch, started 2026-11-09 after the device-support
merge (`0aa6ed21b`). Each phase lists its tasks, how it was verified and the evidence. Nothing is pushed.

Status key: `[x]` done and verified, `[~]` in progress, `[ ]` not started, `[!]` blocked (see Blockers).

## Summary

- State: in progress.
- Commits made by this audit: none yet.
- Blockers: none yet.

## Phase 0: baseline

- [x] Build the merged branch with Xcode 27.2 beta 3 (`AXE_BUILD_ARCHS=arm64 make build`)
- [x] Unit tests on the merged branch (`swift test --skip Playground`)
- [x] Confirm hardware: iPhone 16 Pro Max and iPad Pro 11-inch (M1), both connected

Verification:

- `make build` exited 0 ("Build complete"), binary at `.build/out/Products/Debug/axe`.
- `devicectl list devices` reports both physical devices as `connected`.
- `swift test --skip Playground` passed: 872 tests in 117 suites, exit 0.

## Phase 1: audits (read-only)

Five reviewers, one per area. Findings are triaged before any fix.

- [~] Physical device support
- [~] Simulator input and HID broker stack (selected, Duo, legacy routes)
- [~] Agent mode and `axe agent`
- [~] Output contracts against the published schemas
- [~] Dead code, stale tests, orphan scripts, stale docs

## Phase 2: bug fixes

- [ ] Device support bugs
- [ ] Simulator input and broker bugs
- [ ] Agent mode bugs

## Phase 3: remove dead and stale code

- [ ] Unused Swift symbols
- [ ] Stale or duplicate tests
- [ ] Orphan scripts
- [ ] Stale documentation

## Phase 4: simplify the architecture

- [ ] One shared simulator-or-device routing mechanism for commands
- [ ] Merge or remove redundant input routes
- [ ] Split or shrink oversized files

## Phase 5: output contracts

- [ ] Default output holds only what a person or agent needs; internals only with `--verbose`
- [ ] JSON results match the published schemas
- [ ] Schemas for per-command results

## Phase 6: `axe settings` command

One command for device-wide settings on simulators and physical devices: appearance (light and dark),
Liquid Glass, colour filters, text size, Reduce Motion, Increase Contrast, Show Borders, Reduce
Transparency, VoiceOver, location and status bar overrides.

- [x] Design (uses `devicectl device settings`, `info` and `simulate`, which work for both simulators and devices on Xcode 27.2)
- [~] Implementation
- [ ] Unit tests
- [ ] Verified on a simulator
- [ ] Verified on the iPhone and iPad, with the original settings restored
- [ ] README, skill and CHANGELOG

## Phase 7: gestures

- [ ] Swipe works on simulators, the Duo and devices without extra flags
- [ ] Pinch in and out works without `--input-mode selected`
- [ ] Drawing: a multi-point path command for arbitrary shapes
- [ ] Playground screens that record swipes, pinch scale and drawn paths
- [ ] End-to-end checks for each

## Phase 8: verification

- [ ] Unit tests
- [ ] Simulator end-to-end suites affected by the changes (iPhone, iPad, Duo)
- [ ] Device end-to-end suite (`make e2e-devices`) on the iPhone and iPad
- [ ] Taps and typing on a simulator and on both devices
- [ ] Performance against the pre-audit build (`make bench-quick`)

## Phase 9: documentation

- [ ] README
- [ ] Skill (`Skills/CLI/axe`) and its bundled copy
- [ ] CHANGELOG
- [ ] Command help text

## Decisions

Decisions made without the owner, with the reason.

- "Geo support" in the request is read as "Duo support".
- The device support working log (`docs/device-support.md`) is kept until the audit decides whether to condense it.
- `axe settings` wraps `devicectl` rather than private simulator APIs. `devicectl device info appearance` on the booted iPhone simulator and on the physical iPhone both returned the full appearance record, and a `--mode dark` write on the simulator took 0.28 s. There is no `simctl` fallback: without a `devicectl` that has these subcommands the command fails with `settingUnsupported`.
- `axe settings` never exposes `devicectl device settings reset` (factory reset), audio, biometrics or StandBy.

## Blockers

None yet.

## Commit log

None yet.
