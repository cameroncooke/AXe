# Repeatable simulator checks

The Playground is a normal app. Swift Testing calls the real AXe CLI and checks app state, accessibility, contacts and callbacks after real input. XCUITest does not send the input. The app has no injected test state.

Duo checks cover device support. SimUse checks cover the optional agent interface. Raw accessibility and coordinate commands remain available.

## Build inputs

Use the tracked XcodeGen definition, `AxePlaygroundApp/project.yml`. Generated projects and test packages stay under the new result directory. Install XcodeGen first.

Supply the exact built AXe payload with its matching frameworks and resources. The runner does not rebuild AXe. It records all payload file hashes and links and requires them to stay unchanged. This binds a run to those bytes; it does not prove that an arbitrary executable matches the checkout.

The runner builds the normal Playground once, then copies and builds the exact current test sources once. `checks/source-pins.json` records Package.swift and copied source hashes. `checks/proposal-source-pins.json` records current source origins and the runner/config/count/parser hashes. These files are inputs, not build or test results.

Native state and held-input probes compile against the supplied payload's `Frameworks` directory. The default compiler is the selected Xcode; the default private headers are `Packages/IDBKit/PrivateHeaders`. Set `AXE_TEST_HOST_DEVELOPER_DIR` and `AXE_TEST_IDB_SOURCE` when the matching inputs are elsewhere. The runner records their paths and hashes. Missing inputs fail before the affected case. It does not choose another compiler or runtime.

## Software keyboard prerequisite

Keyboard-observation tests require a visible software keyboard on the selected simulator. Text focus alone does not prove this. Accessibility key frames outside the current app bounds do not prove that the keys are visible.

Before these checks, use the normal Device Hub controls for each test simulator:

1. Select the target simulator and turn hardware keyboard input off.
2. Open the normal Playground page and focus its text field.
3. Confirm that the software keyboard is visible inside the simulator screen. Use the normal Dismiss control and focus the field again if needed.
4. Run the unchanged keyboard checks. Keep their visibility and cache assertions.

FlowDeck is an optional way to set the same prerequisite. It is not a test dependency:

```sh
DEVELOPER_DIR=/absolute/path/to/Xcode.app/Contents/Developer \
flowdeck simulator keyboard hardware off --simulator SIMULATOR_UUID --json
```

Use normal simulator controls. Do not inject app state, guess stored preferences, force detector output or relax tests to prepare the device. A prerequisite change and a passing focused repeat do not change an earlier failed full-run result.


## Run the full suite

Run every group on all three devices with one command:

```sh
DEVELOPER_DIR=/absolute/path/to/Xcode.app/Contents/Developer make e2e
```

`make e2e` runs `scripts/run-e2e.sh`. It uses dedicated iPhone 18 Pro, iPad Air 11-inch (M4) and iPhone Duo simulators on the newest installed runtime that the selected Xcode's iOS SDK supports, named for that runtime, for example "AXe E2E Duo iOS 27.2". It creates any that are missing. A newer runtime, such as an iOS 27.3 beta with Xcode 27.2, is not chosen, because simulator runtimes ship with their Xcode. It never erases an existing simulator. With FlowDeck installed it turns hardware keyboard input off on each one (the prerequisite above). It builds the runtime payload, copies it with the results to `e2e-results/<UTC time>/`, and runs the matrix below with `--suite all`. The matrix reboots the Duo before each of its groups, except a first group that follows the run's own boot (`freshBootPerGroup` in `scripts/playground-acceptance.json`): about an hour into a run the Duo simulator's hinge reads time out and guest barriers go unanswered until it reboots. It never reboots past an input quarantine. After every boot it waits until `axe displays` succeeds, because the Duo reports no active panel for about 12 seconds after `simctl bootstatus` returns. Set `AXE_E2E_IPHONE_UDID`, `AXE_E2E_IPAD_UDID` or `AXE_E2E_DUO_UDID` to use other simulators. Without an installed iPhone Duo runtime it runs the iPhone and iPad groups and exits 2, so the result never counts as a full run.

To run the matrix directly, use three dedicated existing simulators. Prefer warm devices. The runner uses one guest at a time. It can boot a supplied stopped guest once and wait for readiness. It does not create, erase or replace simulators. The last lifecycle case shuts down Duo; iPhone and iPad remain available. Cancellation stops owned work and does not shut down a guest that was already running before the check.

