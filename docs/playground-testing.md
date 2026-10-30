# Repeatable simulator checks

The Playground is a normal app. Swift Testing calls the real AXe CLI and checks app state, accessibility, contacts and callbacks after real input. XCUITest does not send the input. The app has no injected test state.

## Current acceptance — 30 October 2026

| Current isolated candidate check | Actual result |
| --- | --- |
| Complete ordinary iPhone 133 | [PASS: 133/133](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-iphone/acceptance.json), zero issues/skips; 1966.75 seconds. |
| Complete Duo 133 | [PASS: 133/133](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-duo-agent/acceptance.json), zero issues/skips; 2620.14 seconds. |
| Layout 12 | [PASS: 12/12](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-duo-interruptions/acceptance.json), zero issues/skips. |
| Raw keyboard 4 | [PASS: 4/4](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-duo-raw-keyboard-interruptions/acceptance.json), zero issues/skips. |
| Keyboard and slider unit checks | [PASS: 24/24](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-host-unit/acceptance.json), zero issues/skips. |
| Original precision-slider case | [PASS: 1/1](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-duo-slider-from-maximum/acceptance.json); real value 63.273453, zero contacts. |

CLI `ddca4cc6` / native `a42360f5`, source `becb4de5` / host `da5bcfb7`. Native transport/feed 18 and legacy keyboard 9 passed as separate host groups. The separate [actual popup/Escape/Button proof](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/public-typing-popup-escape-proof-v3/run-v1/acceptance.json) adds no suite cases. Each 133 row is one complete run; the focused and host groups add no cases to it.

Keep the native three-second read limit, input/release bounds, slider 15-second limit, 1.5-second release reserve, 0.07 tolerance and 60-second reference expiry. Fixture state waits use fresh read-only attempts before input or after confirmed release; each failed read is saved. A layout write is not repeated. The [audit](audits/2026-10-29-keyboard-reliability.md) retains failed runs and the original safety links. The [local arm64 ZIP roundtrip](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-local-install-v3-plan/zip-roundtrip-v1/inventory.json) preserved all 149 files, 22 links and 49 directories; seven strict signature checks passed. This is not a public release or installation. Commit, local install and installed-image checks remain pending.

## Earlier isolated-candidate record — superseded

The prior record below is retained; the current acceptance above governs the result.

### Previous candidate details

Isolated candidate: CLI `8a994931` / native `553acba2`, selected wire 36. The [signed payload](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/runtime-ready.json) passed seven strict signature checks. FINAL7 changes one production file from FINAL6 to refuse input when all broker request slots are full. Source checkpoints and delivery have separate receipts; no release acceptance is claimed. Earlier FINAL5/FINAL6 results below use CLI `a9f3d8c1`; they are not new-candidate full passes.

| Check | Result | Test source / host | Evidence |
| --- | --- | --- | --- |
| Complete ordinary-iPhone agent run | **133 passed; zero issues or skips** | FINAL5 `eaf6f6f8` / `9b8dd89a` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-iphone-full-v1/result.json), 2002.62 seconds |
| Amended ordinary checks | **1 + 6 + 1 passed; zero issues or skips** | FINAL6 `b506332f` / `baeea9a1` | [Reference recovery](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-iphone-raw-mutation-v1/result.json), [concurrent input](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-raw-admission-v1/result.json), [held touch](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-raw-keyboard-ownership-v1/result.json) |
| Amended Duo reference recovery | **1 passed; zero issues or skips** | FINAL6 `b506332f` / `baeea9a1` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-duo-raw-mutation-v1/result.json) |
| Complete Duo agent run v1 | **Failed: 132 clean cases; 1 failed; zero skips** | FINAL6 `b506332f` / `baeea9a1` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-duo-full-v1/result.json), 2557.88 seconds |
| Duo typing after service recovery | **8 passed; zero issues or skips** | FINAL6 `b506332f` / `baeea9a1` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-focused-after-service-recovery-v1/result.json), 160.47 seconds |
| Complete Duo repeat after service recovery | **Failed: 129 clean cases; 4 failed; zero skips** | FINAL6 `b506332f` / `baeea9a1` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-duo-full-v2/result.json), 2512.05 seconds |
| FINAL7 host checks | **186 passed; zero issues or skips** | FINAL7 `ea9f7785` / `527051ef` | Six disjoint groups, linked below |
| FINAL7 request-capacity check | **SAFE_BUSY_REFUSAL; physical recovery passed** | FINAL7 `ea9f7785`; standalone CLI proof | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/saturation-v1/result.json), 14.2 seconds |
| FINAL7 concurrent input and held-touch ownership | **6 + 1 passed; zero issues or skips** | FINAL7 `ea9f7785` / `527051ef` | [Admission6](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-raw-admission-v1/result.json), [ownership1](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-raw-keyboard-ownership-v1/result.json) |
| FINAL7 complete simulator acceptance | **Not accepted; no new complete full run** | FINAL7 `ea9f7785` / `527051ef` | Strict full133 gates remain open |

