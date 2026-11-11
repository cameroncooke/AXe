# Slider percentages

- Use exactly one of `--endpoint minimum|maximum` or `--value <0...100>`; values must be finite.
- No-flag (plain `axe slider`) interior percentages, on the Duo and on other simulators for a slider with a stable accessibility ID, use the measured native value-feedback route with the existing final raw AX verification; no-flag 0 and 100 there use the semantic endpoint route. Other no-flag cases keep the direct drag.

## Agent command

```bash
axe slider --agent --udid <UDID> --expected-pid <PID> --snapshot-id <UUID> --ref <REF> --value 63.25
```

- Use a current `sliderEndpoint` row. Adds no row token and no tap or drag eligibility.
- Checked before input: current snapshot, native target, inherited visibility, PID, screen, value, domain.
- Rejected: explicit selectors, type overrides, non-default polling, batch use.
- After input, use the replacement capture or refresh. Never reuse an old ref after a change.

## Selected command

```bash
axe slider --input-mode selected --udid <UDID> --id <ID> --value 63.25
```

- Optional guards: the screen pair (`--screen-id` with `--screen-uuid`) and `--expected-pid`. Without them AXe binds the active screen and frontmost app at command start ([device-reference.md](device-reference.md#selected-input)).
- Exactly one `--id` or `--label`. Labels match case-sensitively after trimming whitespace and newlines from query and native label. A label can select a Slider without an ID.
- Duplicates reject before optional `--element-type` filtering, so the filter cannot hide them. Type matching is exact and case-sensitive, with no trimming or aliases. Empty or whitespace-only filters reject.
- Must match: native Slider role, bound PID, current display, positive finite frame, numeric domain. Each owned-handle read must match the root target itself, not a matching child.
- Non-default wait/poll settings reject.

## Value and input rules

- Native slider reads keep their separate identity session and current target/PID/domain checks; no cached coordinates replace them.
- Value = `minimum + (maximum - minimum) * percentage / 100` of the native domain.
- 0 and 100 take the existing minimum or maximum semantic route before input (not a fallback after a physical failure). Receipt `slider` (`action.slider` in agent mode). Endpoint behaviour and its 20-action/15-second bounds are unchanged.

Interior values:

- Need horizontal native scrubber geometry increasing left to right on the current selected display. The measured display context maps logical points to that screen and orientation; no fixed display ID or rotation is required.
- Unsupported geometry rejects before DOWN. Native parent and point evidence are verified before the thumb is picked up. The last point/parent checks run inside the native input admission guard; the live display revision is checked again before DOWN.
- Bounds: 1 contact, 15-second action budget, at most 6 correction paths of at most 12 moves, tolerance 0.07 percent of the native domain.
- After DOWN, it steps one native pixel at a time toward the target until the value follows the contact (on iOS 27.2 the value holds still for about the first 10 points of a contact). Then come the correction paths, and two one-pixel moves before release so the slider keeps the held value when the contact ends.
- It reads fresh native values while the contact is held; a held value is settled after 400 ms unchanged. Each correction moves toward the requested value within the previous path's length.
- Toward the target, held moves can pass the slider frame by at most the lead measured on this contact, the slider's height and the admitted application frame.
- No endpoint seek to calibrate movement. Native value stability and final readback decide completion; app state is not a control input.
- Unreachable values or exhausted bounds fail without a second gesture.

Receipt and failure:

- Receipt `sliderValue` (`action.sliderValue` in agent mode): requested percentage, native target/domain/value, move count, delivery, cleanup.
- A native result does not prove every intermediate app callback; check the visible app value and callback separately.
- Context changes stop input and release the owned contact. Uncertain release keeps the input owner and quarantine; no replay or automatic recovery.
- The sequential checks do not lock the app layout or guarantee one recipient throughout the gesture.

Batches:

- Percentage requests are standalone only, including 0 and 100. Selected endpoint batch steps keep their behaviour; raw legacy batch slider stays unsupported.
- Older requests reject; use the matching native frameworks with guarded retained DOWN and physical value feedback.

## Limits

RTL, custom and vertical Sliders are unproved. No claim of smooth motion, all-callback history or general slider-domain support.
