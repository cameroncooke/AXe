# Duo current work: 22 October 2026

Full Duo support is incomplete. This report reconciles the [canonical checklist](../duo-implementation-checklist.md) with source and saved evidence. Historical passes retain their exact candidates. They do not become current full-tool proof when later code changes.

## Source and accepted work

| Scope | Current position | Recorded verification |
| --- | --- | --- |
| Main | `e9f12719`; selected wire 25 | Accepted selected-input work, optional agent mode, Homebrew helper fix and measured no-flag tap/swipe/drag are integrated. Separate local autonomous-agent edits remain outside these claims. |
| Optional `--agent` | `611f2757`; four commands only | `describe-ui`, `tap`, `type`, `swipe`: compact snapshots, immutable snapshot refs, paging, cache reuse/invalidation, fresh native admission and no-replay receipts. The integrated candidate passed 99 existing checks in 13 suites plus bounded native main input, stale refs, nested-list admission and typing/swipe fold/rotation interruptions. [Integration handoff](/Volumes/Developer/AXe/build_products/verification/agent-integration-20261021/handoff.json). |
| Homebrew helper | `f91b0aee` | An isolated formula install proved helper installation/signing, native framework loading, raw/agent input and explicit selected discovery/tap on Debug arm64 products. No global package was replaced. [Handoff](/Volumes/Developer/AXe/build_products/verification/agent-homebrew-20261021/handoff.json). |
| No-flag standalone tap | `55939716` | The candidate recorded 31 native checks: 29 positives and two changed-context zero-input rejections. Coordinate/ID taps cover seven supported poses; labels, styles, switch, polling, delays and ordinary-iPhone input have bounded proof. Four inner-landscape coordinate/ID checks passed again on the combined main binary. The 160 existing checks belong to the recorded candidate. [Handoff](/Volumes/Developer/AXe/build_products/verification/legacy-tap-20261022/HANDOFF.md). |
| No-flag swipe/drag | Integrated in `e9f12719`, from `02136849`, wire 25 | Accepted 28 bounded native cases: all seven poses, options, 125-second input, fold/rotation/SIGINT cleanup and fresh taps, ordinary-iPhone input and non-Duo rejection. Combined main passed the arm64 build, 164 existing checks in 18 suites and six affected native cases. [Acceptance report](2026-10-22-duo-legacy-paths.md), [combined-main readback](/Volumes/Developer/AXe/build_products/verification/legacy-paths-20261022/main-acceptance.json). |

The optional flag uses the existing selected owner; it is separate from `axe agent <goal>`. It needs no model or provider key. Current source limits it to the four named commands. Main tap checks boot, panel, hinge, orientation and geometry; it does not add app/PID or UI-layout freshness to ordinary input. Full out-and-back changes between equal context samples are not excluded.

## Current work order

1. **Ordinary touch down/move/up:** source and a proof tool are prepared in an isolated worktree. The unmatched-release source defect found in review is corrected; the correction review is complete. Matched native/CLI build, export, docs and simulator checks remain. Batch is unchanged.
2. **Audit improvements awaiting acceptance:** label substring/regex/frame selectors (d0a61932), keyboard visibility signals (2858a8ef), and named hinge positions (b5b7e052). None is merged. Selector and keyboard candidates build; hinge aliases have syntax/guide checks only. All need native checks and combined-main proof.
3. **Missing core/audit code:** whole-batch input ownership, remaining no-flag routes, arbitrary slider percentages, semantic switch activation, Unicode paste, wider optional-agent command support, named final orientation and independent two-finger paths.
4. **Existing code that needs wider proof:** field/control types and command options, fold/rotation combinations, inset app scenes and image-pixel conversion, power/lock/wake/system controls, capture during layout changes, ordinary iPhone/iPad regression and release packaging.

The next core item is ordinary touch, then batch. Numeric hinge setting and left/right rotation already work; named positions are convenience additions. Physical switch taps already work; semantic accessibility activation is separate. Outer upside-down remains N/A by platform design.

## Simulator incident and current limits

The old audit guest 1DF98D02-3F41-4696-A99F-42DBD4369A73 had repeated PosterBoard crashes in wallpaper-store setup. Reports predate the path change; the cause is not established. The stock replacement EEEC0A86-3285-422E-98D8-9F54DCEF09D4 reported Data Migration Failed. Both remain shut down. Earlier resource refusals and failed setup records remain valid; see the [first refusal](/Volumes/Developer/AXe/build_products/verification/legacy-paths-20261022/healthy-boot-recheck-guard/result.json) and [stopped retry](/Volumes/Developer/AXe/build_products/verification/legacy-paths-20261022/healthy-boot-recheck-guard-2/result.json).

