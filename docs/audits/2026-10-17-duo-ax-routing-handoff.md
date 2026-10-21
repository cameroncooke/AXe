# Duo AX routing: native display and context findings

17 October 2026. Main remains `7163081400b59f1df40bff44f3a94dded38eea9a`. Existing source changes are preserved. No production code, commit or push was made in this slice. Full Duo parity and rollout remain open.

## Native result

The new schema-2 diagnostic records actual outgoing point parameters and raw guest display/window-context responses. Four complete read-only runs retain full native context and foreground PID brackets, unchanged fixture bytes, and actual child exits. They send no input and accept no ownership.

| Selected screen and visible point | Returned element | Raw display / context | Meaning |
|---|---|---|---|
| Outer1/0°, History icon (145,183.333) | Session, frame(94.333,52,101,90) | 1 / 3790676041 | Wrong icon; its frame excludes the requested point. |
| Outer1/0°, Session icon (145,84) | Landscape, frame(182,52,101,90) | 1 / 3790676041 | Wrong icon; its frame excludes the requested x coordinate. |
| Inner3/0°, web link (150,325) | AXLink, Open second page, PID30452, frame(57,310,181,28) | 0 / 0 | Correct visible point result. Both zero values are actual numeric responses with native error0; their meaning is unknown. |
| Inner3/0°, native Forward text (557.5,106) | AXStaticText, Forward, PID30370, frame(529.667,97,56,18) | 3 / 1065617825 | Correct point and same retained wrapper as the recursive native child. |

Both Home runs have323 recursive nodes, no truncation, four Session/History matches and13 routing receipts. All four matched occurrences report display3/context1984389622. Each duplicate pair shares its retained wrapper. The Home application root reports display0/context3790676041. These raw values expose a discrepancy; guest caches and display overrides prevent treating them as a current owner certificate.

The Home point wire sends the unchanged logical point, displayId1, no contextId, translation PID0 and client type2. The resolving mode stays0. Thus the host is not silently changing these two points or omitting the requested display. The returned point metadata alone still cannot establish correct element selection.

Each web/native run has25 recursive nodes, no truncation, two native-control matches and9 routing receipts. Native controls report display3/context1065617825; the root reports display0 with that context. The visible web link remains absent from the recursive app tree. Its presenter is30370, its parent is nil, and its separate WebContent PID is30452. Requiring every node to have a positive display/context value would reject this correct web point. No foreign-process input guard was relaxed. The current link objectID differs from the earlier read; old IDs must not be treated as current targets.

## Setup and input evidence

Normal `simctl launch` activated the existing web fixture once. This is setup, not HID proof. The frozen public hinge V2 candidate then made one unfold180 write, observed coherent inner3/0° state, and made one new guarded Back tap. PageB changed toA with exactly one native button callback and history completion. Contact17 has BEGIN/END at(111.667,106), with no held contact. The owned broker exited0. This repeats the bounded inner0 path; it adds no new pose coverage.

## Candidate and verification

Candidate root: `/private/tmp/axe-duo-ax-identity-20261017`.

- Helper `helper-v2/ax-identity-proof-v2`: SHA `1ae4cddd480df896dbf7be6753fd05c794cc4944ac1b8276ef3aee3fc69829b0`.
- Runtime seal: `c07806730108a647cd0999e70dd2fa4b2a59771d1eccba9bbbe9ea0a6cfc9771`.
- Library seal: `5da062c1c3a1fb5bf8f920aba57ad5470d6b036f8db0328a1ded33660aab16a8`.
- Read driver `run-identity-read-v2.py`: SHA `32ebcc03697146e6824937684a57275c244d24992e8bbe2d7cf86de0e47c85ad`.

Framework and helper builds pass with Xcode27.0RC for arm64. The two suites pass22 Swift Testing functions and33 expanded invocations. These cover raw numeric/point decoding, bounded immutable receipts and inherited helper checks. They do not prove native traversal limits, registry cleanup or cancellation. Four failed build/check attempts are retained. Repairs use the Swift importer method name, a valid wrong-type fixture, the verified arm64 class export, and exact Decimal validation before narrowing. The failing fractional assertion remains. Other architectures are unverified. SwiftFairy was unavailable; manual peer review was used.

