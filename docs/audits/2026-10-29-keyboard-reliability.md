# Keyboard reliability and remaining Duo checks

## Current acceptance — 30 October 2026

V3 simulator checks passed. Its complete ordinary iPhone 133 and Duo 133 each executed all 133 cases with zero issues, failures or skips. Their guards exited cleanly and reaped the owned jobs; elapsed times were 1966.75 and 2620.14 seconds. Current unit 24, the original precision-slider case, layout 12 and raw keyboard 4 passed with zero issues or skips. Native transport/feed 18 and legacy keyboard 9 passed separately. The real public popup/Escape/Button proof passed and adds no suite cases.

The isolated candidate is CLI `ddca4cc6`, native `a42360f5`, source `becb4de5`, host `da5bcfb7`, helper `5688d749` from unchanged source `7eb55735`. None of these results proves a main-source apply, commit, installation or installed-image check.

### What caused our faults

- The original raw keyboard timeout came from a new connection for each CLI call. The recorded guest activation took 5.347 seconds, beyond the two-second reply limit. Healthy connection reuse removes that repeated startup path. The first new connection still has the two-second readiness limit and can safely refuse with zero input; all cold starts are not guaranteed.
- The full broker queue closed a caller without a terminal busy reply. Startup recovery could then send its first input late. The corrected terminal refusal was reproduced and physically proved.
- The one-shot hinge reader could close before its cancellation message drained. The corrected reader waits for the sample, host drain and normal original reply within the same three-second limit. Actual loaded-library and guest evidence proved that request order. This does not establish the cause of shared service pauses.

### What V3 changes and proves

The focus-read correction permits one fresh read only for the exact DTX disconnect, within the original remaining deadline. It repeats no key or action. Current context, PID, focus, frame and target checks remain. The Apple provider's reason for disconnecting is unproved; vendor reads do not prove equivalent guarded input.

The native change listener now remains open while separate loops obtain real fresh hinge samples and display observations. An unexpected original listener completion fails closed. Native 18 checks cover the transport and feed state; they do not replace simulator proof. The original precision-slider case now finishes in 36 moves at 63.273453 with zero contacts. The 15-second action limit, 1.5-second release reserve and 0.07 tolerance remain. The earlier final path could be admitted without enough minimum time for pacing and confirmation; the new planner rejects that condition and uses the measured later correction directly. This is not a claim that every service delay is removed.

The fixture records each failed read-only attempt before input or after confirmed release. It does not repeat layout writes or input. Current [layout 12](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-duo-interruptions/acceptance.json) and [raw keyboard 4](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-duo-raw-keyboard-interruptions/acceptance.json) passed. The [unit 24](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-host-unit/acceptance.json) and [slider 1](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-duo-slider-from-maximum/acceptance.json) are separate runs. The [popup proof](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/public-typing-popup-escape-proof-v3/run-v1/acceptance.json) observed a real popup, sent one released Escape pair, preserved text and edits, then proved a fresh physical Button callback and zero contacts.

### Complete runs and delivery status

| Current V3 check | State |
| --- | --- |
| Complete ordinary iPhone 133 | [PASS: 133/133](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-iphone/acceptance.json), zero issues/skips |
| Complete Duo 133 | [PASS: 133/133](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v3/check-duo-agent/acceptance.json), zero issues/skips |
| Local arm64 ZIP roundtrip | [PASS: exact payload and seven strict signatures](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-local-install-v3-plan/zip-roundtrip-v1/inventory.json) |
| Reviewed source/docs, scoped commit and local install | PENDING separate receipts |
| Installed CLI/native image and public-input smoke | PENDING separate receipts |

Shared AXe and RocketSim request delays are measured. Their initiating cause and relation to DTX remain unknown. No Apple defect, vendor equivalence or unfixable service condition is established. The V1 and V2 failures below remain failed with their original candidates. A later pass never changes their outcome.

## Previous combined-candidate record — superseded

The following V1/V2 record is retained byte-for-byte. Its current-status headings describe those earlier candidates; the V3 state above governs this draft. The original audit body and eight keyboard-safety links remain unchanged.


## Current acceptance — 30 October 2026

V2 is not finally accepted. Its ordinary 133 passed; its Duo 133 failed one precision-slider case. The first candidate's ordinary and Duo DTX failures remain failed in the history. A later success does not cancel a failed run.