```sh
PATH="/opt/homebrew/bin:$PATH" python3 scripts/test-playground-matrix.py \
  --axe /absolute/path/to/final-runtime/axe \
  --iphone IPHONE_UUID \
  --ipad IPAD_UUID \
  --duo DUO_UUID \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --suite all \
  --output e2e-results/NEW_RUN
```

The result directory must be new. Earlier failed output is never replaced. The default all run requires the iPad profile. Use the actual installed Xcode and the matching helper compile inputs.

| Group | iPhone | iPad | Duo | Main behaviour |
| --- | ---: | ---: | ---: | --- |
| Core controls | 76 | 72 | 268 | Find, tap, long press, double tap, two-finger tap, type, scroll, scroll until visible, swipe, drag and drag hold, draw, PencilKit ink and tool picker, Control Centre, pinch, switches, sliders, retained contacts and batches |
| Agent controls | 148 | 4 | 165 | RS/1, selectors, references, cache, keys, gestures, sliders, clipboard and refusals |
| Keyboard and hardware | 16 | 10 | 57 | Text sources, editing, delays, held keys/modifiers, hardware buttons and release |
| Capture and recording | 6 | 6 | 30 | PNG, video and streams on ordinary and selected screens, follow-active recording and cleanup |
| Hinge and app layouts | 1 | 1 | 19 | Hinge/rotation, moved controls, inset windows and interrupted touch input |
| Lifecycle, last | 0 | 0 | 1 | Shutdown only the selected Duo and check the other guests |
| **Total** | **245** | **93** | **536** | **874 case executions** |

The focus-and-type suites belong to both the agent and keyboard groups and run once in a full run.

The Duo core group has 20 explicit core cases, 217 expanded cases, eight selected client-exit cases, three raw/selected input handover cases and the twenty drawing, zoom, PencilKit sketch and gesture cases that every device runs. The ordinary iPhone also checks cold-broker admission. Agent checks include the Photos permission buttons and slider input during folding and rotation.

## Physical devices

The physical-device checks are opt-in and separate from `make e2e`:

```sh
DEVELOPER_DIR=/absolute/path/to/Xcode.app/Contents/Developer make e2e-devices
```

`make e2e-devices` runs `scripts/run-e2e-devices.sh`. It reads CoreDevice's device list first and
exits 1 before building anything when it lists no paired physical iPhone or iPad. It checks pairing only:
an offline device that CoreDevice still remembers passes this step and fails at install. It then builds
the AXe runtime payload and the Playground for iOS devices with automatic signing, installs the
Playground on each device, compiles `scripts/fixtures/MediaPatternCheck.swift` and runs
`scripts/test-physical-devices.py`. Build logs and payloads go to `e2e-results/devices-<UTC time>/`,
and the check results to its `checks/` folder: every command in `commands.log` (long-running stream
commands are logged when they start) and `results.json`, which also counts tree reads retried after a
failure. Each tree read is tried up to three times. The Playground needs the iOS 27.1 SDK or later.

Keep each device unlocked, awake and in Developer Mode. Set `AXE_E2E_DEVICES` to a space-separated
list of hardware UDIDs to test only those, `AXE_E2E_SKIP_ROTATION=1` to leave orientation unchanged,
`AXE_E2E_CHECKS` to a comma-separated list of check names (as the output prints them, for example
`"pinch in and out"`) to rerun only those after a fix,
and `AXE_E2E_ALLOW_PROVISIONING_UPDATES=1` to let Xcode register a new device while signing.