Main verified1127 source files and1409 source/runtime/compiler references, with1161 unique references. Actual compiler lists contain99/95/25 Swift files. No hash mismatch or unexpected compiler path was found. Main also verified all104 [helper archive payloads](evidence/2026-10-17-duo-ax-routing-helper-v2/README.md), manifest `2ebe3fd4af54f4379987eaf80f69f2364c18d79aa8942d1357b1661b29bbd0bb`, and all261 [native archive payloads](evidence/2026-10-17-duo-ax-routing-live-v2/README.md), manifest `7de0ab11c4c7dbb8f61b17e186f2508ca3fa17d51fa85115da0dc3e6deb62e5e`.

## Exact native commands

Each diagnostic used:

    python3 -B /private/tmp/axe-duo-ax-identity-20261017/run-identity-read-v2.py --contract CONTRACT --reference REFERENCE --out UNUSED_OUTPUT_DIRECTORY

Home uses `main-v2-read-enabled.json`; web/native controls use `main-v2-web-enabled.json`. Reference/output pairs are:

- `home-visible-history-reference-v2.json` → `live-home-context-v2-1`.
- `home-visible-session-reference-v2.json` → `live-home-session-context-v2-1`.
- `web-link-reference-v2.json` → `live-web-link-context-v2-1`.
- `web-native-forward-reference-v2.json` → `live-native-forward-context-v2-1`.

Setup uses `main-activate-web-v2.py`, then the frozen `run-public-hinge-v2.py --contract outer270-enabled.json --case open-back --out main-open-web-context-v2-1`. `collect-home-reference-v2.py` and `collect-web-reference-v2.py` bracket their selected image with native context and unchanged fixture bytes. Images were inspected before point admission. Driver review corrected a live/snapshot path mix-up before any driver run.

## Explicit context comparison: negative result

The installed guest source distinguishes hosted and global hit-test coordinates. Absent context and explicit zero reach the same branch. A nonzero context can skip automatic context lookup and coordinate conversion; it is not just an owner constraint. The separate schema3 candidate compares absent, explicit zero and fresh root context3790676041. Each invocation reads root attributes12 and63 before one point request. It keeps point, display, translation PID0, token, client type and resolving mode unchanged.

All three native reads complete at the visible outer1/0° History point(145,183.333). Each returns the same wrong Session object8966841042438251283, PID16312, frame(94.333,52,101,90), which excludes the point. Each has13 complete routing receipts,323 recursive nodes, four matches, unchanged selected context/PID/app bytes and no input. An explicit fresh root context does not fix this lookup. The result does not identify the final guest branch. No global remap or ownership acceptance follows from it.

The arm64 framework/helper build and35 local functions in three suites pass, with48 expanded invocations. Thirty-six file-only driver checks pass. These are separate from native evidence. Main verified1126 final source files and1413 current source/runtime/driver references, with1177 unique files and no mismatch. Compiler lists contain99/95/25 Swift files. Main verified all92 [candidate archive payloads](evidence/2026-10-17-duo-ax-context-phase-b-candidate-v1/README.md), manifest `4e1a73638801ab7b04380b15d58877d02aa235c7bc991228b4b1362b22f59c9b`. Runtime seal: `ad812b20fb917a9097c1e43071c48a653247f6bd66c20b53ff39aab1a1386f5d`. Main also verified all149 [native comparison archive payloads](evidence/2026-10-17-duo-ax-context-phase-b-home-live-v1/README.md), manifest `031e8e4c814cc3fdd0c909c9356dbb14ac35fe0938dbda14fea4b00ee0cc57d8`.

Exact command, once per explicitly admitted mode:

    python3 -B /private/tmp/axe-duo-ax-context-phase-b-20261017/run-identity-read-v3.py --contract CONTRACT --reference /private/tmp/axe-duo-ax-context-phase-b-20261017/home-visible-history-reference-v3.json --point-context-mode MODE --out UNUSED_OUTPUT_DIRECTORY

