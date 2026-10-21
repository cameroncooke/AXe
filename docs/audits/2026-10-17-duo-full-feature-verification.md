# AXe Duo feature audit

Date: 16–17 October 2026. Completed audit of the unchanged AXe candidate. Coverage and unverified cells are explicit below; this report does not claim delivered Duo support.

AXe does not yet provide complete Duo automation. The closed outer display has some working physical-input paths. The final six inner-display pointer checks produced no required outcome through 5 s, with a valid FlowDeck positive tap before each action. Separate diagnostic target-aware input can activate that display. Text injection can work after another path establishes focus. Finding a control, accepting a command, and activating that control are separate results.

## Direct parity and missing work

Results below cover the named installed CLI paths and observed Duo poses. Interface availability is separate from live proof.

| Area | AXe candidate | FlowDeck 1.33.0 | RocketSim 16.7.0 | Required AXe work |
|---|---|---|---|---|
| Find and tap | Whole AX trees expose controls; inner point lookup is wrong. Automatic taps fail at bounded readback; physical tap is mixed on outer and absent on inner. | Find/wait/assert interfaces; selector tap, hold and double tap work outer and inner rot0. | Outer selector tap works; inner selector tap has no observed effect. | Separate AX query space, panel ID and HID target; use current display geometry for every route. |
| Pointer gestures | Outer drag/hold and some scroll paths work. Inner tested paths have no required effect. No public pinch, rotation or two-finger command. | Outer tested gestures work. Inner tap path works, but coordinate/multi-touch playback has no observed effect and uses target 0 in the inspected path. | Outer swipe/list/two-finger actions work; one-finger hold lacks longPress. Inner pointer actions have no effect. Container discovery is blocked. | Shared target-aware dispatch, retained-contact lifecycle, all eight presets, named multi-touch and container gestures. |
| Text and keys | Text can be exact after assisted focus and settling. Some commands return before text appears. Backspace/Return/chords fail valid seeded checks; composite batches time out. | Own focus plus exact text works on outer/inner; key-editing parity was not matched here. | Own focus/text work outer. Inner own focus fails; assisted typing yields only R after 5 s. | Define completion/readback, verify key release/flush, and separate focus from typing success. |
| Capture | Closed/refold output is black; rotated inner output can be sideways/upside down. JPEG contracts can emit PNG. | Capture interface available; full matched continuous-media matrix not run here. | Capture interface available; full matched continuous-media matrix not run here. | Active/requested panel, per-frame orientation, encoding/stride contract and recording resize policy. |
| Hinge, power and display | No public panel selector, hinge/pose, display power or simulator lifecycle control. | Pose and angle 0–180; boot/shutdown advertised. No physical-panel selector or display-power CLI verified. | Closed/book/open pose; hinge readback. No physical-panel selector or display-power CLI verified. | Expose each capability with independent state readback; lock/side-button is not display power or simulator shutdown. |
| Batch and agent | All three cache modes miss the second tap after unfolding. Parser/error paths work in bounded checks. Provider agent blocked by missing key. | Batch interface available; equivalent fold-batch/agent run not performed. | Snapshot-hash guard available; equivalent batch/agent run not performed. | Invalidate transport and AX state on pose changes, reject stale actions, and verify provider path with credentials. |

Evidence: [saved-run review](evidence/2026-10-16-duo/features/feature-run-review.md), [vendor and preset review](evidence/2026-10-16-duo/features/vendor-preset-review.md), [FlowDeck target split](evidence/2026-10-16-duo/features/flow-gesture-routing-review.md), [continuous recording review](evidence/2026-10-16-duo/features/transition-media-review.md). Earlier [display routing proof](2026-10-16-duo-display-routing-proof.md) and [control mechanisms](2026-10-16-duo-control-mechanisms.md) establish separate diagnostic capabilities; they are not production AXe support.

## Candidate and method