Later serial checks used the owned control clone ECAB8383-9D82-41C4-B8C7-F02B65A33C08. It retained a migration warning, but every accepted input run kept one SpringBoard PID and recorded no new PosterBoard crash. This proves the recorded operations, not complete OS health or the old crash cause. Each owned guest was shut down after its check. The unrelated running iPhone was preserved. Cam reported that the Chrome Handoff flicker stopped after the old audit guests shut down; no global Handoff setting was changed.

Fixed limits remain app 8 GiB, all simulators 10 GiB and owned commands 4 GiB; sustained CPU limits remain simulator 1200 percent and owned commands 400 percent for 20 seconds. Native work is serial. Acceptance-run peaks were app 7.991 GiB, simulators 8.906 GiB and commands 0.147 GiB. Combined-main build/test/native runs also stayed below the limits. The crash guard's real-new-crash branch remains unverified.

## Remaining Duo capabilities and native proof

| Checklist area | Remaining work |
| --- | --- |
| D01 discovery | Complete the discovery/active-panel matrix, including other rotations and relevant library status paths. Existing boot/read-interval proof covers one pose. |
| D02 command selection/options | Complete applicable command/library parity and wider selector, role, style and pose coverage. Batch-level polling and slider polling remain unsupported. Ordinary selected tap/per-step batch waiting is already supported within D02.WAIT. |
| D03 mapping/transitions | Complete the feature/transition matrix, other hinge-driven layouts and wider held-input transitions. Accepted moving pinch/twist and retained-pair idle release stay bounded to their recorded cases. |
| D04 rotation/hinge | Extend boundary/endpoint combinations and post-dispatch cancellation/uncertain-send proof. Public left/right rotation is already integrated with seven supported positions. Outer upside-down remains N/A. |
| D05 AX lookup | Verify wider labels, values, native scalar types, roles, hosted-process content, duplicates/type filters and remaining point-query poses. |
| D06 coordinates | Prove raw/image-pixel conversions and smaller/inset app scenes across supported orientations. Named-element tap proof alone does not close this row. |
| D07 tap/hold/double-tap | Basic selected actions passed seven poses; wider selectors/styles/roles remain in D02/D05. Complete the remaining ordinary no-flag routes separately. |
| D08 paths/presets | Finish page/preset/options/transition coverage. Ordinary no-flag swipe/drag acceptance and main integration are complete within the recorded scope. The inner90 default Back preset and its shorter explicit option remain failed in their original records; longer or different explicit paths do not erase those failures. The historical final-read timeout remains RECORDED, with no reproduced AXe defect. |
| D09 multi-touch | Extend retained-pair, pinch and twist transition combinations, options and failure injection. Independent arbitrary two-finger paths remain an audit proposal. |
| D10 controls | Fix semantic switch activation if retained in scope. Selected arbitrary slider percentages need real app value-change callbacks and change/cancellation proof; the raw setters were rejected. Extend custom-control, label/no-ID/Unicode, role and pose coverage. Endpoint support and the exact-ID-prefix fix are already accepted within their recorded scope. |
| D11 keyboard | Extend native field roles, poses, data/options, blocked-EOF cancellation and focus/performance proof. Current typing uses US HID mapping. Exact OS key-up timing and an independent OS pressed-key inventory are unavailable; release receipts and recovery are bounded evidence. |
| D12 system controls | Prove supported lock, power, wake, Siri, Apple Pay and wider navigation/lifecycle routes. Home/side-button receipts and wallpaper effects do not establish security-lock or power state. Keep the failed outer Home completion/turn and strict Home latency records. Wider duration/pose/cleanup cases remain open. |
| D13 capture/media | Complete default measured active capture, backing/cache identity work, remaining poses/options/signals, input during capture, continuous fold/rotation capture, sustained performance and ordinary-device coverage. Fixed-pose PNG/MP4/streams do not close D13. Surface identity and presentation time remain unavailable. |
| D14 batch/agent | Extend supported steps, poses, options, failure stopping and full optional-agent parity. Other selected hardware buttons, retained tokens, batch semantic press and media remain unsupported. Whole-batch locking is absent. The separate autonomous agent's dirty edits have no accepted Duo execution proof here. |
| D15 cancellation | Complete the remaining command/transition/client-signal, uncertain cleanup, service-loss/reboot, crash and stale-target cases. Keep accepted per-operation ownership, quarantine and no-replay rules. |
| D16 ordinary devices | Extend current-candidate iPhone/iPad orientations, profiles, roles, options, media and cancellation. Earlier representative portrait input and current-main ordinary-iPhone swipe/drag passed; full current-candidate regression remains open. |
| D17 distribution | Complete universal/Intel/native-AX, private-export/stub/interface, distribution/signature/notarization and real release validation. Local arm64 builds and isolated Homebrew install proof do not establish a universal release. |

