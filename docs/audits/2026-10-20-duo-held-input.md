# Duo held-input checks: 20 October 2026

Eight native checks passed on the final local candidate. A fold and a rotation each interrupted a drag, a one-finger hold, a two-finger hold and a retained single touch. Every check ended with released input, fresh display and accessibility reads, and one real button action.

## Candidate and changes

- Main HEAD: `7163081400b59f1df40bff44f3a94dded38eea9a`, with local changes. No commit or push.
- CLI SHA256: `5f4e71958447de644fea1e2a2844518d7b177598e9050393cd56374e039e17c4`.
- FBSimulatorControl SHA256: `8a614ab3116b3d0b88e21086d8a16d0f39aa06f672dd92123b7fd00e7526b779`.
- Wire version 21. No command, option or schema change.
- One Duo profile 405, iOS 27.2, UIKit fixture version 6. Final boot `5990:1792512359:271787`, app PID `6267`.
- Local Debug arm64 build with two jobs. Release and universal packaging remain unverified.

Two faults were reproduced before changes:

1. A six-second hold did not check for changes during its delay. UIKit cancelled the app touch, but AXe waited 5.67 seconds after the change request before sending its owned release. An earlier app-only check is superseded; it does not prove AXe release timing.
2. A retained contact kept its token and device lock until the caller sent another command. That stale-coordinate command sent zero new events and caused cleanup, but cleanup was not automatic.

The library wait now checks the existing local change feed at most 50 milliseconds apart between scheduled waits. It uses a deadline and does not start full context processes. Before integration, the isolated library sent its owned release after 0.53 seconds for folding and 0.79 seconds for rotation. Original-target identity checks and release barriers completed.

The CLI owner now checks retained input during idle maintenance. It blocks new requests before asynchronous cleanup, releases on the original connection, and clears the old token. Uncertain cleanup keeps the device lock and saves a recovery record. It does not select a new screen or resume a gesture.

## Final native checks

| Input | External change | Result before the new tap |
| --- | --- | --- |
| Drag | Open outer to inner | Stopped after 6 of 122 planned normal events; released |
| Drag | Rotate inner | Stopped after 10 of 122 planned normal events; released |
| One-finger hold | Close inner to outer | One down, then owned release; command ended before the six-second delay |
| One-finger hold | Rotate outer | One down, then owned release; command ended before the six-second delay |
| Two-finger hold | Open outer to inner | Both contacts ended or cancelled; owned cleanup completed |
| Two-finger hold | Rotate inner | Both contacts ended or cancelled; owned cleanup completed |
| Retained single touch | Close inner to outer | Contact cleared before the next request; old token rejected with zero events |
| Retained single touch | Rotate outer | Contact cleared before the next request; old token rejected with zero events |

All eight checks then discovered the active panel, read its accessibility tree, resolved `feature.tap` with the current app PID, and tapped its fresh frame. Each produced one button callback and one released tap contact within 0.5 logical points of the validated point. No touch remained held. The full old drag path did not complete. No interrupted input was replayed.

The external-state tool represents a user changing the device while AXe holds input. It sends a real hinge or orientation request through the previously proved native control path. It sends no touch input and adds no production route around the CLI lock. Each external change started only after the fixture reported the actual held contact or contacts.

## Evidence and checks

The [final result](/Volumes/Developer/AXe/build_products/verification/held-gesture-20261020/main-result.json) links the native checks. The [candidate manifest](/Volumes/Developer/AXe/build_products/verification/held-gesture-20261020/final-candidate.json) saves 89 source/runtime files and nine tool files or binaries. Raw command arguments, app state, touch traces, release evidence and process results remain in each check folder.

Run the saved-data verifier from the repository root. It sends no simulator input:

```bash
/usr/bin/python3 -B build_products/verification/held-gesture-20261020/verify.py --current
```

Without `--current`, it checks the saved candidate copies. Focused checks passed 39 CLI test functions in six suites and nine library test functions in one suite. The latter includes touch, pair and held-key delay cases. Exact commands are in `retained-owner-final-checks/started.json` and `library-candidate/started.json`. The foundation source check passed with `AXE_BUILD_ARCHS=arm64 scripts/build.sh setup`.

Failed baselines remain failed. Cold startup AX reads also failed before input; later warm reads passed. One attempt used stale screen identities after failed setup and rejected before touch dispatch. Those records caused no input retry or timeout change. Python driver clock values and native uptime values are separate clocks; release comparisons use native uptime values only.

The sampled simulator peak was 5.566 GiB and the ChatGPT peak was 4.538 GiB. No resource stop occurred. Checks ran in order, with one guest and no parallel builds or subagents. Final discovery showed no booted guests. Simulator support used 0.502 GiB and 0.0% CPU. The existing Device Hub process was left unchanged.

## Limits

This proves the eight stated cases on one profile and fixture. It does not prove every pose, moving pinch/rotation interruption, retained library pairs, native held keys/buttons, failure during cleanup, or an atomic relation between an OS change and a send. Recorded timing is not a worst-case latency guarantee. The controller must still read the active screen and accessibility tree again before the next action.

Skill files were unchanged. Security scanning remains UNVERIFIED, as requested. The original final hinge-read timeout remains a recorded observation and does not block this work.
