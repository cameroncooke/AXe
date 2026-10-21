# Duo hardware and hinge verification, 21 October 2026

## Candidate and device

This work uses the integrated Debug arm64 candidate from main at `f8bb51e9d64e87914fe020d6afff24c5c2ed2ace`. It does not change the product source or build. The isolated branch is `codex/duo-controls`.

- CLI SHA256: `5f4e71958447de644fea1e2a2844518d7b177598e9050393cd56374e039e17c4`.
- Wire: 21. Source, helper and framework pins are in [controls-candidate.json](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-candidate.json).
- Dedicated device: `F812E915-55DA-46C0-B2DB-B8C6E1EF1B66`, iPhone Duo / iOS 27.2 / profile 405. The other worker's guest was not selected or changed.
- First boot: `71527:1792577354:900415`; fixture version 6, PID `72229`.
- Second boot: `76152:1792578001:862020`; same fixture version 6, PID `76615`.

The script [verify-duo-controls.py](../../scripts/verify-duo-controls.py) saves exact arguments, command results, state and receipts. Each invocation runs one check. It makes no write retry and adds no hidden product route. Run it under the shared resource guard. The final command must supply one explicit owned device ID.

## Results

| Check | Result | Evidence and limits |
| --- | --- | --- |
| First setup | Partial; AX read rejected before input | Launch and one hinge 180 write with coherent inner3 readiness passed. The first cold AX preparation failed, with zero input and cleanup notNeeded. [Record](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-prepare/result.json). |
| Selected standalone side-button, duration 0.2 | Passed bounded transport and visible effect | Inner3/AX3/rotation90/hinge 180: two normal button events, both released, transport drained, completed phase, no interruption, cleanup notNeeded. App counters and full touch trace stayed unchanged. The worker viewed the selected PNG: date and clock wallpaper, no fixture controls. [Result](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-side/result.json), [image review](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-side/visual.json). |
| Separate normal app return | Launch passed; immediate AX read rejected before input | Normal simctl launch returned the same PID 72229. AX preparation then found stale context and sent zero input. The tap did not run. This remains a stopped check, not a failed tap or a completed return/tap proof. [Record](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-side-return/result.json). |
| First-boot separate fresh lookup | Did not start | The resource guard's ps read timed out before child launch. No lookup or input ran. The dedicated guest was shut down after that monitor error. [Guard record](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-side-refind-guard/result.json). |
| Second-boot preparation and first fresh tap | Setup partial; separate tap passed | Cold automation bootstrap timed out before input. One separate explicit existing-bridge lookup passed and the first Button tap changed 0 to 1 with the exact PID, less than 0.5-point error and full release. [Failed setup](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-prepare-r2/result.json), [fresh tap](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-refind-r2/result.json). This later boot does not complete the first-boot return check. |
| Selected batch side-button | Passed bounded transport, visible effect and stop | Inner3/AX3/rotation90/hinge 180: step 1 completed two released and drained events. Step2 had invalid duration 0 and rejected before send, with no request ID; step 3 tap was absent. Fixture counters and touch trace stayed unchanged. The worker viewed date and clock wallpaper. [Result](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-batch-side/result.json), [image review](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-batch-side/visual.json). |
| Separate normal return after batch and fresh tap | Passed | Normal simctl launch returned the same PID 76615. A separate fresh existing-bridge lookup and physical Button tap changed 1 to 2 with less than 0.5-point error, a complete contact and unchanged other controls. [Launch](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-batch-normal-return/result.json), [fresh tap](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-batch-refind/result.json). |
| Hinge boundary observations | Passed bounded current-session checks | Eighteen one-write angle checks passed. Nine actual panel switches each rejected the old panel with zero events and then passed a fresh named Button tap with full release. Adjacent114 to 115 and115 to 114 changes proved input on both sides of the measured boundary. See the table below. |
| Held key/button and retained pair interruption | Pending | The public key command accepts a complete down/delay/up event. A native held-key check has not run here. Retained pairs need separate library proof. |

Side-button acts on the whole device. Explicit screen selection checks the current context; it does not make the button act on one panel only. The typed release receipt is transport evidence, not an independent OS inventory of pressed hardware buttons.

## Measured hinge boundary

