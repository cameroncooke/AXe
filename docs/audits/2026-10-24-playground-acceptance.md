# Playground acceptance: 24 October 2026

## Current result

**FAIL: matrix v5 executed all 47 cases: 35 passed and 12 failed, with no skips or missing cases. Full acceptance remains open.** All 13 ordinary-iPhone cases passed. Duo core passed 17/18 and Duo agent passed 4/4; outer Backspace timed out at the guest barrier. Layout passed 1/6 and interruption passed 0/6. The failed inner-rotation case first tapped successfully at 180 and 270 degrees, then its next fresh AX read disconnected; the whole case remains failed. The other four failed layout cases stopped before their next action. All six interruption gestures failed before input. Zero input events apply to the failed commands, not the whole rotation case. The cause of the connection loss is unresolved; the key timeout does not establish that cause. Earlier targeted passes remain separate. The current Release package passed local installation and real app input. A separate keyboard safety proposal remains isolated and unproved after unchanged typing failed before the new key route ran.

The tracked suite now has **50 cases** at test checkpoint `b45a60e2`. Three added legacy coordinate-tap checks passed separately on ordinary iPhone, Duo outer portrait and Duo inner landscape. The full v5 result remains 35/47; no full 50-case run or pass is claimed.

The production Release code checkpoint is `9c383e1b`: CLI SHA-256 `5bd0e336899673f542a1f9b559547807fec8c3ca9cd9f5ca0a4208c19a1945f2` and FBSimulatorControl SHA-256 `c3f11c9d54dee8356cb44d8bab1486533376743ddc9c774c478157722457f7fe`. App, test and runner changes are committed through `b45a60e2adc28ae17dc8e0ca621dc4ff866cb0b7`. Full matrix v5 used `0e62b532`; `b45a60e2` adds the three separately passed coordinate-tap cases. Earlier checkpoints are `20e4ef51`, `187709bc` and `3bef853f`. No production CLI or library change was made for these test corrections.

[Final full-run result](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v5/result.json), [resource guard](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/guard-matrix-v5/result.json), [protected work snapshot](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/protected-before.json).

## What the suite checks

The table records the 47-case v5 result. Current source adds three raw coordinate taps, for 50 cases: 14 on ordinary iPhone and 36 on Duo. Nine core checks cover the same eight features because tapping has separate selector and coordinate checks.

Duo support covers finding and using controls on the active screen, choosing a screen, changing the hinge and rotation, stopping old input when the device changes, and finding the control again.

The optional agent interface is a separate improvement from the SimUse audit. It provides compact output, saved control references and cached screen reads, and rejects references after an app or layout change. Cam chose an XcodeBuildMCP-style interface. Existing raw output and coordinate commands remain available.

| Device and feature | Expected cases | Required evidence | Matrix v5 |
|---|---:|---|---|
| Ordinary iPhone core input | 8 | Find/tap, type, scroll/select a new row, swipe coordinates, drag movement/release, both switch types, Slider 75% then 40% with app/AX values | 8 passed |
| Ordinary iPhone keyboard | 1 | Exact Backspace, Shift+A and Command+A edits, followed by new text | 1 passed |
| Ordinary iPhone agent mode | 4 | Compact output, raw compatibility, cache reuse, saved-reference tap and refusal after app/layout change | 4 passed |
| Duo core input and keyboard | 18 | The eight core features and keyboard edits on closed outer portrait and open inner landscape | 17 passed; outer Backspace timed out; both Slider cases passed |
| Duo agent mode | 4 | The same agent checks on Duo | 4 passed |
| Duo controls and layout | 6 | Named hinge positions; real Button taps in four inner and three supported outer orientations; old-reference refusal and fresh tap; inactive-screen refusal | 1 passed; five failed; inner rotation includes partial tap evidence |
| Duo input interrupted by fold or rotation | 6 | Held single touch, moving drag and moving pinch: actual contact release, no late input, fresh lookup and real Button tap | 0 passed; acquisition failed before gesture input |
| **Total** | **47** | No failures, skips or missing cases required for acceptance | **35 passed, 12 failed; no skips or missing cases** |

The three added cases read the fresh raw accessibility Button frame, tap its centre with only `tap -x X -y Y --udid UUID`, and require the real app value to change from Initial to Tapped. No agent, selector or selected-display input option is used. [Three-case result](/Volumes/Developer/AXe/build_products/verification/playground-acceptance-20261024/legacy-coordinate-tap-v1/focused-result.json).

Swift Testing runs the macOS driver. It calls the public AXe CLI and reads real app results. It does not use XCUITest to send touches. No separate manual actions are needed to repeat these listed cases.