- AXe binary: /private/tmp/axe-duo-audit-20261016/build/out/Products/Debug/axe, version v1.8.0-1-g7163081-dirty, SHA256 08dfa7f0720ff0659cd037517cb77a7789adf07ff4b7f97e7d11ac11ce64458e.
- Repository HEAD 7163081400b59f1df40bff44f3a94dded38eea9a plus pre-existing dirty source. The source-continuity check at 2026-10-16T23:11:18.095Z found all 67 manifest entries unchanged, with zero missing. No product source was changed for this audit.
- Live host: Xcode 27.2 build 27B5038j, iOS 27.2 Duo runtime 24B91011. Dedicated simulator 3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463. Existing compatible IDB/AXe payload was built with Xcode 27.0 RC; do not present this as a fresh 27.2 framework build.
- Normal UIKit fixture exposes visible controls, stable AX identifiers, event counters, and Documents/state.json. Revision 3 binary b458324dad7384b781c6240b8997ce29abd670aacb7c95a56521158be9cee08b; separate revision 4 binary 4694fdba039feb47c08da58492a1410f6cf88b76378d571467678f7dc8d3b3b7 adds real UIWindow touch observation. Raw command records identify the candidate and fixture used.
- State/output pairs, fresh AX, independent Apple captures and display/hinge readback are the evidence. Exit 0 is not a UI pass. The diagnostic writes state during events, so it is not a performance benchmark.

## Evidence exclusions and setup boundaries

1. Fixture revision 1 failed the SDK's required UIScene lifecycle. Revisions 2/3 initially had a white launch transition. Those captures are excluded. Revision 3 later showed all controls and a reference target 1 tap incremented its counter.
2. Initial closed-run cases after the held-contact sequence lacked a verified reset. Rows marked CONTAMINATED in feature-run-review.md are excluded from isolated failure or success claims.
3. The isolated closed rerun stopped the audit broker between retained-contact sequences and established new baselines. Later valid runs used fresh FlowDeck selector taps for Reset and stopped on failed reset. These are assisted setup procedures, not AXe end-to-end passes.
4. Reference focus is reported separately. Closed physical AXe focus or explicit-target helper focus does not make automatic AXe focus pass.
5. The original partial-fold reference failed, so its no-op rows are inconclusive. A later FlowDeck tap succeeded in partial fold, but focus remained blocked. The refold run had valid helper and FlowDeck positive controls; it stopped when revision 4 crashed during the list gesture, before slider/batch/keyboard.
6. Revision 4 has a fixture defect: touch.view was nil and its hitView dictionary value became nil. The crash stack does not establish the touch phase; a later v5 rerun recorded a nil hit view on an ended event. Crash logs DuoFeatureProbe-2026-10-16-233205.ips and DuoFeatureProbe-2026-10-16-234552.ips identify observeWindowTouch. Exclude refold-valid-list-swipe and supplemental-closed-default-scroll-up partial/no-end observations from AXe failure claims. Revision 5 guards this value with (none); reruns require separate evidence.
7. Inner180 automatic tap/hold and inner270 double-batch retries completed but had no required effect. Their earlier timeouts remain recorded. Inner180/270 and partial keyboard retries were blocked by focus. Cases absent after a failed prerequisite are blocked, not failed keyboard checks.

## All 19 public commands

Disposition covers the tested variants only. Help succeeded for all 19 commands; that establishes discoverability, not device compatibility.

