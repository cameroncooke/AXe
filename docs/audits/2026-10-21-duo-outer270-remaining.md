# Duo outer270 remaining gesture checks

Date: 21 October 2026. All six assigned native cases passed. Product source and binaries were unchanged. This phase is separate from the earlier seven accepted gesture checks and keeps their tool pins unchanged.

## Candidate

- CLI SHA256: 5f4e71958447de644fea1e2a2844518d7b177598e9050393cd56374e039e17c4.
- FBSimulatorControl SHA256: 8a614ab3116b3d0b88e21086d8a16d0f39aa06f672dd92123b7fd00e7526b779. Wire21, local Debug arm64.
- Original audit Duo, profile405/iOS27.2, normal UIKit fixture version6.
- Fresh boot84791:1792578951:735437, app PID85250. Selected outer1/AX1/HID1, rotation270, hinge0.
- Source/runtime pins:89 files, identical to the prior candidate. Six separate tool pins include the public libproc resource guard and its probe binary.

## Native results

The existing strict scripts/verify-duo-input.py ran once for each case after a fresh AX lookup. Every case checked the selected screen, app PID/container, complete window and recognizer traces, exact endpoints, settled app effects, other controls, final accessibility geometry and zero held contacts.

| Case | Required effect observed |
| --- | --- |
| Pinch | Two contacts moved outward, radius30 to39. One completed pinch callback; scale within1.1 to1.5. Both contacts released. |
| Twist | Two opposite radius25 arcs completed45 degrees. One rotation callback; final angle within0.15 radians of pi/4. Both released. |
| Two-finger tap | Two overlapping contacts at opposite30-point offsets. Exactly one added tap callback; both released. |
| Two-finger hold | Same two contacts held at least0.5 seconds. Exactly one added hold callback; both released. |
| Nested up | Complete80-point vertical path moved list0 to70. All30 AX row frames moved by the observed offset. Page stayed173. |
| Nested down | Reverse80-point path moved list70 to0. All30 row frames returned. Page stayed173. |

The pair callbacks can also fire during other pair gestures in this normal fixture. Each tap/hold case therefore compared its own before/after counter and required exactly one added callback. Counts from earlier gestures were not treated as new effects.

## Normal page preparation

At outer270, the nested list starts below the visible page viewport. A fresh AX lookup found the normal StaticText feature.switchLabel. One public coordinate swipe began inside that label and moved the page0 to173. It did not move the nested list or trigger a control/pad recognizer. Both list corners then fit the visible viewport. The two nested cases used that real visible frame. No reset route, injected state, altered fixture or hidden production behavior was used.

The setup also verified the whole contact path, released touch, unchanged other controls and final page/list AX frames. The preparation tool is scripts/prepare-duo-nested-list.py.

## Evidence and saved-data verification

Evidence root: /Volumes/Developer/AXe/build_products/verification/outer270-remaining-20261021.

Raw case folders are outer270-pinch, outer270-rotate, outer270-two-finger-tap, outer270-two-finger-hold, outer270-nested-up and outer270-nested-down. Their check/result.json files contain the bounded native results. Each folder also saves commands, owned child exits, source candidate hash, before/after state, touch traces and final descriptions. expose-list/check contains the normal page preparation.

Latest exact verifier command from the gesture worktree, exit0:

    /usr/bin/python3 -B scripts/check-duo-outer270-evidence.py --current --evidence-root /Volumes/Developer/AXe/build_products/verification/outer270-remaining-20261021

The saved-data verifier sends no simulator input. It validates89 product/runtime pins, six tool pins, all six cases, strict trace/effect grading, final control geometry and all30 row displacements for each nested case. It confirms that the assigned guest is shut down and all owned commands were reaped.

Failed setup records remain separate. A fresh boot reset orientation to0, so the first resume check rejected before gesture input. Two deliberate public rotate-right operations reached90 then270. The initial remote automation-session acquisition then timed out with zero input events. One separate warm acquisition passed. No product timeout changed and no uncertain input was repeated.

## Resources and limits

This worker used one native action at a time, with another assigned guest in parallel. The public libproc guard measured combined ChatGPT/Codex and all simulator processes. Limits stayed8GiB app,10GiB all simulators,4GiB owned commands, and sustained20-second CPU limits of1200percent for simulators/400percent for owned commands.

This phase's sampled peaks: app6.935GiB, all simulators8.329GiB, simulator CPU1564.0percent. CPU peaks were brief; no memory, CPU, time or monitor stop occurred. These global totals include the other worker and cannot be attributed to this guest alone.

The assigned guest shut down after the sixth case. Final catalogue contained no booted guests. The final sample was app6.414GiB, simulator support0.542GiB/16.9percent CPU. All owned commands exited and were reaped; failed setup commands retain their nonzero exits.

These results close the specified outer270 pinch/twist/pair and nested-scroll cells. Together with the earlier phase they also supply outer270 tap, hold, double-tap, swipe and drag evidence. They do not prove retained library pairs, every option, every transition, other profiles, native held buttons, media transitions or release packaging. Do not mark complete device parity from these bounded checks.

No product or skill changes. Only proof tools and this report changed in this branch. No push or security upload. Security scanning remains UNVERIFIED per Cam.
