# Duo fixes and feature parity: active work

Goal: complete the fixes and feature coverage requested by Cam, prove them in isolated candidates, then integrate and verify the production library and AXe paths. A passing subset does not complete this goal. No commit or push is authorized.

17 October 2026. The previous work produced verified progress: [isolated V2 proof](2026-10-17-duo-isolated-fix-proof.md), with 62 final live cases passing. The current production source remains unchanged by this effort. Existing unrelated AXe changes must be preserved.

## Acceptance scope

| Requirement | Current evidence | Work still required |
|---|---|---|
| Current FlowDeck CLI/menu-bar app and RocketSim, licensed | Installed versions and activation recorded in earlier audit; user confirmed licences | Recheck installed and latest versions before final comparison. Do not inspect licence secrets. |
| Vendor mechanisms and implementation lessons | Earlier bundle/header/social/code audit and measured routing comparison | Update the comparison for final candidates; distinguish observed behavior, binary evidence and inference. |
| Runtime screen, AX display and HID target mapping | V2 live ID/UUID/geometry join and wrong-screen controls | Production discovery, validated target ownership, timeout/cancellation, boot invalidation. |
| Coordinate space and rotation | V2 positive paths at inner 0/90/180/270, outer and partial fold | Stale lookups, full gesture traces, app orientation/letterboxing, transitions during held input, public AXe paths. |
| Hinge and pose | Existing helper sets angles; FlowDeck reads mechanical/sensed state | Independent typed read/set capability, range errors, transition completion and fold revision. |
| Screen power, lock and simulator lifecycle | Raw power reads and earlier button outcomes | Separate APIs and independent state proof for display power, lock, boot and shutdown. No inference from a screenshot alone. |
| Find elements and selected-display AX | V2 point query finds selected text child | Whole-tree display semantics, selector/label/coordinate paths, ambiguity, wait behavior and remote/system content. |
| Pointer gestures and containers | V2 taps, hold, swipe, drag, two-finger tap and pinch effects | All directions/presets, double tap, two-finger hold, rotation gesture, zoom-out, slider, switch, nested scroll, exact timing and invalid input. |
| Retained contacts, failure and cancellation | V2 invalid-later-point reproduction leaves one contact; explicit recovery clears it | Whole-event preflight, owned tokens, cleanup, busy rejection, stale context and reconnect proof. |
| Keyboard and text | Earlier audit has valid seeded failures and completion gaps | Focus, file/stdin/positional input, key/sequence/chord semantics, release, Unicode policy and completion. |
| Screenshot, stream and record | Earlier audit proves wrong/black panels, orientation errors and PNG under JPEG contracts | Selected panel, upright output, format/stride/scale/fps/quality contracts and continuous fold/rotation policy. |
| Batch, broker and cache | Earlier audit proves failure after unfold in all cache modes | One session owner, invalidation/reconnect, failure policies, input completion and exact public schemas. |
| Provider agent | Earlier live check blocked by missing provider key | Finish local source/integration checks; verify actual provider when credentials are available without reading or retaining secrets. |
| Comparative performance and options | Diagnostic fixture runs only; no valid benchmark claim | Matched commands, poses, inputs, output criteria, warm/cold conditions and latency distributions. |
| Ordinary iPhone and supported legacy paths | V2 ordinary iPhone eight-case control | Production regressions, Indigo behavior and relevant existing tests. |
| Documentation and release record | Isolated proof and full gap audit saved | Update public command/options docs, skill source, changelog and run required skill validation after integration. |

Every existing public command remains in scope: describe-ui, list-simulators, init, agent, tap, slider, type, swipe, drag, button, key, key-sequence, key-combo, touch, gesture, stream-video, record-video, screenshot and batch. Internal broker paths also remain in scope. Help output is not device proof. Each exposed new screen, hinge, power or multi-touch option needs direct verification.

## Current isolated work

- Session implementation and focused checks: `/private/tmp/axe-duo-session-20261017/idb`.
- Session harness and normal UIKit fixture revision 6: `/private/tmp/axe-duo-session-20261017/harness` and `fixture`.
- Exact V2 invalid-later-point reproduction: `/private/tmp/axe-duo-session-20261017/red-repro/live/invalid-later-point`. Raw output shows active contacts 0 → 1 after rejection → 0 after explicit recovery. The first runner failed to parse multiline JSON; a separate offline decoder recovered the saved evidence without a live rerun.
- Typed hinge/display/boot capability work: `/private/tmp/axe-duo-capabilities-20261017`.
- Frame encoding reproduction and isolated correction: `/private/tmp/axe-duo-capture-20261017`.

These paths are active working candidates, not final evidence archives. Freeze hashes and copy the source, exact commands and reviewed results into this audit directory after each accepted slice. Keep V2 and all earlier failures unchanged.

## Current verification, 17 October 2026