Contracts `main-absent-enabled-v3.json`, `main-zero-enabled-v3.json` and `main-fresh-root-enabled-v3.json` map to modes `absent`, `explicitZero` and `freshRootContext`, and outputs `live-home-absent-v3-1`, `live-home-zero-v3-1` and `live-home-fresh-root-v3-1`. Main inspected the fresh selected image before admission. The first reference collection failed because the sandbox blocked CoreSimulator; its exited child and raw error remain. A separate permitted read collected `home-settled-reference-v3-2`. No diagnostic was replayed after failure.

## Home terminal record: bounded native proof

A separate Home completion candidate adds immutable terminal phase/release/drain evidence. Its experimental helper closes the old session/feed before one new native read under the same device lease. It keeps the original stale error and leaves the destination unverified. The framework/helper build and25 local functions in five suites pass, including the14 unchanged edge/barrier/schema functions. A first check compile failure and support-only correction are retained. These checks do not prove native PID admission or Home behavior.

Main verified that candidate's1127 source files and1397 source/runtime/compiler references, with1155 unique references and no mismatch. The actual compiled-helper EEXIST preflight exits2 before device work and preserves the existing directory. It uses a random nonexistent device identity and inert paths. Main also verified all86 [Home candidate archive payloads](evidence/2026-10-17-duo-home-terminal-candidate-v1/README.md), manifest `f24ee41af32a94ceb0de31540d22c5675df68c5f60eca33ca7df633ffd3405b2`. Its runtime seal is `9ab8aefc527f9d42d1ff891908c87d148bceedd676ceef68720bc2d8d47074ac`.

One new native Home run records all11 planned primitives sent, release before cleanup and a completed drain. Its final context check finds outer rotation270°→0°. The helper keeps exit2 and the original stale error. After session/feed closure, one new native read confirms the same boot, device, panel, HID/AX target, geometry, scale and hinge; only rotation changed. Destination remains unverified in the helper result. Main separately inspected the selected image and observed Home. Contact19 has BEGIN, two MOVE events and CANCEL, with no held contact or dropped trace. This proves this terminal record and one observed Home effect; it does not add a public Home command or clear the original failures.

Exact command:

    python3 -B /private/tmp/axe-duo-home-edge-completion-20261017/run-home-completion-v1.py --contract /private/tmp/axe-duo-home-edge-completion-20261017/main-home-enabled-v1.json --out /private/tmp/axe-duo-home-edge-completion-20261017/live-home-completion-v1-1

Its setup is one frozen public V2 refold followed by a fresh guarded Forward tap, pageA→B/contact18. Main verified all130 [Home live archive payloads](evidence/2026-10-17-duo-home-terminal-live-v1/README.md), manifest `15273ba906f04e796dd7b1651b360ad2541377c2d21b8e82ad2372909cd5e4a3`. All owned children and the setup broker exited. The new record makes a system transition reviewable without converting a stale result into success.

## Next isolated changes

Web owner binding still needs fresh raw presenter evidence and independent A/B/stale controls. Its separate source slice is in progress; the second normal web host remains uninstalled. It has no native acceptance. Home needs a controlled receiver/process-route experiment because adding context alone failed. The [V1 identity handoff](2026-10-17-duo-ax-identity-handoff.md) retains the vendor comparison and earlier failures. Full gesture/pose matrices, power recovery, keyboard/media/batch/agent routes, ordinary-device checks, release checks and production rollout remain open.

## Final native state

Explicit developer directory: `/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer`; iOS27.2. Device `3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463`, boot `16309:1792225249:588057`. Active outer1 UUID `B2547548-07CE-4F39-AEF6-4492B242FD7C`, rotation0°, hinge0, native1398×2034, scale3, logical466×678. Home is visible; SpringBoard PID16312. Normal web app30370 is background on pageB. No held contacts or dropped traces are recorded. All owned native children and brokers have exited. Reacquire context before the next action.