| Check on V2 | Actual result |
| --- | --- |
| Ordinary iPhone 133 | [PASS: 133/133](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v2/check-iphone/acceptance.json), zero issues/skips; 2064.20 seconds. |
| Duo 133 | [FAILED: 133 executed,132 clean, one issue](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v2/check-duo-agent/acceptance.json), zero skips. Selected slider from 100 to 63.25 used its feedback budget before final confirmation; release drained, no quarantine. |
| Same slider, repeat 1 | [PASS: 1/1](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v2/check-duo-slider-from-maximum-1/acceptance.json); actual app value 63.273453, zero contacts, same recorded PID/generation. |
| Same slider, repeat 2 | [FAILED: 1/1](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v2/check-duo-slider-from-maximum-2/acceptance.json); live observation became unavailable. Actual app value 64.346930, zero contacts, same recorded PID/generation. |
| Agent layout 12 | FAILED: 12 executed,11 clean, one referencePinchRotate rotation/display-read issue, zero skips; 549.10 seconds. |
| Raw keyboard 4 | PASS: 4/4, zero issues/skips; 189.49 seconds. |

V2 uses CLI `2f8cfcff`, native `c946160e`, source `6e0701f0`, host `35e03508` and helper `4bde82d4`. Its keyboard 21, ordinary Type 8, Duo Batch 6 and separate real popup/Escape/Button proofs passed. The focus-read correction is still outside main.

### Exact slider outcomes

The complete Duo run's selectedFromMaximum command had initial value 100 and requested63.25. It sent49 events with 48 moves and drained release without quarantine. Its 15-second action limit reserves 1.5 seconds for release; the feedback budget expired before final confirmation. No post-release app value was saved for that first failure, so its final value is not established. Nativec946 and this slider source were unchanged from V1, where the same case passed.

Repeat 1 passed the original case and independently saved actual app value 63.273453 with zero contacts. Repeat2 failed with observationUnavailable: Native observation feed is stale or not initialized. Its release drained; the independent app document showed64.346930 and zero contacts. Both diagnostic reads matched the PID and page generation recorded by the case commands. [Repeat 1 app observation](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v2/check-duo-slider-from-maximum-1/post-app-observation.json) [Repeat2 app observation](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v2/check-duo-slider-from-maximum-2/post-app-observation.json). These are different failure boundaries and do not prove an Apple cause or a V2 keyboard regression.

### Earlier combined candidate remains failed

CLI 40676bea/nativec946160e, source 43628fad/hostbaf214a4: [ordinary 133](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v1/check-iphone/acceptance.json) and [Duo 133](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-candidate-v1/check-duo-agent/acceptance.json) each executed 133 with 132 clean, one DTX focus-read failure and zero skips. Ordinary Type.reference failed before HID input with cleanup not needed. Duo batch.rawCompatibility failed after Shift DOWN; its owned Shift UP drained. Neither run is accepted. The separate actual popup/Escape/Button proofs passed on [V1](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/public-typing-popup-escape-proof-v1/run-v1/acceptance.json) and [V2](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/public-typing-popup-escape-proof-v2/run-v1/acceptance.json), with no full-suite contribution.

V2's [reviewed two-file fix](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/selected-keyboard-focus-read-recovery-v1/manifest.json) permits at most one new native focus-read attempt for the exact top-level DTX disconnect, using the original remaining deadline. Current context, PID/focus/frame/agent-target and owned release checks remain; surrounding input is not replayed. A new underlying Apple connection is not proved. [Vendor AX paths](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-ax-read-vendor-review-v1/review.json) differ and do not establish equivalent guard success or reconnect behavior.

### Work still open

The two slider repeats are separate runs. Repeat 1 does not cancel repeat 2 or the failed complete Duo run. The third repeat and a new complete Duo run have not run. Candidate V3 source proposals are in preparation; no V3 build, pass or main-source apply is claimed. Complete 133/133/12/4 on one final candidate, the scoped commit, local installation and installed-image checks remain open.

A native live-freshness proposal and a separate CLI slider proposal are being prepared. The proposed fixture read retry is separate from product input. Their final source hashes, peer review, builds and new candidate proofs are not yet bound. V2 layout 12 finished failed with 11 clean cases and one terminal rotation/display-read issue, zero skips. Raw 4 passed all four cases with zero issues/skips; this does not accept the two failed groups. The original keyboard startup, capacity and one-shot completion fixes retain their exact earlier proofs. Shared AXe/Rocket service delay is observed; its initiating cause and relation to DTX remain unknown. The first cold keyboard connection still has its original two-second readiness limit.

