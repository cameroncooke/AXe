# iPhone Duo UI interaction audit — 2026-10-16

## Scope

This report checks UI navigation, target selection, and input after a rotation request. It separates command acceptance from the intended app result. See [command parity](2026-10-16-duo-ui-command-parity.md) for the full installed command matrix, [candidate provenance](2026-10-16-duo-axe-candidate.md) for the AXe build, and [earlier live audit](2026-10-16-duo-live-audit.md) for pose, capture, and read latency evidence.

The root worker ran the commands. A second worker read the saved command results and viewed the before/after PNGs independently. The evidence is in [evidence/2026-10-16-duo/ui](evidence/2026-10-16-duo/ui/). JSON preserves command, exit status, duration, stdout, and stderr; embedded JSON was normalized and preview URLs were removed. The device is a new audit simulator; About values are synthetic simulator data.

Environment: Xcode 27.2 beta 3 build 27B5038j, iOS 27.2 build 24B91011, iPhone Duo simulator 3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463. FlowDeck 1.33.0; RocketSim 16.7.0 build 337; AXe v1.8.0-1-g7163081-dirty, fresh candidate at /private/tmp/axe-duo-audit-20261016/build/out/Products/Debug/axe. AXe SHA-256: 08dfa7f0720ff0659cd037517cb77a7789adf07ff4b7f97e7d11ac11ce64458e. Existing source changes were preserved. No source edits or new tests were made for these checks.

## Unique target navigation

All valid attempts start at Settings > General with the About row visible. AXe and FlowDeck use the unique accessibility ID com.apple.settings.general.about. RocketSim uses label About plus type button; its current tree contains one matching button. This avoids the duplicate Settings-label case in the earlier audit.

| State and tool | Command, with shared UDID omitted | Exit and reported result | Independent visual result |
| --- | --- | --- | --- |
| Open; initial requested portrait; AXe | axe tap --id com.apple.settings.general.about | 0; completed successfully at (603.5, 329.6667) | General remains; About did not open |
| Same state; FlowDeck | flowdeck ui simulator tap com.apple.settings.general.about --by-id --json | 0; resolved ID; output point (329, 347) | About opens |
| Same state; RocketSim valid repeat | rocketsim interact tap --label About --type button | 0; ok true; screen_changed false | General remains; About did not open |
| Open; after requested landscape-left; AXe | axe tap --id com.apple.settings.general.about | 0; completed successfully at (459.5, 386.6667) | General remains; About did not open |
| Same state; RocketSim | rocketsim interact tap --label About --type button | 0; ok true; screen_changed false | General remains; About did not open |
| Same state; FlowDeck | flowdeck ui simulator tap com.apple.settings.general.about --by-id --json | 0; resolved ID; output point (386, 209) | About opens |

For initial AXe and FlowDeck, inspect initial.png, open-p-axe-about-after.png, and open-p-flow-about-after.png. AXe leaves the common starting screen unchanged before FlowDeck runs. For the valid RocketSim repeat, inspect open-p-rocket-valid-before.png and open-p-rocket-valid-after.png. Each rotated action has its own left-TOOL-before.png and left-TOOL-after.png. All six valid baselines show General.

These checks prove that AXe accepted two unique-ID tap commands without the intended navigation, and RocketSim accepted two selector taps without navigation. FlowDeck completed the same navigation in both observed states. They do not establish failure rates, all-app behaviour, or full support in any tool.

## Coordinate evidence

| Read | AXe application frame | AXe About frame | FlowDeck application frame | FlowDeck About frame |
| --- | --- | --- | --- | --- |
| Initial | 669 × 951 | x340, y303.6667, w527, h52 | 669 × 951 | x303, y84, w52, h527 |
| After rotation request | 669 × 951 | x270.3333, y360.6667, w378.3333, h52 | 951 × 669 | x360, y20, w52, h378 |