Each row has two fresh matching mechanical samples, two matching independent active-panel reads and unchanged app counters and touch trace before any new input. At an actual panel switch, the old selected-panel tap rejected with zero input. The script then read the current AX tree and tapped `feature.tap` with the current PID. The actual contact point was within 0.5 logical point of the verified target; both events completed and no touch remained.

| Ordered check | Degrees | Active panel | New Button count |
| --- | ---: | --- | ---: |
| close0 | 0 | outer1 | 3 |
| open1 | 1 | outer1 | No input |
| open5 | 5 | outer1 | No input |
| open10 | 10 | outer1 | No input |
| open20 | 20 | outer1 | No input |
| open45 | 45 | outer1 | No input |
| open90 | 90 | outer1 | No input |
| open135 | 135 | inner3 | 4 |
| close90 | 90 | outer1 | 5 |
| open105 | 105 | outer1 | No input |
| open120 | 120 | inner3 | 6 |
| close110 | 110 | outer1 | 7 |
| open115 | 115 | inner3 | 8 |
| close112 | 112 | outer1 | 9 |
| open113 | 113 | outer1 | No input |
| open114 | 114 | outer1 | No input |
| edge-open115 | 115 | inner3 | 10 |
| edge-close114 | 114 | outer1 | 11 |

Each row is in `build_products/verification/parallel-duo-20261021/controls-hinge-<ordered-check>/result.json`. The last adjacent checks are [114 to115](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-hinge-edge-open115/result.json) and [115 to114](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-hinge-edge-close114/result.json).

This guest switched between the measured 114 and 115 degrees in both directions. This is an observation, not a public OS threshold contract. Earlier inner-screen input at 90 degrees belongs to its recorded session and does not establish this new guest's panel. There is no product threshold change or inferred screen selection. Continue to read the active panel after every hinge change.

## Lock, wake and power

The wallpaper image proves a visible system-screen change. It does not prove security lock, screen power off, an idempotent lock command, wake, shutdown or restart. The selected CLI supports Home and side-button. It has no idempotent selected power or wake command. Legacy `button lock` remains a separate route with prior no-effect evidence.

No raw panel power write ran. The prior power experiment had a SpringBoard assertion and black capture after restoration; it is not accepted power support. Those old records remain unchanged. This work does not replace an absent control with uncertain repeat presses.

## Resource control

All native commands used the shared parallel guard: app 8 GiB, combined simulator 10 GiB, owned command 4 GiB; sustained CPU limits also apply. A standalone read-only resource sample confirmed that the first startup peak fell before side-button input. No memory threshold was raised.

The first combined simulator peak was 9.390 GiB during startup preparation, below the 10 GiB limit. Side-button ran after the other original guest stopped: its sampled simulator peak was 4.613 GiB and app peak 5.511 GiB. A later ps timeout was a monitor error, not a memory-limit stop. The next check never started; this worker shut down only its own guest.

The coordinator then replaced ps/top sampling with its separately validated public libproc probe. All second-boot checks used that revised guard at the same path, with unchanged memory limits. The second-boot peak through the hinge checks was 8.931 GiB combined simulator memory; no resource stop occurred. The final hinge sample was 7.012 GiB and 40.3 percent simulator CPU, app 5.629 GiB. These are combined process groups, not a per-device memory claim.

## Remaining scope

Selected standalone and batch side-button now have bounded native evidence. Boundary discovery, old-panel rejection and fresh input are proved in the stated session. Keep failed setup and no-input results. Do not repeat accepted cases without a related change. Next are held public-key interruptions during a fold and a device rotation. Their current receipt exposes generic cleanup, not the exact key-up primitive or an OS pressed-key inventory. Wider poses, cancellation, uncertain cleanup, ordinary-device controls and release packaging remain unverified. Security scanning remains UNVERIFIED per Cam.

## Saved-data verification

`/usr/bin/python3 -B scripts/verify-duo-controls-saved.py --root /Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021` passed on 21 October 2026. It verified all 14 current candidate pins, 22 accepted cases, 18 hinge readbacks, nine old-panel rejections, 11 fresh Button effects and 135 reaped client commands. This command reads saved evidence and sends no input. [Result](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-saved-verification.json).
