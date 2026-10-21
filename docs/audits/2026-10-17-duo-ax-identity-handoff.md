# Duo AX identity: native findings and next fixes

17 October 2026. Production remains on main `7163081400b59f1df40bff44f3a94dded38eea9a`. Existing source changes are preserved. This slice changed no production code and made no commit or push. The full parity goal remains open.

## Result

The isolated identity probe now builds and runs. It found two distinct gaps. The visible web link is available through a selected point query in a separate process, but is absent from the returned recursive app tree. Home has both duplicate tree occurrences and a wrong point hit. A duplicate-removal rule alone would not fix Home selection.

| Check | Native result | Limit |
|---|---|---|
| Native Forward point, inner3/0° | Correct Forward StaticText, PID30370. It is the same retained wrapper as its recursive child. Full tree25 nodes, no truncation. | Read only; this did not press Forward. |
| Visible web link, inner3/0° | `AXLink`, label `Open second page`, PID30452, frame(57,310,181,28). Presenter PID30370 matches the measured app. Tree25 nodes has no link. | Parent is nil; remote PID0 and both remote flags false. Presenter alone does not authorize input. |
| FlowDeck matched tree | Four elements. It reports landscape-left, root951×669 and Forward frame(82,0,48,223). | Actual selected inner screen is0°,669×951. This is a returned-geometry mismatch, not a vendor tap failure or benchmark. |
| RocketSim matched tree | Nine elements, canvas669×951. Native Forward frame(446,82,223,48) matches AXe and the visible control. | Neither vendor tree includes the visible link. No vendor input was sent. |
| New public refold and tap | One hinge set0, coherent outer1/270° reads, then a new guarded Forward tap at(565,24). Page A changes to B. Contact15 begins and ends. | Uses the frozen public hinge V2 candidate. Other poses are not added by this case. |
| Home setup | Explicit bottom edge opens visible Home. Contact16 has BEGIN,two MOVE,CANCEL; no held contact. Outer rotation changes270°→0°. | Helper exits1 with `staleContext`, cleanup `notNeeded`, closed session,11 transport events. The effect is real; the gesture receipt remains failed. |
| Home visible History icon point | At(145,183.333), the selected query returns `Duo Session Probe`, PID16312, frame(94.333,52,101,90). That frame does not contain the requested point. | This is a wrong semantic hit. No icon tap was sent. |
| Home duplicate identity | Tree323 nodes, no truncation. History and Session each occur twice. Each pair shares its retained wrapper and PID/objectID. The selected point object differs from all four matches. | Equal recursive wrappers do not establish the active screen. All real parent reads return nil. |
| Home1.5× point experiment | The wallpaper point(217.5,275) returns a full-screen AXGroup, not History. | No support for a general1.5× correction. No transform was changed. |

All successful probe reads bracket the expected foreground PID and full native context, preserve every occurrence path, and leave the normal app state unchanged. IDs remain decimal strings, including values above the exact integer range of JSON-number consumers. They are diagnostic reads, not feature passes or ownership acceptance.

## Candidate and checks

Candidate root: `/private/tmp/axe-duo-ax-identity-20261017`.

- Helper `helper-v1/ax-identity-proof`, SHA `c249f28d7806c61b1311c7a0f4d86c51afe300aa3aaef8799e8fa02166ea61b8`.
- Runtime seal SHA `8a2e7dc986f2d4a97e8b85742f7487928903f97d08aeba3b10d4b8c910096e55`.
- Library seal SHA `5a07bfe011e5ba8bae1d4caf00322c317452415da347ec2b2017941430049e33`.
- Read driver SHA `452f16c95f8594ca54bfd87edaf3a6005850f8c77282f02b746af5529305f351`.
- Final vendor driver SHA `018dfaa51cb894b252918171eb19524561f9ea1bbf140a646c2cd5cdd0ce7fcc`.

The framework and helper builds passed with Xcode27.0RC. Ten Swift Testing functions passed in one suite, with17 expanded invocations. Their scope is helper request validation, cleanup classification, file hashing, exclusive output creation and no-input result flags. They do not prove native traversal limits, cycles, cancellation or registry cleanup. The private native wrapper cannot use the existing protocol doubles; no production test hook was added.

Review corrected two evidence faults before build: hash and decode the same bytes; create the final output directory exclusively. The original source/reviews are preserved. The first check attempt failed on an external Clang-cache write; the isolated-cache rerun passed. SwiftFairy was unavailable; manual peer review and compiled checks were used.

Main independently verified1116 source files,268 source/runtime/compiler references across252 unique files, and43 helper archive payloads. No mismatch or unexpected compiler path was found. [Helper source and checks](evidence/2026-10-17-duo-ax-identity-helper-v1/README.md). The earlier [source-only archive](evidence/2026-10-17-duo-ax-identity-source-v1/README.md) remains unchanged.

