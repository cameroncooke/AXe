# Ordinary Duo batch input

Status: source fix candidate, 22 October 2026. The earlier matched batch build passed tap and retained-touch checks, but one-event typing chunks caused repeated characters. The boundary-check fix below has not been built or run in a simulator. It is not accepted for main integration. Use matched AXe and FBSimulatorControl artifacts after verification.

The ordinary no-flag `batch` command uses one measured Duo display, native session and common input lease for its whole ordered run. Other devices keep the prior batch route. Selected batch and agent command behavior are unchanged. No CLI option or wire change is added.

The batch keeps its existing parser, command list, normal text output, raw selectors, tap styles, cache/poll settings, type sources and chunk sizes, key sequences/chords, delays and event factories. It sends logical coordinates to the measured transport once. Preset dimensions keep their existing defaults and explicit options. Duo swipe/preset expansion has the existing 100000-movement allocation limit; selected event, text and duration limits do not apply.

## Ownership and failure

- Touch state and keyboard modifiers can span successful parts and typing chunks. A later touch down moves the same contact. A matched up ends at its supplied logical point with no added move.
- An ordinary `touch --up` step has an explicit no-contact rule: validate its point/context, then send zero input if this batch has no contact. That rule belongs to the typed step. It does not change generic/composite native part validation.
- The fixed context is checked before step conversion, before input, during native input and in host waits. A changed hinge, rotation, screen, boot or failed native session stops later input without replay or a new session. Read the UI again in a new command. Equal sampled contexts cannot exclude a complete out-and-back change between reads.
- `--continue-on-error` can continue after a parse, lookup or other pre-input step failure while the same session is valid. Such an error does not release input retained by an earlier step. An invalid native session, cancellation or uncertain cleanup always stops the batch.
- Normal completion and failure close owned input, including a final down without an up. No contact transfers to a later standalone command. Uncertain cleanup attempts to save the existing input quarantine and reports persistence failure explicitly. There is no automatic recovery or input replay.

The lease remains held through host sleeps, AX lookup, type input and final cleanup. Host waits use the existing local feed; they add no HID input or full AX scan. SIGINT/SIGTERM cancel and await the batch operation before close and signal restoration. The Duo step stdin reader waits without an EOF deadline, checks cancellation/context, and preserves the existing line-join behavior. Initial batch `--stdin` still loads before ownership. SIGKILL cleanup is not guaranteed.

Accessibility cache policies remain available. They do not prove current app layout when the pose is unchanged, and this route adds no PID/focus policy to the stateless ordinary interface. Check the real app effect separately.

## Native batch part API

`FBSimulatorHIDSession.submitLegacyBatchPart(_:)` uses the fixed live context, transport, owned input state, drain and cleanup of `submitOwnedPart(_:)`. Its first part performs a full context read. Every primitive, delay and later part uses the continuous native feed, including after drain. This avoids full guest helper reads between key down and key up or during a physical tap hold. Strict owned parts and complete input keep their existing full-read boundaries.

Call `validateLegacyBatchBoundary()` after command conversion and before its first part, then once at normal batch completion. When no touch, key or button is held, it reads and compares the full context. When input is held across steps, it uses the live feed without extending that hold with guest helper work. A failed check invalidates the fixed session and releases owned input. The feed and idle monitor remain active throughout. Only one stream mode can be used in a session. Close it before changing between strict owned parts, legacy batch parts, complete input or explicit retained contacts.

The batch API preserves duplicate modifier codes and a target key that also appears among modifiers. It does not deduplicate or reorder events. Per-part keyboard down credits must cover every up, and extra repeated-down credits must be consumed within that same part. Only actual held key state can continue to another part. Cleanup tracks the existing actual held set, so it releases each still-held key once.

Fresh/extra touch and button ups still reject. A keyboard up with no held/earlier matching down credit rejects. The strict `submitOwnedPart(_:)` API still rejects a second up after release. There is no two-finger, pose or system-state event support in owned batch parts. Existing DTUHID keyboard pacing and Apple Pay adaptation occur once inside native submission.

Native/API receipts show library state and transport progress. They do not prove app behavior or an independent OS key/button inventory. Build, modifier ordering, release, interruption, stdin cancellation and real UI results require the separate guarded native checks before acceptance.
