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

`make e2e` runs `scripts/run-e2e.sh`. It uses dedicated iPhone 18 Pro, iPad Air 11-inch (M4) and iPhone Duo simulators on the newest installed runtime that the selected Xcode's iOS SDK supports, named for that runtime, for example "AXe E2E Duo iOS 27.2". It creates any that are missing. A newer runtime, such as an iOS 27.3 beta with Xcode 27.2, is not chosen, because simulator runtimes ship with their Xcode. It never erases an existing simulator. With FlowDeck installed it turns hardware keyboard input off on each one (the prerequisite above). It builds the runtime payload, copies it with the results to `e2e-results/<UTC time>/`, and runs the matrix below with `--suite all`. The matrix reboots the Duo before each of its groups, except a first group that follows the run's own boot (`freshBootPerGroup` in `scripts/playground-acceptance.json`): about an hour into a run the Duo simulator's hinge reads time out and guest barriers go unanswered until it reboots. It never reboots past an input quarantine. After every boot it waits until `axe list-simulators --displays` succeeds, because the Duo reports no active panel for about 12 seconds after `simctl bootstatus` returns. Set `AXE_E2E_IPHONE_UDID`, `AXE_E2E_IPAD_UDID` or `AXE_E2E_DUO_UDID` to use other simulators. Without an installed iPhone Duo runtime it runs the iPhone and iPad groups and exits 2, so the result never counts as a full run.

To run the matrix directly, use three dedicated existing simulators. Prefer warm devices. The runner uses one guest at a time. It can boot a supplied stopped guest once and wait for readiness. It does not create, erase or replace simulators. The last lifecycle case shuts down Duo; iPhone and iPad remain available. Cancellation stops owned work and does not shut down a guest that was already running before the check.

```sh
PATH="/opt/homebrew/bin:$PATH" python3 scripts/test-playground-matrix.py \
  --axe /absolute/path/to/final-runtime/axe \
  --iphone IPHONE_UUID \
  --ipad IPAD_UUID \
  --duo DUO_UUID \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --suite all \
  --output build_products/playground-results/NEW_RUN
```

The result directory must be new. Earlier failed output is never replaced. The default all run requires the iPad profile. Use the actual installed Xcode and the matching helper compile inputs.

| Group | iPhone | iPad | Duo | Main behaviour |
| --- | ---: | ---: | ---: | --- |
| Core controls | 21 | 17 | 248 | Find, tap, type, scroll, swipe, drag, switches, sliders, retained contacts and batches |
| Agent controls | 142 | 4 | 157 | RS/1, selectors, references, cache, keys, gestures, sliders, clipboard and refusals |
| Keyboard and hardware | 1 | 1 | 52 | Text sources, editing, delays, held keys/modifiers, hardware buttons and release |
| Capture and recording | 0 | 0 | 28 | Selected PNG, video, streams, follow-active recording and cleanup |
| Hinge and app layouts | 1 | 1 | 19 | Hinge/rotation, moved controls, inset windows and interrupted touch input |
| Lifecycle, last | 0 | 0 | 1 | Shutdown only the selected Duo and check the other guests |
| **Total** | **165** | **23** | **505** | **693 case executions** |

The Duo core group has 20 explicit core cases, 217 expanded cases, eight selected client-exit cases and three raw/selected input handover cases. The ordinary iPhone also checks cold-broker admission. Agent checks include the Photos permission buttons and slider input during folding and rotation.

## What the checks prove

Core input checks use current raw accessibility frames and real control state. They require exact text, switch/slider values, new visible rows, gesture callbacks and physical contact paths. Duo repeats coordinate and gesture paths in all seven supported display/orientation positions. The outer display does not support upside-down portrait. Selected requests also check the physical display and boot identity and reject inactive or stale targets before input.

Hinge checks include 18 ordered numeric angles, named closed/tabletop/open positions, measured discovery metadata, controls that move when the hinge changes and controls above and below the fold. Inset-window checks use the same normal app and include raw and agent input. After folding or rotation, the checks find the current element again. They do not reuse an old frame.

Held-input checks wait for actual contacts or text effects before changing the device. They require stopped old-layout input, release evidence, no later input at old coordinates and a fresh real action. They cover raw and selected touch, moving pairs, retained contacts, keys and hardware buttons in their stated cases. The held Shift+A probe checks the public library boundary. It does not prove interruption of the no-flag `key-combo` CLI command.

The matrix sets `FBSIMULATORCONTROL_LOG_HID_DETAILS=1` before its first owned command. Exact held-button release checks need the real button name and UP direction in the receipt. Set the same variable before the test process starts for direct or copied-suite runs. Reuse warm audit devices, but confirm that an earlier owned broker has exited on its normal idle path before this proof. An existing broker keeps its initial environment; the flag does not change it. This is a test diagnostic, not a product logging default.

