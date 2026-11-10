# v2 release readiness

Working log for the production audit of the `v2` branch, started 2026-11-09 after the device-support
merge (`0aa6ed21b`). Each phase lists its tasks, how it was verified and the evidence. Nothing is pushed.

Status key: `[x]` done and verified, `[~]` in progress, `[ ]` not started, `[!]` blocked (see Blockers).

## Summary

- State: simulator work is done and verified; device verification is blocked. Last update 10 November, about 09:35.
- Simulators: unit tests 845 of 845; iPhone 34 of 34 end-to-end suites; Duo 64 of 64 (8 only on an isolated rerun); iPad 11 of 11 at earlier commits. No timing regression against the pre-audit build.
- Not verified: anything on the physical iPhone and iPad; timing against the v1.8.0 release binary (none on this Mac).
- Correction: an earlier version of this log said the third end-to-end run passed 96 of 101 suites. It ran 43. See Phase 8.
- Nothing is pushed.
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
- [x] Bugs found by the final verification (5 fixes, `5b2427fd1` to `edbb353fe`)

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

Bugs found by the final verification, each fixed and committed:

| Bug | Cause | Fix and evidence |
| --- | --- | --- |
| A command straight after `button home` failed with `DTUHID guest barrier timed out` and its input was lost | The guest serves a new connection late after another connection's Home press: 0.7 to 1 s on a healthy simulator, 3.1 to 3.3 s on one that had taken input for hours. AXe sent the input, waited 2 s, closed the connection and the guest never saw it. Not from the audit: the pre-audit build fails the same way. | `cc39c8d49`: a plain connection first sends one request with no input and waits up to 10 s for the answer. Presses 0.5 s apart on the long-running simulator: before 2 of 4 failed, after 12 of 12 succeeded (3.2 to 4.7 s each). Healthy simulator: 0.73 s before and after. A reconnect was tried first and made it worse (every press failed), because abandoned connections add to the guest's backlog. |
| `axe displays` and agent reads failed on a locked iPhone or iPad simulator ("inconsistent screen layout") | A device with one screen was accepted only while lit; a locked Duo already read fine | `a35e1270d`: the one built-in screen is read in any reported state. Locked iPhone 18 Pro now prints `portrait, locked`, JSON `"state":"locked"`, and `describe-ui --agent` returns the lock screen. 10 IDBKit display tests pass. |
| `batch --agent --file` with malformed JSON reported `readFailed` ("AXe could not read a response it expected") | The decoding error fell through to the generic mapping (a regression from the error-code unification) | `5b2427fd1`: `invalidArguments`, "Agent batch JSON is malformed or lacks a steps array." New unit test; the failing e2e case passes. |
| Ordinary `stream-video --format mjpeg` declared `boundary=--mjpegstream` while parts start with `--mjpegstream` | Present since v1.8.0; a strict multipart parser finds no parts | `46c18a694`: declares `boundary=mjpegstream` like the selected stream; part bytes unchanged. |
| A selected tap whose wait timed out printed "The operation couldn't be completed. (AXe.SelectedAXWaitFailure error 1.)" | The failure type had no description of its own, so Foundation's default text reached the output | `edbb353fe`: prints "The control did not become ready before the wait ended."; the readable-text filter also drops that default rendering for any other type. Unit tests, and `PlaygroundDuoTapWaitTests` passes on the Duo |

Not done, with reasons: the audit's claim that the second DTUHID readiness wait is a no-op was wrong
(the first wait is skipped when `dtuhidd` is not yet a child process), so it is kept.

## Phase 3: remove dead and stale code

- [x] Unused Swift symbols in the input stack (`CoordinateHelpers.swift`, dead wrappers; commit `8d1c5a0f8`)
- [x] Stale or duplicate tests (commit `49a587d4`: one shared AX-node fixture replaces 20 private copies; dead suites removed)
- [x] The 17 older end-to-end suites that `make e2e` never ran: run once (all passed), then replaced by five matrix suites (`b623e4f21` to `963cae85f`)
- [x] Orphan scripts, stale goldens and unused fixtures (commit `eecb92b82`: 532 files, 7,770 lines; `swift package dump-package` parses, 19 script tests pass)
- [x] Unused IDBKit code removed (7 commits ending `085823b4f`: 82 files, 6,456 lines; FBControlCore 4.86 MB to 3.63 MB, FBSimulatorControl 15.58 MB to 14.24 MB; the IDBKit test target passed 262 Swift Testing and 9 XCTest tests before and after; the universal build succeeds)
- [x] Stale documentation (see Phase 9)

## Phase 4: simplify the architecture

