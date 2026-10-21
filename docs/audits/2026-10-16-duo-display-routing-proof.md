# Duo display routing: mapping and live tap proof

Date: 16 October 2026. Investigation on main, HEAD 7163081400b59f1df40bff44f3a94dded38eea9a, with existing dirty source preserved. No production implementation, dependency update, automated test target, commit, or push was made.

## Result

An isolated diagnostic using AXe's existing private DTU wire format tapped the intended panel after opening, partial folding, refolding, and all four measured inner-display rotations. Seven primary General → About transitions passed. Two wrong-target controls returned successful transport sends but left General unchanged. Before/after PNGs were independently inspected; success is not based on command exit status alone.

This proves a usable routing mechanism. It does not mean the current axe tap command has been repaired. The diagnostic accepts an explicit target and normalized coordinates; AXe production still supplies its current target and geometry assumptions.

## ID mapping

| Identifier | Outer panel in this run | Inner panel in this run | Meaning |
|---|---|---|---|
| CoreSimulator Screen ID | 1 | 3 | Enumerated by simctl io enumerate. |
| Guest CADisplay.displayId | 1 | 3 | Matched to host screens by uniqueId, name, and dimensions. |
| Modern DTU event target | 1 | 3 | Direct display ID, passed unchanged in payload.target. |
| AX point-query displayId | 1 | 3 | Selects the matching panel when the point is in native display coordinates. |
| AX frontmost-query displayId | Not a reliable panel selector | Not a reliable panel selector | 0, 1, 3, and invalid 99 all returned the active Settings app in these checks. |

The outer UUID was 2E7A2537-1137-44FE-BCFA-D71824EA2094; the inner UUID was 5C58004D-F34C-4EAE-9765-CA0EC3B4B4E7. Both matched host and guest enumeration within this boot. Outer pixels were 1398 × 2034, inner pixels 2007 × 2853, with UI scale 3. These values are observed evidence, not constants for implementation. Re-enumerate on each device/boot.

**Target 0 does not mean active display.** Apple's current dtuhidd maps target 0 to mainTouchscreen service 0x101. Explicit target 1 maps to that same service. Explicit target 3 maps to 0x103. Send the display ID as the event target; do not send the service ID or the legacy 0x40000000 screen mask.

The current DTU target enum accepts values 0 through 10. Its registration loop builds touchscreen services from CADisplay.displayId and uniqueId. This modern path is distinct from the legacy Indigo registration/mask path. The current implementation still identifies the outer CADisplay as main while Duo is open.

Evidence: [host enumeration](evidence/2026-10-16-duo/routing/open-enumerate.json), [guest enumeration](evidence/2026-10-16-duo/routing/open-cadisplays.json), [Apple instruction trace](evidence/2026-10-16-duo/routing/apple/findings.md), and [bounded Apple excerpts](evidence/2026-10-16-duo/routing/apple/target-mapping-excerpts.txt).

## Competitor implementation references

FlowDeck's complete decoded call chain is metadata.screenID → Geometry.target → tap → sendTouch → digitizer → xpc_dictionary_set_uint64(payload, target). Its Duo path passes 1 or 3 directly, without the legacy mask. It normalizes against panel geometry and applies a separate rotation. Its panel-selection code uses a hinge threshold of 28 degrees and validates panel availability. That threshold is vendor logic, not an Apple contract and not a recommended AXe constant.

RocketSim's inspected IDB touch path still initializes target to 0 and normalizes with cached main-screen geometry. It has multi-screen capture APIs, but those do not establish multi-screen touch routing. This concrete path is consistent with the earlier open-Duo tap failure; it does not establish that every RocketSim action uses this path.

Both bundled IDB frontmost AX paths query display 0. FlowDeck then adjusts root geometry to its selected panel. AXe must not infer that it can select an independent accessibility tree by changing only the frontmost query parameter.

See [decoded vendor instructions and binary hashes](evidence/2026-10-16-duo/routing/binary-routing-findings.md). Bounded assembly snippets are retained beside that report; large full disassemblies are not copied into the repository.

## Accessibility: frontmost and point queries differ

The revised diagnostic records the actual AXPTranslatorRequest parameters. Frontmost requests forwarded displayId 1, 3, and 99, each returned responseError 0, and each resolved the same active Settings app. This is not proof of panel-specific frontmost lookup.

Point queries did select panels:

| State and native point | AX display ID | Observed result |
|---|---|---|
| Open, inner rot0, About at (459.5, 386.6667) | 3 | About, Settings PID 13281, identifier com.apple.settings.general.about. |
| Same state and point | 0 or 1 | Other process PID 13052, outer display-sized root 1398 × 2034; not About. |
| Same state and point | 99 | No translation object; diagnostic exit 1. |
| Refolded closed, About at (201, 364.6667) | 0 or 1 | About on the outer panel, Settings PID 13281. |
| Same closed state and point | 3 | Other process PID 13052, inner display-sized root 2007 × 2853; not About. |

Point lookup also requires coordinate conversion. With inner rot180, passing the raw app activation point returned Search. With inner rot270, the raw point returned an unnamed object; its transformed native point returned About. At partial hinge and rot90, the transformed point also returned About. A final check after reboot confirmed that the transformed rot180 point (209.5, 564.3333), with AX displayId 3, returned About. A raw frame centre is not a valid native point in every rotation.

Do not treat a frontmost tree's root bounds as the display dimensions. The raw inner Settings root remained 669 × 951 even while child frames described the 951 × 669 layout. The measured display geometry and individual element activation points were used instead.

Evidence examples: open-v3-ax-1/3/99.json, open-left-hit-0/1/3/99.json, open-right-hit3.json, final180-hit-native.json, open-upside-hit-raw/native.json, partial-hit3.json, and refold-hit-0/1/3.json in [routing evidence](evidence/2026-10-16-duo/routing/).

## Coordinate conversion proved in Settings

Let W and H be the selected panel's unrotated pixel bounds divided by its measured UI scale. Let (x,y) be the fresh app accessibility activation point. The diagnostic used the guest CADisplay currentOrientation readback, not the requested FlowDeck orientation name.

| CADisplay currentOrientation | Native point used for selected-display AX hit query | Normalized DTU point |
|---|---|---|
| rot0 | (x, y) | (x/W, y/H) |
| rot90 | (y, H − x) | (y/W, 1 − x/H) |
| rot180 | (W − x, H − y) | (1 − x/W, 1 − y/H) |
| rot270 | (W − y, x) | (1 − y/W, x/H) |

All four input transforms produced visible About navigation on the inner panel. Native AX point queries were confirmed at all four rotations. The raw rot180 point was recorded as a wrong-coordinate control. The final rot180 check repeated the transformed point query and tap after reboot; both succeeded.

FlowDeck orientation requests returned confirmed:false. Guest display readback and resulting layouts established the effective rotation. For example, the open portrait request produced inner rot90, while the landscape-left request produced inner rot0. Requested device pose, host UI orientation, guest display orientation, and panel-native geometry are separate values.

The closed landscape-left request did not rotate the outer UI: it remained rot0 with unchanged element coordinates. Its successful repeat tap is an ancillary check, not a closed-landscape acceptance claim. Other apps, windows, letterboxing, and scaled content still need their own validation.

## Live outcome matrix

All primary actions below were sent by the isolated route-probe, not by FlowDeck or RocketSim. FlowDeck supplied initial setup, orientation requests, hinge readback, and independent post-action trees. Apple screenshots supplied the visible outcome. After the first outer target, later action points came from the direct AX probe.

| Case | Measured panel rotation | HID target | Visible result |
|---|---|---|---|
| Closed, first outer tap | rot0 | 1 | General → About. |
| Open, wide inner layout | rot90 | 3 | General → About. |
| Open, tall inner layout | rot0 | 3 | General → About. |
| Open, 180-degree change with same dimensions | rot180 | 3 | General → About. |
| Open, opposite wide layout | rot270 | 3 | General → About. |
| Partial fold, mechanical angle 90 degrees | rot90 | 3 | General → About after a fresh layout/target read. |
| Folded closed again | rot0 | 1 | General → About on outer panel. |
| Closed wrong-target control, same outer coordinates | rot0 | 3 | Send accepted; General unchanged. |
| Open wrong-target control, same inner coordinates | rot90 | 0 | Send accepted; General unchanged. |

The partial sample reported mechanical angle 90, sensor angle 94.62032318115234, valid angle/velocity, and zero velocity. Refolding reported mechanical and sensor angles 0. These are separate fields; exact equality between the two is not required to establish that partial state.

[Independent visual review](evidence/2026-10-16-duo/routing/visual-review.md) covers 17 images: seven positive transitions and two unchanged negative controls. The closed inner capture was black; that alone does not prove input ineligibility. No simultaneous two-active-panel case was attempted.

## Required AXe/IDB changes