The failed runs remain separate. FINAL6 full v1 failed one stdin AX focus admission before input (`DTXProxyChannel Code 1`,0 events, `cleanup=notNeeded`, no replay). Its [first eight-case repeat](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-focused-after-dtx-v1/result.json) passed 3 and failed 5 during setup. The [unchanged group passed 8/8 after service recovery](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-focused-after-service-recovery-v1/result.json). Full v2 then failed rotation preparation before dispatch and three display-catalogue preparations. Neither full run recorded a resource stop or crash; the original HID keyboard-startup timeout did not recur. No passing complete Duo run is accepted.

A [direct Apple display query timed out](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/dtx-device-catalogue-fault-v1/result.json), then [passed in 0.13 seconds](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/dtx-device-catalogue-fault-v2/result.json) without a restart. FlowDeck pose/AX, RocketSim hinge and sim-use AX reads passed in that interval; those read-only results do not prove equivalent input admission. Saved [motion accounting](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-diagnostic-v1/guest-motion-accounting.json) shows 17.88-second AXe and 21.68-second RocketSim completion delays and older invocation traffic. Their cause is unproved. The source checkpoint keeps native `553acba2`. A separate native-only candidate `c946160e`, with the same CLI `8a994931`, passed an [actual public hinge-read proof](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-v1/actual-library-proof-v1.json). Its serving process loaded the exact new library. The guest received the cancel reply, stopped angle updates and completed the original request before the connection closed. This one observed order does not prove the cause of the earlier long delays or full resource release for every request. The unchanged [typing8](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-type-v1/result.json), [typing-to-drag1](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-drag-v1/result.json) and [layout2](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-layout-v1/result.json) checks passed on this native library, with no issues or skips. The [nine existing native host checks passed](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-v1/native-host9-v1/acceptance.json), with the new library proved in the loaded-image trace. One new complete Duo133 run is in progress; no result is accepted yet. The native candidate is not integrated or accepted as a full Duo pass.

The [actual ninth-client reproduction](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/selected-broker-saturation-proof-v1/run-v2/result.json) proved delayed first input after the active owner ended. FINAL7 sends a terminal busy response before it reads that client's request body. The [same physical check on the fix](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/saturation-v1/result.json) passed in 14.2 seconds: no ninth-client text, joined owner release, two quiet seconds, then fresh text and one released Button tap. This proves the isolated capacity fix; it is separate from the keyboard connection-startup fix and is not a full-suite or current-main simulator pass.


FINAL7 host checks passed 186 distinct cases with zero issues or skips: [broker/lifetime67](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-unit-v1/result.json), [input boundary63](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-boundary-v1/result.json), [legacy keyboard12](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-legacy-keyboard-v1/result.json), [transport routes11](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-transport-routes-v1/result.json), [rigid schema20](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-rigid-schema-v1/result.json) and [display discovery13](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-display-discovery-v1/result.json). Source `ea9f7785` and host `527051ef` are bound to CLI `8a994931` / native `553acba2`. The [nine native host checks](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/keyboard-startup-native-host-v2/root-acceptance.json) remain separate.

The [earlier FINAL5 Duo run](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-duo-full-v1/result.json) executed 133 cases and failed one recovery tap on a control outside its visible scroll area. Its unchanged repeat reproduced that fixture error. Three test-only corrections also updated the exact busy-error assertions. The nine focused passes above remain separate results. They do not change the failed full run or create a new ordinary-iPhone full pass. The [keyboard audit](audits/2026-10-29-keyboard-reliability.md) keeps the failures and exact receipts.

