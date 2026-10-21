# Duo moving rotation and outer landscape checks

Date: 21 October 2026. Seven native cases passed on the unchanged product candidate. Two moving twists stopped after an external device change, released both contacts, then passed a fresh named-button tap. Five complete single-contact gesture cases passed at closed outer270. These results do not close the full D07 or D09 rows.

## Candidate and scope

- Base: f8bb51e9d64e87914fe020d6afff24c5c2ed2ace. Branch: codex/duo-gestures. Product source and binaries were not changed.
- Frozen canonical CLI SHA256: 5f4e71958447de644fea1e2a2844518d7b177598e9050393cd56374e039e17c4.
- FBSimulatorControl SHA256: 8a614ab3116b3d0b88e21086d8a16d0f39aa06f672dd92123b7fd00e7526b779. Wire21; local Debug arm64.
- Original audit Duo: 3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463, profile405, iOS27.2, normal UIKit fixture version6.
- Accepted boot70028:1792577143:92116, app PID70970. These identities are historical after shutdown.
- 89 product/runtime files remained byte-identical to the preceding held-input and moving-pinch candidate. Seven tool files are saved and pinned separately.

## Moving twists interrupted by device changes

Both public gesture rotate commands requested six seconds, radius40 and spacing0.5. Each planned129 normal pair events. Before changing the device, the driver required two real contacts inside feature.pad, each moved more than two points along opposite circular arcs. It verified constant radius, direction and progress from the actual window trace.

| Saved case | Device change | Result |
| --- | --- | --- |
| rotation-fold | Clockwise90-degree twist at inner90, hinge180. External close to0 selects outer0. | Stopped after19 of129 normal events. Owned pair release confirmed. Fresh exact-ID/PID feature.tap caused one real button callback. |
| rotation-device-v2 | Anticlockwise90-degree twist at outer0, hinge0. External turn selects outer90. | Stopped after17 of129 normal events. Owned pair release confirmed. Fresh exact-ID/PID feature.tap caused one real button callback. |

Both receipts report failedNoReplay, staleContext and releaseEnqueuedAndDrained, without quarantine. Both original contact IDs ended or cancelled before reaching the old endpoint. No contact remained held. A half-second settled observation showed no new old-gesture touch events. The subsequent tap read current displays and the current accessibility tree, checked the fixture PID and feature.tap identity, caused exactly one callback and released its own contact. Actual tap points were within0.5 logical points of the validated point.

The app trace ended about0.51/0.72 seconds after the external change request started. These are app-contact observations, not measured AXe send timestamps or worst-case latency guarantees. UIKit can cancel app touches during device changes; AXe cleanup is separately established by the owned-release receipts.

The unchanged isolated external-change tool sends hinge/orientation commands, not touches. It represents a person changing the simulator during an AXe action. It does not add a hidden production route around input ownership.

## Complete gestures at closed outer270

A public rotate-right operation reached outer270 with two matching observations. The unchanged strict scripts/verify-duo-input.py then passed five independent cases:

| Case | Observed effect |
| --- | --- |
| pad-tap | padTap callback0 to1; one complete stationary contact. |
| hold | longPress callback0 to1; contact held at least0.5 seconds, then released. |
| double-tap | doubleTap callback0 to1; two ordered, fully released contacts. |
| swipe | pan callback0 to1; complete ordered80-point horizontal path. |
| drag | pan callback1 to2; complete ordered80-point horizontal path. |

Each case verified fresh selected geometry, exact app PID/container, full window and recognizer traces, unchanged other controls, final accessibility frames/context and zero held contacts. These are coordinate/gesture-pad effects, not named-button or scroll-view effects. No input was repeated after an uncertain outcome.

## Tools and verification

Evidence root: /Volumes/Developer/AXe/build_products/verification/moving-rotation-20261021.

The candidate manifest saves89 source/runtime pins and seven tools, including the unchanged complete-gesture grader, external-state tool and shared resource guard. Raw folders contain exact commands, process exits, native state changes, contact traces, accessibility descriptions, cleanup receipts, button effects and CPU/memory samples.

Native driver: scripts/verify-duo-moving-rotation.py. Saved-data verifier: scripts/check-duo-moving-rotation-evidence.py. The verifier sends no input. It checks hashes, both interruption receipts/contact paths, fresh actual button effects and re-runs the strict complete-gesture grader against saved outer270 state.

Latest exact verification command, exit0:

    /usr/bin/python3 -B build_products/verification/moving-rotation-20261021/verify.py --current --evidence-root /Volumes/Developer/AXe/build_products/verification/moving-rotation-20261021

When run from this worktree, use the committed saved-data verifier with the same absolute evidence-root. Source/runtime pins refer to the frozen canonical candidate in /Volumes/Developer/AXe. This turn did not build or overwrite shared frameworks.

Two failed setup/tool records remain separate:

- Initial boot exited0, but its final top process sample timed out after10 seconds. The guest was shut down under a working guard before a new boot. This was a monitor failure; no memory/CPU threshold or input failure was observed.
- rotation-device used separate negative-angle arguments. ArgumentParser rejected the command before touch input. The driver changed to --degrees=-90 and the new rotation-device-v2 case passed. The failed folder remains failed.

## Resource control and handoff

This worker sent only one owned action at a time. Other assigned guests ran in parallel. The shared guard measured combined ChatGPT/Codex memory and all simulator processes. Limits:8GiB app group,10GiB all simulators combined,4GiB owned commands; simulator1200percent or owned400percent CPU for20 seconds. The extra continuous global sampler was stopped by the coordinator after the initial sampling failure.

Samples collected by this worker peaked at5.822GiB app,8.108GiB global simulator memory and982.3percent global simulator CPU. No threshold stop occurred. The coordinator paused this worker to leave memory for the other guest. Its last owned command completed, then A shut down successfully. The final catalogue excludes the assigned audit UDID; another worker's guest remains. Final global sample: app5.520GiB, simulator4.611GiB/0.5percent CPU. These totals include other workers; they are not per-guest peak estimates.

Remaining in this workstream: outer270 pinch, twist, two-finger tap/hold and nested scrolling both ways. Nested scrolling requires exposing the list through normal page input first. Further pose/change combinations, retained pairs, held native keys/buttons, cleanup failure injection, ordinary devices and release packaging remain outside these seven passes. No complete parity, atomic OS change/send or worst-case latency claim is made.

The product candidate is unchanged. Only this report and verification scripts are committed in the isolated workstream. No push or security upload. Security scanning remains UNVERIFIED per Cam.
