# AXe source audit for iPhone Duo

Date: 16 October 2026. Scope: source and local framework inspection. This report does not claim a live Duo test pass.

## Candidate and evidence limits

AXe branch: main. HEAD: 7163081400b59f1df40bff44f3a94dded38eea9a. The worktree already had changes in the agent, accessibility models, and coordinate code. Those changes were not made by this audit. Line references below refer to the worktree read on this date. The agent findings include that uncommitted work; they are not claims about a released binary.

IDB checkout: 604c51013438f0c3603b720a05a44b7c5b8f286d, clean when inspected. This equals the default pin in scripts/build.sh:58-61. The configured upstream base is e682506725e9efefb9c43b8b917c0b12eb2a5939. The local XCFramework evidence file records the same IDB SHA and Xcode 27.0 build 27A5237l. A build evidence file is not proof that every installed AXe executable uses these frameworks.

No source, skill, test, or build configuration was changed. No tests were added or run. No simulator state was changed by this source audit. No commit was made.

## Conclusion

AXe has useful Xcode 27 foundations: device discovery, a DTUHID input transport, accessibility queries, IOSurface capture, and coordinate transforms. It has no explicit fold state, active display, or transition model. It has no CLI command to fold, unfold, or rotate a device. Some ordinary commands can still work on Duo in a fixed state. Source alone cannot establish which states work.

The main risk is inconsistent geometry: accessibility, orientation, screenshots, and input can each use a different view of the device. Add a shared current-display state before adding a fold button. Do not treat model-name recognition as complete support.

## Observed source behavior and its implications

