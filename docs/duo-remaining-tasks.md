# Remaining Duo tasks

Updated: 28 October 2026. All remaining core checks passed, and the seven-file source integration is complete. Nothing was pushed, published or deployed.

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