- [x] One shared simulator-or-device routing mechanism for commands (`bdd9ddcce`: one `PhysicalDeviceCommand` protocol used by 13 commands and the physical batch; every refusal now happens before a device lease)
- [x] Merge duplicate payloads: one path payload for swipe, drag and draw (`f3060e258`); Home as a button kind (`9cfd54a05`); one keyboard primitive list, with the temporary-file side channel replaced by a compact encoding (`bdbde8021`); the raw broker's keyboard branch removed (`d6fa0cf73`)
- [x] Test-oracle checks moved out of the product path: the owner decides success, the client checks error, outcome and bound screen (`5d18508a7`)
- [x] `LegacyDuo*` renamed to `OrdinaryBroker*`, since it serves every DTUHID simulator and is not legacy (`48ca3215e`)
- [x] Split oversized files (`AgentModeController.swift`, `AgentModeSnapshot.swift`, in the agent-mode wave)
- [ ] Not done: `SelectedHIDRequest` as header fields plus an enum payload (SEL-16), and folding the ordinary route into the selected route (SEL-17); see Open items

Verification of the architecture wave (7 commits, Sources net 269 lines fewer):

- Unit tests: 945 at the end of the wave. New tests pin the ordinary swipe, drag and draw events and limits; they passed on the old type before the change and unchanged after it. A unit test sends 60,000 characters through the broker's real read path and compares the events.
- Benchmarks, old and new builds alternated, median in ms, on the iPhone simulator at load 11 to 14: tap 279 and 282, swipe 637 and 631, `key 40` 385 and 384, key-combo 456 and 441, type 729 and 734. On the Duo, 30 extra tap pairs at load 12: median paired difference −0.5 ms, new build faster in 15 of 30.
- Playground groups on the final build: iPhone ordinary regression 8 of 8, input handover 3 of 3, raw keyboard broker 1 of 1; Duo raw long text 1 of 1, typing interruption 1 of 1, input handover 3 of 3, motion options 6 of 6, core 17 of 20 (the 3 failures were `simctl launch` exiting 3 under load).
- The Duo selected Home batch group failed on the text of a refusal message; fixed in the polish wave below.

Polish wave (commits `4f266cec1`, `1a0584df9`, `20527d12c`, `e45b0d3db`; 958 unit tests pass):

- Gesture presets on ordinary simulators used a fixed 390×844 screen (also in v1.8.0). They now use the size the ordinary broker route has already measured. On the iPad simulator `swipe-from-right-edge` starts at 800,590 and ends at 20,590; the previous build started at 370,422. `gesture scroll-down` on the iPhone, 7 alternating runs: 0.893 s before, 0.874 s after. Simulators without DTUHID and ordinary batch gesture steps outside the Duo keep 390×844, because no measured size is available there without an extra read.
- A selected batch step that failed to parse printed a Swift value dump; it now prints the parser's sentence with code `rejectedBeforeInput`. The Home batch test now asserts the code and the two step receipts, and passed on the Duo.
- README corrected: only selected-screen `bgra` streams print real dimensions, and `--follow-active-display` works on any simulator.
- A display read failure during early boot now gives "The simulator reported an inconsistent screen layout. Try again." with code `displayUnavailable`; a unit test pins seven such errors to a sentence and a code.
- Not verified: device routing on hardware; keys on a simulator without a shared owner.

Merged state at 03:12: frameworks rebuilt after the IDBKit prune, `swift test --skip Playground` ran 952 tests with one failure, the load-sensitive stream backpressure test, which passed when rerun alone (load average 58 at the time).

## Phase 5: output contracts

- [x] Default output holds only what a person or agent needs; internals only with `--verbose`
- [x] JSON results match the published schemas
- [x] Schemas for per-command results (`schemas/axe.output.command-payloads.v1.schema.json`, 35 entries)
- [x] Same error codes and result shapes on physical-device paths (commits `a7c65702d`, `4b859379d`; not verified on hardware)

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

- [x] Swipe works on simulators and the Duo without extra flags
- [x] Pinch in and out works without `--input-mode selected`; `gesture pinch --scale 2` alone pinches at the screen centre
- [x] Drawing: `axe draw <x,y> <x,y> … [--close] [--duration s]` for arbitrary shapes, also as a batch step
- [!] Draw and pinch on the physical devices: implemented and unit-tested, checks added to the device suite, not run (devices unreachable)
- [x] Playground screens that record pinch scale and drawn paths (Drawing and Zoom)
- [x] End-to-end checks for each on the iPhone, iPad and Duo simulators

