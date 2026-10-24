# Manual checks mapped to repeatable suites

The **693-case/90-run/66-source public set is source-integrated**: iPhone 165, iPad 23 and Duo 505. **Current main build and full acceptance are pending.** The earlier frozen package compiled in 35.99 seconds (37.30 guarded), zero warnings. Main matches 64/66 frozen test sources; two intentional Touch/Pinch test corrections await the normal build. The raw-fix checkpoint is `beb7b11e`, unsigned after signing failed; a recovery checkpoint is not a readiness claim.

| Work | Exact result | What remains |
| --- | --- | --- |
| D39: Use raw and selected input without a false busy error | Seven native cases and 115 host checks passed on CLI `1ae6ede8cc4c…` / native `378144944ee8…`; raw fix checkpoint `beb7b11e`. Public test sources are integrated. | Prove the new public cold setup, build current main and run the full matrix. |
| D38: Closing a command stops its input | Eight input/signal combinations passed across controlled runs. The earlier whole-run failure remains failed. | Run the full named suite on the final candidate. |
| Recording follows the Duo screen | Corrected focused run passed 2/2. Earlier missing-observer failure preserved. | Final full-matrix acceptance. |
| Interior slider values | Current CLI `c829788d` / native `255e7eaf`: held reads completed; accuracy failed after 48 MOVE events in 13.022 seconds, final 57.25047 instead of 56.25, zero contacts after release. | Diagnostic-only CLI work has no math fix yet. Prove a real accuracy fix, then the two slider fold/rotation cases. |
| Photos permission controls | Ordinary iPhone 3/3 passed on CLI `5a6ae9ce`; Duo outer0 3/3 passed on CLI `c829788d`, same Photos source/native `255e7eaf`, zero issues/skips. Source fix and test sources integrated. | Current main build and full-feature/full-suite acceptance. |

[Public package build](../../build_products/verification/duo-complete-20261024/public-suite-integration-proposal-v2/build-receipt.json), [Duo Photos button2](../../build_products/verification/duo-complete-20261024/photos-public-ui-execution-v2/runs/public-photos-duo-PhotosButtonLeafE2ETests/parsed-result.json), [Duo Photos owner1](../../build_products/verification/duo-complete-20261024/photos-public-ui-execution-v2/runs/public-photos-duo-PlaygroundAgentSystemOwnerTests/parsed-result.json), [latest Slider failure](../../build_products/verification/duo-complete-20261024/slider-phase-budget-proposal-v1/recorder-first-j-v1/runs/focused-iphone/parsed-result.json). Earlier Photos refusal/cleanup records and Slider failures remain unchanged. The Photos fingerprint investigation is closed after the unchanged rerun passed; no cache guard or test behavior changed.

| Focused keyboard check | Exact result on CLI `c829788d` / native `255e7eaf` |
| --- | --- |
| Ordinary iPhone raw shortcut | [Failed](../../build_products/verification/duo-complete-20261024/keyboard-focused-c829-v1/runs/keyboard-iphone-keyComboRawLowercase/parsed-result.json). Seed `type AbA` succeeded. The actual `key-combo --modifiers 225 --key 6` then timed out at the guest HID barrier. |
| Ordinary iPhone normal agent key sequence | [Passed 1/1](../../build_products/verification/duo-complete-20261024/keyboard-focused-c829-v1/runs/keyboard-iphone-keySequenceNormal/parsed-result.json), zero issues or skips. |
| Duo raw shortcut | [Setup failed](../../build_products/verification/duo-complete-20261024/keyboard-focused-c829-v1/runs/keyboard-duo-keyComboRawLowercase/parsed-result.json): seed `type AbA` returned stale observation/released. The shortcut command never ran. |
| Duo normal agent key sequence | [Setup failed](../../build_products/verification/duo-complete-20261024/keyboard-focused-c829-v1/runs/keyboard-duo-keySequenceNormal/parsed-result.json): Show Text tap sent zero events and the DTX channel disconnected. The key-sequence command never ran. |

These four outcomes have no proved shared cause. Earlier failures remain saved; no keyboard fix or whole-feature pass is claimed.

The [v2 full run](../../build_products/verification/duo-complete-20261024/final-matrix-v2/result.json) remains **interrupted**: 142/680 completed, 101 passed, 41 issues and 538 without completed results. A Photos permission prompt caused later failures. These are not 41 separate product bugs. Source and payload hashes stayed unchanged. The earlier v1 run and all failed focused records remain preserved.

All original 60 product rows, 18 additional manual rows and 97 earlier technical rows below are unchanged. D38 retains its original row. D39 is the separate raw/selected handover fix; its seven native passes do not accept the full matrix. Rows overlap; do not add their counts. The [JSON map](2026-10-24-manual-suite-map.json) keeps old evidence and current scoped results separate. [Vendor findings](2026-10-24-vendor-failure-review.md) remain separate evidence.

## Duo support