| Check | Read back from |
| --- | --- |
| `doctor` | All readiness checks ready |
| Coordinate taps | Tap Test records each tap at the exact point |
| Typing and keys | The text field holds `axe e2e`, then `axe e2` after backspace |
| Drawing | `draw` with `--close` through a triangle: Drawing records one stroke from and back to the first corner, within 2 points of the corners' bounds, one contact, not cancelled |
| PencilKit ink and tool picker | Sketch (a PencilKit canvas with the system tool picker) is painted with a shaded 3D car, `scripts/fixtures/sketch-car.json` played by `scripts/sketch_picture.py`: about 160 strokes with Watercolor, Crayon, Fountain Pen, Monoline and Pencil. Tools and line weights are chosen in the picker, whose strip is scrolled with `swipe --until-label` to the tools that start out of view; colours come from the screen's twenty swatches. The app must report every stroke and exactly the inks used; the picture is saved as `sketch-car.png` |
| Long press and other touch gestures | On Drawing: `tap --id --hold 1` records one contact of about a second, `--count 2` two short ones, `--touches 2` two fingers; `drag --hold 0.7` takes about 0.65 s longer than the same drag without it |
| Scroll distance and scroll until | `gesture scroll-down --distance 0.4` moves 0.4 of the screen height; `scroll-up --until-id` brings a row 12 below the last visible one on screen, sends nothing when run again, and fails with `elementNotFound` for a missing element |
| Pinch | `gesture pinch --scale 2`, then `0.5`, at the default centre and radius: Zoom records one zoom in above 1.3, then one zoom out at least 0.3 lower |
| Element tap and point lookup | `describe-ui --point` finds `media-pattern-next`; `tap --id` advances the marker phase |
| Screenshot | Upright: four squares, eight edge samples and the app's current phase |
| Raw stream and MP4 recording | Upright decoded frames across one marker change; SIGINT exits 0 |
| Native H.264 | Frames across two changes 24 seconds apart, past the 20-second RTCP timeout, turned by the rotation AXe announces, with few decode failures |
| Rotation | Four `rotate right` turns; each confirmed turn places the next tap exactly, and swaps the app frame when the turn before it was confirmed too |
| All devices at once (two or more devices) | Parallel screenshots and native streams with a marker change on each |

The rotation check accepts `rotationUnconfirmed` because an iPad can keep reporting its previous
display orientation after a software rotation, and an iPhone does not turn its interface upside down.
After an unconfirmed turn the next tap may refuse with `displayOrientationMismatch` (iPad) or land
(iPhone); it fails if a refused tap reaches the app or a landed tap misses, and the result counts the
two outcomes apart. It requires at least two confirmed turns.

The suite does not exercise swipes, drags, gestures other than pinch, other two-finger input, edge presets, standalone `touch`,
batches with held contacts, key sequences and combinations, hardware buttons, semantic press, the lock
refusal or `deviceStreamReplaced`. See [device-support.md](device-support.md) for what devices support.

## Quick performance check

`make bench-quick` times direct CLI commands with a baseline and a candidate payload on one simulator
or device, for quick iteration. The benchmark suite in `benchmarks/` stays the release gate; it measures
whole agent tasks and takes much longer.

```sh
AXE_BENCH_UDID=<udid> AXE_BENCH_BASELINE=/path/to/baseline/payload/axe make bench-quick
```

The target builds the current tree as a payload (`axe` with `Frameworks` beside it) and runs
`scripts/bench-quick.py`; set `AXE_BENCH_CANDIDATE` to time an existing payload instead, and
`AXE_BENCH_ARGS` for extra flags. Both builds must be payloads: a debug build in `.build/` loads the
current tree's frameworks. Use the latest release payload as the simulator baseline. Devices have no
release, so pin a payload under `e2e-results/bench-quick/baselines/` and replace it only with
`--accept NAME` after a run without regression.

It launches the Playground's Tap Test screen and alternates blocks of the two builds. Before each block
it stops every AXe broker for the target, whatever build started it, and waits for it to exit: a broker
from another build could otherwise serve the block, and device brokers refuse a different build. A
block times the first `describe-ui` (cold broker), then repeats each command three times (warm), then
checks that the last tap landed.

| Target | Commands |
| --- | --- |
| Simulator | `describe-ui`, `tap`, `key`; selected `describe-ui` and `tap`; `describe-ui --agent` and its output size |
| Device | `describe-ui`, `tap`, `key`; `--full` adds `tap --id`, a 3-tap batch and a screenshot |

A command is reported slower only when the candidate is slower in every pair (at least five) and the
median difference exceeds the resolution: twice the median absolute deviation of its warm samples, and
at least 3% of the baseline. When any command is flagged, as many pairs again run, and the result stands
only if all but one combined pair agree. Otherwise it prints "no difference" with the resolution. Run
`--self-check` (the baseline against itself) to see the noise floor on a machine. Exit status: 0 no
regression, 1 regression, 2 failed commands. Reports go to `e2e-results/bench-quick/`.

It does not cover task success, tokens across real tasks, competitor comparison, boot, Duo fold
transitions or video; those stay with the release benchmark and the e2e suites. AXe's agent-mode phase
timing (`AXE_TIMING`) is available with `--phases` to explain a difference, not to decide one.

## What the checks prove

