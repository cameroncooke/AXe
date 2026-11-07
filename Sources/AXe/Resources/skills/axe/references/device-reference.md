# iPhone Duo, display-selected input and device commands

Read this only for work the agent path in SKILL.md does not cover: iPhone Duo hinge and rotation,
input or capture on one explicitly selected display, device buttons and simulator shutdown.
For ordinary app automation, use `--agent` as SKILL.md describes.

## Simulator shutdown

Use `axe shutdown --udid <UUID>` for one simulator. JSON reports `shutdownCompleted` only after state readback, or `alreadyShutdown` without a request. Names/all aliases reject. This is simulator shutdown, not guest lock or power-button input. It has a 60-second budget; inspect state after failure. Do not use agent/batch options.

## Selected Duo input

Use ordinary `tap`, `touch`, `swipe` and `drag` without mode flags on the iPhone Duo with current logical UI coordinates. AXe measures the active display and checks boot, panel, hinge, orientation and geometry before input. Keep legacy tap selectors/styles and wait/poll options. Swipe and drag keep their existing event factories, movement duration, swipe delta and drag steps/holds. Their pre/post delays run on the host; normal text output remains. Do not request more than 100,000 movement steps on Duo; AXe rejects these paths before event allocation. Retain the existing `drag --steps` range of 1...1,000. Do not treat pose checks as an app/PID or UI-layout guard. Ordinary `tap` on other DTUHID devices uses the same broker route and reuses one input connection; their `touch`, `swipe` and `drag` keep the existing route. Ordinary Duo typing and batch use owned input below.

Use ordinary Duo `touch -x X -y Y --down` to start one contact; repeat `--down` at a new point to move it. Use `--up` to end at its supplied point, with no added move. Keep the default 0.1-second hold for `--down --up`, or set `--delay 0...10`. The broker owns a successful down across command exits for 60 idle seconds. An orphan up sends zero HID events (`noOwnedContact` internally). Folding or rotation invalidates the stream and releases its original input. Refresh before a new contact; never replay uncertain input. Do not use this route to release selected-token input or claim app/PID, layout or batch guards. Explicit selected retained touch still needs its token, ends at the last held point and keeps its 30-second idle limit.

AXe supports explicit display input on `describe-ui`, `tap`, `slider`, `touch`, `swipe`, `drag` and `gesture`. Use `--input-mode selected --screen-id <ID> --screen-uuid <UUID>` from a fresh display read. Selected AX operations also require the current frontmost app's `--expected-pid <PID>`. Do not assume the primary display is active. Read the UI again after folding or rotation.

Use the normal IDB accessibility-readiness check for selected AX reads and physical target checks. No new preparation option or retained preparation layer is present. Reads go to the device directly; the original v1.8.0 short-lived bootstrap runs only after a direct read returns an empty tree or a point read fails. Native slider and semantic-switch identity sessions remain separate from physical HID input. Use matching CLI, broker and native framework versions. Incompatible requests reject.

Use `axe list-simulators --displays --udid <UDID>` to read the measured integrated catalogue and active panel for one booted simulator. It retains the existing fields and adds the before/after-matched `bootIdentity` and `readInterval.startedUptime`/`finishedUptime` in host monotonic seconds. The interval bounds the full discovery read, not a frame time; do not compare it across machines. These fields are not a lease or admission token. Selected input and capture still perform fresh checks; default legacy capture is unchanged. No new option is required.

Selected `describe-ui --point X,Y` uses oriented logical display points and requires the selected screen plus `--expected-pid`. It reads one direct native element. The foreground app before/after and the point result must match that PID; foreign or hosted-process results are rejected. It sends no input and returns no retained tap target.

