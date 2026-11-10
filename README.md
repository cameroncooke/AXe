<img src="banner.png" alt="AXe" width="600"/>

AXe is a command-line tool that automates iOS simulators, including the dual-screen iPhone Duo, and connected iPhones and iPads. It reads the accessibility tree, sends taps, typing, gestures and hardware buttons, captures screenshots and video, and changes device settings. An agent mode gives AI agents checked, stateful control of the UI.

[![CI](https://github.com/cameroncooke/AXe/actions/workflows/release.yml/badge.svg)](https://github.com/cameroncooke/AXe/actions/workflows/release.yml)
[![Licence: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Install

```bash
brew install cameroncooke/axe/axe
axe --help
```

### AI skill

`axe init` installs the skill bundled with your AXe binary for the AI clients it detects (`--client claude|agents`, `--dest <dir>`, `--force`, `--uninstall`, `--print`). To keep the skill updated as releases ship, install it from this repository's marketplace instead, and keep the CLI on the latest release:

```bash
claude plugin marketplace add cameroncooke/AXe && claude plugin install axe@axe
codex plugin marketplace add cameroncooke/AXe && codex plugin add axe@axe
```

The marketplace reads the case-sensitive `Skills/CLI` path; clients that require a lowercase `skills/` directory are unsupported.

## Quick start

```bash
axe list-simulators                       # find a booted simulator's UDID
export UDID=<UDID>
axe describe-ui --udid "$UDID"            # accessibility tree as JSON
axe tap --label "Continue" --udid "$UDID"
axe type 'Hello world' --udid "$UDID"
axe screenshot --udid "$UDID" --output screen.png
```

Every command needs an explicit `--udid`; AXe never picks a device for you. Coordinates are logical points in the current orientation, the units `axe displays` reports, not screenshot pixels. Run `axe <command> --help` for every option.

## Output and errors

Without `--output`, commands print text:

- Commands that read or change state print that state in a few lines (`displays`, `settings`, `hinge`, `rotate`, `doctor`, `shutdown`, `clipboard copy`).
- Input commands print nothing on success, except `tap`, `slider` and `batch`, which print a `✓ … completed successfully` line.
- `screenshot` and `record-video` print the file path.
- A failure prints `Error: <message>` to stderr and exits nonzero.

Put `--output json` before the command for one `axe.output.command-result` object on stdout:

```
$ axe --output json screenshot --udid "$UDID" --output shot.png
{"command":"screenshot","data":{"result":{"path":"/…/shot.png","pixelHeight":2868,"pixelWidth":1320}},"didError":false,"nextSteps":[],"schema":"axe.output.command-result","schemaVersion":"1"}

$ axe --output json tap --id no-such-element --udid "$UDID"
{"command":"tap","data":{},"didError":true,"error":{"code":"elementNotFound","message":"No accessibility element matched --id 'no-such-element'. …"},"nextSteps":[],"schema":"axe.output.command-result","schemaVersion":"1"}
```

`command` is the full command path, such as `settings status-bar set`. `data.result` is the command's typed result. `error` is present exactly when `didError` is true. Input commands return `{outcome: "completed"}`; media commands return `{path, pixelWidth, pixelHeight, frames?}`. Branch on `error.code`, not on messages or `nextSteps`, whose wording can change. A failure never repeats input. After `screenshot` and `record-video`, `--output` is still the file path; `stream-video` refuses an output format. SIGINT or SIGTERM exits with 128 + the signal.

`--verbose` prints the full receipt (context reads, target checks, cleanup evidence) where AXe owns the input or capture. It only adds detail: the exit status and the error code are the same with and without it.

Simulators and physical devices share one error vocabulary. The codes that matter most:

| Code | Meaning |
|---|---|
| `invalidArguments` | Options or values are wrong, including characters `type` cannot send; nothing was sent |
| `targetNotFound`, `notBooted` | No simulator or device has the UDID, or the simulator is shut down |
| `busy`, `timeout`, `interrupted` | Another AXe command holds the device, a deadline passed, or a signal stopped the command |
| `elementNotFound`, `ambiguousElement`, `elementNotHittable` | A selector matched nothing, several elements, or an element without a usable frame |
| `rejectedBeforeInput`, `inputFailed`, `inputUnavailable` | Input was refused before sending, stopped after some input, or AXe could not reach the input service |
| `cleanupUncertain`, `quarantined` | A touch or key may still be held; input stays blocked until you check the device |
| `screenChanged`, `screensDidNotSettle`, `bootChanged` | The screen or boot changed under the command |
| `captureFailed`, `outputFailed`, `readFailed`, `xcodeUnavailable` | Capture, output file, a state read, or the selected Xcode failed |
| `actionOutcomeUnknown` | A shutdown or clipboard copy may have happened but could not be confirmed |
| `unsupportedOnDevice`, `settingUnsupported` | The target does not offer this command or setting |
| `commandFailed` | Anything else |

Feature-specific codes are listed in their sections. JSON Schema (2020-12) files are in [schemas/](schemas/): the [command result envelope](schemas/axe.output.command-result.v1.schema.json), [each command's `data.result`](schemas/axe.output.command-payloads.v1.schema.json) (in `$defs`, keyed by the full command path), and the agent result [version 1](schemas/axe.output.agent-result.v1.schema.json) (`--view full`) and [version 2](schemas/axe.output.agent-result.v2.schema.json). Receipts printed by `--verbose` are not described. Ignore fields you do not know; AXe can add them within a schema version.

## Reading the UI

```bash
axe describe-ui --udid "$UDID"                 # the whole tree as JSON
axe describe-ui --point 200,400 --udid "$UDID" # the element at one point
```

For agents, `describe-ui --agent` returns compact rows with refs instead; see [Agent mode](#agent-mode).

## Taps, typing and keys

```bash
axe tap -x 200 -y 400 --udid "$UDID"
axe tap --id SaveButton --element-type Button --udid "$UDID"
axe tap --label "Done" --wait-timeout 5 --udid "$UDID"   # poll until it appears
axe type 'Hello' --udid "$UDID"
printf 'line one\nline two' | axe type --stdin --udid "$UDID"
axe key 40 --udid "$UDID"                                 # Return
axe key-sequence --keycodes 42,42 --udid "$UDID"          # two Backspaces
axe key-combo --modifiers 227 --key 4 --udid "$UDID"      # Cmd+A
axe button home --udid "$UDID"
axe touch -x 100 -y 200 --down --up --delay 1.0 --udid "$UDID"   # long press
axe slider --id volume --value 75 --udid "$UDID"
```

`tap` selectors are `--id`, `--label` or `--value`, optionally narrowed with `--element-type`. `--tap-style` chooses `automatic` (the default: a touch for switches, a simulator tap otherwise), `simulator` or `physical`. `type` uses the US keyboard layout; characters outside it, such as `é` or `£`, fail with `invalidArguments` before anything is typed. Keys take HID usage codes. Buttons are `home`, `lock`, `side-button`, `siri` and `apple-pay`.

## Swipes, gestures and drawing

```bash
axe swipe --start-x 200 --start-y 600 --end-x 200 --end-y 300 --udid "$UDID"
axe gesture scroll-up --udid "$UDID"
axe gesture pinch --scale 2 --udid "$UDID"                          # zoom in at the screen centre
axe gesture pinch -x 200 -y 400 --radius 60 --scale 0.5 --udid "$UDID"  # zoom out
axe gesture rotate -x 200 -y 400 --radius 80 --degrees 90 --udid "$UDID"
axe draw 100,400 300,400 --udid "$UDID"                             # a line
axe draw 200,300 300,480 100,480 --close --duration 1.5 --udid "$UDID"  # a triangle
```

Presets are `scroll-up|down|left|right` and `swipe-from-left|right|top|bottom-edge` (`--edge-inset` moves the start of an edge swipe). Coordinate gestures are `pinch`, `double-tap`, `rotate`, `two-finger-tap`, `two-finger-hold` and `two-finger-swipe`; they need no mode flag. `pinch` without `-x/-y` uses the centre of the active screen, and without `--radius` starts a quarter of the screen's shorter side from it; `--scale` above 1 zooms in. On a simulator without the DTUHID touch service, coordinate gestures fail with `inputUnavailable` before input.

`draw` moves one finger down at the first of 2 to 1,000 `x,y` points, in straight lines through the rest, and up at the last; `--close` returns to the first point. The stroke takes `--duration` seconds (default 1, at most 30). A point outside the active screen fails with `invalidArguments` before input. `drag` is the two-point case with explicit move events.

None of these commands proves that the app recognised the gesture; read the screen afterwards.

## Batches

```bash
axe batch --udid "$UDID" --step "tap --id BackButton" --step "type 'hello'"
axe batch --udid "$UDID" --file steps.txt         # one step per line
```

Steps are `tap`, `swipe`, `gesture`, `draw`, `touch`, `type`, `button`, `key`, `key-sequence` and `key-combo`, plus `sleep <seconds>`. They run in order in one input session; a failure stops later steps, and earlier steps are not undone. On a simulator, `--continue-on-error` runs the remaining steps after a failed one; on the iPhone Duo it still stops after a context change or input failure. Success prints `✓ Batch completed successfully (N steps)`. Agent batches (`batch --agent`) take JSON instead; see the [batch reference](Skills/CLI/axe/references/batch-reference.md).

## Screenshots and video

```bash
axe screenshot --udid "$UDID" --output screen.png
axe record-video --udid "$UDID" --fps 15 --output recording.mp4      # Ctrl+C to stop
axe stream-video --udid "$UDID" --fps 10 --format mjpeg > stream.mjpeg
axe stream-video --udid "$UDID" --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset ultrafast output.mp4
```

`stream-video` formats are `mjpeg` (multipart JPEG), `raw` (4-byte big-endian length, then a JPEG), `ffmpeg` (concatenated JPEGs) and `bgra` (packed pixels; dimensions on stderr). On a physical device `--format h264` streams native H.264 Annex B. Stream bytes go to stdout and diagnostics to stderr; keep them separate. `--fps` is an upper limit. On the iPhone Duo, `record-video --follow-active-display` follows folds and rotations into one movie, and `--screen-id` with `--screen-uuid` captures one screen and fails if it stops being active; see the [recording reference](Skills/CLI/axe/references/recording-reference.md).

## Displays, hinge and rotation

```
$ axe displays --udid "$UDID"
iPhone 18 Pro Max  C096259C-C8FB-42E8-B2E5-8BBE4F8C5AE8

Active  main   440×956 pt @3x  portrait
        id 1   C5182A5C-ECD6-48EE-A5A9-2D7707ED1542
```

`displays` waits for a fold or rotation to finish, then shows each screen's role (`main` on a one-screen device, `outer` or `inner` on the iPhone Duo), size in points, scale and orientation, which one is active, and the Duo's hinge angle. JSON is `{udid, name, hinge?, activeScreen, otherScreens}`. Pass the active screen's `id` and `uuid` as `--screen-id` and `--screen-uuid` when a command must refuse to act on any other screen.

On the iPhone Duo:

```bash
axe hinge read --udid "$UDID"
axe hinge set tabletop --udid "$UDID"     # 0...180, or closed, tabletop, open
axe rotate left --udid "$UDID"
```

`hinge read` returns `{udid, hinge: {degrees, mechanicalDegrees, posture}}`: `degrees` is the angle iOS senses, `mechanicalDegrees` the angle `hinge set` drives, and `posture` is `closed`, `partiallyOpen` or `open`. `hinge set` sends one request, waits up to 8 seconds for the screens to settle (`--no-wait` skips this) and returns `{udid, previousDegrees, hinge, activeScreen?}`. `rotate left|right` works on the Duo and on physical devices and returns `{udid, direction, previousRotation?, activeScreen?}`; it is not the two-finger `gesture rotate`. Read the UI again after any of them. Failures: `noHinge` (one-screen simulator), `bootChanged`, `hingeUnavailable`, `screensDidNotSettle`, `rotationFailed`, plus the common codes. Duo-specific input, selected-screen input and capture are in the [device reference](Skills/CLI/axe/references/device-reference.md).

## Settings

`axe settings` changes device-wide settings on a booted simulator or a connected iPhone or iPad, through `xcrun devicectl` (Xcode 27 or later).

```
$ axe settings show --udid "$UDID"
Appearance            light
Text size             large
Increase Contrast     off
Reduce Motion         off
Reduce Transparency   off
Show Borders          off
Liquid Glass          opacity 0.5
Colour filter         off
VoiceOver             off
```

```bash
axe settings set --udid "$UDID" --appearance dark --text-size accessibility-large
axe settings set --udid "$UDID" --color-filter grayscale --reduce-motion on
axe settings location set --latitude 37.7749 --longitude -122.4194 --udid "$UDID"
axe settings location scenarios --udid "$UDID"
axe settings location scenario "City Run" --udid "$UDID"
axe settings location clear --udid "$UDID"
axe settings status-bar preset screenshot --udid "$UDID"   # also low-battery, no-service, charging
axe settings status-bar set --udid "$UDID" --time 9:41 --wifi-bars 3 --battery-level 100 --battery-state charged
axe settings status-bar clear --udid "$UDID"
```

`set` accepts `--appearance`, `--text-size`, `--increase-contrast`, `--reduce-motion`, `--reduce-transparency`, `--show-borders`, `--liquid-glass`, `--liquid-glass-opacity`, `--color-filter`, `--color-filter-intensity` and `--voiceover`. It validates every value before changing anything and prints the result as `show` does. An accessibility text size turns Larger Accessibility Sizes on and a standard size turns it off, so setting the original size restores the device. JSON for `show` and `set` is `{udid, appearance, textSize, increaseContrast, reduceMotion, reduceTransparency, showBorders, liquidGlass: {style?, opacity}, colorFilter: {enabled, type?, intensity?}, voiceOver}`; a setting the device does not report is omitted.

Limits:

- iOS 27.2 offers one Liquid Glass style, so `--liquid-glass` fails with `settingUnsupported`; `--liquid-glass-opacity` works.
- Status bar overrides are simulator-only; on a physical device they fail with `settingUnsupported`.
- Turning VoiceOver on shows a one-time "VoiceOver Gestures" alert. It stays on screen after VoiceOver is turned off again, and blocks input, until you tap its OK button.
- A simulated location lasts until `settings location clear`.

Failures: `settingUnsupported`, `settingFailed` (with devicectl's message), `invalidArguments`, `targetNotFound`, `notBooted`, and on a device that is not ready its `doctor` check code.

## Agent mode

Add `--agent` to `describe-ui`, `tap`, `type`, `swipe`, `drag`, `key`, `key-combo`, `key-sequence`, `slider`, `touch`, `gesture double-tap`, `gesture pinch` and `batch` for checked, stateful control. A capture returns a snapshot ID and rows `ref|actions|role|label|value`, such as `e9|tap|button|AXe Playground|`. An action names a ref from that snapshot; AXe checks that the target is still the control you saw, sends the input, and returns the settled screen as a new capture.

```bash
axe describe-ui --agent --view navigation --udid "$UDID"
axe tap --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref e9
axe type 'Ada' --agent --focus --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref e18
axe batch --agent --udid "$UDID" --steps-json '{"snapshotID":"<SNAPSHOT_ID>","steps":[{"action":"tap","ref":"e12"},{"action":"type","ref":"e7","text":"Ada","focus":true}]}'
```

Results are JSON by default; `--output text` prints the same result compactly. `--view navigation` lists controls, `reading` (the default) adds visible text, and `full` returns the complete schema version 1. A refusal sends no input and carries a typed code such as `screenChanged`, `targetCovered`, `keyboardCovered`, `busy` or `observationFailed`, usually with the current screen. AXe retries inside the call only when the screen or target changed and the target is the same control. Agent mode works on simulators only; a shut-down simulator reports `notBooted`. `AXE_TIMING=1` prints a phase table to stderr after each agent command.

The [AXe skill](Skills/CLI/axe/SKILL.md) is the guide for agents; the [agent reference](Skills/CLI/axe/references/agent-reference.md) has every code, limit and output field. `--agent` needs no model or API key and is separate from `axe agent`.

## Autonomous agent command

`axe agent "<goal>" --udid <UDID>` turns a natural-language goal into AXe actions with TypeSafe AI's Jev model, one checked action at a time, from the accessibility tree without screenshots. It needs `TYPESAFE_API_KEY`; values that the goal does not state need an OpenAI-compatible text model (`AXE_TEXT_MODEL_API_KEY`). Base URLs must use HTTPS, except for `localhost`, `127.0.0.1` or `::1`.

```bash
axe agent "Open Settings and turn on Airplane Mode" --udid "$UDID"
```

See [docs/agent.md](docs/agent.md) for configuration, tracing and limitations.

## Physical iPhone and iPad

```bash
axe list-devices
axe doctor --udid "$DEVICE_UDID"
axe screenshot --udid "$DEVICE_UDID" --output device.png
axe describe-ui --udid "$DEVICE_UDID"
axe tap --udid "$DEVICE_UDID" --id "$ELEMENT_ID" --wait-timeout 15
axe record-video --udid "$DEVICE_UDID" --fps 3 --scale 0.5 --output device.mp4
```

Pair the device in Xcode, enable Developer Mode and keep it unlocked; AXe never pairs, enables Developer Mode, mounts disk images or unlocks. `doctor` checks pairing, Developer Mode, connection, developer disk image, lock state and screenshot service, and a failed check ends with `Error: <name> is not ready.` (it also checks that a simulator is booted). Screenshots, video, accessibility reads, `rotate`, taps, swipes, drags, `draw`, gestures, `touch --down --up`, typing, keys, buttons, batches and `settings` (except the status bar) work with the hardware UDID.

`button lock` needs `--allow-lock`. Agent mode, selected screens, `displays`, `shutdown`, `hinge`, `clipboard`, `slider`, side button, Apple Pay and the right-edge swipe preset return `unsupportedOnDevice`. Physical `record-video` prints the output path; JSON is `{path, pixelWidth, pixelHeight, frames}`, and `--verbose` prints the full receipt. A failed batch step keeps the step's own code. Device-specific codes include `deviceLocked`, `rotationLocked`, `rotationUnconfirmed`, `displayOrientationMismatch` and `deviceStreamReplaced`. Read the [physical device reference](Skills/CLI/axe/references/physical-device-reference.md) for input rules and video, and [docs/device-support.md](docs/device-support.md) for the design and limitations.

## Simulator shutdown and clipboard

```bash
axe shutdown --udid "$UDID"
printf '%s' 'AXe sample' | axe clipboard copy --stdin --udid "$UDID"
```

`shutdown` shuts down exactly one simulator by UUID through `simctl` and prints `Shut down <udid> (was Booted)` or `<udid> was already shut down`; JSON is `{udid, initialState, outcome}`. `clipboard copy` stages 1 to 65,536 UTF-8 bytes in one booted simulator's clipboard, verifies them by readback and prints `Copied N bytes to the clipboard of <udid> (sha256 …)`; JSON is `{udid, bytes, sha256}`. It does not paste. Both report `actionOutcomeUnknown` when the effect could not be confirmed. See the [clipboard reference](Skills/CLI/axe/references/clipboard-reference.md).

## Xcode compatibility

AXe supports Xcode 26 and Xcode 27. Xcode 27 simulator automation uses Device Hub; Simulator.app is not required. Release artifacts are built once and run unchanged with either supported Xcode selected. Compatibility was validated with Xcode 26.5 (build `17F42`) and iOS 26.5 (`23F77`), and with Xcode 27 Beta 3 (build `27A5218g`) and iOS 27 (`24A5380g`). `axe settings` needs Xcode 27.

## Development

AXe keeps its own copy of the IDB frameworks it uses, `FBControlCore` and `FBSimulatorControl`, in [Packages/IDBKit](Packages/IDBKit/README.md); edit them directly. XcodeGen is required to generate their project.

```bash
make build      # rebuilds the IDBKit frameworks only when stale, then swift build
make test       # unit tests
make e2e        # whole Playground suite on dedicated iPhone, iPad and iPhone Duo simulators
make e2e-devices   # opt-in run on connected iPhones and iPads
make bench-quick   # quick A/B timing of direct commands against a baseline payload
```

`AXE_BUILD_ARCHS` defaults to `"arm64 x86_64"`; set `arm64` for local Duo work. `make e2e` creates missing simulators, needs Xcode 27.1 or later for the Playground's Duo hinge view, and exits 2 without an iPhone Duo runtime. `make e2e-devices` exits 1 before building when no device is paired. See [Playground testing](docs/playground-testing.md) for simulator overrides and rerunning single groups. To validate a release payload under another Xcode, build the test bundle with that Xcode, then run `AXE_BIN_PATH=/path/to/release/axe ./test-runner.sh --tests-only`.

### Benchmarks

[benchmarks/](benchmarks/README.md) compares AXe with its best accepted baseline and with FlowDeck and RocketSim on Weather, Contacts and Reminders tasks, recording calls, time and returned tokens. Each run builds and measures the current source.

```bash
./benchmarks/run setup     # then set Xcode, a warm simulator and tool paths in benchmarks/config.local.json
./benchmarks/run doctor
./benchmarks/run
./benchmarks/run --tools axe --scenarios weather
```

Reports stay under `benchmarks/history/`, which Git ignores; accepted baselines are in [benchmarks/baselines.json](benchmarks/baselines.json).

## Documentation

Full documentation is available at [axe-cli.com/docs](https://axe-cli.com/docs).

## Disclaimer

AXe is an independent open-source iOS Simulator automation project and is not affiliated with, endorsed by, or associated with Deque Systems or its axe® accessibility products.

## Licence

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Third-party licensing notices, including Meta's IDB MIT attribution, are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

The keyboard signal detector is adapted from sim-use commit `c02295ed` under Apache 2.0. Its [licence and upstream NOTICE](Sources/AXe/Resources/licenses/sim-use) are included in AXe's resource bundle, with the source and changes listed in `ADAPTATION.md`. AXe's root MIT licence is unchanged.
