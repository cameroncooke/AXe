# Remaining Duo tasks

## Current status — 30 October 2026

### Duo simulator support

- [x] Current layout 12 and raw keyboard 4 passed with zero issues or skips.
- [x] The original precision-slider case passed at 63.273453 with zero contacts. The native listener and fresh-read host checks passed separately.
- [x] The current complete [Duo 133-case run](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-duo-agent/acceptance.json) passed with zero issues or skips. This does not cover every feature on every screen or orientation.

### SimUse improvements and existing commands

- [x] Preserve healthy keyboard reuse, terminal busy refusal and one-shot completion fixes. The first new keyboard connection can still refuse safely at two seconds.
- [x] Current keyboard/slider unit 24 and the separate real popup/Escape/Button proof passed. A fresh focus read does not replay input.
- [x] The current complete [ordinary iPhone 133-case run](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-iphone/acceptance.json) passed with zero issues or skips.
- [x] The local arm64 ZIP roundtrip preserved the exact signed payload.
- [x] Reviewed source and documents committed as `9eb7cbee`. The [local update](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-local-install-v3-plan/local-install/run/result.json) and [installed CLI check](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-local-install-v3-plan/installed-prefix-smoke/run-v1/result.json) passed.

The current isolated CLI/native pair is `ddca4cc6/a42360f5`. The [master checklist](duo-implementation-checklist.md) gives current results; the [audit](audits/2026-10-29-keyboard-reliability.md) retains V1/V2 failures and exact candidate maps. Both complete 133-case results are accepted for this isolated candidate. The reviewed source is committed and the exact tested CLI is installed locally. All four approved work items are complete; no push, publication or deployment occurred. The cause of shared service delays and the Apple-provider disconnect remains unproved.

## Previous task record — superseded

The prior record below is retained; the current status above governs acceptance.

Updated: 29 October 2026. The keyboard and capacity fixes are in a reversible source checkpoint, and current main source compiles. Runtime acceptance remains open. The earlier ordinary 133 pass and failed Duo full runs keep their exact candidate identities.

## Duo simulator support