Ordinary selected `tap --id`, `tap --label` or `tap --value` accepts optional `--element-type <Type>`. Read the type from a fresh description, for example `Button`. Matching is exact and case-sensitive, without aliases or type-name trimming; empty or whitespace-only types reject. The filter applies before uniqueness and again to the final target before input. If a proved StaticText child is the hit for a Button, filter the Button target rather than its child. Keep the screen pair, expected PID and all hit checks. Coordinates and `--semantic-press` reject the filter and polling. For an ordinary selected ID, label or value tap, use `--wait-timeout <seconds>` from greater than zero through 30. Use `--poll-interval <seconds>` from 0.05 through 30 (default 0.25). Without a positive wait, keep the default interval. Only an absent match is retried. Duplicate matches, a wrong PID, read errors, cancellation or a changed screen, hinge, rotation or boot stop the command. AXe keeps the initial screen and input lease, then validates the final target and sends one tap. A failed final validation or input send is never retried. The wait receipt records attempts, elapsed time and outcome. Selected requests require a matched CLI and broker; incompatible requests reject. Tap routes on other devices are unchanged.

Ordinary selected coordinate or ID/label/value taps accept explicit `--tap-style physical`, `--tap-style simulator` or `--tap-style automatic`. Omitted style and explicit `physical` keep the existing guarded touch path. Explicit `simulator` uses the real `tapAt` down/up sequence with no inserted hold. Explicit `automatic` uses that simulator sequence for coordinates. For selectors, it uses the existing `AccessibilityElement.isSwitchLikeControl` rule on the resolved target: physical for switch/toggle-like controls, simulator otherwise. The style choice is checked again on the fresh validated target before the first down; a changed choice rejects before input. This does not add legacy descendant/sibling redirection or retry another style after failure. Selector taps retain exact ID/label/value/type, current/final target and expected PID checks; coordinates have fresh selected bounds but no PID or AX target guard. Pre/post delays, context checks, owned release and cleanup remain in effect. Put the style inside a selected batch tap step, for example `--step 'tap --id <ID> --tap-style automatic --expected-pid <PID>'`; the same builder and guards apply. Non-default batch-level styles (`physical` or `simulator`) and non-default batch-level wait/poll options remain rejected. Explicit batch-level `automatic` is accepted as the existing default but does not change selected step style; a step with no style keeps the physical 0.1-second hold. `--semantic-press` rejects every explicit style. This is not full switch support or exact legacy timing parity. Verify the app effect separately; there is no semantic/legacy fallback or automatic replay.

Selected `tap --value <text>` uses the legacy scalar text conversion for AXValue: String first, then Int, Double and Bool converted to text. Missing, null, array and object values do not match. Both the query and scalar text trim surrounding whitespace/newlines, then compare case-sensitively; query text is not parsed as a number. For example, `true` differs from `TRUE`, and query `1.0` does not equal scalar text `1`. Empty or whitespace-only queries reject. Optional exact `--element-type` filters before strict uniqueness; selected matching does not prefer an actionable duplicate. The value must still match at the current and final guarded target checks. Keep the measured pair and expected PID, and verify the app effect separately. Values cannot be combined with coordinates, another selector or `--semantic-press`; there is no fallback.

Selected selector taps use HID and strict target validation. A rejected hit does not trigger semantic AXPress or legacy input. The automatic legacy switch/toggle behavior above does not establish selected Duo switch support. Full keyboard, media, batch and agent coverage remain incomplete; do not bypass a selected rejection by sending legacy input. Complete selected batch steps use the route below.

For native `CheckBox` only, use `tap --semantic-press --id <ID>` with selected options and `--expected-pid`. Coordinates, labels, values, delays and explicit styles reject. The inspected host image is required; no HID/mouse fallback occurs. Success is `switchValueChangedObserved` after fresh same-target Boolean change within the original eight-second budget. Reply/delivery stay separate. Verify app callbacks; zero AXe HID does not mean zero guest touches. Never replay.

