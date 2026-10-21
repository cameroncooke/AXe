# Duo initial connection barrier: isolated handoff

17 October 2026. Main remains `7163081400b59f1df40bff44f3a94dded38eea9a`. Pre-existing source changes remain. No production source edit, commit or push was made for this slice. Full Duo support is not complete.

## Result

The old public V3 default back gesture was reproduced as a native failure at inner 0°: its contact followed the correct path and released, but the app and selected AX stayed on Detail. A two-file library candidate adds the existing guest barrier during selected connection startup. The same default gesture passed twice at inner 0° and once at outer 270° after folding. The app returned to canvas, final selected AX confirmed the page, measured identity stayed fixed and all contacts released. Every owned broker and command process exited and was reaped.

The change does not add a sleep or alter targets, transforms, default duration, sample spacing or cleanup. The service reply establishes service progress; it is not a UIKit readiness acknowledgement. The source mechanism was compared with saved same-hash FlowDeck disassembly. Native evidence supports this candidate on the tested paths, not all input paths.

The inner guest BEGIN-to-handler gap was 177.401 ms for old V3, then 1.049 ms and 2.867 ms for the candidate. Contact spans remained about 0.34 seconds. These are guest event observations, not host latency or a vendor benchmark.

## Candidates and local checks

- CLI: `/private/tmp/axe-duo-initial-barrier-20261017/public/axe/.build/out/Products/Debug/axe`; SHA256 `9109b4289b1931fd623c1ff14a3412084fd37b0cd837b247ae9867e9a82e0b22`.
- FBSimulatorControl SHA256: `18d9544c5b3441853998b44d0e40002469f0c29eb0bd5179d0f0d492a30df4a5`.
- Runtime seal: `/private/tmp/axe-duo-initial-barrier-20261017/runtime-seal.json`; SHA256 `15483ee2b0da005d5065667d92f3f4cd65005925ec6475a6b7ea90f536748a1c`.
- Library seal SHA256: `ad0b40b06810bf6e83818f1ab63098b464914287a0738557bb3d3ceb091fff61`.
- Build compiler: Xcode 27.0 RC, matching the frozen V17/V3 baseline. Native checks: Xcode 27.2 Beta 3, iOS 27.2 build 24B91011. Always set `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer` for native work.

Both builds passed. Seven new Swift Testing gate cases, nine existing guest-barrier cases, seven host-callback cases and 272 existing CLI tests passed. The full CLI test retry used `swift test --skip-build --disable-sandbox --cache-path .../public/swiftpm-cache --jobs 4` with local socket access and E2E disabled. Original cache-path and three socket sandbox failures are retained. Existing dependency warnings remain. The gate checks do not exercise live session open by themselves.

## Exact native checks

Runner: `/private/tmp/axe-duo-fast-back-20261017/run-public-default-back-v1.1.py`, SHA256 `d45bbf1af2c69727f931f75f852cecf7ad3d45e15604e69fe6996cfdb181c78d`.

Run `python3 -B RUNNER --contract CONTRACT --out NEW_DIRECTORY`, with `--open-detail` only when starting from the visible canvas. The runner sends `gesture swipe-from-left-edge` with explicit selected screen ID/UUID and no duration or delta override. It checks native context, PID, fresh selected AX, actual guest contacts, page changes, later release and owned process exits. It never retries input after an uncertain outcome.

All paths below are under `/private/tmp/axe-duo-fast-back-20261017/`:

| Contract | Extra option | Output | Result |
|---|---|---|---|
| `old-v3-inner0-default-v1.1-contract.json` | `--open-detail` | `live-old-v3-inner0-default-v1.1` | Correct delivery; page effect absent |
| `initial-barrier-inner0-default-v1.1-contract.json` | none | `live-initial-barrier-inner0-default-v1.1` | Pass |
| `initial-barrier-inner0-default-v1.1-contract.json` | `--open-detail` | `live-initial-barrier-inner0-default-with-setup` | Pass |
| `initial-barrier-outer270-default-v1.1-contract.json` | `--open-detail` | `live-initial-barrier-outer270-default-with-setup` | Pass |

The earlier V1 old-outer run remains incomplete: it stopped on an early active contact, although later states showed canvas and release. V1.1 permits a valid in-progress early trace, then requires release and native effect at later reads. No original result was rewritten.

The unfold receipt also retains a rejected immediate read: hinge 180° was observed while outer remained active. A later fresh read proved inner 0° before input. Hinge completion alone must not authorize input to a different screen.

## Vendor result

FlowDeck 1.33.0 reported success for both selected comparisons. Inner 0° produced no new app contact. At outer 270°, request `(20,233)` to `(658,233)` produced a vertical guest path `(233,446)` to approximately `(233,0)`. Detail remained in both cases. This is evidence of a path failure, not proof of its exact internal target or transform. RocketSim was not part of this matched gesture comparison.

## Evidence and next work

- [Source candidate and local checks](evidence/2026-10-17-duo-initial-barrier-candidate/README.md): 71 payloads; manifest `31550ab40de56dd9cf191a60de5db140ad3b419ba50d80928033b238577e99f8`.
- [Old/new native comparison](evidence/2026-10-17-duo-public-default-back-initial-barrier-v1/README.md): 228 payloads; manifest `bf23191359bab5e16e2b44bf9abcf4ab416920feb25de18d204666446cf71c9b`.
- [Flow controls](evidence/2026-10-17-duo-flow-back-controls-v1/README.md): 153 payloads; manifest `d4668390a658bd6e46a51bc3c9cbeb83cd06c2ca30edf1c06b416249d1ade5b8`.
- [Outer 270° candidate proof](evidence/2026-10-17-duo-public-default-back-outer-addendum-v1/README.md): 67 payloads; manifest `01eba3d3465c1685fdb10b2646d12ae5ced38ebe55c2c1f7bb549d4f424f67bc`.

Main independently verified all four archive manifests and all 519 payload hashes. The outer proof retains separate setup contact 24 and gesture contact 25, five native context reads and three PID reads. Its guest BEGIN-to-handler gap was 0.984 ms; no general timing claim follows from this one sample.

Next: run the remaining gestures and poses with this candidate, including the two retained inner 270° recognition failures; test normal WKWebView forward history and top/bottom system effects; then include the proved startup change in the combined library candidate. Do not call one native gesture a complete regression run. Public hinge integration, boot-change cleanup, screen-power/capture recovery, keyboard transitions, media lifecycle, batch/agent ownership, ordinary iPhone regression and clean first AX still need their stated proof. See the [coverage table](2026-10-17-duo-isolated-status.md).

The normal browser-history fixture is built at `/private/tmp/axe-duo-system-gestures-20261017/web-history/build-main-1/DuoHistoryProbe.app`, binary SHA256 `61f61742384c537fc1f961d02907d0088e6e7eac662d60897b35c7a790f3cb43`. It has not been installed or tested live. Its source/build manifest and runner review remain under the same temporary root.

Current audit device: `3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463`, boot `16309:1792225249:588057`, fixture PID 36111. It is folded, outer screen 1/UUID `B2547548-07CE-4F39-AEF6-4492B242FD7C`, rotation 270°, hinge 0°, logical 678 × 466. The normal preset fixture is on canvas with zero active contacts. Re-read this state before further input. There are no pending owned native commands.
