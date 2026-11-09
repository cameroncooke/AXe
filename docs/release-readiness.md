# v2 release readiness

Working log for the production audit of the `v2` branch, started 2026-11-09 after the device-support
merge (`0aa6ed21b`). Each phase lists its tasks, how it was verified and the evidence. Nothing is pushed.

Status key: `[x]` done and verified, `[~]` in progress, `[ ]` not started, `[!]` blocked (see Blockers).

## Summary

- State: in progress.
- Commits made by this audit: see the commit log at the end.
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

- [x] Physical device support
- [x] Simulator input and HID broker stack (selected, Duo, legacy routes)
- [x] Agent mode and `axe agent`
- [x] Output contracts against the published schemas
- [x] Dead code, stale tests, orphan scripts, stale docs

Verification: each reviewer read the code without building or running it, and wrote findings with
`file:line`, evidence and a proposed fix. Every finding is re-checked in the code by the agent that fixes it.

| Area | Findings | Most important |
| --- | --- | --- |
| Physical devices | 30 (5 bugs, 13 dead code, 7 complexity, 2 architecture, 3 output); none high | A device drag ignores `--duration` and `--steps`. No path leaves a touch or key held. |
| Simulator input and brokers | 23 plus 17 mechanical cleanups (7 bugs) | Duo batch gesture presets use a fixed 390×844 screen. The raw broker exits on idle while a touch is held. `--verbose` changes exit status and error codes. |
| Agent mode | 30 (10 bugs; 1 high) | A retry after a changed screen does not check that an ID or label target is still the same control. |
| Output contracts | 21 (4 high) | Broker errors print raw enum text. Some errors print Swift type dumps. Screenshot and recording receipts print host paths and PIDs by default. 211 error sites have no error code. |
| Dead and stale code | 47 | About 14,000 removable lines: unused IDBKit command families (about 5,000), stale goldens (about 4,100), orphan scripts (about 3,500), an unused 232-line helper file. |

The five route map for simulator input, from the audit: direct HID per command; the raw broker; the
selected broker with a client-captured context ("ordinary" Duo and DTUHID input); the selected broker
binding the active screen (`--input-mode selected`); and an in-process owner for ordinary Duo batches.
The third and fourth are one owner with two admission styles and can be merged.

## Phase 2: bug fixes

- [ ] Device support bugs
- [~] Simulator input and broker bugs
- [ ] Agent mode bugs

## Phase 3: remove dead and stale code

- [~] Unused Swift symbols
- [ ] Stale or duplicate tests
- [~] Orphan scripts, stale goldens and unused fixtures
- [ ] Unused IDBKit command families
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
- [x] Implementation: `settings show`, `settings set`, `settings location`, `settings status-bar`
- [x] Unit tests
- [x] Verified on a simulator
- [x] Verified on the iPhone and iPad, with the original settings restored
- [x] README, skill and CHANGELOG
- [~] Follow-up: a standard text size turns Larger Accessibility Sizes off again

Verification (commit `198a1e702`):

- `swift test --skip Playground` passed 883 tests (872 before, 11 new in `SettingsTests`).
- Timings on the simulator, median of 5: `show` 0.26 s, one-option `set` 0.47 s. `show` on a device takes about 1 s.
- The orchestrator re-ran `settings show`, `settings set --appearance dark` and back, the JSON form, the no-option error (exit 64) and an unknown UDID (`targetNotFound`, exit 1) on the simulator, and `settings show` on the iPhone.
- After the device checks, `show` on the simulator, iPhone and iPad matched the output recorded before them.

| Setting | Simulator | iPhone | iPad |
| --- | --- | --- | --- |
| Appearance dark and back | pass; screenshot brightness 0.65 to 0.26 | pass | pass |
| Text size (all 12 on the simulator; one step on devices) | pass | pass | pass |
| Increase Contrast | pass | pass | pass |
| Reduce Motion, Reduce Transparency, Show Borders, Liquid Glass opacity | pass | not tested | not tested |
| Colour filter (4 types, intensity, off) | pass | not tested | not tested |
| VoiceOver on, then off at once | pass | pass | pass |
| Location set and clear | pass | pass | pass |
| Status bar preset, set and clear | pass | `settingUnsupported` | `settingUnsupported` |
| Liquid Glass style (clear or tinted) | `settingUnsupported` | not tested | not tested |

iOS 27.2 offers only one Liquid Glass style, so `--liquid-glass` fails with `settingUnsupported` before
changing anything. Devices do not support status bar overrides.

## Phase 7: gestures

- [ ] Swipe works on simulators, the Duo and devices without extra flags
- [ ] Pinch in and out works without `--input-mode selected`
- [ ] Drawing: a multi-point path command for arbitrary shapes
- [x] Playground screens that record pinch scale and drawn paths (Drawing and Zoom)
- [ ] End-to-end checks for each

Verification of the Playground screens (commit `2c7044ad1`), on the iPad simulator with the pre-audit CLI:

- `axe drag` from (100, 300) to (600, 500): the app recorded start `100.0,300.0`, end `600.0,500.0`, 61 samples, one contact, and a 16-point path within 1 pt of the line.
- A five-point square drawn with `touch --down` moves and one `touch --up`: the recorded 16-point path matched exactly, length 750.0.
- `gesture pinch --scale 2` zoomed to 1.82 and `--scale 0.5` back to 1.01; the app counted two zoom gestures, `in` then `out`. The scale lands about 10% short of the request, so checks assert direction and a range.
- The orchestrator viewed the screenshot: the line and the square are both drawn.

## Phase 8: verification

- [~] Baseline: full simulator end-to-end run of the merged branch before any fix (`make e2e` in a separate checkout at `6ab92d88d`)
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
- One agent at a time edits Swift sources in the main checkout, because a second agent's half-finished edits would break the first one's build. End-to-end runs use a separate checkout (`/Volumes/Developer/AXe-verify`) on the three "AXe E2E" simulators; agents use other simulators.
- Mixed v1.8.0 and v2 installs are not supported, so the probe for a v1.8.0 raw broker is removed.
- The selected input wire protocol has never been released, so it may change without a compatibility path.
- Order of work on the input stack: bugs and behaviour-neutral removals first, then merging duplicate payload types, then folding the "ordinary" route into the selected route. The last step changes the path of every ordinary tap, so it needs a timing comparison before it is kept.
- `icon.png` is kept: nothing in the repository uses it, but it may be the GitHub social image.

## Blockers

None yet.

## Commit log

| Commit | Change |
| --- | --- |
| `6ab92d88d` | Add this log |
| `2c7044ad1` | Playground: Drawing and Zoom screens |
| `198a1e702` | `axe settings` command |