- Session candidate `716081a6`: five preflight/selection cases passed on closed outer display. The exact invalid-later-point failure is corrected: no contact starts before the complete event passes validation. Five cancellation and five retained-contact cases delivered complete releases with zero active contacts. The cancellation queue correctly stopped because a later close changed the earlier confirmed cleanup receipt to uncertain. This is an open reporting defect in that candidate, not a proven stuck contact.
- The same session completed 11 taps, two swipes and a pinch on one connection: 15 guest contacts began and ended, with no active contact at the final readback. This is one closed-pose case, not all-pose coverage.
- Timing remains unacceptable in the first session candidate. Requested 100 ms contact intervals measured 449.336 ms retained and 442.133 ms composite. The old split-send control measured 294.098 ms. These are single guest-trace samples, not performance distributions. Full device reads between primitives are a measured design cost. Session V2 `3bf8f957` has a native change feed and corrected close receipts; live proof is pending.
- Native hinge candidate `5b153849`: set 0/90/180 with independent FlowDeck mechanical-angle readback; rejected -1/181/NaN/infinity without a change. Each panel separately powered off and on with native state readback. All nine cases passed; final pose was closed and both panel power values were on. Native hinge-read V2 has only stable-closed proof so far.
- JPEG correction: the unchanged default-quality path returned PNG for PNG input and accepted invalid data unchanged. The isolated correction passed five encoding/type/size/error checks. Live stream and recording paths remain open.
- [Validated gesture construction](evidence/2026-10-17-duo-gesture-construction/README.md): the old swipe factory generated NaN for distances 0, 0.1 and 5 with spacing 10. The new constructor passed 34 checks, including exact endpoints, complete paths, duration sums, pinch/rotation geometry and invalid input. Live gesture recognition and timing remain open.
- Selected-screen capture candidate `4b579207` rejected a valid closed outer selection with `staleSelection`, while independent before/after context matched and Apple capture succeeded. Preserve this failure. A diagnostic build will identify which guard rejected the capture before a correction is accepted.
- Installed FlowDeck CLI 1.33.0 matches its current release feed. RocketSim 16.7.0 build 337 matches its current released changelog entry; 16.7.1 is listed as upcoming. Final menu-bar visibility remains unverified.

Exact live commands and results currently reside under the session `evidence/closed-*`, capability `live-v1`, and capture `live` directories above. No production source, commit or push was made. `git diff --check` passed after this ledger update's preceding source checks. All pending cells in the acceptance scope remain open.

## Integration gate

Use the real library for input and the normal app surface for outcome proof. Reject before sending when context is invalid. Do not turn unsupported or uncertain behavior into a silent fallback. Hold requested, mechanical and sensed hinge values separately. Keep input timing separate from transport drain and connection lifetime.

Before integration, complete the [session proof groups](evidence/2026-10-17-duo-isolated/NEXT-SLICE-DESIGN.md). Then verify each affected public AXe route with the same measured display context. Update this ledger from current evidence, not planned behavior. The goal remains active until every required item is delivered and verified or Cam explicitly changes its scope.

## Follow-up evidence, 17 October 2026

- Session V2 `3bf8f957` failed stable native-feed startup because display enumeration changed the property seed without a semantic display change. V3 `2514ab54` removes seed from semantic equality and retains it in diagnostics. A 15-second stable run had 56 host snapshots, 140 refreshes, 141 motion samples, and no validation failure. After close, callback counters stopped. A separate real rotation produced host callbacks for both panels; host orientation is not the per-panel guest rotation.
- Session V3 passed five preflight, five cancellation and five retained-contact cases on outer display 1 at measured rotation 0. No contacts remained active and no cleanup receipt was uncertain. The prior close-receipt defect did not recur. One connection delivered 11 taps, two swipes and one pinch, with all 15 guest contacts ended. Raw evidence: `/private/tmp/axe-duo-session-20261017/evidence/closed-next-groups-v3`.
- V3 timing is still incorrect: requested 100 ms measured 0.060875 ms retained and 0.069208 ms composite in guest UITouch timestamps. The old split-send control measured 286.949292 ms. Host-side delays did occur. These are single samples; transport buffering is an unproved hypothesis. Gesture result labels PASS_BOUNDED cover delivery, expected UI effects and cleanup, not timing acceptance.
- Selected-screen capture V2 diagnostic showed seed-only guard rejection. V3 `857cfbb7` excludes that seed and checks power state. It returns the selected geometry, but both candidate and Apple captures remain black after confirmed normal app input. Opening the audit device in Device Hub also showed no guest content at first observation. This is unresolved; file creation and power readback do not prove image content recovery.
- Session V4 `f5223972` adds a bounded cancellable transport enqueue gate. A local held-callback reproduction showed V3 close remained busy after cancellation. Seven V4 callback ownership scenarios and the unchanged 19 session checks passed locally. Main-owned live proof remains pending. V4 does not claim to fix gesture timing.
- Native context V1 `379c2570` builds and can classify the installed Duo profile. It joins selected host and guest IDs/UUIDs, guest rotation, boot identity and native hinge samples without FlowDeck or simctl. Live full reads and process cleanup remain pending. Its explicit profile catalog and sequential snapshot limits remain prototype restrictions.

All frozen candidates remain separate. No production integration or commit has occurred.

## Targeted follow-up run, 17 October 2026