Agent checks require valid RS/1 output, real app effects, reference/cache reuse when valid and refusal when the app, focus, layout or selected target changes. They include all prior accepted comparison behaviours and preserve strict negative cases. A successful command or screenshot alone is not an app-effect proof.

The normal app's Documents readback is checked against its real PID and generation. Contact, callback, layout and text data come from normal visible pages. External state tools fold or rotate the guest; AXe sends the input under test. No hidden state route is used.

## Results and failures

Both runners use `scripts/playground-suite-counts.json` and `scripts/playground-acceptance.json`. The matrix requires every named source declaration before it builds. Change the counts only when actual test cases change.

**Completed case instances come from the structured Swift Testing version-0 event stream.** This includes each parameter argument. The reader requires one complete serial run, matching start/end events, the exact expected count and zero issues, skips or cancellation. It also checks XML for failed/skipped declarations. XML alone is not an executed-case count on this toolchain.

Each result has JSON, XML, structured events, full command logs and a per-suite artifact directory. The result stores started and completed cases, errors and cases without completed results. Missing completed XML/event records do not prove that no native action started. The reader has 16 pure tests with a genuine 27-case/4-declaration trace and damaged/failing variants; those tests are separate from the 693 simulator cases.

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

The one-case `PlaygroundDuoRawLongTextTests` suite is part of the full Duo profile and its `keyboard-hardware` group. It tests 300 bytes of raw mixed-case text on the inner screen in landscape, after normal agent focus taps. It requires exact text and callback counts, unchanged control and touch state, then a lowercase key and a fresh native field read. It uses the existing command deadline. It is separate from the 133-case `PlaygroundAgent` run.

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

These checks use the full AXe Swift package through `test-runner.sh`. The four new direct-suite sources are registered separately from the matrix source list. The raw suites import AXe internals and must not be copied into the matrix standalone package.

| Direct suite | Cases | Device |
| --- | ---: | --- |
| `PlaygroundAgentLifecycleTests` | 6 | iPhone or Duo |
| `PlaygroundAgentBrokerRestartTests` | 1 | iPhone or Duo |
| `PlaygroundRawKeyboardBrokerTests` | 1 | Ordinary iPhone |
| `PlaygroundRawInputAdmissionTests` | 6 | Ordinary iPhone |
| `PlaygroundAgentNativeStateTests` | 6 | iPhone or Duo |

Use an existing warm simulator with the normal Playground installed. First build the full-package test host from the same source and matching native frameworks. `--tests-only` does not build that host. Set `AXE_BIN_PATH` to the actual matched CLI executable, not an installation wrapper. The broker-restart case checks that executable, simulator, user and process start time before it stops its own idle worker.

Run one command at a time. Read each saved result before the next command. These commands describe 19 cases on one ordinary iPhone; they are not passing results:

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

Then use the warm Duo for the three shared suites, 12 cases. The ordinary-only raw suites reject Duo mode before simulator work:

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

Run these jobs serially. The runner supplies a new artifact directory and checks the registered case counts: two and four, with no skipped or missing cases. The normal matrix and agent-controls/keyboard-hardware groups also register the suites. Keep the prior 17 host focus tests; these six cases add real simulator evidence. Preserve failed outputs and do not replay input. Public accessibility output still does not prove exact native UID continuity. Shared-ID and anonymous fields remain separate checks.

## Resources, delivery and boundaries

The matrix builds the public process probe and records CPU and memory every 15 seconds in `resources.jsonl`, starting before the Playground build. It records Codex, Device Hub, simulator services and the largest/highest-CPU processes. There is no 8 GB cap. Run heavy work one job at a time and inspect for sustained growth. Stop owned work if it runs away; preserve the evidence.

Build, signing, packaging and local installation use a separate exact-payload recipe. The current recipe uses the ordinary iPhone, which the full matrix leaves warm. It verifies archive contents, strict signatures, an unlinked installed wrapper, a real app action and complete removal/restoration. It must use the final runtime and completed build receipts. These checks do not add to 693 and do not authorise uploads, pushes, publication or deployment.

The current hosted workflow runs non-E2E checks. Local results do not prove hosted simulator coverage. Repeated cold-start stress, conditional empty-tree recovery without a reproduced fault, Intel hardware and Apple Pay payment UI are outside this run. Apple Pay hardware delivery remains in scope. The suite repeats the documented prior behaviours; it does not claim every possible app, option or new OS state.
