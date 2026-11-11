# v2 release readiness

Working log for the production audit of the `v2` branch, started 2026-11-09 after the device-support
merge (`0aa6ed21b`). Each phase lists its tasks, how it was verified and the evidence. Nothing is pushed.

Status key: `[x]` done and verified, `[~]` in progress, `[ ]` not started, `[!]` blocked (see Blockers).

## Summary

- State: the full end-to-end suite passes on the three simulators at `d0885cfa2` (run 3 of Phase 13, 11 November): 116 suites, 872 tests, none failed. Two earlier full runs that night found three failures: two tests that raced the simulator, fixed in the tests, and one fault in AXe's new owned input connection, fixed in `d0885cfa2`. The device suite passes on the iPhone at the same commit; the iPad was locked and was not rerun. Open: the slider on percentage sliders (B1) and the Reminders benchmark failure, which is a state of the benchmark simulator and not of the build; the owner set both aside. The AXe-only agent benchmark was rerun on 11 November: Weather and Contacts are in line with 10 November, Reminders still shows the simulator state (Phase 13). Last update 11 November, about 09:10.
- Simulators at `d0885cfa2`: unit tests 877 of 877; iPhone 36 of 36 end-to-end suites (245 tests); Duo 67 of 67 (534 tests); iPad 13 of 13 (93 tests), all in one run. No timing regression against the pre-audit build.
- Devices: iPhone 16 Pro Max 14 of 14 checks at `d0885cfa2`. iPad Pro: last passed the full device suite at `25dfab0ca` and the two changed checks at `c96e375c9`, and it was locked overnight so it was not rerun; the owner decided on 11 November to skip it. The commands changed since then take their device branch before the changed code, by inspection, and the iPhone run exercises that same device code at the final commit.
- Not verified: timing against the v1.8.0 release binary (none on this Mac); timing on the Duo and on devices in this pass; the iPad Pro at the final commit.
- Correction: an earlier version of this log said the third end-to-end run of Phase 8 passed 96 of 101 suites. It ran 43. See Phase 8.
- Nothing is pushed.
- Commits made by this audit: see the commit log at the end.
- Blockers: none open. The devices were unreachable through CoreDevice from about 22:45 until 09:35, and the iPad again from about 12:30 until the owner restarted `CoreDeviceService` at about 13:38.

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

- [x] Device support bugs: fixed and merged into `v2` (7 commits); the device suite passes on the iPhone and iPad (Phase 8)
- [x] Simulator input and broker bugs
- [x] Agent mode bugs: fixed and merged into `v2` (13 commits)
- [x] Bugs found by the final verification (6 fixes, `5b2427fd1` to `2faeeedbc`)

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
| `gesture pinch --scale 2` without `--radius` failed on both devices with `pointOutsideDisplay` | The default radius put the end of the motion exactly on the screen edge, which a device refuses | `2faeeedbc`: the default radius keeps the wider end 16 points inside the screen. Unit tests; the device pinch check passes on the iPhone and the iPad |

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
- [x] `SelectedHIDRequest` as header fields plus an enum payload (SEL-16): done later, in Phase 11 (`986ecf927`). Folding the ordinary route into the selected route (SEL-17) is not done; it is tracked as the open item in Phase 11, not here

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
- [x] Draw and pinch on the physical devices: draw passed on both; pinch failed on both with `pointOutsideDisplay`, was fixed (`2faeeedbc`) and now passes on both (Phase 8)
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
- [x] Zoom suite on all three simulators after the pinch fix: passes (the iPad on a rerun)
- [x] Simulator end-to-end suites affected by the changes: iPhone 34 of 34 at `cc39c8d49`; Duo 64 of 64 passed at least once at `cc39c8d49` or later, 8 of them only on an isolated rerun; iPad 11 of 11 at `e45b0d3db` and `a35e1270d`, not rerun after the last input fix
- [x] Device end-to-end suite (`make e2e-devices`) on the iPhone 16 Pro Max and iPad Pro at `25dfab0ca`: 21 of 23 checks; the 2 pinch failures fixed (`2faeeedbc`) and that check rerun alone, passing on both
- [x] Taps and typing: verified on the iPhone, iPad and Duo simulators by the suites above, and on both devices ("coordinate taps", "typing and keys" and "element tap and point lookup" pass)
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

Physical devices (`e2e-results/devices-20261110T093536Z`, `v2` at `25dfab0ca`, about 6 minutes): the owner made the devices reachable again at 09:35. 21 of 23 checks passed.

| Check | iPad Pro (11-inch, M1) | iPhone 16 Pro Max |
| --- | --- | --- |
| Doctor | ready | ready |
| Coordinate taps | 2 exact, 970×1389 points | 2 exact, 440×956 points |
| Typing and keys | pass | pass |
| Draw a closed triangle | pass, 1.29 s | pass, 1.27 s |
| Pinch in and out | FAIL `pointOutsideDisplay` | FAIL `pointOutsideDisplay` |
| Element tap and point lookup | pass | pass |
| Screenshot | 1940×2778 upright | 1320×2868 upright |
| Raw stream, MP4 recording | pass | pass |
| Native H.264 over 20 s | 288 frames | 1008 frames |
| Rotation with taps | 4 turns confirmed | 3 confirmed, 1 unconfirmed (the tap after it landed exactly) |
| Both at once: capture and input | pass | pass |

Pinch: without `--radius` a pinch started a quarter of the shorter side from the centre, so `--scale 2` ended exactly on the screen edge (x = 0 and x = 440 on the iPhone). A device refuses a point on the edge; a simulator accepts it. The default radius is now reduced when needed so the wider end stays 16 points inside the screen (`2faeeedbc`, unit tests). Rerun of that one check with the new `AXE_E2E_CHECKS="pinch in and out"` option (`ba8619661`; `e2e-results/devices-20261110T094519Z`): iPad 1.00 → 1.81 → 0.98, iPhone 1.00 → 1.68 → 0.97, both pass.

The pinch fix also changes the default radius on simulators, so `PlaygroundZoomTests` alone was run on all three (`e2e-results/zoom-isolated-1` and `-2`, `v2` at `ba8619661`): iPhone and Duo passed; the iPad failed once with a default-pinch zoom of 1.27 (the check needs more than 1.3) and passed on rerun with 1.82, the same value as before the change. Fourteen isolated pinches on that simulator, eight with the new default and six with the old 205-point radius, gave 1.82 to 1.91, so the 1.27 was not caused by the radius. The measured zoom depends on when the app's recogniser sees the first movement, which varies when the machine is busy.

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

## Phase 10: drawing evidence, PencilKit and the competitor comparison (10 November)

