# Duo slider ID fix and percentage check — 21 October 2026

Selected slider endpoints now select the exact, unique native slider handle. A sibling named slider.unitState no longer causes a request for slider.unit to fail. The legacy substring search is unchanged.

This completes D10.SLIDER.ID for the cases below. Selected percentage values remain unsupported. The isolated numeric setter changed each real slider value, but sent no UIKit valueChanged event. That route was rejected before product integration.

## Candidate and scope

- Base: 24cca0ef26ed2b52084ee82ac8e55d77b14d142a, wire22.
- CLI SHA256: bca976be21a1e6e4d77e5317a6b62cfc66bf6506584ad9068514b23ac1fe3ad1.
- FBSimulatorControl SHA256: 088440e581b7f42aaed415a3a894f947abaffc35415dcfb1f78703be15fc6a2a.
- One iPhone Duo, profile405, iOS27.2; local Debug arm64.
- Fresh boot72543:1792596915:610193, fixture PID72780. Outer1/AX1 and inner3/AX3 have separate UUIDs in bindings.json.
- Compiler: Xcode27.0 Release Candidate. Guest tools: Xcode27.2 Beta3. Exact command arrays are saved with each build and case.

## Change

The initial tree used exact ID matching. The later native-handle search used contains and returned the earlier StaticText slider.unitState. The final guard then rejected it before input. The new internal search uses exact ID equality, rejects duplicate matches before role filtering and checks the deadline after native selector reads. Label matching retains its existing trimmed, case-sensitive rule. Ownership transfers once; all failure paths close the original handle.

The tracked IDB patch and its61 postimage hashes were updated. Only FBAccessibilityElement.swift, FBSimulatorSlider.swift and FBSimulatorSliderLabelTests.swift changed within that patch. No CLI option, wire version, fallback or timeout changed. After native acceptance, the same three source postimages were promoted to the main IDB cache. All61 prior cache hashes matched before promotion; all61 new hashes matched after it. Old copies are saved. No compiled main runtime was replaced.

## Native verification

| Case | Actual result |
| --- | --- |
| Outer0, exact slider.unit maximum |0.25 to1;8 real callbacks. The earlier slider.unitState remains present. |
| Outer0, exact slider.shifted minimum |5 to-20;3 real callbacks on native range-20...80. |
| Outer0 partial ID, StaticText ID and wrong type | Each rejected with invalidSelection,0 semantic actions and0 touch events. |
| Show duplicate through visible button | One real button effect; contact began and ended. |
| Duplicate ID and exact label | Each rejected before action; both slider values stayed unchanged. |
| Hide duplicate through visible button | One real button effect; contact began and ended. |
| Left rotation, then outer270 exact slider minimum | One rotation write;0 to270 observed twice. Slider1 to0;10 real callbacks. |
| Open180, then exact inner slider maximum | New inner panel observed twice. Slider0 to1;10 real callbacks. |
| Inner partial ID and Fresh button | Prefix rejected with no action. A fresh exact-ID tap produced one button effect and one complete contact. |

All13 cases and two transitions passed. Four slider operations produced31 actual valueChanged callbacks and no HID events. Three button taps produced three complete contacts. No touch remained held. Other slider values and unrelated counters stayed unchanged within each case. This verifies the named endpoint and button paths after settled changes; it does not verify percentage dragging or interruption during a slider action.

The saved verifier checks203 frozen inputs, exact command arrays, raw stdout, native values, callback/action/sample agreement, contact identities, full release and context bindings. It also checks both rejected raw-setter experiments. It sends no input and starts no process.

Run from the repository:

```text
/usr/bin/python3 -B scripts/verify-duo-slider-id-evidence.py --evidence /Volumes/Developer/AXe/build_products/verification/duo-slider-value-20261021 --current
```

Result: PASS_BOUNDED_EXACT_ID,13 cases,2 transitions,2 rejected raw setters. Omit --current to check the frozen copies after future source changes. The before-input manifest is preserved. A later verifier-only correction changed the expected left-turn angle from90 to270; every executed product and driver pin stayed unchanged, and no input was replayed.

## Build and checks

The source checks passed28 Swift Testing functions in3 suites: owned search, exact labels and type filters. They include44 expanded cases in the new owned-search suite, with prefix, case, padding, duplicate-role, depth and deadline checks. The exact command is saved in tests-id-exact-03/started.json. All child commands were reaped.

The first two test builds stopped at an existing private-module interface check. The test bundle then built without distribution interfaces and passed. The final product frameworks built with distribution interfaces enabled. A copied old CLI could not load the new framework during initial read-only setup; that attempt sent no UI input and remains saved as setup03 and runtime-exact-incompatible. The CLI and all four frameworks were then built together. Only that matched candidate sent the13 accepted cases.

## Resource use and remaining work

One guest and one native case ran at a time. Builds used one Xcode job and the final builds also used one Swift compiler job. Sampled physical-footprint peaks were app7.811GiB, simulator4.053GiB and owned command0.491GiB. No resource limit stopped a command. The owned Duo is shut down. The old broker for the separate quarantined guest was preserved; no recovery state was cleared. No Device Hub session was started.

Next: prove a percentage input route that sends normal app change events. The raw setter is not that route. A physical route needs verified thumb/track geometry, fresh target checks, client cancellation, fold/rotation stop and contact release before integration. Apple's installed UISlider header states that setValue:animated: does not send an action; XCUIElement declares adjustToNormalizedSliderPosition: as a separate UI manipulation path. Neither a new gesture nor the XCUI path is accepted by this report.

Other slider poses, custom controls, percentage values, slider polling, changes during slider input, universal/release packaging and old compiled-client ABI remain unverified. This fix does not close the wider D10 or D02.OPTIONS rows. Security remains UNVERIFIED per Cam. No push.