The selected display PNG changes from 2853 × 2007 pixels to 2007 × 2853 pixels. The visible layout changes with it. AXe's application frame stays 669 × 951 while its child frames change. FlowDeck's frame axes and action points differ from AXe's. The numeric values alone do not establish that one public coordinate contract is wrong. Native display coordinates, app accessibility frames, screenshot pixels, CLI points, and HID normalized coordinates can use different spaces. Conversion must be explicit at each boundary.

The successful FlowDeck action points are consistent with a quarter-turn conversion of the AXe target centres, within rounding: initial (y, 951-x), then (y, 669-x). This is an inference from two observed points, not proof of FlowDeck's implementation or a complete transform for all states.

The failed AXe navigation and differing transforms support a coordinate-chain defect. These records do not isolate target mapping from HID transport normalization or display routing. A targeted trace of the selected display, mapping, transport geometry, and final HID coordinates is still required before a source fix.

The FlowDeck orientation command exits 0 and reports success true, but confirmed false and visualOrientation unknown. Therefore these rows use the requested orientation and observed geometry. They do not claim visual orientation confirmation from that command.

## Invalid baselines and reset limits

The first RocketSim About attempt followed a failed reset and is excluded. Its files are open-p-rocket-about.json and open-p-rocket-about-after.*; use only open-p-rocket-valid-* for the initial RocketSim comparison.

RocketSim semantic activation of General returned ok true with screen_changed false and did not establish the needed reset. FlowDeck's back command also returned success true but left About visible. A later FlowDeck coordinate tap at (148,48) did return to General in the initial state. Reusing that coordinate after rotation was not a valid general reset method; the target geometry had changed. After rotation, a fresh FlowDeck point (48,375) returned to General; left-coordinate-back-after.png confirms it. These reset outcomes show why the before image must be checked separately for each action.

## Swipe and scroll samples

These six attempts ran sequentially in the open device after the landscape-left request. Each has its own before/after capture. They are outcome checks, not a performance benchmark or proof of identical coordinate contracts.

| Evidence prefix | Action | Command result | Observed result |
| --- | --- | --- | --- |
| axe-swipe | swipe from (459,750) to (459,400), duration 0.5 s | Exit 0 | Neither pane visibly moved |
| rocket-swipe | interact swipe with the same endpoints and duration | Exit 0; screen_changed false | Neither pane visibly moved |
| axe-preset | gesture scroll-up, default 390×844 preset geometry | Exit 0 | Neither pane visibly moved |
| flow-swipe | ui simulator swipe from (750,210) to (400,210), duration 0.5 s | Exit 0; changed false | Neither pane visibly moved |
| flow-scroll | ui simulator scroll --direction DOWN --distance 0.4 | Exit 0; moved false, reached_end true, stalled true | Neither pane visibly moved; actual end of content was not proved |
| rocket-scroll | interact scroll --id 1 --direction down --pages 1 --screen eede300e | Exit 1; invalid_argument/no_scrollable_ancestor | Ineligible Sidebar group target. Excluded from valid-scroll failure comparison |

The explicit endpoints were chosen for the General pane using each tool's observed frame space: AXe/RocketSim (459,750)→(459,400), FlowDeck (750,210)→(400,210). The preset used its defaults. These results prove no visible movement for the five accepted samples. They do not prove that all directions, coordinate choices, or containers fail. RocketSim still requires discovery of a valid scrollable container.

## ASCII text input

All three tools entered the requested ASCII text in the open device after the landscape-left request. FlowDeck established Search focus for every case. The first focus used point (903,544); the later cases used fresh focus and empty-field readback. Each final PNG shows the exact text and its matching No Results message. Separate FlowDeck screen reads confirm the TextField values.

| Tool | Command, with shared UDID omitted | Exit | Verified TextField value |
| --- | --- | --- | --- |
| AXe | axe type DuoAudit | 0 | DuoAudit |
| FlowDeck | flowdeck ui simulator type FlowAudit --json | 0 | FlowAudit |
| RocketSim | rocketsim interact type RocketAudit | 0 | RocketAudit |