- [x] Drawing shown on a simulator and both devices: nine strokes (star, house, "AXe", wave, 120-point spiral) with `axe draw` on the iPhone 18 Pro simulator, the iPhone 16 Pro Max and the iPad Pro. The app counted 9 strokes on each. Screenshots in `e2e-results/drawing-demo/`.
- [x] A PencilKit screen in the Playground (`Sketch`, `c1995e53f`): a `PKCanvasView` with the system tool picker. A finger draws, so `axe draw` leaves real ink. The screen reports the stroke count, the selected tool and the last stroke's ink.
- [x] A painting made with axe alone (`scripts/demos/paint-sunset.py`): a sunset with a sun, mountains, a tree, a boat, stars and birds. 78 strokes from 235 axe commands in 4.5 minutes on the iPhone 18 Pro simulator. Tools and line weights are chosen in the tool picker by accessibility label, opacity by dragging the picker's slider, colours by tapping the system colour picker's grid. Picture and recording: `e2e-results/sketch-demo/sunset-iphone-sim.png` and `.mp4` (keep).
- [x] End-to-end checks for it (`ea1115840`): `PlaygroundSketchTests` (4 cases, on the iPhone, iPad and Duo profiles) and a device check, "PencilKit ink and tool picker". Run since in isolation: the suite, now 5 cases, passes on the three simulators and the device check on both devices, at `c96e375c9` (Phase 12).
- [x] Gesture conveniences that FlowDeck or RocketSim have and AXe lacks: closed, item by item, in Phase 11

What the painting found:

- The pen's line gets thinner as the finger moves faster, so fills made with it leave gaps. Monoline keeps one width (about 7 points at "Very Heavy") and is opaque, so every solid shape uses it. The marker blends like a highlighter and suits the sky and water washes only.
- `axe slider --id Opacity --value 100` fails on the tool picker's opacity slider with `unsupportedValueDomain`: the slider reports its value as "80%" and no numeric range. The script drags the knob instead. Not fixed.
- The system colour picker draws in another process and exposes no elements, so its grid is tapped by position (measured for a 402-point-wide iPhone).
- A tap sent 0.6 s after the picker expanded was ignored once; the script checks that the colour picker opened and taps again.

Gesture and drawing commands compared (FlowDeck 1.34.0 `flowdeck ui simulator`, RocketSim 16.8.0 `rocketsim interact`, both read from the installed command lines):

| Capability | AXe | FlowDeck | RocketSim |
| --- | --- | --- | --- |
| Tap by point or element | yes | yes | yes |
| Long press | point: `touch --down --up --delay`; element: agent `--ref` only | `tap --duration`, point or label | `long-press`, point or selector |
| Double tap | point; element: agent `--ref` only | point or label | no |
| Two-finger tap and hold | yes, two points | no | `--touches 2`, point or selector |
| Swipe between points | yes | yes | yes |
| Swipe by direction | presets `scroll-*`, fixed length; inside an element with agent `--ref` | direction and `--distance` | direction; from an element |
| Hold, then drag (reorder) | `drag` rests briefly, not adjustable | `swipe --hold` | no |
| Scroll until an element shows | no | `scroll --until` | no (pages only) |
| Edge and system swipes | left, right, top and bottom edge presets | `back` | back, Notification Centre, Control Centre |
| Pinch | yes, centre, radius, scale | yes | no |
| Rotate | yes | yes | no |
| Two-finger swipe | yes | no | no |
| Draw a path of points | `draw`, up to 1,000 points | no (`touch` has down and up only) | no |
| Touch down, move, up | yes | down and up | no |
| Physical iPhone and iPad | yes | no | no |

AXe has every gesture type the other two have and is the only one that can draw. Its gaps are conveniences: a long press or double tap on an element without agent mode, an adjustable hold before a drag, scrolling until an element is visible, a distance for direction swipes, and a Control Centre swipe.

## Phase 11: gesture gaps, bugs from the painting and the remaining refactors

Gaps against FlowDeck and RocketSim (from the table in Phase 10), all closed in `a551b96ff`:

- [x] G1. Long press on an element: `tap --hold <seconds>` with `--id`, `--label`, `--value` or a point
- [x] G2. Double tap on an element: `tap --count 2`
- [x] G3. Two-finger tap on an element: `tap --touches 2` (two contacts 40 points apart; with `--hold`, a two-finger long press)
- [x] G4. Hold before a drag: `drag --hold <seconds>`
- [x] G5. Scroll until an element is visible: `gesture scroll-* --until-id` or `--until-label`, with `--max-swipes` (default 10)
- [x] G6. Distance for direction swipes: `gesture scroll-* --distance <fraction of the screen>`
- [x] G7. Control Centre: the `swipe-from-top-right-corner` preset

Evidence for G1 to G7:

- Unit tests: 13 new (`GestureConvenienceTests`); the whole suite passes, 858 tests.
- Live on the iPhone 18 Pro simulator and the physical iPad Pro, read back from the Drawing screen, which records every contact: `tap --hold 1.2` one contact of 1.20 s (1.21 s on the iPad); `tap --id --hold 0.8` 0.80 s at the element's centre; `--count 2` two contacts; `--touches 2` two fingers; `drag --hold 0.7` 1.36 s against 0.72 s without it, both 200 points long; `scroll-down --distance 0.5` moved 437 of 874 points (694.5 of 1389 on the iPad); `scroll-up --until-id` found a row 14 below the last visible one after 2 scrolls, sent nothing on a second run ("after 0 scrolls") and failed with `elementNotFound` for a missing element.
- Control Centre opened on the simulator from the home screen and on the physical iPad from the Playground; on the iPad it was closed again with a tap and the device stayed unlocked. It does not open from a screen that defers system gestures (the Drawing screen shows the system's grabber instead), as a finger would not.
- End-to-end: a new suite, `PlaygroundGestureConvenienceTests` (8 cases), passes alone on the iPhone, iPad and Duo simulators (`e2e-results/sketch-gestures-2`). Two new device checks: "long press and other touch gestures" passes on both devices; "scroll distance and scroll until" passed on the iPhone and failed once on the iPad when a screen read taken while the list was still moving came back invalid. Scroll-until now retries that read up to three times (`47f7cec06`).

Bugs and limits found while painting:

- [ ] B1. `axe slider` fails with `unsupportedValueDomain` on the tool picker's opacity slider. Not fixed. The slider is not a native slider underneath: it reports its value as text ("80%"), a minimum and maximum of 0, and none of the scrubber geometry AXe's slider code reads. A first attempt (treat a percentage as 0 to 100) got past the range check and failed at the next one, so it was reverted. A real fix is a second strategy for sliders without native geometry: drag along the frame and read the value back. Workaround: `drag` the knob
- [x] B2. A tap sent just after the tool picker expanded or scrolled did nothing. Cause found: iOS does not deliver a tap that lands while a scroll view is still gliding or bouncing back; the touch only stops the motion. Scroll-until now waits until two reads of the screen match before it reports success (`4b6b93964`), so the next command can tap
- [x] B3. The system colour picker exposes no accessibility elements (it draws in another process). A system limit. The Sketch screen now has ten named colour swatches (`sketch.colour.<name>`), so checks pick colours without it
- [x] B4. The painting script's colour grid positions are measured for one screen size. Unchanged in the demo script, which says so; the end-to-end checks use the swatches instead and run on every screen size

PencilKit checks:

- [x] `PlaygroundSketchTests` alone on the iPhone, iPad and Duo simulators: 4 of 4 cases on each (`e2e-results/sketch-isolated-1`), and "PencilKit ink and tool picker" on both devices after the check was changed to use only elements a device lists (`cea002db1`)
- [x] A picture in the checks, first version (`4c6501a46`): sky, grass, a sun, a house, a tree and two birds. It passed on both devices and all three simulators, and the owner found it crude
- [x] A shaded 3D car instead (`ad67ba737`). `scripts/demos/car_picture.py` holds a small 3D model of a coupe, lights it, projects it and emits flat faces far to near, each in one of five tones of red, over watercolour washes, a crayon road and a soft cast shadow, with fountain-pen lines, pencil hatching and highlights. `scripts/sketch_picture.py` plays that list through the axe CLI on a simulator or a device, and both the simulator case and the device check run it. Painted once on the iPhone 18 Pro simulator: 161 strokes, 23 inks, 296 axe commands, 183 s (`e2e-results/sketch-demo/car-iphone-sim.png`). It now passes in the checks on the iPhone, iPad and Duo simulators (`e2e-results/sketch-car-5`) and on the iPhone 16 Pro Max and iPad Pro (`devices-20261110T141600Z`: 163 and 164 strokes, 23 inks), at `c96e375c9`; what it took is in Phase 12
- [x] Scrolling inside one strip and stopping at its end (`95335a390`, `6a5eaab54`, `4b6b93964`), after the owner watched a probe script bounce the tool picker against its end: `swipe` takes `--until-id`/`--until-label`, scroll presets take `--inside-id`/`--inside-label`, an element counts as on screen only when a lookup at its centre finds it, and the loop stops with `elementNotFound` as soon as a scroll moves nothing. On the simulator, `gesture scroll-left --inside-id Drawing-Palette --until-label Watercolor` took 2 scrolls and 3.2 s, and a tool that does not exist failed after 2 scrolls in 3.8 s instead of 10. Unit tests: 17 in `GestureConvenienceTests`; whole suite 861

Input-stack refactors carried over from Phase 4:

- [x] SEL-16. `SelectedHIDRequest` now has header fields and one `Payload` enum instead of thirteen optional fields (`986ecf927`). A mixed request cannot be built or decoded, and the validation that policed mixes is gone; 42 files, 21 fewer lines. Unit suite passes. End to end, run alone at `76f538fd9` (`e2e-results/sketch-sel16-1`): 17 of 17 suite runs passed across the three simulators (core, agent, agent pinch, ordinary regression and Sketch on the iPhone and iPad; Duo core, hardware, selected batch keyboard, selected Home batch, hinge window, agent, agent pinch and Sketch on the Duo), and 6 of 6 device checks
- [x] SEL-17, in the narrower form the measurement supported (`d4b9952fd`): plain tap, swipe, drag, draw, scroll presets and complete touch let a running broker bind the screen, as selected input does. Keyboard commands and split touches keep their route, because selected input has different rules for them. Detail and evidence under "SEL-17 change" in Phase 12

## Phase 12: device speed, the Device MCP comparison and scroll-until (10 November, afternoon)

The owner found device commands far too slow while watching the car being painted on the iPad, and asked for the cause and a comparison with Device MCP.

Where the time went, measured on the iPhone 16 Pro Max (iOS 27.2, USB):

- [x] Every command made the device broker run `devicectl` twice before doing anything: device details, then lock state, 0.25 s each. A coordinate tap took 0.60 s, of which the touch was 0.07 s. `devicectl --version` alone takes 0.19 s, so the cost is starting the tool, not the query.
- [x] A read of the accessibility tree is a new request to the device each time, and the wait is on the device: the first part of the tree arrives after about 0.9 s and the identifiers in a second part, about 40 ms per element in all. The broker sits idle in `poll` meanwhile, and turning the tree into JSON takes 0.01 s. Keeping accessibility switched on between reads did not shorten it, and a held subscription sent nothing in 4 s after a tap changed a label, so each read has to ask.
- [x] `tap --id`, `--label` and `--value` read the tree twice and compared the target before tapping.
- [x] The device does not offer its lock state over the tunnel: the request was sent to every `com.apple.coredevice.*` service and each answered "not implemented". So the lock check cannot be made cheaper than a `devicectl` run.

Changes (`7ca36099c`):

- The broker skips the two readiness reads when it sent input to the device in the last 25 seconds, the quiet gap a batch already used. A failed operation or `button lock` ends that. After a quiet gap the first command pays the 0.5 s again (measured: 0.64 s, then 0.10 s).
- A tap by selector taps from one read. A target that appeared while `--wait-timeout` was polling is still read a second time and refused with `targetChanged` if it moved.
- Tried and withdrawn: running the two `devicectl` reads at once. Right after it, three commands in a row failed with "devicectl device info … The operation failed" after 10 s each, then recovered. I could not show that the parallel reads caused it, so they run in sequence as before.

| iPhone 16 Pro Max | AXe before | AXe now | Device MCP 0.9.0 |
| --- | --- | --- | --- |
| Tap at a point | 0.60 s | 0.10 s | 0.055 s |
| Tree after a tap | 1.86 s | 1.4 s | 1.6 to 1.8 s |
| Tree with no input before it | 1.86 s | 1.86 s | 1.0 s without identifiers; 0.01 s from its cache |
| Tap by label | 2.8 s | 1.45 s | 1.75 s |

Device MCP (Proxyman, `/Applications/Device MCP.app`), driven through its `device-mcp` bridge and sampled while it read (`e2e-results/device-perf/device-mcp-sample.txt`, `device-mcp-log.txt`):

- It waits on the device for the tree exactly as AXe does: its session thread is parked in `kevent` for the whole read and parsing the dump takes 6 ms of 5.9 s sampled. It uses the same accessibility service and the same HID service.
- It is one long-running app that keeps its connections, so a tap costs 0.055 s with no process start and no readiness check. It opens its own tunnel through usbmux and never calls `devicectl`, which is why it listed the iPad as ready while CoreDevice could not answer for it.
- Its first answer is a "quick pass" tree that may lack identifiers (it does not wait for the second part), and it serves a tree from a cache for a few seconds. After a tap made outside it, it returned the old tree in 0.00 s ("Selected: Row 14" when the screen showed Row 17).
- The owner's decision: the tree wait is the device's and is the same in both, so it stays.

Scroll-until skipped its target (found by the isolated rerun at `a1b74d1c3`, `e2e-results/sketch-car-2`):

- [x] Cause: each step was a flick. A `scroll-up --distance 0.4` moved the list 10.5 rows on a screen that shows 10, so a row could cross the screen between two reads. Each step now slows to a stop before the finger lifts, on simulators and devices, and moves exactly its own length (5 rows, at rest at once). By hand: the failing case finds row 22 in 3 scrolls on the iPhone simulator and row 40 in 4 scrolls on the physical iPhone, and the row is tappable straight away. Device MCP's `scroll_to` documents the same rule.
- [x] The picture player swiped the tool picker from a point on its colour button, where a drag moves or minimises the palette instead of scrolling the tools. It now swipes between the first and third tools.
- [x] The Sketch screen selects the pen on every visit. The system tool picker restores the last launch's tool, so the first check drew with whatever the car painting left selected.

Isolated reruns of the two suites the changes touch, never the full suite:

| Run | Commit | iPhone | iPad | Duo |
| --- | --- | --- | --- | --- |
| `e2e-results/sketch-car-2` | `a1b74d1c3` | Sketch 4 of 5, gestures 7 of 8 | Sketch 1 of 5, gestures 8 of 8 | Sketch 1 of 5, gestures 8 of 8 |
| `e2e-results/sketch-car-3` | `948517299` | Sketch 4 of 5 (the car stopped on "Monoline options"), gestures 8 of 8 | Sketch 5 of 5, gestures 8 of 8 | Sketch 5 of 5, gestures 8 of 8 |
| `e2e-results/sketch-car-4` | `04762105a` | Sketch 5 of 5 (car: 161 strokes, 23 inks, 172 s) | not rerun | not rerun |
| `e2e-results/sketch-car-5` | `c96e375c9` | Sketch 5 of 5, gestures 8 of 8 | Sketch 5 of 5, gestures 8 of 8 | Sketch 5 of 5, gestures 8 of 8 |

- [x] The last iPhone failure: a tool selected at the edge of the picker's strip slides into view, so the tap that opens its options landed where it had been. The player now waits until two reads agree on the tool's frame (`04762105a`).
- [x] By hand with the same player: the car on the iPad Air simulator (164 strokes, 170 s, `e2e-results/sketch-demo/car-ipad-sim.png`) and on the iPhone 18 Pro simulator (161 strokes, 183 s).
- [x] Rerun on the devices after the owner restarted `CoreDeviceService` (about 13:38): see below.
- Unit tests: 867 of 867 at `c96e375c9`. Script tests: 19 of 19.

Device rerun of the two changed checks, both devices each time (`make e2e-devices` with `AXE_E2E_CHECKS`):

| Run | Commit | iPhone 16 Pro Max | iPad Pro |
| --- | --- | --- | --- |
| `devices-20261110T133900Z` | `588a1e9d0` | scroll passes; picker would not scroll to Watercolor | scroll passes; whole car painted, then every read failed |
| `devices-20261110T140550Z` | `5fdeccb7a` (replaced) | scroll passes; `ambiguousPoint` on the picker | the same |
| `devices-20261110T141600Z` | `c96e375c9` | both pass: 163 strokes, 23 inks, 314 s | both pass: 164 strokes, 23 inks, 403 s |

What the first two runs found:

- [x] A read of a large screen failed on a device. The device takes about 0.9 s plus 44 ms per element to send its tree (iPad Pro: 48 elements in 2.9 s, 148 in 7.3 s, 188 in 9.1 s), and a read was given 6 s, so any screen above about 115 elements failed with `treeUnavailable`. PencilKit lists each stroke as an element, which is how the car found it: after 141 strokes the iPad could not be read, and clearing the canvas brought reads back to 2.9 s. A read now has 20 s, about 330 elements (`eaf1d3a51`). This is a limit real apps would have met.
- [x] The second request for a tree made large reads slower. A device that had sent nothing after 2.5 s was asked again, and asking restarts a tree it is still building: 9.6 s for 148 elements with it, 7.3 s without. It now waits 6 s (`eaf1d3a51`). Recent runs show no cluster of reads 2.5 s slower than their neighbours, so the case it rescues is rare.
- [x] A short scroll-until step did not scroll on a physical iPhone. A 92-point swipe at the default 50 points a move has two moves, and with two the tool picker's strip stayed put; with ten it scrolled. A device step now has at least eight moves (`eaf1d3a51`). The iPad's lane was 102 points, three moves, which is why it worked there.
- [x] The Sketch canvas no longer lists its strokes as elements (`c96e375c9`), so the check's reads stay near 2 s on the iPhone however much is drawn. A first attempt made the canvas one element; it then covered the tool picker floating over it and a device refused every point of the picker with `ambiguousPoint`, because a device tree has no z-order.
- One read on the iPad took 11.2 s in the passing run, against 2 to 4 s for the rest; not investigated.

Release check and CHANGELOG (10 November, late afternoon):

- [x] `make release-check` (`bad29dfa8`) runs the quick checks in one go and reports each: released CHANGELOG sections unchanged, script tests, the two skill copies identical, skill lint, no open items in this log, packaging dry run, unit tests. First run: 6 pass, and "readiness log" fails on the two open items in Phase 11, as it should.
- [x] CHANGELOG reviewed against v1.8.0 by comparing every command and option in the source: 10 new commands, all described; 77 new options, none removed. Three corrections: the `screensDidNotSettle` entry left Fixed (the Duo is new in this release), the scroll-until entry says each scroll stops with the finger, and the device entry names `draw`, taps by selector and the time a screen read takes.

SEL-17 measurement (10 November, about 15:10; load average 4 to 9; scripts in `e2e-results/sel17/`):

Plain commands and `--input-mode selected` commands were run alternately, 20 to 30 times each, on the iPhone 18 Pro and iPhone Duo simulators, with the same points and durations. Medians in ms:

| Command | iPhone plain | iPhone selected | Duo plain | Duo selected |
| --- | --- | --- | --- | --- |
| Tap, simulator style (no hold) | 158 | 87 | 173 | 99 |
| Tap, physical style (0.1 s hold) | 263 | 196 | 287 | 203 |
| Tap, each route's default | 159 | 186 | 186 | 213 |
| Swipe, 0.3 s | 502 | 436 | 526 | 441 |
| Drag, 0.3 s | 670 | 597 | 718 | 653 |
| `gesture scroll-down` | 720 | 630 | 758 | 653 |
| Draw, 3 points, 0.3 s | 635 | 560 | 671 | 592 |
| `touch --down --up`, repeated | 904 | 195 | about 1,050 | 216 |

- [x] For the same input, selected is faster on every command, by 65 to 105 ms. In 30 alternating pairs on the iPhone the selected swipe, drag and scroll were faster 30 times out of 30.
- [x] The earlier figure (selected tap 0.183 s, plain tap 0.153 s) compared different taps. A plain tap defaults to the simulator style, with no hold; a selected tap at a point holds the touch for 0.1 s by default.
- [x] Where the 70 ms goes: a plain command loads the simulator set and measures the active screen in the client before it sends anything; a selected command sends its request at once and the broker, which already holds that state, binds the active screen. Naming the screen with `--screen-id` and `--screen-uuid` saves the broker a further 17 ms.
- [x] A cost found on the plain route: after a plain `touch --down --up`, the next plain command of any kind takes 0.6 to 0.9 s longer (iPhone: a tap 911 ms instead of 156, a swipe 1,075 instead of 505; still 0.4 s longer after a 2 s pause). The plain touch path closes its input session and display feed when the finger lifts, which the other commands do not. A selected touch takes 195 ms and leaves nothing behind. The CHANGELOG's "a touch 0.25 s" is right for the touch itself and does not mention this.
- What a fold cannot include without changing behaviour: `key`, `type` and the other keyboard commands (selected keyboard input requires `--focus-id` of the focused field; plain does not), a `touch --down` followed later by a separate `touch --up` (selected uses a contact token), the plain default tap style, and the plain swipe's own event list, which ends with a repeated last point to stop the content gliding.
- Proposed, not done: a narrower fold. Plain tap, swipe, drag, draw, scroll presets and complete `touch --down --up` on current simulators let the broker bind the active screen instead of measuring it in the client, keeping their events, defaults and output. Expected: about 70 ms off each of those commands and the 0.6 to 0.9 s after a touch gone. Keyboard and split touches stay as they are.

SEL-17 change (10 November, evening; the owner approved the narrower fold):

- [x] Where the time went, with temporary timing in a plain tap of 150 ms: loading the simulator set in the client 64 ms, reading the active screen 10 ms, reading its geometry 8 ms, the exchange with the broker 40 ms.
- [x] The change (`d4b9952fd`): when a broker is already running, a plain tap at a point, swipe, drag, draw, scroll or edge preset and complete `touch --down --up` send their input for the broker to bind to the active screen. The events, defaults and output are unchanged. With no broker running, or when the broker refuses before input, the command takes the measured route as before, so the first command after a boot and every refusal message are the same as in the previous build (checked for an off-screen tap, swipe, drag and draw). Commands that read or override the screen first keep the measured route: a tap by selector, a pre-delay, an explicit screen size, scroll-until and scroll inside an element.
- [x] A complete touch is now one contact, like a tap, on both routes. That removes the 0.6 to 0.9 s the next command paid.
- [x] Unit tests: 876 of 876, 9 new (the request's rules, the wire round trip, which refusals allow a fallback, the tap and touch contacts against the old events, the preset layout against the client's, and a connect that never starts a broker). The wire version is 90.

Medians in ms, previous build (`c96e375c9`) then this one, in alternating blocks (`e2e-results/sel17/`):

| Command | iPhone before | iPhone after | Duo before | Duo after |
| --- | --- | --- | --- | --- |
| Tap | 139 | 78 | 161 | 92 |
| Tap, 0.1 s hold | 259 | 200 | 268 | 214 |
| Swipe, 0.3 s | 495 | 440 | 504 | 458 |
| Drag, 0.3 s | 666 | 604 | 662 | 597 |
| Draw, 3 points | 633 | 571 | 633 | 563 |
| `gesture scroll-down` | 713 | 654 | 723 | 670 |
| `touch --down --up`, repeated | 922 | 200 | 874 | 209 |
| Tap after a touch | 820 | 88 | 802 | 101 |

Isolated end-to-end runs of the suites that use plain touch input, never the full matrix:

| Run | Commit | iPhone | iPad | Duo |
| --- | --- | --- | --- | --- |
| `e2e-results/plain-bound-1` | `d4b9952fd` | 9 of 10 suites | 7 of 8 suites | 15 of 16 suites |
| `e2e-results/plain-bound-2` | `4ac61b349` | Sketch 5 of 5 | Sketch 5 of 5 | Sketch 5 of 5 |

- The suites: core, drawing, zoom, Sketch, gesture conveniences, ordinary regression, ordinary input, ordinary batch and the two input handover suites on the iPhone; the first eight on the iPad; on the Duo its core, gesture, coordinate and scroll coverage, tap style, retained input, motion options, navigation, batch coverage, legacy batch interruption and horizontal preset suites, with drawing, zoom, Sketch, gesture conveniences and input handover.
- [x] The one failure in the first run, on all three simulators, was the car: with taps 60 ms quicker, the first colour tap after a tool's options closed landed while they were still closing and the app ignored it. The picture player now confirms the first colour after each tool change (`4ac61b349`). This is the app's timing, and a faster tool reaches it sooner; scripts that tap straight after dismissing something may meet the same.
- Not rerun: the agent, keyboard, media and hinge groups, which do not use the changed commands, and the device checks, which use a different broker.

Agent benchmark, AXe only, simulators (10 November, evening; `benchmarks/artifacts/20261110T174245Z-74bbfd15c2d9`):

The owner asked for the benchmark against the last run and the baseline, without the third-party tools. Three repeats per app at `829069eeb` (v1.8.0-405), model `claude-opus-4-7`, on the benchmark simulator once it was warm. Ranges over the repeats:

| Task | Accepted baseline (v1.8.0-185) | Last run, 8 November (v1.8.0-257) | This run (v1.8.0-405) |
| --- | --- | --- | --- |
| Weather | 16 to 19 calls, 206 to 227 s, 7.0k to 7.7k tokens, passed | 19 to 20 calls, 123 to 134 s, 9.1k to 10.6k tokens, passed 3 of 3 | 20 calls, 116 to 124 s, 8.9k to 9.7k tokens, passed 3 of 3 |
| Contacts | 11 to 12 calls, 144 to 168 s, 8.4k to 9.0k tokens, passed | 12 calls, 96 to 101 s, 10.5k to 10.9k tokens, passed 3 of 3 | 12 calls, 95 to 112 s, 9.7k to 10.0k tokens; recorded unverified 3 of 3, passes when regraded |
| Reminders | 20 to 25 calls, 195 to 312 s, 8.6k to 10.3k tokens, passed | 17 to 18 calls, 94 to 100 s, 11.4k to 11.7k tokens, passed 3 of 3 | 26 to 28 calls, 230 to 293 s, 12.2k to 13.0k tokens; failed 2, unverified 1 |

- The harness reports no ranked comparison with the baseline: the skill, the harness and the Weather app source have changed since it was accepted, so the baseline belongs to another contract. The figures are side by side, not ranked.
- [x] Per-command time is unchanged from 8 November in the Reminders transcripts: a tap 0.72 s today and 0.76 s then; typing 2.68 and 2.66 s; a read 0.22 and 0.20 s. Agent commands were not part of today's plain-input change.
- [x] Contacts was graded unverified because of the benchmark's grader, not AXe. A compact refusal reply omits `data.cache`, as documented, and the transcript reader then ignored its capture, which is where the saved card was last seen. Fixed in the grader (`96f6ebe53`; 195 benchmark tests pass); the same evidence passes. The recorded reports in history still say unverified.
- [ ] Reminders is worse today and it is not this build: the AXe binary kept from the 8 November run, run today, failed the same way (30 calls, 338 s). Investigated on 10 November, late evening; the on-screen cause is found and what switches it on is not (evidence in `e2e-results/benchmark-reminders/`):
  - What happens, from screenshots taken four times a second during a failing run: the first reminder is completed and its row stays on screen. On a healthy simulator Reminders removes that row by itself about 2.2 s after it is completed. Here it stays until the next touch, 4 s or more later. That touch is the agent's tap on the second reminder's circle, so the list reshuffles under the tap, the circle is left looking filled, the title stays black and the reminder is not completed. AXe's reply is accurate: two events sent, and the returned capture says "Incomplete".
  - It is a state of the simulator, not of the build or of the Reminders session. On the benchmark simulator the same scripted sequence completed the reminder 30 times out of 30 until 19:25 and failed 12 times out of 12 after a benchmark run at 19:29; relaunching Reminders did not clear it and the earlier reboot had. On the development simulator it never failed (about 20 tries). When the row has already gone, AXe sees the changed screen, retries inside the call and the tap lands (`retried: true`), which is what every passing run shows.
  - Ruled out as the switch, each tried on a healthy simulator: the delay between the two taps (1.3 to 6.6 s), reading the screen or taking screenshots in between, Show Completed, deleting a list, taps in the form the benchmark's preparation uses, relaunching Reminders straight into a read, and the device settings (identical on both simulators).
  - Not done: finding which step of a benchmark run switches it on. The next step would be to reboot the benchmark simulator, confirm it is healthy, then run the preparation and the task one part at a time with the two-tap test after each.
  - A mistake of mine during this: after I relaunched Reminders a test script kept adding reminders on the overview screen and created 115 in the default list of the benchmark simulator. I deleted them and the three scratch lists; the simulator's Reminders is back to its recorded inventory.
- [x] Weather: `type --focus` on the search field failed with `nativeActionFailed` in 3 runs of 3 and in none on 8 November. It was a regression in this branch, fixed in `1c5c3eeba`. After the focus tap the keyboard takes about two seconds to report that field as focused, so the typing phase is refused before any key. The 8 November build retried that refusal and typed on the second attempt; the audit's narrower retry policy (`c7050c0e5`) stopped retrying it, and the command failed after 2.6 s. The focus-and-type flow now sends the typing phase again, up to three more times, for that one refusal; the general policy is unchanged. On the Weather app by hand: the 8 November build types in 5.6 s, the build before the fix fails 5 times of 5, the fixed build types 6 times of 6. Unit tests 877 of 877. Isolated runs at `1c5c3eeba` (`e2e-results/focus-type-1`): agent batch, agent type and focus-and-type suites pass on the iPhone and Duo simulators. Two more Weather benchmark runs: the typing step succeeded in both; one passed with 17 calls and no errors.
  - I tried to add a Playground screen that reproduces the delay (a search field in a sheet with two sizes, as in Weather). It did not: every build typed there in 2 s, so I removed it. The regression test is a unit test of which refusals are sent again; nothing end to end covers a slow-focus field.
  - Seen twice and not investigated: the first Weather launch after the benchmark simulator boots cannot be read for about 25 seconds (`observationFailed` three times), even 2.5 minutes after boot. The agent retries and continues.
- A first run, straight after I booted the benchmark simulator, is in history but not in the table: Weather's first three reads failed with `observationFailed` for 25 seconds after launch, which is the freshly booted simulator.
- `./benchmarks/run doctor` fails with `'setupAxe'` when `build_products/axe` does not exist. A run builds it; doctor should say so. Not fixed.

## Phase 13: full end-to-end runs and the fixes they led to (10 to 11 November, overnight)

The owner approved the full suite on the evening of 10 November, then asked for any failures to be fixed and checked in isolation, with one more full run once nothing was left to fix. Three full runs, each `scripts/run-e2e.sh` from a clean checkout on the dedicated iPhone, iPad and Duo simulators, Xcode 27.2 beta 3, about 175 minutes each:

| Run | Commit | iPhone | Duo | iPad |
| --- | --- | --- | --- | --- |
| `e2e-results/20261110T210529Z` | `95415b39e` | 35 of 36 suites (245 tests, 1 failed) | 67 of 67 (534 tests) | 13 of 13 (93 tests) |
| `e2e-results/20261111T001748Z` | `d0a22a5f3` | 35 of 36 (1 failed) | 66 of 67 (1 failed) | 13 of 13 |
| `e2e-results/20261111T043856Z` | `d0885cfa2` | 36 of 36 (245 tests) | 67 of 67 (534 tests) | 13 of 13 (93 tests) |

- [x] The third run is the release evidence for simulators: 116 suites and 872 tests, none failed, at the commit that holds every fix below. The payload was unchanged by the run and every process the run started had stopped at its end.
- The three failures were three different things. Two were tests that raced the simulator; one was a fault in AXe.

Run 1, iPhone, `PlaygroundOrdinaryButtonTests`: the Siri check timed out waiting for the Siri window.

- [x] Not AXe. The press arrived: SpringBoard logged it. On this simulator Siri's device arbitration finds no other device on every press and asks for Siri to be dismissed. That request normally lands before Siri starts to appear and does nothing. In the failing run it landed about 30 ms after, and Siri closed as it opened. The unchanged test then passed 3 times of 3 alone (`e2e-results/siri-rerun-1` to `-3`).
- [x] The test now presses again, up to three times, and only when SpringBoard's log shows that the press before it arrived, so a press AXe failed to deliver still fails the test (`d0a22a5f3`). 3 of 3 alone (`siri-fix-1` to `-3`), and it passed in runs 2 and 3. The Duo's Siri check has the same exposure and has not failed; it is unchanged.

Run 2, Duo, `PlaygroundDuoSelectedTargetTests`: a comparison of the screen before and after a command saw the text field lose focus.

- [x] Not AXe. The test dismisses the keyboard with a tap and then records the screen. The tap ends before the field gives up focus, so the next command appeared to cause the focus change. Plain taps are about 60 ms quicker since `d4b9952fd`, which is what brought the test to that moment. The test now waits for the field to lose focus before recording (`0fb3bb7ca`).

Run 2, iPhone, `PlaygroundColdInputHandoverTests`: `The input was refused. No input was sent.`

- [x] A fault in AXe, in code new in v2. The first command sent through a new owned input connection waits for the simulator to answer before any input goes out. It waited 2 s, twice. The iPhone simulator, three hours into the run, answered after 3.5 to 4.3 s (under 1 s on a fresh one), so both tries ran out and the command was refused. The plain connection has waited 10 s for the same answer since `cc39c8d49`; the owned one now waits as long, with its one fresh try kept (`d0885cfa2`).
- The refusal was honest: no input was sent and the reply said so. What it hid was the reason (`DTUHID initial guest barrier timed out`), which the error text filter drops because it looks like a dump.
- Before the fix, on the simulator as the run left it: the two handover suites failed in 5 of 6 isolated runs of the run's build (`cold-rerun-1` to `-6`) and in 4 of 9 with a build that logged the wait (`cold-diag-1` to `-9`). With the change: 6 of 6 (`cand-1` to `-6`). With the committed build: 3 of 3 on the iPhone for the two handover suites and the agent touch suite, and 3 of 3 on the Duo for the selected target, retained input and retained pair suites (`e2e-results/barrier-fix/`).
- Unit tests at `d0885cfa2`: 877 of 877. `make release-check`: 6 checks pass; the seventh is this log's own two open items.
- No changelog entry: the owned connection does not exist in v1.8.0.

Physical devices at `d0885cfa2`:

- [x] iPhone 16 Pro Max: `make e2e-devices` passes 14 of 14 checks (`e2e-results/devices-20261111T073614Z` in the main checkout; the car: 163 strokes, 23 inks). The rotation check confirmed 3 of 4 turns with exact taps and reported the fourth as unconfirmed, which it allows.
- iPad Pro: not rerun, and the owner decided on 11 November to skip it. It has been locked since the evening of 10 November (`passcodeRequired: true`) and only the owner can unlock it. Both devices were locked overnight; the iPhone was unlocked by 07:35. The iPad's last evidence is the full device suite at `25dfab0ca` and the two changed checks at `c96e375c9`. None of the three overnight commits touches device code: two change tests that run only on simulators, and the third changes the simulator's input session.

Agent benchmark, AXe only (11 November, morning; `benchmarks/artifacts/20261111T083456Z-b658d8abc130`):

The owner asked for the benchmark again, compared with the baseline and with the v1.8.0 release. Three repeats per app at `3e2ce1661` (v1.8.0-415; the code of `d0885cfa2`), model `claude-opus-4-7`, on the benchmark simulator about ten minutes after a fresh boot. Ranges over the repeats:

| Task | Accepted baseline (v1.8.0-185) | 8 November (v1.8.0-257) | 10 November (v1.8.0-405) | This run (v1.8.0-415) |
| --- | --- | --- | --- | --- |
| Weather | 16 to 19 calls, 206 to 227 s, 7.0k to 7.7k tokens | 19 to 20 calls, 123 to 134 s, 9.1k to 10.6k tokens | 20 calls, 116 to 124 s, 8.9k to 9.7k tokens | 17 to 19 calls, 109 to 123 s, 7.6k to 9.3k tokens |
| Contacts | 11 to 12 calls, 144 to 168 s, 8.4k to 9.0k tokens | 12 calls, 96 to 101 s, 10.5k to 10.9k tokens | 12 calls, 95 to 112 s, 9.7k to 10.0k tokens | 12 to 13 calls, 96 to 113 s, 9.8k to 10.5k tokens |
| Reminders | 20 to 25 calls, 195 to 312 s, 8.6k to 10.3k tokens | 17 to 18 calls, 94 to 100 s, 11.4k to 11.7k tokens | 26 to 28 calls, 230 to 293 s, 12.2k to 13.0k tokens | 23 to 39 calls, 232 to 397 s, 11.6k to 16.2k tokens |

- There is no v1.8.0 release figure and there cannot be one for this benchmark: v1.8.0 has no agent commands, which are what the benchmark measures. The oldest run in history is the accepted baseline, v1.8.0-185. A v1.8.0 comparison would be of single-command timing (`make bench-quick`), and that needs the release binary, which is not on this Mac; building the tag clones idb from GitHub.
- The harness still gives no ranked comparison with the baseline (`comparable: false`): the skill, the harness and the Weather app source have changed since it was accepted. The figures are side by side.
- Against the baseline: Weather and Contacts take about half to two thirds of the time for about the same number of calls, with about 10 to 20 percent more returned text. Against 10 November: Weather and Contacts are the same or slightly leaner. Reminders is no better than on 10 November and far from 8 November.
- Grades as recorded: Weather passed 1 and unverified 2; Contacts passed 2 and failed 1; Reminders unverified 2 and failed 1. Read against the transcripts:
  - Weather: the task checks pass in all three. The two unverified runs are the model checking its own build with `ls` and with `grep … | tail` before installing, which the grader flags for review. Nothing to do with AXe.
  - Contacts: the contact was saved correctly in all three. In the failed run the model checked the saved card with `tap --label 'MCP Contact Benchmark'`, which taps the name on the card, and the task forbids input after saving. In the other two it tapped by reference from the list it had just been shown; AXe refused because the card was already on screen, and the refusal's capture is what the grader reads. The reply to the Done tap shows the list behind the closing form, not the card that follows it.
  - [x] Reminders, the two unverified runs: the grader did not know AXe's plain screenshot receipt (`Screenshot saved to PATH`), so reading a screenshot counted as an unknown command. Fixed in the grader (`199606564`; 196 benchmark tests pass). Regraded, both runs pass every task check. The reports in history still say unverified.
  - Reminders, the failed run, and the calls and time of all three: the state recorded in Phase 12. The first completion lands, the batch stops because the screen changed, the second completion is sent alone and the model then cannot tell whether it took, so it reads, takes screenshots and taps again. On 10 November a reboot had cleared it until a benchmark run brought it back. This time the simulator was shut down and booted before the run and the first Reminders job, the second job of the run, already showed it. So either a reboot no longer clears it or something early in a benchmark run switches it on; I have not separated the two. That the 8 November binary fails the same way still stands.
- The benchmark simulator is shut down again, as it was before the run.

## Open items for the owner

- Timing has not been compared against the v1.8.0 release binary, which `AGENTS.md` requires; there is none on this Mac. The comparison in Phase 8 is against the pre-audit build.
- Interior slider values spawn a child process per read and take about 13 s; under load they fail. A redesign (reads in-process) is the fix.
- A simulator that has taken input for hours answers new input connections 3 to 4 s late (Xcode 27.2 beta 3). AXe now waits instead of failing, on plain connections since `cc39c8d49` and on owned ones since `d0885cfa2` (Phase 13), but the first command on each new connection is slow there until the simulator is rebooted. On the same simulator the ordinary-suite agent also saw typed text gain doubled spaces (`Hello,   x`), which cleared after a reboot; I could not reproduce it and have not investigated it.
- Ordinary `stream-video --format bgra` output cannot be decoded reliably: it ignores `--scale`, pads rows and has no frame boundaries. Unchanged from v1.8.0; no end-to-end case covers it.
- The selected input path stops input when its display or motion feed is more than 0.5 s old. That tripped twice on the Duo: the display feed (0.57 s) at a load average above 100, with input quarantined, and the motion feed (0.51 s) at a load average of about 40, released cleanly. The limit is deliberate; it needs a decision on whether busy machines get more margin.
- The early-boot accessibility wedge ("No translation object" or every read timing out until reboot) hit three Duo suites on 10 November. The matrix's boot gate does not catch it; a rerun on a fresh boot passes.
- The plain keyboard commands (`key`, `type`, `key-sequence`, `key-combo`) and a `touch --down` lifted by a later `touch --up` still measure the screen in the client. Selected input has different rules for both (a focus identifier, a contact token), so folding them in would change behaviour.
- On the Duo, about 1 plain command in 1,000 stopped mid-input ("Input stopped") with the new route: 4 in about 3,700, against 0 in 680 with the previous build. The samples are too small to show a difference, and both routes use the same session and the same freshness check, which is the open item two bullets above.

## Future improvements

Not needed for the release; noted so they are not lost.

- Send the car picture's strokes through `axe batch`. The picture player runs one `axe` command per stroke and per swatch tap, about 290 in all. `batch` accepts `draw` and `tap` steps on simulators and devices, so each run of "tap a swatch, draw several strokes" could go out as one batch, with the tool changes left as separate commands because they read the screen. Estimated saving: about 30 s of a 5 to 7 minute device run, not measured. The player would also have to work out which strokes landed when a batch stops on a failed step. The owner decided on 10 November to leave it out for now.

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

- **Physical devices unreachable through CoreDevice (closed at 09:35 on 10 November, when the owner made them reachable).** From about 22:45, `devicectl device info lockState` and `details` time out for both the iPhone and the iPad (20 to 30 seconds each, still failing at 00:09), while `devicectl list devices` shows both as connected and simulator calls answer in 0.5 s. Every AXe device command makes those calls, so no device check can run. A direct tunnel screenshot by the device agent showed both devices awake and unlocked. It started during the device agent's first `make e2e-devices` run, whose harness then had the bug of leaving capture processes running. Restarting the user-level `CoreDeviceService` is the likely fix; the permission system refused that action, so it was not done. To clear it: quit and reopen Xcode's Device Hub, or run `killall CoreDeviceService`, or unplug and replug the devices. Device verification of tonight's fixes waits on this.
- **Duo screens read as "still changing" when nothing moves (fixed and merged).** The refusal appeared once more on 10 November, in `PlaygroundDuoHardwareInterruptionTests` at a load average of about 40, and not when that suite was rerun alone. Cause and fix are described under Phase 8. Workaround on older builds: fold the Duo open and closed once.

## Commit log

All 152 commits made on `v2` since `0aa6ed21b` before the one that last updated this log, oldest first. None is pushed. This table is generated from `git log`.

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
| `25dfab0ca` | docs(release): Correct the run counts and record the Duo triage and timing |
| `2faeeedbc` | fix(gesture): Keep a default pinch radius inside the screen |
| `ba8619661` | test(device): Rerun single device checks with AXE_E2E_CHECKS |
| `ce809e81a` | docs(release): Record the device run, the pinch fix and the zoom reruns |
| `e9cb2485c` | docs(release): Close the device items in the progress log |
| `c1995e53f` | feat(playground): Add a PencilKit Sketch screen and a painting demo |
| `ea1115840` | test(e2e): Add PencilKit sketch checks for simulators and devices |
| `2a8dc0834` | docs(release): Record the drawing evidence, PencilKit work and comparison |
| `f97d11824` | docs(release): List the gesture gaps, painting bugs and remaining refactors |
| `cea002db1` | test(device): Find the Sketch canvas through elements a device lists |
| `a551b96ff` | feat(gesture): Add long press, double tap, drag hold and scroll-until |
| `9e325e7c5` | test(e2e): Cover the new gesture options on simulators and devices |
| `5974d8507` | test(device): Name the touch gesture check without commas |
| `abaa6cc23` | test(e2e): Open the Control Centre check from a screen with a known marker |
| `4c6501a46` | test(e2e): Paint a picture in the PencilKit checks |
| `47f7cec06` | fix(gesture): Retry a failed device screen read while scrolling until |
| `79ca2f220` | test(e2e): Drop repeated points from a picture's fill strokes |
| `986ecf927` | ref(selected): Give a request one payload enum instead of thirteen optionals |
| `76f538fd9` | test(device): Close a tool's options from a point read before they opened |
| `5f783420e` | docs(release): Record the gesture options, the picture checks and SEL-16 |
| `95335a390` | feat(gesture): Scroll inside an element, and stop at the end of the content |
| `6a5eaab54` | fix(gesture): Treat an empty point lookup as not visible while scrolling |
| `4b6b93964` | fix(gesture): Wait for the content to rest before scroll-until succeeds |
| `ad67ba737` | test(e2e): Paint a shaded 3D car in the PencilKit checks |
| `f657505b1` | docs(release): Record SEL-16's end-to-end run, the car picture and the slider limit |
| `0fd758ac1` | test(e2e): Tap the Sketch swatches by position and keep a tool in hand |
| `a1b74d1c3` | fix(gesture): Judge scroll-until only at rest, and let an element own its parts |
| `7ca36099c` | perf(device): Skip readiness reads after recent input and tap from one tree read |
| `614b25e5d` | fix(gesture): End each scroll-until step at rest so nothing is flicked past |
| `948517299` | test(e2e): Start the Sketch screen on the pen and scroll the picker under its tools |
| `04762105a` | test(e2e): Tap a picker tool for its options only once the strip is at rest |
| `588a1e9d0` | docs(release): Record the device timings, the Device MCP comparison and the scroll-until fix |
| `eaf1d3a51` | fix(device): Read large accessibility trees and scroll short strips on a device |
| `c96e375c9` | test(playground): Keep the Sketch canvas's strokes out of the accessibility tree |
| `16f331be5` | docs(release): Record the device rerun, the tree read limit and the passing checks |
| `81601c0fc` | docs(release): Close the items in the log that later work finished |
| `a1ee6c835` | docs(release): Note batching the car picture's strokes as a future improvement |
| `bad29dfa8` | build: Add make release-check, the quick release checks in one run |
| `37bf37ae3` | docs(changelog): Bring the unreleased section up to date |
| `0e9cff650` | docs(release): Record the release check and the CHANGELOG review |
| `8c1e45ac6` | docs(release): Record the SEL-17 timing of plain against selected input |
| `d4b9952fd` | perf(input): Let a running broker bind the screen for plain touch commands |
| `4ac61b349` | test(e2e): Confirm the first colour after a tool change in the picture player |
| `829069eeb` | docs(release): Record the plain-input change, its timings and its isolated runs |
| `96f6ebe53` | fix(bench): Read the current screen from a compact refusal reply |
| `d0f87e0e0` | docs(release): Record the agent benchmark against the last run and the baseline |
| `0a9b7f215` | docs(release): Record what the Reminders benchmark failure is and what is still unknown |
| `1c5c3eeba` | fix(agent): Send the typing phase again while the keyboard catches up with a focus tap |
| `95415b39e` | docs(release): Record the type --focus regression, its fix and its evidence |
| `d0a22a5f3` | test(e2e): Press Siri again when the simulator's Siri closes itself as it opens |
| `0fb3bb7ca` | test(e2e): Wait for the field to lose focus before the Duo selector comparison |
| `d0885cfa2` | fix(hid): Wait for the guest to answer a new owned connection as long as a plain one |
| `f7278726a` | docs(release): Record the three full end-to-end runs and the fixes they led to |
| `3e2ce1661` | docs(release): Record the owner's decision to skip the iPad device rerun |
| `199606564` | fix(bench): Accept the file an AXe screenshot was asked to write |
