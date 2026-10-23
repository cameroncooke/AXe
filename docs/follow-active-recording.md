# Follow-active-display recording

Candidate `f4fd3030df880e9af7611c3355427a541bbc0a1e` and staged CLI `d345e62204b65ddc0777dba2cd2afc7c0e5955b48b7f5e252e90613516bc40df` passed the scoped build, native recording, decode and visual checks on 23 October 2026.

Use `record-video --follow-active-display` to keep one movie across measured active-panel, orientation and hinge changes on one boot. The first frame fixes the canvas; later upright frames fit with black bars. Existing paired-screen recording still stops on context changes. Raw recording and selected streams retain their routes.

The command retries only typed lock-busy or transition reads after cleanup. No lease is held during retry sleep. Capture uses the existing native feed, child ownership and same-frame context checks; it does not accept a frame across a detected change. Boot changes and uncertain cleanup remain fatal. The recording follows the display, not an app PID. It does not promise smooth animation or all intermediate poses. See the [recording reference](../Skills/CLI/axe/references/recording-reference.md) for exact bounds.

## Verified behavior

Both movies used the normal v6 sample app on owned Duo E, requested 1 FPS, quality 60 and scale 0.25.

| Check | Actual result |
| --- | --- |
| Opening and rotation | Outer rotation 0 → inner rotation 90, then inner 90 → 180. One FlowDeck open and one external native right turn. Eight frames at 348×508; actual 0.3935 FPS. |
| Closing | One explicit AXe setup-open 180, then inner rotation 90 → outer rotation 0 with one FlowDeck close. Six frames at 712×500; actual 0.4091 FPS. |
| Decoded movies | All 14 frames decoded, with strictly increasing media timestamps and one fixed canvas per movie. Root reviewed every PNG: upright content, proportional top/bottom or side black bars, no stretch or crop. |
| Stop and cleanup | SIGINT saved both movies. Recorder and observed capture children exited; no temporary movie remained. Same app/SpringBoard PIDs and boot per run; input values and contact traces stayed unchanged. E shutdown completed. |
| Refusals | Follow-active plus either screen option, incomplete selected pair, legacy expected-boot, wrong boot on a fresh path, and existing-output protection in follow-active and selected modes all refused as expected. |

Opening/rotation recovered from two actual read errors: a clean inactive-display result and a changed-context read. Closing needed no recovery. The accepted-frame spans were 17.7893 and 12.2211 seconds; maximum gaps were 3.2208 and 2.5224 seconds. Requested FPS is a maximum, not a guaranteed rate.

## Build and check evidence

The isolated CLI build and stage passed. Thirty-five existing tests across eight suites passed in separate runs: 34 media tests and one artifact test with nine variants. The first full run failed because an earlier isolated setup had omitted the compiled FBSimulatorControl Swift module. Copying the exact accepted module into this owned build copy fixed that setup gap; no production verifier, test or runtime changed. The original full-run failure and a later wrong-working-directory failure remain saved. This is not a complete pipeline rerun or release claim.

Four offline source/bundled guide checks passed on the merged proof notes. Security scan remains UNVERIFIED per Cam. Five Swift feature files, native framework source and wire versions are unchanged.

## Evidence and limits

Local evidence is under `build_products/verification/follow-active-recording-20261023/`: `feature-scoped-acceptance.json`, `native-acceptance-v3.json`, the opening movie in `manual-proof/proof-v3/`, and the closing movie in `manual-proof/closing-proof-v1/`. Both movie folders retain full command receipts, state records and decoded PNGs. The first decoder failure is preserved; a corrected bounded decoder read the same movie without a retake.

This proves low-rate recording through these opening, closing and rotation changes. It does not prove smooth animation, every angle/rate, reboot recovery, forced-cleanup paths, successful legacy recording on this candidate, or a universal/distribution release. Surface identity and native frame presentation time remain unavailable. Native actions were serial and resource-monitored.