This verifies ASCII injection after focus. It does not prove AXe or RocketSim field targeting, a full independent focus-and-fill workflow, Unicode input, or closed-display typing. The first-run keyboard tip remained visible during these checks; it did not prevent the observed text entry.

Evidence: type-focus.*, type-focus-after.*, axe-type*, flow-type*, and rocket-type*. The focus-read records show the empty Search placeholder before each competitor case.

## Required repairs

### P0: correct the input coordinate chain

1. Create one input context that identifies the active display, native and app orientation, logical bounds, pixel bounds, scale, and state generation. Acquire AX elements and send HID input against that same context. Do not infer active display from a fixed screen ID or assume the device type's main-screen geometry is current.
2. Trace and verify each conversion: app AX frame → action point → display coordinates → normalized HID coordinates and target. Select the display explicitly where the supported interface permits it. Fail clearly where the required display state cannot be established.
3. Invalidate AX roots, coordinate maps, and retained transport geometry after fold, display change, or rotation. Re-resolve just before sending. If the generation changes, cancel and release active contacts safely. Do not replay a possibly completed action without an outcome check.
4. Route gesture presets and point queries through the same conversion. Derive preset bounds from the active viewport.

Exact source anchors: Sources/AXe/Utilities/SimulatorOrientationReader.swift:55 selects screen ID 1; OrientationAwareCoordinates.swift:145-220 combines AX root aspect with orientation and fallback heuristics; :255 has no screenshot display option. idb_checkout/FBSimulatorControl/HID/FBSimulatorDTUHIDTransport.swift:114-123 retains main-screen geometry and :139-155 normalizes contacts from it. DTUHIDModels.swift:54-72 gives target a default value of 0; its display meaning is not proved here. Sources/AXe/Agent/SimulatorAgentExecutor.swift:221-241 keys its map cache only by viewport. Sources/AXe/Utilities/Batch/BatchContext.swift:45-58 caches roots per batch. HIDBrokerReadiness.swift:6-36 checks boot identity, not fold/rotation state. Commands/Gesture.swift:172-204 bypasses the shared conversion; Utilities/AccessibilityFetcher.swift:51-65 does so for point lookup.

### P1: reach usable automation parity

- Add public find results bound to a snapshot/generation, read-only wait/assert, and explicit accepted-versus-verified action results. Preserve the slider command's existing AXValue postcondition.
- Add selector-based gesture endpoints, batch drag/slider, and named double-tap/long-press with defined timing. Existing low-level touch already supports a held press.
- Expose the fork's existing pinch/two-finger implementation after display routing is correct. Sequential single touches cannot replace simultaneous contacts.
- Add text readback and broader character input; define support for vertical/RTL sliders and transport-specific hardware buttons.
- Verify refind after rotation/folding in the CLI, batch, and agent separately. Agent semantic refind exists; the missing part is a reliable display/generation contract.

## Verification still required

The current samples do not test AXe raw coordinate taps, double taps, held touch, arbitrary drag, sliders, two-finger actions, a full AXe focus-and-fill workflow, keyboard shortcuts, app switching, or expected-result assertions. These samples do not test closed/partial pose input, every orientation, repeated fold cycles, mid-gesture transitions, or stale guards. Source capability and installed help are recorded in the separate command parity report.

No source change is approved or delivered by this report. Repair acceptance requires a fresh candidate and manual outcomes for each input family across the relevant display and orientation states.

## Handoff

The root worker reports that the audit text was cleared. The saved FlowDeck Home command exited 0; no final Home screenshot was retained for independent visual confirmation. The saved xcrun simctl shutdown command for the audit UDID exited 0. Cleanup records are finish-home.json and finish-shutdown.json. Only the audit simulator was targeted.

Candidate continuity was checked after the live run against /private/tmp/axe-duo-audit-20261016/source-manifest-after.sha256. The root worker and this review independently hashed the listed files: 67 checked, 0 changed, 0 missing. This ties the reviewed current sources to the candidate source manifest. The root worker also reports git diff --check passed, local documentation links resolved, and no preview URL token remained.
