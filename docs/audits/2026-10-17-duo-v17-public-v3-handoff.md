# V17 library and public V3 handoff

17 October 2026. Full feature parity remains open. No production source, commit or push changed. Main remains at `7163081400b59f1df40bff44f3a94dded38eea9a`; the pre-existing agent/source/test changes remain intact.

## Frozen candidates

- Combined library V17: `/private/tmp/axe-duo-combined-20261017/idb-v17`. Framework SHA256 `6337fc278fae3f52348c32fd3c46d7564e2af7ed22aa1ef600c94c560edcb341`. It merges V16 target/session behavior and endpoint V3 through eight changed/added files, with one explicit AX preparation type. [Source and native proof](evidence/2026-10-17-duo-combined-v17-live/README.md).
- Public CLI V3: `/private/tmp/axe-duo-broker-v3-20261017/axe/.build/out/Products/Debug/axe`. SHA256 `a9c1efc56ddb32b437014031f3a7d85fe1f01d8b5556c421512aa3e8ae9a2c2e`. Final seal SHA256 `dcd1b34259f83d1bb34318def23016f97557c0cd0c31da20cd2b08565649a6ba`. [Public proof and source](evidence/2026-10-17-duo-public-broker-v3-live/README.md).

V3 adds selected whole-tree `describe-ui`, exact ID/label `tap`, and ID-based `slider --endpoint minimum|maximum`. Each AX route requires explicit screen ID/UUID and expected PID. `--ax-preparation existing-bridge` is explicit. The default remains `automation-session`; there is no fallback. Existing selected coordinate/path/retained requests retain their rules under a separate version-5 socket.

One per-device owner covers selected reads, taps, sliders and HID. It waits for feed cleanup before releasing the common input lease. Uncertain input cleanup or AX action delivery keeps the live lease and publishes a private persistent quarantine record. New candidate leases reject that record, including malformed records. Persistence failure retains the live lock and prevents idle shutdown; forced process exit after storage failure is not durable. Old installed binaries do not honor the new lease or quarantine.

Public AX responses allow 4 MiB. Target output capacity is checked before down. Endpoint output uses bounded scalar samples/actions. The endpoint controller still has a 15-second/20-action budget with both 0.6/5-second final observations and backend cleanup; public context setup and outer feed cleanup are additional work. Do not present this as a hard 15-second CLI limit.

## Verification

V17 local checks pass: 53 AX functions/134 cases; 13 acquisition functions/17 cases; 47 session scenarios; 11 lease-owner checks; 27 endpoint functions/38 cases; six framework-path checks. Main verified 1,115 source files, three compiler lists, 12 runtime paths and 35 seal entries. Main also verified all 364 library archive payload hashes.

The combined library passes nine native cases on outer screen at 270°: ID tap, duplicate-label/wrong-PID rejection and six endpoint cases. Lower 100→0 and upper 0→100 each produce exactly 10 app callbacks for 10 AX actions. Both no-ops and both invalid-target cases send 0 actions. Tap gives one app increment and one complete contact. Outer90 setup was rejected before AX/input because native rotation was 270°; this failure remains separate.

Public V3 build, 61 test functions/107 expanded cases in eight suites, and five help/version calls pass. The initial build failure is retained. Three local socket tests initially hit sandbox `EPERM`; the same suite passes outside that sandbox. Real-owner checks cover mixed operations, cleanup uncertainty, persistence failure and idle/shutdown. Complete source review and the narrow dependency/test review found no remaining defect. Main verified 658 source hashes, 24 runtime files, 33 final references, six compiler lists and 226 compiler inputs.

All 16 public native cases passed. All four owned brokers exited 0 and were reaped. Main verified all 357 public archive payload hashes. Manifest SHA256: `f1a7f7aec1f0ffa30f0f43f717761885a1f75385f1f6612b782d191a954cbecf`.

The public native sequence uses one frozen CLI and one fixture process/boot:

