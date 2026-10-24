# Repeatable simulator checks

The Playground is a normal app. These checks drive the built AXe CLI and read the resulting app state through accessibility. They do not inject app state or replace native input with a mock.

## Build inputs

`AxePlaygroundApp/project.yml` is the tracked XcodeGen definition. The generated Xcode project stays in `build_products`. Install XcodeGen before running the checks.

Use a built AXe payload with its matching frameworks and helper. The runner records every payload file hash and symbolic link, selected Xcode, app source hashes, test source hashes, commands, and results. It requires the payload to remain unchanged. It does not rebuild AXe or establish that an arbitrary executable matches the current checkout.

For the interruption checks, the runner builds `scripts/fixtures/DuoExternalStateChange.swift` against the supplied AXe frameworks. It uses the selected Xcode and `idb_checkout/PrivateHeaders` by default. Set `AXE_TEST_HOST_DEVELOPER_DIR` if those frameworks need a different host compiler. Set `AXE_TEST_IDB_SOURCE` to the matching IDB source checkout if it is elsewhere. The runner records both directories, header hashes, source hash, and built tool hash. Missing inputs cause a clear failure; the runner does not select another compiler or runtime.

## Run the same checks on iPhone and Duo

Use two dedicated, available simulators. Prefer devices that are already running. The runner uses them one at a time and leaves both running. If a supplied device is shut down, the runner boots it and waits until it is ready. It does not create, erase, or delete a device. Cancellation stops owned commands; it does not shut down a device that was already running before the check.

```sh
PATH="/opt/homebrew/bin:$PATH" python3 scripts/test-playground-matrix.py \
  --axe /absolute/path/to/payload/axe \
  --iphone IPHONE_UUID \
  --duo DUO_UUID \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --output build_products/playground-results/NEW_RUN
```

The default `--suite all` runs 47 checks: 13 on iPhone and 34 on Duo. Use `--suite core` for the original eight core checks on each device, `--suite agent` for the optional interface, or `--only duo --suite duo` for the 30 Duo-specific checks.

| Suite | Ordinary iPhone | Duo |
| --- | --- | --- |
| Core controls | 8 checks in the current orientation | 16 checks: the same eight features on the outer display in portrait and the open inner display in landscape |
| Hardware keyboard input | 1 check | 2 checks: one on each measured display and orientation |
| Optional agent interface | 4 checks | 4 checks |
| Duo hinge, rotation and display selection | — | 6 checks |
| Input interrupted by folding or rotation | — | 6 checks |

The full Duo run uses the 16 checks with explicit display and orientation requirements. It does not repeat the eight generic core checks. `--suite core` retains the generic checks for a narrow compatibility run.

Use `--only iphone` or `--only duo` while fixing a failure. Such a run proves only that device. The output directory must be new, so an earlier failure cannot be replaced by a later result.

The app and exact tracked test sources build once. A separate Swift Testing package under the result directory uses the existing CLI helpers. It has no third-party dependencies. The normal AXe test target also includes these test sources.

## Core checks

| Check | Required app result |
| --- | --- |
| Find and tap | Discover the button by its ID; its value changes from Initial to Tapped. |
| Type | Discover and focus the field; typed text and character/word counts match. |
| Scroll | A row outside the initial visible range becomes visible and can be selected. |
| Swipe | The app records one right swipe and both requested points. |
| Drag | The app records the start, an intermediate move, and release at the requested end point. |
| SwiftUI switch | The app records Off, On, then Off. |
| UIKit switch | The app records Off, On, then Off. |
| Slider | AX and the app's exact value both reach 75% and 40% within the stated tolerance. |

Keyboard checks focus a real field, send keys, use Backspace, hold Shift for a capital letter, and use Command+A to replace the selected text. Each step checks the resulting app text. Duo runs this check on both measured display configurations.

The runner requires the exact expected count for each suite, with no failures or skips. A disabled suite or zero executed checks is a failure. The result lists each check and its result, including failures from a nonzero test command. Full logs and Swift Testing XML stay in the result directory. A failed check is not retried automatically.

Both runners read the expected counts from `scripts/playground-suite-counts.json`. Update that file when the tracked suite gains or loses a check.

The matrix runner is the full acceptance entry point. The existing `test-runner.sh` also accepts each named suite for a narrow check. Its `--tests-only` mode requires that the native AXe test target and current Playground app are already built and installed. For example:

```sh
AXE_BIN_PATH=/absolute/path/to/payload/axe \
SIMULATOR_UDID=DUO_UUID AXE_DUO_E2E=1 \
AXE_DUO_STATE_CHANGE_PATH=/absolute/path/to/previous-matrix-run/duo-external-state-change \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./test-runner.sh --tests-only PlaygroundDuoInterruptionTests
```

The direct interruption filter fails before simulator work if the state tool is absent. The state tool must match the supplied AXe runtime. A direct filter does not replace the full matrix result.

## Agent checks

| Check | Required app result |
| --- | --- |
| Compact capture and cache reuse | RS/1 output has valid rows; an unchanged capture reuses its snapshot without changing app values; raw output stays raw. |
| Saved reference | A saved button reference changes the actual button value. |
| App relaunch | The old reference is rejected without input; a fresh reference changes the relaunched app. |
| Changed app layout | The old reference is rejected without input; a fresh reference changes the new control. |

## Duo checks

| Check | Required app result |
| --- | --- |
| Hinge controls | Closed, partly open, and fully open positions each permit a fresh lookup and a real button tap. |
| Inner display rotations | A fresh lookup and button tap work in all four supported rotations. |
| Outer display rotations | A fresh lookup and button tap work in all three supported rotations. Upside-down portrait is not a supported outer-display position. |
| Fold with a saved reference | The old reference is rejected without input; a fresh reference changes the app on the active display. |
| Rotate with a saved reference | The old reference is rejected without input; a fresh reference changes the rotated app. |
| Inactive display | Input to the inactive display is rejected before input; a fresh tap on the active display changes the app. |

The six interruption checks cover a held touch, a moving drag, and a moving pinch. Each gesture runs once with a fold and once with a rotation. The app must observe the contact or contacts before the change, then observe all contacts released or cancelled with no later move at the old coordinates. A fresh lookup and button tap must work after the change. These checks use the Playground's visible touch-monitor screen and an external state-change tool; AXe sends the gestures being checked.

Each suite receives its own artifact directory under the result directory. Interruption receipts, command output, and app observations stay there for review. Do not count a source-only addition as a passed simulator check.

## Scope limits

The core suite alone does not prove every fold angle, rotation, selected-screen path, held-input interruption, or optional agent action. Existing audit receipts remain separate from a new run. The suite covers the cases listed above; do not use the test count as a claim that every AXe command has been checked.

The current hosted CI workflow runs non-E2E checks. A local matrix result does not prove hosted CI simulator coverage.

The runner builds the tracked public-process probe and records CPU and memory every 15 seconds in `resources.jsonl`. Sampling starts before the Playground build. The log includes Codex, Device Hub, simulator services, the five largest processes, and the five processes with the highest CPU use. It does not enforce the old 8 GB limit. Inspect the log during native work. Run one heavy build or simulator job at a time. Stop owned test work if a process has a sustained resource increase; do not terminate unrelated apps or devices.

Apple Pay payment-screen testing is excluded. Local package verification does not authorise publishing or deployment.