## Previous status — superseded

The record below keeps its original date, candidate identities, failures and eight historical keyboard-safety links.

Updated: 29 October 2026. Three confirmed AXe faults are corrected and integrated: repeated keyboard startup, delayed input at broker capacity and early one-shot hinge-read close. One genuine Duo133 run passed. Separate transition groups remain failed; the cause of their shared service delay is unknown.

## Current transition checks

| Scope | Exact result |
| --- | --- |
| Complete Duo regression | 133 passed, zero issues/skips; CLI 8a/native c946, source ea9, host 527. This is one complete run, not combined focused results. [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-full-v1/result.json) |
| New agent transition group | FAILED: 12 executed, 6 clean, 6 issues, 0 skips; 373.29 seconds. Three hinge-sample reads and three initial display queries failed. |
| New raw keyboard transition group | FAILED: 4 executed, 3 clean, 1 issue, 0 skips; 148.52 seconds. Held-letter fold stopped with confirmed key release/no replay, then its native hinge read failed. |
| Isolated fold writer controls | Idle and matched batch passed. The full groups above did not pass; four fixture/test files remain on hold and unapplied. |

The new groups used source 7436/host e1fb and the same product runtime. Their [validated case and guest-log report](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/held-tests-sensor-failure-report-v2/report.json) records each failed stage, cleanup evidence and its limits. Requests from AXe and RocketSim overlapped in the failed pinch window: action completion took 6.002714 and 10.392391 seconds. The batch window also has delayed requests from both tools. This proves shared delay, not its initiating client or an Apple defect. Some failed cases lack final mechanical, quiet and fresh-use proof.

Both later read-close diagnostic arms allowed a fresh native read. No fault was reproduced and no new correction is claimed. Successful later AXe/Rocket/FlowDeck reads prove only those later calls. Filtered logs cannot prove that an unrecorded ACK was not sent.

The old failed groups remain failed. The protocol-only idle control had 43 real post-close samples at 180 degrees despite both transport replies. The caller-held idle control later passed; its first attempt remains failed at the final catalogue transition. The matched caller-held batch then passed with release, stale-reference refusal and fresh physical input. Detailed helper iterations, exact times and all prior receipts are retained in the [diagnostic history](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/keyboard-reliability-docs-proposal-v1/v13-final-held-groups-shared-delay/draft.md). These controls do not create an all-16 pass.

## Our faults and the unknown service delay

| Finding | Current state |
| --- | --- |
| New keyboard connection for each raw CLI call | Guest activation took 5.347 seconds, beyond the two-second reply limit. Shared connection reuse corrected the repeated-start path and passed the five-process proof. |
| Input arrives late when the broker is full | The server closed the ninth connection without a busy reply. The client entered startup recovery and sent its first input after the held operation ended. The corrected server sends a terminal busy reply; the exact comparison passes. |
| Duo motion and display requests pause | A request from peer 65449 took 17.881096 seconds and a RocketSim 338 request took 21.678895 seconds in the same window. Direct Apple display queries also timed out. Their cause and relation to the AX disconnect remain unknown. |
| One-shot hinge read can return before its cancellation reply is sent | The baseline AXe reader returns after the sample, then cancels. XPC can discard unsent messages. One diagnostic proved the normal cancellation protocol. The correction is built and signed. The public library-path read and the four targeted groups passed. Complete Duo133 passed. The separate transition groups remain failed. |

The first two defects are ours. There is no basis to call the remaining problem unfixable, classify every failure as an Apple bug, or accept the failed full Duo runs.

## Keyboard startup: confirmed cause and correction

For raw client 96699, the guest received the connection at 22:00:57.083231 UTC on 28 October. AXe cancelled at 22:00:58.819621. The guest activated it at 22:01:02.430297, 5.347066 seconds after receipt. The field remained A. This explains that recorded timeout; it does not explain why guest setup was slow or every older timeout. [Original source and guest timeline](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/input-timeout-root-cause-20261029/native-source-and-guest-timeline-review-v1.json)

The correction keeps a healthy keyboard connection across raw CLI calls on verified ordinary profiles and Duo. The owner returns it only after the complete stream is drained, all owned keys are released, the context is current and no cancellation or cleanup is pending. Text/file/stdin parsing, repeated modifiers, guest replies, input deadlines and no-replay rules stay intact. Legacy touch batches remain outside this reuse rule.

