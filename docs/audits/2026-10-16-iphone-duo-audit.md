# AXe, FlowDeck, and RocketSim: iPhone Duo audit

Date: 16 October 2026. AXe candidate: main, HEAD `7163081400b59f1df40bff44f3a94dded38eea9a`, plus the pre-existing worktree changes. This is an audit and a proposed plan. It does not add Duo support.

## UI automation follow-up

The [UI command comparison](2026-10-16-duo-ui-command-parity.md) lists finding, selectors, coordinate taps, gestures, scrolling, typing, keys, waiting, batching, and agent actions. The [UI interaction audit](2026-10-16-duo-ui-interaction-audit.md) records fresh element reads, unique-ID taps before and after rotation, coordinate swipes, scrolling attempts, and text entry. These reports supersede any implication that capture checks establish UI control.

AXe has many input primitives, but complete Duo UI control is not verified. In the follow-up, AXe re-found About after rotation but its tap returned success without opening the page in both checked layouts. RocketSim showed the same navigation failure; FlowDeck opened About in both layouts. Coordinate swipes did not move the tested list. This is a correctness problem in the interaction path, not just a screenshot problem.

## Private-framework control follow-up

Cam has asked to investigate the private control mechanisms already used by AXe and its competitors. The [control mechanism investigation](2026-10-16-duo-control-mechanisms.md) records fresh vendor symbols, confirmed private-event hinge writes at 0/90/180 degrees, per-screen power commands, and exact IDB source gaps. It supersedes the earlier public-API-only prerequisite. The later [display-routing proof](2026-10-16-duo-display-routing-proof.md) now establishes direct screen-ID targets and seven visible About navigations using an isolated diagnostic. Target 0 routes to the outer main screen, not the active panel. AX point queries select displays; frontmost-app queries did not reliably do so. Production AXe remains unchanged.

## Decision

AXe does not have complete iPhone Duo support. It has no pose control or current-display contract. Its input, accessibility, orientation, and capture paths can use different geometry. Live checks now confirm failures: AXe captures the inactive inner display when closed and does not correct the inner display rotation. The repeated Settings-label check stopped at an ambiguous selector. See the [live audit](2026-10-16-duo-live-audit.md) and [candidate provenance](2026-10-16-duo-axe-candidate.md).

The first change should be a shared device/display state model. A fold command alone will not fix input or capture after the display changes. Follow that work with display-aware input, accessibility, capture, and state confirmation.

FlowDeck supplies arbitrary-angle and orientation controls. Its named open/closed controls worked, but its 90-degree confirmation and screenshot selection failed in this environment. RocketSim selected the active display for screenshots; its hinge read and pose confirmation failed. Neither competitor is a complete acceptance oracle. Use Apple display capture as an independent reference.

## Installation and current limits

| Item | Verified result |
|---|---|
| FlowDeck CLI | Installed `1.33.0 [fac60d]` from the official installer. The live `latest.txt` feed returned `1.33.0` on a second check. The web changelog still stopped at 1.32.0. |
| FlowDeck path | `~/.local/bin/flowdeck` links to `~/.local/share/flowdeck/flowdeck`. The command resolves in this shell. |
| FlowDeck license | Activated by Cam. Licensed pose commands ran. The earlier `NO_LICENSE` result is superseded. |
| RocketSim | Installed Mac App Store app `16.7.0`, build `337`. App metadata, CLI status, and the released changelog entry agree. 16.7.1 is marked upcoming. |
| RocketSim CLI | `/opt/homebrew/bin/rocketsim` links to `/Applications/RocketSim.app/Contents/Resources/CLI/rocketsim`. The bundled launcher resolves the helper correctly and reports matching app/CLI versions. |
| RocketSim menu bar | The app is running and its bundle has `LSUIElement=true`. Onboarding advanced through setup. After the last step, native UI inspection returned a zero-size-window error. Thus, the app's menu bar configuration is verified; the final icon was not visually confirmed. |
| Signatures | `codesign --verify --deep --strict` passed for RocketSim. `codesign --verify --strict` passed for the FlowDeck binary. |
| Host | macOS 26.6.2, build 25G83. |
| Audit Xcode | 27.2 beta 3, build 27B5038j, selected per command with `DEVELOPER_DIR`. System selection remains 27.0 RC. |
| Duo runtime | iOS 27.2 Duo runtime, build 24B91011. Dedicated audit UDID `3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463`. |
| Activation and permissions | Cam confirmed both products are activated and RocketSim Screen Recording setup is complete. |