| ID | Feature | Exact suite IDs | Final result |
| --- | --- | --- | --- |
| D01 | Remove the added Duo AX setup requirement | `PlaygroundDuoCoreTests`, `PlaygroundDuoTests` | Final run pending |
| D02 | Fix default scroll presets after rotation | `PlaygroundDuoScrollCoverageTests` | Final run pending |
| D03 | Set closed, tabletop or open by name | `PlaygroundDuoTests` | Final run pending |
| D04 | Set a numeric hinge angle | `PlaygroundDuoHingeWindowTests` | Final run pending |
| D05 | Fix taps after rotation | `PlaygroundDuoTests`, `PlaygroundDuoCoordinateCoverageTests`, `PlaygroundDuoCoreTests` | Final run pending |
| D06 | Fix swipes after rotation | `PlaygroundDuoGestureCoverageTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoAdditionalInterruptionTests` | Final run pending |
| D07 | Fix drags after rotation | `PlaygroundDuoGestureCoverageTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoAdditionalInterruptionTests` | Final run pending |
| D08 | Stop old touches when the phone folds or turns | `PlaygroundDuoInterruptionTests`, `PlaygroundDuoAdditionalInterruptionTests`, `PlaygroundDuoRetainedInputTests`, `PlaygroundDuoRetainedPairTests` | Final run pending |
| D09 | Choose the active inner or outer display for supported input | `PlaygroundDuoTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoHardwareTests` | Final run pending |
| D10 | Send guarded Siri input | `PlaygroundDuoHardwareTests` | Final run pending |
| D11 | Send guarded Lock input | `PlaygroundDuoHardwareTests` | Final run pending |
| D12 | Send guarded Apple Pay input | `PlaygroundDuoHardwareTests` | Final run pending |
| D13 | Enter text and keyboard shortcuts in a selected TextField | `PlaygroundDuoKeyboardSourcesTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoCoreTests`, `PlaygroundDuoKeyboardDelayTests` | Final run pending |
| D14 | Release held no-flag keys and shortcuts when Duo folds or turns | `PlaygroundDuoKeyboardInterruptionTests`, `PlaygroundDuoHeldModifierTests` | Final run pending |
| D15 | Keep ordinary standalone typing reliable on Duo | `PlaygroundDuoKeyboardSourcesTests`, `PlaygroundDuoTypingInterruptionTests`, `PlaygroundDuoKeyboardInterruptionTests`, `PlaygroundDuoKeyboardDelayTests` | Final run pending |
| D16 | Show the lock screen | `PlaygroundDuoHardwareTests` | Final run pending |
| D17 | Wake the phone | `PlaygroundDuoHardwareTests` | Final run pending |
| D18 | Open Siri | `PlaygroundDuoHardwareTests` | Final run pending |
| D19 | Shut down one simulator | `PlaygroundSimulatorLifecycleTests` | Final run pending |
| D20 | Keep a finger pressed between commands | `PlaygroundDuoRetainedInputTests`, `PlaygroundDuoManualBoundaryTests` | Final run pending |
| D21 | Release a finger left idle | `PlaygroundDuoRetainedInputTests` | Final run pending |
| D22 | Release a finger when its command process stops | `PlaygroundDuoRetainedInputTests` | Final run pending |
| D23 | Run a sequence of commands on Duo | `PlaygroundDuoBatchCoverageTests`, `PlaygroundDuoLegacyBatchInterruptionTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoSelectedHomeBatchTests` | Final run pending |
| D24 | Show a clear error for invalid Duo batch steps | `PlaygroundDuoBatchCoverageTests`, `PlaygroundAgentBatchTests` | Final run pending |
| D25 | Prevent repeated characters when typing in a batch | `PlaygroundDuoBatchCoverageTests`, `PlaygroundDuoSelectedBatchKeyboardTests` | Final run pending |
| D26 | Record a chosen display at a fixed position | `PlaygroundDuoMediaTests` | Final run pending |
| D27 | Capture again after rotation | `PlaygroundDuoMediaTests` | Final run pending |
| D28 | Capture again after folding | `PlaygroundDuoMediaTests` | Final run pending |
| D29 | Keep recording while the phone folds or turns | `PlaygroundDuoMediaTests`, `PlaygroundDuoMediaSafetyTests` | Final run pending |
| D30 | Use controls in a smaller app window | `PlaygroundDuoHingeWindowTests`, `PlaygroundWindowTests` | Final run pending |
| D31 | Keep core iPhone and iPad input working | `PlaygroundCoreTests`, `PlaygroundKeyboardTests`, `PlaygroundOrdinaryRegressionTests`, `PlaygroundWindowTests` | Final run pending |
| D32 | Set a Duo slider to the requested percentage reliably | `PlaygroundDuoCoreTests`, `PlaygroundDuoSelectedSliderTests`, `PlaygroundAgentSliderTests`, `PlaygroundDuoInteriorSliderTests` | Final run pending |
| D33 | Use app controls after folding during a long press | `PlaygroundDuoSameAppFoldTests` | Final run pending |
| D34 | Stress-check app controls after a cold Duo start | — | Deferred |
| D35 | Run repeated automated iPhone and Duo Playground checks | `PlaygroundCoreTests`, `PlaygroundOrdinaryRegressionTests`, `PlaygroundAgentTests`, `PlaygroundAgentSelectorTests`, `PlaygroundAgentObservationTests`, `PlaygroundAgentKeyTests`, `PlaygroundAgentKeyComboTests`, `PlaygroundAgentKeySequenceTests`, `PlaygroundAgentTouchTests`, `PlaygroundAgentDoubleTapTests`, `PlaygroundAgentDragTests`, `PlaygroundAgentPinchTests`, `PlaygroundAgentSliderTests`, `PlaygroundAgentNativeStateTests`, `PlaygroundAgentSystemOwnerTests`, `PlaygroundAgentBatchTests`, `PlaygroundClipboardTests`, `PlaygroundIndependentPairTests`, `PlaygroundSemanticSwitchTests`, `PlaygroundAgentTypeTests`, `PlaygroundKeyboardTests`, `PlaygroundWindowTests`, `PlaygroundDuoCoreTests`, `PlaygroundDuoGestureCoverageTests`, `PlaygroundDuoCoordinateCoverageTests`, `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoSelectedSwitchTests`, `PlaygroundDuoTapStyleTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoSelectedSliderTests`, `PlaygroundDuoPairCoverageTests`, `PlaygroundDuoRetainedInputTests`, `PlaygroundDuoRetainedPairTests`, `PlaygroundDuoAdditionalInterruptionTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoNavigationTests`, `PlaygroundDuoTapWaitTests`, `PlaygroundDuoBatchCoverageTests`, `PlaygroundDuoLegacyBatchInterruptionTests`, `PlaygroundDuoSameAppFoldTests`, `PlaygroundDuoHorizontalPresetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoSemanticSwitchTests`, `PlaygroundDuoInteriorSliderTests`, `PlaygroundDuoAgentInterruptionTests`, `PlaygroundDuoKeyboardInterruptionTests`, `PlaygroundDuoKeyboardSourcesTests`, `PlaygroundDuoSelectedKeyInterruptionTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoHeldModifierTests`, `PlaygroundDuoTypingInterruptionTests`, `PlaygroundDuoHardwareTests`, `PlaygroundDuoHardwareInterruptionTests`, `PlaygroundDuoSelectedHomeBatchTests`, `PlaygroundDuoKeyboardDelayTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoMediaSafetyTests`, `PlaygroundDuoTests`, `PlaygroundDuoInterruptionTests`, `PlaygroundDuoHingeWindowTests`, `PlaygroundSimulatorLifecycleTests` | Final run pending |
| D36 | Extract and start the Apple-silicon package locally | — | Local delivery pending |
| D37 | Verify the release package locally | — | Local delivery pending |
| D38 | Closing a command stops its input | `PlaygroundSelectedClientExitTests` | Done in scope: eight distinct input/signal combinations passed across controlled runs; fix integrated. Full named suite and matrix pending |

## SimUse and optional agent improvements