| Bug or feature | Current state | Evidence or remaining check |
| --- | --- | --- |
| Find and use controls on either screen | Core finding, tapping, typing, scrolling, swiping, dragging, switches and sliders remain available. | Current full Duo regression is listed below; earlier core results stay in the history. |
| Type exact raw and selected text on both screens | Literal, file and standard-input text keep their existing parsing. | [12 text-source cases](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-final5-duo-keyboard-sources-v1/result.json) and [300-byte raw text](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-final5-duo-raw-long-text-v1/result.json) passed. |
| Stop keyboard input after folding or rotation, then use the new layout | Held keys and key sequences stop safely and allow fresh text. | [All four transition cases passed](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-final5-duo-raw-keyboard-interruptions-v1/result.json). Five modifier/cancellation/busy checks also passed; see the [audit](audits/2026-10-29-keyboard-reliability.md#duo-keyboard-safety-proofs). |

## SimUse improvements: optional agent mode and existing commands

| Bug or feature | Current state | Evidence or remaining check |
| --- | --- | --- |
| Keep RS/1 references across new CLI calls | One RAM table lasts up to 60 seconds. New captures replace it; old callers cannot erase a newer table. Current app, layout and native state are checked before input. | [Storage and refusal rules](agent-mode-persistence.md). Full ordinary 133 and the amended reference checks are recorded below. |
| Preserve raw commands beside stateful agent input | No-flag output and coordinate input remain. Complete keyboard commands can reuse a healthy connection after release. | [Five separate calls on one connection](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/ordinary-shared-keyboard-reuse-proof-v1/run-final5-v1/result.json) and the [original seven key-sequence cases](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-final5-key-sequence-v1/result.json) passed. |
| Refuse a new action when broker request slots are full | The isolated fix sends a terminal busy refusal before any request body. | The same [physical check passed](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/saturation-v1/result.json); no delayed ninth-client input. Release acceptance remains open. |
| Accept the measured ordinary-iPhone display report | The strict decoder accepts omitted active flags only for the verified report. | Schema 20 and discovery 13 passed within host186; the full ordinary 133 run also passed. |

## Final acceptance

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


Source integration: the [reversible 57-file checkpoint](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v1/receipt.json) is applied, with 45 changed files and 12 unchanged files. The 14 unrelated work files, managed IDB source, Git index, main runtime and installed CLI remain unchanged. A [fresh offline main compile passed in 39.77 seconds](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v1/compile-only.json). That result proves compilation only; it does not prove simulator acceptance. **Release acceptance remains blocked by the failed full Duo runs**. The strict readiness promoter was not run. The audit is a separate guarded document addition. No local installation, push, publication or deployment is claimed.

## Work still open

- [x] Verify the native hinge reader on `c946160e`. The actual public cancel/completion order, typing8, drag1, layout2 and native host9 checks passed.
- [ ] Integrate the reviewed HingeReader source and matching native inputs after the current complete Duo run is accepted. Preserve the 14 unrelated work files and managed IDB source.
- [ ] Obtain current-candidate runtime acceptance through the strict complete 133 gates. Keep each actual CLI, test source and host identity; do not combine focused passes into a full result.
- [x] Apply the reviewed source checkpoint and compile current main source. The 57-file checkpoint and compile-only pass preserve the 14 unrelated work files and managed IDB source; they do not satisfy the strict full-run gates.
- [ ] After runtime acceptance, use matching final compile inputs and verify local installation through its separate smoke check. The installed CLI and main runtime are unchanged.

## Failed history and proof limits

The [earlier FINAL5 Duo run](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-duo-full-v1/result.json) executed 133 cases and failed one recovery tap on a control outside its visible scroll area. Its unchanged repeat reproduced that fixture error. Three test-only corrections also updated the exact busy-error assertions. The nine focused passes above remain separate results. They do not change the failed full run or create a new ordinary-iPhone full pass. The [keyboard audit](audits/2026-10-29-keyboard-reliability.md) keeps the failures and exact receipts.

The 133-case agent group does not test every action in every Duo screen and orientation. No live foreign-user-ID injection was performed. The `postActionRefreshFailed`, `postActionRefreshQuarantined` and `batchRefreshFailed` branches were not separately forced on this hardware; source and host checks do not prove those live branches. These are evidence limits, not missing core commands. Apple Pay payment screens and Intel execution are excluded. Cold-start stress and unreproduced empty-screen recovery stay deferred.

## Earlier task records — unchanged

The records below retain their original date and candidate. Their completed or pending labels are historical; use the current list above.

Updated: 28 October 2026. The prior Duo core checks passed, and the seven-file source integration is complete. The optional agent follow-up below remains open. Nothing was pushed, published or deployed.

## Current optional agent follow-up — verification in progress

Two source fixes are implemented: keep the reference table until its 60-second expiry, and refuse an old snapshot ID without clearing another caller's newer table. See [agent-mode persistence](agent-mode-persistence.md) for storage, replacement and refusal rules.

Current isolated candidate: CLI `9fcfabcdc1ae40b0d367326e77abbaaa5f09620c1bc2cdb2000b81e328b9647c`, native framework `0be5aea43faee4e96de587d6ed6de11f9f56073748dc1f2060dab5de81cb4949`.

- [x] Verify reference lifetime across separate calls: survive 35 idle seconds, keep the original expiry, refuse expired input, then use a fresh reference. [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/run-iphone-idle-isolated/result.json).
- [x] Verify keyboard visibility, cached metadata, paging and dismissal: all six cases passed on the dedicated iPhone. [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/run-iphone-keyboard-isolated/result.json).
- [x] Run all 121 host input cases: 58 broker/lifetime and 63 input/selector cases passed, with no missing cases or skips. [Broker](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/run-unit-ledger-final/result.json), [input](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/run-boundary-ledger-final/result.json).
- [ ] Complete the full 130-case ordinary-iPhone run: all 124 existing optional agent cases plus six new reference cases. The current run uses the existing dedicated AXe Isolated Control iPhone. The earlier shared-device run stopped at zero contacts after a read found Handful. No full-run pass is claimed. [Stop record](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/iphone-v2-stopped-for-device-conflict.json).
- [ ] Complete the focused Duo reference, fold and rotation checks, then record exact results and CPU/memory checks.

The sections below record the prior completed Duo core scope and its earlier evidence. They do not close this new optional agent follow-up.

## Duo simulator support

- [x] Read and select the correct screen with an extra inactive virtual display.
- [x] Set and read the hinge, and select the correct screen after folding and supported rotation.
- [x] Find controls and tap them by identifier or fresh accessibility coordinates on both screens.
- [x] Type and edit text, scroll, swipe, drag, use switches and set sliders on both screens.
- [x] Stop ongoing input after a layout change, release keys and touches, refuse old references, then find and tap the control again.
- [x] Pass the exact original typing-while-opening case after its earlier accessibility-read failure.
- [x] Shut down only the target simulator and preserve all other simulator states.

All 20 original Duo control identities passed in separate 16-case and four-case runs on CLI8fe / native0be5. The full Agent10 run remains nine passed and one failed; the later original opening1 pass replaces only that case. No full-group pass is claimed. The batch stopped on a refresh error; folding as its cause was not proved. [Control16](../build_products/verification/duo-recovery-20261027/scoped-hinge-regressions-v1/runs/duo-core-non-typing16-scoped/result.json), [typing4](../build_products/verification/duo-recovery-20261027/scoped-hinge-regressions-v1/runs/duo-core-typing4-scoped/result.json), [opening1](../build_products/verification/duo-recovery-20261027/type-opening-focused-run-v1/runs/duo-type-opening1-scoped/result.json), [shutdown1](../build_products/verification/duo-recovery-20261027/scoped-hinge-final-lifecycle-v1/runs/duo-lifecycle1-scoped-final/result.json).

## SimUse improvements and existing commands

- [x] Refuse an old saved reference before input, including a measured-screen mismatch.
- [x] Preserve existing raw accessibility output and coordinate input beside the optional agent interface.
- [x] Pass all eight original ordinary-iPhone identities in separate selected runs.
- [x] Pass raw and selected typing plus Return with exact text, four edit callbacks and real focus loss.
- [x] Verify the exact existing 116-character input in 4.17 seconds, within the unchanged 30-second limit.
- [x] Compare FlowDeck, sim-use and RocketSim typing after the same AXe preparation. All three passed the typing action.

The long-text check was manual CLI verification, not an executed TypeTests suite. The vendor checks did not test vendor Return or the full Duo suite. Earlier failures remain saved; no common cause was proved. The three trial raw-typing fixes remain unaccepted and excluded. The existing raw path passed after restarting only the audit simulator. [Raw false1](../build_products/verification/duo-recovery-20261027/original-raw-typing-one-case-host-v1/proof-v1/runs/iphone-original-raw-false1/result.json), [selected true1](../build_products/verification/duo-recovery-20261027/original-selected-typing-one-case-host-v1/proof-v1/runs/iphone-original-selected-true1/result.json), [long text](../build_products/verification/duo-recovery-20261027/original-long-text-116-final-candidate-v1/import-fix-v2/run/result.json).

## Finish and record the work

- [x] Verify local ZIP/tar archives, seven signatures and arm64/x86_64 files.
- [x] Verify a temporary unlinked installation with a real Button tap and complete cleanup.
- [x] Accept the current case ledger: 693 planned cases passed, no failed or incomplete cases, no added identities. The 64 selected current IDs passed; old run failures remain in history.
- [x] Apply the seven proved source, test and changelog files and check the exact applied hashes.

The ledger combines inherited history with separate accepted runs. It is not one full-suite execution. [Accepted current ledger](../build_products/verification/duo-recovery-20261027/canonical-ledger-merge-v2-proposal/case-ledger.current.json), [local archives](../build_products/verification/duo-recovery-20261027/scoped-hinge-local-delivery-v1/package-output-v1/delivery-result.json), [local installation](../build_products/verification/duo-recovery-20261027/scoped-hinge-local-delivery-v1/install-output-v1/result.json).

No further core task remains in this scope. The applied production and test source matches the verified candidate. Unrelated work and the managed IDB checkout stayed unchanged. The default installed CLI was not replaced, and no commit was made. [Applied source receipt](../build_products/verification/duo-recovery-20261027/source-integration-inventory-v1/final-seven-files-applied.json). Apple Pay payment screens and Intel hardware checks are excluded. Cold-start stress and empty-screen recovery remain deferred. Notarization was not tested. Release checks stayed local.

Reference: [master checklist](duo-implementation-checklist.md).

## Earlier task record — unchanged

This is the previous 27 October status. Use the current list above for remaining work.

Updated: 27 October 2026. Approved by Cam. Reuse the existing warm simulators, tools and evidence. Run one heavy job at a time. Check CPU and memory at intervals. Do not push, publish or deploy.

## 1. Read and select the correct Duo screen — proved and added to source

- [x] Fix rejection of an extra inactive virtual display.
- [x] Pass all 18 saved display checks.
- [x] Select the correct built-in screen after partly opening, fully opening, closing and supported rotation, while the virtual display remains inactive.
- [x] Add the proved decoder change to the tracked library patch and verify all 63 source hashes on a fresh exact-base source tree.

CLI 826e525e / library 7c2d27a2 passed on the same warm Duo boot that failed with the old decoder. This proves display discovery and selection in these cases. [Display results](../build_products/verification/duo-vendor-failures-20261026/inactive-virtual-native709-build-v1/POINT-1-RESULT.md).

## 2. Check the existing warm simulator — proved

- [x] Read the real field, Target and Dismiss controls before a restart.
- [x] Read them again after a normal Playground launch, using the new app process and current screen.
- [x] Confirm that the reads send no input and leave the app state unchanged.

No restart, new simulator, app install, setup service or longer timeout was needed. The old missing-tree failure did not recur in these reads; no permanent recovery fix is claimed. [Discovery results](../build_products/verification/duo-recovery-20261027/recovery-result.json).

## 3. Fix and prove the remaining input faults — final typing fix in progress

### Duo support

- [x] Pass the original opening case, six batch cases and seven key-sequence cases: 14 existing cases.
- [x] Pass the original held A/Shift fold and rotation cases. Both keys released; a fresh physical Button tap and exact lowercase input worked. The observed accent picker was closed before Dismiss.
- [x] Pass the original batch-fold case with the isolated hinge-reading change. A new outer-screen Button tap worked.
- [x] Pass the original two-finger fold case with the isolated hinge and early old-reference changes. Both fingers released, the old reference sent no input, and a freshly found outer-screen Button received one real tap.
- [x] Pass the existing ordinary-iPhone Core9 and Duo Core20 groups for finding controls, tapping, typing, scrolling, swiping, dragging, switches and sliders.

[Opening, batch and key-sequence proof](../build_products/verification/duo-recovery-20261027/targeted-failures-v1/effect-review.json), [held-key proof](../build_products/verification/duo-recovery-20261027/fold-test-fixture-proposal-v2/held-modifier-proof-v1/combined-acceptance-review.json), [batch-fold proof](../build_products/verification/duo-recovery-20261027/hinge-threshold-zero-agent-two-bind-v1/independent-effect-review.json), [pair-fold proof](../build_products/verification/duo-recovery-20261027/agent-reference-preflight-pair1-bind-v1/device-plan-effect-review.json), [core proof](../build_products/verification/duo-recovery-20261027/core-lifecycle-scope-v1/core-effect-review.json).

These are separate saved runs. Batch-fold passed on CLI 826e525e / library a12fea10. Pair-fold passed later on CLI 8fe0842c / library a12fea10. The pair test body and assertions stayed unchanged. Its early missing-snapshot check is proved; the separate measured-display-mismatch branch was not observed. Neither new source change is in the default library yet.

### SimUse improvements and existing-command compatibility

- [x] Identify the ordinary-iPhone raw typing failure: whole-text A!q7 failed twice while selected typing and Return passed.
- [x] Reject the slow character-at-a-time trial. Four characters reached the field, but its minimum 52.2-second wait for the existing 116-character test exceeds that test's unchanged 30-second limit.
- [ ] Prove the smaller raw keyboard change with the original whole-text A!q7 command: exact text and four callbacks, with no extra touch.
- [ ] Prove the exact existing 116-character text within the unchanged 30-second command limit.
- [ ] Repeat the affected existing ordinary-iPhone tests on the accepted final candidate.

The new keyboard candidate uses the existing two-second guest-service barrier once before a whole raw keyboard event. It adds no setup service, per-character wait, retry or input replay. Only its source has been reviewed; build and simulator results are still required. [Source review](../build_products/verification/duo-recovery-20261027/raw-keyboard-initial-barrier-native7c-proposal-v1/independent-source-review.json).

The vendor checks are bounded comparisons. All three tools encountered the normal accent picker after shared AXe setup. FlowDeck later completed the shared batch-fold comparison and AXe recovered on the outer screen. RocketSim's latest comparison stopped at an AX read before any RocketSim fold command; that is not a RocketSim capability failure. Do not call the original AXe faults Apple bugs. [Popup comparison](../build_products/verification/duo-recovery-20261027/shared-comparison-v3/popup-effect-review.json), [FlowDeck fold comparison](../build_products/verification/duo-recovery-20261027/vendor-fold-comparison-v2/effect-review.json).

## 4. Add the proved changes and finish repeatable checks — pending

- [ ] Add the proved popup-aware helper to tracked tests. Keep the original cases and assertions.
- [ ] Add the proved hinge-reading and early old-reference changes to the library source.
- [ ] Add a raw typing fix only after the short and long text checks pass within the original limits.
- [ ] Build one matched final candidate and run the affected raw-command, coordinate and optional --agent checks on the existing warm iPhone and Duo. Preserve the separate earlier results.
- [x] Check local archives, signing and temporary unlinked installation for the earlier matched CLI 826e525e / library 7c2d27a2, including a real installed Button action and cleanup.
- [ ] Refresh local delivery checks for the accepted final candidate where its changed files require them.
- [ ] Run the existing target-only simulator shutdown check last.
- [ ] Merge accepted results into the unique case record and update the master checklist. Keep failed, unrun, excluded and deferred work separate.

The earlier matched-source check binds all 141 committed production files to CLI 826e525e and all 63 native source hashes to library 7c2d27a2. The protected local source changes stay excluded and preserved. The new hinge, reference and keyboard candidates remain isolated; no rollout or final-candidate readiness is claimed. [Source comparison](../build_products/verification/duo-recovery-20261027/local-delivery-v1/source-equivalence.json), [earlier local installation](../build_products/verification/duo-recovery-20261027/local-delivery-v1/install-output-v1/result.json).

The last accepted master totals remain unchanged until the result merge. Separate passing runs are not one full-suite pass. Cold-start stress and empty-screen recovery remain deferred. Apple Pay payment-screen checks and Intel hardware checks are excluded. Release checks are local only.

Reference: [master checklist](duo-implementation-checklist.md).
