# iPhone Duo, display-selected input and device commands

Open only for Duo hinge and rotation, input or capture pinned to one display, device buttons and simulator shutdown. App automation uses `--agent` (SKILL.md).

Rules for every command here:

- Never replay failed or uncertain input automatically: a failure can follow partial input or an effect.
- Receipts prove transport (delivery, cleanup), not the app effect. Verify the effect separately.
- Read the UI again after a fold, rotation or hinge change, before input.
- Selected requests need matching CLI, broker and native framework versions; incompatible or older requests reject.

## Contents

- [Simulator shutdown](#simulator-shutdown)
- [Screens, hinge and rotation](#screens-hinge-and-rotation)
- [App input on the iPhone Duo](#app-input-on-the-iphone-duo)
- [Selected input](#selected-input)
- [Selected Home button](#selected-home-button)
- [Selected device buttons](#selected-device-buttons)
- [Selected batch steps](#selected-batch-steps)
- [Selected PNG screenshots](#selected-png-screenshots)
- [Selected video recording](#selected-video-recording)
- [Selected video streams](#selected-video-streams)
- [Automation and testing](#automation-and-testing)

## Simulator shutdown

`axe shutdown --udid <UDID>`

- One simulator by UDID; names and aliases (such as `booted`) reject. No agent or batch options.
- Simulator shutdown, not guest lock or power-button input.
- Prints `Shut down <udid> (was Booted)` or `<udid> was already shut down`. JSON `{udid, initialState, outcome}`: `shutDown` only after state readback; `alreadyShutDown` sends no request.
- 60-second budget; after a failure, inspect the state.

## Screens, hinge and rotation

`axe displays --udid <UDID>` waits for a fold or rotation to finish, then shows the screens:

```
iPhone Duo  2154413A-7E31-4566-A03E-598AC9B5D4D7
Hinge   113.8°, partially open

Active  inner  951×669 pt @3x  landscape
        id 3   0DFCB507-C4AA-4CB8-8575-8E2D0DB7C6B9
Off     outer  466×678 pt @3x
        id 1   85D7C4CD-0F9F-422B-94DA-658B4164694D
```

- Sizes are logical points, the unit of all AXe coordinates. The active size is oriented (like `capture.screen`); other screens are unrotated.
- Role: `outer` (smaller built-in screen), `inner` (larger), `main` (one-screen device; no Hinge line).
- `axe --output json displays --udid <UDID>` → `data.result`: `{udid, name, hinge?: {degrees, mechanicalDegrees, posture}, activeScreen: {id, uuid, role, width, height, scale, rotation, orientation, state}, otherScreens: [{id, uuid, role, width, height, scale, state}]}`.
- `state` (from backlight): `on`, `locked`, `off`, `starting`, `unknown`.
- An observation, not a lease: selected input and capture check the screen again.

`axe hinge read --udid <UDID>` prints `Hinge 113.8°, partially open`; JSON `{udid, hinge: {degrees, mechanicalDegrees, posture}}` (the `hinge` of `displays`).

- `degrees`: angle iOS senses, rounded to 0.1; the true pose.
- `mechanicalDegrees`: angle `hinge set` drives; at rest can differ by several degrees (mechanical 120, sensed 113.8).
- `posture`: `closed` (sensed ≤ 0.5°), `partiallyOpen`, `open` (≥ 179.5°).
- One-screen simulator: hinge commands fail with `noHinge`.

`axe hinge set <0-180|closed|tabletop|open> --udid <UDID>`

- Names are case-sensitive: 0, 90, 180. Fractions valid.
- Sends one request, never repeats it; `bootChanged` if the simulator restarts.
- By default waits up to 8 s for the screens to settle and prints:

```
Hinge 180°, open (was 113.8°)
Active  inner  951×669 pt @3x  landscape
        id 3   0DFCB507-C4AA-4CB8-8575-8E2D0DB7C6B9
```

- JSON `{udid, previousDegrees, hinge: {degrees, mechanicalDegrees, posture}, activeScreen?}`. `--no-wait` returns once the hinge reaches the angle, without `activeScreen`.
- Bounds on the mechanical move: `--tolerance` 0...1 degrees (default 0.5), `--timeout` 0.5...15 s (default 8).
- iOS 27.2: closing settled in about 3 s, opening in about 0.6 s.

`axe rotate left|right --udid <UDID>`

- Prints `Rotated left` (or right) and the active screen; JSON `{udid, direction, previousRotation, activeScreen}`.
- Rotates the screen active at start; with `--screen-id` and `--screen-uuid`, refuses unless that screen is active. `bootChanged` if the simulator restarts.
- Device-wide: takes the common input lock, rejects held touches.
- Sends one request, observes two matching positions, checks the position remains after the connection closes. `--timeout`: observation budget, 0.5...15 s, default 8; native reads have separate bounds.
- Duo: all four inner positions; the outer screen skips upside-down portrait.
- App layout readiness is not guaranteed.
- An uncertain send holds the input lock and saves a recovery record.
- Not the two-finger `gesture rotate`; not a batch step.

Failures carry one code: `targetNotFound`, `notBooted`, `noHinge`, `bootChanged`, `busy`, `timeout`, `hingeUnavailable`, `screensDidNotSettle`, `displayUnavailable` (no consistent set of screens yet, as in the first seconds after boot; read again), `rotationFailed`, `quarantined`.

## App input on the iPhone Duo

- Use the agent commands. An agent capture binds the active screen; a fold, rotation or hinge change makes its refs stale, so capture again.
- Plain `tap`, `touch`, `swipe`, `drag` and `type` run on the Duo with logical points and measured pose checks but check no target or app: never use them to operate an app.
- At most 100,000 movement steps on the Duo; larger paths reject before event allocation.

## Selected input

Use `--input-mode selected` only when input must refuse every screen but one, or the command has no agent form.

- Commands: `describe-ui`, `tap`, `slider`, `touch`, `swipe`, `drag`, `gesture`, `type`, `key`, `key-sequence`, `key-combo`, `button`, `batch`.
- `--screen-id <ID> --screen-uuid <UUID>` (from `axe displays`), optional: refuses unless that screen is active. Without it, the broker binds the screen active when it admits the request.
- A retained touch keeps its screen: a fold since `touch --down` fails, never retargets.
- `--expected-pid <PID>`, optional where AXe reads accessibility (`describe-ui`, selector `tap`, `slider`, keyboard); `touch`, `swipe`, `drag` accept it only with `--agent`. Without it, the broker binds the app frontmost at start; every later target, hit and frontmost check requires that PID, so an app change fails before input.
- Keyboard commands require `--focus-id`.

Output:

- Default as the plain command: `describe-ui` (also `--point`) prints the accessibility tree JSON (`roots`); retained `touch --down` prints `Contact token: <uuid>`; other input prints nothing.
- `axe --output json`: `{outcome: "completed", screen: {id, uuid, width, height, rotation}, pid, token?}`. Ordinary and physical input: `{outcome: "completed"}`.
- Failure: one error code, either the accessibility failure (such as `targetRejected`) or `rejectedBeforeInput`, `inputFailed`, `cleanupUncertain`, `quarantined`, `timeout`, `busy`; it says whether any input was sent.
- `--verbose`: full broker receipt, also for ordinary input the broker owns on the Duo and DTUHID simulators.

Reads:

- AX reads go to the device directly; a short-lived accessibility bootstrap runs only after a direct read returns an empty tree or a point read fails.
- Native slider and semantic-switch identity sessions stay separate from physical HID input.
- `describe-ui --point X,Y`: oriented logical display points; reads one direct native element. Foreground app before and after, and the point result, must match the bound PID; foreign or hosted-process results reject. Sends no input; returns no retained tap target.

Selector taps (HID, strict target validation):

- A rejected hit sends nothing. Never bypass a selected rejection with plain input.
- AXe validates the final target and sends one tap; a failed validation or send is never retried.
- Optional `--element-type <Type>` on `tap --id|--label|--value`: take the type from a fresh description (for example `Button`). Exact, case-sensitive, no aliases or trimming; empty or whitespace-only rejects. Applied before uniqueness and again to the final target. If a proved StaticText child is the hit for a Button, filter the Button. Bound screen, PID and hit checks still apply. Coordinates and `--semantic-press` reject the filter and polling.
- `tap --value <text>`: case-sensitive text match after trimming surrounding whitespace (`true` ≠ `TRUE`, `1.0` ≠ `1`). Not with coordinates, another selector or `--semantic-press`.
- Tap routes on other devices are unchanged.

Semantic press, native `CheckBox` only: `tap --semantic-press --id <ID>` with selected options.

- Coordinates, labels, values, delays and explicit styles reject. Needs the inspected host image; no HID or mouse fallback.
- Success: `switchValueChangedObserved`, a fresh same-target Boolean change within the original 8-second budget. Reply and delivery stay separate.
- Verify app callbacks: zero AXe HID does not mean zero guest touches.

Keyboard (`type`, `key`, `key-sequence`, `key-combo`) with `--focus-id <exact-field-ID>` and optional `--expected-pid`:

- First focus the field explicitly and inspect it: an enabled, visible, focused `TextField`.
- Checked before every key down; key-up cleanup needs no focus.
- Text: US key positions unless `--layout <name>` names the device's keyboard layout (`British`, `German`); `--layout auto` is simulator-only. At most 256 UTF-8 bytes. Sequences: at most 1024 events and 20 s requested delay, within a shared 8-second admission budget.
- Not atomic OS recipient control.

Slider:

- Exactly one ID or label, and exactly one of `--endpoint minimum|maximum` or finite `--value <0...100>`.
- Interior values need horizontal native scrubber geometry increasing left to right on the current measured screen; RTL, custom and vertical sliders are unproved. 0 and 100 use the semantic endpoint route before input.
- Non-default polling and percentage batch steps reject. Read [slider selection, input limits and receipts](slider-reference.md) first.

Retained touch: pass the token `touch --down` prints as `--contact-token`. Forms: `touch --help`.

Gestures:

- Coordinate gestures (`pinch`, `double-tap`, `rotate`, `two-finger-tap`, `two-finger-hold`, standalone `two-finger-swipe`) use this owned route even without the flag; with it, the screen pair can guard the screen. See `axe gesture --help`. Receipts do not prove app recognition.
- `two-finger-swipe`: starts `-x/-y`, `--x2/--y2`; ends `--end-x/--end-y`, `--end-x2/--end-y2`. Selected logical points, shared duration and delta, existing gesture bounds. Either finger may stay still. Simultaneous coincident contacts reject, including between samples; crossings at different times are allowed. Batch and agent mode reject it.
- `swipe-from-left-edge|right-edge|top-edge|bottom-edge --edge-inset <points>`: changes only the start distance from that edge; finite, positive, leaving an inward path. The opposite endpoint stays 20 logical points from its edge. Defaults: start inset 20, duration 0.3 s, delta 50. Example: 951-point-wide display, left inset 1 → x=1 to x=931. Plain, selected and batch steps support it; scroll and complete multi-touch gestures reject it. Selected bounds are read fresh. Explicit geometry, not an automatic Back action or fallback; inspect the visible app.

## Selected Home button

`axe button home --udid <UDID> --input-mode selected`, optional active-screen pair.

- Home acts on the whole device; the pair guards context, it does not route Home to one display or app.
- `--duration` omitted: down/up, no requested hold. Explicit: finite, > 0, ≤ 10 s; fractions such as `0.2` work.
- `--verbose`, when available: receipt `home` fields (execution phase, planned/sent counts, release/drain flags, interruption, cleanup release evidence). No execution evidence, no `home` result. Transport records only, not an OS held-button inventory or visible-Home proof.
- Home can act before an unchanged final-pose guard reports failure; preserve that failure.
- Also a selected batch step, same request and guards.

## Selected device buttons

`axe button <side-button|siri|lock|apple-pay> --udid <UDID> --input-mode selected`, optional active-screen pair (guards context; buttons act on the whole device).

- Duration as Home: omitted, no hold; explicit finite, > 0, ≤ 10 s.
- Typed `button.kind` and execution/cleanup evidence (`--verbose`) confirm transport only. No receipt proves Siri, Wallet or payment UI, secure lock, wake or power state.
- Siri, Lock, side-button: two primitives. Apple Pay (native two-side-press): four primitives, 0.15 s gap, half the supplied duration per hold. Home keeps its `home` result.
- A final context failure can follow an effect; never use a fallback button.
- Batch steps: same names, guards and exact count/release checks. Raw routes unchanged. Selected requests use a separate broker endpoint.

## Selected batch steps

```bash
axe batch --udid <UDID> --input-mode selected \
  --step 'tap --id <ID>' \
  --step 'type --focus-id <FIELD_ID> -- hello'
```

- Batch level: UDID, input mode, optional screen pair. Without the pair, each step binds the screen active when the broker admits it.
- Per step: `--focus-id` on each keyboard step (field already focused); `--expected-pid` only to refuse another app, otherwise each step binds the app frontmost when it starts. Keep per-step options on the step.
- Each input step resolves its current context and target. Selector taps keep the IDB accessibility-readiness check; slider endpoints keep native semantic control; keyboard steps keep focus checks.
- After a fold, rotation or app change, a step with the pair or its own `--expected-pid` refuses; one without binds the new screen and app.
- No whole-batch lease or transition wait. Use separate commands when the next step needs a fresh inspection.
- Supported: complete taps, slider endpoints, swipes, drags, draws, gestures, touch down/up pairs, literal/file/stdin text, keys, key sequences, key combinations, `button home|side-button|siri|lock|apple-pay`, `sleep`. Not supported: `gesture two-finger-swipe`, `tap --semantic-press`, retained-token chains. Batch-level tap-style, polling and continue-on-error reject.
- ID/label/value tap steps accept `--element-type` with the standalone builder and final target checks.
- Success prints `✓ Batch completed successfully (N steps)`. `--verbose`: one JSON line per attempted step (index, request ID, status, full response when available).
- Any failure, including output failure, stops later steps; earlier effects remain; nothing is replayed.

`type --stdin`:

- Reads process stdin once at that step, before its keyboard request. Give steps with `--step` or `--file`, pipe the text, close the pipe.
- 1–256 UTF-8 bytes, US key positions or the named `--layout`; bytes and newlines are not trimmed or truncated.
- The synchronous read waits for EOF with no deadline and cannot observe cancellation while blocked; cancellation is checked after the read and before send. Normal PID, focus and per-key checks apply.
- Invalid or empty input stops later steps.
- Batch-level `--stdin` consumes the stream first, so a nested `type --stdin` sees EOF and rejects empty text. A second stdin step also sees EOF after the first successful read; there is no separate text stream.

`drag`:

- Options `--start-x`, `--start-y`, `--end-x`, `--end-y`, `--duration`, `--steps`, `--pre-delay`, `--post-delay`. Defaults as standalone selected drag: 0.6 s, 60 steps.
- Fresh oriented logical coordinates; the whole path is checked against current selected bounds before input.
- No selectors or `--expected-pid`; does not prove the recipient app.

`slider`:

- Exactly one `--id` or `--label`, plus `--endpoint minimum|maximum`; optional `--expected-pid`. Screen selection from the batch.
- Native semantic control, zero HID events. `endpointObserved` (clean) confirms endpoint value readback; `alreadyAtEndpoint` completes without a new action. Neither is a touch-release receipt or callback proof.
- Optional `--element-type` uses the standalone builder and native checks; filtered completion needs matching bounded native type evidence for the recorded samples and actions.
- Label steps: same trimmed, case-sensitive matching and duplicate-before-type checks as standalone selected slider, including targets without an ID.
- Percentage `--value` and non-default wait/poll options reject. Legacy batch slider is unsupported.
- A failure can follow a semantic action; keep the receipt.

`button home`: same request, duration rules and typed completion evidence as [Selected Home button](#selected-home-button); the batch supplies the screen selection.

`sleep <seconds>`:

- Host wait; no input lease or broker request. Any finite non-negative Double, including 0; no total cap.
- Monotonic elapsed time, bounded cancellable waits; not a readiness or exact timing guarantee.
- JSON step receipt `hostWait`: `requestedSeconds`, `elapsedSeconds`, `outcome`, error when present; no request ID or broker response. Status `completed`; `waitInterrupted` or `waitFailed` (interruption, wait-owner failure) stops later steps.
- SIGINT/SIGTERM handling only during the wait: cancels and awaits the wait task, then restores prior signal dispositions. Not whole-batch signal handling or an atomic signal-boundary guarantee.
- The next input step runs its normal fresh guards. Sleep does not preserve or prove device state, reserve the device or inspect other processes' held input.

## Selected PNG screenshots

```bash
axe screenshot --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --output selected.png
```

- Both options required: the measured active screen's `id` and `uuid` from `axe displays`. No `--input-mode` or `--expected-pid`.
- An inactive panel, invalid selection or changed context fails, with no display or legacy fallback. Existing files are not replaced.
- Success writes the PNG and prints its path. `--verbose`: JSON receipt with path, pixel size, before/after context, capture child receipt.
- No surface identity or frame presentation time. Context checks bound the capture but do not prove an atomic frame/context observation.
- `SIGINT`/`SIGTERM` request cancellation; AXe waits for the operation and its cleanup to return. Cancellation accepted before output publication writes no PNG; a late signal can arrive after publication. Unconfirmed cleanup stays an error. Cleanup after parent termination or `SIGKILL` is not guaranteed.
- Without the pair, legacy capture and path-only stdout are unchanged.

## Selected video recording

Fixed panel: `--screen-id`/`--screen-uuid`. Fixed-canvas movie following measured display changes on one boot: `--follow-active-display`. Never combine them. Options, bounded transition recovery, stop/publication rules and limits: [recording contract](recording-reference.md).

## Selected video streams

```bash
axe stream-video --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --format raw
```

- Active screen's pair from `axe displays`. No `--input-mode` or `--expected-pid`.
- stdout: stream bytes only. Capture stderr separately: dimensions, layout, frame counts, final summary.

| Format | stdout bytes |
|---|---|
| `raw` | 4-byte unsigned big-endian JPEG length, then exactly that JPEG |
| `ffmpeg` | concatenated standalone JPEGs; no ffmpeg process starts |
| `mjpeg` | boundary `mjpegstream` declared without delimiter hyphens; parts use `--mjpegstream`, Content-Length, JPEG bytes; normal completion includes the closing delimiter |
| `bgra` | packed top-to-bottom BGRA, premultiplied alpha, no row padding, `width * 4` row bytes, `width * height * 4` frame bytes; dimensions from stderr; quality has no effect |

- Scaling: upright PNG dimensions, rounded down, minimum one pixel.
- Every frame must keep the initial boot, panel, geometry, scale, orientation and hinge pose; a context or capture failure stops, no retargeting or retry. The lease covers each capture only.
- FPS is a requested maximum; achieved FPS uses host output times, not display presentation times.
- No surface identity or atomic frame/context proof. Never claim continuous rotation or fold coverage.
- Stop with SIGINT or SIGTERM and await the real exit; capture cleanup is awaited.
- A started packet must finish within the 5-second output deadline or fail; successful MJPEG also needs its closing delimiter. The deadline bounds userspace backpressure waits, not all native/kernel calls or encoding.
- Errors or cancellation can leave partial bytes: keep them as incomplete; never retry by appending. A summary alone is not success if the final exit or cleanup fails.
- Cleanup after parent termination or SIGKILL is not guaranteed.
- Without the pair, legacy streaming is unchanged.

## Automation and testing

Options hidden from `--help`, for test suites needing a fixed boot, a specific destination screen or full broker evidence:

- `--expected-boot <PID:SECONDS:MICROSECONDS>`: refuses unless the boot matches. On `hinge read`, `hinge set`, `rotate`, selected `button` and its batch steps, and `screenshot`, `record-video`, `stream-video` with the screen pair or `--follow-active-display`. Identity: `bootIdentity` in `axe displays --verbose`. Without it, `hinge set` and `rotate` pin the boot they read at start.
- `hinge set --wait-for-screen-id <ID> --wait-for-screen-uuid <UUID>`: also requires that screen to become active after the move. Pass both. `--readiness-timeout <seconds>` (0.5...15, default 8) bounds the wait. `--no-wait` rejects them.
- `--verbose` prints full JSON instead of the short result: display measurements on `displays` (pixels, native orientation, primary display, `bootIdentity`, `readInterval`, source fields); the broker reply on `hinge read`, `hinge set`, `rotate`; the broker receipt on every selected input command (one JSON line per attempted step on `batch`). Exit status, error code and checks are identical without it. Parse it only when a check needs context, target-check or cleanup evidence.
