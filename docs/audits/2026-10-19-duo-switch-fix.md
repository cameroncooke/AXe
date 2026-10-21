# Duo switch fix: accepted local scope

Date: 19 October 2026. No commit or push.

The isolated switch fix passed before library integration. The integrated library then passed five switch checks through the public AXe CLI. This closes the exact-ID physical switch defect within the scope below. Semantic AXPress is still open.

## What was wrong

The selected accessibility tree found the UISwitch, but a point read returned its unnamed internal Group. The old guard could prove a Button/child relationship only. It rejected the switch before sending input. Changing the point or accepting an overlapping frame did not establish the missing relationship.

## Change

The library reads the simulator element token from the selected screen request. It checks the token against a separate native snapshot of the exact named UISwitch. It then follows the real native parent chain from the selected point element to that switch. Process ID, window, screen, frame and identity must agree. The same point token is read again before input. The existing final context, process and first-touch checks remain in force.

The token parser accepts only the inspected 20-byte simulator format and a positive matching process ID. The native target identity must independently agree with that token. Native method signatures are checked before calls. Snapshot walks stop at 32 levels or 512 nodes; parent walks stop at 12 nodes and reject cycles. The read session is closed after validation. A switch relationship that needs this path requires explicit automation-session preparation; existing-bridge preparation does not silently create a session.

The native global point API ignored its supplied root and returned an inactive display in the investigation. The accepted path does not use that API. It uses the token returned by the explicitly selected display. Bounds alone never admit the tap. The existing Button path remains separate.

The change is in three existing library files:

- FBSimulatorControl/Commands/FBAXPlatformElement.swift
- FBSimulatorControl/Commands/FBAccessibilityElement.swift
- FBSimulatorControl/Commands/FBSimulatorAXTargetOperation.swift

Two focused checks were added to FBSimulatorAXElementTypeTests.swift. The tracked foundation patch and its file hashes include all four changes. No CLI command, option, skill source, or fixture behavior changed.

## Native acceptance

One UIKit UISwitch, accessibility ID feature.switch, in the existing version 6 control fixture. One app process, 52114, and one boot, 51804:1792431773:88125. The simulator is iPhone Duo - AXe Audit, UDID 3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463. These identities are historical. A new run must read fresh identities.

| Action before the tap | Selected screen | Rotation reported by AXe | Hinge | CLI tap style | Observed switch change |
| --- | --- | --- | --- | --- | --- |
| Start closed | Outer 1 | 0 degrees | 0 degrees | physical | Off to on |
| Open in Device Hub | Inner 3 | 90 degrees | 180 degrees | physical | On to off |
| Rotate Right in Device Hub | Inner 3 | 180 degrees | 180 degrees | physical | Off to on |
| AXe hinge set 90 | Inner 3 | 180 degrees | 90 degrees | omitted, default physical | On to off |
| AXe hinge set 0 | Outer 1 | 90 degrees | 0 degrees | automatic, selects physical | Off to on |

For each tap, AXe found the target again from the current tree. Each receipt reported nativeCheckBoxAncestor and two input events. The app recorded exactly one switch change, one touch down and one touch up. Contact duration was between 0.05 and 0.3 seconds; both recorded points were within 0.5 point of the selected point. No touch remained held. Slider, text, scrolling and other controls stayed unchanged within each case.

The inactive inner screen and an old app process ID both rejected before input. The full guest state file stayed byte-identical. A normal named Button tap then passed through the existing uniqueButtonDescendant path: one button effect, one down/up pair, and the switch stayed on. The final visible app state was saved in cli-final-device-hub.png and cli-final-device-hub-ax.txt.

The CLI wire receipt currently retains the match kind, target and context. The detailed native PID/display/window/ancestor proof is present on the library receipt but is not copied into the CLI wire receipt. The acceptance verifier uses the CLI path marker and the independent app touch/effect records.

## Candidate and verification

Evidence root: build_products/verification/switch-fix-20261019/.

- Integrated CLI SHA-256: 5d7819aa4cfd243d5eb32fc4724963f38c752900e6114262e045ba664663c7d4.
- Integrated FBSimulatorControl SHA-256: dfdba39b0bb44e6f09a83bed44352aeb22606a15c666603138e4ef424fd34042.
- integrated-candidate.json pins 81 source, runtime, module and resource files. Exact byte copies are retained. The tracked patch metadata and the Unreleased changelog entry changed after native input. Both changes are recorded separately; no compiled source or runtime changed.
- integrated-result.json records all five accepted cases and limits. Every guarded operation retains the exact command, exit status and resource samples in result.json and resources.jsonl.
- verify-integrated.py checks the saved receipts, current and saved dependency hashes, real app effects, contact coordinates, negative checks and shutdown state. It sends no input and starts no simulator.
- verify.py independently checks the earlier isolated prototype and its saved 80 dependency files. Its result remains separate from library acceptance.

Run the saved verifiers from the repository root:

~~~sh
/usr/bin/python3 -B build_products/verification/switch-fix-20261019/verify.py
/usr/bin/python3 -B build_products/verification/switch-fix-20261019/verify-integrated.py
~~~

The matching Debug arm64 library and CLI builds passed with two jobs. The first CLI test attempt found a mismatched FBDeviceControl dependency before any test ran; rebuilding it against the same FBControlCore fixed that setup fault. The accepted CLI result is 50 tests in five tap suites. The library result is 26 tests in three selector/role suites, including the two new checks. The first library test command used a target name as a scheme and ran no tests; the corrected command used the existing FBSimulatorControl scheme. These failed setup records remain in the evidence directory.

The tracked patch reproduction check also passed:

~~~sh
AXE_BUILD_ARCHS=arm64 scripts/build.sh setup
~~~

Build compiler: Xcode 27.0 release candidate. Native runtime/control tools: installed Xcode 27.2 beta 3, iOS 27.2 simulator. This is local Debug arm64 proof. The staged XCFramework folders contain local Debug replacements. Their prior release text interfaces are not refreshed or accepted by this work. IDB_BUILD_EVIDENCE.txt now states the exact local Debug provenance and that release validation was not performed; its prior contents are retained with the framework backups. Release/universal packaging requires a complete normal framework build. No release or installed system CLI was updated.

## Resource control and final state

Work ran serially, with one audit simulator and no subagents. Builds used two jobs. The saved guard sampled CPU and process memory before, during and after each command. It rejects 8 GiB for ChatGPT or simulator groups, 4 GiB for the owned command, and sustained high CPU. It stops only its owned command group. The owner must still shut down a simulator if the resource limit is reached.

The first two-guest setup was refused at 8.513 GiB. The audit Duo was stopped, and Cam approved stopping iPhone 18 Pro. The accepted CLI native sequence then peaked at 5.377 GiB for the simulator group. No accepted command hit a resource stop. The final native check recorded no booted guests, Device Hub had quit, and simulator support processes used 0.451 GiB and 0.5 percent CPU. These are sampled values, not continuous maxima.

## Still open

- Semantic switch AXPress: the earlier true return without a switch effect remains a failure.
- Other switch roles, labels, values, options and native selected batches. Explicit simulator tap style was not accepted by these checks.
- The other supported switch rotations and other simulator/runtime versions.
- Folding, rotation or app layout changes during a held action. These five cases waited for the change before input.
- Full ordinary-device regression, hard cancellation of synchronous native AX calls, long-lived session reuse and release/universal packaging.
- Security scan: UNVERIFIED, as requested by Cam.

No full Duo parity claim follows from this switch fix.