The visible Touch Monitor page records real UIKit contact IDs, movement, end/cancel events and active contact count. Its bounded log is `Documents/touch-monitor.json`. The suite waits for actual contacts or movement before changing the device. It checks the native release receipt, the app log and absence of late input, then reads the new controls and taps the Button again. The tracked external state tool models a user folding or turning the simulator. It sends no touch input and does not take AXe's input lock. No hidden app state or production test route is used.

## Repeatable local command

The runner builds and installs the Playground, then runs the suites in sequence on the named devices. It reuses the existing devices and records case names, counts, results, source hashes and CPU/memory samples. Use a new output directory for each run; failed results are not replaced by later attempts.

The completed 47-case matrix v5 command was run at `0e62b532`. Current source uses the same entry point for 50 cases; supply a new output directory when running it again:

```sh
env PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  AXE_TEST_HOST_DEVELOPER_DIR=/Applications/Xcode-27.0.0-Release.Candidate.app/Contents/Developer \
  AXE_TEST_IDB_SOURCE=/Volumes/Developer/AXe/build_products/verification/direct-ax-default-20261023/slider-minimal-universal-release-v3/idb-source \
  /usr/bin/python3 -B /Volumes/Developer/AXe/scripts/test-playground-matrix.py \
  --axe /Volumes/Developer/AXe/build_products/verification/direct-ax-default-20261023/slider-minimal-universal-release-v3/runtime-release-v3/axe \
  --iphone 098FE01B-F022-4F1F-A00A-2D398BB77346 \
  --duo 18C664CE-4A72-4CC6-8DA4-91BC7D8AFCB9 \
  --developer-dir /Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer \
  --output /Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v5
```

The default is `--suite all`. See [Playground test instructions](../playground-testing.md) for normal use and required local inputs.

## Retained attempts

| Attempt | Result | Evidence and limit |
|---|---|---|
| Matrix v1 | Build failed; all 47 cases not executed | App and state operator built; three Swift Testing macro errors stopped the checks build. [Result](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v1/result.json). |
| Matrix v2 | 47 executed: 44 passed, 3 failed, no skips or missing cases | iPhone 13/13; Duo core 17/18; Duo layout 6/6; Duo agent 4/4; interruption 4/6. Test drag bounds and pinch movement observations failed. [Result](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v2/result.json). |
| Focused correction run | 8 executed: 7 passed, 1 failed | Ordinary drag and corrected inner drag passed. Interruption passed 5/6, including both pinch changes; drag/fold failed before input because the measured display did not settle in the existing ten-second preparation window. [Interruption result](/Volumes/Developer/AXe/build_products/verification/playground-acceptance-20261024/focused-recipe-v1/duo-interruptions-result.json), [guard](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/guard-focused-v1/result.json). |
| Matrix v3 | 41 completed case results: 38 passed, 3 failed, no skips; 6 without completed case results (`notExecuted: 6` in the runner) | iPhone 13/13; Duo core 15/18; layout 6/6; agent 4/4. Interruption actions did start and three release/callback artifacts exist, but XML was incomplete after its test helper hung. [Result](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v3/result.json). |
| Diagnostic checks on Duo I | 9 cases: 1 passed, 8 failed | Outer tap passed. Outer keyboard hit a post-send guest barrier timeout with uncertain cleanup. The saved quarantine rejected the later cases before input; they did not exercise the async-wait helper change. [Quarantine](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/quarantine-after-keyboard-20261024.json), [guard](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/guard-diagnostics-async-v1/result.json). |
| Targeted checks on existing Duo H | 9/9 passed | Outer tap, outer keyboard, inner keyboard and all six interruption cases passed with the same Release and corrected test sources. This is a targeted result, not a full 47-case result. [Tap](/Volumes/Developer/AXe/build_products/verification/playground-acceptance-20261024/diagnostics-on-duo-h-v1/outer-tap-result.json), [outer keyboard](/Volumes/Developer/AXe/build_products/verification/playground-acceptance-20261024/diagnostics-on-duo-h-v1/outer-keyboard-result.json), [inner keyboard](/Volumes/Developer/AXe/build_products/verification/playground-acceptance-20261024/diagnostics-on-duo-h-v1/inner-keyboard-result.json), [interruption](/Volumes/Developer/AXe/build_products/verification/playground-acceptance-20261024/diagnostics-on-duo-h-v1/duo-interruptions-result.json). |
| Matrix v4 on warm Duo H and iPhone J | 47 executed: 44 passed, 3 failed, no skips or missing cases | iPhone 13/13; Duo core 16/18; layout 6/6; agent 4/4; interruption 5/6. The outer tap changed the app successfully but launch changed the measured rotation. Inner Slider refused before input for insufficient release/readback reserve. Pinch/rotation released the contacts, then fresh selected input failed before input after the AX acquisition channel disconnected. [Result](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v4/result.json). |
| Post-launch correction checks | Build/install passed; 5/5 checks passed, no skips | Outer tap, inner drag, both keyboard cases and inner Slider passed after test-only display checks moved after app launch. No runtime, timeout or production change was made. [Result](/Volumes/Developer/AXe/build_products/verification/playground-acceptance-20261024/post-launch-orientation-v1/focused-result.json), [guard](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/guard-post-launch-v1/result.json). |
| Matrix v5 on warm Duo H and iPhone J | 47 executed: 35 passed, 12 failed, no skips or missing cases | iPhone 13/13; Duo core 17/18, layout 1/6, interruption 0/6 and agent 4/4. Outer Backspace hit a guest barrier timeout. The inner-rotation case tapped at 180 and 270 degrees, then lost its next AX read; it remains a failed case. The other four failed layout cases stopped before their next action. All six interruption gestures failed before input. Zero events apply only to the failed commands. No cause is established between these failures. [Result](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v5/result.json). |
| Three legacy coordinate taps | 3/3 passed | Ordinary iPhone, closed Duo outer portrait and open Duo inner landscape each changed the real Button after a fresh raw-frame coordinate tap. The same Release payload was used; the current default count is now 50. This is separate from the failed full 47-case run. [Result](/Volumes/Developer/AXe/build_products/verification/playground-acceptance-20261024/legacy-coordinate-tap-v1/focused-result.json), [guard](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/guard-coordinate-tap-v1/result.json). |
| Isolated keyboard candidate build | Build/sign passed for both host architectures; first verification failed | The first verification expected the old generated version label. A metadata-only continuation corrected the expected label against generated Git metadata, then checked the exact four source postimages and existing payload. It passed without rebuilding. [Original failure](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/keyboard-cleanup-proposal-v1/build-output/result.json), [continuation](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/keyboard-cleanup-proposal-v1/metadata-continuation-v1/output-v1/result.json). |
| Isolated keyboard candidate native checks | 2 of 3 cases executed: 1 passed, 1 failed; inner case not run | iPhone keyboard passed. Duo outer failed in unchanged `type "AXe keys 123"` with a guest barrier timeout and uncertain cleanup; quarantine was saved. The new Key/Combo route did not run, no input was replayed and the candidate was not rolled into main. [Result](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/keyboard-cleanup-proposal-v1/native-output-v1/result.json), [failed app check](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/keyboard-cleanup-proposal-v1/native-output-v1/duo-outer-keyboard-swift-testing.xml). |