- [V3 source and session archive](evidence/2026-10-17-duo-session-v3/README.md): 680 exact files copied and hash-verified. Full source-input hashes and loaded framework paths identify the candidate.
- [Fourteen closed-panel gesture cases](evidence/2026-10-17-duo-gesture-live-v3/README.md): every expected endpoint matched exactly, expected app callbacks occurred, and all contacts ended. Timing remained incorrect. Pad pan is not nested scrolling or system-navigation proof.
- V4 closed-to-open transition rejected the stale outer-display tap before sending any input (enqueued=0, no new guest contact). It incorrectly reported cleanup as uncertain despite owning no input. A separate receipt correction is required; this is not a full cleanup pass. Raw evidence: `/private/tmp/axe-duo-session-20261017/evidence/v4-closed-to-open`.
- [Native context V1 live archive](evidence/2026-10-17-duo-native-context-v1/PROOF-RUNNER.md): both panel reads matched host/guest/hinge/boot references in the open pose, three invalid-selection cases matched exact errors, and eight cancellation cases returned with no matching helper at the four-second final snapshot. The helper was observed in both 50 ms cases; exact cancellation stage was not instrumented. This is bounded process cleanup evidence, not proof that an arbitrarily late spawn cannot occur.
- Both first and second capture surfaces remained black and unchanged during a 15-second observer run, with zero frame callbacks and one surface callback. Open inner-display capture also remained black. The next timing run stopped during setup: simctl terminate reported SpringBoard probably crashed (code 64), then fixture launch timed out at 40 seconds. No timing action ran on the inner panel. Recovery and a fresh baseline are required before more input.

## Recovery and timing correction, 17 October 2026

The audit SpringBoard report set ties the first display-configuration assertion to the inner-panel power-off result within about 39 ms (file mtime versus crash timestamp). Six crashes preceded power restoration. This is a strong temporal correlation, not an isolated causal test. Raw power callback/readback success is retained as narrow evidence; overall power capability acceptance is withdrawn. The later folding crashes occurred after that damaged state and need a clean-boot comparison. See `/private/tmp/axe-duo-wake-20261017/crash-review.md`.

The verified backlight-wake call timed out at 10 seconds. Post-wake Apple capture overlapped reboot, so that run cannot isolate wake recovery. A controlled shutdown/boot restored app launch and visible selected-panel capture. Boot identity changed from `86225:1792221343:967247` to `16309:1792225249:588057`, and both panel UUIDs changed. No power writes have occurred on the new boot.

On that clean boot, V4 requested 100 ms contacts measured 0.140/104.423 ms for first/repeated retained contact and 0.086/104.809 ms for composite contact. FlowDeck measured 103.737/104.394 ms. V6 `3b473fd3` adds the verified one-key guest HID barrier request after each event. The same four native samples measured 104.100/106.165 ms retained and 103.101/105.795 ms composite. This is a targeted first-contact correction, not a latency distribution or full gesture acceptance. Forty local checks also passed; production integration remains pending.

Selected-display AX candidate `870618f1` passed live closed-panel ID-only lookup for `feature.tap`, and unique ID/label lookup for `feature.text`, each checked against an explicit point query. Duplicate label `Tap counter` correctly rejected the button plus its text child as ambiguous. That failure is retained; matching rules were not weakened. Whole-tree rotation, folding, remote content and public CLI integration remain open.

## Clean fold and complete outer gesture matrix, 17 October 2026

- [V6 frozen source and proof archive](evidence/2026-10-17-duo-session-v6/README.md) retains 421 matching expected hashes and 1,578 verified files. It preserves the provenance correction and the V4-to-V6 timing comparison. All 14 outer-screen gestures delivered the intended app effects with exact endpoints and zero active contacts. Timing overhead remains open; these results do not prove scroll containers or public CLI routes.
- On the fresh boot with no power writes, a real native hinge change from closed to 180 degrees passed selected AX stale-reference rejection. A fresh screen-3 lookup found feature.tap at (433.5,161), guest rotation 90, with an independent point-label match. The selected screen UUID was 769ED878-389B-4346-9C56-CB0703AB3E58. Raw command and result: /private/tmp/axe-duo-ax-20261017/live/clean-fold-inner90.
- A post-fold capture showed the normal fixture on the inner panel. Native gesture tests are running there; each completed case is graded using actual guest contact coordinates and app callbacks. The prior power-damaged boot remains separate evidence.
- V7 native context/session candidate 89f52e06 built with 47 local checks. It has explicit verified Duo and ordinary iPhone 18 Pro capability policies. Live V7 integration remains pending; other profiles are rejected as unverified.
- Separate keyboard, slider, switch and nested/page scroll proof runners are prepared. This is preparation only until their main-owned live results are recorded.

## Inner-screen control results, 17 October 2026

All 14 V6 inner-screen gesture cases passed their endpoint, app-effect and complete-contact checks at guest rotation 90 after a clean fold. Maximum coordinate error was 0.166667 logical points. No contact remained active. Timing is reported separately and has no acceptance threshold in this matrix. Raw evidence: /private/tmp/axe-duo-gestures-20261017/live/open-inner90-v6.

Control checks used fresh selected-screen AX targets plus V6 input. The first switch runner stopped before candidate input because a visible control extended two points beyond the scroll viewport. The corrected prerequisite validates the actual hit point or straight-path endpoints inside the visible intersection; it does not require the entire control frame to be visible. Original blocked evidence remains.