| ID | Feature | Exact suite IDs | Final result |
| --- | --- | --- | --- |
| A01 | Find a control from part of its label | `PlaygroundAgentSelectorTests` | Final run pending |
| A02 | Find a control with a text pattern | `PlaygroundAgentSelectorTests` | Final run pending |
| A03 | Find a control within a chosen screen area | `PlaygroundAgentSelectorTests` | Final run pending |
| A04 | Report whether the keyboard is visible | `PlaygroundAgentObservationTests` | Final run pending |
| A05 | Provide the optional RS1 agent interface | `PlaygroundAgentSelectorTests`, `PlaygroundAgentObservationTests`, `PlaygroundAgentKeyTests`, `PlaygroundAgentKeyComboTests`, `PlaygroundAgentKeySequenceTests`, `PlaygroundAgentTouchTests`, `PlaygroundAgentDoubleTapTests`, `PlaygroundAgentDragTests`, `PlaygroundAgentPinchTests`, `PlaygroundAgentSliderTests`, `PlaygroundAgentNativeStateTests`, `PlaygroundAgentSystemOwnerTests`, `PlaygroundAgentBatchTests`, `PlaygroundClipboardTests`, `PlaygroundIndependentPairTests`, `PlaygroundSemanticSwitchTests`, `PlaygroundAgentTypeTests`, `PlaygroundDuoSemanticSwitchTests`, `PlaygroundDuoInteriorSliderTests`, `PlaygroundDuoAgentInterruptionTests` | Final run pending |
| A06 | Reuse screen snapshots safely | `PlaygroundAgentTests`, `PlaygroundAgentObservationTests` | Final run pending |
| A07 | Tell agents which app owns a system alert | `PlaygroundAgentSystemOwnerTests` | Final run pending |
| A08 | Install the required helper with Homebrew | — | Local delivery pending |
| A09 | Activate a switch through its accessibility action | `PlaygroundSemanticSwitchTests`, `PlaygroundDuoSemanticSwitchTests` | Final run pending |
| A10 | Check switch state before reporting success | `PlaygroundSemanticSwitchTests`, `PlaygroundDuoSemanticSwitchTests` | Final run pending |
| A11 | Drag from an agent element reference | `PlaygroundAgentDragTests`, `PlaygroundDuoAgentInterruptionTests` | Final run pending |
| A12 | Press and hold an element by its agent reference | `PlaygroundAgentTouchTests`, `PlaygroundDuoAgentInterruptionTests` | Final run pending |
| A13 | Press a key in an agent-selected text field | `PlaygroundAgentKeyTests` | Final run pending |
| A14 | Press a keyboard shortcut in an agent-selected field | `PlaygroundAgentKeyComboTests` | Final run pending |
| A15 | Press several keys in an agent-selected field | `PlaygroundAgentKeySequenceTests` | Final run pending |
| A16 | Double tap a control by its agent reference | `PlaygroundAgentDoubleTapTests` | Final run pending |
| A17 | Move a slider to an end by its agent reference | `PlaygroundAgentSliderTests` | Final run pending |
| A18 | Pinch an area by its agent reference | `PlaygroundAgentPinchTests`, `PlaygroundDuoAgentInterruptionTests` | Final run pending |
| A19 | Run several agent actions in one request | `PlaygroundAgentBatchTests`, `PlaygroundDuoAgentInterruptionTests` | Final run pending |
| A20 | Enter Unicode through clipboard and a current Paste button | `PlaygroundClipboardTests` | Final run pending |
| A21 | Set a slider to a chosen percentage | `PlaygroundAgentSliderTests`, `PlaygroundDuoInteriorSliderTests` | Final run pending |
| A22 | Move two fingers along separate paths | `PlaygroundIndependentPairTests`, `PlaygroundDuoAgentInterruptionTests`, `PlaygroundDuoPairCoverageTests` | Final run pending |
| A23 | Improve recovery when an app reports no accessible controls | — | Deferred |

## Additional prior manual checks

| ID | Feature | Exact suite IDs | Final result |
| --- | --- | --- | --- |
| T01 | Discovery metadata and explicit panel admission | `PlaygroundDuoHingeWindowTests`, `PlaygroundDuoMediaTests` | Final run pending |
| T02 | Selected lookup by point, label, exact value and type | `PlaygroundDuoSelectedTargetTests` | Final run pending |
| T03 | Selected physical, simulator and automatic tap styles | `PlaygroundDuoTapStyleTests` | Final run pending |
| T04 | Find moved controls in real partial-fold layouts | `PlaygroundDuoHingeWindowTests` | Four focused rotation cases passed on v4; new full run pending |
| T05 | Nested scrolling, page scrolling and actual four-way content | `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoHorizontalPresetTests` | Final run pending |
| T06 | Retained native pairs and stale owner rejection | `PlaygroundDuoRetainedPairTests`, `PlaygroundDuoManualBoundaryTests` | Final run pending |
| T07 | Complete two-finger gestures and moving twists | `PlaygroundDuoPairCoverageTests`, `PlaygroundDuoAdditionalInterruptionTests` | Final run pending |
| T08 | Selected slider endpoints and exact native identity | `PlaygroundDuoSelectedSliderTests` | Final run pending |
| T09 | Tap waiting and safe cancellation | `PlaygroundDuoTapWaitTests` | Final run pending |
| T10 | Edge navigation and short gesture geometry | `PlaygroundDuoNavigationTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoManualBoundaryTests` | Final run pending |
| T11 | Selected batches and host waits | `PlaygroundDuoBatchCoverageTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoSelectedHomeBatchTests` | Final run pending |
| T12 | Selected PNG output, cancellation and retained input exclusion | `PlaygroundDuoMediaTests`, `PlaygroundDuoMediaSafetyTests` | Final run pending |
| T13 | Selected streaming and exact format bytes | `PlaygroundDuoMediaTests` | Final run pending |
| T14 | Held hardware buttons across layout changes | `PlaygroundDuoHardwareInterruptionTests` | Final run pending |
| T15 | Selected held key across opening or rotation | `PlaygroundDuoSelectedKeyInterruptionTests` | Final run pending |
| T16 | Ordinary iPad and iPhone selected compatibility | `PlaygroundOrdinaryRegressionTests` | Final run pending |
| T17 | Local build and release boundaries | — | Local delivery pending |
| T18 | Physical and coordinate switch identity | `PlaygroundDuoSelectedSwitchTests` | Final run pending |

## Earlier technical rows

Parent rows include the suites for their child requirements. Outer upside-down portrait is not applicable. The isolated final hinge-read timeout is retained as earlier failed evidence; it has no speculative fix. Local delivery rows use a separate recipe.

