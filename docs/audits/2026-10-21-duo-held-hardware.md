# Duo held hardware buttons, 21 October 2026

Home and side-button holds stopped on the tested fold and inner-screen rotation changes. AXe sent the exact owned button-up, confirmed the guest barrier and drain, then accepted a fresh named Button tap. Four real-library checks and two public CLI checks passed. No product change was needed.

The extra outer-screen Home rotation did not change the selected UI context. It remains a failed setup attempt with cause UNPROVEN. It is not accepted as an interruption check.

## Candidate and scope

- Base commit: f6e262d14cd944c91fabc615431474b546d97a0e.
- Debug arm64 CLI SHA256: 5f4e71958447de644fea1e2a2844518d7b177598e9050393cd56374e039e17c4, wire 21. FBSimulatorControl SHA256: 8a614ab3116b3d0b88e21086d8a16d0f39aa06f672dd92123b7fd00e7526b779.
- Dedicated Duo: F812E915-55DA-46C0-B2DB-B8C6E1EF1B66, profile 405 / iOS 27.2 / fixture 6. Boot 7798:1792584854:414322. Actual fixture PID 9564 throughout.
- Inner panel 3 / D5163A29-9A9F-4976-AB40-8873CF734232; outer panel 1 / FF335747-81FC-4750-952C-BCB950CCB2B4.
- Each hold used DOWN, delay 6, UP. Each external operator sent one native hinge or rotation write. No automatic input replay ran.
- Hardware buttons act on the device. The selected screen binds admission and freshness; this does not route Home or side-button events to a panel.

The [20-pin manifest](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-candidate.json) records the current runtime, sources and tools. It was saved after these checks. The Swift probe and state operator binary were unchanged. The Python driver gained its public branch after the four library cases, then a description and case-label correction after the public cases. There was no source digest at each launch. Raw command, process and native receipts are retained.

## Accepted checks

| Caller and action | Actual context change | Owned release and fresh input |
| --- | --- | --- |
| Library Home / fold | Inner 3, UI 90, hinge 180 to outer 1, UI 0, hinge 0 | Exact Home UP; Button counter 0 to 1. |
| Library Home / rotation | Fully open inner 3, UI 180 to 270 | Exact Home UP; Button counter 1 to 2. |
| Library side-button / fold | Inner 3, UI 270, hinge 180 to outer 1, UI 270, hinge 0 | Exact side-button UP; Button counter 2 to 3. |
| Library side-button / rotation | Fully open inner 3, UI 90 to 180 | Exact side-button UP; Button counter 3 to 4. |
| Public CLI Home / fold | Inner 3, UI 180, hinge 180 to outer 1, UI 0, hinge 0 | Exact Home UP; Button counter 4 to 5. |
| Public CLI side-button / rotation | Fully open inner 3, UI 180 to 270 | Exact side-button UP; Button counter 5 to 6. |

Each accepted hold sent one normal DOWN and stopped in its delay after a stale-context interruption. The normal UP was not sent. One cleanup UP matched the requested button: Button home up or Button side_button up. Its native receipt confirms IndigoButtonEvent enqueue and guest barrier, followed by a completed drain. Release identity matched the original device, boot, panel UUID, dimensions and scale before and after cleanup. Public CLI receipts also confirm planned 2 / sent 1, bound context and no quarantine.

After each cleanup, a separate normal app launch returned the same PID 9564. A new current-screen catalogue and AX query found feature.tap. The public physical tap used that current frame and PID, increased only its Button counter, and produced matching BEGIN/END contact events within 0.5 point of the requested point. Each tail ended with zero held contacts and no dropped trace. These are six real effects, not only successful command exits.

Raw accepted records are under [hardware-home-fold](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-home-fold/result.json), [hardware-home-rotate-inner](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-home-rotate-inner/result.json), [hardware-side-fold](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-side-fold/result.json), [hardware-side-rotate-inner](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-side-rotate-inner/result.json), [hardware-public-home-fold](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-public-home-fold/result.json) and [hardware-public-side-rotate-inner](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-public-side-rotate-inner/result.json). Each has a separate -return and -refind folder.

## Library and CLI evidence limits

[DuoHeldHardwareProbe.swift](../../scripts/fixtures/DuoHeldHardwareProbe.swift) opens the real live freshness provider and FBSimulatorHIDSession. It uses the existing public session.status() to record executing with one normal event after the native DOWN send and its guest barrier. The full normal gesture has not drained. That saved marker precedes the external write in all four library cases. There are no mocks or production status hooks.