| Command | Current disposition | Missing verification or capability |
|---|---|---|
| describe-ui | Whole trees expose fixture controls; closed point query finds Tap counter text. Inner point queries returned an unrelated empty 1398×2034 group. | Panel-specific AX hit-testing and coordinate contract; refold/partial completion; system and remote content. |
| list-simulators | Duo listing and boot-state output obtained. | No panel discovery or per-display capabilities. |
| init | Print, temporary install and uninstall completed with exit 0. | Host-only skill operation; force/client-selection variants not exercised here. |
| agent | Blocked: TYPESAFE_API_KEY missing. | No live provider action or fold/rotate recovery proved. Source supports only a subset of CLI actions. |
| tap | Mixed on closed: physical selector button tap worked; automatic/simulator/coordinate/label routes and switch did not meet expected outcomes. Inner pointer variants failed or were blocked. | Value/type combinations, selector ambiguity/wait boundaries, duplicate safety and complete state coverage. |
| slider | Closed 75 reached 74.953445. Sequential 25 reached 28.026072;0 reached 0.372439;100 stayed 0.372439. All four inner 75 attempts stayed 50. Missed targets returned errors. | Repeated-transition and vertical-slider support remain missing; refold run stopped before this case. |
| type | Exact Duo123 appeared in valid assisted-focus cases. Auxiliary stdin/file mismatched at 0.6 s. Repeat stdin was exact; repeat file became exact by 5 s. Chunked batch matched 150 characters; composite timed out at 79. Unicode emoji rejected explicitly. | File command returned before text settled. Pointer focus remains separate; prior mismatches do not prove permanent loss. |
| swipe | Closed vertical list moved 224.33 points. Closed horizontal swipe delivered some contact/pan events but not the required >50-point displacement. Inner attempts had no required effect. | Reverse directions, option ranges, retained-state transitions and reference comparisons. |
| drag | Closed isolated drag produced pan+1 and 98-point horizontal displacement. Inner attempts had no required effect. | Other directions, durations/steps and mid-gesture fold/rotation. |
| button | Valid follow-up on both panels: side-button --duration .2 showed lock/clock wallpaper; home --duration .2 showed Home. Default side-button left the fixture visible. All six calls exited 0. | Duration changes observed behavior. Initial default runs had absent effects or blocked setup; Siri/Apple Pay remain setup-dependent. Display power/backlight and lifecycle state were not read directly. |
| key | Backspace 42 and Return 40 had no required effect in core valid-focused cases. Auxiliary held Backspace had an invalid empty seed. A supplemental FlowDeck-seeded abc check stayed abc at 0.6 s and 5 s after held Backspace, exit 0; supplemental held Return also had no callback or blur through 5 s with a valid abc seed. | Closed exact-seed deletion/Return failures now have 5 s readbacks; all open supplemental keyboard cases were focus-blocked. |
| key-sequence | ab appeared on closed, inner0 and inner90; inner270 had no observed change. | Other codes/delays and post-error release; inner180 focus was blocked. |
| key-combo | Shift 225+C6 did not append C in core valid-focused cases. Auxiliary Cmd+A started empty, so selection/release was inconclusive. Supplemental exact-abc-seeded Shift+C also left abc unchanged through 5 s. | Seeded Cmd+A→Z→b stayed abc through 5 s; insertion failed, but selection and release cannot be isolated from text alone. |
| touch | Closed/refold holds and split releases worked. Inner required effects were absent. A contact held across unfolding ended at off-screen(738,1434), with no cancellation. | Correct retained-contact translation and transition cancellation remain unproved; movement follow-up separate. |
| gesture | All 32 explicit-size preset routes completed: closed 16 delivered contacts; inner rot0 16 had no observed delivery/effect. Both closed top-edge routes opened a clock/date cover. | Full scroll/navigation semantics and other rotations/partial-fold options remain unverified. Default scroll-up has separate closed/open/refold evidence. |
| stream-video | All four formats emitted data and stopped cleanly in the inspected runs; closed content was black and inner90 content was sideways. Default JPEG contracts emitted PNG payloads. | Other orientations, fold/rotation during one stream, scale/fps/quality ranges and BGRA metadata. |
| record-video | Continuous 97-frame MP4 follows closed/open/rot0/rot180/refold: black outer, sideways rot90, upright rot0, upside-down rot180, black outer. | Active-panel selection and orientation fail; resize policy and remaining options need work. |
| screenshot | Closed wrong-panel/black content and inner180 upside-down content independently verified. | Complete latest seven-state image review; selected panel and orientation controls are absent. |
| batch | Closed perStep/none tap pairs and batch hold worked; a later stable default-cache physical tap pair also worked. All 3 cache modes delivered first tap but missed second after unfold despite exit 0. File/stdin accepted steps but taps absent; error modes reported expected diagnostics. | Successful continuation UI effect not proved. Refold batch blocked by prior run stop. No batch drag/slider. |

## Final five-second input subset

Twelve fresh v5 cases used a valid reset and a FlowDeck tap that added exactly one count before the AXe action. All AXe commands exited 0. Counts below exclude that positive control. Closed is outer rot0; open is inner rot90. Every final state had zero active contacts.

| AXe action | Closed at 5 s | Inner rot90 at 5 s |
|---|---|---|
| Automatic selector tap | No tap or contact increment | No tap or contact increment |
| Physical selector tap | Tap +1; complete contact | No tap or contact increment |
| Coordinate list swipe | List +362.3333 points; complete contact | No offset or contact increment |
| Combined hold | longPress +1; complete contact | No hold or contact increment |
| Drag | pan +1; panX +98; complete contact | No pan or contact increment |
| Batch two physical taps | Tap +2; two complete contacts | No tap or contact increment |

