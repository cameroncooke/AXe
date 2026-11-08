# Video recording modes

## Output format and destination paths

Keep the format before the command; keep the file path after it:

```bash
axe --output json record-video --udid <UDID> --output recording.mp4
axe --output json screenshot --udid <UDID> --output screenshot.png
```

The root `--output text|json` selects the command result format. `record-video --output` and `screenshot --output` retain their existing destination-path meaning. Normal output is unchanged when no format is selected. Explicit format selection for `stream-video` is rejected before capture; stream bytes remain on stdout only in its existing no-format mode. Read [output fields](agent-reference.md#output-format) for JSON success and error results.

For one fixed measured panel:

```bash
axe record-video --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --expected-boot <BOOT_ID> --output selected.mp4
```

Both screen options are required; the boot check is optional. Every frame must match the first frame's boot, screen identity, orientation, hinge pose and geometry. A context change or capture error fails without retargeting or stale-frame continuation.

To follow the active panel through folding and rotation:

```bash
axe record-video --udid <UDID> --follow-active-display --expected-boot <BOOT_ID> --output active.mp4
```

This explicit mode rejects either screen option. The boot check is optional before the first accepted frame; every later frame must keep that first frame's boot. Each frame discovers the measured active ID/UUID under the common lease and uses unchanged before/after context checks. Only complete validated frames enter the movie. A new panel or orientation can be accepted between frames.

The first accepted frame determines the even video dimensions after --scale (0.1...1.0, default 1.0). Upright frames fit without stretching or cropping; black bars fill unused space. Native PNG pixels are already upright. The encoder keeps one fixed canvas and one timeline. It does not encode every transition animation or rotate pixels again. A player can hold the previous frame across a capture gap.

Only typed lock-busy or context-transition errors can start a fresh read-only attempt. Recovery reads again after each 250ms wait and starts no further attempt after a 30-second window from the frame's first failure; the waits hold no input lease. Each native operation keeps its existing timeout and cleanup bounds, so an in-flight operation can finish after that window. Boot changes, quarantine, uncertain cleanup, generic unavailable errors, malformed frames and writer errors remain fatal. There is no input replay or alternate capture backend. Logs preserve each recovered error. A separate input command may still meet a busy lease during a capture.

Do not add --agent, --input-mode or --expected-pid. --fps is 1...30 (default 10) and --quality is 1...100 (default 80). FPS is a requested maximum, not a guaranteed rate. Surface identity and native frame presentation time are unavailable; timestamps use monotonic host acceptance time. Follow-active JSON includes observedContextChanges, maximumFrameGapSeconds, recoveryAttempts and recoveryWaitSeconds. These are observations, not a count of all physical transitions or proof of smooth animation.

SIGINT and SIGTERM request a normal stop: cancel and await capture, finish validated frames, then publish a completed MP4 and JSON receipt. Existing destinations are never replaced. A stop before the first accepted frame, task cancellation or uncertain cleanup produces no successful output. Late signals can arrive after publication; parent termination and SIGKILL cleanup are not guaranteed. Input between frames is possible. Without a selected pair or --follow-active-display, legacy recording and path-only output stay unchanged.

Follow-active recording is low-rate capture: it does not provide smooth animation or cover every pose or rate. Fixed-screen recording and streaming keep their existing scope.