| Library case | DOWN status marker | External write start | Cleanup UP start |
| --- | ---: | ---: | ---: |
| Home/fold | 171910.361995 | 171910.710557 | 171911.205695 |
| Home/inner rotation | 172318.535806 | 172318.883003 | 172319.640295 |
| Side/fold | 172389.319859 | 172389.672275 | 172390.183573 |
| Side/inner rotation | 172460.505712 | 172460.823057 | 172461.586473 |

Times are native host uptime seconds on one clock. The marker proves session/transport ordering. It is not an OS pressed-button inventory.

The public CLI event factory SelectedButtonPolicy.event is private to the CLI. The isolated probe does not call that factory, broker admission or host lease. Source review confirms the same ordered button/delay/button enum values. The two separate public cases run the actual button command, its selected-screen broker path and that factory. Public timing uses one declared two-second schedule delay, then checks the final typed receipt. It has no independent live DOWN marker; down-before-change ordering is proved independently only in the library cases.

## Preserved outer-screen attempt

[hardware-home-rotate](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-home-rotate/result.json) remains FAILED_NO_REPLAY. The outer screen began at UI 0 and hinge 0. The external rotation sent one write, then exited 2 because the requested selected UI 90 was not observed twice. Its delivery is uncertain. The Home session completed its original six-second hold normally: DOWN and UP, normal count 2, phase completed, all inputs released, normal drain complete, cleanup notNeeded. Both processes were reaped without signals.

Separate read-only observations found the Home/system UI in foreground, physical portrait, outer UI 0 active, inner inactive, and no persisted broker quarantine record. No safety record was deleted. The direct external operator does not itself write a broker quarantine record, so that absence does not prove that the uncertain write had no effect. The cause is UNPROVEN. This record is classified NOT_INTERRUPTED_NO_CONTEXT_CHANGE, with no AXe interruption failure inferred.

The fully open inner Home rotation was a new stated pose after the normal Home UP and fresh fixture setup. It passed with an actual selected UI change. It does not change the failed outer record or establish a platform design rule. [Read-only findings](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-home-rotate-readonly-findings.json).

## Reuse and saved verification

- [verify-duo-held-hardware.py](../../scripts/verify-duo-held-hardware.py): one owned library or public CLI hold and one external change, no replay. App return and fresh input are separate explicit actions.
- [DuoExternalStateChange.swift](../../scripts/fixtures/DuoExternalStateChange.swift): unchanged explicit-device native state operator from the prior accepted phase. It sends no touch or key input.
- [verify-duo-controls.py](../../scripts/verify-duo-controls.py): unchanged selected-screen AX/PID/Button effect checks for the six tails.
- [verify-duo-held-hardware-saved.py](../../scripts/verify-duo-held-hardware-saved.py): reads saved pins, raw receipts, ordered markers, exact release/barrier/drain/identity fields, six physical effects and the preserved failure. It sends no input.

The probe compiled in Swift 5 language mode with two jobs and the current frameworks. [Exact compile command](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-compile-probe/started.json). No product build ran.

On 21 October 2026, /usr/bin/python3 -B scripts/verify-duo-held-hardware-saved.py --root /Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021 passed. Both new Python files passed AST parsing. [Saved result](/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/hardware-saved-verification.json).

## Resources and remaining scope

All native actions used the common public-libproc guard. The 32 own phase guards sampled peaks of 7.549 GiB app memory, 8.045 GiB combined simulator memory and 0.044 GiB command memory. No guard stop, monitor error or process signal occurred. The limits stayed 8/10/4 GiB and sustained 1200/400 percent CPU for 20 seconds. The coordinator also monitored both guests. Native cases on this guest ran one at a time.

The owned Duo shut down with exit 0. The final sample was app 7.331 GiB and combined simulator 0.593 GiB. No other guest was selected or changed.

This proves the six stated interruption paths on this candidate. It does not prove OS pressed-button state, secure lock, idempotent wake, power, other buttons or poses, retained library pairs, or atomic recipient delivery. No lock or power claim is based on wallpaper. No raw power cycle ran. No product source, public option, wire schema or framework changed. Security scanning remains UNVERIFIED per Cam. No push ran.
