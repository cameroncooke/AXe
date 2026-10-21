# FlowDeck and RocketSim bundle audit

Date: 16 October 2026. Read-only inspection of the installed products. This report complements the AXe source audit and the separate live CLI checks.

## Scope and evidence rules

Inspected FlowDeck CLI at /Users/cameron/.local/share/flowdeck, identified as version 1.33.0 by the main audit. Inspected RocketSim at /Applications/RocketSim.app. Its Info.plist independently reports version 16.7.0, build 337, bundle ID com.swiftLee.RocketSim, minimum macOS 15.2, and LSUIElement=true. The RocketSim app and its FBSimulatorControl framework record Xcode 27.1 build 27A9275.

The inspection covered bundle layout, metadata, linked libraries, imported and exported symbols, selected embedded strings, Duo device resources, the CLI launcher, and shipped command documentation. It did not execute a private API, control a simulator, open user preferences, inspect licenses/accounts, read credentials, or change an installation.

Evidence classes used below:

- Metadata: a file or Mach-O field states the value.
- Link/import: compiled code refers to a framework or symbol. This is stronger than a plain string but does not prove that a particular command used it in this session.
- Export: a framework supplies the named function or type. This does not prove a caller uses it.
- String: a type name, selector, diagnostic, or constant is present. It can describe an inactive or error path.
- Documentation: a shipped usage claim. It still needs a live check.
- Inference: a proposed explanation based on the above evidence, not observed runtime behavior.

No complete source code or exact source revision for either installed product was recovered. Matching framework names and version 1.0 metadata do not mean the implementations are equal.

## Bundle identity

| File | Architecture | SHA-256 |
|---|---|---|
| FlowDeck flowdeck | arm64 | be960e49a06c8300edad8cb678f72df1cc827a757b863cdad3ce761fa766b31f |
| FlowDeck FBSimulatorControl | arm64 and x86_64 | c403757e8e4a8486f305d84eaacbc0e6d240e8d6ab221612cdc9248c269ec53d |
| RocketSim main executable | arm64 and x86_64 | c2876fcfb3e95de3eb172bf1615408bb024621be4ab805598de38492fe8fa4c4 |
| RocketSim FBSimulatorControl | arm64 and x86_64 | 559c7d4ca98f138a1cb6234a8de2b60fd9a0bf3a36607d4593bc3c92bc9bd90c |

Hashes identify the inspected bytes. They do not by themselves establish vendor authenticity or latest release status.

FlowDeck occupies about 126 MB and includes FBControlCore, FBSimulatorControl, FBDeviceControl, and XCTestBootstrap frameworks. It also has project-creation resources, XcodeGen resources, an AppStoreConnectAPITests resource bundle, and FlowDeck Virtual Mac.app. That app links Virtualization.framework and has bundle ID studio.flowdeck.virtualmac. It is a separate virtual-machine component.

RocketSim occupies about 83 MB. It embeds FBControlCore, FBSimulatorControl, XCTestBootstrap, Sentry, and RocketSimConnectLinker.nocache frameworks. It has a RocketSimNetworkExtension system extension, a Helpers/rocketsim executable, a Resources/CLI/rocketsim shell launcher, and an Agent-Skill/rocketsim documentation tree. Other resource bundles cover capture, Xcode control, audio, diagnostics, and the capture editor.

RocketSim's LSUIElement metadata fits a menu bar app. FlowDeck's inspected package does not contain a separate named menu bar app. FlowDeck strings such as ui mac menubar list describe control of other macOS menu items. No NSStatusItem or SwiftUI MenuBarExtra import was found in the CLI import search. This absence is not proof that no menu bar integration exists elsewhere; it is not valid evidence that CLI installation also installs one.

## Shared foundations and different integration choices

Both main executables link FBSimulatorControl, FBControlCore, and XCTestBootstrap. FlowDeck also links FBDeviceControl. This gives AXe a direct technical comparison point: all three have IDB-family foundations.

FlowDeck imports Objective-C FBSimulator, FBSimulatorControl, FBSimulatorHID, IOSurface size/ID/seed functions, dlopen/dlsym, and XPC dictionary/connection functions. Its main executable contains FlowDeckSimulatorCore, FlowDeckSimulatorHID, and FlowDeckSimulatorControl type names. The bundled FBSimulatorControl still exposes the older mainScreenSize/mainScreenScale and Indigo message strings. Inference: significant newer Duo logic lives in FlowDeck's own compiled modules, alongside its bundled IDB framework. This is not proof that every input bypasses IDB.