Ordinary Duo `type` preserves literal/file/stdin loading, US mapping and plain output. It uses one measured owned session with startup readiness, context checks, signal cancellation and key release. It remains stateless, with no added PID/focus guard or selected text limit. Never replay partial or uncertain input. Other-device typing and optional agent behavior are unchanged.

`type`, `key`, `key-sequence` and `key-combo` also accept selected screen options plus `--expected-pid <PID> --focus-id <exact-field-ID>`. First focus that field explicitly and inspect it. It must be an enabled, visible, focused `TextField`. AXe checks it before every key down; key-up cleanup does not require focus. Text input keeps the existing US keyboard mapping and is capped at 256 UTF-8 bytes. Complete sequences allow at most 1024 events and 20 seconds of requested delay, within a shared eight-second admission budget. This is not atomic OS recipient control. Input can be partial on failure; never replay it automatically.

Selected slider operations require exactly one ID or label and exactly one `--endpoint minimum|maximum` or finite `--value <0...100>`. Interior values require horizontal native scrubber geometry that increases from left to right on the current measured screen. RTL, custom and vertical Sliders remain unproved. Numeric 0 and 100 use the existing semantic endpoint route before input. Read [slider selection, input limits and receipts](slider-reference.md) before use. Non-default polling and percentage batch steps reject. No-flag Duo interior percentages use measured native value feedback. No-flag 0/100 and other-device slider routes retain the existing direct drag. Explicit selected retained touch operations require the receipt's `--contact-token`; use `touch --help` for complete/retained forms.

Use `axe hinge read --udid <UDID>` for native angle and boot identity. Set once with `axe hinge set <degrees|closed|tabletop|open> --udid <UDID> --expected-boot <identity>`. Exact case-sensitive names mean 0/90/180 degrees; numeric fractions remain valid. Names retain options, JSON and measured mechanical completion. For separate active-screen readiness, supply both `--wait-for-screen-id` and `--wait-for-screen-uuid`. Names do not select a screen. Refresh display/UI before input.

Use `axe rotate left|right --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --expected-boot <BOOT_ID>` to turn the Duo. Read the boot and active screen pair first. This device-wide action uses the common input lock and rejects held touches. It sends one request, observes two matching selected-screen positions, and checks that the position remains after the connection closes. `--timeout` sets the observation budget (0.5...15 seconds, default 8); native reads have separate bounds. The Duo supports all four inner positions and skips upside-down portrait on the outer screen. Read the UI again before input. App layout readiness is not guaranteed. Do not replay a failed or uncertain request. An uncertain send holds the input lock and saves a recovery record. This command is separate from the two-finger `gesture rotate` and is not a batch step.

Selected gesture names also include `pinch`, `double-tap`, `rotate`, `two-finger-tap`, `two-finger-hold` and standalone `two-finger-swipe`. They require explicit geometry; use `axe gesture --help`. Their receipts confirm input delivery and cleanup, not application recognition. Verify the app effect separately.

Use `two-finger-swipe` with starts `-x/-y`, `--x2/--y2` and endpoints `--end-x/--end-y/--end-x2/--end-y2`. Keep selected logical points, shared duration/delta and existing gesture bounds. Either finger may stay still. Reject simultaneous coincident contacts, including between samples; spatial crossings at different times are allowed. Batch and agent mode reject it.

For `swipe-from-left-edge`, `swipe-from-right-edge`, `swipe-from-top-edge` and `swipe-from-bottom-edge`, `--edge-inset <points>` changes only the start distance from that edge. Use a finite positive value that leaves an inward path. The opposite endpoint stays 20 logical points from its edge. Defaults remain start inset 20, duration 0.3 seconds and delta 50. On a 951-point-wide display, left-edge inset 1 gives x=1 to x=931. Legacy and selected commands and batch steps support this option; scroll and complete multi-touch gestures reject it. Selected bounds are read fresh. With an explicit inset, legacy input also requires the remaining path span to be at least the effective delta (50 by default); choose a smaller explicit delta for a shorter path. Selected input retains its safe single-step handling for short paths. This is explicit geometry, not an automatic Back action or fallback. Inspect the visible app and verify its effect separately; do not replay a failed gesture automatically.

