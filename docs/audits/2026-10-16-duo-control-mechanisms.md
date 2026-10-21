# Duo control mechanisms: private-framework investigation

Date: 16 October 2026. Repository: main at 7163081400b59f1df40bff44f3a94dded38eea9a, with existing dirty source preserved. This is investigation evidence, not delivered AXe support.

Cam has explicitly asked to investigate Apple's private frameworks and the competitor implementations. This supersedes the earlier audit recommendation to require a public Apple control API before this investigation. Private interfaces are already part of AXe's architecture. Version checks, typed bindings, observed readback, and clear unsupported results remain required.

## Shared foundation, different code

Fresh symbol and link inspection confirms that AXe, FlowDeck, and RocketSim use IDB-family frameworks. The implementations are not identical.

| Tool | Direct binary/source evidence | Ownership lesson |
|---|---|---|
| RocketSim | Its FBSimulatorControl exports FBSimulator.setHingeAngle, makeHingeSession, FBFramebuffer.allScreenSurfaces, screenSurface(screenID:), and observeScreenProperties. Its app imports the hinge/session and screen APIs. | RocketSim extended its IDB layer with hinge and multi-screen state. |
| FlowDeck | Its main CLI exports SimulatorDTUHIDMessage.vendorDefinedHingeAngle, digitizer(...target: UInt64), SimulatorHIDSession.sendTouch(...target:), and LiveSimulatorControl.setDuoHingeAngle(...waitForSettle:). Matching hinge APIs were not found in its bundled IDB export search. | FlowDeck has its own control layer around the same Apple mechanisms. Updating its bundled IDB alone would not explain its Duo support. |
| FlowDeck display control | Its main CLI exports integratedDisplays, selectIntegratedDisplay, setIntegratedDisplayPower, and setDisplayBacklightActive. Metadata includes screenID, portIdentifier, powerState, pixel size, and nativeRotationDegrees. | Display selection and power are explicit parts of its internal model. These symbols do not establish a public CLI option or prove the runtime path for every action. |
| AXe | Package.swift includes private CoreSimulator, CoreSimDeviceIO, SimulatorKit, and accessibility headers. Its IDB transport already uses private DTU/XPC mechanisms. | Extend the existing architecture; a public-only replacement is not required for the authorized investigation. |

See [fresh symbol evidence](evidence/2026-10-16-duo/control/competitor-manifest.json), [FlowDeck display interfaces](evidence/2026-10-16-duo/control/flow-cli-display-exports.txt), [FlowDeck HID interfaces](evidence/2026-10-16-duo/control/flow-cli-exports.txt), and [RocketSim framework interfaces](evidence/2026-10-16-duo/control/rocket-framework-exports.txt). Exported interfaces establish compiled capability, not the exact executed payload or source implementation. Exact vendor fork revisions have not been established.

## Concrete gaps in our source

1. **Accessibility:** IDB FBAXTranslationRequest.swift lines 67, 69, and 199 pass displayId 0 for frontmost, point, and remote-content queries. PrivateHeaders/AccessibilityPlatformTranslation/AXPTranslator.h lines 107 and 113 already declare display-specific APIs. Thread a selected display through those requests and their results.
2. **Framebuffer:** FBFramebuffer.swift line 48 selects the first displayClass 0 descriptor. Duo has two integrated displays. Enumerate and select a screen explicitly, then observe its changes.
3. **Touch geometry:** FBSimulatorDTUHIDTransport.swift lines 114–123 cache device-type main-screen size and scale; lines 139–155 normalize touches with them. Use the selected display's current geometry.
4. **Touch target:** DTUHIDModels.swift lines 54–72 include a target field defaulting to 0. Prove the modern target mapping before changing it. SimulatorApp/Indigo.h lines 82–86 describe a legacy screen-ID bitmask and registration requirement; that is a research lead, not proof for modern DTU events.
5. **Hinge:** No hinge binding or session was found in the current IDB source or private headers. Add a validated write event and a separate read/confirmation session.
6. **AXe state:** SimulatorOrientationReader.swift line 55 selects screen 1. Agent mapping reuse depends on viewport size. Broker reuse depends on boot identity. These assumptions do not cover a display switch, rotation with unchanged dimensions, or folding within one boot.

The low-level bindings, screen enumeration, routing, and hinge sessions belong in the IDB fork. AXe should own command options, shared action context, stale-state rejection, and result reporting. This follows RocketSim's clear framework boundary without claiming to copy its implementation.

## Bounded live hinge probe

Used only the dedicated audit Duo: 3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463. Selected Xcode explicitly with DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer. The global Xcode selection was not changed.