- Physical 100 ms switch tap passed. The old zero-duration simulator tap delivered the same correct coordinates and released its contact, but did not change the switch through five seconds. Its guest duration was 0.338333 ms. An explicit tapAt duration of 100 ms then passed with guest duration 108.147 ms and exactly one switchChanged callback.
- Nested-list up/down passed. The list offset increased to 233 points and returned to zero; the outer page stayed at zero. Both contacts had complete releases and endpoint error 0.166667 points. These are real scroll-container effects, not pad-pan counters.
- Existing slider calibration failed. Requested75 settled at76.4926834 through five seconds despite endpoint error only0.0953 points and complete release. The public path uses fixed normalized offsets, which remain unaccepted across sizes. Native AX value-setting feasibility is the next isolated slice; another empirical offset is not planned.

Exact raw sets: /private/tmp/axe-duo-controls-20261017/live-inner90-switch-v2, live-inner90-switch-v3, live-inner90-slider-v3 and live-inner90-timed-switch-list-v4. All changes remain isolated; public CLI integration is pending.

## Native V7 session and active-panel boundary, 17 October 2026

V7 framework89f52e06 completed all19 inner90 session cases: five preflight, five cancellation, five retained-contact, three measured timing and one long-lived case. The queue reported no active contacts or uncertain cleanup. Requested100ms guest contact spans were108.224750ms retained and106.667208ms composite; the legacy split-send control was499.469833ms. These are individual samples, not a benchmark distribution. Exact command: DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer python3 /private/tmp/axe-duo-session-20261017/harness-v7/run-session-groups.py --udid 3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463 --display-id 3 --rotation 90 --out /private/tmp/axe-duo-session-20261017/evidence/native-inner90-v7 (actual argument separation is retained in queue-contract and per-group command JSON).

Panel membership is not active-panel proof. Frontmost AX can ignore the requested display ID. Current positive cases also use independent point queries and actual guest input on the active panel, so those bounded results stand; they do not prove rejection of a valid but inactive panel. CAD mainDisplay remains outer1 even when inner3 is active. A verified Apple FrontBoard monitor path exposes an active hardware identifier, but the first live guest probe returned currentLayout=nil and exit2, with successful monitor invalidation. Preserve /private/tmp/axe-duo-active-display-20261017/live-open-inner90.json. Bounded asynchronous initialization is under investigation; no active-panel fallback is accepted.

AX V2 ownership and request-cleanup fixes built with22 local cases. Its typed snapshots include AXValue. Live acceptance is pending. The rotated root-frame mismatch also affects default remote grid bounds; a separate selected-logical-screen correction is in progress.

## Isolated AX, hinge and media follow-up, 17 October 2026

AX V3 framework 8c238b9c uses measured logical screen bounds for default remote sampling. Five V2 bounds failures were reproduced; V3 passed 28 local cases. Live inner90 queries completed at right point (800,150) and bottom point (450,600), with exact feature.tap and feature.row.04 identities. Raw sets: /private/tmp/axe-duo-ax-20261017/live-remote-grid-v3-{baseline,right,bottom}. These establish grid completion and point identity; they do not establish discovery of separate-process remote content.

The keyboard V6 queue stopped before candidate input: FlowDeck resolved feature.text at (433,409), but normal fixture trace recorded (542,433), hitting UIStackView, with focus false. This equals (951-y,x), but the vendor root cause is not established. The preceding FlowDeck tap counter action reached (433.667,161) correctly. Preserve /private/tmp/axe-duo-keyboard-20261017/live-inner90-v6, including blocked-state.json. A new setup uses selected-context timed input and fresh AX coordinates; no keyboard pass is claimed.

Active-display V2 delivered one monitor callback but both layout arguments were nil; 52 reads over 1.505 seconds still returned no layout. It exited2 and invalidated its monitor. Callback delivery alone is not active-panel proof. Raw /private/tmp/axe-duo-active-display-20261017/live-open-inner90-v2.json.

Typed hinge candidate 51c58125 passed ten bounded live cases: invalid negative/high/NaN and stale-boot rejection, 0/90/180 mechanical set/readback, immediate and20ms cancellation, and explicit restoration to180. Native and independent FlowDeck mechanical values matched every case. Immediate cancellation was notDispatched;20ms cancellation was uncertain and final observed angle remained180. This does not prove successful post-dispatch cancellation or UI transition completion. At requested90, sensed angle was85.378685; it remains separate from mechanical90. Raw command, receipts and runner: /private/tmp/axe-duo-hinge-20261017/live-typed-v1 and run-live-typed-v1.py. No power writes occurred.

Stream V2 captured and independently decoded15 frames each for MJPEG, length-prefixed JPEG, concatenated JPEG and packed BGRA at inner90. Visible content was upright. MP4 decoded15 frames but failed the unchanged10us PTS check: AVFoundation chose600Hz track timing despite1MHz source CMTimes. Isolated stream V3 sets the verified public input.mediaTimeScale to1,000,000 before writing. The repeated live MP4 run passed, maximum PTS error0.959us,15 decoded712x500 frames. Source BGRA was713x501; MP4 uses documented even dimensions. Static content is not dynamic rendering or transition proof. Raw /private/tmp/axe-duo-stream-20261017/live-inner90-static-v2 and live-inner90-static-v3.

Slider AX V3 feasibility: setValue(NSNumber(75)) returned, and fresh AX reads were75 at return/0.6/5 seconds. No normal fixture event published and sliderChanged remained0. A separate fresh selected100ms tap on feature.tap then published the actual UISlider value75 exactly, with tap count+1, no active contacts, and still no sliderChanged. This is precise value mutation but not equivalent to a user drag. Raw /private/tmp/axe-duo-slider-20261017/live-inner90-set75-v3 and live-publish-tap. The production slider fix must also preserve app event delivery.