D07 basic taps/holds/double taps is VERIFIED. The other 16 broad groups retain their stated gaps. The checklist retains each narrow accepted result. Failed setups, RED records and unsupported cases are not converted to passes by later work elsewhere.

## Remaining sim-use proposals

The [comparison](/Volumes/Developer/AXe/build_products/verification/sim-use-review-20261021/comparison.txt) examined source at sim-use `c02295ed` against AXe `805093f1`. sim-use was not built, installed, run or benchmarked. It provides no live speed or native reliability ranking.

- Implemented since the comparison: optional compact state/reference output with live input admission, cache/invalidation reporting, structured errors/next steps and the helper installation fix. Measured active-display routing is integrated for no-flag tap, swipe and drag.
- Isolated code awaiting native acceptance: substring/regex/frame selectors; keyboard visibility signals (likelyVisible or unknown, not focus proof); named closed/tabletop/open hinge aliases. These are not current-main capabilities.
- Open proposals: Unicode paste with focus/clipboard/destination checks; candidate hints; same-app remote/empty-AX recovery comparison; Resize Mode/inset-scene checks; named final orientation; independent bounded two-finger paths; equal-workflow cold/warm resource/timing benchmarks; signature-preservation assessment and wider command error consistency.
- Deferred by the audit: local UI/tree viewer, optional video-format additions, Android/Linux and physical iOS. Existing fixed-pose H.264 MP4 recording does not establish the proposed native codec/stream/GIF work. Platform expansion requires a separate product decision.
- Rejected approaches remain rejected: cached coordinates without fresh validation, assumed scene origin, requested hinge angles reported as measured, automatic replay after uncertain delivery and unmeasured performance claims.

Security scanning remains UNVERIFIED at Cam's request. No scanner installation or upload is part of this work.

## Latest verification and checklist totals

Date: 22 October 2026. Main source e9f12719bf5d619643ff5b61ffeb62e66dbf9c3d; CLI SHA256 330916a44750ed70fef5aa7a8cbef617c5e16f6442a183b8e90f8f9089399328. The build includes the 14 preserved unrelated local file states; their content hashes still match the pre-merge record. No acceptance claim is made for the separate autonomous-agent behavior.

The combined tree passed xcrun swift build --arch arm64 --jobs 1 --skip-update under Xcode 27.0 RC with the recorded IDB checkout. The existing selected-input filter passed 164 tests in 18 suites. Exact build/test argv and guard logs are in legacy-paths-20261022/build.json, main-tests.json, main-build-guard/ and main-tests-guard/. No new test suite was added.

Against that exact staged binary, serial native checks passed inner270 swipe/drag, fold during drag, rotation during swipe, and ordinary-iPhone swipe/drag without a sibling display helper. Both interruption cases released input, then found and tapped the current button; independent tree/trace checks matched within 0.5 point. Exact commands, states and resource results are linked by [main-acceptance.json](/Volumes/Developer/AXe/build_products/verification/legacy-paths-20261022/main-acceptance.json). All six checks passed; all owned guests shut down and guarded children were reaped.

The checklist has 17 parent groups and 77 scoped subitems after adding D08.LEGACY.PATHS. Of the subitems, 68 are VERIFIED, three IMPLEMENTED, three TODO, one historical ISOLATED, one N/A and one RECORDED. These overlap and have different sizes; they are not a completion percentage. Historical candidates and failed setups remain unchanged. The earlier documentation count of 94 rows before this addition was wrong: it was 93 then, and is 94 now.

Main integration was an authorised local merge. Signing failed in 1Password; the documented unsigned fallback was used. No push. The remaining touch and audit-improvement candidates are still isolated.

Documentation validation: all eight newly added local links resolve; git diff --check passed. One unchanged historical temporary slider-label manifest link is unavailable. Its earlier result text is retained; the missing file is not treated as current evidence. See build_products/verification/legacy-paths-20261022/status-document-validation.json.