Closed successes were already present at 0.6 s, with list offset +297.667 then settling to +362.3333. Different earlier closed results therefore cannot be explained solely by delayed delivery; session/setup variation remains. File typing separately proved command return before visible text completion. This subset supersedes broad claims about these six paths, but does not cover all orientations or options. [Closed swipe raw state](evidence/2026-10-16-duo/features/settled-closed-list-swipe-state.json), [inner tap raw state](evidence/2026-10-16-duo/features/settled-open-tap-physical-state.json), [stable batch raw state](evidence/2026-10-16-duo/features/settled-closed-batch-physical-state.json); all twelve exact commands and increments are retained under settled-*. [Independent settled review](evidence/2026-10-16-duo/features/settled-input-review.md) confirms no failure-to-pass conversion between the two reads.

## Seven-state interaction coverage

C=closed outer; I0/I90/I180/I270=open inner with measured guest rotations; Partial=partial fold; R=refold. PASS means required effect observed, F means required effect absent, D means partial contact delivery without required movement, B means prerequisite/session blocked, M means mixed variants, U means not reviewed, I means inconclusive reference/setup. An asterisk denotes assisted keyboard focus. These codes do not certify all options of a command. Core state snapshots usually use a 0.6 s readback; F means absent at that bound, not proof that input can never arrive. Later 2 s and 5 s checks are identified separately.

| Feature/path | C | I0 | I90 | I180 | I270 | Partial | R |
|---|---|---|---|---|---|---|---|
| Fresh whole AX tree | observed | observed | observed | observed | observed | observed | observed |
| AX point finds intended target | PASS | F | F | F | F | I | not reviewed |
| Automatic/simulator/coordinate/label tap | F | F | F | F (retry) | F | I | F |
| Physical selector button tap | PASS | F | F | F | F | I | F |
| Automatic switch tap | F | F | F | F | F | I | F |
| Combined hold | PASS | F | F | F (retry) | F | I | PASS |
| Split down/up hold | PASS | F | F | F | F | I | PASS |
| Horizontal swipe | D | F | F | F | F | I | D |
| Vertical list swipe | PASS at 5 s; earlier short reads mixed | F | F | F | F | I | F at 2 s on v5; v4 crash excluded |
| Drag | PASS | F | F | F | F | I | PASS |
| Slider 50→75 | PASS | F | F | F | F | I | B: fixture crash stopped run |
| Batch cache modes, stable layout | M | F | F | F | F | I | B: fixture crash stopped run |
| Batch hold | PASS | F | F | F | F | I | B: fixture crash stopped run |
| Batch horizontal swipe | D | F | F | F | F | I | B: fixture crash stopped run |
| Two ordinary batch taps → doubleTap | F | F | F | F | F (retry) | I | B: fixture crash stopped run |
| Automatic field focus | F | F | F | F | F | I | B: fixture crash stopped run |
| Positional type | PASS* | PASS* | PASS* | B: focus | PASS* | B: focus | B: fixture crash stopped run |
| Backspace and Return | F* | F* | F* | B: focus | F* | B: focus | B: fixture crash stopped run |
| Key sequence 4,5 | PASS* | PASS* | PASS* | B: focus | F* | B: focus | B: fixture crash stopped run |
| Shift 225+C6 | F* | F* | F* | B: focus | F* | B: focus | B: fixture crash stopped run |
| Stream formats | F | not covered | F | not covered | not covered | not covered | not covered |
| Continuous MP4 content | F | PASS at rot0 | F | F | not covered | not covered | F |
| Still image correctness | F | not reviewed | not reviewed | F | not reviewed | not reviewed | not reviewed |
| Provider agent | B: key | B: key | B: key | B: key | B: key | B: key | B: key |

Core rows use closed-isolated, inner*-valid, retry180/retry270, partial-valid and refold-valid records. Later focus failure does not erase earlier valid focused outcomes. Partial-fold reference success from a later run does not validate earlier failed setup. The refold list gesture is excluded due to the fixture crash; later cases are blocked by that crash.

## Fold transitions and auxiliary paths

Hardware duration follow-up supersedes a blanket no-effect conclusion: valid closed/open baselines produced lock/clock wallpaper with side-button --duration .2 and Home with home --duration .2. Default side-button left the fixture visible in both. All six calls exited 0. Initial eight default-name calls had no observed settled effect, while two were setup-blocked. Neither unchanged captures nor lock wallpaper proves display power, backlight, or simulator shutdown; those need independent state readback.

All three batch cache modes (perBatch, perStep, none) started with a valid closed reset, delivered tap 1, then unfolded. The app changed 466×678→951×669; tap count remained 1 and each batch exited 0. Re-querying AX between steps did not by itself restore delivery at the recorded bound. A later stable default-cache physical tap pair succeeded; the earlier perBatch no-effect result does not establish a general cache defect.