Active-display clarification: current FrontBoardServices has a one-second initial-update timeout that publishes nil. V2/V3's nil callbacks match that path; they are not evidence of a live layout service. V3 resolved the default endpoint unchanged to com.apple.frontboard.systemappservices, service com.apple.frontboard.layout-monitor, instance com.apple.frontboard.main-display. It still had no layout. Raw /private/tmp/axe-duo-active-display-20261017/live-open-inner90-v3.json.

## Active-screen source and remaining input failure, 17 October 2026

Xcode27.2 devicectl device info displays --device AUDIT_UDID --timeout5 --json-output NEW_FILE succeeded on the simulator. Its v5 JSON reports outer1 primary=true/active=false and inner3 primary=false/active=true, with exact independently measured panel UUIDs and inner rot90. Typed host-reader-v1 c0dbca50 passed20 file-only rejection/decoder checks and a main-owned live read. Raw supported response and typed output: /private/tmp/axe-duo-active-display-20261017/devicectl-audit-displays.json and live-host-inner90-v1. This is a completed snapshot, not a continuous input guard. The V4 guest helper with the exact publisher entitlement could not launch (Security policy issue163); that failed access route is retained.

Keyboard setup V7 proved fresh selected AX target focus using100ms input. Fourteen cases passed their stated checks: Backspace/Return with default and held forms, Shift, Cmd+A replacement, sequence, positional/file/stdin, empty, trailing newline, Unicode rejection, and30-character text. Unicode remains unsupported; safe rejection without partial input is the passed property. The150-character case failed after7 characters (Ab1Ab1A): native feed became stale/uninitialized, execute and close reported uncertain cleanup. The queue stopped. No further Duo input was sent pending release-only recovery and feed investigation. Raw /private/tmp/axe-duo-keyboard-20261017/live-inner90-setup-v7/text-150. A separate ordinary-device session queue was running at this time; interference is unproved.

Ordinary iPhone18Pro native V7 discovery succeeded without a hinge request. The first queue stopped before candidate input because the existing AXe bootstrap timed out at5 seconds. Exact retry succeeded in0.529 seconds; a separate unchanged warm queue then passed preflight, cancellation and retained groups so far. Cold failure remains /private/tmp/axe-duo-session-20261017/evidence/native-ordinary-v7; current warm output is native-ordinary-v7-warm.

Main independently verified all archived file hashes: inner90 gesture/control821; native V7 session952; timed switch/list761; AXV3 460; hinge/slider/media471. No mismatches. Production source remains unchanged by this effort.

## Release recovery and next diagnostic, 17 October 2026

The release-only helper c08a29e1 completed exactly four key-up sends for225,4,5,30. It checked the failed run boot/screen/geometry/rotation and mechanical180 before sending, then checked fresh native context before each send and after all sends. All guest barrier/drain calls returned; helper exit0. This proves transport completion, not observed guest key release. Exact command is in /private/tmp/axe-duo-feed-recovery-20261017/manifest.json and output is live-release-once. No key-down or automatic retry occurred.

Read-only feed review found sequential motion and display renewal with component deadlines of3 seconds and a500ms freshness limit. Display callbacks do not refresh the display age. The saved text failure has no age/phase trace, so its exact cause remains unknown. A separate diagnostic candidate retains the same limit and dispatch policy. No cross-device routing defect is proved.

The ordinary iPhone18Pro warm V7 queue has now completed all19 cases with no active contacts or uncertain cleanup. The cold AX bootstrap failure remains separate. The combined V8 candidate built with47 session and28 AX local cases passing; it has no live acceptance yet and does not fix the long-text failure.

Static devicectl --stream produced only a human-readable initial table. The JSON file appeared after5 seconds with the timeout error, without structured initial or update records. The bounded collector reaped the child. This does not provide an accepted continuous active-screen feed. Raw /private/tmp/axe-duo-active-display-20261017/live-stream-static-v1.

## Long-text diagnostic and slider actions, 17 October 2026

Diagnostic framework b40dba9a changes only bounded trace recording from V7. It passed47 existing and3 trace checks. Main verified32 frozen dependency hashes without mismatch. The exact150-character case alone delivered400 events in6.212485 seconds, exact150 textChanged events and exact text at return/0.6/5-second readbacks, with no uncertain cleanup. Its65 renewals had maximum motion/display gaps119.484/121.816ms and no old-sample rejection or stale check. This is a non-recurrence under the stated conditions, not a fix. Raw /private/tmp/axe-duo-feed-diagnostic-20261017/live-text150-alone.

Host-only serial bounds place the ordinary busy-during-action FlowDeck setup tap command inside the earlier keyboard input/cleanup interval. The ordinary native action began after the keyboard error. The first stale-check time was not recorded. The overlap does not prove cause. Derivation: /private/tmp/axe-duo-keyboard-20261017/text150-ordinary-overlap.md. Guest touch timestamps are excluded from that clock comparison.

Slider action candidate849053cf invoked each declared AX action once. Increment changed AX and normal fixture value50→60.0000038; decrement changed60.0000038→50.0000076. Each produced exactly one sliderChanged event, with stable values through5 seconds. These prove step actions with app events, not arbitrary75 target precision. Raw /private/tmp/axe-duo-slider-actions-20261017/live-inner90-increment-v1 and live-inner90-decrement-v1. Physical feedback remains a separate isolated candidate.