Five separate CLI processes reused actual UUID 51291D51-53D2-4AB9-9FEA-4ECAF124BF3F. The same app received exact text Abcbcbcbcbc, ten new edit callbacks and no touch contacts. The acquired/reused/returned UUID records and serving native image confirm the path. [Five-process proof](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/ordinary-shared-keyboard-reuse-proof-v1/run-final5-v1/result.json)

A first new connection still uses the existing two-second readiness check before input. A slow first acquisition can fail safely with no input and discard the connection. This is a source-confirmed availability limit, not a new observed candidate failure. Reuse removes repeated creation; it does not make all cold starts succeed.

## Broker capacity: reproduced delayed first delivery

The original comparison held one key and opened seven further client slots. A separate capacity probe received EOF. The ninth raw CLI entered startup recovery, then inserted b after the held operation was cancelled. This was delayed first delivery, not replay of accepted input. [Original reproduction,31527e11](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/selected-broker-saturation-proof-v1/run-v2/result.json)

The one-file correction keeps capacity 8, wire 36 and existing input deadlines. At capacity, the server sends ready:false,rejection:busy before it reads a request body. On FINAL7 CLI 8a994931 and native 553acba2, the same comparison returned SAFE_BUSY_REFUSAL. The ninth command failed without entering startup recovery or inserting b. After confirmed release, fresh c and a physical Button tap worked. Final text was ac, with two edit callbacks and zero contacts. [Fixed comparison,b42c800e](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/saturation-v1/result.json)

## What the vendor comparisons establish

The earlier prepared-field comparison passed with sim-use and FlowDeck raw keys 5,6. RocketSim passed text bc. Their timing and completion guarantees differ: sim-use retains a daemon connection and uses host-send barriers; the RocketSim check was text only. These passes support reuse as a design choice. The original AXe guest log supplies the direct startup cause. They do not prove equivalent guarded typing or explain the later motion pause. [Matched keyboard comparisons](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v4/matched-keyboard-tools-v1)

During the separate DTX/display incident, FlowDeck and sim-use read the Playground AX tree and RocketSim read the hinge while a direct Apple display query timed out. The Apple query recovered in 0.13 seconds without a requested restart, then the unchanged eight-case Type group passed. Different paths remained available. This does not prove an AXe reconnect fix or that Apple caused the earlier DTX disconnect. [Apple timeout](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/dtx-device-catalogue-fault-v1-response.json) [Apple recovery](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/dtx-device-catalogue-fault-v2-response.json) [Unchanged Type8 pass](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-focused-after-service-recovery-v1/result.json)

## Duo keyboard safety proofs

These recorded checks passed on FINAL5 CLI `a9f3d8c1` and native `553acba2`. The automated groups used source `eaf6f6f8` and test host `9b8dd89a`. They remain bound to that candidate. They are separate from the current CLI 8a/native c946 full run and do not establish an equivalent current full pass.

| Check | Recorded result | Evidence |
| --- | --- | --- |
| Repeated Shift modifier | Passed; final text `Acq7` | [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/raw-physical-duplicate-v1/result.json) |
| Shift as modifier and target | Passed; final text `cq7` | [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/raw-physical-target-modifier-v1/result.json) |
| Cancel held key with SIGINT | Passed; confirmed release and final `aq7` | [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/raw-physical-cancel-int-v1/result.json) |
| Cancel held key with SIGTERM | Passed; confirmed release and final `aq7` | [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/raw-physical-cancel-term-v1/result.json) |
| Refuse competing raw keyboard input | Passed; no text from the refused call, final `abq7` | [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/raw-physical-busy-v1/result.json) |
| Raw and selected literal, file and stdin typing | All 12 passed on outer portrait and inner rotation 90; exact `aQ7` | [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-final5-duo-keyboard-sources-v1/result.json) |
| Raw text above 256 bytes | Passed; exact 300-byte text, then one lowercase `c` | [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-final5-duo-raw-long-text-v1/result.json) |
| Stop held key and key sequence after fold or rotation | All 4 passed; cleanup, quiet state and fresh typing | [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-final5-duo-raw-keyboard-interruptions-v1/result.json) |