Verification (commits `abedff34f`, `f53c105bf`, `f75a93767`, `3d3edfeeb`):

- Unit tests: 938 at the end of this wave, including new `DrawTests` and `GestureDefaultRouteTests`. A unit test pins the events `drag` sends, which are unchanged: `drag` is now the two-point case of the same stroke builder.
- New Playground suites, all passing: Drawing 5 of 5 and Zoom 2 of 2 on each of the iPhone, iPad and Duo.
- Existing groups rerun: iPhone core 9 of 9, agent drag 7 of 7, agent pinch 8 of 8; iPad core 9 of 9, ordinary regression 8 of 8; Duo gesture coverage 28 of 28, pair coverage 28 of 28, motion options 6 of 6, agent drag 7 of 7, agent pinch 8 of 8. iPhone ordinary regression 7 of 8: the one failure is the typing race fixed separately in `be2335b1e`.

| Simulator | Triangle sent with `--close`, 1.5 s | What the app recorded | Pinch with defaults: scale 2, then 0.5 |
| --- | --- | --- | --- |
| iPhone | 201,335 314,714 88,714 | start and end 201,335; bounds 88,335,314,714; one contact; 1.99 s | 1.75, then 0.92 |
| iPad | 410,376 649,964 171,964 | start and end 410,376; bounds 171,376,649,964; 1.97 s | 1.86, then 1.00 |
| Duo | 191,269 298,550 84,550 | start and end 191,269; bounds 84,269,298,550; 1.93 s | 1.60, then 0.91 |

- The recorded 16-point paths were within 4 pt of the expected path in every case.
- Timing on the iPhone, median of 7, old and new builds alternated: swipe 0.685 s old and 0.687 s new; drag 0.849 s old and 0.840 s new.
- A drawn stroke takes about a third longer than `--duration` (1 s requested records about 1.35 s), the same per-move cost `drag` already has.
- Not verified: physical devices; a simulator without the DTUHID touch service (it should refuse with `inputUnavailable`); strokes longer than 1.5 s.

Verification of the Playground screens (commit `2c7044ad1`), on the iPad simulator with the pre-audit CLI:

- `axe drag` from (100, 300) to (600, 500): the app recorded start `100.0,300.0`, end `600.0,500.0`, 61 samples, one contact, and a 16-point path within 1 pt of the line.
- A five-point square drawn with `touch --down` moves and one `touch --up`: the recorded 16-point path matched exactly, length 750.0.
- `gesture pinch --scale 2` zoomed to 1.82 and `--scale 0.5` back to 1.01; the app counted two zoom gestures, `in` then `out`. The scale lands about 10% short of the request, so checks assert direction and a range.
- The orchestrator viewed the screenshot: the line and the square are both drawn.

## Phase 8: verification

- [x] Baseline: full simulator end-to-end run of the merged branch before any fix (`make e2e` in a separate checkout at `6ab92d88d`): invalid, see below
- [x] Second run on `v2` after the input-stack wave: iPhone 24 of 27 suites, iPad 5 of 5, Duo did not run
- [x] Third run on `v2` at `e45b0d3db` (03:28, 70 minutes, one agent still testing on other simulators): 43 of the 101 planned suites ran and 38 passed; the Duo stopped after 7 suites
- [x] Targeted rerun of the 5 failed suites and the new ordinary suites on a quiet machine at `a35e1270d`
- [x] Fourth run on `v2` at `cc39c8d49`, simulators rebooted first, stopped by the owner after 2 h 20 min: iPhone 34 of 34 passed, Duo 47 of the 51 that ran; 13 Duo and 11 iPad suites did not run
- [x] Isolated reruns of the four failed Duo suites: all four pass (three after fixes `edbb353fe` and `6463de619`)
- [x] Isolated run of the 13 Duo suites the fourth run did not reach: 9 passed; the other 4 passed when rerun alone (one after a script fix, `c06e149e8`)
- [x] Triage of the three failing iPhone cases: none is a regression (see below)
- [x] Unit tests at `c06e149e8`: `swift test --skip Playground` 845 of 845 in 117 suites; script tests 19 of 19
- [x] Simulator end-to-end suites affected by the changes: iPhone 34 of 34 at `cc39c8d49`; Duo 64 of 64 passed at least once at `cc39c8d49` or later, 8 of them only on an isolated rerun; iPad 11 of 11 at `e45b0d3db` and `a35e1270d`, not rerun after the last input fix
- [ ] Device end-to-end suite (`make e2e-devices`) on the iPhone and iPad: blocked, `devicectl` still times out at 08:50 on 10 November
- [~] Taps and typing: verified on the iPhone, iPad and Duo simulators by the suites above; not run on the devices (blocked)
- [x] Performance against the pre-audit build (`scripts/bench-quick.py`, 7 pairs, iPhone 18 Pro simulator): no regression in two runs

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