| ID | Earlier requirement | Exact suite IDs or disposition |
| --- | --- | --- |
| D01 | Device discovery and status report active screen, orientation and hinge. | `PlaygroundDuoCoreTests`, `PlaygroundDuoTests`, `PlaygroundDuoHingeWindowTests`, `PlaygroundDuoMediaTests` |
| D01.DISCOVERY | Discover the active panel without knowing its ID in advance. | `PlaygroundDuoHingeWindowTests`, `PlaygroundDuoMediaTests` |
| D01.DISCOVERY.METADATA | Report the matched boot identity and complete host read interval without changing existing discovery fields. | `PlaygroundDuoHingeWindowTests`, `PlaygroundDuoMediaTests` |
| D02 | Consistent screen selection across applicable CLI commands and library APIs. | `PlaygroundDuoCoreTests`, `PlaygroundDuoTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoHardwareTests`, `PlaygroundDuoTapStyleTests`, `PlaygroundDuoSelectedSliderTests`, `PlaygroundDuoTapWaitTests` |
| D02.OPTIONS | Preserve applicable existing tap and slider options in selected mode. | `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoTapStyleTests`, `PlaygroundDuoSelectedSliderTests`, `PlaygroundDuoTapWaitTests` |
| D02.WAIT | Bounded ordinary selected ID/label/value tap waiting and per-step batch waiting, wire22. | `PlaygroundDuoTapWaitTests` |
| D02.TYPE | Exact case-sensitive type filter on ordinary selected ID/label tap, wire14. | `PlaygroundDuoSelectedTargetTests` |
| D02.VALUE | Exact value selector on ordinary selected tap, wire15. | `PlaygroundDuoSelectedTargetTests` |
| D02.PHYSICAL | Explicit --tap-style physical on ordinary selected coordinate or ID/label/value taps, including per-step batch taps. | `PlaygroundDuoTapStyleTests` |
| D02.SIMULATOR | Explicit --tap-style simulator uses actual tapAt down/up with no inserted hold for ordinary selected coordinates or ID/label/value taps and per-step batches. | `PlaygroundDuoTapStyleTests` |
| D02.AUTOMATIC | Explicit selected automatic tap style through the existing guarded owner, wire 17. | `PlaygroundDuoTapStyleTests` |
| D03 | Screen, AX display and HID target mapping survives transitions. | `PlaygroundDuoCoreTests`, `PlaygroundDuoTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoHardwareTests`, `PlaygroundDuoHingeWindowTests`, `PlaygroundDuoInterruptionTests`, `PlaygroundDuoAdditionalInterruptionTests`, `PlaygroundDuoRetainedInputTests`, `PlaygroundDuoRetainedPairTests`, `PlaygroundDuoSameAppFoldTests`, `PlaygroundDuoPairCoverageTests` |
| D03.OPEN.REFIND | Open the device, reject the old panel and find and tap the field on the active inner panel. | `PlaygroundDuoTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoHardwareTests` |
| D03.FOLDLAYOUT | Find and use real controls after a hinge callback moves them. | `PlaygroundDuoHingeWindowTests` |
| D03.FOLDTABLETOP | Find and use real controls above and below an active hinge division after rotation. | `PlaygroundDuoHingeWindowTests` |
| D03.HELDINPUT | Stop old-layout input, release contacts, then discover and tap the current element after an external fold or rotation. | `PlaygroundDuoInterruptionTests`, `PlaygroundDuoAdditionalInterruptionTests`, `PlaygroundDuoRetainedInputTests`, `PlaygroundDuoRetainedPairTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoSameAppFoldTests` |
| D03.MOVINGPINCH | Interrupt a moving pinch after both contacts move; release both, then find and tap the current element. | `PlaygroundDuoInterruptionTests`, `PlaygroundDuoAdditionalInterruptionTests`, `PlaygroundDuoRetainedInputTests`, `PlaygroundDuoRetainedPairTests` |
| D03.MOVINGROTATION | Stop a moving two-finger twist on external folding or device rotation, release both contacts, then find and tap the current element. | `PlaygroundDuoInterruptionTests`, `PlaygroundDuoAdditionalInterruptionTests`, `PlaygroundDuoRetainedInputTests`, `PlaygroundDuoRetainedPairTests`, `PlaygroundDuoPairCoverageTests` |
| D04 | Rotation and continuous hinge controls with reliable readback. | `PlaygroundDuoTests`, `PlaygroundDuoHingeWindowTests`, `PlaygroundDuoCoordinateCoverageTests`, `PlaygroundDuoCoreTests` |
| D04.ENDPOINTS | Set closed0 and full-open180 with measured panel readiness, then control the active app. | `PlaygroundDuoTests` |
| D04.BOUNDARY | Measure the active panel near a hinge switch, reject old selection and use the current screen. | `PlaygroundDuoHingeWindowTests` |
| D04.ROTATION | Rotate the Duo through the library/CLI with selected-screen readback and fresh named input. | `PlaygroundDuoTests`, `PlaygroundDuoCoordinateCoverageTests`, `PlaygroundDuoCoreTests` |
| D04.ROTATION.METHOD | Prove a headless Duo orientation event, persistent selected UI readback and correct named-element input. | `PlaygroundDuoTests`, `PlaygroundDuoCoordinateCoverageTests`, `PlaygroundDuoCoreTests` |
| D04.OUTER.UPSIDE | Outer upside-down portrait UI input. | NOT_APPLICABLE_APPLE_OUTER_DISPLAY_POLICY |
| D05 | AX descriptions, exact-ID searches, label searches and point queries select the correct screen. | `PlaygroundDuoTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoHardwareTests` |
| D05.POINT | Read one direct-PID element at selected oriented logical coordinates. | `PlaygroundDuoTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoHardwareTests` |
| D05.LABEL | A unique label selects and focuses the correct TextField. | `PlaygroundDuoTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoHardwareTests` |
| D06 | Point, element-frame and image-pixel conversion in each supported orientation. | `PlaygroundDuoHingeWindowTests`, `PlaygroundWindowTests` |
| D07 | Coordinate taps, exact-ID element taps, double taps and long presses in the seven supported Duo poses. | `PlaygroundDuoTests`, `PlaygroundDuoCoordinateCoverageTests`, `PlaygroundDuoCoreTests` |
| D07.IDTAP | Find the same exact-ID button again after rotation/folding and tap the selected screen. | `PlaygroundDuoTests`, `PlaygroundDuoCoordinateCoverageTests`, `PlaygroundDuoCoreTests` |
| D08 | Swipes, drags, page/nested scrolling and existing presets. | `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoGestureCoverageTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoAdditionalInterruptionTests`, `PlaygroundDuoHorizontalPresetTests`, `PlaygroundDuoNavigationTests`, `PlaygroundDuoManualBoundaryTests` |
| D08.LEGACY.PATHS | Ordinary no-flag Duo swipe and drag use the measured active screen and stop old-coordinate input after a context change. | `PlaygroundDuoGestureCoverageTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoAdditionalInterruptionTests` |
| D08.NESTED | Scroll the nested list in both directions without moving the page in all seven supported Duo poses. | `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoHorizontalPresetTests` |
| D08.NESTED.OUTER270 | Scroll a real visible nested list both ways at closed outer270. | `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoHorizontalPresetTests` |
| D08.NESTED.OUTER90 | Scroll a real visible nested list both ways at closed outer90. | `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoHorizontalPresetTests` |
| D08.PAGE | Scroll the page while the nested list and controls stay unchanged. | `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoHorizontalPresetTests` |
| D08.PRESETS.HORIZONTAL | Preserve default horizontal preset geometry and completed app pan. | `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoHorizontalPresetTests` |
| D08.PRESETS.CANVAS | Default presets move real UIScrollView content in all four directions at closed outer portrait and fully open inner90. | `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoHorizontalPresetTests` |
| D08.PRESETS.EDGEINSET | Explicit start inset for all four edge presets, including batch paths. | `PlaygroundDuoNavigationTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoManualBoundaryTests` |
| D08.SWIPE.SHORT | Finite positive legacy factory paths shorter than the effective delta produce finite balanced events. | `PlaygroundDuoNavigationTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoManualBoundaryTests` |
| D08.FINALREAD | Retain the one historical final hinge-read timeout without treating it as a proved AXe defect. | RETAINED_UNREPRODUCED_HISTORICAL_TIMEOUT |
| D08.SWIPE.INNER90 | One complete 80-point selected swipe at inner rotation90 and hinge90 reports completion and releases input. | `PlaygroundDuoMotionOptionsTests` |
| D09 | Pinch, rotation and existing multi-touch gestures. | `PlaygroundIndependentPairTests`, `PlaygroundDuoAgentInterruptionTests`, `PlaygroundDuoPairCoverageTests`, `PlaygroundDuoAdditionalInterruptionTests`, `PlaygroundDuoRetainedPairTests`, `PlaygroundDuoManualBoundaryTests` |
| D09.RETAINED | Retain and move two contacts; release both during idle after folding or rotation, reject old input, then find and tap the current Button. | `PlaygroundDuoRetainedPairTests`, `PlaygroundDuoManualBoundaryTests` |
| D09.OUTER270 | Complete pinch, twist, two-finger tap and hold at closed outer270. | `PlaygroundDuoPairCoverageTests`, `PlaygroundDuoAdditionalInterruptionTests` |
| D10 | Buttons, switches, sliders and text fields. | `PlaygroundDuoKeyboardSourcesTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoCoreTests`, `PlaygroundDuoKeyboardDelayTests`, `PlaygroundDuoSelectedSliderTests`, `PlaygroundAgentSliderTests`, `PlaygroundDuoInteriorSliderTests`, `PlaygroundDuoSelectedSwitchTests`, `PlaygroundSemanticSwitchTests`, `PlaygroundDuoSemanticSwitchTests` |
| D10.FOCUS | Observe actual selected TextField focus changes. | `PlaygroundDuoKeyboardSourcesTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoCoreTests`, `PlaygroundDuoKeyboardDelayTests` |
| D10.SLIDER | Explicit selected slider endpoints without HID input. | `PlaygroundAgentSliderTests`, `PlaygroundDuoSelectedSliderTests` |
| D10.SLIDER.TYPE | Optional exact case-sensitive type filter on selected standalone and batch slider endpoints, wire18. | `PlaygroundDuoSelectedSliderTests` |
| D10.SLIDER.LABEL | Exact-label selected slider endpoints through the shared standalone/batch route. | `PlaygroundDuoSelectedSliderTests` |
| D10.SLIDER.ID | Bind the exact unique native slider handle when earlier IDs share its prefix. | `PlaygroundDuoSelectedSliderTests` |
| D10.SLIDER.PERCENT | Set a selected slider to a requested percentage and notify the app. | `PlaygroundDuoCoreTests`, `PlaygroundDuoSelectedSliderTests`, `PlaygroundAgentSliderTests`, `PlaygroundDuoInteriorSliderTests` |
| D10.SWITCH | Selected exact-ID physical input controls the named UIKit switch on the stated poses. | `PlaygroundDuoSelectedSwitchTests` |
| D10.SWITCH.SEMANTIC | Semantic activation changes the switch with no hidden fallback. | `PlaygroundSemanticSwitchTests`, `PlaygroundDuoSemanticSwitchTests` |
| D10.SWITCH.COORDINATE | Explicit coordinate input controls the selected switch. | `PlaygroundDuoSelectedSwitchTests` |
| D11 | Literal/file/stdin text, keys, combinations and sequences. | `PlaygroundDuoKeyboardSourcesTests`, `PlaygroundDuoTypingInterruptionTests`, `PlaygroundDuoKeyboardInterruptionTests`, `PlaygroundDuoKeyboardDelayTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoCoreTests`, `PlaygroundDuoHeldModifierTests`, `PlaygroundDuoSelectedKeyInterruptionTests` |
| D11.TEXTFIELD | Bounded selected literal/file/stdin text, single keys, modifier combination and later focus-loss rejection. | `PlaygroundDuoKeyboardSourcesTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoKeyboardDelayTests`, `PlaygroundDuoCoreTests` |
| D11.HELDKEY | Stop one public held-Space action after opening or device rotation, confirm owned cleanup, then find and tap the current Button. | `PlaygroundDuoKeyboardInterruptionTests`, `PlaygroundDuoHeldModifierTests`, `PlaygroundDuoSelectedKeyInterruptionTests` |
| D11.STDIN.OPEN | Existing selected standalone stdin on fully open inner 3/AX 3/HID 3/rotation 90. | `PlaygroundDuoKeyboardSourcesTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoCoreTests`, `PlaygroundDuoKeyboardDelayTests` |
| D12 | Existing hardware-button, navigation, lock, power and device controls where supported. | `PlaygroundSimulatorLifecycleTests`, `PlaygroundDuoHardwareInterruptionTests`, `PlaygroundDuoHardwareTests`, `PlaygroundDuoNavigationTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoManualBoundaryTests` |
| D12.HOME | Existing hardware Home action moves the app to Home. | `PlaygroundDuoHardwareInterruptionTests` |
| D12.HOME.SELECTED | Explicit selected Home uses the common owner/session with a hardware completion receipt. | `PlaygroundDuoHardwareInterruptionTests` |
| D12.SIDE.VISUAL | One explicit side-button action changes the visible app to date/clock wallpaper. | `PlaygroundDuoHardwareTests` |
| D12.SIDE.SELECTED | Selected standalone and batch side-button share the guarded hardware route and typed completion evidence. | `PlaygroundDuoHardwareTests`, `PlaygroundDuoHardwareInterruptionTests` |
| D12.SIRI.SELECTED | Selected Siri uses guarded device context and typed delivery/release evidence. | `PlaygroundDuoHardwareTests` |
| D12.LOCK.SELECTED | Selected Lock uses guarded device context and typed delivery/release evidence. | `PlaygroundDuoHardwareTests` |
| D12.APPLEPAY.SELECTED | Selected standalone and batch Apple Pay use the guarded route and exact four-event completion evidence. | `PlaygroundDuoHardwareTests` |
| D12.HELD | Stop held Home and side-button input after a real fold or inner-screen turn, release the owned button, then use the current app. | `PlaygroundDuoHardwareInterruptionTests` |
| D12.NAV.BACK | Default left-edge preset returns one normal pushed page at closed outer portrait. | `PlaygroundDuoNavigationTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoManualBoundaryTests` |
| D12.NAV.BACK.EXPLICIT | One explicit x1/.3-second swipe returns the normal Detail page at full-open inner90. | `PlaygroundDuoNavigationTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoManualBoundaryTests` |
| D13 | Selected-screen screenshots, recording and streaming with correct orientation. | `PlaygroundDuoMediaTests`, `PlaygroundDuoMediaSafetyTests` |
| D13.PNG | Explicit selected PNG capture with validated context and no fallback. | `PlaygroundDuoMediaTests`, `PlaygroundDuoMediaSafetyTests` |
| D13.RECORD | Explicit selected H.264 clips at one fixed pose on each physical screen. | `PlaygroundDuoMediaTests` |
| D13.STREAM | Explicit selected raw/MJPEG/ffmpeg/BGRA streams at one fixed measured pose on each physical screen. | `PlaygroundDuoMediaTests` |
| D13.JPEG | Existing JPEG conversion produces valid image data. | `PlaygroundDuoMediaTests` |
| D14 | Batch and agent routes expose the same supported behavior. | `PlaygroundAgentSelectorTests`, `PlaygroundAgentObservationTests`, `PlaygroundAgentKeyTests`, `PlaygroundAgentKeyComboTests`, `PlaygroundAgentKeySequenceTests`, `PlaygroundAgentTouchTests`, `PlaygroundAgentDoubleTapTests`, `PlaygroundAgentDragTests`, `PlaygroundAgentPinchTests`, `PlaygroundAgentSliderTests`, `PlaygroundAgentNativeStateTests`, `PlaygroundAgentSystemOwnerTests`, `PlaygroundAgentBatchTests`, `PlaygroundClipboardTests`, `PlaygroundIndependentPairTests`, `PlaygroundSemanticSwitchTests`, `PlaygroundAgentTypeTests`, `PlaygroundDuoSemanticSwitchTests`, `PlaygroundDuoInteriorSliderTests`, `PlaygroundDuoAgentInterruptionTests`, `PlaygroundDuoBatchCoverageTests`, `PlaygroundDuoLegacyBatchInterruptionTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoSelectedHomeBatchTests` |
| D14.BATCH | Complete selected batch steps use the guarded selected owner. | `PlaygroundDuoBatchCoverageTests`, `PlaygroundDuoLegacyBatchInterruptionTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoSelectedHomeBatchTests` |
| D14.BATCH.SLEEP | Selected batch sleep is a host wait without input ownership. | `PlaygroundDuoBatchCoverageTests` |
| D14.BATCH.SLEEP.MIXED | One selected input / host wait / input batch has two independent effects. | `PlaygroundDuoBatchCoverageTests` |
| D14.BATCH.HOME | Selected batch Home uses the existing request and typed completion evidence. | `PlaygroundDuoSelectedHomeBatchTests` |
| D14.BATCH.SLIDER | Selected batch slider endpoints use semantic completion and stop after failure. | `PlaygroundDuoBatchCoverageTests` |
| D14.BATCH.DRAG | Selected batch drag delivers one complete path and stops after a later invalid step. | `PlaygroundDuoBatchCoverageTests` |
| D14.BATCH.TAPS | Selected batch performs ordered taps and stops after a parser rejection. | `PlaygroundDuoBatchCoverageTests` |
| D14.BATCH.KEYBOARD | Selected batch types and uses keys, then stops on later focus loss. | `PlaygroundDuoBatchCoverageTests`, `PlaygroundDuoSelectedBatchKeyboardTests` |
| D14.BATCH.STDIN | Selected batch stdin uses the existing bounded text loader and per-key owner. | `PlaygroundDuoSelectedBatchKeyboardTests` |
| D15 | Cancellation, interruption and stale targets release held input safely. | `PlaygroundDuoRetainedInputTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoMediaSafetyTests`, `PlaygroundDuoTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoHardwareTests` |
| D15.PNG.SIGNALS | Selected PNG handles SIGINT/SIGTERM by cancelling and awaiting its operation. | `PlaygroundDuoMediaTests`, `PlaygroundDuoMediaSafetyTests` |
| D15.PNG.LEASE | A retained touch prevents selected PNG capture through the common input lease. | `PlaygroundDuoMediaTests`, `PlaygroundDuoMediaSafetyTests` |
| D16 | Existing ordinary iPhone/iPad behavior remains working. | `PlaygroundCoreTests`, `PlaygroundKeyboardTests`, `PlaygroundOrdinaryRegressionTests`, `PlaygroundWindowTests` |
| D16.LEGACY | Bounded ordinary-device portrait legacy description, screenshot, exact-ID tap, field focus and literal text. | `PlaygroundCoreTests`, `PlaygroundKeyboardTests`, `PlaygroundOrdinaryRegressionTests`, `PlaygroundWindowTests` |
| D16.LEGACY.CURRENT | Bounded current-candidate ordinary portrait legacy regression. | `PlaygroundCoreTests`, `PlaygroundKeyboardTests`, `PlaygroundOrdinaryRegressionTests`, `PlaygroundWindowTests` |
| D16.SELECTED | Bounded selected discovery, PNG, AX and exact-ID physical Button input on two ordinary portrait devices. | `PlaygroundCoreTests`, `PlaygroundKeyboardTests`, `PlaygroundOrdinaryRegressionTests`, `PlaygroundWindowTests` |
| D16.CORE.CURRENT | Current isolated Duo source preserves representative portrait iPhone/iPad input through both legacy and selected routes. | `PlaygroundCoreTests`, `PlaygroundKeyboardTests`, `PlaygroundOrdinaryRegressionTests`, `PlaygroundWindowTests` |
| D15.INACTIVE | Reject selected input aimed at an inactive screen. | `PlaygroundDuoTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoHardwareTests` |
| D17 | Library/CLI integration, help, docs and packaging. | `PlaygroundCoreTests`, `PlaygroundOrdinaryRegressionTests`, `PlaygroundAgentTests`, `PlaygroundAgentSelectorTests`, `PlaygroundAgentObservationTests`, `PlaygroundAgentKeyTests`, `PlaygroundAgentKeyComboTests`, `PlaygroundAgentKeySequenceTests`, `PlaygroundAgentTouchTests`, `PlaygroundAgentDoubleTapTests`, `PlaygroundAgentDragTests`, `PlaygroundAgentPinchTests`, `PlaygroundAgentSliderTests`, `PlaygroundAgentNativeStateTests`, `PlaygroundAgentSystemOwnerTests`, `PlaygroundAgentBatchTests`, `PlaygroundClipboardTests`, `PlaygroundIndependentPairTests`, `PlaygroundSemanticSwitchTests`, `PlaygroundAgentTypeTests`, `PlaygroundKeyboardTests`, `PlaygroundWindowTests`, `PlaygroundDuoCoreTests`, `PlaygroundDuoGestureCoverageTests`, `PlaygroundDuoCoordinateCoverageTests`, `PlaygroundDuoScrollCoverageTests`, `PlaygroundDuoSelectedSwitchTests`, `PlaygroundDuoTapStyleTests`, `PlaygroundDuoSelectedTargetTests`, `PlaygroundDuoSelectedSliderTests`, `PlaygroundDuoPairCoverageTests`, `PlaygroundDuoRetainedInputTests`, `PlaygroundDuoRetainedPairTests`, `PlaygroundDuoAdditionalInterruptionTests`, `PlaygroundDuoMotionOptionsTests`, `PlaygroundDuoNavigationTests`, `PlaygroundDuoTapWaitTests`, `PlaygroundDuoBatchCoverageTests`, `PlaygroundDuoLegacyBatchInterruptionTests`, `PlaygroundDuoSameAppFoldTests`, `PlaygroundDuoHorizontalPresetTests`, `PlaygroundDuoManualBoundaryTests`, `PlaygroundDuoSemanticSwitchTests`, `PlaygroundDuoInteriorSliderTests`, `PlaygroundDuoAgentInterruptionTests`, `PlaygroundDuoKeyboardInterruptionTests`, `PlaygroundDuoKeyboardSourcesTests`, `PlaygroundDuoSelectedKeyInterruptionTests`, `PlaygroundDuoSelectedBatchKeyboardTests`, `PlaygroundDuoHeldModifierTests`, `PlaygroundDuoTypingInterruptionTests`, `PlaygroundDuoHardwareTests`, `PlaygroundDuoHardwareInterruptionTests`, `PlaygroundDuoSelectedHomeBatchTests`, `PlaygroundDuoKeyboardDelayTests`, `PlaygroundDuoMediaTests`, `PlaygroundDuoMediaSafetyTests`, `PlaygroundDuoTests`, `PlaygroundDuoInterruptionTests`, `PlaygroundDuoHingeWindowTests`, `PlaygroundSimulatorLifecycleTests` |
| D17.ARTIFACT.MATCHER | Accept AXe-owned identifiers while rejecting private imports/types and incomplete artifacts. | LOCAL_DELIVERY_PENDING_FINAL_CANDIDATE |
| D17.ARM64 | Build current CLI against the reproducible selected library and helper. | LOCAL_DELIVERY_PENDING_FINAL_CANDIDATE |