| Area | Observed source | Inference or required check |
|---|---|---|
| Command coverage | Sources/AXe/main.swift:16-36 lists the public command set. No fold, unfold, rotate, display selection, or device-state command exists. | Direct control of those state changes is absent. External tools can change state while AXe measures the result. |
| Device discovery | Sources/AXe/Commands/ListSimulators.swift:16-23 uses the default simulator set and prints each description. IDB FBSimulator.m:35-49 uses inferSimulatorConfigurationFromDeviceSynthesizingMissing. | An unknown model need not be absent from the list. Duo discovery must be checked live. No JSON capability or current-display record is exposed by this command. |
| Model metadata | IDB FBSimulatorConfiguration+CoreSimulator.swift:40-65 has strict model lookup plus a generic fallback. FBiOSTargetConfiguration.swift:61-63 assigns an unknown model arm64 architecture and familyUnknown. No Duo model entry was found in that configuration directory. | Existing-device discovery can survive missing model metadata. Device-family dependent creation or queries need separate checks. Do not claim the missing model table entry blocks all commands. |
| Orientation source | Sources/AXe/Utilities/SimulatorOrientationReader.swift:38-73 creates SimulatorKit.SimDeviceScreen with screenID 1 and reads screenProperties.uiOrientation. | The chosen screen may not be the active screen after a fold. The meaning of screen ID 1 on Duo is not established. |
| Coordinate geometry | Sources/AXe/Utilities/OrientationAwareCoordinates.swift:145-232 derives mapping from the application frame, private orientation, and screenshot aspect ratio. Lines 397-407 derive device dimensions from the app frame; lines 536-540 use the Application root or first root. | An app window is not always the physical input viewport. Open Duo, split views, letterboxing, and multiple windows can break that assumption. A wide screen does not prove landscape orientation. |
| Snapshot timing | OrientationAwareCoordinates.swift:126-135,159-162,196 and 255 read AX, orientation, and a simctl screenshot in separate operations. | A transition can occur between reads. A correct value from each source can still form an inconsistent combined state. The screenshot probe has no display selection. |
| Touch normalization | IDB FBSimulatorDTUHIDTransport.swift:75-76,114-123 stores mainScreenSize and mainScreenScale from device.deviceType at connection. Lines 139-155 use these values for single and two-finger input. FBSimulatorIndigoHID.swift:150-153 divides point coordinates by those dimensions after scale conversion. | Size changes within one boot can leave input normalized with stale or wrong dimensions. A new connection alone is not sufficient if the device-type dimensions are fixed. Read live active-display geometry. |
| Input target | IDB DTUHIDModels.swift:54-73 defines a target value whose default is 0. FBSimulatorDTUHIDTransport.swift:142-154 does not override it. | Check what target means in the installed Apple transport. It is not yet proved to be a display ID. Do not copy another tool's numeric value without evidence. |
| Session life | Sources/AXe/Utilities/HIDBrokerReadiness.swift:6-35 identifies launchd_sim by PID and start time; lines 82-86 reuse a session when this identity matches. HIDInteractor.swift:236-247 caches HID by UDID. | Fold and rotation do not necessarily cause a new boot. Cached input state has no display-change invalidation path. A held contact also needs a defined cancellation rule if the device changes during a drag. |
| Gesture presets | Sources/AXe/Commands/Gesture.swift:172-205 uses 390 by 844 unless values are supplied, then creates a HID swipe directly. | Presets bypass OrientationAwareCoordinates. This is a concrete source gap for different sizes and orientations, including ordinary iPads and large iPhones. User-supplied dimensions do not add the missing rotation transform. |
| Other coordinate commands | Tap.swift:142, Touch.swift:75, Swipe.swift:91, Drag.swift:80, and Slider.swift:180 use OrientationAwareCoordinates. | These have a common repair point. They still depend on a correct current display and input geometry. |
| Accessibility scope | Sources/AXe/Utilities/AccessibilityFetcher.swift:95-120 serializes the frontmost application. At-point queries use target.accessibilityElement at lines 58-65. Neither accepts a display. | Check open Duo layouts, keyboard focus, app windows, and overlays. A valid hierarchy is not proof that it describes the same surface as the screenshot or input target. |
| Framebuffer choice | IDB FBFramebuffer.swift:48-77 selects the first IO descriptor with displayClass 0. The descriptor is stored at line 83. | This can work if Duo changes the surface within that descriptor. It can fail if the active display uses a different descriptor. Enumerate and observe transitions before choosing a rule. |
| Surface changes | IDB FBFramebuffer.swift:155-172 forwards IOSurface changes. FBSimulatorVideoStream.m:840-898 remounts a new surface and creates a frame pusher. | Some resize support already exists. Do not describe capture as entirely static. This does not prove active-descriptor changes or output-consumer resize behavior work. |
| Screenshot connection | Sources/AXe/Commands/VideoCommandSupport.swift:68-71 calls IDB takeScreenshot. IDB FBSimulatorScreenshotCommands.swift:46-53 caches its image/framebuffer object. | A persistent capture can remain bound to a prior descriptor. A successful screenshot must be checked for correct active content and dimensions. |
| MP4 recording | Sources/AXe/Commands/RecordVideo.swift:98-110 fixes output dimensions from the first frame. VideoCommandSupport.swift:165-170 stores them, and line 245 draws each later image across that full rectangle. | If aspect ratio changes, output can stretch. Choose and document a policy: fixed canvas with aspect preservation, or segmented recording. This behavior is visible from code; the Duo effect has not been exercised here. |
| Raw video contract | Sources/AXe/Commands/StreamVideo.swift:174-198 exposes raw BGRA with an example that requires a fixed WIDTHxHEIGHT. | A consumer cannot safely interpret changing dimensions without a resize signal or restart rule. A larger byte stream is not proof of a correct resized image. |
| Agent coordinate cache | Worktree Sources/AXe/Agent/SimulatorAgentExecutor.swift:221-240 caches mapping by AX viewport only. | A 180-degree rotation can keep the same viewport dimensions and still require a different transform. Fold state, display identity, and rotation must invalidate the cache. This finding applies to current uncommitted agent work. |
| Agent freshness | Worktree AgentModels.swift:48-66 stores an element hash and viewport; AgentFreshness.swift:28-66 permits some changed layouts after target resolution. AgentScreenObserver.swift:70-116 can reuse an accessibility handle. | Fresh element coordinates are useful but do not establish physical display freshness. Include device/display state in the action precondition. Reacquire the relevant handle when its display or scene changes. |
| Verification coverage | test-runner.sh:18 defaults to iPhone 17 Pro. Its landscape checks are opt-in at lines 382-419. Both checked-in Xcode 26.5 and Xcode 27 beta 3 golden provenance files name iPhone 17 Pro. | These artifacts do not establish Duo, fold, full rotation, or multi-window support. Orientation math examples for an iPad are not a Duo transition pass. |

## Framework and transport map

Package.swift:49-67 links AXeCore, ArgumentParser, FBSimulatorControl, FBDeviceControl, FBControlCore, and XCTestBootstrap. The binary target paths are local XCFrameworks. Linking FBDeviceControl does not expose physical iPhone control through the current simulator CLI.

