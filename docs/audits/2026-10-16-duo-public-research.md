# iPhone Duo: public source audit

Date: 16 October 2026. Sources were read on this date. This report covers published documents, source code, and local help results supplied by the main audit agent. It does not certify Duo runtime behavior or measured product performance. See the main audit for binary and runtime evidence.

> Later same-day update: both products are activated. Xcode 27.2 beta 3 and the Duo-specific iOS 27.2 runtime are available. The environment limits below describe the initial research pass. See [live audit](2026-10-16-duo-live-audit.md) for measured behavior; it supersedes those limits.

## Main findings

Complete Duo control needs more than a fold command. Input, accessibility, screenshots, orientation, and scene selection must follow the correct display through a transition. A command can report success before the final device state is stable. Two displays can also be active at the same time.

The public evidence supports three distinct comparisons: FlowDeck for simulator control and app workflows; RocketSim for control plus capture and overlays; Bitrig for arbitrary hinge movement and simultaneous display workflows. No current, independent Duo performance comparison was found.

## FlowDeck

The fetched [release index](https://flowdeck.studio/changelog) stops at 1.32.0 on 30 September 2026. This index is behind the current release: the main audit agent verified the latest CLI feed and installed FlowDeck 1.33.0 [fac60d] on 16 October. Version 1.32.0 unified the Mac app, CLI, and skill versions. The [release article](https://flowdeck.studio/changelog/iphone-duo-support-and-better-conversation-controls) states support for multiple Duo poses and orientations with Xcode 27.1 beta or later. It also states that a new CLI pose command controls posture and hinge angle. Viewport rotation follows the device. Gesture delivery, text entry, deep-link confirmation, and recording startup received reliability fixes.

There is a documentation defect: the article itself shows 1 April 2026, while the release index shows 30 September. The linked [simulator reference](https://docs.flowdeck.studio/cli/simulators) did not contain a pose section in the fetched page. The main audit agent resolved the missing contract through installed 1.33.0 help. Do not copy RocketSim syntax into FlowDeck commands.

Local help confirms these pose forms. Angle brackets and vertical bars below show syntax choices, not a literal shell script.

~~~text
flowdeck simulator pose get -S <UDID> [--stream] [--interval <SECONDS>] [--change-threshold <DEGREES>] [--json]
flowdeck simulator pose set <closed|partially-folded|open|angle> [angle] -S <UDID> [--json] [--dry-run]
~~~

Thus, FlowDeck exposes arbitrary angles and streamed readback. Help output proves the command contract; no Duo runtime was available to check the result.

The web simulator reference also documents these commands:

~~~sh
flowdeck simulator orientation get -S "iPhone Duo" --json
flowdeck simulator orientation set landscape-left -S "iPhone Duo" --json
flowdeck ui simulator screen --tree --json
~~~

The orientation command normally waits up to 30 seconds for physical and visual confirmation. Local help confirms all four orientation names and that --no-wait skips visual confirmation. The reference says upside-down portrait is unsupported on iPhone simulators. This general statement needs a Duo-specific check.

FlowDeck says [physical-device UI automation is unsupported](https://flowdeck.studio/learn/device-development). Its physical-device workflow uses xcodebuild and devicectl for build, install, launch, and logs. This is separate from simulator UI control. Its [home page](https://flowdeck.studio/) identifies Apple accessibility frameworks and screenshots as automation inputs. Public documents do not establish the exact Duo control framework or event path. No official public implementation repository was identified in the searches.

## RocketSim

The [changelog](https://www.rocketsim.app/changelog/) lists 16.7.0 build 337, released 9 October 2026. The main audit agent verified this installed version and confirmed that its local Duo command help matches the documented forms below. Search and page fetches disagreed about the upcoming banner; one showed unreleased 16.7.1. Treat upcoming notes as unreleased.

Duo support shipped in 16.6.0 on 8 October. Relevant fixes include Device Hub overlay alignment, rotated captures, cloned simulators without windows, and concurrent accessibility reads. The camera compatibility work included private device queries. Upcoming notes mention high-frame-rate playback marking, missing Duo models, and clearer conversion errors. These are useful failure cases, but published fixes are not local verification.

The [CLI reference](https://www.rocketsim.app/docs/features/agentic-development/rocketsim-cli/) gives this contract:

~~~sh
rocketsim duo pose closed|book|open --udid <udid>
rocketsim duo hinge --udid <udid>
rocketsim screenshot --bezel device3d --udid <udid> > duo.png
~~~

The hinge result reports hinge_state and hinge_angle_degrees. States are closed, openFlat, and partiallyOpen. Angles run from 0 to 180 degrees. Pose control needs neither Device Hub nor macOS Accessibility permission. The documented CLI does not expose an arbitrary-angle setter in this section. The screenshot --orientation flag changes output orientation; it is not proof of device rotation control.

The [recording reference](https://www.rocketsim.app/docs/features/capturing/recordings/) says captures retain both display streams and live hinge movement. Apple’s 3D folding model supplies the rendered device. Recording preserves rotation, and the output aspect ratio changes as the device unfolds. This describes capture composition; it does not prove that both displays are independently addressable for input.

The [rs/1 reference](https://www.rocketsim.app/docs/features/agentic-development/rs1-protocol/) describes a running Mac app that retains simulator connections and screen state. Compact element rows, screen hashes, typed errors, and interaction deltas reduce repeated reads. A bounded settlement period precedes delta calculation. These are useful design ideas for AXe. They do not guarantee that hinge, display, pixels, and accessibility all describe the same instant.

## Social posts and engineering reports

The strongest readable engineering report was the author's [SwiftLee Weekly Issue 342](https://newsletter.avanderlee.com/posts/swiftlee-weekly-issue-342). It explains two problems: capture became a three-dimensional timeline rather than a fixed rectangle, and Device Hub's changing screen rectangle made touches, grids, and rulers hard to place. The author reports reading live hinge angles, storing them during recording, and applying them again during export. The fetched newsletter gives a relative publication date; do not assign it an exact date from that text.

The official [SwiftLee LinkedIn feed](https://nl.linkedin.com/company/swiftlee-weekly) also contains posts about using Instruments and RocketTrace to optimize Duo support, and about forthcoming Duo recordings. These are primary posts, but their dates were relative. They contain no reproducible Duo benchmark.

The author's [22 September article](https://www.avanderlee.com/swiftui/iphone-duo-simulator/) embeds a [18 September X post](https://x.com/twannl/status/2101017044397257161) about holding Option on Device Hub pose controls to expose the hinge slider. The article recommends checks during transitions, with navigation, sheets, selection, and text entry already active. It also identifies camera behavior, reach, haptics, and device performance as areas that need physical hardware.

Direct X fetches returned 403 or cache errors. The following discovered posts were not directly read: [22 September workflow post](https://x.com/twannl/status/2102381152963101077) and [19 September skill post](https://x.com/twannl/status/2101263538094325997). Secondary indexes were used only to locate these URLs. They are not evidence for their contents.

Targeted searches of FlowDeck, @flowdeckstudio, and @afterxleep did not produce a readable primary Duo engineering post. The [FlowDeck account](https://x.com/flowdeckstudio) fetch failed. Thus, FlowDeck's social engineering history remains unverified. Its release notes establish product claims only.

## Open source: hinge

The MIT-licensed [hinge source](https://github.com/artemnovichkov/hinge/tree/7acb090dd7d28fb0aea8e1907211ceff15aa450e) was read with gh. Revision: 7acb090dd7d28fb0aea8e1907211ceff15aa450e. This is a separate tool, not evidence that either vendor uses the same implementation.

The [C helper](https://github.com/artemnovichkov/hinge/blob/7acb090dd7d28fb0aea8e1907211ceff15aa450e/skills/hinge/scripts/hinge_helper.c) runs inside the simulator. It creates a vendor-defined HID event and dispatches it through IOHIDEventSystemClient. Its payload uses usage page 0xFF61, usage 0x5B, provider com.apple.Virtualization, source hinge-slider-control, type range, and a degree value. The helper clamps angles to 0–180 and implements a nominal 60 Hz sweep. It waits 100 ms before exit, without verifying the result.

The [shell wrapper](https://github.com/artemnovichkov/hinge/blob/7acb090dd7d28fb0aea8e1907211ceff15aa450e/skills/hinge/scripts/hinge) compiles for arm64 iOS Simulator, links IOKit and CoreFoundation, signs the helper, and invokes simctl spawn. It reads the angle with devicectl device motion hinge-angle. Its default selection takes the first booted simulator. Its cache key hashes the source and Xcode path, not the actual Xcode build. Those choices should not be copied into AXe without change.

[Open PR 1](https://github.com/artemnovichkov/hinge/pull/1), created 12 October, provides important rotation evidence. It was unmerged when checked; head 1b3713c3bd293a29d95bcc0c65f4403348838269. The author reports that devicectl orientation set succeeds but Duo reverts. The proposed helper sends the Device Hub orientation event instead. Its payload uses provider com.apple.Virtualization.VirtualMachines, source orientation-picker-control, type enum, and an absolute orientation; upside-down portrait uses pud. The author reports full rotation cycles and framebuffer dimension changes on Xcode/iOS 27.1. This is author-reported testing, not a local result. All issue comments, review comments, and reviews were requested; there were none.

These event contracts are private and undocumented. The repository states that limitation. They are research evidence only. AXe's current rules prohibit new private SDK configuration paths without a verified public API. A production proposal must either use a supported boundary or obtain a separate design decision; this audit does not approve that change.

## Bitrig and Apple

Bitrig's [28 September release](https://bitrig.com/blog/simulator-use-can-now-test-iphone-duo) claims arbitrary hinge-angle and orientation control. It explicitly states that taps, screenshots, and accessibility follow the active display. It also supports scripts that combine folding, input, capture, and inspection, with accessibility tree differences. Its [8 October camera release](https://bitrig.com/blog/build-iphone-duo-camera-apps) adds Mac camera or prerecorded-video input through AVFoundation and shows CameraCaptureAccessory content on the outer display while the main app uses the inner display. These are vendor claims; no independent runtime check was made here.

Apple's [preparation guide](https://developer.apple.com/iphone-duo/prepare/) identifies Xcode 27.1's Duo simulator as the preferred native check. Resizable simulator windows and iPhone Mirroring are useful for layout sizes, but they do not cover the full Duo behavior. Avoid global screen bounds and orientation-based layout decisions.

Apple's [multidisplay talk with code samples](https://developer.apple.com/videos/play/tech-talks/111464/) distinguishes hinge effects from layout. SwiftUI onHingeChange and UIKit UIHingeInteraction report hinge state and angle. Arrangement and reserved-region APIs handle layout. Scene accessories can make both displays active; availability can change while the app runs. New app windows are available on the inner display, not the outer one. These are app-facing APIs, not a documented Mac API to set simulator hinge state.

The [SwiftUI Agent Skill Duo reference](https://github.com/AvdLee/SwiftUI-Agent-Skill/blob/204dba7c67256a8b707ee3fbc5759a824191974f/skills/swiftui-expert-skill/references/iphone-duo.md) was read at revision 204dba7c67256a8b707ee3fbc5759a824191974f. It provides concrete adaptive-layout examples. It is guidance, not simulator transport source or runtime proof.

## Xcode setup required for local Duo checks

The main audit agent found Xcode 27.0 RC (27A266a) and iOS 27.0 (24A434), with no Duo runtime. This prevents local Duo verification even though both vendor CLIs expose Duo commands.

Apple released [Xcode 27.1 (27A9275) on 15 October 2026](https://developer.apple.com/news/releases/?id=10152026a). This is the final 27.1 release, not a requirement to install a beta. Apple's [system requirements](https://developer.apple.com/xcode/system-requirements) list macOS Tahoe 26.6 or later and the iOS 27.1 SDK. The release page's [download link](https://developer.apple.com/download/applications) redirected to Apple Account sign-in during this research. No account action or download was performed.

For a later setup, install Xcode 27.1 and complete first launch. In that Xcode, open Settings > Components and install iOS 27.1 platform support and its simulator runtime. If necessary, use Other Installed Platforms to select the required version. Apple's [component guide](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components) also documents xcodebuild -downloadPlatform, -buildVersion, -runFirstLaunch, and -importPlatform for command-line setup. Pin the intended Xcode for every check; do not assume a different installed Xcode uses the same runtime or SDK.

Use Device Hub's Add Device control to create an iPhone Duo with the installed runtime, as described in Apple's [Device Hub guide](https://developer.apple.com/documentation/xcode/pairing-your-devices-with-your-mac). Record the resulting device type, runtime build, and UDID before the comparison. Confirm that its native open, close, fold, and rotation controls work before checking third-party tools.

The fetched [27.1 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes) still used an RC title. They list slow first simulator launch, unavailable StandBy, and unavailable run/debug support for most app extensions on Duo. Keep these as stated runtime limits, and recheck them against the installed final build. Do not classify them automatically as AXe defects.

## Performance comparison plan

RocketSim's [published benchmark](https://www.rocketsim.app/blog/testing-ai-agents-ios-simulator/) used AXe 1.8.0, XcodeBuildMCP 2.7.0, and RocketSim 16.4.2 on Xcode 26.6/iOS 26.5. The dated run was 31 July. It predates Duo and the current AXe work. It compares fixed command workflows, not model quality. Its context figures are byte estimates and exclude screenshot bytes. The article acknowledges the difference between raw AXe primitives and an agent layer. Its published speed and output ratios must not be presented as current Duo results.

Proposed local comparison:

1. Record exact tool versions, binary hashes, Xcode build, runtime, app build, simulator UDID, and permission state.
2. Run the same visible app flows, separately for raw commands and agent workflows. Use explicit device targets.
3. Measure cold startup separately from warm commands. Include resident app memory and CPU for tools that keep a service running.
4. Measure pose dispatch, confirmed hinge state, first valid frame, stable accessibility, and first correct input as separate times.
5. Report median and tail latency, failure count, wrong inputs, output bytes, image bytes, and command count. Preserve failures.
6. Cover closed/open/book, arbitrary angles where supported, all permitted rotations, rapid reversal, keyboard, sheet, split view, app switch, display transfer, and simultaneous camera displays.
7. Confirm results from the app's visible state and a second read path. A zero exit code alone is insufficient.

No benchmark was run by this research task. No source code, tests, or skills were changed. The report is the only new file.