1. **Explicit target and live geometry in IDB.** Carry the selected CADisplay/CoreSimulator screen ID into modern DTU target. Normalize using that panel's current bounds and scale. Retain legacy routing as a separate implementation.
2. **One action context.** Keep boot identity, screen UUID/ID, geometry, scale, effective rotation, and a state revision together. Query, hit-check, and input must refer to the same revision. Never use target 0 as an active-display shortcut.
3. **Separate AX contracts.** Use frontmost lookup to obtain the active app, then validate the resolved target with a selected-display native-coordinate point query. Do not promise arbitrary per-panel AX trees until that path is proved, especially for two active panels.
4. **One transform for all actions.** Apply the verified display transform to taps, held touches, swipes, drags, sliders, point queries, and multi-touch. Re-read after folding/rotation, including 180 degrees with unchanged dimensions. Account for app-window transforms where required.
5. **Reject stale or incompatible actions.** Invalidate batch/agent roots and broker geometry on display-state changes. Release held contacts safely. Do not silently retry an input whose outcome is uncertain.
6. **Expose the state and outcome.** Display list/selection, actual orientation, hinge state, and accepted-versus-verified results must be machine-readable. Preserve AXe's existing verified slider result behaviour.

These changes belong mainly in the IDB fork, followed by AXe's common context and CLI/batch/agent integration. The retained probe is investigation code, not production-ready input transport or a replacement for the maintained framework.

## Reproduction and handoff

Toolchain: Xcode 27.2 beta 3 at /Applications/Xcode-27.2.0-Beta.3.app, selected per command with DEVELOPER_DIR. Dedicated simulator: 3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463. No other simulator was targeted.

Build and use instructions are in [probe README](evidence/2026-10-16-duo/routing/probe/README.md). The source dynamically loads the existing private frameworks and uses the current IDB DTU envelope. It does not require a production rebuild. The [guest display helper](evidence/2026-10-16-duo/routing/apple/cadisplays.m) reads CADisplay properties only.

Core commands, with explicit audit UDID:

    xcrun simctl io UDID enumerate
    xcrun simctl spawn UDID /private/tmp/axe-duo-routing-20261016/apple/cadisplays
    route-probe ax UDID AX_DISPLAY_ID
    route-probe ax UDID AX_DISPLAY_ID NATIVE_X NATIVE_Y
    route-probe tap UDID HID_TARGET NORMALIZED_X NORMALIZED_Y
    xcrun simctl io UDID screenshot --display=SCREEN_ID output.png

Each input sends start/end on one connection, holds for 100 ms, and drains for 300 ms. Exit 0 only confirms the send barrier. Full command arguments, elapsed time, exit code, stdout, and stderr are retained in JSON. AX queries have per-request and outer process bounds; the tree/grid are diagnostic and do not imply full UI coverage.

Probe AX reading was improved during the run: initial depth14 queries were incomplete, revision2 added full accessors/depth64, and revision3 added request tracing. The tap implementation stayed unchanged. Final probe SHA256: 9a365860ffc6af547032e5697556e9ca0d8f8bb2f32c89457f78eea7e0b0d231. Revision2 source and hash are retained. The final source hash is not retroactive provenance for the initial AX reader.

Known diagnostic failures are retained: initial depth-limited AX trees; invalid-display99 point query; raw-point hit tests after rotation; a driver JSON decode error after the expected invalid-display failure; and an unsupported cleanup home command (exit64). The driver stopped before its rotation step and that rotation was run separately. Shutdown of the audit UDID then exited0. The simulator was left closed and shut down. bootstatus exited0 but logged Data Migration Failed; later visible Settings navigation is the actual UI evidence.

Latest verification: 16 October 2026. Seven primary positive outcomes and two negative controls checked as above. A further rot180 check after reboot confirmed the transformed point lookup and repeated General → About navigation. Its before/after PNGs were inspected; the after image captures navigation in progress, and the subsequent AX tree contains ProductModelName on About. final180-refold.json and final180-shutdown.json both record exit0. Source manifest comparison checked67 files with zero changed or missing; git diff --check passed. See [verification record](evidence/2026-10-16-duo/routing/verification.json). Existing source changes remain untouched. Enumeration evidence omits unrelated host audio devices; full vendor disassemblies and compiled diagnostic binaries remain outside the repository.

Unverified: concurrent input to both active panels; arbitrary per-panel AX trees; physical Duo; other apps/window layouts; every gesture family; held contacts during transitions; restart/Xcode compatibility; stale-state rejection; production CLI/batch/agent integration. No complete Duo-support claim is made.
