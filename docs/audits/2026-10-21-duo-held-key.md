# Duo held-key interruption proof, 21 October 2026

Two public held-Space commands have bounded fold and device-rotation evidence. Both returned the expected stale-context interruption after one normal key-down and confirmed owned cleanup. Key repeat stopped, then a fresh selected Button tap passed. No product change was needed.

This is generic public cleanup evidence. The response does not expose an independent key-up primitive, key-up timestamp or OS pressed-key inventory. Those claims remain UNVERIFIED.

## Candidate and scope

- Same Debug arm64 CLI `5f4e71958447de644fea1e2a2844518d7b177598e9050393cd56374e039e17c4`, wire 21, and 14 source/runtime pins from [controls-candidate.json](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-candidate.json).
- Dedicated Duo `F812E915-55DA-46C0-B2DB-B8C6E1EF1B66`, profile 405 / iOS 27.2 / fixture 6, boot `76152:1792578001:862020`, PID `76615`.
- Public action: `key 44 --duration 6 --expected-pid 76615 --focus-id feature.text`, with fresh explicit selected-screen ID/UUID. No automatic focus action or replay.
- The real text field was already focused. The driver read its current AX tree before input; the product then validated the exact field and PID before key-down.

## Native results

| Check | Result |
| --- | --- |
| Opening during held Space | Outer 1 / rotation 0 / hinge 114 to inner 3 / rotation 90 / hinge 180. The first real Space callback was saved before the external hinge write. Public key returned `failedNoReplay`, `staleContext`, one normal event, one validated key-down, `releaseEnqueuedAndDrained`, and no quarantine. The first post-cleanup read contained nine Spaces from key repeat. Later text and callback counts stayed at nine. A separate first fresh Button tail changed 11 to 12, with the same PID, less than 0.5-point error and a complete released contact. |
| Device rotation during held Space | Inner3 / rotation 90 to180 / hinge 180. A real Space callback preceded the external rotation. The public key returned the same expected interruption and generic cleanup evidence. At the first post-cleanup read, nine repeat callbacks had changed text length 9 to 18. Four timed post-cleanup state reads stayed unchanged. A fresh Button tap changed 12 to 13 at the new frame, with less than 0.5-point error and full contact release. The wrapper passed. |

The fold wrapper remains `FAILED_NO_REPLAY`. Its assertion wrongly required exactly one Space after a held key. It stopped after the valid interruption receipt, before the new Button tap. Holding Space can repeat. The later read-only stability checks and the first Button tail are separate evidence; neither the key nor the fold was repeated. [Original fold record](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-key-fold-focused/result.json), [ordered review](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-key-fold-review.json), [fresh tail](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-key-fold-refind/result.json).

The rotation criteria were declared before its input. They allow repeat before cleanup and require stable text and callback counts after the cleanup receipt, through the fresh Button action. [Rotation result](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-key-rotate/result.json).

One earlier preparation check also remains failed. Its ordinary field tap landed and released correctly, but a 250-millisecond state sample was too early for the focus callback. A separate later read confirmed focus, without another tap. No key or hinge write ran in that failed preparation. The final driver requires an already focused field and has no implicit focus retry. [Preparation](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-key-fold/result.json).

## Order and timing limits

The fold Space snapshot was saved at 10:35:44.333 UTC; the external-change marker was saved at 10:35:44.970 UTC. The key client exited and was reaped before the 10:35:46.008 UTC post-cleanup state. Later reads at 10:36:48 and10:37:38.369/39.120 UTC retained nine Spaces and nine callbacks. Native hinge write observation ran from uptime 165657.2015 to 165658.2164. These host file times and native uptime values are separate clocks; no subtraction across them is used.

The key process record confirms exit 1 without signals. Both external operators exited 0. These are expected interruptions, not successful completion of the original six-second hold. Public cleanup confirms release and drain on the owned session. It does not establish when the OS processed a particular key-up or an atomic recipient guarantee.

## Tools and saved verification

- [verify-duo-held-key.py](../../scripts/verify-duo-held-key.py) runs one public key/change/refind sequence and saves command, state and process receipts.
- [DuoExternalStateChange.swift](../../scripts/fixtures/DuoExternalStateChange.swift) uses the existing proved library control methods with an explicit owned device and helper path. It sends no touch or key input. Its deliberate overlap represents an external fold or turn while AXe owns the key. It adds no product route around the input lock.
- [verify-duo-held-key-saved.py](../../scripts/verify-duo-held-key-saved.py) reads saved evidence without sending input.

The state operator built with the recorded Xcode compiler in Swift 5 language mode, two jobs, the current framework set and no product build. Exact command and resource result: [controls-compile-external](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-compile-external/started.json).

`/usr/bin/python3 -B scripts/verify-duo-held-key-saved.py --root /Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021` passed on 21 October 2026. It verified the 14 current pins, real pre-change Space effects, expected interruption and cleanup receipts, stopped repeat, two fresh Button effects and final shutdown. It retains the failed original fold wrapper. [Saved verification](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/controls-held-key-saved-verification.json).

## Resources and handoff

All native operations ran under the revised common public-libproc guard. The held-key rotation sampled peaks of 7.334 GiB for all simulator processes and 6.370 GiB for the app process group. No resource stop or monitor error occurred in this phase. The dedicated Duo was shut down with exit 0. The final sample was 0.524 GiB / 3.7 percent simulator CPU and 6.406 GiB app memory. Other worker guests were not selected or changed.

No product source, public option, wire schema or framework changed. Held hardware buttons, retained library pairs, other keys/poses, uncertain cleanup, power and release packaging remain separate unverified work. Security scanning remains UNVERIFIED per Cam. No push ran.