The drag test used a raw Application root frame of 669×951 while the active inner display was 951×669. Its old endpoint Y 761 was out of bounds. AXe refused before input with zero events and `notNeeded` cleanup. A native read found the visible control frame at (0,82,867,553). The corrected test uses start (347,386) and end (347,524), keeping the actual start/movement/release checks. [Native frame diagnosis](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/drag-frame-proof-v1/finding.json).

The first pinch observation poll threw at exactly two points of movement before the external change. That did not establish a gesture-interruption failure. Corrected pinch fold and rotation checks then passed with actual release and fresh Button input.

Matrix v3 stopped in Foundation `Process.waitUntilExit` after the child had exited. No AXe child remained. The owned suite group was terminated, and the runner continued with the independent agent suite. Three artifacts contained contact release and Button callbacks; they are not counted as a completed interruption suite. The test helper now uses bounded asynchronous completion. [Stack sample](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v3/interruption-hang-sample.txt), [explicit stop record](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v3/interruption-stop-reason.json).

Duo I was stopped after the uncertain-cleanup failure; its quarantine was preserved. A separate existing audit Duo H was booted and checked. No device was created, no marker was deleted and no input was replayed. Passing H does not claim automatic recovery of I.

After the isolated keyboard failure, owned audit Duo H was shut down in 3.43 seconds. Its quarantine was kept byte-for-byte, SHA-256 `a838d075c1f1f83fffc364200f63fe40dcc4236b3b1cbcac23835b4397f2d6da`. Audit Duo I is also shut down; ordinary iPhone J remains booted. Shutdown does not prove that the earlier key released or that recovery succeeded. [Quarantine and provenance](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/quarantine-duo-h-provenance-20261024.json), [final device states](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/devices-after-h-shutdown.json), [shutdown guard](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/guard-stop-quarantined-h-v1/result.json).

## What remains open

