# Duo rotation control: 20 October 2026

The local library and CLI now provide `axe rotate left|right`. The command passed native checks in all four inner-screen positions and all three supported outer-screen positions. Each check found `feature.tap` again and produced one real button action.

This closes D04.ROTATION for the verified Duo profile. It does not close the full Duo checklist.

## Candidate

- Main HEAD: `7163081400b59f1df40bff44f3a94dded38eea9a`, with local changes. No commit or push.
- CLI SHA256: `5441d46707e1444ad00bb7b1c5e5830e157a124777fff2588b0c8c22bb4d63d3`.
- FBSimulatorControl SHA256: `2c0fafdf17ed118aac26d273b6834dba4a6dce82d04f5fd703b6f88961292563`.
- Selected protocol version: 21. Version 20 requests reject.
- IDB base: `604c51013438f0c3603b720a05a44b7c5b8f286d` plus the tracked foundation patch.
- Runtime: Xcode 27.2 Beta 3, iOS 27.2, Duo profile 405. Build: Xcode 27.0 RC, Debug arm64, two jobs.
- One audit simulator, one version 6 UIKit fixture, boot `87985:1792505859:26169`, app PID `88398`.

The manifest saves 90 source/runtime files and three verification tools. Their hashes and saved copies identify the accepted candidate. Existing Debug text interfaces were not refreshed. These artifacts have no release or universal-build acceptance.

## Command and ownership

```bash
axe list-simulators --displays --udid <UDID>
axe rotate right --udid <UDID> --screen-id <ID> \
  --screen-uuid <UUID> --expected-boot <BOOT_ID>
```

Both screen fields and the fresh boot identity are required. `--timeout` sets the observation budget from 0.5 to 15 seconds, with default 8. Native reads have separate bounds.

Rotation changes the whole device. The selected screen is used to check the request and result. It does not rotate one screen independently. This command is separate from the two-finger `gesture rotate`; it is not a batch step.

The command uses the same owner and device lock as other selected input. It rejects held touches. It sends one vendor event, waits for two equal selected-screen observations, closes the connection, waits 250 milliseconds, then checks the position again. It does not replay a write. An uncertain result retains the device lock and saves a recovery record.

Read the accessibility tree again before the next action. The receipt proves selected-screen rotation, not that every app animation or layout change is complete.

## Reference and mapping

The earlier audit found the [public hinge code sample](https://github.com/artemnovichkov/hinge/pull/1), pinned at `1b3713c3bd293a29d95bcc0c65f4403348838269`. The owned isolated tool proved its orientation event before library integration. The event uses the existing vendor HID service and envelope, with source `orientation-picker-control` and type `enum`. The hinge source remains `hinge-slider-control` with type `range`.

Vendor names describe physical device orientation. They differ from inner-screen UI angles:

| Vendor value | Inner UI angle | Outer UI angle |
| --- | ---: | ---: |
| portrait | 90 | 0 |
| landscape-right | 180 | 90 |
| pud | 270 | N/A |
| landscape-left | 0 | 270 |

Right follows inner UI 0, 90, 180, 270, then 0. Outer follows 0, 90, 270, then 0. Left reverses the order. The outer screen skips upside-down portrait under the recorded Apple policy. Mapping is limited to the verified Duo profile.

## Native results

| Screen | Direction | Before | After | Real button actions |
| --- | --- | ---: | ---: | ---: |
| Outer | left | 90 | 0 | 1 |
| Outer | left | 0 | 270 | 1 |
| Outer | left | 270 | 90 | 1 |
| Inner | right | 180 | 270 | 1 |
| Inner | right | 270 | 0 | 1 |
| Inner | right | 0 | 90 | 1 |
| Inner | right | 90 | 180 | 1 |

Each tap used the current ID, PID, frame and selected-screen context. The actual contact landed within 0.5 logical points of the validated point. Each contact released. Other controls and frames stayed equal within each tap check. Rotation itself sent no touch events. A separate outer right rotation also passed; its following tap stopped before input at the existing AX admission deadline and is not counted as a successful tap.

Three rejection checks passed: old boot identity, inactive screen and rotation during a real held touch. The owned touch then released. The existing hinge command opened from 0 to 180 degrees and confirmed active inner-screen readiness.

## Findings and retained failures

The first integrated rotation found a temporary `selectedRotationMismatch` between the guest and active-panel readers. The command sent one event, stopped and saved an uncertainty record. The simulator was shut down and the owned broker stopped before that record was archived. The fix permits another read only for that typed mismatch with confirmed child exit. It sends no second rotation event. The final seven cases passed with this fix.

One tap hit its existing AX admission deadline before input. One negative-check attempt reached an idle broker's busy rejection. Both records remain failed observations. Later separate checks passed. Neither observation caused a timeout increase, fallback or speculative input fix. The earlier final hinge-read timeout remains a historical observation, with no reproduced AXe defect.

## Verification and limits

All 108 focused checks in 11 suites passed. Exact build/test arguments, exits and resource samples are saved in the evidence folders' `started.json` and `result.json`. Source setup passed with `AXE_BUILD_ARCHS=arm64 scripts/build.sh setup`. Both skill copies passed pinned skill-check 1.2.0 and the official quick validator. Security scanning stayed UNVERIFIED, as requested.

Run the saved-data verifier from the repository root. It sends no simulator input:

```bash
/usr/bin/python3 -B build_products/verification/rotation-capability-20261020/verify-integrated.py --current
```

Without `--current`, it checks saved candidate copies. Evidence: [result](/Volumes/Developer/AXe/build_products/verification/rotation-capability-20261020/integrated-result.json), [manifest](/Volumes/Developer/AXe/build_products/verification/rotation-capability-20261020/integrated-candidate.json), [verifier](/Volumes/Developer/AXe/build_products/verification/rotation-capability-20261020/verify-integrated.py).

The sampled simulator peak was 3.938 GiB; the ChatGPT group peak was 4.495 GiB. No resource stop occurred. All owned commands were reaped. Final discovery showed no booted guests. Simulator support used 0.494 GiB and 0.2% CPU. The already-running Device Hub process was left unchanged.

Remaining scope: external folding or rotation during held gestures, cancellation after dispatch, other device profiles, wider control/option coverage and release packaging. The next core check is input during a device change, followed by a fresh screen read and accessibility query.