The five separate modifier/cancel/busy checks used inner display 3 at rotation 270. Each then entered fresh `q7`, found the Button again and tapped it. Each ended with one Button callback, two balanced physical contact groups and zero contacts. Both cancellation cases returned `releaseEnqueuedAndDrained`; no input was replayed and no broker was signalled. The global OS pressed-key inventory was not read.

The four fold/rotation cases kept exact `AXe helda` through four quiet reads, then used the new tree and entered `fresh after fold` or `fresh after rotate`. Held keys had confirmed release; sequences stopped before the second key with no release needed. These results do not explain the earlier hinge completion timeout or prove that the keyboard correction changed hinge behavior. The old failed runs remain in the record.

## Shared motion pause: cause unproved

The saved guest window 13:48:15–13:48:50 UTC contains 168 hinge invocations: 137 with threshold 0.1 and 31 with threshold 0. Each logs action success within the window. Root separately verified peer 40220 as the running RocketSim 338 app. The log shows:

- Peer 65449 invocation 7ADB3D02…: start 13:48:22.735214, peer cancellation 25.761326, action success 40.616310. Elapsed 17.881096 seconds.
- RocketSim invocation FCCB81F0…: start 22.012471, interrupted send 40.616500, proxy cancellation 40.617000, action success 43.691366. Elapsed 21.678895 seconds.
- Three further Rocket connections activated at 27.133392, 32.801535 and 40.050569. Their actions did not start until 40.616607–40.616799.
- Another 467 failed side-channel sends refer to 18 older invocation UUIDs with no start or completion in this window. Their earlier lifetime and owners are not established here. Three further send errors belong to current Rocket invocations.

This is shared service-path delay and old invocation traffic. It does not identify the cause, prove a client leaked a stream, or justify quitting another tool as a fix. [Exact guest log](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/duo-full-v2-guest-motion-log-v1/stdout) [Traffic accounting](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-diagnostic-v1/guest-motion-accounting.json)

## One-shot hinge completion: targeted checks passed

The diagnostic sent one threshold-0 request within the unchanged absolute three-second bound. For invocation B5FFD567-E4AA-49F0-AAF6-E5E20E473D35, it recorded the sample, cancellation ACK enqueue, host-send barrier, normal original reply and then connection cancel. The reply contained an empty CoreDevice.output dictionary. The guest explicitly logged consumer cancellation at 14:22:05.089810, proxy-task cancellation at 05.089874 and action success at 05.089905. This proves cancellation of this stream proxy before its normal completion reply. It does not prove OS-wide unregister or explain the shared pause. [Diagnostic result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-diagnostic-v1/probe-v2/run-v1/result.json) [Matching guest cancellation](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-diagnostic-v1/probe-v2/guest-reply-log-v1/stdout)

The reviewed HingeReader postimage 87c761e6 waits for the first fresh sample, cancellation ACK host barrier and normal original reply after ACK enqueue. It keeps the three-second limit, request, decoder, deferred close and public API. An early reply fails safely. The live subscription close path is unchanged. The native derivative compiled in 24.67 seconds and staged with seven strict signatures in 1.91 seconds. Public headers/interfaces and exports are unchanged, with no added or removed symbol; dependency bytes stay unchanged. Signed native c946160e uses the unchanged CLI 8a994931. Build and staging alone were not simulator proof. The actual public library-path result below now proves this one read. The targeted checks below passed. Complete Duo133 passed. The separate transition groups remain failed. [Native proposal](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-proposal-v1/manifest.json)
 [Native build and signed runtime](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-v1/native-ready.json) [API review](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-v1/api-review-v1.json)

The actual public hinge command then passed on CLI 8a994931 and native c946160e, with the same verified Duo boot and zero input events. Exact serving broker 9279 loaded the staged c946 framework. For invocation 8B56D283-99ED-4B0E-8CBF-B746A965E0F5, the guest received the cancellation ACK at 14:50:15.954851, stopped angle updates at 15.954867, logged action success at 15.955010, destroyed this stream proxy at 15.955044 and invalidated the peer at 15.955136. Thus the new library reader completed this request after its cancellation protocol, before connection close. This does not identify or fix the earlier shared service pause. [Actual library-path proof](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-v1/actual-library-proof-v1.json)