Main verified all1,104 payload/seal hashes in evidence/2026-10-17-duo-ordinary-active-display without mismatch. No production integration or commit has occurred.

## Dynamic capture and app-orientation evidence, 17 October 2026

All five dynamic V3 formats passed independent decode and actual UI-effect checks at inner90: MJPEG29frames, raw29, concatenated-JPEG30, BGRA30, MP4 30. Each normal selected tap incremented the visible counter by one and completed its contact. Main inspected first/last images for every format: correct visible fixture, upright image and matching counter change. MP4 timing retained the unchanged10us check. Raw /private/tmp/axe-duo-stream-20261017/live-inner90-dynamic-v3, including visual-review.json. This does not prove capture during fold/rotation.

Landscape-only normal fixture launch first returned emptyHierarchy from AXV3 before input. A later fresh tree succeeded, but the original proof expected the button ID from a point query that correctly returned its StaticText child. V3 proof now requires exact point-node membership in the selected button subtree, including PID/type/label/ID/frame; no library matching was weakened. The inner90 tap passed: one complete110.338ms contact, one app tap, endpoint error0.166667pt and unchanged app/native geometry. Raw /private/tmp/axe-duo-letterbox-20261017/live-inner90-tap-v3.

FlowDeck orientation set landscape-left reported success with confirmed=false. Independent host active read showed inner3 stillactive, rotation0. UIKit then reported portrait orientation1 and669x951 bounds despite the app landscape-only declarations. The selected screenshot showed the same portrait layout. The proof stopped before input because the expected fixed landscape precondition was absent. No letterboxing is proved. Evidence: active-inner0, inner0-before.png and live-inner0-tap-v3/blocked-state.json in the landscape root. The pose was explicitly restored with the Duo-capable DEVELOPER_DIR; an earlier omitted-environment command rejected before action.

Main independently verified all2,733 payload hashes in the keyboard/feed-failure archive without mismatch. The manifest is the2,734th file. The controlled Flow tap overlap completed exact150 text,400 input events and no uncertain cleanup; maximum motion/display gaps120.507/120.216ms. The original stale-feed cause remains unresolved.

## Active admission and physical slider follow-up, 17 October 2026

V9 framework4c9215e5 passed47 session and49 AX/admission local cases. Main verified26 helper/source/framework hashes. Live selected inner3 at rot90 passed the complete active ID/UUID join. Explicit outer1 was rejected as inactiveSelection before input. Ordinary iPhone18Pro was rejected before input because Apple schema5 omits the active field for its single display. This is an ordinary-device compatibility defect in V9, not a reason to accept missing active state on Duo. Exact outputs: /private/tmp/axe-duo-combined-20261017/v9-live-{inner-active,outer-inactive,ordinary-active} and v9-ordinary-devicectl.json. A separate correction is required.

Physical slider feedback V1 binary0e2c2342 failed requested75. Its retained contact began on the thumb at50 and one large move reached the requested point. Fresh AX remained50 during the held contact, so the measured-response guard stopped without a search or retry. Cleanup reported releaseEnqueuedAndDrained; final normal fixture value52.9607468,21 sliderChanged events and zero active contacts. The later readback matched. Raw /private/tmp/axe-duo-slider-feedback-20261017/live-inner90-target75-v1. This is a failed precise-value proof, with complete release. Compare sampled-path delivery and UI response before changing the correction method; the0.07 tolerance remains unchanged.

The first normal-fixture cold setup for that slider run failed with DTXProxyChannel Code1 Channel disconnected before input. A separate warm setup passed through the visible Reset control. This cold failure is distinct from the landscape fixture emptyHierarchy failure. Exact setup evidence: /private/tmp/axe-duo-slider-feedback-20261017/setup-inner90 and setup-inner90-warm.

V9 completed all five inner90 preflight/selection cases: tap, invalid later point, invalid nested pair, invalid target and invalid UUID. Valid input produced the expected tap; invalid composites produced no partial contact before valid follow-up. All cases ended with zero active contacts and no uncertain cleanup. Raw /private/tmp/axe-duo-combined-20261017/live-inner90-v9-preflight. The single initial active read took0.298498s, including0.083216s devicectl child time. These are individual samples, not a latency benchmark.

## Cold AX lease comparison and V10 schema correction, 17 October 2026

Main verified215 lease candidate artifact/build-input hashes. An explicit cold normal-app comparison reproduced emptyHierarchy in baselineAXV3 (1.74753s) and leaseV1 (2.17180s). V1 preserved a zero-frame Application root with exact launched PID69007 and no children. Its eight AX requests completed non-nil in0.18–2.10ms; the session remained retained until local close returned. Thus session lifetime alone does not fix cold readiness. Both separate app-switch reads passed exact feature.tap/PID69007 at inner3rot90. These are distinct setup conditions. Raw /private/tmp/axe-duo-ax-readiness-20261017/live-normal-cold-* and live-switch-*.

Lease cancellation at0ms returned CancellationError before session acquisition; the500ms stimulus returned CancellationError after loaded/close-start/close-returned. Total command times0.529s and1.304s are not cancellation-response latency. No input was sent. Cleanup evidence is local invalidate return only; there is no Apple server acknowledgement. Raw live-cancel-zero-v1 and live-cancel-500ms-v1.