Triage of the three iPhone failures from the second run:

- Typing and Return (selected): a race in the test. It typed 0.01 s after the tap, before UIKit scrolled the field 17 pt above the keyboard, and AXe correctly refused a target that moved. The test now waits for the settled keyboard (`be2335b1e`); 3 of 3 passes afterwards.
- Agent slider interior value: load-dependent. The pre-audit binary fails the same cases under the same load. Each pickup read launches a child `axe` process, and under load about 11 s of the fixed 15 s budget goes there. No change tonight; listed under Open items.
- Agent focus-and-type: the one accessibility read after typing hit its 8 s limit under load. 3 of 3 passes on rerun; no change.

The machine load during these runs was 8 to 261 on 18 cores, so a clean end-to-end verdict needs a run with no agents working.

Duo "screens still changing" refusal, investigated and fixed (merged into `v2`):

| Scenario | Trials | Inner screen reported lit while inactive | Cleared by itself |
| --- | --- | --- | --- |
| Close from 180°, idle machine | 19 | 1.9 to 3.2 s | yes |
| Close from 120° and from 90° | 10 each | 2.2 to 3.2 s | yes |
| Close from 180°, load average 80 to 240 | 31 | 2.5 to 3.6 s | yes, except one stale case |
| Open to 180° | 10 | none seen | yes |
| Reboot while closed | 4 | about 8 s | yes |

- Trigger: under heavy CPU load, CoreDevice's display report misses an update and stays stale (2 of about 65 closes; once for over 5 minutes). SpringBoard's log shows the inner screen did turn off. A hinge move or an app launch refreshes the report; it never clears by itself. A running AXe broker or a recording is not the cause.
- New rule: a lit inactive screen is still treated as a fold in progress, unless the hinge is at rest at an end stop with the matching screen active, the active screen is lit, and the whole report and the hinge reading have been identical for 5 seconds. The proof is cached per simulator, so only the first command waits.
- Why it cannot bind the wrong screen: during a real close the outgoing screen stays flagged active for up to 1 s at hinge 0, which the posture check refuses; the only lit-inactive shape that fits the hinge is a close's dwell, which ended within 3.5 s in 66 closes with the correct flag throughout; a stale report that flags the dark screen active is still refused (taps bound there never reached the app).
- Red and green: in the natural stale state the old build's `axe displays` refused after 8 s and the new build answered in 5.3 s. With the stale report injected, the first tap took 5.9 s, later taps 0.4 s, and all landed. Over 20 open and close cycles, every accepted tap bound the correct screen.
- Tap timing on the Duo in the normal state, median of 7: 0.423 s before, 0.390 s after.
- Not conclusive: Duo matrix groups run under load averages of 100 to 240 failed on both the old and the new build (app launch failures and the known early-boot accessibility wedge), so they need the quiet final run.

Third run (`e2e-results/20261110T032721Z`, 70 minutes, `v2` at `e45b0d3db`): 43 of the 101 planned suites ran: iPhone 26 of 29 passed, iPad 7 of 7, Duo 5 of 7. The Duo part stopped at its seventh suite when its input was quarantined, so 57 Duo suites did not run. An earlier version of this log said "96 of 101 suites passed"; that wrongly counted the suites that never ran as passes. The ordinary-suite agent was still running its own simulators until about 04:00 (load average up to 370), so the run was not quiet. The five failures:

| Suite | Failure | Verdict |
| --- | --- | --- |
| iPhone `PlaygroundAgentBatchTests` | Malformed batch file reported `readFailed` | Real regression, fixed (`5b2427fd1`); passes on rerun |
| iPhone `PlaygroundAgentSliderTests` | Two interior-value cases ran out of time (13 to 14 s) | Load; passes on the quiet rerun |
| iPhone `PlaygroundAgentKeyComboTests` | Two taps refused after an observation timed out | Load; passes on the quiet rerun |
| Duo `PlaygroundDuoCoreTests` | `simctl launch` returned no process for the first test | Simulator launch failure under load; passed in the fourth run |
| Duo `PlaygroundDuoScrollCoverageTests` | A swipe stopped because the display feed was 0.57 s old (limit 0.5 s); cleanup uncertain, input quarantined | Load; passed in the fourth run. The quarantine then correctly blocked every later Duo input until I rebooted that simulator and removed the record. |

