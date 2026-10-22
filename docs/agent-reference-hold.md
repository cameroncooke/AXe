# Press and hold an agent reference

Status: source candidate, 22 October 2026. Build and native verification are pending.

Use a complete touch when an agent needs to press a named control or keep a finger down on it. Read a fresh snapshot, then pass that snapshot and reference:

~~~sh
axe describe-ui --agent --udid "$UDID" --expected-pid "$APP_PID"
axe touch --agent --udid "$UDID" --expected-pid "$APP_PID" \
  --snapshot-id "$SNAPSHOT_ID" --ref "$REF" --down --up --delay 0.7
~~~

Omitted delay is 0.1 seconds. An explicit delay must be finite and greater than zero through 10 seconds. The delay requests a physical contact duration. The app decides which action follows. A long delay alone does not prove that the app accepted a long press.

The reference must identify a visible, enabled control with a unique native ID or label. The broker checks the saved snapshot against a fresh tree, resolves the native target again, and uses its current activation point. The existing selected tap operation checks native identity, point hit and the current app/display before touch down. The existing input session detects folding, rotation and other measured context changes, releases its touch and stops further input. It does not promise detection of every app-only layout change during a hold.

The command invalidates old cache state before input. Success can include a fresh replacement snapshot. If refresh fails after a completed action, read again; do not repeat the action. Uncertain input is never replayed.

This option rejects coordinates, one-sided down/up, retained contact tokens, explicit AX preparation and batch use. It does not expose new pad or slider references. Existing no-flag and explicit selected coordinate touch behavior, including a zero delay, is unchanged. Older brokers reject the new hold action kind instead of treating it as an ordinary tap.

## Verification to complete

Use the existing UIKit control sample and normal app input. Do not inject sample state.

- Find the current Button reference. A default complete reference touch must cause exactly one button callback, touch down/up and no held contact.
- Focus the existing Text entry field, enter text, dismiss any edit menu, and capture again. Hold its current reference for 0.7 seconds. Require the native text-edit menu in fresh accessibility and image output, with contact release. Text content must stay unchanged. The Gesture pad is not assumed to be an available reference.
- After a real UI change, an old snapshot/ref must reject with no input and no app change. A new capture must allow input again.
- During a longer reference hold, use Device Hub's normal Fold control after real touch down. Require cancellation and release, no later input at the old point, then a fresh reference tap on the active panel with one callback.
- Check wrong PID, mixed coordinates, a retained token, a partial touch, invalid delay and agent batch use. Each must reject before input.
- Check one ordinary coordinate touch and one ordinary selected coordinate touch for compatibility.

Use one owned simulator at a time with the existing CPU/memory monitor. Record the exact CLI and native framework hashes, commands, effects and cleanup. Existing tests may be run; no new suite is part of this change.

Security scanning remains UNVERIFIED at Cam's request. Guide checks are recorded separately in the source handoff.
