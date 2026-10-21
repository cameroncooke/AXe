# Public V3 gesture and lifecycle checks

17 October 2026. Full Duo support remains open. Production source was not changed by this batch. Main remains at `7163081400b59f1df40bff44f3a94dded38eea9a`; existing local changes were preserved. No commit or push was made.

## Candidate and scope

Selected developer directory: `/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer`. `xcodebuild -version` confirms Xcode 27.2, build 27B5038j. The recorded Duo runtime is iOS 27.2, build 24B91011. These results do not claim Xcode 27.3 coverage.

The tests use the frozen [public V3 candidate](2026-10-17-duo-v17-public-v3-handoff.md) and combined V17 library. Public executable SHA256: `a9c1efc56ddb32b437014031f3a7d85fe1f01d8b5556c421512aa3e8ae9a2c2e`. Public runtime seal: `dcd1b34259f83d1bb34318def23016f97557c0cd0c31da20cd2b08565649a6ba`. Main checked all 24 runtime files again, with no mismatch. No runtime rebuild occurred during this batch.

The selected path uses explicit screen ID/UUID, measured geometry and boot identity. AX reads also use the expected app PID and explicit `--ax-preparation existing-bridge`. These checks do not clear the separate automation-session bootstrap failure or establish first-use behavior on a clean device.

## Completed checks

| Check | Actual result |
|---|---|
| Stale width and height | Both commands reject before input. Fixture state is unchanged. |
| Outer 0° list swipe and drag | Public V3 moves the list +75 then −75 points. Main page and slider stay unchanged. Exact contact endpoints and release are confirmed. |
| Held refold and unfold | The original broker rejects the stale token with zero new action events. The guest had already cancelled each contact before rejection. Cleanup drains. |
| Held inner rotation 90° to 0° | Stale token rejected with zero new action events. The guest END follows the checkpoint, with coordinates transformed into the new orientation. No new BEGIN or MOVE is added. |
| Idle expiry | One held contact ends after 30.204 seconds in the guest trace. Cleanup and owned broker exit are confirmed. This is one sample, not a hard timing guarantee. |
| Lost response | One request is sent and its reply is not read. The contact ends after 30.182 seconds. Client outcome remains unknown; no replay occurs. |
| Canvas down/left/right presets, inner 0° | Actual offsets change on the intended axis only. Each pair of settled states at 5 and 5.6 seconds agrees. |
| Native back at one second, inner 0° | Both the explicit path from X1 and the named preset from X20 return to the canvas. Navigation depth changes from 2 to 1; fresh selected AX agrees; contacts end. The default remains unchanged. |

Every completed run above has zero active contacts at its final observation. Owned brokers exit 0 and are reaped before another test starts.

## Preserved failures

The first held-unfold driver overwrote the Apple display JSON with its own command receipt. It stopped before sending a stale request. V3.2 changes only the output filename. A local regression check reproduces the old collision and confirms separate outputs. The original source and failed run remain in the archive.

A FlowDeck portrait request returned without a measured panel rotation. No stale request ran. A separate landscape-left request produced the measured inner 90° to 0° transition. Device orientation labels do not establish the active panel coordinate transform.

The original canvas scroll-up path was delivered and moved the canvas +310.333 points, but the test required settlement after 0.6 seconds. UIKit was still decelerating then. The state was settled at 5 seconds and unchanged after broker exit. The failed verdict remains. A separate V1.1 driver checks motion at 0.6 seconds and requires matching settled states at 5 and 5.6 seconds. This changes the test rule, not AXe.

The unchanged back preset starts 20 points from the left edge. It delivered one complete contact to the detail page, but navigation stayed at depth 2. This is a real missing UI effect, despite successful transport. A separate X1 start at the same 0.3-second duration also fails. Changing only that explicit path duration to one second passes. The named preset with its original X20 start also passes with `--duration 1.0`. All use delta 50 and 13 movement steps. These are bounded override results, not acceptance of a changed default. The first MOVE in the failed paths is already far from the start; later delivery and recognizer timing remain under investigation. No matched FlowDeck back test ran. Its prepared wrapper is marked unrun.

## Commands and evidence