- **Add full release tracking for no-flag Duo keys and shortcuts.** Source review found that Key/Combo do not share all of Type's held-key tracking and cleanup. This is a separate code gap from the simulator timeout. A four-file proposal reuses the existing Type lifecycle, without a setup step, new flag, timeout change or native-framework rebuild. Its isolated CLI is `e826c6fb5039ef3c8b12d5c89f9901218b97ddfe8c65c70fccc2cc0a273aab74`, with unchanged native `c3f11c9d`. It is not accepted or merged: the unchanged Type command failed before the changed key path ran. [Exact source/runtime pins](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/keyboard-cleanup-proposal-v1/runtime-ready-continuation-v1.json).
- **Get one clean full run of the implemented 50-case suite.** The latest full run failed. The guest barrier timeout and AX connection loss remain unresolved, and no cause is established between them. Later targeted passes do not close full acceptance. The full suite was not repeated after the uncertain-cleanup failure.

The two proposed held-key fold/rotation cases passed a build-only check in 36.66 seconds (peak combined footprint 8.728 GiB); native execution was zero. They were not added to the tracked suite. The default remains 50, not 52. [Build-only guard](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/guard-keyboard-interruption-build-only-v1/result.json). No guest-barrier fix or automatic recovery is claimed.

[Partial inner-rotation trace](/Volumes/Developer/AXe/build_products/verification/playground-final-20261024-v1/matrix-v5/duo-PlaygroundDuoTests.log).

## Resources and process cleanup

Matrix v5 completed in 929.51 seconds. Its guard reaped the command in 929.97 seconds, with no guard stop, crash or signals. Both named devices remained booted, all owned command groups stopped and the production payload stayed unchanged. Earlier guards recorded no resource stop or crash. Matrix v3's suite termination is recorded above and is not hidden by the outer guard's empty signal list.

| Attempt | Guard time | Peak combined footprint |
|---|---:|---:|
| Matrix v5 | 929.97 s | 12.927 GiB |
| Three coordinate taps | 69.90 s | 12.735 GiB |
| Isolated keyboard native checks | 65.89 s | 12.629 GiB |
| Two proposed held-key tests: build only, no native input | 36.66 s | 8.728 GiB |
| Matrix v4 | 1184.31 s | 12.696 GiB |
| Post-launch correction | 201.96 s | 12.630 GiB |
| Matrix v2 | 1144.81 s | 11.737 GiB |
| Focused correction | 192.32 s | 11.738 GiB |
| Matrix v3 | 1425.57 s | 12.277 GiB |
| Quarantined Duo I diagnostic | 59.38 s | 12.321 GiB |
| Passed Duo H targeted checks | 267.52 s | 12.032 GiB |

These are measured process-group footprints, not one process's memory. CPU and memory samples remain in each run directory. The earlier targeted passes do not replace the failed full v5 result. The full suite was not repeated after the uncertain-cleanup failure.

## Final package installation

The current Release ZIP passed a unique local Homebrew `--skip-link` installation. All seven payload signatures passed strict verification. The installed wrapper passed the real Playground `findAndTap` check on the existing Duo. The temporary package was removed and original global paths and inputs were restored. All owned command groups stopped. The guard completed in 49.01 seconds with no resource stop or crash.

[Installation and restoration result](/Volumes/Developer/AXe/build_products/verification/direct-ax-default-20261023/slider-minimal-universal-release-v3/local-install-v1/output-v1/result.json), [installation guard](/Volumes/Developer/AXe/build_products/verification/direct-ax-default-20261023/guard-final-slider-install-v1/result.json), [installed wrapper app check](/Volumes/Developer/AXe/build_products/verification/direct-ax-default-20261023/slider-minimal-universal-release-v3/local-install-v1/output-v1/playground-find-and-tap-swift-testing.xml).

This proves local unlinked installation and real input through the installed wrapper. No push, publication, upload or deployment occurred. Current-artifact notarization was not performed.

## Scope limits

- Core actions cover closed outer portrait and open inner landscape. Other supported rotations have real Button checks. This is not every action in every position.
- Custom hinge-driven split layouts, every control type, every CLI option, every text source and every gesture form are not covered by the current 50 cases.
- The six interruption cases cover one complete single hold, drag and moving pinch for each change. Retained contacts, held hardware buttons, key interruption and other multi-touch forms retain their separate historical evidence.
- The test driver permits 15 seconds for an owned command to finish cleanup. This uses the retained 11.595-second normal pinch result and source review. The longer failure-cleanup grace was not separately exercised by a deliberate failure rerun.
- Hosted CI still runs unit tests only. Simulator acceptance runs locally.
- Repeated fresh-start stress checks and empty-control recovery remain deferred. No recovery fix is claimed without a reproduced failure.
- Actual Intel hardware testing and Apple Pay payment-screen testing are excluded by Cam.
- Earlier failures remain failed records. Security scan remains unverified by Cam's instruction.