## Selected Home button

Use standalone `axe button home --udid <UDID> --input-mode selected --screen-id <ID> --screen-uuid <UUID>` with a fresh active-panel pair. Home acts on the whole device; the pair guards context and does not route Home to one display or app. Optional `--expected-boot <BOOT_ID>` must match exactly before the input connection opens. Omitted `--duration` means down/up with no requested hold. Explicit duration must be finite and greater than zero, up to 10 seconds; positive fractions such as `0.2` are supported.

When available, response `home` fields record execution phase, planned/sent counts, release/drain flags, interruption and cleanup release evidence. No execution evidence means no `home` result. These are transport records, not an OS held-button inventory or visible Home proof. Inspect the effect separately. Home can act before an unchanged final-pose guard reports failure; preserve that failure and do not replay it automatically.

Selected batches also accept `button home` through the same request and guards. Selected Home options in a legacy batch still reject before conversion. Legacy Home behavior is unchanged; the other selected device buttons are described below.

## Selected device buttons

Use `axe button <side-button|siri|lock|apple-pay> --udid <UDID> --input-mode selected --screen-id <ID> --screen-uuid <UUID>`. The fresh active pair guards context; buttons act on the whole device. Optional `--expected-boot` must match before input. Omitted duration has no requested hold; explicit duration is finite, greater than zero and at most 10 seconds.

Typed `button.kind` and execution/cleanup evidence confirm transport only. Siri, Lock and side-button use two primitives. Apple Pay uses the existing native two-side-press adaptation: four primitives, a 0.15-second gap, and half the supplied duration per hold. Home keeps its `home` result. No receipt proves Siri, payment UI, secure lock, wake or power state. Final context failure can follow an effect; never replay uncertain input or use a fallback button.

Selected batch steps use the same names, guards and exact count/release checks. Raw routes stay unchanged. Selected requests use a separate broker endpoint; older requests reject. Receipts do not prove Siri or Wallet UI.

## Selected batch steps

Set the UDID, input mode and screen pair at batch level. Put the current app PID and keyboard focus ID on each step that needs them. Selector taps keep the normal IDB accessibility-readiness check; slider endpoints keep native semantic control and keyboard steps keep their existing focus checks:

```bash
axe batch --udid <UDID> --input-mode selected --screen-id <ID> --screen-uuid <UUID> \
  --step 'tap --id <ID> --expected-pid <PID>' \
  --step 'type --expected-pid <PID> --focus-id <FIELD_ID> -- hello'
```

ID/label/value tap steps accept `--element-type` through the same builder and final target checks as standalone selected tap. The field must already have focus before the type step. Each input step resolves its current context and target. Supported steps are complete taps, slider endpoints, swipes, drags, gestures, touch down/up pairs, literal/file/stdin text, keys, key sequences, key combinations and `button home|side-button|siri|lock|apple-pay`. Batch does not support `gesture two-finger-swipe`, `tap --semantic-press` or retained-token chains.

Selected batch `type --stdin` reads the process standard input once at that ordered step, before sending its keyboard request. Supply the step list with batch `--step` or `--file`, then pipe the text to AXe and close the pipe. The text must contain 1–256 UTF-8 bytes and use the existing US keyboard mapping; bytes and newlines are not trimmed or truncated. The synchronous read waits for EOF, has no deadline and cannot observe task cancellation while blocked. AXe checks task cancellation again after the read and before send. The normal current PID, focus and per-key checks still apply. Invalid or empty input stops later steps; earlier effects remain and input is not replayed. Batch-level `--stdin` consumes the same stream as the step list first, so a nested `type --stdin` sees EOF and rejects empty text. A second stdin text step also sees EOF after the first successful read; there is no separate text stream.

