# v2 release readiness

Working log for the production audit of the `v2` branch, started 2026-11-09 after the device-support
merge (`0aa6ed21b`). Each phase lists its tasks, how it was verified and the evidence. Nothing is pushed.

Status key: `[x]` done and verified, `[~]` in progress, `[ ]` not started, `[!]` blocked (see Blockers).

## Summary

- State: in progress.
- Commits made by this audit: see the commit log at the end.
- Blockers: 1 open (physical devices unreachable through CoreDevice since about 22:45). See Blockers.

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

- [~] Device support bugs: fixed and merged into `v2` (7 commits); the final device run is blocked
- [x] Simulator input and broker bugs
- [x] Agent mode bugs: fixed and merged into `v2` (13 commits)

Verification of the simulator input wave (8 commits, `3d938025a` to `01ac672d3`):

- `swift test --skip Playground` passed 889 tests. Two timing tests failed in full runs while the machine load average was about 145 and passed when rerun alone.
- New unit tests: a held contact gets its touch-up before the raw broker exits on idle, and a request is validated before its first touch-down (`HIDBrokerTests`); selected input, hinge and rotate return the same codes with and without `--verbose` (`VerboseOutputContractTests`).
- Shut-down iPhone 18 Pro simulator: `tap`, `swipe` and `type` print "iPhone 18 Pro is not booted" and exit 1; JSON code `notBooted`. Before, they said no simulator was found.
- Booted iPhone 18 Pro: three coordinate taps took 0.60, 0.21 and 0.20 s; swipe, `gesture scroll-down`, `key 40` and `button home` exited 0.
- Duo batch with a `swipe-from-bottom-edge` preset completed on the closed outer screen (466×678) and the inner screen (951×669). The old fixed 390×844 start point (y=824) is off both screens.
- `hinge read` on the iPhone gives `noHinge` and exit 1 with and without `--verbose`. A selected tap on a missing ID gives `targetRejected` both ways.
- Playground groups on the iPhone simulator: `PlaygroundOrdinaryRegressionTests` 5 of 5 and `PlaygroundInputHandoverTests` 3 of 3.
- Net change: 617 lines added, 1,010 removed.

Merged state: after both branches were cherry-picked onto `v2` (no conflicts), `AXE_BUILD_ARCHS=arm64 make build`
succeeded and `swift test --skip Playground` passed 922 tests in 127 suites.

Device wave evidence:

- Fixed: a device drag lost the wait before its first move and the whole `--duration` with `--steps 1` (fixture tests for 1, 4 and 60 steps); a gesture's post-delay ran inside the broker; the end-to-end harness left capture processes running after a failed check; a cold command spawned `devicectl list devices` twice; a redundant display read before an element tap; a leaked UDP receiver; duplicate helpers and dead cases.
- One audit finding was wrong, measured on the iPad: reusing one `deviceinfo` connection is slower than a fresh one (a second request after a 0.5 s pause usually got no reply in 3 s; a fresh read takes 13 to 38 ms).
- iPad timings, median of 5, before and after: cold `describe-ui` 2.62 to 2.20 s, cold `tap --id` 4.13 to 3.96 s, cold coordinate tap 1.64 to 1.19 s; warm `describe-ui` 1.97 to 1.82 s, warm coordinate tap 0.83 to 0.73 s.
- `make e2e-devices` on the pre-fix build: iPhone 9 of 9 checks. iPad 1 of 9 at first because a "VoiceOver Gestures" alert covered the Playground; after one tap on OK, element tap, screenshot, raw stream, MP4 and rotation (4 of 4 turns) passed.
- `make e2e-devices` could not build the Playground at first because its Xcode project is no longer checked in; the script now generates it with XcodeGen.
- Not verified: a final device run on the fixed build (see Blockers), the drag timing on a device, and the top-edge swipe in landscape.

Agent-mode wave evidence:

- Fixed: an in-call retry could act on a different control at the same place (it now requires the same native object); certain refusals were retried five times for nothing; focus-and-type retries dropped their plan; paging a changed snapshot returned another snapshot's first page as a success; ticking text refused every action; a caller's invalid request cleared another caller's snapshot; `--focus-id` reported a batch error. `axe agent` refuses plain-HTTP base URLs for remote hosts.
- New refusal codes agents can branch on: `targetCovered`, `busy`, `observationFailed`, `displayChanged`, `waitTimedOut`, `waitCancelled`, `inputIncomplete`, `cleanupUncertain`, `responseTooLarge`, `invalidExpectedPID`.
- Compact replies lost their constant and internal fields: `describe-ui --agent` 1,901 to 1,785 bytes, `tap --agent` 2,045 to 1,850 bytes on the Playground. The v2 schema matches what is emitted.
- Timing before and after, two alternating runs under load 11 to 21: describe 332 and 513 ms before, 360 and 423 ms after; tap 810 and 1,264 ms before, 939 and 1,009 ms after. The runs disagree in direction, so no difference is shown either way. A traced ref tap makes the same three reads in both builds.
- Playground agent groups on the new build: iPhone 19 of 21 suites first time (slider and type passed on rerun; both failed on timeouts under load), iPad all passed.
- `AgentModeController.swift` and `AgentModeSnapshot.swift` are split into smaller files (pure moves).

