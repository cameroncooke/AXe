# Selected slider percentages

Use exactly one of `--endpoint minimum|maximum` or `--value <0...100>`. Values must be finite. The no-flag slider command keeps its existing behavior.

## Selected command

`axe slider --input-mode selected --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --expected-pid <PID> --id <ID> --value 63.25`

Use exactly one ID or label. Labels match case-sensitively after trimming whitespace and newlines from the query and native label. A label can select a Slider without an ID. Duplicate matches reject before optional `--element-type` filtering; the filter cannot hide duplicates. Type matching is exact and case-sensitive, without trimming or aliases. Empty or whitespace-only filters reject. The native Slider role, expected PID, current display, positive finite frame and numeric domain must match. Each owned-handle read must match the root target itself, not a matching child. Select `--ax-preparation automation-session|existing-bridge` as with endpoints. Non-default wait/poll settings reject.

## Agent command

`axe slider --agent --udid <UDID> --expected-pid <PID> --snapshot-id <UUID> --ref <REF> --value 63.25`

Use the existing current `sliderEndpoint` row. This adds no new row token or tap/drag eligibility. The current snapshot, native target, inherited visibility, PID, screen, value and domain are checked before input. Explicit selectors, type/preparation overrides, non-default polling and batch use reject. Use the replacement capture or refresh after input. Never reuse an old reference after a change.

## Value and input rules

A percentage maps to the native domain: `minimum + (maximum - minimum) * percentage / 100`. Numeric 0 and 100 select the existing minimum or maximum semantic route before input. Their receipt is `slider` (`action.slider` in agent mode). This is not a fallback after a physical failure. Endpoint behavior and its 20-action/15-second bounds remain unchanged.

Interior values require horizontal native scrubber geometry that increases from left to right on the current selected display. The measured display context maps logical points to that screen and orientation; there is no fixed display-ID or rotation requirement. Unsupported geometry still rejects before DOWN. The command verifies native parent and point evidence before it picks up the thumb. The last point/parent checks run inside the native input admission guard; the live display revision is checked again before DOWN.

The physical route uses at most one contact, four paths of at most 12 moves each, and a 15-second action budget. It reads fresh native values while the contact is held. Each correction moves toward the requested value within the previous path's length. It does not seek an endpoint to calibrate movement. Native value stability and final readback decide completion; app state is not a control input. Unreachable values or exhausted bounds fail without a second gesture. The tolerance is 0.07 percent of the native domain.

The receipt is `sliderValue` (`action.sliderValue` in agent mode). It records the requested percentage, native target/domain/value, move count, delivery and cleanup. A native result does not prove every intermediate app callback. Check the visible app value and callback separately. Context changes stop input and release the owned contact. Uncertain release keeps the input owner and quarantine; there is no replay or automatic recovery. These sequential checks do not lock the app layout or guarantee one recipient throughout the gesture.

Percentage requests are standalone only, including numeric 0 and 100. Selected endpoint batch steps keep their behavior. Raw legacy batch slider remains unsupported. Current CLI wire 34 rejects older requests and needs the matching native frameworks with guarded retained DOWN and physical value feedback.

## Verification

Isolated controllers proved input on the outer display in portrait and the inner display at rotation 90, with actual app value changes and released contacts. One separate fold rejected before DOWN. These checks do not establish this public command, endpoint-to-interior pickup, other positions or general slider support. Earlier failed runs remain recorded. The incremental CLI build and public native proof are pending for this source change. Security scanning is UNVERIFIED per Cam. RTL, custom and vertical Sliders remain unproved. No smooth motion, all-callback history or general slider-domain claim is made.