Selected batch `drag` accepts `--start-x`, `--start-y`, `--end-x`, `--end-y`, `--duration`, `--steps`, `--pre-delay` and `--post-delay`. Defaults match standalone selected drag: 0.6-second movement and 60 steps. Use fresh oriented logical coordinates; the owner checks the complete path against current selected bounds before input. Drag does not accept selectors or `--expected-pid` and does not prove the recipient app. Verify the real app effect separately. Legacy batch drag remains unsupported.

Selected batch `slider` requires exactly one `--id` or `--label`, `--endpoint minimum|maximum` and positive `--expected-pid`. The screen pair comes from the batch. The step uses native semantic control and sends zero HID events. A clean `endpointObserved` receipt confirms endpoint value readback; `alreadyAtEndpoint` completes without a new action. Do not treat these as touch-release receipts or app callback proof. Optional `--element-type` uses the standalone builder and native checks. Filtered completion requires matching bounded native type evidence for the recorded samples and actions. Label steps use the same trimmed, case-sensitive matching and duplicate-before-type checks as standalone selected slider, including targets without an ID. Percentage `--value` and non-default wait/poll options are rejected. Legacy batch slider remains unsupported. A failure can follow a semantic action; retain the receipt and do not replay it.

For selected batch `button home`, use the same request, boot/duration rules and typed completion evidence as [Selected Home button](#selected-home-button). Use a matched CLI and broker. The batch supplies the active screen pair. Keep per-step options on the step. Stop later steps after failure; never replay uncertain input.

Selected `sleep <seconds>` waits on the host with no input lease or broker request. It accepts every finite non-negative Double duration, including zero, with no total cap. AXe measures monotonic elapsed time and uses bounded cancellable waits; this is not a readiness or exact timing guarantee. The JSON step receipt has a `hostWait` object with `requestedSeconds`, `elapsedSeconds`, `outcome` and an error when present; request ID and broker response are absent. A completed wait has status `completed`; interruption or wait-owner failure has `waitInterrupted` or `waitFailed` and stops later steps. SIGINT/SIGTERM handling applies only during the wait, cancels and awaits the owned wait task, then restores prior signal dispositions. This is not whole-batch signal handling or an atomic signal-boundary guarantee. Output failure also stops the batch. The next input step uses its normal fresh context/target/focus guards; sleep does not preserve or prove device state, reserve the device or inspect other processes' held input.

Each attempted step prints one JSON line with its index, request ID, status and full response when available. Failure stops later steps; earlier effects remain. No input is replayed. Non-default legacy cache, chunk, batch-level tap-style and batch-level polling settings, plus continue-on-error, are rejected; per-step ordinary tap supports `--tap-style` values `physical`, `simulator` and `automatic`. Explicit batch-level `--tap-style automatic` has the same effect as omission and does not change selected step style; a step without its own style keeps the physical 0.1-second hold. There is no whole-batch lease or automatic transition wait. Use separate commands when the next step needs a fresh inspection. Put selected polling on the tap step, for example `--step 'tap --id ready --expected-pid <PID> --wait-timeout 5'`. A closed client connection cancels an active tap wait; this does not add whole-batch signal handling or undo sent input.

## Selected PNG screenshots

For the measured active panel, use the exact ID/UUID pair from a fresh `list-simulators --displays` read:

```bash
axe screenshot --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --output selected.png
# Optional boot check; use the identity from hinge read
axe screenshot --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --expected-boot <BOOT_ID> --output selected-boot.png
```

Both screen options are required. Do not add `--input-mode` or `--expected-pid` to this command. An inactive panel, invalid selection or changed context fails without display or legacy fallback. Existing output files are not replaced.

Success writes a PNG and prints a JSON receipt with the output path, dimensions, before/after context and capture child receipt. Surface identity and frame presentation time are unavailable. The context checks bound capture; they do not prove an atomic frame/context observation. Without the screen pair, legacy capture and path-only stdout stay unchanged.

For selected capture, `SIGINT` and `SIGTERM` request cancellation. AXe waits for the operation to return, including its cleanup path. Cancellation accepted before output publication produces no PNG. A late signal can arrive after publication. Unconfirmed cleanup remains an error; this does not guarantee cleanup after parent termination or `SIGKILL`.

## Selected video recording

Use the paired `--screen-id`/`--screen-uuid` options for a fixed panel, or `--follow-active-display` for a fixed-canvas movie that follows measured display changes on one boot. Do not combine these modes. Read the [recording contract](recording-reference.md) for options, bounded transition recovery, stop/publication rules and limits.

## Selected video streams

Use `axe stream-video --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --format raw` with the pair from a fresh measured active-panel read. `--expected-boot <BOOT_ID>` is optional. Do not add `--input-mode` or `--expected-pid`.

Keep stdout for stream bytes only and capture stderr separately. It carries dimensions, layout, frame counts and the final summary. Use the decoder for the chosen format:

- `raw`: four-byte unsigned big-endian JPEG length, then exactly that JPEG.
- `ffmpeg`: concatenated standalone JPEG images; no ffmpeg process is started.
- `mjpeg`: boundary `mjpegstream` is declared without delimiter hyphens; parts use `--mjpegstream`, Content-Length and JPEG bytes. Normal completion includes the closing delimiter.
- `bgra`: packed top-to-bottom BGRA with premultiplied alpha, no row padding, `width * 4` row bytes and `width * height * 4` frame bytes. Use stderr dimensions. Quality does not change raw BGRA.

Scaling uses upright PNG dimensions rounded down to at least one pixel. Every frame must keep the initial boot, panel, geometry, scale, orientation and hinge pose. A context or capture failure stops without retargeting or retry. The lease covers each capture only. FPS is a requested maximum; achieved FPS uses host output times, not display presentation times. Surface identity and atomic frame/context proof are unavailable. Do not claim continuous rotation or fold coverage.

Stop normally with SIGINT or SIGTERM and await the actual exit. Capture cleanup is awaited. A started packet must finish within its existing five-second output deadline or fail; successful MJPEG also needs its closing delimiter. Errors or task cancellation can leave partial bytes. Preserve them as incomplete; never retry by appending. A summary alone is not success if final exit or cleanup fails. The deadline bounds userspace backpressure waits, not all native/kernel calls or encoding. Parent termination and SIGKILL cleanup are not guaranteed. Legacy streaming without the screen pair stays unchanged.

## Ordinary Duo batch

Ordinary Duo batch owns one fixed measured display/session and common lease through all steps and host waits. Keep logical points, existing type chunks/styles and normal output. Context/native failure or cancellation stops later input without replay, even with `--continue-on-error`; pre-input errors can continue only in the same valid session. Remaining input closes at batch end and never transfers to standalone commands. Step stdin is cancellable without an EOF deadline; initial batch stdin loads before ownership. A typed orphan touch-up sends no input; other unmatched releases reject. Preserve modifier order; native parts allow one touch, with no two-finger or pose events. Use matched artifacts and verify the real app effect.

## Selected-screen tap waiting

Put `--wait-timeout` and optional `--poll-interval` inside an ordinary selected ID, label or value tap step. Use the active batch screen pair and a positive expected PID. The timeout must be greater than zero through 30 seconds. The interval is 0.05–30 seconds (default 0.25); a non-default interval needs a positive wait. Batch-level polling is rejected. Only an absent match retries. Cancellation, changed device state or any other failure stops later steps without replay.

```sh
axe batch --input-mode selected --screen-id <ID> --screen-uuid <UUID> --udid <UDID> \
  --step 'tap --id ready --expected-pid <PID> --wait-timeout 5' \
  --step 'tap --id continue --expected-pid <PID>'
```