A held contact began at(191,246), unfolded, and ended at(738,1434) in a 951×669 app window. Active contacts returned 1→0, with an end event but no cancel. This proves release delivery with an invalid post-fold position; it does not prove correct cancellation or targeting.

Auxiliary text: stdin expected `Duo Stdin 42`, observed Duo St; file expected `Duo File 42`, observed Duo File ļ. Both returned 0. Original readback was 0.6 s after return. In the delayed repeat, stdin exactly matched at 0.6 s and 5 s; file was Duo Fil at 0.6 s and exactly Duo File 42 at 5 s. Command completion can precede visible completion. Earlier mismatches are not proof of permanent loss; the earlier wrong character still has no established cause. Chunked batch produced exactly Ab1 repeated 50 times. Composite delivered 79/150 characters before the 45 s audit timeout. A separate 30-character composite request also timed out at 45 s, with 21 characters at both 0.6 s and 5 s after timeout; it did not complete within the bound. Unsupported emoji returned a clear no-keycode error, with no partial text at readback.

Auxiliary Backspace and Cmd+A started with empty text because the abc seed failed: deletion and selection semantics are inconclusive. Return had no callback/blur; type Z and plain b produced no text. The value-selector check used type Switch while AX reported CheckBox/value 0: that filter was invalid, not a value-matching defect. Label-only matching resolved a button and nested label, so it did not test distinct-target ambiguity. Missing-ID polling returned the expected error; dynamic appearance was not tested.

Slider 75/25/0/100 were sequential from one reset. Values were 74.953445/28.026072/0.372439/0.372439. First exited 0; remaining calls exited 1 with matching AX value errors after about 12–13 s. All contacts ended. This shows forward success and reverse/endpoint failures, not a blanket slider pass.

Supplemental suite completed on revision 4. Closed retained movement eventually delivered one begin/move/end pair from(156,246) to(226,246), panX 60, active 0; the first down had no event at its 0.6 s checkpoint, so per-command completion was delayed. The open rot90 retained sequence had no contact effects. Coordinate physical taps had no effect on closed or open. Corrected value 0/typeCheckBox resolved the switch on both screens but did not change it. Batch Home returned 0 while independent after images still showed the fixture on both screens. Closed default scroll-up is excluded because revision 4 crashed; open default scroll-up had no observed app delivery. All seven open text/key/composite cases were blocked by reference focus, so they add no keyboard failure claims. Closed seeded Backspace/Return/Shift+C failed their required effects through 5 s. Cmd+A followed by Z and plain b left abc unchanged; insertion failed, but selection range and modifier-release state are not directly observed. Revision 5 reruns are separate evidence. With a fresh FlowDeck positive tap in each case, default scroll-up moved the list by 570.6667 points closed and 940 points refolded, with complete release and zero active contacts; open had no effect. Coordinate list swipes had no effect in closed/open/refold at 2 s. The valid v5 result replaces the crashed observation; it does not make the v4 crash an AXe defect. Five-second input follow-up is separate. Completed closed cases now show automatic tap delta 0, physical tap delta +1, and list offset +362.3333 with complete begin/move/end and active 0. The successful settled-run list swipe was already moving at 0.6 s (+297.667), then reached +362.3333 at 5 s. Earlier separate no-effect runs therefore show session/setup variation; delay alone is not an established cause. The same caution applies to other closed pointer repeats. File typing has separate direct evidence of late completion. The complete settled subset is tabulated above.

## Eight gesture presets: completed route ledger

All eight presets ran standalone and in batch on closed outer rot0 and open inner rot0, using explicit current dimensions. This is 32 distinct routes, all fixture v5 and exit 0: 16 closed routes delivered window contacts; 16 inner routes had no observed window delivery or app effect. No final route is blocked or missing. This does not cover every rotation or default-size option. Touch delivery is separate from scroll/navigation/system semantics.