V10 framework0afdb04d passed47 session and73 expanded AX/admission local cases; main verified26 helper/source/framework hashes. The ordinary live read now succeeds using the exact verified single integrated panel/profile/devicectl-version policy. It preserves missing active state and records selectionBasis=verifiedSingleIntegratedPanel. No Duo missing-active fallback was added. Raw /private/tmp/axe-duo-combined-20261017/v10-live-ordinary-active.json. Duo and ordinary input checks for V10 remain pending.

## Visible orientation lock and confirmed rotation, 17 October 2026

The separate public-UIKit orientation fixture com.camsoft.duo-orientation-probe PID69854 installed and launched. Its first cold selected AX read failed emptyHierarchy; the separately recorded warm read passed. A visible Landscape button produced UISceneErrorDomain101: current window mode does not allow programmatic interface-orientation changes. The visible lock control did enable actual effectiveGeometry.isInterfaceOrientationLocked, confirmed by callback.

A FlowDeck landscape-left request while app lock was on reported success/confirmed=false. Fresh native and Apple reads still showed display rot90; a selected tap passed at the unchanged geometry with0.166667pt error and complete release. The directory name live-locked-inner0-readiness describes the requested test pose, not the actual90 result. It does not prove mismatch or letterboxing. Main inspected the selected screenshot.

After a visible unlock, actual lock became false and the app/native screen changed from inner90/951x669 to inner0/669x951. The unlock touch completed before the change; the session post-input check returned staleContext with cleanup notNeeded. A fresh AX lookup and tap then passed at inner0: tap+1, complete release,0.166667pt error, no host error. These prove safe refresh and input in the two measured geometries. App/window and screen coordinates matched; fixed screen coordinates differed at90 as expected. No fixed-app-orientation mismatch or letterbox transform is proved. Exact records: /private/tmp/axe-duo-orientation-20261017/live-request-landscape, live-lock, live-locked-after-rotation-tap, live-unlock, live-unlocked-inner0-tap.

Main verified archive payload hashes without mismatch: active-admissionV9 1791, slider-feedbackV1 RED519, and separate coldDTX13. Each archive manifest is additional. No production edits or commit.

## Sampled slider and AX notification diagnostic, 17 October 2026

SliderV2 e09c3a9b delivered a physical result within the unchanged75±0.07 tolerance:50→73.8038788→75.0691986, one measured correction. The .6s/5s settled AX and fixture readbacks matched. Normal applicationProof=true,147 sliderChanged events, one complete contact and zero active contacts. Overall passed=false because the final read returned15.687s after the original15s budget boundary. CleanupnotNeeded and sessionclosed. Exact command wall time17.927s includes setup before that budget. Raw /private/tmp/axe-duo-slider-feedback-20261017/live-inner90-target75-v2. Initial210.75pt motion and10.59pt correction each used120samples and took about3.21s. Preserve this timeout result; a smaller correction-sampling policy is a separate candidate, not a relaxed deadline or tolerance.

AX notificationV2 4ff6e27a registered verified notification1021 after load, then waited for the exact selected PID72422 active status. No status arrived within5s; command exited1 after6.762s and local close returned. No tree retry or input occurred. This does not prove notification delivery or initial-status availability. Raw /private/tmp/axe-duo-ax-readiness-20261017/live-normal-cold-readiness-v2.

V10 still rejects valid-but-inactive Duo outer1 with exact inactiveSelection. Ordinary schema correction did not weaken that guard. Raw v10-live-outer-inactive.stderr.

## Stale and held rotation controls, 17 October 2026

V10 bound inner90, performed one real rotation to0, then rejected the old tap as staleContext before input. Session closed, enqueued0, no new guest counts and0active contacts. PASS_BOUNDED. The next separate held-contact run rotated0→90: stale move rejected, same boot/panelUUID/nativegeometry, one begin/oneend and0active contacts. Receipt remained uncertain on rejection andclose, so overall REJECTED_WITH_UNCERTAIN_CLEANUP. Existing V10 policy conservatively marks stale cleanup uncertain; its trace cannot distinguish a completed release/barrier/drain from an error within cleanup. A separate diagnostic is required. Raw /private/tmp/axe-duo-combined-20261017/live-v10-stale-rotation-inner90-to0 and live-v10-held-rotation-inner0-to90. Input stopped after the latter; guest zero alone does not upgrade the receipt.

Apple devicectl lockState returned CoreDeviceError1001: Get Lock State unsupported by this Duo simulator. Raw /private/tmp/axe-duo-power-20261017/audit-lock-state-read.json. It is not an independent lock read capability on this runtime.

The AX notification delivery control did receive1021 callbacks, but its strict payload decoder rejected missing suspended fields. The target switch-back launch exceeded its3s control bound; the control terminated that launch process and the AX helper, so it has no local lease-close proof and does not pass. Exact timelines/commands: /private/tmp/axe-duo-ax-readiness-20261017/live-notification-switch-control-v2. Later selected screenshot and fixture read inspect actual state separately; no input retry occurred.

## Release transport and notification schema, 17 October 2026

