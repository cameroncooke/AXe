# Selected Duo tap waiting: 21 October 2026

Cam authorized local commits and continued core Duo work. This packet adds ordinary selected-screen tap waiting. It does not close the whole Duo audit.

## Change

Ordinary selected taps by exact ID, label or value now accept a positive finite wait through 30 seconds. The poll interval is finite, from 0.05 through 30 seconds, with a 0.25-second default. Zero wait keeps the existing immediate path. A non-default interval without a positive wait rejects before send. Coordinates and semantic press still reject polling. Individual selected batch tap steps use the same request builder. Batch-level polling stays unsupported.

Selected wire 22 carries a typed optional wait policy. Old wire 21 rejects. No native framework source or ABI change is needed. The existing final target checks and tap styles remain in effect.

The owner takes the common input lease and the initial screen/boot/hinge/rotation observation once. It retries only the typed native absent-match result, using fresh read-only snapshots. Ambiguity, wrong PID, acquisition failure, cancellation or a device change stops the wait. Each acquisition and sleep uses the remaining monotonic wait budget. The owner retains no snapshot history. After a match, final target acquisition/admission and the single input send run outside the retry loop. That existing final phase has its own budget; the wait timeout is not an end-to-end tap deadline.

Positive-wait taps also monitor the admitted client's socket. EOF, extra data or a socket error cancels the owned operation. The monitor is cancelled and joined before the server can close or reuse the descriptor. This is scoped to positive-wait taps. It does not add whole-batch signal handling, undo sent input, or guarantee an atomic cancellation boundary after input starts.

## Candidate and method

- Source base: main 731a440f7169be7d13f2ed02f8df61c5810c0faa, isolated branch codex/duo-tap-wait.
- Debug arm64 CLI SHA256: 8ae3dd442beae6906fc7f4743b5e0dab3758dadb9874ffc4b50ce4a92676865e.
- Unchanged FBSimulatorControl SHA256: de27c2cedaeeef2415a0a257c9fa417dd62cbf7fea000a2b1c27f232a574fe3d.
- Context helper SHA256: e9bfece805a2064b15aa27d889f4d724a1da574e2741ba12c3bef5d1dce4fe57.
- Compiler: Xcode27.0 Release Candidate; runtime: Xcode27.2 Beta3, Duo profile405.
- One owned guest: 1DF98D02-3F41-4696-A99F-42DBD4369A73. Boot54662:1792592849:410942; proof app PID54953.

The separate public UIKit app com.camsoft.duo-tap-wait-probe has visible controls to show, hide or delay a target, create a duplicate, and activate a sentinel or fresh button. Only normal UI callbacks change its state. Its read-only state file records actual window contacts after normal event dispatch, complete contact IDs/phases/points, callback counters and view geometry. There is no hidden app state control or production test route.

Each case freezes 26 source/runtime/fixture files before input and retains every raw command, exit, receipt, app state and read-only owner-busy witness. A separate pinned verifier checks saved evidence without input. Failed or uncertain input is never replayed.

## Verification

- Build: DEVELOPER_DIR=/Applications/Xcode-27.0.0-Release.Candidate.app/Contents/Developer IDB_CHECKOUT_DIR=/Volumes/Developer/AXe/idb_checkout xcrun swift build --arch arm64 --jobs 1 --skip-update: passed.
- Focused Swift checks: same environment, swift test --arch arm64 --jobs 1 --skip-update with the exact filter in tests-01/started.json: 182 tests in 19 suites passed.
- Public host boundaries: scripts/verify-duo-parity-boundaries.py, 12 parser/help/build-boundary cases passed, no simulator input.
- Skill checks: pinned skill-check1.2.0, --no-security-scan --no-installs --format json, both skill directories passed with zero errors/warnings. The official skill-creator quick validator also passed both directories with local PyYAML6.0.3. The first quick-validator attempts lacked PyYAML; no source change followed. axe init --print exactly matched the bundled source.

All 23 native cases passed on the frozen CLI above. The saved verifier passed every record and matched the current production source pins. All 70 actual touch cycles ended, with zero held contacts. The final app recorded 19 target callbacks and 5 sentinel callbacks; the other 46 contacts activated visible setup controls.

| Check | Cases | Result |
| --- | --- | --- |
| Immediate target, standalone and batch | 2 | One target action each; batch sentinel followed. |
| Delayed ID, label and value, standalone and batch | 6 | Repeated fresh probes, one target tap and complete release. |
| Additional inner-screen delayed ID and batch label | 2 | Matched waits after opening and after rotation. |
| Missing and duplicate target, standalone and batch | 4 | Zero target input; no later batch step. Duplicate resolution failed after one probe. |
| SIGINT and SIGTERM, standalone and batch | 4 | Waiting owner was witnessed busy before appearance. No late touch through the original wait budget plus the existing target budget and settle margin. Same owner accepted a new request; fresh lookup/tap of the same target passed. |
| Opening, same-panel hinge change, closing | 3 | Outer0 to inner90 at hinge180; inner90 hinge180 to90 with the same panel; inner180 hinge90 to closed outer90. Each old wait stopped with zero input, then the same element was found and tapped again. |
| Inner and outer rotation | 2 | Inner90 to180 at hinge90 in batch; outer90 to270 standalone. No old touch or later batch action. A fresh same-element tap passed at the new frame. |

The original 12 cases keep the first frozen driver. Before interrupted input began, the driver and saved verifier were strengthened to require a fresh same-target tap after all interruptions. Both verifier versions and their separate hashes remain in the evidence root. No production code changed after the successful build.

Resource limits used physical footprint: app 8 GiB, combined simulator 10 GiB and command 4 GiB, with the existing sustained CPU limits. Sampled peaks were app 7.281 GiB, simulator 4.711 GiB and command 0.377 GiB. Simulator CPU briefly reached 1529.9 percent during startup; no 20-second sustained condition or other resource stop occurred. Builds used one compiler job. One guest and one native input case ran at a time. All owned command children were reaped. The owned Duo was shut down; the final device catalogue has no booted guests.

The first cold setup failed while creating a remote accessibility session. It reported zero events before any visible setup tap. Its failed record remains at cases/immediate-outer0. A separate settled setup passed. No timeout increase, fallback or speculative bootstrap fix was added.

## Evidence and limits

Evidence root: /Volumes/Developer/AXe/build_products/verification/duo-tap-wait-20261021. Raw exact build/check/native commands, resource samples and frozen candidate copies remain there. The committed native driver is scripts/verify-duo-tap-wait.py; the read-only verifier is scripts/verify-duo-tap-wait-evidence.py. For one saved record, run python3 -B scripts/verify-duo-tap-wait-evidence.py <case-directory> --out <new-result.json>.

This packet is one Duo profile/runtime, one public UIKit Button role and a local Debug arm64 build. It does not prove every app/pose/selector scalar, rigid-device polling, release/universal packaging, native switch activation, arbitrary slider percentages, multiline/long text, retained batch token chaining, or lock/wake/power behavior. Those remain separate checklist items. Security scanning remains UNVERIFIED. No push is authorized.