Targeted rerun on a quiet machine (`e2e-results/final-targeted-1`, 23 minutes, `v2` at `a35e1270d`, 19 suites): the three iPhone agent suites passed, all five iPad ordinary suites passed, and four of the six new ordinary iPhone suites passed. `PlaygroundOrdinaryBatchTests` and `PlaygroundOrdinaryButtonTests` failed with `DTUHID guest barrier timed out`, which led to the fix in `cc39c8d49` (Phase 2). The Duo suites did not run because of the quarantine record above.

Fourth run (`e2e-results/20261110T053045Z`, `v2` at `cc39c8d49`, quiet machine): started as a last full run because `cc39c8d49` changes every plain input command. The owner stopped it after 2 hours 20 minutes: a full run is too expensive for one fix, and a few plain-input suites would have covered that change. The rule is now in `AGENTS.md` (Build and test). What it showed before it was stopped:

- iPhone: 34 of 34 suites passed, including the two ordinary suites that had failed with `DTUHID guest barrier timed out`.
- Duo: 51 of 64 suites ran, 47 passed. This was the first time since the audit began that more than 7 Duo suites ran.
- Not run: 13 Duo suites and all 11 iPad suites. The iPad suites last passed at `e45b0d3db` (7 suites) and `a35e1270d` (5 ordinary suites).

The four Duo failures, each rerun alone (`e2e-results/duo-isolated-1` on the old build, `duo-isolated-2` at `6463de619`):

| Suite | Cause | Result |
| --- | --- | --- |
| `PlaygroundDuoAgentInterruptionTests` (11 issues) | The test launched its interrupted input without `--view full`, so the compact reply lacked the `kind` and `replayed` fields it decodes. Stale since `7c95e5f9e`. | Test fixed (`6463de619`); passes |
| `PlaygroundDuoLegacyBatchInterruptionTests` (2) | The audit added `--verbose` and a ban on the string "FBSimulatorControl" in the same change (`8f8f4a061`); the verbose loader log always prints that string. | Test now bans the error type name (`6463de619`); passes |
| `PlaygroundDuoTapWaitTests` (2) | The test passed `--poll-interval` with a zero wait, which `4b859379d` made an argument error. | Test fixed (`6463de619`); passes |
| `PlaygroundClipboardTests` (9) | Every accessibility read on that boot timed out after 8 s: the known early-boot accessibility wedge of iOS 27.2, which lasts until reboot. | 9 of 9 pass alone on the unchanged build; no change |

The tap-wait logs also showed a product bug: a selected tap whose wait timed out printed "The operation couldn't be completed. (AXe.SelectedAXWaitFailure error 1.)". It now prints "The control did not become ready before the wait ended. No input was sent." (`edbb353fe`, with unit tests; the tap-wait suite now refuses that text in every failing case).

The 13 Duo suites the fourth run did not reach (`e2e-results/duo-remaining-13`, `v2` at `6463de619`, 25 minutes, load average 25 to 40 from system daemons and six idle simulators): 9 passed, 4 failed. Each failed suite was then rerun alone with the other simulators shut down (`duo-isolated-3`, `duo-isolated-4`):

| Suite | Failure in the 13-suite run | Result alone |
| --- | --- | --- |
| `PlaygroundDuoTests` | Accessibility read failed with "No translation object" (early-boot wedge) | Passes |
| `PlaygroundDuoInterruptionTests` | Same | Passes |
| `PlaygroundDuoHardwareInterruptionTests` | Five reads refused with "The screens were still changing after 8 s" | One case then failed with `KeyError('home')`: the proof script read the held Home receipt under a key that `9cfd54a05` merged into `button`. Script fixed (`c06e149e8`); passes |
| `PlaygroundDuoHeldModifierTests` | One hold stopped because the motion feed was 0.51 s old (limit 0.5 s) | First rerun: `simctl launch` returned no process for a different case. Second rerun: passes |

So of the Duo failures seen since the fourth run began, 4 were stale test or script expectations left by the audit (fixed) and 6 were refusals or launch failures on a slow or freshly booted simulator that passed on rerun. The logs also exposed one product bug (the wait wording, fixed). No Duo suite fails at `c06e149e8`, but the last group shows the Duo suites are sensitive to machine load; see Open items.

Background load found on the morning of 10 November: `PerfPowerServices` at about 150% of a core and Spotlight at about 100% (indexing is enabled on `/Volumes/Developer`), plus six idle booted simulators. Seven leftover wait loops from the night were also found and stopped; they only slept. The idle simulators are now shut down.

