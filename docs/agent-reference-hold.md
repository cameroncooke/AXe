# Press and hold an agent reference

Status: integrated in main 9a2d07ec, 22 October 2026. The seven production files match tested candidate af6bb00b. The isolated arm64 build and 95 existing checks passed.

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

## Recorded verification

The default reference press caused one Button callback and a complete released contact. A 0.7-second reference hold on Text entry produced a measured 0.707-second contact and fresh Select/Select All accessibility controls. The text stayed unchanged. The native edit controls were GenericElement/StaticText nodes, not Buttons. The full normal driver run remains FAIL because it expected the wrong roles; its valid subchecks are accepted separately. No after-hold screenshot was saved, so visual menu verification remains open.

Normal Device Hub folding during a ten-second requested hold stopped input after about 6.79 seconds and released the original contact. AXe then read two matching fresh outer-screen trees and tapped the newly found Button once. The complete fold-v7 run and cleanup passed. Earlier failed setup and timing attempts remain unchanged.

Wrong PID, stale references, coordinates mixed with references, retained tokens, partial touches, invalid delays and agent batch input rejected without app input in the saved subchecks. Existing raw and selected coordinate touches and a fresh agent tap passed. The batch rejection message was generic; a separate fix addresses its wording.

[Scoped acceptance](/Volumes/Developer/AXe/build_products/verification/agent-reference-hold-20261022/scoped-acceptance.json) records exact candidate/runtime hashes, commands, effects, guard results and limits. Other target roles, positions and interruption cases remain open. No combined main build or full-tool claim is made.

Security scanning remains UNVERIFIED at Cam's request. Guide checks are recorded separately in the source handoff.