Core input checks use current raw accessibility frames and real control state. They require exact text, switch/slider values, new visible rows, gesture callbacks and physical contact paths. Duo repeats coordinate and gesture paths in all seven supported display/orientation positions. The outer display does not support upside-down portrait. Selected requests also check the physical display and boot identity and reject inactive or stale targets before input.

Hinge checks include 18 ordered numeric angles, named closed/tabletop/open positions, measured discovery metadata, controls that move when the hinge changes and controls above and below the fold. Inset-window checks use the same normal app and include raw and agent input. After folding or rotation, the checks find the current element again. They do not reuse an old frame.

Held-input checks wait for actual contacts or text effects before changing the device. They require stopped old-layout input, release evidence, no later input at old coordinates and a fresh real action. They cover raw and selected touch, moving pairs, retained contacts, keys and hardware buttons in their stated cases. The held Shift+A probe checks the public library boundary. It does not prove interruption of the no-flag `key-combo` CLI command.

The matrix sets `FBSIMULATORCONTROL_LOG_HID_DETAILS=1` before its first owned command. Exact held-button release checks need the real button name and UP direction in the receipt. Set the same variable before the test process starts for direct or copied-suite runs. Reuse warm audit devices, but confirm that an earlier owned broker has exited on its normal idle path before this proof. An existing broker keeps its initial environment; the flag does not change it. This is a test diagnostic, not a product logging default.

Agent checks require valid RS/1 output, real app effects, reference/cache reuse when valid and refusal when the app, focus, layout or selected target changes. A successful command or screenshot alone is not an app-effect proof.

The normal app's Documents readback is checked against its real PID and generation. Contact, callback, layout and text data come from normal visible pages. External state tools fold or rotate the guest; AXe sends the input under test. No hidden state route is used.

## Results and failures

Both runners use `scripts/playground-suite-counts.json` and `scripts/playground-acceptance.json`. The matrix requires every named source declaration before it builds. Change the counts only when actual test cases change.

**Completed case instances come from the structured Swift Testing version-0 event stream.** This includes each parameter argument. The reader requires one complete serial run, matching start/end events, the exact expected count and zero issues, skips or cancellation. It also checks XML for failed/skipped declarations. XML alone is not an executed-case count on this toolchain.

Each result has JSON, XML, structured events, full command logs and a per-suite artifact directory. The result stores started and completed cases, errors and cases without completed results. Missing completed XML/event records do not prove that no native action started. The reader has 16 pure tests with a genuine 27-case/4-declaration trace and damaged/failing variants; those tests are separate from the simulator cases.

A failed case is not replayed. An input quarantine stops later work on that guest and stays in place. The runner does not clear it, restart a guest or add a production setup path. Preserve the failed result and inspect it before a new run.

## Focused checks

Use `--only iphone`, `--only ipad` or `--only duo` with a group: `core-controls`, `agent-controls`, `keyboard-hardware`, `media` or `hinge`. A focused run proves only that group and guest. `--suite core` keeps the nine generic core checks for a narrow compatibility check. The full Duo profile uses explicit display/orientation cases instead.

The existing direct runner accepts each exact Playground suite and the registered `PhotosButtonLeafE2ETests` suite. Its tests-only mode needs the current app and native test target already built, and matching helper paths from a matrix run. For example:

```sh
AXE_BIN_PATH=/absolute/path/to/final-runtime/axe \
SIMULATOR_UDID=DUO_UUID AXE_DUO_E2E=1 \
AXE_DUO_STATE_CHANGE_PATH=/absolute/path/to/matrix-run/duo-external-state-change \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./test-runner.sh --tests-only PlaygroundDuoInterruptionTests
```

The one-case `PlaygroundAgentTransportTests` suite repeats selected typing, a coordinate drag in the same field, fresh discovery and a physical Button tap. It checks exact text callbacks and balanced contacts on an ordinary iPhone or Duo. It is part of both agent matrix profiles. To run it alone on an existing warm simulator with the matched full-package test host:

```sh
AXE_BIN_PATH=/absolute/path/to/final-runtime/axe \
DYLD_FRAMEWORK_PATH=/absolute/path/to/final-runtime/Frameworks \
SIMULATOR_UDID=IPHONE_UUID AXE_DUO_E2E=0 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./test-runner.sh --tests-only PlaygroundAgentTransportTests
```

For Duo, set its UUID and `AXE_DUO_E2E=1`. This focused case does not replace the full suite.

