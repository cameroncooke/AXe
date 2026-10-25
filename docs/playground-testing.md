# Repeatable simulator checks

The Playground is a normal app. Swift Testing runs host checks that call the real AXe CLI. The checks read accessibility and app state after real input. They do not use XCUITest to send UI actions, inject app state or replace gestures with mocks.

## Current acceptance

The full plan is **693 case executions across 90 suite runs and 66 Swift sources**: iPhone 165, iPad 23 and Duo 505. These are planned full-run counts; **there is no full-suite pass**.

**D38 is proved within scope and integrated.** Eight distinct input/signal combinations passed across two controlled runs: held Space, delayed key sequence, held touch and moving pinch, each under SIGINT and SIGTERM. Seven passed in the earlier run; the separately named moving-pinch SIGINT case now passed. The earlier whole eight-case run remains failed because its later fresh AX action disconnected. Both records are retained. The full named eight-case suite and current 693-case matrix remain pending. [Named pinch result](../build_products/verification/duo-complete-20261024/selected-client-exit-native-v5-result.json), [earlier seven passes/one failure](../build_products/verification/duo-complete-20261024/selected-client-exit-native-v4-result.json), [source integration](../build_products/verification/duo-complete-20261024/client-exit-integration-plan-v1/integration-result.json). The named run took 95.66 seconds, peak combined memory 14.068 GiB, without a resource stop or crash.

The earlier runtime checks used CLI v5 `926233146df9…` / native `6ffe56ce1181…`. [Ordinary-iPhone regression passed 8/8](../build_products/verification/duo-complete-20261024/ordinary-regression-native-v2-result.json), including the corrected sole-display check and raw/selected typing. [115 host cases passed against CLI v5 sources](../build_products/verification/duo-complete-20261024/host-v5-all-result.json). The earlier [eight native release fault checks](../build_products/verification/duo-complete-20261024/native-owned-release-tests-v4/parsed-result.json) use that same unchanged native image. Host/native/parser checks do not add to 693. Final acceptance must use a runtime that matches the integrated source.

The [earlier 672-case attempt](../build_products/verification/duo-complete-20261024/final-matrix-v1/result.json) remains interrupted after 36 completed: 33 passed and three failed, with no skips. The original raw timeout, incorrect test assertion and agent observation failure remain recorded. The ordinary regression passed separately; the agent read failure still has no proved cause. The [four hinge-layout passes](../build_products/verification/duo-complete-20261024/hinge-layout-native-v2-result.json) retain their CLI v4 scope.

The first two recording-follow checks failed because the test command did not supply its existing process-observer path. This was a test prerequisite error, not a confirmed product fault. The [corrected two-case run passed separately](../build_products/verification/duo-complete-20261024/duo-media-follow-native-v2-result.json). It does not replace full acceptance.

The [coverage map](audits/2026-10-24-manual-automation-map.md) retains all 175 prior rows and adds D38 and D39. The [JSON map](audits/2026-10-24-manual-suite-map.json) distinguishes scoped results, failed attempts and the pending full run. The [vendor review](audits/2026-10-24-vendor-failure-review.md) is source/binary evidence, not another simulator pass. Local package/install acceptance remains pending. No upload, push, publication or deployment is authorised.

Duo checks cover device support. SimUse checks cover the optional agent interface. Raw accessibility and coordinate commands remain available.

## Build inputs

Use the tracked XcodeGen definition, `AxePlaygroundApp/project.yml`. Generated projects and test packages stay under the new result directory. Install XcodeGen first.

The earlier build-source preparation path passed [fresh](../build_products/verification/duo-complete-20261024/public-setup-source-proposal-v1/tracked-fresh-v1/result.json) and [repeat](../build_products/verification/duo-complete-20261024/public-setup-source-proposal-v1/tracked-repeat-v1/result.json) checks for all 63 pinned source hashes. The original cache stayed unchanged. This is local-file source preparation, not compilation, simulator input or package acceptance.

Supply the exact built AXe payload with its matching frameworks, helper and resources. The runner does not rebuild AXe. It records all payload file hashes and links and requires them to stay unchanged. This binds a run to those bytes; it does not prove that an arbitrary executable matches the checkout.

The runner builds the normal Playground once, then copies and builds the exact current test sources once. `checks/source-pins.json` records Package.swift and copied source hashes. `checks/proposal-source-pins.json` records current source origins and the runner/config/count/parser hashes. These files are inputs, not build or test results.

Native state and held-input probes compile against the supplied payload's `Frameworks` directory. The default compiler is the selected Xcode; the default private headers are `idb_checkout/PrivateHeaders`. Set `AXE_TEST_HOST_DEVELOPER_DIR` and `AXE_TEST_IDB_SOURCE` when the matching inputs are elsewhere. The runner records their paths and hashes. Missing inputs fail before the affected case. It does not choose another compiler or runtime.

## Run the full suite

Use three dedicated existing simulators. Prefer warm devices. The runner uses one guest at a time. It can boot a supplied stopped guest once and wait for readiness. It does not create, erase or replace simulators. The last lifecycle case shuts down Duo; iPhone and iPad remain available. Cancellation stops owned work and does not shut down a guest that was already running before the check.

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

The Duo core group has 20 explicit core cases, 217 expanded cases, eight selected client-exit cases and three raw/selected input handover cases. The ordinary iPhone also checks cold-broker admission. Agent checks include the Photos permission buttons and slider input during folding and rotation. The iPad retains its earlier baseline scope.

## What the checks prove

Core input checks use current raw accessibility frames and real control state. They require exact text, switch/slider values, new visible rows, gesture callbacks and physical contact paths. Duo repeats coordinate and gesture paths in all seven supported display/orientation positions. The outer display does not support upside-down portrait. Selected requests also check the physical display and boot identity and reject inactive or stale targets before input.

Hinge checks include 18 ordered numeric angles, named closed/tabletop/open positions, measured discovery metadata, controls that move when the hinge changes and controls above and below the fold. Inset-window checks use the same normal app and include raw and agent input. After folding or rotation, the checks find the current element again. They do not reuse an old frame.

Held-input checks wait for actual contacts or text effects before changing the device. They require stopped old-layout input, release evidence, no later input at old coordinates and a fresh real action. They cover raw and selected touch, moving pairs, retained contacts, keys and hardware buttons in their stated cases. The held Shift+A probe checks the public library boundary. It does not prove interruption of the no-flag `key-combo` CLI command.

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

## Resources, delivery and boundaries

The matrix builds the public process probe and records CPU and memory every 15 seconds in `resources.jsonl`, starting before the Playground build. It records Codex, Device Hub, simulator services and the largest/highest-CPU processes. There is no 8 GB cap. Run heavy work one job at a time and inspect for sustained growth. Stop owned work if it runs away; preserve the evidence.

Build, signing, packaging and local installation use a separate exact-payload recipe. The current recipe uses the ordinary iPhone, which the full matrix leaves warm. It verifies archive contents, strict signatures, an unlinked installed wrapper, a real app action and complete removal/restoration. It must use the final runtime and completed build receipts. These checks do not add to 693 and do not authorise uploads, pushes, publication or deployment.

The current hosted workflow runs non-E2E checks. Local results do not prove hosted simulator coverage. Repeated cold-start stress, conditional empty-tree recovery without a reproduced fault, Intel hardware and Apple Pay payment UI are outside this run. Apple Pay hardware delivery remains in scope. The suite repeats the documented prior behaviours; it does not claim every possible app, option or new OS state.