Not done, with reasons: the audit's claim that the second DTUHID readiness wait is a no-op was wrong
(the first wait is skipped when `dtuhidd` is not yet a child process), so it is kept.

## Phase 3: remove dead and stale code

- [x] Unused Swift symbols in the input stack (`CoordinateHelpers.swift`, dead wrappers; commit `8d1c5a0f8`)
- [ ] Stale or duplicate tests
- [x] Orphan scripts, stale goldens and unused fixtures (commit `eecb92b82`: 532 files, 7,770 lines; `swift package dump-package` parses, 19 script tests pass)
- [ ] Unused IDBKit command families
- [ ] Stale documentation

## Phase 4: simplify the architecture

- [ ] One shared simulator-or-device routing mechanism for commands
- [ ] Merge or remove redundant input routes
- [ ] Split or shrink oversized files

## Phase 5: output contracts

- [x] Default output holds only what a person or agent needs; internals only with `--verbose`
- [x] JSON results match the published schemas
- [x] Schemas for per-command results (`schemas/axe.output.command-payloads.v1.schema.json`, 35 entries)
- [~] Same error codes and result shapes on physical-device paths (branch `audit/integration`)

Verification (commits `8f8f4a061` to `342581d55`):

- `swift test --skip Playground` passed 897 tests at the end of this wave. The payload tests build each command's result from its real type and fail on any field the schema does not declare.
- No error reaches the user as a Swift, NSError or framework description: one mapping in `Sources/AXe/Types/Errors.swift` serves both plain and JSON output. SIGINT and SIGTERM exit with 128 plus the signal number and print nothing.
- Error sites that reported the catch-all `commandFailed`: 195 before; 32 remain without a specific code, 21 of them in files this wave could not edit and 11 internal pipe failures where the catch-all is accurate.
- The envelope's `command` is now the full path (`hinge set`, not `hinge`), and `error` is required exactly when `didError` is true.
- `shutdown`, `clipboard`, selected screenshots and recordings now print text by default and a compact result with `--output json`; their full receipts moved behind `--verbose`.
- Convention for plain-text success: a command that reads or changes state prints that state in a few lines; input commands print nothing, except `tap`, `slider` and `batch`, which keep the "✓" line they printed in v1.8.0; media commands print the file path.
- Run live on the iPhone simulator in plain and JSON form, success and one failure, with each JSON result validated against both schemas: `describe-ui`, `list-simulators`, `displays`, `settings show` and `set`, `status-bar`, `location scenarios`, `doctor`, `clipboard copy`, `init`, `tap`, `key`, `swipe`, `screenshot`, `record-video`, `batch`, `shutdown`. On the Duo: `displays`, `hinge read` and `set`, `rotate`, selected screenshot and recording.
- Playground groups: clipboard passed on the iPhone; Duo media 18 of 18; Duo keyboard interruption groups 5 of 5. Two Duo groups could not run because of the Duo display problem described under Phase 8.
- Not run live: `settings location set` and `clear`, and a successful selected slider move.

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
- [x] Follow-up: a standard text size turns Larger Accessibility Sizes off again (commit `01ac672d3`; `devicectl info appearance` showed the flag true after an accessibility size and false after `large`)

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

- [x] Swipe works on simulators, the Duo and devices without extra flags (already the case; end-to-end check pending)
- [~] Pinch in and out works without `--input-mode selected`
- [~] Drawing: `axe draw <x,y> <x,y> …` for arbitrary shapes
- [x] Playground screens that record pinch scale and drawn paths (Drawing and Zoom)
- [ ] End-to-end checks for each

Verification of the Playground screens (commit `2c7044ad1`), on the iPad simulator with the pre-audit CLI:

- `axe drag` from (100, 300) to (600, 500): the app recorded start `100.0,300.0`, end `600.0,500.0`, 61 samples, one contact, and a 16-point path within 1 pt of the line.
- A five-point square drawn with `touch --down` moves and one `touch --up`: the recorded 16-point path matched exactly, length 750.0.
- `gesture pinch --scale 2` zoomed to 1.82 and `--scale 0.5` back to 1.01; the app counted two zoom gestures, `in` then `out`. The scale lands about 10% short of the request, so checks assert direction and a range.
- The orchestrator viewed the screenshot: the line and the square are both drawn.