The one-case `PlaygroundDuoRawLongTextTests` suite is part of the full Duo profile and its `keyboard-hardware` group. It tests 300 bytes of raw mixed-case text on the inner screen in landscape, after normal agent focus taps. It requires exact text and callback counts, unchanged control and touch state, then a lowercase key and a fresh native field read. It uses the existing command deadline.

Run only that case on an existing warm Duo with the matched full-package test host:

```sh
AXE_BIN_PATH=/absolute/path/to/final-runtime/axe \
DYLD_FRAMEWORK_PATH=/absolute/path/to/final-runtime/Frameworks \
SIMULATOR_UDID=DUO_UUID AXE_DUO_E2E=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./test-runner.sh --tests-only PlaygroundDuoRawLongTextTests
```

The exact Swift Testing filter is `PlaygroundDuoRawLongTextTests/exactLongText`: one case. Registration and count checks do not prove that this case ran or passed.

The Photos button suite requires the matching process observer from a matrix run. Its two cases use a fresh agent reference and a selected accessibility ID:

```sh
AXE_BIN_PATH=/absolute/path/to/final-runtime/axe \
SIMULATOR_UDID=IPHONE_UUID \
AXE_MEDIA_PROCESS_OBSERVER_PATH=/absolute/path/to/matrix-run/verification-drivers/observe-media-process.py \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./test-runner.sh --tests-only PhotosButtonLeafE2ETests
```

If that helper is missing, the direct runner exits before simulator work.

The direct Duo-only path validates an explicit available Duo UUID before simulator work. Each suite's helper requirements are in the shared configuration. The direct filter uses the same structured result reader. It does not replace full acceptance.

### Physical tap timing and release

Use `scripts/verify-physical-taps.py` for the repeatable physical-tap check. First build the normal Playground from the tracked XcodeGen setup and install it on the existing warm target. The installed app must include the `duo-controls` page and its version-6 Documents readback. Supply the complete matched AXe runtime, including its frameworks and resources. This script does not build, install or boot a simulator.

Run one device at a time, with no other UI job on that device:

```sh
DEVELOPER_DIR=/absolute/path/to/Xcode.app/Contents/Developer \
/usr/bin/python3 scripts/verify-physical-taps.py \
  --runtime /absolute/path/to/matched-runtime/axe \
  --udid IPHONE_UUID \
  --output /absolute/path/to/NEW_PHYSICAL_TAP_RESULT
```

Keep the normal Playground running on its Duo Controls page before each run. The launch command reuses that warm app process; it does not terminate it. An app on another page fails the existing target checks without test input. Navigate to Duo Controls through the normal UI before starting a new run.

Then run the same command with the warm Duo UUID and a different new result directory. The script can use the normal Show pad button once if the controls are clipped. It does not fold or rotate the device, change app data or replay failed input.

The check compares fresh native frames with the app's window coordinates and visible scroll area before each no-flag coordinate tap. It requires one pad tap and one button callback, one released contact per action, no long-press callback and no change to other controls. It records actual guest DOWN-to-UP time and requires it to stay below the fixture's 0.5-second long-press threshold. It does not promise an exact 100 ms guest interval.

Each result contains the actual CLI, native framework, app and script hashes; command arguments, output and process results; display context; broker executable observations; and before/after app state. Failed runs retain their output and final state when it can be read. These are current-pose checks only. A Duo outer-screen result does not prove inner-screen, other-rotation or fold-interruption coverage, and these two actions do not replace the matrix.

## Reference and raw-input follow-up checks

These checks use the full AXe Swift package through `test-runner.sh`. Their sources are registered under `directSuiteSources` in `scripts/playground-acceptance.json`, separately from the matrix source list. The raw suites import AXe internals and must not be copied into the matrix standalone package.

| Direct suite | Cases | Device |
| --- | ---: | --- |
| `PlaygroundAgentLifecycleTests` | 6 | iPhone or Duo |
| `PlaygroundAgentBrokerRestartTests` | 1 | iPhone or Duo |
| `PlaygroundRawKeyboardBrokerTests` | 1 | Ordinary iPhone |
| `PlaygroundRawInputAdmissionTests` | 6 | Ordinary iPhone |
| `PlaygroundAgentNativeStateTests` | 6 | iPhone or Duo |

Use an existing warm simulator with the normal Playground installed. First build the full-package test host from the same source and matching native frameworks. `--tests-only` does not build that host. Set `AXE_BIN_PATH` to the actual matched CLI executable, not an installation wrapper. The broker-restart case checks that executable, simulator, user and process start time before it stops its own idle worker.