## Suite sources and planned counts

These are case instances per applicable guest, not feature counts. The iPad runs the earlier baseline and ordinary-device checks only. The existing comparison cases retain their prior iPhone and Duo scope. The added cases retain the device limits below.

| Suite | Cases per guest | Tracked source |
| --- | --- | --- |
| `PlaygroundCoreTests` | 9 | [PlaygroundCoreTests.swift](../../Tests/PlaygroundCoreTests.swift) |
| `PlaygroundKeyboardTests` | 1 | [PlaygroundKeyboardTests.swift](../../Tests/PlaygroundKeyboardTests.swift) |
| `PlaygroundAgentTests` | 4 | [PlaygroundAgentTests.swift](../../Tests/PlaygroundAgentTests.swift) |
| `PlaygroundDuoCoreTests` | 20 | [PlaygroundDuoCoreTests.swift](../../Tests/PlaygroundDuoCoreTests.swift) |
| `PlaygroundDuoTests` | 6 | [PlaygroundDuoTests.swift](../../Tests/PlaygroundDuoTests.swift) |
| `PlaygroundDuoInterruptionTests` | 6 | [PlaygroundInterruptionTests.swift](../../Tests/PlaygroundInterruptionTests.swift) |
| `PlaygroundDuoGestureCoverageTests` | 28 | [PlaygroundDuoGestureCoverageTests.swift](../../Tests/PlaygroundDuoGestureCoverageTests.swift) |
| `PlaygroundDuoCoordinateCoverageTests` | 28 | [PlaygroundDuoGestureCoverageTests.swift](../../Tests/PlaygroundDuoGestureCoverageTests.swift) |
| `PlaygroundDuoScrollCoverageTests` | 12 | [PlaygroundDuoScrollCoverageTests.swift](../../Tests/PlaygroundDuoScrollCoverageTests.swift) |
| `PlaygroundDuoSelectedSwitchTests` | 24 | [PlaygroundDuoSelectedControlTests.swift](../../Tests/PlaygroundDuoSelectedControlTests.swift) |
| `PlaygroundDuoTapStyleTests` | 6 | [PlaygroundDuoSelectedControlTests.swift](../../Tests/PlaygroundDuoSelectedControlTests.swift) |
| `PlaygroundDuoSelectedTargetTests` | 2 | [PlaygroundDuoSelectedTargetTests.swift](../../Tests/PlaygroundDuoSelectedTargetTests.swift) |
| `PlaygroundDuoSelectedSliderTests` | 6 | [PlaygroundDuoSelectedTargetTests.swift](../../Tests/PlaygroundDuoSelectedTargetTests.swift) |
| `PlaygroundDuoPairCoverageTests` | 28 | [PlaygroundDuoPairCoverageTests.swift](../../Tests/PlaygroundDuoPairCoverageTests.swift) |
| `PlaygroundDuoRetainedInputTests` | 8 | [PlaygroundDuoRetainedInputTests.swift](../../Tests/PlaygroundDuoRetainedInputTests.swift) |
| `PlaygroundDuoRetainedPairTests` | 3 | [PlaygroundDuoRetainedPairTests.swift](../../Tests/PlaygroundDuoRetainedPairTests.swift) |
| `PlaygroundDuoAdditionalInterruptionTests` | 10 | [PlaygroundDuoAdditionalInterruptionTests.swift](../../Tests/PlaygroundDuoAdditionalInterruptionTests.swift) |
| `PlaygroundDuoMotionOptionsTests` | 6 | [PlaygroundDuoMotionOptionsTests.swift](../../Tests/PlaygroundDuoMotionOptionsTests.swift) |
| `PlaygroundDuoNavigationTests` | 3 | [PlaygroundDuoMotionOptionsTests.swift](../../Tests/PlaygroundDuoMotionOptionsTests.swift) |
| `PlaygroundDuoTapWaitTests` | 23 | [PlaygroundDuoTapWaitTests.swift](../../Tests/PlaygroundDuoTapWaitTests.swift) |
| `PlaygroundDuoBatchCoverageTests` | 19 | [PlaygroundDuoBatchCoverageTests.swift](../../Tests/PlaygroundDuoBatchCoverageTests.swift) |
| `PlaygroundDuoLegacyBatchInterruptionTests` | 2 | [PlaygroundDuoLegacyBatchInterruptionTests.swift](../../Tests/PlaygroundDuoLegacyBatchInterruptionTests.swift) |
| `PlaygroundDuoSameAppFoldTests` | 1 | [PlaygroundDuoLegacyBatchInterruptionTests.swift](../../Tests/PlaygroundDuoLegacyBatchInterruptionTests.swift) |
| `PlaygroundDuoHorizontalPresetTests` | 1 | [PlaygroundDuoLegacyBatchInterruptionTests.swift](../../Tests/PlaygroundDuoLegacyBatchInterruptionTests.swift) |
| `PlaygroundDuoKeyboardSourcesTests` | 16 | [PlaygroundDuoKeyboardSourcesTests.swift](../../Tests/PlaygroundDuoKeyboardSourcesTests.swift) |
| `PlaygroundDuoSelectedKeyInterruptionTests` | 2 | [PlaygroundDuoKeyboardSourcesTests.swift](../../Tests/PlaygroundDuoKeyboardSourcesTests.swift) |
| `PlaygroundDuoSelectedBatchKeyboardTests` | 10 | [PlaygroundDuoKeyboardSourcesTests.swift](../../Tests/PlaygroundDuoKeyboardSourcesTests.swift) |
| `PlaygroundDuoHeldModifierTests` | 2 | [PlaygroundDuoHeldModifierTests.swift](../../Tests/PlaygroundDuoHeldModifierTests.swift) |
| `PlaygroundDuoTypingInterruptionTests` | 1 | [PlaygroundDuoTypingInterruptionTests.swift](../../Tests/PlaygroundDuoTypingInterruptionTests.swift) |
| `PlaygroundDuoHardwareTests` | 9 | [PlaygroundDuoHardwareTests.swift](../../Tests/PlaygroundDuoHardwareTests.swift) |
| `PlaygroundDuoHardwareInterruptionTests` | 6 | [PlaygroundDuoHardwareInterruptionTests.swift](../../Tests/PlaygroundDuoHardwareInterruptionTests.swift) |
| `PlaygroundSimulatorLifecycleTests` | 1 | [PlaygroundSimulatorLifecycleTests.swift](../../Tests/PlaygroundSimulatorLifecycleTests.swift) |
| `PlaygroundDuoKeyboardInterruptionTests` | 4 | [PlaygroundDuoKeyboardInterruptionTests.swift](../../Tests/PlaygroundDuoKeyboardInterruptionTests.swift) |
| `PlaygroundDuoHingeWindowTests` | 7 | [PlaygroundHingeWindowTests.swift](../../Tests/PlaygroundHingeWindowTests.swift) |
| `PlaygroundDuoMediaTests` | 18 | [PlaygroundDuoMediaTests.swift](../../Tests/PlaygroundDuoMediaTests.swift) |
| `PlaygroundWindowTests` | 1 | [PlaygroundHingeWindowTests.swift](../../Tests/PlaygroundHingeWindowTests.swift) |
| `PlaygroundOrdinaryRegressionTests` | 8 | [PlaygroundOrdinaryRegressionTests.swift](../../Tests/PlaygroundOrdinaryRegressionTests.swift) |
| `PlaygroundAgentSelectorTests` | 9 | [PlaygroundAgentSelectorTests.swift](../../Tests/PlaygroundAgentSelectorTests.swift) |
| `PlaygroundAgentObservationTests` | 6 | [PlaygroundAgentObservationTests.swift](../../Tests/PlaygroundAgentObservationTests.swift) |
| `PlaygroundDuoManualBoundaryTests` | 7 | [PlaygroundDuoManualBoundaryTests.swift](../../Tests/PlaygroundDuoManualBoundaryTests.swift) |
| `PlaygroundAgentKeyTests` | 12 | [PlaygroundAgentKeyboardTests.swift](../../Tests/PlaygroundAgentKeyboardTests.swift) |
| `PlaygroundAgentKeyComboTests` | 16 | [PlaygroundAgentKeyboardTests.swift](../../Tests/PlaygroundAgentKeyboardTests.swift) |
| `PlaygroundAgentKeySequenceTests` | 7 | [PlaygroundAgentKeyboardTests.swift](../../Tests/PlaygroundAgentKeyboardTests.swift) |
| `PlaygroundAgentTouchTests` | 17 | [PlaygroundAgentTouchTests.swift](../../Tests/PlaygroundAgentTouchTests.swift) |
| `PlaygroundAgentDoubleTapTests` | 7 | [PlaygroundAgentDoubleTapTests.swift](../../Tests/PlaygroundAgentDoubleTapTests.swift) |
| `PlaygroundAgentDragTests` | 7 | [PlaygroundAgentDragTests.swift](../../Tests/PlaygroundAgentDragTests.swift) |
| `PlaygroundAgentPinchTests` | 8 | [PlaygroundAgentPinchTests.swift](../../Tests/PlaygroundAgentPinchTests.swift) |
| `PlaygroundAgentSliderTests` | 12 | [PlaygroundAgentSliderTests.swift](../../Tests/PlaygroundAgentSliderTests.swift) |
| `PlaygroundAgentNativeStateTests` | 4 | [PlaygroundAgentNativeStateTests.swift](../../Tests/PlaygroundAgentNativeStateTests.swift) |
| `PlaygroundAgentSystemOwnerTests` | 1 | [PlaygroundAgentSystemOwnerTests.swift](../../Tests/PlaygroundAgentSystemOwnerTests.swift) |
| `PlaygroundAgentBatchTests` | 6 | [PlaygroundAgentBatchTests.swift](../../Tests/PlaygroundAgentBatchTests.swift) |
| `PlaygroundClipboardTests` | 9 | [PlaygroundClipboardTests.swift](../../Tests/PlaygroundClipboardTests.swift) |
| `PlaygroundIndependentPairTests` | 6 | [PlaygroundIndependentPairTests.swift](../../Tests/PlaygroundIndependentPairTests.swift) |
| `PlaygroundSemanticSwitchTests` | 1 | [PlaygroundSemanticSwitchTests.swift](../../Tests/PlaygroundSemanticSwitchTests.swift) |
| `PlaygroundAgentTypeTests` | 8 | [PlaygroundAgentTypeTests.swift](../../Tests/PlaygroundAgentTypeTests.swift) |
| `PlaygroundDuoSemanticSwitchTests` | 2 | [PlaygroundSemanticSwitchTests.swift](../../Tests/PlaygroundSemanticSwitchTests.swift) |
| `PlaygroundDuoInteriorSliderTests` | 1 | [PlaygroundSemanticSwitchTests.swift](../../Tests/PlaygroundSemanticSwitchTests.swift) |
| `PlaygroundDuoAgentInterruptionTests` | 12 | [PlaygroundDuoAgentInterruptionTests.swift](../../Tests/PlaygroundDuoAgentInterruptionTests.swift) |
| `PlaygroundDuoMediaSafetyTests` | 10 | [PlaygroundDuoMediaSafetyTests.swift](../../Tests/PlaygroundDuoMediaSafetyTests.swift) |
| `PlaygroundDuoSelectedHomeBatchTests` | 1 | [PlaygroundDuoSelectedHomeBatchTests.swift](../../Tests/PlaygroundDuoSelectedHomeBatchTests.swift) |
| `PlaygroundDuoKeyboardDelayTests` | 1 | [PlaygroundDuoKeyboardDelayTests.swift](../../Tests/PlaygroundDuoKeyboardDelayTests.swift) |
| `PlaygroundSelectedClientExitTests` | 8 | [PlaygroundSelectedClientExitTests.swift](../../Tests/PlaygroundSelectedClientExitTests.swift) |
| `PlaygroundInputHandoverTests` | 3 (iPhone and Duo) | [PlaygroundInputHandoverTests.swift](../../Tests/PlaygroundInputHandoverTests.swift) |
| `PlaygroundColdInputHandoverTests` | 1 (iPhone only) | [PlaygroundColdInputHandoverTests.swift](../../Tests/PlaygroundColdInputHandoverTests.swift) |
| `PhotosButtonLeafE2ETests` | 2 (iPhone and Duo) | [PhotosButtonLeafE2ETests.swift](../../Tests/PhotosButtonLeafE2ETests.swift) |

## Separate checks and limits

Host checks stay separate from the 693 simulator cases. The latest 115 host checks passed against the raw-fix candidate. Local build, signing, archive and installation checks remain separate and pending for the final candidate. No combined final candidate pass is claimed.

The new cold setup waits for existing helpers to close on their own. It checks old and new raw helper locks and shared input ownership before the first UI input, then checks again before the selected DOWN. Both checks share one 75-second setup allowance. It does not stop another process or restart a simulator. The modified public setup has compiled in the frozen package, but has not run; current main build remains pending.

The Photos tests use a local raw accessibility DTO with `AXUniqueId` and `children`; they need no native framework test dependency. Their process observer returns at direct CLI exit, then runs one read-only ownership check after the prompt closes. Its environment requirement is explicit. The three diagnostic named wrappers stay outside the public source list and counts.

The no-flag held-letter and sequence checks use the CLI. The held Shift+A checks use a public library probe. They do not prove interruption of the no-flag `key-combo` command. Earlier selected Siri activation failed; its strict final app-effect check must pass before that result can change.

Repeated cold-start stress and conditional empty-tree recovery remain deferred. Apple Pay payment UI and Intel hardware testing are excluded. Apple Pay hardware delivery remains in scope. No upload, push, publication or deployment is authorised.