Performance (`scripts/bench-quick.py --pairs 7`, baseline the pre-audit build `0aa6ed21b`, candidate the payload built at `6463de619`, iPhone 18 Pro simulator). There is no v1.8.0 release binary on this Mac, so this is not the release comparison that `AGENTS.md` asks for.

| Command | Run 1 (load 39): baseline, candidate | Run 2 (load 31, all other simulators off): baseline, candidate |
| --- | --- | --- |
| cold `describe-ui` | 0.160 s, 0.161 s | 0.126 s, 0.121 s (faster in 7 of 7 pairs) |
| selected `describe-ui` | 0.174 s, 0.183 s | 0.105 s, 0.101 s |
| selected tap | 0.237 s, 0.253 s | 0.191 s, 0.183 s |
| agent `describe-ui` | 0.129 s, 0.158 s | 0.121 s, 0.108 s (faster in 7 of 7) |
| `describe-ui` | 0.130 s, 0.139 s | 0.126 s, 0.117 s (faster in 7 of 7) |
| `key` | 0.303 s, 0.315 s | 0.288 s, 0.275 s (faster in 7 of 7) |
| `tap` | 0.174 s, 0.195 s (slower in 6 of 7 pairs) | 0.162 s, 0.153 s (faster in 7 of 7) |

Both runs ended "No regression". Run 1's plain `tap` was 15 ms slower in 6 of 7 pairs, which is why the run was repeated; in run 2 the candidate was faster in every pair, so run 1's difference was noise from the busy machine. The Duo was not timed in this pass.

Ordinary-simulator coverage (merged as `b623e4f21` to `963cae85f`): 17 legacy end-to-end files that `make e2e` never ran were run once through their old path (all passed), then replaced by five matrix suites, 54 cases on the iPhone and 50 on the iPad, plus unit tests for option refusals and `list-simulators`. `make e2e` now plans iPhone 34 suites and 232 cases, iPad 11 and 80, Duo 64 and 521. The unit count fell from 958 to 845 because those files are gone; nothing that ran before was dropped. Not covered: ordinary BGRA streaming (output has padded rows and no frame boundaries) and ordinary landscape (`rotate` is Duo-only by design).

Follow-ups: document that turning VoiceOver on shows this alert; keep agents off the E2E simulators
(already the rule; the settings agent ran before the rule existed).

## Phase 9: documentation

- [x] README: rewritten as a user guide, 647 lines to 302
- [x] Skill (`Skills/CLI/axe`) and its bundled copy
- [x] CHANGELOG: the unreleased section now describes v2 as its net change against v1.8.0 (about 210 bullets to 25)
- [x] `docs/device-support.md`: the 590-line working log replaced by a 57-line design and limitations document (the log stays in git history)
- [x] Command help text (4 commits: 44 help pages from 8,346 words to 6,829; `batch` 831 words to 402; only help strings changed)

Verification (commits `762e228b3` to `cb6cc95f2`):

- Every command line and JSON shape in the README was run or read from `--help` and the schemas; example output came from a booted iPhone simulator.
- The doc-checking unit tests (21), the script tests (19, including the Playground count check) and `scripts/check-changelog-released.py v2` pass.
- `skill-check` 1.2.0 on `Skills/CLI/axe`: 100 of 100, no errors or warnings; `diff -r` against the bundled copy is clean.
- CHANGELOG "Fixed" keeps only bugs confirmed to exist in v1.8.0 (110 bullets to 7); attributions #64, #68, #77 and #80 are kept.
- Left out because they could not be verified: Duo `displays` and `hinge` example output (described in words), and `button siri` on physical devices.

## Open items for the owner

- Restart `CoreDeviceService` (or replug the devices), then run `make e2e-devices`: nothing changed tonight on device paths has been run on hardware.
- Interior slider values spawn a child process per read and take about 13 s; under load they fail. A redesign (reads in-process) is the fix.
- A simulator that has taken input for hours answers new input connections 3 to 4 s late (Xcode 27.2 beta 3). AXe now waits instead of failing, but back-to-back `button` presses are slow there until the simulator is rebooted. On the same simulator the ordinary-suite agent also saw typed text gain doubled spaces (`Hello,   x`), which cleared after a reboot; I could not reproduce it and have not investigated it.
- Ordinary `stream-video --format bgra` output cannot be decoded reliably: it ignores `--scale`, pads rows and has no frame boundaries. Unchanged from v1.8.0; no end-to-end case covers it.
- The selected input path stops input when its display or motion feed is more than 0.5 s old. That tripped twice on the Duo: the display feed (0.57 s) at a load average above 100, with input quarantined, and the motion feed (0.51 s) at a load average of about 40, released cleanly. The limit is deliberate; it needs a decision on whether busy machines get more margin.
- The early-boot accessibility wedge ("No translation object" or every read timing out until reboot) hit three Duo suites on 10 November. The matrix's boot gate does not catch it; a rerun on a fresh boot passes.
- Folding the "ordinary" input route into the selected route (audit item SEL-17) is not done: it changes the path of every ordinary tap and needs a quiet machine to benchmark against v1.8.0.

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
- **Duo screens read as "still changing" when nothing moves (fixed and merged).** The refusal appeared once more on 10 November, in `PlaygroundDuoHardwareInterruptionTests` at a load average of about 40, and not when that suite was rerun alone. Cause and fix are described under Phase 8. Workaround on older builds: fold the Duo open and closed once.