V11 framework aafccae0 repeated the exact held inner0-to90 transition. The stale move was rejected; the app recorded one complete contact and zero active contacts. New cleanup records prove successful host enqueue, guest barrier and drain, with no timeout. Before/after-close records match. The outcome remains uncertain because screen identity was not read again after interruption. This is transport completion evidence, not a corrected cleanup contract. Raw: /private/tmp/axe-duo-combined-20261017/live-v11-held-rotation-inner0-to90. A separate identity-aware cleanup candidate is required.

AX notification V3 ff18e519 completed both app launches with the same target PID76819. Eight1021 callbacks decoded; the actual keys are display-type(number), pid(number), suspended-status(string). The assumed suspended field was absent. AX readiness still timed out under unchanged rules; local close returned and the child exited without forced termination. This proves callback delivery and a schema mismatch, not cold readiness. Raw: /private/tmp/axe-duo-ax-readiness-20261017/live-notification-switch-control-v3.

The fresh disposable power device116F3CD1-3B6A-4045-AE6D-A3B1B7D36E05 reported Data Migration Failed (terminal status3) during first boot despite command exit0. No power/backlight write or fixture install preceded this failure. Booted state and an active outer display do not establish a clean comparison baseline. Read-only diagnostics remain separate under /private/tmp/axe-duo-power-20261017/fresh-outer-post-boot-read.

Main verified hashes with no mismatch: orientation-lock archive364 payloads, sliderV2 budget-failure archive80, sliderV3 local-only archive18, AXV3 candidate22. SliderV3 local archive has no live claim. Production source is unchanged by this effort.

## V12 release fix and inner0 gesture matrix, 17 October 2026

V12 framework f2be41e2 passed the exact held-touch inner0-to90 reproduction. Fresh cleanup identity reads matched the original boot, panel ID/UUID, native size and scale before and after release. Release enqueue, guest barrier and drain completed. The stale move was rejected; one guest contact ended and none remained active. The cleanup receipt is releaseEnqueuedAndDrained and remains unchanged after close. Main verified492 candidate source/helper/framework/check hashes. Raw: /private/tmp/axe-duo-combined-20261017/live-v12-held-rotation-inner0-to90. This is bounded original-target release confirmation; it is not an atomic display/input guarantee.

All14 V10 inner0 gesture cases passed their unchanged endpoint, app-effect and complete-contact checks. Maximum endpoint error0.166667 logical points. Cases include double tap, pinch in/out, both rotation gestures, two-finger hold, short/zero swipes, four swipe directions, hold and drag. No uncertain cleanup or active contacts remained. Timing is measured separately and has no pass threshold in this matrix. Raw: /private/tmp/axe-duo-gestures-20261017/live-v10-inner0-owned.

SliderV3 physical feedback passed the same75±0.07 tolerance and15s operation limit: final75.0691986,136 value-change events,1begin/127moves/1end,zeroactive. The operation interval through final sample has a conservative12.958812s upper bound; full command15.272277s includes setup. Only the correction sample count changed from120to7. Arbitrary initial thumb geometry, endpoints and other poses remain open. Main verified65 payload hashes in evidence/2026-10-17-duo-slider-feedback-v3-live.

Installed FlowDeck1.33.0[fac60d] still matches the official latest.txt feed on17October. RocketSim16.7.0build337 still matches its released changelog;16.7.1 remains upcoming. RocketSim native inspection showed its side-window AX surface; the status-item inspection timed out, so the menu-bar icon is still unverified. No production source edits, commit or push.

## Fold release and first public CLI proof, 17 October 2026

V12 held inner90-to-outer0 folding passed the unchanged transition checks. The app cancelled its one contact during the fold before cleanup sent release. The library independently confirmed release enqueue/barrier/drain on the original inner3 connection, with matching original boot/UUID/size/scale before and after. Active outer1 was verified separately. No uncertain cleanup; no active contact; old-context move rejected. Raw: /private/tmp/axe-duo-combined-20261017/live-v12-held-fold-inner90-to-outer0.

Public isolated CLI5ba108e6 using exact V12 passed outer0 tap at fresh AX point(191,161): exactly one app tap and complete contact with zero coordinate error. Retained touch(191,246)to(221,246) produced one complete contact and a pan event. Both selected and legacy competing clients were rejected before input. A separate point(9999,161) failed pointOutsideDisplay with enqueued0 and unchanged app counts/trace. Main read exact receipts and guest traces; app-proof.json files record these bounded passes. Raw: /private/tmp/axe-duo-broker-20261017/live-outer0-public-{tap,retained,invalid}-v1. All other public routes remain unproved.

AX acquisition13d89688 passed current outer0 in one attempt, then reproduced the original inner90 cold empty tree as explicit notReady and obtained the valid tree on attempt2 under the same lease/deadline. Both attempts had exact launchedPID14544; fresh targets matched inner3/UUID/rotation90. Local lease close returned. No relaunch, restart or readiness sleep occurred inside acquisition. Main verified224 compiled-source/product/helper hashes. Warm and app-switch checks passed; wrongPID stopped with processChanged; cancellation0/500ms reported cancelled;1ms budget reported deadlineExceeded; missing selector failed after one ready tree. The1ms case still took about327ms through the inherited provider call, so this is not a hard end-to-end deadline guarantee. Raw: /private/tmp/axe-duo-ax-readiness-20261017/live-acquisition-v1-inner90-cold and live-acquisition-v1-negative-queue.
