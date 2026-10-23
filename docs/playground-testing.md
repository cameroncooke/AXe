# Repeatable simulator checks

The Playground is a normal app. These checks drive the built AXe CLI and read the resulting app state through accessibility. They do not inject app state or replace native input with a mock.

## Build inputs

`AxePlaygroundApp/project.yml` is the tracked XcodeGen definition. The generated Xcode project stays in `build_products`. Install XcodeGen before running the checks.

Use a built AXe payload with its matching frameworks and helper. The runner records the CLI SHA-256, selected Xcode, app source hashes, test source hashes, commands, and results. It does not rebuild AXe or establish that an arbitrary executable matches the current checkout.

## Run the same checks on iPhone and Duo

Use two dedicated, available, shut-down simulators. The runner uses them one at a time and shuts down each device after its check. It does not erase or delete a device.

```sh
PATH="/opt/homebrew/bin:$PATH" python3 scripts/test-playground-matrix.py \
  --axe /absolute/path/to/payload/axe \
  --iphone IPHONE_UUID \
  --duo DUO_UUID \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --output build_products/playground-results/NEW_RUN
```

Add `--suite all` to run core and agent checks on both devices, plus hinge/rotation checks on Duo. Use `--suite agent` to check only the optional interface, or `--only duo --suite duo` for the Duo controls.

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

The runner requires all eight core test results, with no failures or skips. A disabled suite or zero executed checks is a failure, not native proof. Full logs and Swift Testing XML stay in the result directory.

## Scope limits

The core suite alone does not prove every fold angle, rotation, selected-screen path, held-input interruption, or optional agent action. Those need their own native results. Existing audit receipts remain separate from a new run.

The current hosted CI workflow runs non-E2E checks. A local matrix result does not prove hosted CI simulator coverage.

Check CPU and memory during native work. Run one heavy build or simulator job at a time. Stop owned test work if a process has a sustained resource increase; do not terminate unrelated apps or devices.

Apple Pay payment-screen testing is excluded. Local package verification does not authorise publishing or deployment.