The local FBSimulatorControl Mach-O has weak links to CoreSimulator and AccessibilityPlatformTranslation, plus links to FBControlCore and XCTestBootstrap. Capture dependencies include IOSurface, CoreVideo, CoreMedia, AVFoundation, VideoToolbox, CoreImage, and Metal. The image path uses an IOSurface rather than macOS window screenshots.

Some dependencies load at runtime and are not fully visible in otool output. IDB FBWeakFramework+ApplePrivateFrameworks.swift:12-27 finds CoreSimulator, SimulatorKit, and DTXConnectionServices. It handles the Xcode 27 move of SimulatorKit into SharedFrameworks. Lines 46-47 load AccessibilityPlatformTranslation. AXe's SimulatorOrientationReader calls private Objective-C selectors through method pointers.

The modern input path in FBSimulatorDTUHIDTransport.swift:37-45 and 84-112 looks up com.apple.coredevice.feature.remote.hid.digitizer on the simulator, constructs an XPC endpoint with private _4sim functions, enables simulator-to-host messaging, and sends typed dictionaries. Input completion is only a send barrier at lines 189-196. The 80 ms flush at lines 62-69 and 199-203 is a bounded drain delay; it is not a guest action acknowledgment. This matters when comparing latency or claiming a tap succeeded.

The legacy input path loads SimulatorKit IndigoHIDMessageFor functions, then constructs touch messages (FBSimulatorIndigoHID.swift:31-43 and 109-139). Both transports normalize points using device-type geometry. This shared assumption needs attention before a transport switch can count as a Duo fix.

These are observations of existing code. They are not approval to add more private SDK configuration. The repository rules require a verified public API for SDK configuration. Prefer a documented Apple command or API, or the normal Device Hub UI, for state changes. If the needed control has no public route, report that limit and make the API policy decision explicit before implementation.

## Proposed design and implementation order

### 1. Establish the actual Duo state model

Use the installed Apple device definition and the running device. Record each screen/display identifier, active state, pixel size, point size, scale, orientation, IO descriptor identity, and screenshot dimensions before and after open/close. Record the runtime and Xcode build. Distinguish a foldable device from a device with multiple simultaneously active displays. Do not assume the external and internal surfaces use IDs 0 and 1.

Use a small existing app with known accessibility controls at several positions. Keep a separate normal iPhone as the control. Use Device Hub or a verified external tool to change fold and rotation state while AXe performs read-only queries and then input. This isolates state control from AXe's current input/capture behavior.

### 2. Introduce one device/display state owner

Define a typed state record with device UDID, boot identity, display identity, fold configuration, orientation, live pixel/point bounds, scale, input coordinate bounds, and a monotonically changing state revision. Record unavailable data explicitly. Do not guess from aspect ratio when the state cannot be determined.

All coordinate commands, capture, and the agent must consume the same record. Use a bounded stability check around observation and action dispatch. If the revision changes, reacquire geometry and AX data before the next action. A 180-degree turn must change the revision even when dimensions stay equal. Do not hold old contact state across a display change.

Keep the provider boundary in one owned module. Put IDB transport changes in the pinned fork, with an exact revision and build evidence. Do not patch the generated local checkout as the release method.

### 3. Add state reporting, then state changes

First expose a machine-readable state/capability command. It must show what AXe can observe and control on this runtime. Include unsupported operations and useful failure reasons.

Then add explicit set-state commands for the fold configurations and orientations that the device actually supports. Prefer idempotent requests to toggles. A command returns success only after observed state matches the request and display geometry is stable. Bound the wait and report the actual state on failure. Provide batch and agent access only after the direct CLI contract works.

New command names and options in this report are proposals, not existing features. Update the README, command documentation, skill source, and changelog with implementation. Skill changes must use the skill-creator workflow and pass skill-check.

### 4. Repair geometry and input as one change

Read active geometry, not a fixed device-type size. Verify the transport's target semantics. Route gesture presets through the same transform as tap, touch, swipe, drag, and slider. Derive preset bounds from the active viewport; retain explicit user overrides with defined units.

Invalidate broker/session geometry, agent mapping, and AX handles when required by a state change. Reject or cancel a gesture if its display changes after contact down. A failed or uncertain send must not replay the contact down and cause a duplicate action.

Keep screen points, screenshot pixels, app-window points, and normalized HID coordinates as distinct types or clearly named structures. Include window origin and scaling when the app does not fill the active screen.

### 5. Define capture continuity