| Preset | Closed standalone | Closed batch | Inner rot0 standalone / batch |
|---|---|---|---|
| scroll-up | Upward 200-point path delivered; no offset change | Same path delivered | No app delivery / no app delivery |
| scroll-down | Downward 200-point path delivered | Same path delivered | No app delivery/effect / no app delivery/effect |
| scroll-left | Leftward 200-point path delivered | Same path delivered | No app delivery/effect / no app delivery/effect |
| scroll-right | Rightward 200-point path delivered | Same path delivered | No app delivery/effect / no app delivery/effect |
| swipe-from-left-edge | x 20→446 delivered | Same path delivered | No app delivery/effect / no app delivery/effect |
| swipe-from-right-edge | x 446→20 delivered | Same path delivered | No app delivery/effect / no app delivery/effect |
| swipe-from-top-edge | y 20→658; cancel plus visible clock/date cover overlay | Recovery repeat delivered; visible clock/date cover overlay | No app delivery/effect / no app delivery/effect |
| swipe-from-bottom-edge | y 658→20 delivered; system meaning unproved | Same path delivered | No app delivery/effect / no app delivery/effect |

The first closed top-edge batch was setup-blocked; the recovery repeat delivered the path and opened the clock/date cover. The final distinct set uses 15 presets2-closed cases plus the recovered presets3-closed top-edge batch, and all 16 presets3-open cases after one dedicated-device recovery. Original stopped/blocked runs are preserved and not counted as action failures. See [preset route ledger](evidence/2026-10-16-duo/features/preset-count-ledger.md). All 16 closed standalone/batch paths now have delivery evidence. These explicit-size preset cases use a 5 s readback. Contact delivery does not prove scroll/navigation semantics. All start at zero scroll offset; downward motion can bounce. There is no horizontal content or back stack. Separately, default-size scroll-up on v5 moved the closed list by 570.6667 points and the refolded list by 940 points, with complete release, at 2 s. Open default-size scroll-up had no observed effect. Other rotations and partial-fold presets remain unverified.

Revision 4 observes real UIWindow contacts but can crash when a touch has no hit view; a later v5 trace observed a nil view during ended. Revision 5 corrects only that logger defect and preserves normal UIKit dispatch. Its absence of contact alone cannot distinguish wrong routing from system interception. Its last 16 trace samples and first/last coordinates verify delivery direction; they do not establish every app's gesture semantics. The fixture has no horizontal scroll content. A small-pad miss is not a transport failure if the window received the correct path.

## Media findings beyond screenshots

Closed scale 0.25: mjpeg/raw/ffmpeg each contained 8 complete JPEGs, all identical black 501×713 images. MP4 decoded 9 frames over 4.2133 s at 500x712; first/last black. BGRA 13,142,016 bytes had zero B/G/R throughout and opaque alpha. The inferred 9×2048-byte-stride×713-row geometry matches scaled inactive inner dimensions, not the active outer panel; stream metadata did not report that geometry.

Closed defaults: all three compressed streams emitted PNG 2007×2853. MJPEG advertised image/jpeg although bytes started with PNG magic. This is a confirmed encoding-contract defect in addition to wrong panel selection; no particular player's behavior was assumed.

Stable open inner rot90: independent Apple capture was upright 2853×2007, while all three compressed formats and the inferred BGRA preview were sideways 501×713. MP4 decoded 9 frames at 500x712, with identity preferredTransform; first/last were sideways. Intermediate video frames were decoded but not all independently classified. Inner rot180 still image was upside down despite unchanged portrait dimensions. A continuous 50.0467 s MP4 at 2 fps/scale 0.25 decoded 97 frames, all 500×712 with identity transform:42 black,13 stable sideways,20 stable upright,18 stable upside down and 4 animation frames. Independent Apple references show upright active content in all five poses. Opening at inner rot90 was sideways; rot0 upright; rot180 upside down; closed/refold black. Frame groups and boundaries were visually reviewed; all 97 frames were decoded/exported/classified, not individually visually inspected. The fixed inner-surface explanation is inferred from content/geometry. No exact response latency is claimed because host-action and video clocks are not aligned. See transition-media-review.md.

## Competitor parity and mapping

Installed FlowDeck 1.33.0 [fac60d] and RocketSim 16.7.0 build 337 match the prior audit. This phase read installed versions; it did not repeat upstream latest-feed checks.

FlowDeck's inspected tap/double-tap path couples panel-aware geometry with an explicit modern HID target. Its separate NativeGestureDriver.play path supplies target 0 to multi-touch playback, including the inspected pinch/rotation and drag-path branches. The separate routing probe established useful target 1/target 3 delivery in prior seven-state navigation checks. Those helper successes do not verify AXe production commands. RocketSim's inspected bundled IDB path still used target 0/main-screen geometry; its GUI, capture and pose paths are separate.