RocketSim imports Swift FBSimulatorControl APIs for hinge sessions, multiple screen framebuffers, and screen-property observation. These APIs are also exported by its bundled FBSimulatorControl. This is strong evidence that its IDB-family framework includes a newer display and hinge abstraction than AXe's current pin. The binary does not provide the fork URL or commit.

RocketSim's FBSimulatorControl weakly links CoreSimulator. Its capture links include IOSurface, Metal, VideoToolbox, and IOKit. RocketSim's main app also links ScreenCaptureKit, MetalKit, and RealityFoundation. FlowDeck's main executable links ScreenCaptureKit and IOKit. A link does not establish that Duo capture uses ScreenCaptureKit; the framebuffer symbols give a separate and more specific capture path.

SimulatorKit need not appear as a normal load command. FlowDeck has paths for both Library/PrivateFrameworks/SimulatorKit.framework and SharedFrameworks/SimulatorKit.framework, plus IndigoHIDMessageFor functions and SimulatorKit.SimDeviceLegacyHIDClient strings. Dynamic loading means otool -L alone is incomplete.

## FlowDeck Duo evidence

| Evidence | Class | What it establishes |
|---|---|---|
| simulator pose set closed, partially-folded, open, angle; angle validation 0 through 180 | String and main-audit CLI help | Explicit fold control exists in the command surface. Numeric angle control is available. |
| simulator pose get with stream, interval, and change-threshold examples | String and main-audit CLI help | A continuous observation interface is present. |
| com.apple.CoreSimulator.SimDeviceType.iPhone-Duo | String | Explicit device-type recognition exists. |
| Xcode 27.1 or later requirement and unavailable Duo HID/motion errors | String | Capability gating and error paths are present. |
| com.apple.coredevice.feature.remote.hid.vendordefined, hinge-slider-control, IndigoVendorDefinedEvent | String | Consistent with vendor-defined HID for hinge mutation. Payload shape and actual executed calls remain unverified. |
| com.apple.coredevice.feature.monitormotion and com.apple.coredevice.action.streamhingeangle | String | Consistent with a separate motion stream for hinge readback. |
| com.apple.coredevice.action.streamdevicemotionstate and remote.devicecontrol.orientation | String | Distinct device-motion observation and orientation-control paths are represented. |
| SimulatorDuoOrientationGate, SimulatorDuoMotionMonitor, DuoOrientationStateStore | String/type metadata | Orientation has dedicated Duo state and coordination components. |
| Duo hinge-selected display is not available; Duo active display is unavailable or ambiguous | Diagnostic string | Display selection is checked and can fail explicitly. |
| frontmostApplicationWithDisplayId:bridgeDelegateToken: and Duo accessibility screen is unavailable | Selector/diagnostic string | Accessibility has a display-specific path. The active numeric display ID was not recovered. |
| pixelSize, nativeRotationDegrees, powerState, selectedDuoDisplay | String/type field | Display geometry and native rotation are represented separately. |
| The iPhone Duo hinge did not reach the requested value | Diagnostic string | A readback check is represented. Timeout and tolerance were not established from this inspection. |
| Invalid physical hinge sample, malformed/oversized monitor-line diagnostics | Diagnostic string | Parsing and sample validity have explicit failure paths. |

FlowDeck also contains a path named data/Library/Preferences/com.flowdeck.duo-orientation. This is evidence of a state-store path in code only. The file was not opened. Its existence, persistence rules, and correctness across launches were not checked.

The likely design is: resolve capabilities; maintain a Duo state/motion session; select the active display; send a vendor hinge event or orientation request; then read back state. That is an inference from the type and diagnostic names, not reconstructed source code.

## RocketSim Duo evidence

The RocketSim main binary imports these framework APIs, confirmed with nm and Swift demangling:

- FBSimulator.hingeAngle() and FBSimulator.makeHingeSession().
- FBSimulatorHingeSession.setAngle() and finish().
- FBSimulator.connectToAllScreenFramebuffers().
- FBFramebuffer.screenDescriptor and observeScreenProperties().
- FBFramebufferScreenDescriptor.pixelSize, screenType, and uiOrientation.

Its framework exports additional related APIs:

- FBFramebuffer.screenSurface(for:screenID:logger:) and a predicate-based screen selector.
- FBFramebufferScreenDescriptor fields screenID, uniqueID, name, pixelSize, isDefault, powerState, screenType, uiOrientation, and backlightState.
- FBSimulatorHingeAngle.vendorEvent(), with validated angle construction.
- FBSimulatorHingeProtocol.request(), sample(channel:notBefore:now:), and checkReply().
- FBSimulatorHingeReadSession.read(), with a constructor that accepts timeout, channel UUID, and clock.
- FBSimulatorDTUHIDTransport.setAngle() and a separate FBSimulatorHingeWriteTransport protocol.

These are more than generic IDB imports. They show an explicit hinge read/write lifecycle, time-qualified samples, screen enumeration, and observed screen properties. Runtime correctness and payload details still need live/source verification.

Relevant framework strings include the vendor-defined HID service, hinge-slider-control, IndigoVendorDefinedEvent, the motion-monitor service, and streamhingeangle. It also contains screen connection/disconnection and frame/surface/property callback selectors. Accessibility selectors include both frontmost and at-point queries with displayID. This is consistent with display-specific AX and capture.

The app contains LiveSimulatorDuoHingeController, SimulatorDuoHingeSessionBroker, SimulatorDuoPoseController, and SimulatorDuoPostureBroker type names. Its helper describes duo pose as direct hinge control without Device Hub. The shipped skill documents closed, book, and open poses, plus a hinge read with closed, openFlat, and partiallyOpen states. It says pose control does not need macOS Accessibility permission. These command semantics are documentation claims until the live audit confirms them.

### Capture and fold rendering

The app has DuoFramebufferRecorder, DuoPanelFrames, LiveDuoPanelFrameSource, DuoScreenStreamFactory, and DuoScreenshotPanelSelector types. It also has DuoHingeTimelineRecorder, DuoRecordingArtifacts, DuoPhysicalOrientationReconciler, DuoPanelOrientationMapper, and per-panel touch-painting types.

Diagnostics refer to separate inner and outer video tracks, recording sidecars, hinge timelines, panel orientation, and a missing hinge reading fallback that chooses by frame brightness. The fallback string does not prove when the fallback runs, or whether it works reliably.

The 3D path has DuoFoldRenderer, DuoFoldCompositor, DuoFoldVideoComposer, and preview/thumbnail types. Diagnostics reference Metal uploads, RealityKit completion, fold animation in a V68.usdz model, and a model found through the selected Xcode. This model is not shipped as a visible standalone USDZ file in the RocketSim bundle inventory. The error asks for Xcode 27.1 or later. Inference: frame capture, fold timing, and 3D presentation are separate stages. AXe needs capture correctness first; a 3D marketing export is a separate product decision.

The shipped documentation says plain screenshot selects the outer display while closed and inner display while open. Styled screenshot/video renders the current hinge pose, and device3d explicitly selects the fold model. The installed code has substantial supporting components, but static inspection does not verify the visual result.

## Duo device resource details

RocketSim ships XcodeControl_XcodeControl.bundle/Contents/Resources/iPhone Duo capabilities.plist and iPhone Duo profile.plist. The profile identifies model iPhone19,4. The capability file has:

| Resource array entry | Display type | Pixels | Scale | Native rotation | Derived point size before native rotation |
|---|---|---|---|---|---|
| 0 | integrated | 1398 by 2034 | 3 | 0 degrees | 466 by 678 |
| 1 | integrated | 2007 by 2853 | 3 | 270 degrees | 669 by 951 |
| 2 | tvOut | 720 by 480 | 1 | 0 degrees | 720 by 480 |

The main-screen resource values match entry 0. These are bundled defaults, not live geometry. The array indexes are not verified runtime screen IDs. The 270-degree native rotation is a concrete reason to avoid treating every display as a portrait rectangle whose only state is width versus height. The current Xcode definition and live descriptors must establish the authoritative values.

## CLI and process boundary

RocketSim's helper strings and shipped skill describe a local IPC socket and the rs/1 response envelope. The launcher resolves itself, then execs Contents/Helpers/rocketsim. It checks CODEX_SANDBOX=seatbelt and emits sandbox_unavailable rather than starting the sandboxed helper inside another sandbox. Root handles installation and live invocation; no helper was executed during this inspection.

