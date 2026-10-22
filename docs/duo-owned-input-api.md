# Native owned input and ordinary Duo touch

This document describes the isolated touch candidate. The matched native/CLI build and 173 existing checks passed. Ordinary-iPhone portrait complete touch and separate down/move/up passed with real app effects and released contacts. Duo verification remains pending after a PosterBoard crash before candidate input. This is not main integration or full native acceptance. Use matched AXe and FBSimulatorControl artifacts; the new public Swift API and selected wire are not compatible with an older framework or broker.

## Native session contract

`FBSimulatorHIDSession.submitOwnedPart(_:)` accepts one part of an owned logical-coordinate input stream and returns `FBSimulatorHIDSessionReceipt`. Open the session with its measured `FBSimulatorHIDSessionObservation` and a live freshness provider. The session owns one fixed display context and DTUHID connection.

- Supply logical UI points from the current layout. The existing transport applies the measured rotation and display transform once. Do not pre-rotate these points.
- A first single-touch down starts a contact. A later down moves that contact. A matched up ends at the coordinate supplied in that event; it does not insert a move first.
- Validate the entire part before dispatch. Every up must match input already held by this session or begun earlier in the same part. An unmatched touch, key or button release rejects before normal dispatch. Repeated releases after the input was released also reject.
- Retain single-contact, key and button state across successful parts. Owned parts reject two-finger events. The current ordinary CLI adapter uses only single touch; this API does not establish batch, key or button behavior proof.
- Require finite in-bounds points and finite non-negative representable delays. No new implicit coordinate conversion or app-layout recovery is added.
- Do not enter owned-part mode with an explicit retained token. After the first owned part, complete `execute` and explicit retained-contact creation reject on that session, even after all input is released. Close it before changing input modes.

A successful part returns `retained` while input remains held, or `enqueuedAndDrained` after release. The session state is `retainedInputs` for held owned-part input. No explicit contact token is returned. `status().hasRetainedContact` describes touch state only; it is not a key/button inventory or an independent OS input-state read.

The session checks the original context before and during input, at delays, and after drain. Its local feed also checks context while owned input is idle. Invalidation, cancellation and execution failure use the existing cleanup owner on the original connection, then prevent reuse. An invalid later part also closes the stream and releases any input already owned; it does not dispatch the invalid part. Keep uncertain cleanup as an error and do not replay input.

Call and await `close()` when finished. Cancel and await an active caller action before closing it; concurrent caller execution rejects as busy. The native session has no 60-second idle expiry. The timeout below belongs to the CLI broker.

## Ordinary Duo touch adapter

Only the verified Duo profile takes this new route when no input-mode flag is supplied. Other devices keep their prior touch route. The existing flags, logical coordinate interface and normal text output remain. The adapter does not expose an implicit token.

| Ordinary command | Effect |
| --- | --- |
| `touch -x X -y Y --down` with no contact | BEGIN at the supplied point |
| Another `--down` with a contact held | MOVE the same contact to the supplied point |
| `--up` with a contact held | END at the supplied point, with no added MOVE |
| `--down --up` | Down at the supplied point, hold, then up at that point; a previously held contact is moved and ended |
| `--up` with no owned contact | Zero HID events; internal outcome `noOwnedContact` |

The complete pair keeps its default 0.1-second hold. Optional `--delay` must be finite and in 0...10 seconds, and is valid only with both flags. Zero adds no delay. Touch has no new pre/post-delay option.

A successful down survives normal command exit. The broker retains the original session and common input lease for up to 60 seconds without an accepted touch request. Folding, rotation, changed context or expiry releases the original owned input. No old stream is transferred to a replacement display. Client loss during an active submission cancels that part and waits for cleanup; this differs from normal client exit after a successful retained down. Parent termination and SIGKILL cleanup are not guaranteed.

An orphan up still validates a canonical current Duo context, but sends no input. It cannot release an explicit selected contact or send END on a replacement display after invalidation. Explicit selected input cannot take an implicit ordinary contact. Selected retained input keeps its existing explicit token, end-at-last-held-point behavior and 30-second broker idle limit.

The adapter does not add app/PID checks, wait for layout readiness, resolve a new accessibility target or make context and input atomic. Read the UI again after a layout or pose change. Equal sampled contexts cannot exclude a full out-and-back change between reads. Verify the actual app effect separately.

## Wire and scope

Selected wire 26 rejects wire 25 and older requests. The internal `legacyTouch` payload requires one complete envelope with empty primitives, no token, a measured `expectedContext` and no other payload. The owner requires the canonical verified Duo profile before it creates the live feed or native session. Continuations must match the original measured context and ownership.

The touch checkpoint adds no CLI option, agent command or batch path. The separate [ordinary Duo batch candidate](duo-batch-owned-input.md) uses one fixed in-process owner and the additive `submitLegacyBatchPart(_:)` API. That candidate is source preparation only; its build and native proof remain pending. It does not change selected wire 26 or relax `submitOwnedPart(_:)` release validation.