Run one command at a time. Read each saved result before the next command. These commands describe 20 cases on one ordinary iPhone; they are not passing results:

```sh
export DEVELOPER_DIR=/absolute/path/to/Xcode.app/Contents/Developer
export AXE_BIN_PATH=/absolute/path/to/matched-runtime/axe
export SIMULATOR_UDID=IPHONE_UUID
export AXE_DUO_E2E=0
./test-runner.sh --tests-only PlaygroundAgentLifecycleTests
./test-runner.sh --tests-only PlaygroundAgentBrokerRestartTests
./test-runner.sh --tests-only PlaygroundRawKeyboardBrokerTests
./test-runner.sh --tests-only PlaygroundRawInputAdmissionTests
./test-runner.sh --tests-only PlaygroundAgentNativeStateTests
```

Then use the warm Duo for the three shared suites, 13 cases. The ordinary-only raw suites reject Duo mode before simulator work:

```sh
export SIMULATOR_UDID=DUO_UUID
export AXE_DUO_E2E=1
./test-runner.sh --tests-only PlaygroundAgentLifecycleTests
./test-runner.sh --tests-only PlaygroundAgentBrokerRestartTests
./test-runner.sh --tests-only PlaygroundAgentNativeStateTests
```

The direct runner writes a separate result directory and rejects failed, missing or skipped cases using the registered count. Keep failed output. Do not combine these commands or earlier focused results into a full-suite pass. Check CPU and memory between jobs as described below.

## Focus a field and type

The focus-and-type suites use the normal UIKit Agent Examples field and the normal SwiftUI Text Input field. They run two cases on an ordinary iPhone and four on Duo: both fields on the outer portrait screen and inner landscape screen. They use the existing public CLI and normal Playground navigation. No extra fixture, injected state or external helper is required.

These six proof cases use `--view full`. The saved argument list includes that option and matches the actual command. They do not check the default compact focus-and-type response.

Each case first verifies an empty, unfocused field. Text Input focuses on entry, so setup sends one normal Return key before this check. UIKit uses a fresh normal page. The case then sends unsupported £ text and requires a structured rejection with no action/batch receipt and unchanged native field state. It obtains a new reference and sends one valid `type --agent --focus` command. Both phase receipts must complete: a two-event focus tap and typing events. Independent native readback must show exact text and actual focus. UIKit must report the exact editing-callback increase; SwiftUI must show the exact character count. Other field values must remain unchanged.

Use an existing warm ordinary iPhone first:

```sh
export AXE_BIN_PATH=/absolute/path/to/matched-runtime/axe
export SIMULATOR_UDID=IPHONE_UUID
export AXE_DUO_E2E=0
./test-runner.sh --tests-only PlaygroundAgentFocusAndTypeTests
```

Then use the existing warm Duo:

```sh
export SIMULATOR_UDID=DUO_UUID
export AXE_DUO_E2E=1
./test-runner.sh --tests-only PlaygroundDuoAgentFocusAndTypeTests
```

Run these jobs serially. The runner supplies a new artifact directory and checks the registered case counts: two and four, with no skipped or missing cases. The normal matrix and agent-controls/keyboard-hardware groups also register the suites. Preserve failed outputs and do not replay input. Public accessibility output still does not prove exact native UID continuity. Shared-ID and anonymous fields remain separate checks.

## Resources, delivery and boundaries

The matrix builds the public process probe and records CPU and memory every 15 seconds in `resources.jsonl`, starting before the Playground build. It records Codex, Device Hub, simulator services and the largest/highest-CPU processes. There is no 8 GB cap. Run heavy work one job at a time and inspect for sustained growth. Stop owned work if it runs away; preserve the evidence.

Build, signing, packaging and local installation use a separate exact-payload recipe. The current recipe uses the ordinary iPhone, which the full matrix leaves warm. It verifies archive contents, strict signatures, an unlinked installed wrapper, a real app action and complete removal/restoration. It must use the final runtime and completed build receipts. These checks are not part of the matrix count and do not authorise uploads, pushes, publication or deployment.

The hosted workflow runs non-E2E checks. Local results do not prove hosted simulator coverage. The suite does not cover repeated cold-start stress, conditional empty-tree recovery without a reproduced fault, Intel hardware or the Apple Pay payment UI; it does cover Apple Pay hardware button delivery. It does not claim every possible app, option or new OS state.
