# Duo moving-pinch checks: 21 October 2026

Both native checks passed on the unchanged local candidate. Folding and rotation each stopped a moving pinch, released both contacts, and allowed a fresh element lookup and tap. No product fix was needed.

## Candidate

- Main HEAD: `7163081400b59f1df40bff44f3a94dded38eea9a`, with local changes. No commit or push.
- CLI SHA256: `5f4e71958447de644fea1e2a2844518d7b177598e9050393cd56374e039e17c4`.
- FBSimulatorControl SHA256: `8a614ab3116b3d0b88e21086d8a16d0f39aa06f672dd92123b7fd00e7526b779`.
- Wire version 21. The prior held-input fixes are present. No production source, command, option or schema changed for these checks.
- One audit Duo, profile 405, iOS 27.2, UIKit fixture version 6. Boot `56288:1792568825:854790`, app PID `56667`.
- Local Debug arm64 only. Runtime tools used `/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer`.

## Native checks

Both public `axe gesture pinch` commands specified six seconds and 0.5-point spacing. Each planned 83 normal pair events, including the final release. The driver waited for two real contacts and more than two points of opposite motion by each finger before it started the external device change.

| Case | Gesture and device change | Result |
| --- | --- | --- |
| `pinch-fold-v2` | Outward pinch, radius 40 to 80 points. Close hinge 180 to 0 from inner screen 3 at 90 degrees. | Stopped after 16 of 83 normal events. Both contacts ended. Confirmed owned release. Fresh lookup and real button tap passed on outer screen 1 at 0 degrees. |
| `pinch-rotate` | Inward pinch, radius 80 to 40 points. Rotate closed outer screen 1 from 0 to 90 degrees. | Stopped after 15 of 83 normal events. Both contacts cleared. Confirmed owned release. Fresh lookup and real button tap passed on outer screen 1 at 90 degrees. |

Both receipts report `failedNoReplay`, `staleContext` and `releaseEnqueuedAndDrained`, with no quarantine. These are the expected interruption results. Neither old path reached its final radius. Both contact IDs ended or cancelled, with zero active touches. A further half-second observation found no new touch events.

Each case then read the active display and accessibility tree again. The exact-ID tap of `feature.tap` checked the current app PID and selected display. Each tap produced one button callback, one down/up contact, and a point within 0.5 logical points of the validated point. No touch remained held.

App contacts cleared about 0.53 seconds after the fold request started and 0.76 seconds after the rotation request started. These values measure the app touch trace. The cleanup receipt separately confirms AXe sent and drained its owned release. The app timings are not direct AXe send times or worst-case latency bounds.

The copied external-state tool sends hinge/orientation requests only. It represents a user changing the device during input. It sends no touch input and adds no production route around the CLI lock.

## Tools and evidence

The [result](/Volumes/Developer/AXe/build_products/verification/moving-pinch-20261021/main-result.json) records both cases and resource samples. The [candidate manifest](/Volumes/Developer/AXe/build_products/verification/moving-pinch-20261021/candidate.json) saves 89 source/runtime files and six verification tools or binaries. The prior candidate verifier passed before the simulator was started. No build or broad test suite was needed for this unchanged product candidate.

Each case folder saves the exact commands, fresh context, geometry, contact traces, native change receipts, cleanup result, app callback, child exits and CPU/memory samples. The driver, resource guard and external-state tool are in the same evidence folder. To validate saved evidence without simulator input, run from the repository root:

```bash
/usr/bin/python3 -B build_products/verification/moving-pinch-20261021/verify.py --current
```

Without `--current`, the verifier checks the saved candidate copies.

Two failed attempts remain recorded:

- `setup`: the initial remote automation-session read timed out during startup. It sent zero touch events. A separate warm setup succeeded; no product timeout was changed.
- `pinch-fold`: the driver used inconsistent comparisons at exactly two points of motion. It stopped before any fold request. The recorded pinch moved correctly, completed its normal path and released both contacts. The corrected driver waits for more than two points on both contacts and allows owned commands time to drain on failure. The new `pinch-fold-v2` attempt passed. The original attempt remains failed.

## Resources and limits

Checks ran in order with one guest, no parallel builds and no subagents. The guard sampled working memory and aggregate process CPU. The stop limits were 8 GiB for the app or simulator group, 4 GiB for owned commands, or simulator CPU at least 600% for 20 seconds. No stop condition occurred.

Sampled peak memory was 5.070 GiB for simulator processes and 3.984 GiB for ChatGPT. Initial setup had two high CPU samples, 1,539.1% and 854.9%; the final setup sample fell to 486.7%. The successful warm setup ended at 3.6%. After shutdown, simulator support used 0.450 GiB and 0.2% CPU. Final discovery showed no booted guests. Existing Device Hub was left unchanged.

This proves outward-pinch closure at inner 90 degrees and inward-pinch rotation from outer 0 to 90 degrees on this candidate. Other pinch/change combinations, poses, moving two-finger rotation, retained library pairs, native held keys/buttons and failure during cleanup remain unverified. This is not an atomic OS change/send guarantee or release-package acceptance.

Skill sources were unchanged. Security scanning remains UNVERIFIED, as requested.