| Comparison | Known interface/design result | Matched current live comparison |
|---|---|---|
| Targeting | AXe lacks panel selection; FlowDeck internally routes active-panel input. Neither inspected vendor tap CLI exposes physical inner/outer selection. | FlowDeck selector tap works outer/inner rot0; this does not prove every input route. |
| AX display vs screen ID | An AX parameter with a display number is not proof that frontmost lookup selects that physical panel. Keep AX hit-test and HID target domains distinct. | See the linked display-routing proof; the three identifier domains are not interchangeable. |
| Gestures | FlowDeck exposes double-tap, pinch, two-finger rotation, hold/drag and global scroll. RocketSim exposes long press, two-touch tap and container scroll. AXe exposes fewer named operations. | Outer FlowDeck effects observed; several inner coordinate/multi-touch effects absent. RocketSim outer results mixed. |
| Stale-state protection | RocketSim --screen is a snapshot hash guard. FlowDeck --screen selects returned tree detail. Neither means panel selection. | Fold/orientation guard coverage not proved. |
| Hinge/power | FlowDeck advertises pose/angle and simulator lifecycle. RocketSim advertises closed/book/open pose and hinge readback. AXe has no hinge/pose/display-power CLI. | Prior hinge/private power investigation remains separate. |
| Performance | Different payload sizes, debug/release builds and fixture event writes prevent a fair current ranking. | No new speed claim. |

Prior Settings evidence showed FlowDeck activating About before/after rotation while AXe and RocketSim did not. This is a bounded prior result, not blanket vendor superiority across every gesture. Current FlowDeck-assisted Reset is setup evidence only.

Matched v5 vendor2 cases: FlowDeck produced every tested outer-screen effect (tap, hold, swipe, drag, list swipe, global scroll, double tap, pinch, rotation, exact FlowDuo text). Pinch/rotation counters and nonzero values establish recognition, not exact requested scale/angle. On inner rot0, FlowDeck tap, hold, double tap, focus and exact text worked; swipe, drag, global scroll, pinch and rotation produced no app events at the recorded bound. Inner list swipe was blocked by coordinate-space disagreement, not attempted. Thus a panel-aware tap implementation does not establish complete Duo gesture coverage. Static inspection of the same 1.33.0 CLI hash shows play sets target x5=0 at 0x10121c870 and the multi-touch driver forwards it unchanged; tap/double-tap instead read geometry.screenID at+0x18. This split is consistent with the live difference and is a likely cause, not a per-invocation wire trace. It does not cover every GUI path or future version. See flow-gesture-routing-review.md and its assembly extracts.

RocketSim outer: tap, swipe, list swipe, two-finger tap/hold and exact RocketDuo text produced the required effects; one-finger hold delivered contact but no longPress callback. Container scroll was blocked because the debug snapshot exposed no unique list container (scrollables=[]). Inner rot0 RocketSim tap, hold, swipe, list swipe, two-finger tap and two-finger hold had no required effect. Its own focus failed; FlowDeck-assisted typing produced only R from RocketDuo after 5 s. Pointer readbacks use a 0.8 s bound; text uses 5 s. Later arrival beyond those bounds is not ruled out.

## Missing capability versus broken existing path

Absent public AXe capabilities: enumerate/select panel; hinge/open/closed/angle; device rotation/pose; display power/backlight; simulator boot/shutdown/restart; public pinch/rotation/two-finger tap/hold/finger identity; dedicated double-tap; standalone find/wait/assert; selector/container scroll/drag; batch drag/slider. Internal IDB primitives are not public CLI support. No volume-button CLI is registered.

Existing but failed/partial paths: automatic/simulator taps, inner pointer routing, point queries, swipe endpoint behavior, some batch modes, key/chord effects, active-screen capture, orientation and default stream encoding. Blocked paths: provider agent without key and specific automation-session timeouts. Inconclusive paths: failed positive-control/setup cases. Untested options must remain unverified.

Apple Pay must not be labelled absent solely from its DTUHID primitive: the current public event adapter rewrites it into two side-button presses 150 ms apart. Its actual system outcome still needs a live check.

## Fix plan in dependency order

