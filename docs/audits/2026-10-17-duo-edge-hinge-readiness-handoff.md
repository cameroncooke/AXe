# Duo edge and hinge readiness handoff

17 October 2026. Production remains on main `7163081400b59f1df40bff44f3a94dded38eea9a`. Pre-existing agent changes remain untouched. No commit or push was made. Runtime candidates remain isolated.

## Accepted evidence

| Check | Observed result | Limit |
|---|---|---|
| Public hinge V1 read | Hinge0, same boot and unchanged app state. | Mechanical read only. |
| V1 wrong boot and angle181 | Reject before write; no guest state change. | No vendor wire trace. |
| V1 unfold180 | Two fresh mechanical matches. Fresh inner0 context, AX read and guarded Back tap change real page B to A. | Mechanical completion did not establish display completion. |
| V1 refold0 | Two fresh mechanical matches. The immediate native display read fails with `changedDuringRead`, before AX or tap. | Original continuation remains failed. |
| Separate settled Forward | A later outer270 context and guarded Forward tap change A to B. No hinge write. | Does not repair the failed immediate refold check. |
| Bottom swipe, edge none | Outer270, path(339,465) to(339,20), duration0.3, delta50. Complete guest contact29; app scrolls and stays active. | Home absent. |
| Same bottom swipe, explicit edge | Logical bottom maps to native left, wire2. Home appears. Contact30 receives BEGIN, two MOVE events and CANCEL; zero held contacts. | All11 transport events counted. Final context rejects Home rotation0 as stale. No complete gesture success receipt. |
| Fresh Home read | Selected outer0 SpringBoard tree is ready. | Duplicate app IDs remain ambiguous. Recursive branches have different ancestor geometry; equal JSON does not prove equal native identity. |
| Visible Home coordinate control | Public tap at(56.6667,183.3333) uses fresh outer0, sends2 events and drains. Later app state gains exactly one sceneActive event, at outer270, with no held contact. | Coordinate control only. The public coordinate route has no AX element/PID admission. |
| Browser Forward, no edge hint | Complete contact8, path(658,233) to(20,233). Page A and forward item B remain unchanged. | Actual gesture-effect failure. |
| Same browser path, right-edge hint | Native wire3; exact page A to B, one backForward completion, correct history and no toolbar action. Contact9 starts and ends correctly; no held contacts or dropped logs. | Strict sample-by-sample grade fails: only MOVE sample indices1,4,13 are observed. Original result remains failed despite its separately established navigation effect. |
| Separate Forward V1.1 | PASS_BOUNDED. Contact11 has BEGIN,10MOVE,END; indices1,3,6,7,8,9,10,11,12,13. Exact A to B history and one completion, no toolbar action, active678×466 scene, same full context and zero held contacts. | Missing MOVE indices2,4,5 remain explicit. No claim that all samples reached UIKit or met a timing bound. |

The normal browser Back setup before V1.1 passed and returned to page A with forward item B. V1.1 then moved to B. All owned brokers and helpers from these records exited. That edge slice ended on folded outer1 at270, mechanical0, boot `16309:1792225249:588057`, app PID30370. The later hinge slice changes this state as recorded below.

Latest edge native command:

    python3 -B /private/tmp/axe-duo-edge-native-proof-20261017/run-web-edge-v1.1.py --edge right --inset 20 --out /private/tmp/axe-duo-edge-native-proof-20261017/web-right-inset20-v1.1

## Saved archives

Main independently verified every payload in these archives:

- [System and web gestures](evidence/2026-10-17-duo-system-web-gestures-v1/README.md):359 payloads; manifest `d68a694f2bf516ee5f2ac60b64875d3e0b24d88a7b44c5aa09f7e5c82ea57ccb`.
- [Public hinge V1 source and checks](evidence/2026-10-17-duo-public-hinge-candidate-v1/README.md):117 payloads; manifest `da6fb97f27a001edd0e0ecf9cb905955abf6dbcf4ece76b3e6be5cf52f31fc52`.
- [Public hinge V1 native records](evidence/2026-10-17-duo-public-hinge-live-v1/README.md):251 payloads; manifest `118657b6f6732e02990fd85a2d8980a7f3feb6afb670f96796f316ed5c2c0baf`.
- [Explicit edge source, checks and native records](evidence/2026-10-17-duo-explicit-edge-v1/README.md):348 payloads; manifest `d44a5e3a5bc1b775443b8768bd97a1fc768b053689fa746fe42848c8fd1e9d27`.
- [Public hinge readiness V2 source and checks](evidence/2026-10-17-duo-public-hinge-readiness-v2/README.md):125 payloads; manifest `586738e030392c716d77c2e20c77bb668b5e5e787289784488f5135cecf04e5b`.
- [Public hinge readiness V2 native proof](evidence/2026-10-17-duo-public-hinge-readiness-v2-live/README.md):227 payloads; manifest `7f3e82a6d2e4be69b76743700dbbc08b404f433c2af04f3382669dab65779af1`.
- [Next AX diagnostic source only](evidence/2026-10-17-duo-ax-identity-source-v1/README.md):27 payloads; manifest `d18c1018a95062a5e8f8437ca18b5974bfb224be030df90507cbd6449af70914`. This is reviewed source, not native acceptance.

The explicit-edge source/build seal is `/private/tmp/axe-duo-explicit-edge-20261017/seal.json`, SHA `9ebaf4abfd27cc8f2506769311910281cdcac62f530e3382d18876711d85e823`. Main verified43 artifact and8 runtime hashes. Helper SHA `7f6067786fc0146acbf0257cf1946065b7ef71aac333f0d0c153565f53e5c6ca`; framework SHA `ee9108f8d1838d30d7c78994be38a7a085ddac028e51701bda7e2655f3a1a056`. Fourteen Swift tests passed; no public edge option or default changed.

## Public hinge V2 native acceptance

Public hinge readiness V2 is at `/private/tmp/axe-duo-public-hinge-readiness-v2-20261017`. Full source review found no material defect; all25 pinned files matched. The mechanical writer, native full-context reader and common input lock remain unchanged from V1. The review SHA is `18c5fa966a284dda114cf761f3fd5dc0e824f61b904696b964a06a23c317dfec`.

The opt-in command pairs `--wait-for-screen-id` and `--wait-for-screen-uuid`, with a bounded `--readiness-timeout`. Wire7 prevents an old broker from silently ignoring the new request. Under the same owner, it validates the requested pair before one hinge write, then requires two coherent full native reads. A clean display failure preserves the mechanical receipt and releases ownership. Unconfirmed observer cleanup uses a separate schema3 record and retains ownership. No UI readiness or future display stability is claimed.

The framework and public CLI build passed. All20 library policy checks passed after a sorted-key encoding correction to one test. The first public build failure required the parser's supported explicit UUID transform; the typed option and behavior remain. Both failures and original source are retained. The first public suite also retained three socket bind failures from sandbox permissions; the identical socket-enabled rerun passed288 tests in39 suites, with native E2E disabled. Both quick skill checks and content lint passed. Security validation remains incomplete because its runner is unavailable. All build/check children exited before native use.

Main verified2495 source/runtime/compiler hash references across2285 unique files, with no mismatch or unexpected compiler path. CLI SHA `2559e1b1ac38c37a559062af0f12218ae6e847c2f11b436c4d641a70d8940084`; framework SHA `8b6a1dcdcea5116ecebe575781364a2c292452bb3277808750f3c1c17d842b7a`. Runtime seal SHA `05756f2ff3bbc989ad1082bd7aa904610889603f58e3725aa8831df29c167939`; library seal SHA `3007c1e689fe38b693ffd198249a44d216fc7242e346f97a5895b27afccc9aec`. The seals admit isolated native testing; they explicitly exclude full skill security and native acceptance.

Five separate native cases passed with the frozen V2 CLI:

| Case | Result |
|---|---|
| read | Mechanical/sensed0. App state and native context unchanged; no input. |
| wrong-readiness-pair | Inner ID3 plus outer UUID rejects with `invalidRequest`, no mechanical receipt/readiness/hinge failure/quarantine. Later read and full native/app state remain unchanged. |
| open-back | One set180. One transitional read error, then two matching inner3/0° observations. New full context and guarded Back tap at(111.667,106) change B to A. Contact12 begins and ends; zero final contacts. |
| close-forward | One set0. Two transitional read errors, then two matching outer1/270° observations. New full context and guarded Forward tap at(565,24) change A to B. Contact13 begins and ends; zero final contacts. |
| clean-incomplete | One set180 waits for the valid outer pair. After16 attempts, display observation is incomplete. Mechanical receipt remains successful; cleanup is confirmed, no hinge failure/quarantine. Same broker accepts a later read. No UI tap. |

All five owned brokers exited0. No write or input was replayed. The original V1 immediate-refold failure remains unchanged.

Exact driver for each case:

    python3 -B /private/tmp/axe-duo-public-hinge-proof-v2-20261017/run-public-hinge-v2.py --contract CONTRACT --case CASE --out UNUSED_OUTPUT_DIRECTORY

`outer270-enabled.json` was used for read, wrong-readiness-pair and open-back; `inner0-enabled.json` for close-forward; `outer270-incomplete-enabled.json` for clean-incomplete. Each contract is in that driver directory and pins the driver, runtime, fixture and support hashes. Driver SHA `1415e4d51e8bd683a07fae18865382a2d784d0832e1bdc6186b765973f32ae2a`. Its25 file checks passed. One deadline-oracle correction is retained with its original source.

The separate final read at `proof-v2/post-incomplete` measures actual inner3 UUID `769ED878-389B-4346-9C56-CB0703AB3E58`, rotation0, native2007×2853, scale3, logical669×951, mechanical180. Boot remains `16309:1792225249:588057`; app PID30370 and SpringBoard PID16312 remain. The normal web app is active on page B with zero contacts/dropped logs. This read is separate from the incomplete case and does not add an active-panel claim to its receipt. Do not reuse its coordinates without a new observation.

The browser driver correction is separate from the frozen strict result. It grades an ordered subset of the requested quantized path, states which MOVE observations are missing, requires one contact and a real END release, and preserves the exact history oracle. Its26 file checks and the new native V1.1 run passed. The rule is bounded to the measured scale and outer270 path.

## Next native boundary

The V2 native boundary above is complete for these five cases. Native cancellation/boot change, other poses/profiles and production integration remain open. Preserve every partial or failed result; do not replay a write or input after an unknown outcome.

Web HTML AX visibility and native Home object/display ownership still need read-only diagnostics. Do not remove selector ambiguity by frame, label, tree position or equal JSON. The inspected vendor factories use edge none; this candidate is not a verified copied vendor fix. Upstream WebKit source explains recognizer gates but does not identify the installed cause of missing web AX nodes.

The next source-only diagnostic is at `/private/tmp/axe-duo-ax-identity-20261017/DESIGN.md`, with the source archive above for restoration. It preserves recursive branches and compares one selected visible point with wrapper, translation, presenter/remote and parent-chain evidence. Installed translation equality compares objectID without PID; it is not a safe ownership/dedup key. One review batch corrected nil children being reported as an empty list. Nil now means unknown/incomplete; actual [] remains a reported empty result. The correction peer review has no remaining finding. Its11 checks cover source text/hashes only. An owned helper, isolated build, compiled checks and native read-only checks remain before diagnostic acceptance. No target guard is relaxed. The 2 MB limit is post-encoding; the character cap is not a hard memory bound.

The remaining gesture poses, boot changes, keyboard paths, sliders, media lifecycle, batch/agent ownership, ordinary iPhone regression, power capture recovery and vendor performance comparison remain in [the coverage register](2026-10-17-duo-isolated-status.md). No raw panel-power write is part of these checks. Production rollout remains pending.
