# Selected two-finger straight paths

This source candidate adds one complete selected gesture. Build and native acceptance are pending.

## CLI

Use a fresh selected display ID and UUID. Coordinates are current logical display points:

```bash
axe gesture two-finger-swipe --udid "$UDID" --input-mode selected \
  --screen-id "$SCREEN_ID" --screen-uuid "$SCREEN_UUID" \
  -x 200 -y 300 --end-x 240 --end-y 380 \
  --x2 400 --y2 300 --end-x2 360 --end-y2 420 \
  --duration 0.6 --delta 5
```

Both contacts begin together, follow independent straight paths on one timeline and release together. Either path may remain stationary. Finger order stays fixed throughout the event. Simultaneous coincident logical positions reject before event construction, including collisions between samples. Spatial crossings at different times remain allowed. Relative differences and products must remain finite; native preflight still checks display bounds. This is not a curved path, retained-contact operation or recognition guarantee. Batch steps and agent mode do not support this new gesture. Commands without selected options keep their existing behavior.

Duration is finite and in (0,10] seconds, default 0.6. Delta is finite and in (0,200] logical points, default 5. Each pre/post delay is in [0,10] seconds; duration plus delays is at most 20 seconds. The longer path determines one shared segment count, at most 500. The complete expanded gesture is limited to 1024 events. The native preflight checks every point against the fresh selected display before input. Endpoints and all start coordinates are required. Radius, scale, degrees, hold, interval, edge inset and dimension overrides reject.

The complete owner/session supplies the measured display transform once and keeps its existing boot, fold, rotation and cleanup checks. A changed context stops old-coordinate input and attempts release on the original connection. A failed or uncertain gesture is never replayed. Read the UI again before a separate recovery action. Coordinate input does not add app/PID or layout checks.

## Native API

`FBSimulatorHIDGesture.twoFingerSwipe(firstStart:firstEnd:secondStart:secondEnd:duration:spacing:)` returns the existing composite `twoFingerTouch` event shape. It uses a shared paired-motion emitter with pinch/rotation, exact linear endpoints and the existing final stationary sample. Native construction remains bounded to 4096 segments; the CLI applies the smaller 500-segment limit. All events use logical points and native session preflight. Transport, contact tracking, cancellation and cleanup are unchanged.

Selected wire 27 rejects wire 26 and older requests. The new associated gesture payload cannot mix with primitives, other gesture payloads or retained tokens. The native source change is exported through the complete tracked Duo foundation patch and postimage manifest; build AXe against that matched library.

## Verification limit

No build or simulator input has run against this candidate. Required native proof is one asymmetric two-path action with separate contact identities and exact endpoints, one stationary-finger action, and normal fold interruption followed by complete pair release and a fresh named tap. Existing shared-session rotation evidence remains separate; no new rotation matrix is required unless a failure appears. Use the existing visible fixture, resource guard and saved contact readback. Existing gesture checks must also cover the unchanged pinch/rotation event shape. No new verification suite or hidden app route is added.