The [keyboard audit](audits/2026-10-29-keyboard-reliability.md) records the exact connection-reuse, text-source, modifier/cancellation, long-text and fold/rotation proofs. The [source checkpoint is applied](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v1/receipt.json), and the [main compile passed](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v1/compile-only.json). These results do not change the failed full Duo runs or prove an installed-candidate pass.

Use the [guarded repeat commands](agent-mode-persistence.md#repeat-the-candidate-checks) with the FINAL7 full-package host and its signed runtime. No current-candidate full run is accepted. The ordinary and Duo `PlaygroundAgent` filters each require 133 completed cases. The separate raw long-text and keyboard-interruption groups do not add to 133.

The source registries describe planned coverage. Direct-suite registration remains 19 ordinary cases and 12 Duo cases; it does not prove those commands ran. The nine focused cases above are the actual amended checks. They do not create a combined direct-suite or full-suite pass.

The 133-case agent group does not test every action in every Duo screen and orientation. No live foreign-user-ID injection was performed. The `postActionRefreshFailed`, `postActionRefreshQuarantined` and `batchRefreshFailed` branches were not separately forced on this hardware; source and host checks do not prove those live branches. These are evidence limits, not missing core commands. Apple Pay payment screens and Intel execution are excluded. Cold-start stress and unreproduced empty-screen recovery stay deferred.

The sections below retain earlier evidence and tracked runner instructions. Their historical counts are not current full-suite results.

## Earlier acceptance

The earlier full plan was **693 case executions across 90 suite runs and 66 Swift sources**: iPhone 165, iPad 23 and Duo 505. These figures describe that earlier plan; **there is no full-suite pass**. The current source has five native-state cases instead of four and one typing-to-drag case on both iPhone and Duo. This gives 697 planned matrix cases by calculation only. The new raw long-text case below adds one planned Duo case, for a calculated total of 698. This is not a test result. The extra direct checks below are separate from that matrix.

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

The [saved command receipt](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v3-keyboard-hardware-off-v1-guard/result.json) records this public command on the audit Duo. Its reply had `success: true` and `enabled: false`. That reply does not establish the previous setting or prove that the software keyboard is now visible; focus the field and check the screen.

Use normal simulator controls. Do not inject app state, guess stored preferences, force detector output or relax tests to prepare the device. A prerequisite change and a passing focused repeat do not change an earlier failed full-run result.


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

## Reference and raw-input follow-up checks

These checks use the full AXe Swift package through `test-runner.sh`. The four new direct-suite sources are registered separately from the matrix source list. The raw suites import AXe internals and must not be copied into the matrix standalone package.

| Direct suite | Cases | Device |
| --- | ---: | --- |
| `PlaygroundAgentLifecycleTests` | 6 | iPhone or Duo |
| `PlaygroundAgentBrokerRestartTests` | 1 | iPhone or Duo |
| `PlaygroundRawKeyboardBrokerTests` | 1 | Ordinary iPhone |
| `PlaygroundRawInputAdmissionTests` | 6 | Ordinary iPhone |
| `PlaygroundAgentNativeStateTests` | 5 | iPhone or Duo |

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

## Resources, delivery and boundaries

The matrix builds the public process probe and records CPU and memory every 15 seconds in `resources.jsonl`, starting before the Playground build. It records Codex, Device Hub, simulator services and the largest/highest-CPU processes. There is no 8 GB cap. Run heavy work one job at a time and inspect for sustained growth. Stop owned work if it runs away; preserve the evidence.

Build, signing, packaging and local installation use a separate exact-payload recipe. The current recipe uses the ordinary iPhone, which the full matrix leaves warm. It verifies archive contents, strict signatures, an unlinked installed wrapper, a real app action and complete removal/restoration. It must use the final runtime and completed build receipts. These checks do not add to 693 and do not authorise uploads, pushes, publication or deployment.

The current hosted workflow runs non-E2E checks. Local results do not prove hosted simulator coverage. Repeated cold-start stress, conditional empty-tree recovery without a reproduced fault, Intel hardware and Apple Pay payment UI are outside this run. Apple Pay hardware delivery remains in scope. The suite repeats the documented prior behaviours; it does not claim every possible app, option or new OS state.
