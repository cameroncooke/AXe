# Duo isolated fixes: live proof

17 October 2026. The isolated V2 library passed **62 of 62 live cases**: 56 main cases across seven device states, plus six screen-selection controls and rechecks. The main AXe library has not been changed. This proves the listed input paths in stable states; it does not establish full Duo support.

The implementation, portable patches, build records and exact harness sources are in the [source package](evidence/2026-10-17-duo-isolated/README.md). Raw commands, requests, app state, display records and screenshots are in the [live evidence](evidence/2026-10-17-duo-isolated-live/). The [independent validator](evidence/2026-10-17-duo-isolated-live/final-evidence-validation.json) checked all 99 recorded cases, including earlier failures, with no record or provenance mismatch.

## Implemented in isolation

| Change | Implementation | Proof and limit |
|---|---|---|
| Runtime screen discovery | Typed CoreSimDeviceIO screen records with ID, UUID, native size, scale and raw state | Joined host and guest IDs, UUIDs and geometry before every case. No automatic active-screen rule. |
| Explicit screen selection | Unique runtime screen lookup | IDs 1 and 3 resolved. Missing IDs 99 and 4294967295 were rejected. The raw HID context still accepts arbitrary targets. |
| HID target and coordinates | One immutable display context for single and two-contact events | Correct visible effects on the selected panel through four rotations and fold transitions. Context must be refreshed by the caller. |
| Selected-display AX point lookup | Explicit AX display ID and native, unrotated logical point | Found the Tap counter text child on the selected panel. The other panel returned an unrelated AX group. This is not a complete element-query API. |
| Short-lived input delivery | DTUHID post-send keepalive increased from 80 to 380 ms | Default taps and two-finger taps worked in the final matrix. This is a measured wait, not a guest acknowledgement or a timing guarantee. |

All tested input used the actual isolated FBSimulatorHID/AX implementation. The prior direct wire probe was used only to read AX data. FlowDeck supplied a visible positive tap before each case and set orientation. The hinge helper set the pose. Neither tool sent the input being graded.

## Live matrix

Each main row contains eight cases: default tap, separate down/up tap, list swipe, drag, hold, two-finger tap, pinch and selected-display AX point lookup.

| V2 device state | Measured target / guest rotation | Result |
|---|---|---|
| Duo open | Inner 3 / 0 degrees | 8/8 |
| Duo open | Inner 3 / 90 degrees | 8/8 |
| Duo open | Inner 3 / 180 degrees | 8/8 |
| Duo open | Inner 3 / 270 degrees | 8/8 |
| Duo refolded | Outer 1 / 0 degrees | 8/8 |
| Duo partially folded | Inner 3 / 90 degrees | 8/8 |
| Ordinary iPhone 18 Pro | Screen 1 / 0 degrees | 8/8 |
| Open-inner wrong-screen controls | HID 1 and AX 1 while the tested app was on inner 3 | 2/2 |
| Closed-outer controls and rechecks | Positive HID/AX 1; wrong HID/AX 3 | 4/4 |

The wrong HID target caused no contact in the intended app. It was not rejected by the API. The wrong AX display did not return the intended text. These results distinguish screen routing from command success. They do not prove that input has no effect on an unobserved panel.

Before each action, the harness matched fresh host and guest display identity, geometry and rotation, reset the visible fixture, and required one complete FlowDeck positive tap. It then obtained fresh AX target geometry, sent the candidate action, and read app state at 0.6 and 5 seconds after command completion. A successful send alone could not pass a gesture. Expected app effects and complete contact release were required.

This sequence proves fresh lookup and input after a transition. It does **not** prove that a saved element or coordinate remains safe across rotation or folding. The next slice must reject such stale actions.

## Failures retained and fix isolated

| Candidate/run | Result | Finding |
|---|---|---|
| Baseline, closed outer | 7/8 | Default tap produced no contact. |
| Baseline, open inner | 0/8 | No expected pointer effects; default AX lookup returned an unrelated group. |
| V1, closed outer | 7/9 | Default tap and an added 50 ms tap failed. |
| V1, open inner | 6/8 | Routing worked for longer actions; default tap and two-finger tap failed. |
| V1, timing experiment | 3/4 | 100/200 ms holds worked; a 200 ms pre-send wait failed; a default tap with 300 ms extra post-send keepalive worked. |
| V2, complete final matrix | 62/62 | Only executable change from V1 was the drain from 80 to 380 ms. |

Across all candidates there are 99 cases: 85 passes and 14 absent expected effects. Those 14 failures remain in the archive. They are baseline/V1 evidence, not final-candidate failures. The validator checked the recorded effects independently of the runner's grading function. Across the recorded cases, all 89 received contacts ended; none remained active at final readback. No cancellation case was run.

Keeping the connection open after enqueue is consistent with deferred guest consumption before disconnect. The data does not identify a fixed daemon deadline. Adding a hold to every tap would have hidden the lifetime issue and changed gesture semantics; V2 preserves the event factories and their requested spacing.

## Coordinate and timing evidence

The [coordinate review](evidence/2026-10-17-duo-isolated-live/independent-coordinate-review.md) compares requested points with new guest touch records. It excludes the preceding FlowDeck contacts. The largest observed endpoint error was approximately **0.167 logical points**. Two-contact pairs were matched without assuming finger order, and their centers and radii were checked separately.

The fixture keeps 16 trace entries. Six drag starts fell outside that window, including V2 inner90, refolded outer and ordinary iPhone runs. Their start coordinates remain unverified. The saved release endpoints and app effects were observed. This is not proof that every interpolated move arrived, nor a full-screen coordinate sweep.