1. Shared device/display context in IDB: enumerate runtime panels, active surface, native/logical dimensions, scale, guest orientation, AX-query context and HID target. Carry a generation through query and action; do not hard-code observed IDs or hinge thresholds.
2. Explicit action transforms: AX frame/activation point → selected display/native geometry → normalized HID. Thread target through simulator, physical, broker, shared-session and multi-contact routes. Check tapAt and swipe implementations separately; a transport fix alone does not prove their event sequences.
3. Retained-state recovery: invalidate broker transport geometry, batch AX roots and agent mapping on fold/rotation/boot, including 180° equal-size changes. Release or cancel held contacts safely; reject stale generations without replay. Keep existing agent target re-resolution rather than deleting it.
4. Common gesture dispatch: remove 390×844 defaults as implicit device geometry; use measured viewport or explicit caller coordinates. Apply the same transform to all 8 presets, point lookup, slider and batch/agent paths. Retain slider value verification and add explicit accepted-versus-observed outcomes.
5. Keyboard delivery: reproduce Backspace/Return/modifier no-ops with verified focus and inspect short/held/chord flush/release paths. Keep successful text generation separate from pointer focus.
6. Capture: select the active/requested surface, orient every frame from current state, define recording resize behavior, encode JPEG when advertised and expose/repack BGRA stride metadata.
7. Add missing public capabilities after route correctness: hinge/pose/readback, panel selector/capabilities, display power/backlight, simulator boot/shutdown/restart, find/references/wait/assert, named multi-touch and container gestures. Power and lifecycle require independent state readback; lock/side-button effects do not verify either. Update command docs/skill consistently. Private API use needs version/capability checks and concrete headers/runtime proof, not guessed IDs.
8. Repeat the audited cases and close unverified matrix cells against the repaired candidate, with matched vendor positive controls, fresh baselines, all states and retained/mid-gesture transitions. A repair plan is not delivered support.

## Existing tests and reproducibility

Existing non-E2E tests: 119 executed, 119 passed, 122 skipped. Swift Testing's top-level 241 figure includes skipped cases; it is not 241 live Duo passes. E2E suites were explicitly disabled. No repository test target was added or changed; temporary diagnostic scripts supplied the live checks.

Exact command: DEVELOPER_DIR=/Applications/Xcode-27.0.0-Release.Candidate.app/Contents/Developer AXE_E2E=0 AXE_LANDSCAPE_E2E=0 xcrun swift test --scratch-path /private/tmp/axe-duo-feature-20261016/unit-build --disable-sandbox --no-parallel. Exit 0. Source checks cover math, validation, serialization/retries, slider logic, broker readiness, batch parsing and agent freshness, not live panel routing. See unit-tests.log and support-checks.md.

Retained evidence: [evidence README](evidence/2026-10-16-duo/features/EVIDENCE-README.md), [file manifest](evidence/2026-10-16-duo/features/evidence-manifest.json), and [feature inventory](evidence/2026-10-16-duo/features/feature-inventory.md). Original evidence directory: /private/tmp/axe-duo-feature-20261016/. Core sources: feature-inventory.md; feature-run-review.md/json; media-review.md and media-review/; support-checks.md; source-continuity.json. Raw per-action JSON records preserve exact command, exit, timing, stderr and state readback. These commands are authoritative when harness revisions differ. The retained evidence includes audit.py and a README; the freeze manifest hashes every retained file recursively. Helpers: live.py, matrix.py, review-runs.py, capture.py, auxiliary.py, extras.py, buttons.py, transitions.py; retained driver hashes identify the final versions; raw command records identify each actual run.

Fixture sources/build notes: app/main.m + README.md (v3), app/main-v4.m + README-v4.md (v4), app/main-v5.m + README-v5.md (v5). Revision 5 source SHA256 c3afee5ab456de4ae945f3a9720e2da420916c0b941d83c41dd99daf93db31ae; binary ff30da9f469df1284f9e0d3b687af53c0e99b20e671c88c92447faa6986524d2. Mapping probe: /private/tmp/axe-duo-routing-20261016/probe/route-probe.m and README.md. Source anchors are in feature-inventory.md; no probe or fixture result should be attributed to unmodified production AXe without the recorded command.

Final cleanup: the dedicated audit simulator was closed at mechanical/sensor angle 0 with zero velocity, then confirmed Shutdown at 2026-10-16T23:19:43.265109Z. The final crash index lists only four earlier fixture crashes, latest 22:45:52Z; no later v5 crash report was found. git diff --check passed. See [cleanup state](evidence/2026-10-16-duo/features/final-cleanup-state.json), [pose readback](evidence/2026-10-16-duo/features/final-cleanup-pose.json), [crash index](evidence/2026-10-16-duo/features/final-fixture-crash-index.json), and [source continuity](evidence/2026-10-16-duo/features/handoff-source-continuity.json). No product code, commit or push was made for this audit.