| Pose / transition | Public checks | Actual effect |
|---|---|---|
| Folded outer screen 1, rotation 270° | 10 cases: describe, ID tap, duplicate label, wrong PID, inactive panel, four endpoint cases, unique slider label tap | ID tap increments once at (381, 161). Three negatives send 0 input with unchanged app state. Lower/upper give 10 AX actions and 10 callbacks each. No-ops give 0 actions. Unique slider label produces BEGIN/END at (381, 329); value stays 100, so this is contact targeting, not slider-value proof. |
| Rotate outer to 0° | Fresh describe and ID tap | Tap increments once at (191, 161). |
| Unfold to inner screen 3, measured rotation 90° | Fresh describe and ID tap | Tap increments once near (433.7, 161). |
| Fold back to outer screen 1, measured rotation 0° | Fresh describe and ID tap | Tap increments once at (191, 161). |

Each case checks fresh native context before/after, response context, app state and guest touch trace. Each ID tap has exactly one BEGIN and one END on the same contact, with zero active contacts afterward. Rotation setup uses FlowDeck. Hinge setup uses the isolated typed `hinge-proof`, which waits for two mechanical readbacks. These are setup tools; V3 does not yet expose hinge or orientation commands.

Exact commands and results are under `/private/tmp/axe-duo-broker-v3-20261017`: `run-public-proof.py`, `public-*-contract.json`, four `live-public-*` directories, `run-native-setup.py` and three `setup-*` directories. Each public run starts and awaits its own foreground broker; no replay or forced termination. Independent review is in `independent-public-live-review.json`.

The public candidate loads V17 FBSimulatorControl/FBControlCore/XCTestBootstrap. FBDeviceControl and its nested framework copies remain from V2; this is an explicit packaging limit. Skill lint passes with no errors/warnings. Full skill-check remains incomplete because its security runner is unavailable.

## Lifecycle evidence and setup limits

[Public V2 lifecycle archive](evidence/2026-10-17-duo-public-lifecycle-v2/README.md): retained contact expiry passes on inner screen 3 at 0°, with one BEGIN/END, drain log and clean owned exit after about 30 seconds. A deliberately lost response also releases one contact; client outcome stays unknown and no replay occurs. The first lost-response attempt sent no input because the test client used an overlong Unix socket path. A separate driver copy corrects only the connection path.

The old capability enqueue helper did not fold the device: native hinge remained 180°. The typed hinge setter reached 0°, but active outer rotation became 90° rather than the declared 0°. That held-fold test stopped before a stale move. Later, native rotation was 270°. No causal explanation for that later change is claimed. Inactive-panel orientation cannot predict the next active coordinate space; fresh active readback is required. Public stale-token fold rejection remains unproved. V2 lifecycle results do not establish V3 lifecycle acceptance.

## Device and next work

Audit UDID `3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463`, boot `16309:1792225249:588057`, fixture PID 32539. Final measured pose: outer screen 1 UUID `B2547548-07CE-4F39-AEF6-4492B242FD7C`, rotation 0°, hinge 0°. Inner screen 3 UUID `769ED878-389B-4346-9C56-CB0703AB3E58`. Slider value 100. Re-read all current identities before new input. No power writes occurred on this boot. Both earlier disposable Duos remain shut down with their data intact.

Continue with the frozen V3 public swipe/drag and all eight presets, using visible fixture targets and actual scroll/system effects. Then adapt the strict lifecycle driver for version 5 and this binary: held fold, expiry, lost response and boot change. Preserve all old failures. Do not reuse a timed-out or stale token, infer an active screen from an inactive snapshot, or silently switch preparation modes.

Remaining scope includes outer 180° setup, two original inner 270° gesture-recognition failures, clean first-use AX, keyboard freshness/cancellation, public hinge integration, failed visible panel-power recovery, media transitions/public routes, batch/agent ownership, ordinary-phone regression and matched vendor performance. See [full current coverage](2026-10-17-duo-isolated-status.md). Main owns native operations; build workers must wait during device input. No production rollout or full-parity claim is justified yet.