Select the active display explicitly. Rebind when its descriptor changes. Handle IOSurface replacement within a descriptor. Pair each captured frame with state metadata in an optional sidecar or framed stream format.

For MP4, use a documented fixed canvas with aspect preservation, or stop one segment and start another on size change. Preserve the existing behavior unless Cam approves a changed contract. For raw BGRA, provide a defined resize event through a framed output mode or end the stream with a clear resize reason. Do not silently change unframed image dimensions.

### 6. Make support claims from manual evidence

Run the matrix below through public CLI commands and the real app UI. Save stdout, stderr, screenshots, state records, and elapsed times. Check the resulting UI change, not only exit status. No new automated tests are required by this audit; Cam must request them before they are added.

## Proposed manual acceptance matrix

| Dimension | Cases | Required evidence |
|---|---|---|
| Stable Duo states | Each supported fold configuration, each allowed orientation | Correct state record, AX root/window frames, active screenshot dimensions and content |
| Input placement | Center, near each usable corner, edge gesture, scroll, drag, slider, keyboard focus | App-visible result at the intended target; no scaled or mirrored hit |
| State transitions | Open to closed, closed to open, both 90-degree directions, 180-degree turn | New state revision, refreshed input/capture mapping, first action after transition correct |
| Active operations | Change state during a drag, stream, recording, batch, and delayed agent decision | Defined cancellation or continuation; no stuck touch, stale screenshot, stretched content, or duplicate action |
| App layouts | Adaptive app, portrait-only app, landscape-only app, keyboard shown, sheets/alerts, supported multi-window layouts | AX, capture, and input agree on the active content and origin |
| Recovery | Simulator reboot, app relaunch, Device Hub reopen, external tool changes state | Correct reconnect and bounded failure; no old display cache reused |
| Control devices | Existing iPhone 17 Pro Xcode 26/27 paths; one small iPhone; one iPad | Existing operation behavior preserved; preset geometry correct |

## Performance comparison method

Do not compare one tool's send completion with another tool's visible UI completion. Define each operation's start and end in the same way. Record both command latency and app-visible completion latency where possible.

Measure cold command start, warm repeated command, accessibility fetch, screenshot, tap, drag, fold completion, rotation completion, first correct frame after a state change, and first correct input after a state change. For streams record effective FPS, frame age, CPU, memory, and dropped or stale frames. Keep device/runtime/app/screen and capture resolution equal. Use the same target points and gesture duration. Report median and p95 from repeated runs, with failure counts. Separate setup and permission prompts from steady operation.

AXe has costs worth measuring, not assumed timing results: framework startup; AX collection; private orientation lookup; a possible PNG screenshot probe with a three-second timeout; HID broker connection; and the 80 ms DTUHID drain. Batch and persistent agent sessions can reduce some startup costs, but their cache correctness must be checked through transitions. Comments that mention 3 ms, 130 ms, or 250 ms in the agent source are prior developer notes, not measurements from this audit.

## Other support gaps

- Fixed-size gesture presets and app-frame-as-screen assumptions affect iPads, multi-window apps, and other iPhone sizes.
- There is no exposed secondary-display selection for capture, AX, or input.
- Commands use the default simulator device set; custom device-set paths are not exposed consistently through the CLI.
- Physical iPhone, iPad, watchOS, tvOS, and visionOS control is not established by importing FBDeviceControl or by listing simulator records.
- Existing evidence is concentrated on iPhone 17 Pro. Device discovery, fixed-state input, state changes, accessibility, screenshots, and recording need separate support claims.

## Audit verification record

On 16 October 2026, the following read-only checks ran in /Volumes/Developer/AXe:

- git status --short; git branch --show-current; git rev-parse HEAD: confirmed the branch, candidate, and pre-existing dirty worktree.
- git -C idb_checkout rev-parse HEAD; git -C idb_checkout status --short: confirmed the pinned clean IDB checkout.
- Source searches with rg and reads through node:fs/promises: confirmed the cited code paths. No source was edited.
- otool -L build_products/XCFrameworks/FBSimulatorControl.xcframework/macos-arm64_x86_64/FBSimulatorControl.framework/Versions/A/FBSimulatorControl: confirmed the listed local framework links for arm64 and x86_64.

Known unverified areas: all live Duo behavior, the meaning of DTUHID target on Duo, current Apple public fold APIs, simulator transition timing, active descriptor changes, physical device support, and cross-tool latency. The main audit must combine this source report with live and vendor evidence before it makes a complete support claim.