Main also independently verified all410 [native/driver/vendor archive payloads](evidence/2026-10-17-duo-ax-identity-live/README.md), manifest `dc90e5d8d4a2b2541a9f7f378fac8ae7f68b0213d99874985024c5bef33f6663`, and all20 [presenter investigation payloads](evidence/2026-10-17-duo-ax-presenter-v1/README.md), manifest `2f55cd7578506ab87faa25acc21333f7323cd69108c78b51a94e5ad15d17fdb9`. No hash mismatch was found. Private vendor outputs are excluded; the native archive uses field-allowlisted vendor trees and safe command receipts.

## Preserved setup failures

The first native-control attempt stopped before a native query: the reference hashed Python-formatted JSON while the app file used its original bytes. Parsed data was exactly equal. A separate reference uses the saved original bytes; the old failure stays recorded.

The first Home attempt also stopped before a native query. Four later `layoutChanged` callbacks changed the background app record, from count47 to51. Both records already had phase `background`; an initial explanation that called this a background transition was imprecise. `home-reference-detail.json` records the correction. A separate read-only collection then required identical app bytes and context across a new Home capture.

The first completed Home read used bundle-style filters that did not match the native identifiers, so it has zero matches. A separate read uses exact native names `Duo History Probe` and `Duo Session Probe` and finds four occurrences. Both reads preserve the wrong Session hit. No failed input was replayed; each later diagnostic is a separate read-only control.

## Vendor and presenter lessons

Static vendor evidence shows different discovery and activation policies. FlowDeck normally expands opaque containers with up to48 point probes; the inspected probe path uses display0. Its separate Duo identifier Press returns the first recursive match. RocketSim has optional remote-grid discovery using display0 and frame/PID collection filters. No safe active-Home branch or foreign-owner rule was found in these paths. The matched native reads above show why more returned elements cannot be treated as correct screen control.

The installed presenter chain was traced: host attribute0x41 maps to guest AX12010, then `_accessibilityHostPid`. WebCore forwards to the web-page object; WebProcess returns the PID of its retained registered remote element after an `ax-uuid` join. This is useful host-relation evidence. Token authentication, current scene/display membership and stale binding are still unproved. The host can cache this attribute. No input guard was relaxed.

The next web slice needs a separate normal WKWebView app with the same link label/layout, fresh A→B→A reads, and a report-only wrong-owner control. An expected-root-PID rejection is a different control; it does not prove presenter rejection. Exact request/response presence and type for the presenter attribute should be recorded before an acceptance policy is proposed.

The next Home slice must trace the selected frontmost and point paths, per-node display/context and cache lifetime. Do not apply a global scale, merge by geometry, choose the first duplicate, or press an icon from this evidence. A candidate fix must first make the point on the visible icon return that icon, then prove guarded activation after folding and rotation.

The installed guest trace now establishes a concrete routing limit. `processFrontMostApp` uses system-app attribute0x44e and does not read request parameters or display ID in that method. `processHitTest` separately reads point/display/context, can obtain a window through `contextIdForPoint:` without a display argument, then uses a hosted-context or system-wide display API. The live trace does not show which branch or context was used. This supports a narrow window/context investigation, not a proved cause or offset fix. A guest per-node `_accessibilityDisplayId` implementation exists, but its host translation route is not yet verified. Current static evidence is at `/private/tmp/axe-duo-home-ax-point-20261017/REVIEW.md`.

## Commands and final state

Each read used:

    python3 -B /private/tmp/axe-duo-ax-identity-20261017/run-identity-read.py --contract /private/tmp/axe-duo-ax-identity-20261017/main-read-enabled.json --reference REFERENCE --out UNUSED_OUTPUT_DIRECTORY

Successful reference/output pairs are `native-forward-reference-v1.1.json`→`live-native-forward-v1.1`, `web-link-reference-v1.1.json`→`live-web-link-1`, `home-history-reference-v1.1.json`→`live-home-history-v1.1`, `home-visible-history-identity-reference.json`→`live-home-visible-history-identity-1`, and `home-scale-hypothesis-reference.json`→`live-home-scale-hypothesis-1`.

Vendor reads used `run-vendor-tree-read.py --vendor flow|rocket --out UNUSED_OUTPUT_DIRECTORY`. They bracket native context and app PID, and require unchanged app bytes. Raw vendor outputs can contain preview URLs and remain excluded from archives; only reviewed safe fields may be copied.

Native environment: `/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer`, iOS27.2. Simulator `3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463`; boot `16309:1792225249:588057`. Final measured active screen is outer1, UUID `B2547548-07CE-4F39-AEF6-4492B242FD7C`, rotation0°, hinge0, native1398×2034, scale3, logical466×678. SpringBoard PID16312 remains foreground. Web app PID30370 is background on B, with no held contacts. All owned native children and brokers have exited. Reacquire context before the next action.

The [prior edge/hinge handoff](2026-10-17-duo-edge-hinge-readiness-handoff.md) retains the preceding bounded fixes. Full gestures/poses, power recovery, keyboard/media/batch/agent routes, ordinary-device regression, release checks and production rollout remain open.
