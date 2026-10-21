# Duo build and remaining option parity: 21 October 2026

## Result

The isolated Debug arm64 candidate built and passed 111 existing test functions in 14 suites. This includes nine copied-artifact acceptance and rejection cases. Ten public host checks passed for help output, unsupported selected options and the universal build guard. Twenty native ordinary-device actions also passed across the legacy and selected routes. No product source changed in this workstream.

These results establish the stated build, host command and ordinary portrait input paths. They do not establish full Duo coverage, a complete ordinary-device matrix, release readiness or support for the rejected options.

## Candidate and commands

- Source base: `f8bb51e9d64e87914fe020d6afff24c5c2ed2ace`.
- Worktree: `/Users/cameron/.codex/worktrees/duo-regression/AXe`, branch `codex/duo-regression`.
- CLI: `.build/out/Products/Debug/axe`, SHA-256 `a476d2aa0d62170c7223040a35f411c57851dff4b37c307a3bbc89ca9310f153`.
- FBSimulatorControl: accepted Debug arm64 binary, SHA-256 `8a614ab3116b3d0b88e21086d8a16d0f39aa06f672dd92123b7fd00e7526b779`.
- Compiler: Xcode 27.0 Release Candidate. Runtime tools: Xcode 27.2 Beta 3.
- Frameworks were copied into the worktree. The canonical frameworks and patched IDB checkout were not changed. `IDB_CHECKOUT_DIR=/Volumes/Developer/AXe/idb_checkout` supplied the exact read-only headers.
- The worktree has its own `.build`. The simulator helper was rebuilt through `AXE_BUILD_ARCHS=arm64 scripts/build.sh debug-helper`; its ad-hoc signature check passed.

The build used `swift test --arch arm64 --jobs 2`, with live E2E flags disabled. Its filter was:

```text
SelectedAXFocusTests|SelectedInputBoundaryTests|SelectedRotationTests|SelectedKeyboardTests|SelectedCompleteGestureTests|SelectedHomeTests|SelectedTapElementTypeTests|SelectedTapValueTests|SelectedTapAutomaticTests|SelectedTapPhysicalTests|SelectedTapSimulatorTests|SelectedSliderLabelTests|SelectedBatchSliderTests|BuildArtifactVerificationTests
```

All heavy commands used the coordinator's resource guard. The exact argument arrays, exit status, child cleanup, output and resource samples are saved in:

- `/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/regression-focused-checks/`
- `/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/regression-helper/`
- `/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/regression-public-boundaries-guard/`
- `/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/regression-public-boundaries/`

The focused build completed in 52.67 seconds. Its sampled peaks were 0.559 GiB for the owned command, 5.997 GiB for the app group and 2.921 GiB for all simulator processes. The last two groups include other parallel work. No guard limit stopped this command. Its child exited zero and was reaped.

## Public host checks

Run [the host verification tool](../../scripts/verify-duo-parity-boundaries.py) under the shared guard, with `--repo`, `--cli` and a new `--out` directory. It does not boot a guest or send input. It records the CLI hash, source hashes and every child command, and checks that the input files did not change.

| Check | Observed result |
| --- | --- |
| `tap`, `slider`, `batch`, `agent` help | All four exit zero with usage output. |
| Selected tap `--wait-timeout 0.1` | Exit 64 before input; polling is unsupported. |
| Selected tap `--poll-interval 0.5` | Exit 64 before input; polling is unsupported. |
| Selected slider `--value 33` | Exit 64 before input; only the endpoint route is admitted. |
| Selected batch polling | Exit 64 before execution; legacy polling settings are unsupported. |
| Agent `--input-mode selected` | Exit 64 for an unknown option. |
| Framework build with `AXE_BUILD_ARCHS="arm64 x86_64"` | Exit one at the architecture guard, before project generation or compilation. |

The unsupported-option checks use dummy device, screen and process identities. They prove parser rejection, not native failure. All ten children were reaped. The host-check wrapper had no resource stop.

## Source work still required

| Gap | Necessary work | Acceptance evidence still required |
| --- | --- | --- |
| Selected tap wait and polling | Add an explicit request contract and bounded pre-input polling. Every lookup must use fresh AX data and retain the boot, panel and process checks. Stop on context changes. Do not retry an uncertain send. | Delayed target appearance, timeout, cancellation and fold/rotation while waiting; no input before a valid target. Standalone and batch routes must agree. |
| Selected slider percentages | Add a verified numeric-target operation. Native domain conversion and tolerance already exist, but the current controller only steps toward minimum or maximum. A discrete slider may not reach an arbitrary value such as 33 percent. | Reachable values, unreachable values, wrong target/domain, cancellation and stale context. Read back the actual stable value. Do not silently use the legacy drag correction. |
| Agent selected execution | Connect the agent's observation and action boundary to explicit screen identity and the guarded selected routes. Current agent actions use the legacy HID session. Keep unrelated agent work separate. | Fresh selection after layout changes, exact target and focus checks, interruption and no replay, through the normal agent boundary. |
| Universal and release packaging | Provide and validate the other architecture's private bridge inputs and all dependent module artifacts before changing the current guard. Refresh distribution interfaces and validate the complete staged payload. | Both architecture slices, private export rejection, helper inclusion and startup from the staged payload. Signing, notarization and publication remain separate release work. |