Guest duration is still a defect area. Some successful taps with explicit host holds had almost zero guest contact duration. A requested 0.8-second hold had a shorter observed guest span. V2's separate down/up calls each include a drain, which changes the actual interval between them. Exact hold duration, swipe speed and pinch scale fidelity are not accepted by this report.

The fixture permits overlapping recognizers. Some holds also incremented tap counters, and some pinches incremented other two-finger counters. The pass contract establishes the requested effect and released contacts; it does not establish exclusive recognition or full gesture semantics. The fixture writes state on events, so these runs are not a performance benchmark.

## New state findings

For this boot, the outer panel was screen 1, UUID `8148B2A9-85DB-41AA-9568-BC522682E9FF`, 1398 by 2034 pixels at scale 3. The inner panel was screen 3, UUID `06899BE7-BEB7-418E-9343-569E91064531`, 2007 by 2853 pixels at scale 3. These are measured identities, not library constants.

Host raw UI orientation was the same on both panels while guest rotation differed. Both panels also reported raw power state 1 when only one was used. Neither field can select the active panel or supply its coordinate transform. The raw inner backlight value of -101 remains uninterpreted.

Folding can leave a panel's ID, UUID, size, scale and guest rotation unchanged. Geometry checks alone cannot reject a stale fold context. A verified pose-change signal or pose readback must form part of the action revision. In the partial-fold run, mechanical angle was 90 degrees and sensed angle was about 85.385 degrees. Requested, mechanical and sensed values must remain separate.

## Remaining work before rollout

| Area | Current status | Next proof |
|---|---|---|
| Discovery, mapping and coordinate transforms | Bounded isolated proof complete | Add validated target ownership, discovery timeout and failure handling. |
| Delivery lifetime | Temporary drain fix proved for this matrix | Separate event timing from connection lifetime; test persistent sessions and close. |
| Stale lookup, cancellation and held contacts | Not implemented | Reject old context revisions; preflight full gestures; release contacts after failure/cancellation. |
| Keyboard and text editing | Not covered by this candidate | Verify editing, completion and keyboard-related coordinate changes. |
| Hardware buttons and power writes | Not covered | Verify each operation and guest state change; do not infer support from raw power reads. |
| Hinge capability | Setup helper used successfully | Add a library API with explicit mechanical/sensed state and transition completion rules. |
| Capture | Screenshots retained as evidence only | Verify target selection and capture correctness as a separate capability. |
| Other named gestures | Not covered | Double tap, two-finger hold, rotation gesture, zoom-out and each remaining factory need their own semantic checks. |
| AXe command, batch, broker and provider paths | Unchanged | Integrate only after session safety passes, then exercise every public entry path. |

Source review also found that a valid down followed by an invalid later coordinate can fail before release. Raw target membership, inherited numeric conversions and cancellation during drain require explicit handling. These are review findings; this run did not reproduce each one live.

The [next-slice design](evidence/2026-10-17-duo-isolated/NEXT-SLICE-DESIGN.md) defines one input-session owner and 11 focused proof groups. It covers invalid later points/targets, cancellation, stale rotation/fold lookups, transitions while held, split timing, persistent connections, concurrent calls and reboot. It is a design, not delivered functionality.

FlowDeck was a live reference in this slice. RocketSim's implementation evidence remains in the [earlier mechanism audit](2026-10-16-duo-control-mechanisms.md); it was not rerun here. These results do not establish performance parity with either product. The broader feature gaps remain in the [full feature audit](2026-10-17-duo-full-feature-verification.md).

## Candidate and reproduction record

- AXe branch `main`, HEAD `7163081400b59f1df40bff44f3a94dded38eea9a`; existing changes preserved.
- IDB base `604c51013438f0c3603b720a05a44b7c5b8f286d`; original checkout remains clean.
- Changes built under `/private/tmp/axe-duo-fixes-20261017/idb`; no commit or push.
- Build compiler/SDK: Xcode 27.0 RC. Live simulator: Xcode 27.2 beta 3, build 27B5038j; iOS 27.2, build 24B91011.
- FlowDeck 1.33.0, commit fac60d; normal UIKit fixture revision 5.

| Framework | SHA-256 |
|---|---|
| Baseline | `3c9d1598d847b11d5152dcf53212fc14b1e25cda13292fa3fbf6abff04265118` |
| V1 | `e022362532d311d003cbe7fd205959394d15dc3363f3020a3f85193b2b743c05` |
| V2 | `8c73da1e5a402ee26fba6a0b1360b709951ab91c1bb104ceb2fc609e5b45087c` |

The final sender hash is `76db562dfd8cdfa2b533b0bc957ce7605b8066787b4b1389153d3bbfc75f43b1`. Source and compiler arguments are in the build manifests. Input receipts record loaded framework paths; AX-only receipts lack that image list and rely on linked-build provenance. All 75 baseline and 76 candidate Swift build inputs resolved into the intended isolated trees. Earlier builds with incorrect source paths were excluded.

Exact final driver commands were:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer python3 /private/tmp/axe-duo-fixes-20261017/harness/run-rotation-matrix.py
DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer python3 /private/tmp/axe-duo-fixes-20261017/harness/run-final-controls.py
python3 /private/tmp/axe-duo-fixes-20261017/harness/review-coordinates.py
python3 /private/tmp/axe-duo-fixes-20261017/harness/validate-final-evidence.py
```

All case-specific commands and options are retained in each run contract and command record. The source package explains path adaptation for reproduction. Portable patches were applied to the exact clean base and reproduced all retained candidate source files. Sixty-eight local transform checks passed. The separate live display selector passed four checks. Neither count is included in the 62-case matrix.

The Duo was restored to closed pose before shutdown. Both dedicated test devices were then verified as Shutdown. They remain registered for follow-up. See [cleanup readback](evidence/2026-10-17-duo-isolated-live/cleanup/final-device-states.json).