- [Geometry rejection](evidence/2026-10-17-duo-public-geometry-v3/README.md): `/private/tmp/axe-duo-broker-v3-20261017/run-public-proof.py` with `/private/tmp/axe-duo-public-geometry-v3-20261017` contracts and results. Main verified all 43 archive payload hashes; manifest SHA256 `fddb7c81afebcf613150e9fd74e596a7c45e4b719b20eb99ec4077f3f086cbb8`.
- [List swipe and drag](evidence/2026-10-17-duo-public-list-outer0-v3/README.md): `/private/tmp/axe-duo-public-gestures-v3-20261017/run-public-gesture.py`. Manifest SHA256 `7fbf94fb150e86e6a0215d2a0710eeb5b8c5f2a839e6961b1ef91bf75871cb68`; all 64 payload hashes checked by main.
- [Lifecycle](evidence/2026-10-17-duo-public-lifecycle-v3/README.md): `/private/tmp/axe-duo-public-lifecycle-v3-20261017/run-public-lifecycle-v3.2.py --contract PATH --out NEW_DIRECTORY`. The original V3 driver ran expiry and lost response. V3.1 retains the failed output collision. Exact argv and receipts are archived. Manifest SHA256 `84f1ebfe5699b19a257c3a0d1c829c7354c3f229b32dd102f03793a7e88fde59`; all 311 payload hashes checked by main.
- [Preset and back-navigation evidence](evidence/2026-10-17-duo-public-presets-v3/README.md): eight runs, five bounded passes and three preserved failures. Main verified all 416 payload hashes. Manifest SHA256 `10d265482fa1513dcbb2e304dfdb78b597e4b1f2593f88d0b0fb68b3a1850914`. Preset driver: `python3 -B /private/tmp/axe-duo-preset-fixture-20261017/run-preset-v1.1.py --contract /private/tmp/axe-duo-preset-live-v3-20261017/inner0-contract.json --case CASE --out NEW_DIRECTORY`. Cases: `scroll-down`, `scroll-left`, `scroll-right`, `native-back`. Original `scroll-up` uses V1.
- Separate edge diagnostic: `python3 -B /private/tmp/axe-duo-preset-fixture-20261017/run-edge-start-diagnostic-v1.py --contract /private/tmp/axe-duo-preset-live-v3-20261017/inner0-contract.json --case native-back --out /private/tmp/axe-duo-preset-live-v3-20261017/live-edge-start-1-v1`.

The duration-only explicit check uses `run-edge-duration-diagnostic-v2.py` with output `live-edge-duration-1-v2`. The named-preset check uses `run-preset-duration-diagnostic-v2.py` with output `live-native-back-duration1-v2`; both use the same `--contract` and `--case native-back` arguments above. All three diagnostic drivers are under `/private/tmp/axe-duo-preset-fixture-20261017`. Each new run has a new output directory and awaits its owned broker.

The normal UIKit fixture has a two-axis canvas, visible Center canvas and Open detail controls, and standard native back navigation. It has no hidden control route or injected app state. Source SHA256 `301c5577a73c461d02632504b44b60db0a1b44943a8d4781b30e90cc8f77752b`; binary SHA256 `73a11c59772d331a1bd16e0e992d0ee936f35e52e6e7cfb5baa28859bc348e9b`. The corrected source only adds the required nonatomic/strong declaration to SceneDelegate.window. Build, plist and signature checks pass without compiler warnings.

## Device and remaining work

Audit UDID: `3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463`. Boot: `16309:1792225249:588057`. Latest measured panel: inner 3, UUID `769ED878-389B-4346-9C56-CB0703AB3E58`, rotation 0°, hinge 180°, logical 669×951. Foreground preset fixture: `com.camsoft.duo-preset-probe`, PID 36111. Older v6 fixture PID 32539 remains installed. Final visible state is Gesture canvas, navigation depth 1, with zero active contacts and zero dropped trace events. The post-exit state exactly matches the final 5.6-second observation. Re-read all identities and UI state before new input.

Open work includes wider proof and a candidate fix for the back-preset default, forward navigation, top/bottom system gestures, boot-change cleanup, other pose matrices, two original inner 270° recognition failures, public hinge integration, visible panel-power recovery, keyboard freshness, media transitions, batch/agent ownership, ordinary-phone regression and matched vendor performance. See [current coverage](2026-10-17-duo-isolated-status.md). Full skill-check also remains incomplete because its security runner is unavailable.
