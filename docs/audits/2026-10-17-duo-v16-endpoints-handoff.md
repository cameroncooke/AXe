# Isolated AX preparation and endpoint handoff

17 October 2026. The full parity goal remains active. No production source, commit or push was made. Main remains at7163081400b59f1df40bff44f3a94dded38eea9a; unrelated agent/source/test changes remain untouched. See [current coverage](2026-10-17-duo-isolated-status.md) for the full open scope.

## Accepted bounded results

- V16 framework86ec17d015537ad800109be0c9c36ecf1604538087307e34307a4b493ebc8bdc: explicit existingBridge mode covers initial acquisition and final target validation. Outer0/90/270 and inner0 after unfold pass exact-ID taps, one app increment, same-contact BEGIN/END, unchanged context and0active contacts. Three invalid-target controls reject without input. The automationSession default is unchanged. [Evidence](evidence/2026-10-17-duo-target-guard-v16-live/README.md).
- First existingBridge read on a new Duo returns72 nodes in one attempt; an absent ID rejects with unchanged app state and0input. A later warm tap passes. Boot reported Data Migration Failed, so this is not a clean baseline or a first-tap cold proof. AX initially disabled is not established. [Evidence](evidence/2026-10-17-duo-first-read-v16/README.md).
- Endpoint V3 framework238017bbc10c4d1f7abe2febdf7e3f883dc554f753917f61a5f0cf5a767e0173: inner0 lower50→0 uses5 actions in8.0025s; upper0→100 uses10 in9.7177s. Each action has one app value-change event. Both0.6s/5s observations and the unchanged15s budget pass. Already-minimum/maximum send0actions; wrong-context/non-slider controls send0actions. This is AX endpoint proof, not physical-thumb or arbitrary interior-value proof. [Complete source chain and live evidence](evidence/2026-10-17-duo-slider-endpoint-v3-live/README.md); main verified all322 payload hashes.

## Failures retained

- V15 and the matched V16 automationSession control fail with AccessibilityBootstrap Code10, session-request, DTXProxyChannel Code1 Channel disconnected. The same failure also blocks the V2.1 endpoint candidate after unfolding. V3 requires explicit existingBridge; it does not silently retry or change modes.
- Outer180 request through FlowDeck reports success=true but confirmed=false. Native screen and Apple device orientation remain at the prior90/landscapeRight observation. The test stops before input. Fixture masks allow all four orientations; cause remains unproved. Source report: `/private/tmp/axe-duo-outer180-investigation-20261017/REVIEW.md`.
- Disposable Apple panel power changes raw1→0→1. Off capture exits60 after61s. App input works after restoration, but two later captures stay black and byte-identical. Migration warning is retained. [Cycle](evidence/2026-10-17-duo-apple-panel-power-v1/README.md), [capture addendum and vendor paths](evidence/2026-10-17-duo-apple-panel-power-posttap-v1/README.md).

## Exact working candidates and commands

V16 source/build/helpers are under `/private/tmp/axe-duo-combined-20261017`, with `idb-v16`, `seal-v16.json`, `candidate-v16-provenance.json` and `run-v16-live.py`. The helper requires explicit preparation in its request. Main checked19seal,837source,6binary and3compiler-list hashes without mismatch.

Endpoint V3 is `/private/tmp/axe-duo-slider-endpoint-v3-20261017`. Main checked48manifest,1113source and6runtime hashes without mismatch. Exact native commands:

```sh
python3 /private/tmp/axe-duo-slider-endpoint-v3-20261017/run-live-cases-v3.py --preparation existingBridge --cases wrong-context unavailable-target lower --out /private/tmp/axe-duo-slider-endpoint-v3-20261017/live-inner0-first
python3 /private/tmp/axe-duo-slider-endpoint-v3-20261017/run-live-cases-v3.py --preparation existingBridge --cases already-lower upper already-upper --out /private/tmp/axe-duo-slider-endpoint-v3-20261017/live-inner0-followup
```

These directories are used evidence outputs; do not reuse them. The runner needs explicit setup and does not reset the fixture. The visible Reset button established50 before the first queue. All six helper outcomes and child exits were checked. `main-independent-live-review.json` checks exact app callback counts and unchanged touch traces.

V2.1 corrected only the helper's `/tmp` versus `/private/tmp` framework-path check. Its automation failure remains under `/private/tmp/axe-duo-slider-endpoint-v2.1-20261017/live-inner0-first`. V3 copied V16's preparation type into its older standalone slider source. A combined library must use one shared definition; do not copy a duplicate enum into V16.

## Device state at handoff

- Audit3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463: boot16309:1792225249:588057, active inner3 UUID769ED878-389B-4346-9C56-CB0703AB3E58, rotation0, hinge180, fixturePID32539. Slider100, zero contacts after endpoint proof. No power writes on this boot.
- Power disposable116F3CD1-3B6A-4045-AE6D-A3B1B7D36E05: restored outer1 raw power1; captures remain black despite the later app tap. Do not use it as a clean capture baseline.
- First-read disposable4D015B3E-84DA-4767-86A1-632DE1AB3289: boot48598:1792248818:92289, outer1 UUID68646889-4B37-4674-A7DF-BB55CDE72844, rotation0, fixturePID50563, tap1, zero contacts. Migration warning remains. Re-read current identities before any later input.

After those observations, both disposable devices were shut down with exit0. Their data was preserved. A fresh device listing confirms both Shutdown and the main audit device Booted. [Cleanup readback](evidence/2026-10-17-duo-disposable-cleanup/verified-devices.json). The disposable boot/PID values above are historical proof identities, not running processes.

## Next implementation boundary

Consolidate the accepted target, endpoint and session work into one isolated candidate before production rollout. Preserve explicit preparation, full display/boot admission, original-target cleanup, complete event preflight and the existing deadline rules. Public broker V3 remains incomplete; selected describe/ID tap and endpoint routes need exact command proof and documentation.

Remaining native work includes outer gesture matrices, the outer180 setup defect, two original inner270 recognition failures, public fold/expiry/lost-response/boot-change behavior, stream transitions, the original keyboard freshness failure, and safe visible panel-power recovery. Do not count passing V15 or V10 cases as tests of a later combined binary. Provider-agent proof and matched vendor performance remain open. Main owns simulator operations; workers may prepare source/build/archive work, with builds held during live input.