## Phase 8: verification

- [x] Baseline: full simulator end-to-end run of the merged branch before any fix (`make e2e` in a separate checkout at `6ab92d88d`): invalid, see below
- [x] Second run on `v2` after the input-stack wave: iPhone 24 of 27 suites, iPad 5 of 5, Duo did not run
- [~] Triage of the three failing iPhone cases (typing and Return, agent slider, agent focus-and-type)
- [ ] Unit tests
- [ ] Simulator end-to-end suites affected by the changes (iPhone, iPad, Duo)
- [ ] Device end-to-end suite (`make e2e-devices`) on the iPhone and iPad
- [ ] Taps and typing on a simulator and on both devices
- [ ] Performance against the pre-audit build (`make bench-quick`)

Baseline run (`e2e-results/20261109T222215Z` in the verification checkout, 58 minutes): FAIL, for two
environmental reasons, so it says nothing about the code.

- iPhone: all 27 suites failed. A "VoiceOver Gestures" system alert covered the Playground. It appeared when the settings checks turned VoiceOver on, and it stays up after VoiceOver is turned off. One tap on OK dismissed it.
- Duo: only 4 suites ran. `axe displays` did not succeed within the 180-second boot budget for one group while three agents were building and testing (load average up to 145 on 18 cores).
- iPad: all 5 suites passed.

Second run (`e2e-results/20261109T232340Z`, 47 minutes, on `v2` after the input-stack wave): 194 cases
ran, 3 failed. No Duo suite ran: `axe displays` refused for the whole 180-second budget with "The
screens were still changing after 8 s". `devicectl device info displays` showed why: the outer screen
active and the inner screen inactive but with its backlight still `activeOn`, which AXe reads as a fold
in progress. Opening and closing the hinge once cleared it. Three later reboots of the same simulator
(closed, shut down while open, and the test matrix's own sequence) all settled within 20 seconds, so the
trigger is not yet known. The same state appeared on a second Duo simulator used by an agent.

Follow-ups: document that turning VoiceOver on shows this alert; keep agents off the E2E simulators
(already the rule; the settings agent ran before the rule existed).

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

- **Physical devices unreachable through CoreDevice (open).** From about 22:45, `devicectl device info lockState` and `details` time out for both the iPhone and the iPad (20 to 30 seconds each, still failing at 00:09), while `devicectl list devices` shows both as connected and simulator calls answer in 0.5 s. Every AXe device command makes those calls, so no device check can run. A direct tunnel screenshot by the device agent showed both devices awake and unlocked. It started during the device agent's first `make e2e-devices` run, whose harness then had the bug of leaving capture processes running. Restarting the user-level `CoreDeviceService` is the likely fix; the permission system refused that action, so it was not done. To clear it: quit and reopen Xcode's Device Hub, or run `killall CoreDeviceService`, or unplug and replug the devices. Device verification of tonight's fixes waits on this.
- **Duo screens intermittently read as "still changing" after boot (investigating).** Described under Phase 8. Workaround: fold the Duo open and closed once.

## Commit log

| Commit | Change |
| --- | --- |
| `6ab92d88d` | Add this log |
| `2c7044ad1` | Playground: Drawing and Zoom screens |
| `198a1e702` | `axe settings` command |
| `eecb92b82` | Remove orphan scripts, stale goldens and unused fixtures |
| `3d938025a` | Release a held contact before the raw broker exits; validate before input |
| `6a7361854` | Same exit status and codes with `--verbose` |
| `19ffbeddf` | Duo batch gesture presets use the measured screen |
| `3979992b8` | A shut-down simulator reports `notBooted`; shared booted-simulator lookup |
| `2f991f496` | Correct tap, batch and `--expected-pid` help |
| `7ad37746a` | Build each command's events once; share signal scoping (wire version 85) |
| `8d1c5a0f8` | Remove unused coordinate helpers and dead wrappers |
| `01ac672d3` | Text size alone decides Larger Accessibility Sizes |
| `8f8f4a061` | Code every error; compact results by default |
| `a6fc4426d` | Payload schema for every command result |
| `526878eac` | Legacy edge insets on the measured size; slider failure codes |
| `aab61ae57` | Document result shapes, error codes and the payload schema |
| `342581d55` | Keep framework dumps out of messages |
| `4f1c…` to `80b3bcb74` | Device fixes (7 commits): drag duration, post-delay, harness leaks, cold-start spawn, dead code |
| `…` to `4f28af3ee` | Agent-mode fixes (13 commits): retry binding, typed refusals, compact replies, file splits |

Commits from `379715af0` onwards are unsigned: 1Password stopped answering signing requests.