This architecture affects performance comparison. RocketSim's command can use a running app and shared hinge/capture sessions. FlowDeck is a standalone CLI with its own session types. AXe has both one-shot commands and a persistent HID broker. Compare cold start and warm operation separately, and include readback/visible completion. The presence of a persistent broker is not proof of lower latency.

## Lessons for AXe

1. Treat hinge readback as a separate channel from hinge mutation. Use timestamps/freshness, bounded waits, and explicit failure reasons.
2. Enumerate screens and observe their properties. Make screen identity, native rotation, pixel geometry, power state, and AX display identity explicit.
3. Use one state owner for capture, coordinates, and actions. Do not mix one display's orientation with another display's framebuffer or AX tree.
4. Keep input connections and active contacts under a clear session lifecycle. Define what changes on close/open and which state must be reacquired.
5. Keep inner/outer capture and fold timeline data distinct if recording transitions. Define the output contract before adding visual decoration.
6. Seek the source and license for the newer IDB hinge/screen APIs before a fork update. Do not infer an upstream commit from a framework version string or copy unverified wire constants.
7. Follow-up: Cam has explicitly requested private-framework investigation. See [control mechanism findings](2026-10-16-duo-control-mechanisms.md). Validate bindings, protocol, and state readback before integration; static symbols alone do not prove a working control path.

## Reproducible inspection commands

The following commands ran. Output was filtered or bounded where noted. Shell file inspection used metadata tools, rg, and node:fs/promises; no cat or sed read was used.

- rg --files /Users/cameron/.local/share/flowdeck /Applications/RocketSim.app
- du -sh /Users/cameron/.local/share/flowdeck /Applications/RocketSim.app
- file /Users/cameron/.local/share/flowdeck/flowdeck /Applications/RocketSim.app/Contents/MacOS/RocketSim
- plutil -p /Applications/RocketSim.app/Contents/Info.plist
- plutil -p '/Applications/RocketSim.app/Contents/Resources/XcodeControl_XcodeControl.bundle/Contents/Resources/iPhone Duo capabilities.plist'
- plutil -p '/Applications/RocketSim.app/Contents/Resources/XcodeControl_XcodeControl.bundle/Contents/Resources/iPhone Duo profile.plist'
- otool -L /Users/cameron/.local/share/flowdeck/flowdeck
- otool -arch arm64 -L /Applications/RocketSim.app/Contents/MacOS/RocketSim
- otool -arch arm64 -L /Applications/RocketSim.app/Contents/Frameworks/FBSimulatorControl.framework/Versions/A/FBSimulatorControl
- otool -L /Users/cameron/.local/share/flowdeck/Frameworks/FBSimulatorControl.framework/Versions/A/FBSimulatorControl
- strings /Users/cameron/.local/share/flowdeck/flowdeck, filtered with rg for hinge, Duo, orientation, display, HID, motion, SimulatorKit, and menu bar terms.
- strings -arch arm64 /Applications/RocketSim.app/Contents/MacOS/RocketSim, with the same targeted searches.
- strings /Applications/RocketSim.app/Contents/Helpers/rocketsim, filtered for Duo and IPC terms.
- nm -arch arm64 -u /Users/cameron/.local/share/flowdeck/flowdeck
- nm -arch arm64 -u /Applications/RocketSim.app/Contents/MacOS/RocketSim | xcrun swift-demangle
- nm -arch arm64 -gU /Applications/RocketSim.app/Contents/Frameworks/FBSimulatorControl.framework/Versions/A/FBSimulatorControl | xcrun swift-demangle
- shasum -a 256 on the four files in the identity table.

A first bare swift-demangle invocation failed because that command was not on PATH. The xcrun form succeeded. This affected only symbol formatting.

Read in full as artifact data: RocketSim's bundled FBSimulatorControl README, Agent-Skill/rocketsim/SKILL.md, and Resources/CLI/rocketsim. The README includes old general statements, including Pure Objective-C, that are contradicted by the current Swift symbol exports. It is not a reliable source for the exact current implementation.

## Limits

This is a targeted static audit, not a full disassembly or proof of every runtime path. It does not establish complete Duo control, successful fold/rotation transitions, screenshot correctness, stream continuity, latency, or physical device behavior. It does not identify a verified public Apple fold API. Combine these findings with the live report and vendor source/release evidence.
