# Duo current work: 22 October 2026

Full Duo support is incomplete. This report reconciles the [canonical checklist](../duo-implementation-checklist.md) with source and saved evidence. Historical passes retain their exact candidates. They do not become current full-tool proof when later code changes.

## Source and accepted work

| Scope | Current position | Recorded verification |
| --- | --- | --- |
| Main | `55939716`; selected wire 24 | Accepted selected-input work, optional agent mode, Homebrew helper fix and measured no-flag standalone tap are integrated. Separate local autonomous-agent edits remain outside these claims. |
| Optional `--agent` | `611f2757`; four commands only | `describe-ui`, `tap`, `type`, `swipe`: compact snapshots, immutable snapshot refs, paging, cache reuse/invalidation, fresh native admission and no-replay receipts. The integrated candidate passed 99 existing checks in 13 suites plus bounded native main input, stale refs, nested-list admission and typing/swipe fold/rotation interruptions. [Integration handoff](/Volumes/Developer/AXe/build_products/verification/agent-integration-20261021/handoff.json). |
| Homebrew helper | `f91b0aee` | An isolated formula install proved helper installation/signing, native framework loading, raw/agent input and explicit selected discovery/tap on Debug arm64 products. No global package was replaced. [Handoff](/Volumes/Developer/AXe/build_products/verification/agent-homebrew-20261021/handoff.json). |
| No-flag standalone tap | `55939716` | The candidate recorded 31 native checks: 29 positives and two changed-context zero-input rejections. Coordinate/ID taps cover seven supported poses; labels, styles, switch, polling, delays and ordinary-iPhone input have bounded proof. Four inner-landscape coordinate/ID checks passed again on the combined main binary. The 160 existing checks belong to the recorded candidate. [Handoff](/Volumes/Developer/AXe/build_products/verification/legacy-tap-20261022/HANDOFF.md). |
| No-flag swipe/drag | Isolated `02136849`, wire 25, based on main `55939716` | Source/build review and 164 existing checks in 18 suites passed. Saved cases show movement/release in seven poses and bounded large/long paths. PosterBoard crashes during that guest session prevent stable-simulator acceptance. Not merged. [Checkpoint report](/Volumes/Developer/AXe/build_products/verification/legacy-paths-20261022/audit-report.md). |

The optional flag uses the existing selected owner; it is separate from `axe agent <goal>`. It needs no model or provider key. Current source limits it to the four named commands. Main tap checks boot, panel, hinge, orientation and geometry; it does not add app/PID or UI-layout freshness to ordinary input. Full out-and-back changes between equal context samples are not excluded.

## Immediate continuation and blocker

Native continuation needs both a healthy owned Duo and resource headroom. The old guest `1DF98D02-3F41-4696-A99F-42DBD4369A73` had repeated PosterBoard `EXC_BREAKPOINT` reports in wallpaper-store setup. Reports predate the swipe/drag candidate. The exact bad file and cause are unknown. The stock replacement `EEEC0A86-3285-422E-98D8-9F54DCEF09D4` reported `Data Migration Failed`; a short crash-free idle interval did not establish a healthy boot.

On 22 October, the first health recheck did not launch: app footprint 8.001 GiB exceeded the fixed 8 GiB limit, `pid` was null and the guard recorded `RESOURCE_LIMIT_BEFORE_LAUNCH`. When headroom briefly returned, one guarded retry started. Its second stock-guest boot again ended at terminal status 3, `Data Migration Failed`, despite exit 0. The guard then stopped at app footprint 8.013 GiB with `MEMORY_LIMIT`, sent SIGINT and reaped its child. The guest was shut down. No AXe or fixture was launched. No further boot is planned in this pass. [First refusal](/Volumes/Developer/AXe/build_products/verification/legacy-paths-20261022/healthy-boot-recheck-guard/result.json), [boot readback](/Volumes/Developer/AXe/build_products/verification/legacy-paths-20261022/healthy-boot-recheck.json), [latest stop](/Volumes/Developer/AXe/build_products/verification/legacy-paths-20261022/healthy-boot-recheck-guard-2/result.json).

The fixed limits remain app 8 GiB, all simulator processes 10 GiB and owned commands 4 GiB; sustained CPU limits remain simulator 1200 percent and owned commands 400 percent for 20 seconds. CPU/memory guards did not detect the earlier service crash loop. The crash-aware guard's first-new-crash branch still lacks a real-crash check.

Before main integration, the isolated no-flag swipe/drag change still needs:

1. Acceptance on a healthy simulator, including a path longer than the prior 120-second response wait. The new duration-plus-120-second wait has source/build review only.
2. Fold, rotation and client-signal interruption with actual release, no replay, then fresh discovery and a real named-element effect.
3. Ordinary-device compatibility and direct-wire rejection of non-Duo requests.
4. Review of the complete intended main diff, combined-tree build and affected native proof after integration. Preserve the unrelated local edits.

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
| D08 paths/presets | Finish page/preset/options/transition coverage and the isolated no-flag path acceptance above. The inner90 default Back preset and its shorter explicit option remain failed in their original records; longer or different explicit paths do not erase those failures. The historical final-read timeout remains RECORDED, with no reproduced AXe defect. |
| D09 multi-touch | Extend retained-pair, pinch and twist transition combinations, options and failure injection. Independent arbitrary two-finger paths remain an audit proposal. |
| D10 controls | Fix semantic switch activation if retained in scope. Selected arbitrary slider percentages need real app value-change callbacks and change/cancellation proof; the raw setters were rejected. Extend custom-control, label/no-ID/Unicode, role and pose coverage. Endpoint support and the exact-ID-prefix fix are already accepted within their recorded scope. |
| D11 keyboard | Extend native field roles, poses, data/options, blocked-EOF cancellation and focus/performance proof. Current typing uses US HID mapping. Exact OS key-up timing and an independent OS pressed-key inventory are unavailable; release receipts and recovery are bounded evidence. |
| D12 system controls | Prove supported lock, power, wake, Siri, Apple Pay and wider navigation/lifecycle routes. Home/side-button receipts and wallpaper effects do not establish security-lock or power state. Keep the failed outer Home completion/turn and strict Home latency records. Wider duration/pose/cleanup cases remain open. |
| D13 capture/media | Complete default measured active capture, backing/cache identity work, remaining poses/options/signals, input during capture, continuous fold/rotation capture, sustained performance and ordinary-device coverage. Fixed-pose PNG/MP4/streams do not close D13. Surface identity and presentation time remain unavailable. |
| D14 batch/agent | Extend supported steps, poses, options, failure stopping and full optional-agent parity. Other selected hardware buttons, retained tokens, batch semantic press and media remain unsupported. Whole-batch locking is absent. The separate autonomous agent's dirty edits have no accepted Duo execution proof here. |
| D15 cancellation | Complete the remaining command/transition/client-signal, uncertain cleanup, service-loss/reboot, crash and stale-target cases. Keep accepted per-operation ownership, quarantine and no-replay rules. |
| D16 ordinary devices | Extend current-candidate iPhone/iPad orientations, profiles, roles, options, media and cancellation. Earlier representative portrait input passed; it is not full regression or proof for the isolated new path. |
| D17 distribution | Complete universal/Intel/native-AX, private-export/stub/interface, distribution/signature/notarization and real release validation. Local arm64 builds and isolated Homebrew install proof do not establish a universal release. |

All broad parent rows remain open. The checklist retains each narrow accepted result. Failed setups, RED records and unsupported cases are not converted to passes by later work elsewhere.

## Remaining sim-use proposals

The [comparison](/Volumes/Developer/AXe/build_products/verification/sim-use-review-20261021/comparison.txt) examined source at sim-use `c02295ed` against AXe `805093f1`. sim-use was not built, installed, run or benchmarked. It provides no live speed or native reliability ranking.

- Implemented since the comparison: optional compact state/reference output with live input admission, cache/invalidation reporting, structured errors/next steps and the helper installation fix. Automatic active-display routing is partly addressed by the later no-flag tap and isolated path work.
- Open proposals: Unicode paste with focus/clipboard/destination checks; explicit keyboard-state readback; substring/regex/frame selectors and candidate hints; same-app remote/empty-AX recovery comparison; Resize Mode/inset-scene checks; named final orientation/fold aliases; independent bounded two-finger paths; equal-workflow cold/warm resource/timing benchmarks; signature-preservation assessment and wider command error consistency.
- Deferred by the audit: local UI/tree viewer, optional video-format additions, Android/Linux and physical iOS. Existing fixed-pose H.264 MP4 recording does not establish the proposed native codec/stream/GIF work. Platform expansion requires a separate product decision.
- Rejected approaches remain rejected: cached coordinates without fresh validation, assumed scene origin, requested hinge angles reported as measured, automatic replay after uncertain delivery and unmeasured performance claims.

Security scanning remains UNVERIFIED at Cam's request. No scanner installation or upload is part of this work.

## Verification of this documentation update

Source review date: 22 October 2026. Read main branch/HEAD/status with `git branch --show-current`, `git rev-parse --short HEAD` and `git status --short`; inspected `git show --stat --oneline 611f2757`, `55939716` and isolated `02136849`, registered commands/options, saved handoffs and the full canonical checklist. Main was `55939716`; isolated branch `codex/agent-mode` was `02136849`.

This update ran no AXe input, simulator, app, build or test. Recorded native commands/results remain in the linked handoffs. The coordinator's separate health-boot retry is stated above. `git diff --check -- docs/duo-implementation-checklist.md docs/audits/2026-10-22-duo-current-work.md` passed. Read-only Python checks confirmed valid new local links, unchanged status labels for all 94 capability rows and byte-identical historical result text from `Latest integrated verification` to EOF. No commit or push ran.