The same signed c946 native then passed four existing checks. The eight typing cases completed in 160.21 seconds, the one typing and drag case in 28.97 seconds, and the two fold/rotation cases in 34.52 seconds. Each result has the exact CLI 8a/native c946, source ea9 and host 527 input map, a complete case ledger, zero issues and zero skips. The nine native host cases completed in 12.17 seconds and proved that its test process loaded c946. The guards show normal exit, reaped children, no stop reason and no crash. These are separate checks; their counts do not form a full Duo run. [Type8](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-type-v1/result.json) [Drag1](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-drag-v1/result.json) [Fold and rotation2](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-layout-v1/result.json) [Native9](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-v1/native-host9-v1/acceptance.json)

## Exact acceptance state

| Candidate and scope | Result |
| --- | --- |
| FINAL5 a9f3d8c1/553acba2; ordinary host 9b8dd89a, source eaf6f6f8 | One genuine full ordinary-iPhone run passed all 133 cases in 2002.62 seconds, with no issue or skip. [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-iphone-full-v1/result.json) |
| FINAL5 full Duo | 133 executed; 132 clean and one failed offscreen recovery tap. The unchanged repeat confirmed a clipped fixture target. The full run remains failed. [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-duo-full-v1/result.json) |
| FINAL6 focused test-only corrections; source b506332f, host baeea9a1, unchanged a9/553 | Nine focused cases passed: Duo lifecycle 1 and ordinary lifecycle/admission/ownership 1+6+1. These are not another ordinary full run. [Focused result table](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/keyboard-reliability-docs-proposal-v1/postimages/docs/audits/2026-10-29-keyboard-reliability.md) |
| FINAL6 Duo fullv1 | 133 executed; 132 clean and one stdin AX admission failure. DTX disconnected before input: zero events, cleanup not needed. No HID guest-barrier timeout. [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-duo-full-v1/result.json) |
| FINAL6 Duo fullv2 | 133 executed; 129 clean, four failed, no errors/skips. Initial rotation context hinge read timed out before dispatch; three Type cases failed Apple display-catalogue preparation at five seconds. Later stdin passed. No full pass. [Result](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-duo-full-v2/result.json) |
| FINAL7 8a994931/553acba2; source ea9f7785, host 527051ef | All 186 host cases passed in six complete groups. Raw admission 6 and retained-touch keyboard ownership 1 also passed. These focused results do not replace a full run. [Admission6](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-raw-admission-v1/result.json) [Ownership1](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-raw-keyboard-ownership-v1/result.json) |
| Hinge completion derivative 8a994931/c946160e; source ea9f7785, host 527051ef | The actual public hinge read passed. Typing8, typing and dragging1, fold/rotation2 and native host9 each passed in complete separate runs, with no issue or skip. One complete Duo run passed 133 cases with zero issues/skips; the separate transition groups remain failed. [Public read](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-v1/actual-library-proof-v1.json) |

The FINAL7 host groups are [ownership67](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-unit-v1/result.json), [boundaries63](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-boundary-v1/result.json), [payload12](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-legacy-keyboard-v1/result.json), [routes11](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-transport-routes-v1/result.json), [schema20](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-rigid-schema-v1/result.json) and [display13](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-display-discovery-v1/result.json).

Earlier native9, Duo modifier/cancellation5, text-source12, raw300-byte1 and keyboard-transition4 passes remain valid on their stated FINAL5 candidate. The [preserved prior audit](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/keyboard-reliability-docs-proposal-v1/postimages/docs/audits/2026-10-29-keyboard-reliability.md) retains their exact receipts and failed-run history. They are separate results, not a combined full Duo pass.

The reviewed 57-path checkpoint is applied locally. Its main-checkout compile passed in 39.77 seconds. All 14 protected paths, 61 managed-IDB entries and the index stayed unchanged. This is compile proof, not simulator acceptance. The new HingeReader derivative is excluded from that checkpoint. [Checkpoint receipt](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v1/receipt.json) [Main compile receipt](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v1/compile-only.json)

The second source integration added the reviewed canonical HingeReader patch and matching c946 compile input. Current main compiled in 41.64 seconds. The combined compile product was not installed or simulator-tested. Protected work, managed IDB, the index, main runtime and installed CLI stayed unchanged. [Source integration](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v2/receipt.json) [Compile](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v2/compile-only.json)

Remaining work: the seven failed transition cases are not accepted. The four fixture/test files remain on hold; no all-tests-complete, unfixable-Apple or new live-close correction claim is made. No push, publication, deployment or local CLI installation is part of this update.
