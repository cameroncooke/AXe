# Video recording modes

## Output format and destination paths

```bash
axe --output json record-video --udid <UDID> --output recording.mp4
axe --output json screenshot --udid <UDID> --output screenshot.png
```

- Root `--output text|json` goes before the command and selects the result format; `--output` after `record-video` or `screenshot` stays the destination path.
- No format: normal output, unchanged.
- `stream-video` rejects explicit format selection before capture; its stream bytes go to stdout only without a format.
- JSON results: [output fields](agent-reference.md#output-format).

## Fixed screen

```bash
axe record-video --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --output selected.mp4
```

- One fixed measured panel: the active screen's `id` and `uuid` from `axe displays`. Both are required.
- Every frame must match the first frame's boot, screen identity, orientation, hinge pose and geometry.
- A context change or capture error fails it: no retargeting, no stale-frame continuation.

## Follow the active display

```bash
axe record-video --udid <UDID> --follow-active-display --output active.mp4
```

- Follows the active panel through folds and rotation. Rejects either screen option.
- Every later frame must keep the first accepted frame's boot. Test suites can also pin it with hidden `--expected-boot`: [device-reference.md](device-reference.md#automation-and-testing).
- Each frame discovers the measured active ID/UUID under the common lease, with unchanged before/after context checks.
- Only complete validated frames enter the movie. A new panel or orientation can be accepted between frames.
- Low-rate capture: no smooth animation; does not cover every pose or rate. Fixed-screen recording and streaming keep their existing scope.

## Video canvas

- The first accepted frame sets the even video dimensions after `--scale`.
- Upright frames fit without stretching or cropping; black bars fill unused space. Native PNG pixels are already upright.
- One fixed canvas, one timeline. Not every transition animation is encoded; pixels are not rotated again.
- A player can hold the previous frame across a capture gap.

## Transition recovery

- Only typed lock-busy or context-transition errors start a fresh read-only attempt.
- It reads again after each 250ms wait; no new attempt starts 30 s after the frame's first failure. Waits hold no input lease.
- Native operations keep their own timeout and cleanup bounds, so one in flight can finish after that window.
- Fatal: boot change, quarantine, uncertain cleanup, generic unavailable errors, malformed frames, writer errors.
- No input replay or alternate capture backend. Logs keep each recovered error.
- A separate input command can still meet a busy lease during capture.

## Options and limits

| Option | Range | Default |
|---|---|---|
| `--fps` | 1...30, a requested maximum, not a guaranteed rate | 10 |
| `--quality` | 1...100 | 80 |
| `--scale` | 0.1...1.0 | 1.0 |

- Never add `--agent`, `--input-mode` or `--expected-pid`.
- Surface identity and native frame presentation time are unavailable; timestamps are monotonic host acceptance time.
- Follow-active JSON has `observedContextChanges`, `maximumFrameGapSeconds`, `recoveryAttempts`, `recoveryWaitSeconds`: observations, not a count of all physical transitions or proof of smooth animation.

## Stop and publication

- SIGINT or SIGTERM stops normally: cancel and await capture, finish validated frames, publish a completed MP4, print its path. `--verbose` prints the receipt with context reads, frame gaps and recovery waits.
- Never replaces an existing destination.
- No successful output after a stop before the first accepted frame, task cancellation or uncertain cleanup.
- Late signals can arrive after publication. Parent termination and SIGKILL cleanup are not guaranteed.
- Input between frames is possible.
- Without a selected pair or `--follow-active-display`, legacy recording and path-only output are unchanged.