The CLI itself is a terminal command. RocketSim is the menu bar app that supplies its CLI. The FlowDeck CLI package does not establish a separate FlowDeck status-bar item.

The official [FlowDeck installer](https://flowdeck.studio/install.sh) resolves its [live version feed](https://d2axxxfnawvxo.cloudfront.net/releases/cli/latest.txt). The [RocketSim changelog](https://www.rocketsim.app/changelog/) distinguishes released and upcoming builds. These were checked separately from installed metadata.

The initial pass lacked a Duo runtime. Cam then supplied the newer toolchain. The installed app is Xcode 27.2 beta 3, not Xcode 27.3. Runtime checks use this explicit path. RocketSim needed a restart after the Xcode change to clear a loaded CoreSimulator version mismatch. That setup failure is excluded from Duo defect counts.

## Coverage comparison

“Local help” proves a command exists. “Vendor” means published behavior. “Static” means bundle or source evidence. These labels describe the first source pass. The live results below take precedence.

| Capability | AXe current source | FlowDeck 1.33.0 | RocketSim 16.7.0 |
|---|---|---|---|
| Discover a Duo | Generic fallback exists; explicit UDID works live | Duo command support; local help | Duo profiles and command support; static/help |
| Set named pose | Absent | Open/closed passed live; named partial not checked | Open changed pose, but confirmation timed out |
| Set arbitrary angle | Absent | 90-degree request changed mechanical angle to 90; reported angle 94.62; confirmation failed | No arbitrary-angle option in public Duo CLI help |
| Read/stream hinge | Absent | Get works; stream not exercised | Hinge query failed with `hinge_not_ready` |
| Rotate device | No command | Four readbacks matched requests; all returned `confirmed:false` | Screenshot orientation is an output option. No equivalent device setter established in this audit |
| Follow display for input | Settings selector has duplicate matches in both poses; coordinate coverage remains open | Settings tap opened the app in both poses | Settings tap worked closed; open returned success with no navigation |
| Accessibility after a fold | Frontmost app; no display contract | Display-specific frontmost-app selector; static | Resident snapshot service; vendor/static. Duo transition result unproved |
| Plain screenshot | Closed images black; open images retain raw surface rotation | Fails because two displays require selection | Active display selected in eight-state check |
| Fold/rotate during recording | Plain video has sideways inner content and a black closed sample | Default and internal-display video fail at display selection | Plain video also has a black closed sample; separate 3D result in live report |
| Both displays active | No explicit support | Not established | Capture support established as a claim; two-display input remains unproved |
| Physical-device UI control | Not exposed by current simulator commands | Physical lifecycle support; simulator UI automation only | Physical preview/capture and lifecycle support; no claim of full physical Duo UI automation |

Bitrig is a useful fourth reference. Its [Duo release](https://bitrig.com/blog/simulator-use-can-now-test-iphone-duo) claims active-display input and arbitrary angles. Its [camera release](https://bitrig.com/blog/build-iphone-duo-camera-apps) covers simultaneous inner/outer content. Include that case in AXe's coverage target; open versus closed is not the complete state space.

## Main AXe gaps

1. Orientation reads screen ID 1. Input caches device-type size and scale. Capture selects the first display of class 0. These paths do not share a live display identity.
2. The HID broker reuses a session by boot identity. A fold within one boot need not invalidate it.
3. Gesture presets use 390 by 844 points by default and bypass the common coordinate transform. This also affects ordinary iPhones and iPads.
4. Agent mapping in the current uncommitted work is cached by viewport. A 180-degree turn can preserve dimensions but require a new mapping.
5. App-window bounds are used as screen geometry. Letterboxing, split layouts, scene accessories, and reserved areas make those different coordinate spaces.
6. Recording fixes its canvas from the first frame. Unframed BGRA output has no geometry-change contract.
7. There is no machine-readable support report for hinge, display, rotation, or transition state. Existing device evidence is concentrated on iPhone 17 Pro.

The [source audit](2026-10-16-axe-duo-source-audit.md) contains exact file and line references, framework paths, and the distinction between existing HEAD and uncommitted agent work.

## What the implementation evidence tells us

Both products ship IDB-family simulator frameworks. FlowDeck also contains its own simulator control modules. Framework names alone do not prove that their revisions or behavior match AXe's fork.

FlowDeck's binary contains hinge-slider event strings, a hinge stream action, and display-specific accessibility queries. These support an inference that it selects a display from hinge state and routes observations accordingly. They do not reveal every branch or prove successful operation on this Mac.

RocketSim's app imports simulator framework APIs for hinge sessions, all-screen framebuffer connections, screen descriptors, and screen-property observation. Its own symbols include a fold renderer and a hinge timeline recorder. This supports a design with display state in the lower transport layer and capture composition in the app layer. Its shipped Duo profile describes two integrated screens, with different sizes and native rotations. Do not turn profile array positions into assumed runtime display IDs.

The [bundle audit](2026-10-16-duo-bundle-audit.md) records versions, hashes, framework links, symbols, resources, and the limits of static inspection. No vendor binary was modified. The later control mechanism investigation executed a separate temporary private-API helper; the original bundle inspection was read-only.

## Engineering lessons from public reports

RocketSim's author describes the move from one capture rectangle to two display streams and a changing fold pose. Overlay coordinates must track the rendered device rectangle. A recording also needs time-aligned hinge and rotation state. See [SwiftLee Weekly 342](https://newsletter.avanderlee.com/posts/swiftlee-weekly-issue-342).

The open [hinge project](https://github.com/artemnovichkov/hinge) provides a concrete private HID event example. Its [unmerged rotation change](https://github.com/artemnovichkov/hinge/pull/1) reports that `devicectl` can report success before Duo returns to its previous orientation. This is author-reported behavior, not a reproduction here. It shows why state readback and stable pixels matter more than command exit status.

Direct X access failed. No readable FlowDeck social post about the Duo implementation was found. The audit uses readable author posts, official release notes, and pinned open source instead. It does not invent the missing social history. Details and source URLs are in the [public research report](2026-10-16-duo-public-research.md).

Cam has explicitly authorized investigation of the private interfaces. Use the competitor implementations and existing IDB stack as references. Validate the current ABI, payload, lifecycle, and readback before integration; do not treat header or symbol presence as runtime proof.

## Implementation plan

| Order | Work | Completion evidence |
|---|---|---|
| 1 | Complete the remaining device-state matrix | Toolchain and dedicated Duo are ready; open/closed capture matrix is recorded. Partial angles, simultaneous displays, and recovery remain |
| 2 | Add a single typed device/display state owner in the transport layer | Current identity, geometry, scale, orientation, hinge state, and revision available through a stable CLI/API boundary |
| 3 | Use that state for input, accessibility, and agent decisions | First input after each transition hits the intended target; 180-degree turns invalidate mapping; stale actions fail clearly |
| 4 | Add pose/rotation commands after validating the control transport and state readback, including private interfaces | Explicit device target; idempotent set; bounded wait; actual state returned on mismatch; unsupported capability reported |
| 5 | Repair capture continuity | Correct display chosen; frame/screen changes observed; aspect ratio preserved; raw stream resize behavior defined |
| 6 | Add explicit display selection for two-display input and accessibility; then optional composition and 3D presentation | Both displays can be addressed independently; streams and state have timestamps; exported result follows the full transition |
| 7 | Publish support and performance evidence; update docs, skill, changelog | Reproducible matrix against the exact candidate; no unsupported device claims; skill source passes required skill-check |

Put transport changes in the maintained IDB fork, pin an immutable revision, and rebuild the shipped frameworks. Do not rely on an untracked local patch. A framework update affects the build and release system and must retain Xcode 26/27 compatibility evidence.

Keep physical screen pixels, logical screen points, app-window points, and HID coordinates separate. A revision must change when display identity, orientation, geometry, or input routing changes. Frame, accessibility, and input must use the same state revision. Reject an action if that revision changes before dispatch. Cancel held contacts on an incompatible display transition. Do not replay an uncertain touch automatically.

## Live verification procedure

Use a dedicated Duo and an existing app with visible, accessible controls. Keep the user's current simulator unchanged. First use Device Hub as the control path. Then repeat the same states with each vendor CLI. Finally use that external state control while AXe reads and acts; this can expose AXe gaps before AXe has its own hinge setter.

The following command forms define the wider procedure. Some ran in the live audit; only its evidence table establishes a pass. Set `DUO` to the dedicated simulator UDID after creating it. Use the intended Xcode for Apple commands and configure the same Xcode in RocketSim.

```sh
flowdeck simulator pose set closed -S "$DUO" --json
flowdeck simulator pose set angle 90 -S "$DUO" --json
flowdeck simulator pose set open -S "$DUO" --json
flowdeck simulator pose get -S "$DUO" --json
flowdeck simulator orientation set landscape-left -S "$DUO" --json

rocketsim duo pose book --udid "$DUO"
rocketsim duo hinge --udid "$DUO"
rocketsim screenshot --udid "$DUO" > duo-active.png
rocketsim screenshot --bezel device3d --udid "$DUO" > duo-model.png

xcrun simctl io "$DUO" enumerate
xcrun devicectl device motion hinge-angle --device "$DUO" --session-timeout 2 --timeout 5
```

Do not run FlowDeck's streamed pose query without a termination plan; it continues until interrupted. For Apple display screenshots, select a display ID from the current enumeration rather than assuming ID 1.

Cover named poses and 0, 30, 60, 90, 120, 150, and 180 degrees where supported. Include hinge thresholds in both directions, all supported orientations, and rotation while partly folded. Check transitions during a drag, keyboard entry, scrolling, capture, and delayed agent action. Include adaptive and compatibility-mode apps, sheets, app switching, multiple windows, and simultaneous camera displays. Run a normal iPhone and iPad as controls. Include multiple-simulator isolation, shutdown/reboot recovery, stream cancellation, and selected-Xcode changes. App-facing hinge APIs can provide an independent readback in an existing suitable sample; they do not set the host simulator pose.

## Performance comparison

The [live audit](2026-10-16-duo-live-audit.md) records a bounded read-command benchmark. It compares different output contracts, not equivalent full workflows. There is no valid general Duo speed ranking from this audit. RocketSim's [published July comparison](https://www.rocketsim.app/blog/testing-ai-agents-ios-simulator/) predates Duo and current AXe work. It uses an older raw AXe command path. Its context figures are byte estimates, not a measured current Duo token result.

For a useful comparison, use the same Mac, Xcode, runtime, app, screen content, output resolution, and gesture duration. Separate cold process startup from warm resident sessions. Compare raw operations separately from agent workflows. Include resident app CPU and memory, not just CLI process cost.

For each tool and supported state, use five warm-up runs and at least 30 measured repeats. Record median, p95, failures, and output/image bytes. Measure dispatch time, confirmed pose, first correct frame, stable AX tree, and first correct tap separately. For video, measure effective FPS, frame age, CPU, memory, missing frames, and aspect-ratio errors. Keep failed runs in the result. A faster wrong tap is a failure, not a performance gain.

## Initial verification record

This section preserves the first pass. The [live audit](2026-10-16-duo-live-audit.md) supersedes its environment and activation limits.

Latest verification: 16 October 2026, against the installed versions above and the stated dirty AXe source candidate.

- `flowdeck --version` returned `1.33.0 [fac60d]`; the live version feed also returned `1.33.0`.
- `rocketsim status` returned matching `16.7.0/337` app and CLI versions, working IPC, and configured Xcode tools.
- `rocketsim doctor`, after a screen query, returned six passes, zero warnings, and zero failures on iPhone 17 Pro.
- `rocketsim screen --udid ...` returned a successful screen summary. Its temporary preview token was excluded from saved audit evidence.
- `rocketsim screenshot --udid ...` produced a readable 2622×1206 PNG. The image contained the portrait Home Screen rotated into a landscape canvas. Apple capture produced 1206×2622, while `devicectl device orientation get` reported `landscapeLeft`. This is an orientation mismatch between capture paths and readback. Physical/UI orientation differences could explain it; transform and timing errors remain possible. Capture generation passed; upright-content behavior is not certified by this check.
- `rocketsim duo hinge --udid ...` rejected the ordinary iPhone with `unsupported_target`. This is a negative capability check, not a Duo pass.
- `xcrun simctl list runtimes` and `list devicetypes` confirmed the missing Duo environment.
- `git diff --check` passed. No source, tests, or skill files were changed by this audit. No commit or push was made. Existing changes remain in place.

Machine-readable installation results: [local-verification.json](evidence/2026-10-16-duo/local-verification.json). Detailed bundle findings and inspection commands are recorded in the bundle audit.

Remaining work: the full transition and simultaneous-display matrix, physical-device acceptance, and verified host-side hinge/display input integration. A visual check of the final RocketSim menu bar icon remains unrecorded; its running menu-bar configuration is verified. Activation, Duo setup, bounded live capture/input checks, and read timing are now complete. No product code was changed. The audit includes source and bundle inspection, public engineering references, eight capture states, six controlled label actions, pose readback checks, short fold recordings, and 90 measured read commands.