Existing selected batch routing is implemented for the admitted complete operations. More batch cases are verification work unless a reproducible failure identifies a source defect. Whole-batch exclusion, retained touch tokens and semantic press are not current selected batch features.

## Native regression status

Twenty native actions passed on the exact CLI and framework candidate above. Each ordinary device ran alone in this workstream; the coordinator also allowed one Duo control workstream. The iPhone was shut down before the iPad booted.

| Device | Runtime and measured pose | Legacy actions | Selected actions |
| --- | --- | --- | --- |
| iPhone 18 Pro, `098FE01B-F022-4F1F-A00A-2D398BB77346`, PID 76468 | iOS 27.2, portrait, 402 by 874 logical points, screen 1, scale 3 | Find and tap the Button; swipe its TouchPad through 80 points; focus the TextField; type `a`; Return | The same five actions, with explicit screen UUID and process checks; type `b` |
| iPad mini (A17 Pro), `36B2A185-B110-4FFF-95EE-9357846E39DF`, PID 80548 | iOS 27.2, portrait, 744 by 1133 logical points, screen 1, scale 2 | The same five legacy actions | The same five selected actions |

Each device had two real Button callbacks and exact text changes from empty to `a` to `ab`. Every accepted swipe produced its complete observed 80-point path and one completed pan callback. Twelve accepted touch contacts ended, and both devices finished with zero held touches and the field unfocused. Every operation read a fresh AX tree and bound the published fixture state to the actual app container and PID. Selected operation contexts matched before, during and after input. Touch endpoints were within 0.5 logical point of the fresh AX geometry. Keyboard checks prove effects and local delivery; they do not inventory held keys inside the OS.

The new driver initially expected the swipe recognizer translation to equal the entire 80-point touch path. UIKit began recognition after the first 10 points, so it reported 70 points. The first iPhone legacy swipe therefore failed its driver assertion after fully delivering and releasing. That failed result is preserved; later actions did not run. The corrected driver checks the full contact path, the completed recognizer and its observed translation. One explicit new legacy swipe passed before proceeding. No uncertain input was replayed and no product code was changed. Both driver versions and their pins remain saved.

Native tools and raw evidence:

- [One-action native driver](../../scripts/verify-ordinary-input.py), with explicit `--mode`, `--case`, device/PID/state path and selected display identity. It never resets or injects fixture state.
- `/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/regression-main-result.json`: 20 accepted cases, 111 focused checks and 10 host cases.
- `regression-iphone-legacy-swipe/`: original failed driver assertion. `regression-iphone-legacy-swipe-v2/`: separate accepted action.
- `regression-native-tool-pins.json` and `regression-native-tool-pins-v2.json`: exact CLI, helper, four runtime frameworks, driver, guard and probe hashes.
- Replay-free cohort check: `/usr/bin/python3 -B build_products/verification/parallel-duo-20261021/verify-regression-evidence.py build_products/verification/parallel-duo-20261021 /Users/cameron/.codex/worktrees/duo-regression/AXe`. It passed against the actual binaries and saved raw callback, contact, AX and process records. It sends no input.

The coordinator replaced slow `top`/`ps` process scans with a separately verified public `libproc` physical-footprint and CPU probe before native input. Revised guard SHA-256: `1c555defcb55ba1ee444968fbe47fcf12bfa832f7d63554edd6d55ded59e4605`. Native caps remained 8 GiB for the app group, 10 GiB for all simulators and 4 GiB for the owned command, with the same sustained CPU limits. Historical monitor failures in the other workstreams are not regraded.

C native input phases sampled at most 8.392 GiB for the shared simulator group. The earlier offline duplicate preparation observed 9.747 GiB while both Duo workstreams ran. Across C command records, the app group peaked at 6.860 GiB and owned commands at 0.559 GiB. No C resource stop occurred. Both C guests were shut down and their absence was confirmed in the final booted catalogue. That catalogue still contained the other workstream's Duo. The final C sample was simulator 3.987 GiB / 16.5 percent CPU and app 6.509 GiB / 16.6 percent CPU. These are shared sampled values, not performance guarantees.

Other ordinary profiles, orientations, roles, options, media, cancellation and complete release packaging remain outside this proof. Earlier ordinary-device records retain their original candidate and pose limits.

## Limits

The accepted framework record states `PUBLIC_TEXT_INTERFACES=PREEXISTING_NOT_REFRESHED_DEBUG_COMPILED_MODULES_USED`. Passing the copied-artifact checks does not prove that every distribution interface was rebuilt. The universal guard is intentional and remains in force. No universal build, notarization or release was attempted.

No central checklist, changelog, skill source, agent source or library source was changed in this workstream. Security scanning remains **UNVERIFIED**, as Cam requested. No push occurred.