## Commit log

All 97 commits made on `v2` since `0aa6ed21b`, oldest first. None is pushed. This table is generated from `git log`, so the commit that updates this log is the one after the last row.

| Commit | Subject |
| --- | --- |
| `6ab92d88d` | docs(release): Add the v2 release readiness log |
| `2c7044ad1` | test(playground): Add Drawing and Zoom screens |
| `198a1e702` | feat(settings): Add axe settings for appearance, accessibility and location |
| `9f9d96ac9` | docs(release): Record audit results, settings and Playground evidence |
| `eecb92b82` | chore(repo): Remove orphan scripts, stale goldens and unused fixtures |
| `3d938025a` | fix(hid): Release a held contact before the raw broker exits |
| `6a7361854` | fix(output): Keep exit status and codes the same with --verbose |
| `19ffbeddf` | fix(batch): Use the measured screen for Duo gesture presets |
| `3979992b8` | fix(input): Report a shut-down simulator as not booted |
| `2f991f496` | docs(help): Correct tap, batch and --expected-pid help |
| `7ad37746a` | ref(input): Build each command's events once and share signal scoping |
| `8d1c5a0f8` | ref(input): Remove unused coordinate helpers and dead wrappers |
| `01ac672d3` | fix(settings): Let the text size alone decide Larger Accessibility Sizes |
| `3054520ba` | docs(release): Record the input-stack fix wave |
| `379715af0` | docs(release): Record the invalid baseline end-to-end run |
| `8f8f4a061` | fix(output): Code every error and print compact results by default |
| `a6fc4426d` | feat(output): Publish a payload schema for every command result |
| `526878eac` | fix(input): Check legacy edge insets on the measured size; code slider failures |
| `aab61ae57` | docs(output): Document result shapes, error codes and the payload schema |
| `342581d55` | fix(output): Keep framework dumps out of messages; name unparsed commands |
| `eadb117e5` | docs(release): Record device and agent waves, second e2e run and blockers |
| `274eea28b` | test(device): Generate the Playground project and stop leaked captures |
| `8cd8dc359` | fix(device): Keep the whole drag duration and sleep post-delays locally |
| `b7659d37a` | perf(device): Resolve devices in the broker and share one display read |
| `38f773ca0` | ref(device): Run translator lookups off the pool and drop duplicate checks |
| `0912e1cea` | ref(device): Name device files after the types they hold |
| `e044d5a3f` | fix(device): Print readable check names in doctor text output |
| `80b3bcb74` | ref(device): Share the readiness and lock gate with the display stream |
| `f9084fd4c` | fix(agent): Refuse plain-HTTP model URLs for remote hosts |
| `c7050c0e5` | fix(agent): Bind retries to the same native object and type refusals |
| `402e4e121` | fix(agent): Refuse a page of a snapshot whose screen changed |
| `7d4fe21c5` | fix(agent): Admit single actions on screens with ticking text |
| `8a16aa638` | fix(agent): Keep the shared table on a caller's own request error |
| `05471c02b` | fix(agent): Give ID and option refusals their own codes |
| `7c95e5f9e` | perf(agent): Trim the compact agent reply to what an agent acts on |
| `a57fd8df9` | ref(agent): Remove dead agent code and share repeated checks |
| `df461bc96` | ref(agent): Merge the three owned-tree input paths in performReserved |
| `b8bf74027` | ref(agent): Split AgentModeController into batch, focus and planner files |
| `1294da23a` | ref(agent): Split AgentModeSnapshot into capture, fingerprint and index files |
| `976137639` | docs(agent): State the HTTPS rule for model base URLs |
| `4f28af3ee` | test(agent): Read the held-touch receipt from the full view |
| `b93050d72` | docs(release): Record the merge, output-contract evidence and gesture plan |
| `abedff34f` | feat(draw): Add axe draw for one-finger strokes through many points |
| `f53c105bf` | feat(gesture): Run coordinate gestures on simulators without a flag |
| `f75a93767` | test(e2e): Check draw and pinch on the Drawing and Zoom screens |
| `3d3edfeeb` | docs(gestures): Document draw and flag-free gestures |
| `be2335b1e` | test(e2e): Type only after the page settles above the keyboard |
| `a7c65702d` | fix(output): Use one error vocabulary on device and agent paths |
| `4b859379d` | ref(device): Treat explicit default options as given and drop duplicates |
| `49a587d4d` | test: Share test fixtures and helpers and drop dead tests |
| `1c6da9be2` | docs(release): Record gesture evidence, triage results and open items |
| `bdd9ddcce` | ref(device): Route physical device commands through one protocol |
| `762e228b3` | docs(readme): Rewrite the README as a user guide |
| `614371b77` | docs(skill): Match refusal codes, device output and settings limits |
| `e837aa93a` | docs(changelog): Describe v2 as its net change against v1.8.0 |
| `6c7807450` | docs(device): Replace the device working log with a design document |
| `cb6cc95f2` | docs(agent): Separate the environment summary heading |
| `d9de6dfd8` | docs(release): Record the documentation rewrite |
| `f3060e258` | ref(input): Carry ordinary swipe, drag and draw in SelectedHIDPath |
| `9cfd54a05` | ref(input): Make Home a selected button kind |
| `bdbde8021` | ref(input): Use one keyboard primitive list and drop the file channel |
| `d6fa0cf73` | ref(input): Send raw keys without the raw broker's keyboard branch |
| `5d18508a7` | ref(input): Let the selected owner decide success |
| `48ca3215e` | ref(input): Rename LegacyDuo types to OrdinaryBroker |
| `8a6daeff4` | docs(release): Record the Duo display investigation and IDBKit prune |
| `f4f717862` | docs(help): Shorten the shared input and agent option help |
| `0f66f3ff1` | docs(help): Rewrite the input command help as synopses and examples |
| `db36a515a` | docs(help): Rewrite the media and device state command help |
| `ed0814ce3` | docs(help): Rewrite the root, settings and setup command help |
| `a3dfc799b` | fix(duo): Trust a steady stale display report that fits the hinge |
| `e0ecca91f` | ref(idbkit): Remove two unused AX admission members |
| `1c92ef4de` | ref(idbkit): Remove XCTest, REPL and device-only protocol leftovers |
| `68eea2ed9` | ref(idbkit): Remove unreached FBControlCore utilities |
| `667da47b8` | ref(idbkit): Remove instruments and xctrace support |
| `fb12b4021` | ref(idbkit): Remove command families AXe never calls |
| `75d57037e` | ref(idbkit): Remove code the command removals orphaned |
| `085823b4f` | docs(idbkit): Describe what the trimmed IDBKit keeps and removes |
| `e048b33da` | docs(release): Record the architecture wave and merged state |
| `4f266cec1` | fix(gesture): Size presets from the measured screen on every simulator |
| `20527d12c` | docs(readme): Match the bgra stream and follow-active recording to the code |
| `1a0584df9` | fix(batch): Print a sentence for a selected step that fails to parse |
| `e45b0d3db` | test(displays): Pin display read failures to a sentence and a code |
| `2a4ee5093` | docs(release): Record the polish wave and the final run start |
| `b623e4f21` | test: Check command option refusals and list-simulators as unit tests |
| `7bc02cf5a` | test(e2e): Run plain commands on ordinary simulators in the matrix |
| `879674514` | test(e2e): Delete unregistered suites now covered by matrix suites |
| `963cae85f` | test(e2e): Fit the ordinary suites to the iPad and drop the BGRA case |
| `5b2427fd1` | fix(batch): Report malformed agent batch JSON as invalid arguments |
| `46c18a694` | fix(stream): Declare the ordinary MJPEG boundary without hyphens |
| `a35e1270d` | fix(displays): Read a locked or dark rigid simulator screen |
| `dbdb01118` | docs(testing): Say the capture suites cover ordinary screens too |
| `cc39c8d49` | fix(hid): Wait for the guest input service before plain input |
| `e908ab579` | docs(release): Record the third run, its triage and the four fixes |
| `0d8a5b0d9` | docs(agents): Limit the full e2e suite to major milestones |
| `edbb353fe` | fix(selected): Word a failed wait instead of printing its Swift type |
| `6463de619` | test(duo): Match three Duo suites to the audited output |
| `c06e149e8` | test(duo): Read the held Home receipt under the button key |