Inspected and compiled the MIT-licensed [hinge helper](https://github.com/artemnovichkov/hinge/blob/7acb090dd7d28fb0aea8e1907211ceff15aa450e/skills/hinge/scripts/hinge_helper.c) at commit 7acb090dd7d28fb0aea8e1907211ceff15aa450e. Its source and license are retained in the evidence directory. This is a temporary guest-side probe, not an AXe production dependency or test suite.

The helper constructs a binary-serialized dictionary with provider com.apple.Virtualization, source hinge-slider-control, type range, and a degree value. It sends a vendor-defined IOHID event with usage page 0xFF61 and usage 0x5B through the simulator's IOHIDEventSystem. FlowDeck and RocketSim contain matching hinge service/event names, but this does not prove an identical end-to-end transport: the helper runs in the guest while their compiled interfaces indicate host-side DTU/CoreDevice paths.

Compile: xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -O2 -o /private/tmp/axe-duo-control-20261016/hinge_helper /private/tmp/axe-duo-control-20261016/hinge_helper.c -framework IOKit -framework CoreFoundation. Ad-hoc codesign succeeded.

Write: xcrun simctl spawn <audit-UDID> /private/tmp/axe-duo-control-20261016/hinge_helper set <angle>.
Read: flowdeck simulator pose get -S <audit-UDID> --json.

| Request | Helper exit | FlowDeck mechanical angle | FlowDeck reported angle | Posture |
|---|---|---|---|---|
| Initial read | Not applicable | 0 | 0 | closed |
| 90 | 0 | 90 | 85.38811492919922 | partially-folded |
| 180 | 0 | 180 | 180 | open |
| 0 | 0 | 0 | 0 | closed |

All read samples reported valid angle, valid velocity, and zero velocity. This verifies three writes against a separate tool's state readback. It is not a physical angle measurement or a complete UI transition check. Mechanical/requested and reported sensor angles must not be treated as equal. The earlier 90-degree timeout may involve that distinction, but its cause is not proved.

The sample project's suggested devicectl motion hinge-angle help invocation returned the parent device help on this installation. It did not establish a working Apple readback command here. FlowDeck supplied the successful readback. Its private motion stream and RocketSim's read-session interfaces remain the references for an AXe-owned reader.

## Display discovery and power probe

Apple's installed simctl io help exposes enumerate and screenConfig --display=<selector> power on/off. It also exposes geometry changes. The selector accepts screen ID, name, device name, screen UUID, or port UUID. Geometry changes were not attempted.

Enumeration returned two Integrated screens in this run: screen 1 at 1398 × 2034 and screen 3 at 2007 × 2853, plus TVOut, CarPlay, and Scene screens. These are observed IDs, not constants for production. Power state on a port is not enough to identify the active Duo panel: both integrated ports reported On in the initial closed state.

Commands run after restoring the hinge to closed:

- xcrun simctl io <audit-UDID> screenConfig --display=1 power off
- xcrun simctl io <audit-UDID> enumerate
- xcrun simctl io <audit-UDID> screenConfig --display=1 power on
- xcrun simctl io <audit-UDID> enumerate

Both power commands exited 0. The outer display's IOSurface entry disappeared after off and returned after on. Its port Power state remained On in both records. This is observable framebuffer lifecycle evidence, not proof of screen appearance, input eligibility, or the exact screen/backlight power value. A typed screen-property readback is still needed. FlowDeck's separate display-power and backlight methods are useful implementation references.

Cleanup: xcrun simctl shutdown <audit-UDID> exited 0. Initial hinge was closed and was restored to closed before shutdown. No other simulator was targeted. bootstatus exited 0 but included Data Migration Failed; this probe does not claim normal app/UI boot acceptance.

## Next implementation investigation

1. Trace FlowDeck's target-bearing digitizer calls and RocketSim's screen descriptor lookup to establish the mapping between AX display ID, CoreSimulator screen ID, port identity, and modern HID target. Do not copy the legacy bitmask without proof.
2. Add an isolated host-side hinge prototype using the existing IDB DTU connection. Compare it with the successful guest event. Include session cleanup, range validation, timeout, and mechanical-versus-sensor readback.
3. Refresh only the required private declarations against the installed framework ABI. Recover typed screen enumeration, property observation, power, and backlight bindings. Header availability alone is not ABI proof.
4. Prove a selected-screen accessibility lookup and tap on each eligible panel. Then check rotation and folding with fresh target resolution. This is the critical missing proof; the present hinge probe does not fix the earlier failed About taps.
5. Carry the same state into AXe queries, all input families, batch/agent actions, and captures. Report accepted input separately from confirmed outcome.

Private-interface compatibility can change with Xcode. Record capabilities and toolchain identity; reject unsupported operations explicitly. No source implementation, dependency update, new automated tests, commit, or push was made in this investigation.

## Evidence and verification

[Control evidence directory](evidence/2026-10-16-duo/control/) contains commands, exit codes, timings, readbacks, selected symbol output, helper source, license, and source revision. Enumeration records retain only Display/DisplayAdapter ports and omit unrelated host audio devices. git diff --check passed after the investigation; pre-existing source changes remain untouched. Full interactive control, modern HID target routing, host-side hinge readback, display power semantics, and multi-display simultaneous input remain unverified.
