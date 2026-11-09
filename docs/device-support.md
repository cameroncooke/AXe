# Physical device support

Working plan for running AXe commands against a physical iPhone or iPad. Tick items as they land.

- Design: [AXe Physical Device Support Design](https://claude.ai/artifact/CWSMBBHmBK4gPALxZ5vtJ1)
- CLI surface and decisions: [AXe Device CLI Structure](https://claude.ai/artifact/1bERuSnxTYxzAGLdJamE3H)
- Wire formats: [device-protocols.md](device-protocols.md)

Rules that apply to every phase:

- Same commands and flags; `--udid` decides simulator or device. Anything a phone cannot do fails with `unsupportedOnDevice`.
- AXe never pairs, enables Developer Mode, mounts disk images or unlocks. It detects each and prints the fix.
- Protocol code is written from `device-protocols.md` and our own captures, never ported from GPL code (pymobiledevice3).
- `devicectl` is read only through its JSON file output, accepting both the `properties` shape and the older `connectionProperties`/`deviceProperties` shape.

## Phase 1: connection, listing, screenshot

- [x] `devicectl` JSON reader for both shapes
- [x] Target resolver for `doctor` and `screenshot`: simulator set first, then CoreDevice devices; `targetNotFound` names both
- [x] RSD port discovery (`remoted` socket, `remotepairingd` log fallback) and a held RSD session
- [x] XPC wire encoder/decoder and HTTP/2 RemoteXPC client
- [x] `axe list-devices` (text and JSON, readiness blockers)
- [x] `axe doctor --udid` for devices (six requirements) and simulators
- [x] `axe screenshot --udid <device>` through `screencaptureservice`
- [x] Proven on a phone: `list-devices`, `doctor`, `screenshot`
- [x] Repository fixture tests for both JSON shapes, readiness, the wire codec and the display rule

Verification on 2026-11-09 from this worktree, based on `a0d07c3ab`:

- `swift build --disable-automatic-resolution` succeeded. The device CLI build had SHA-256
  `08dadcf19a49a23b6b4333f9c96c3e90d9b9a4f85c2c7518450d069067fe0c23`.
- Ran `axe list-devices` in text and JSON, then `axe doctor --udid <device>` and
  `axe screenshot --udid <device> --output <temporary PNG>` over the local network on an
  iPhone 16 Pro Max with iOS 27.2. All six checks passed. `sips` decoded a 1320 × 2868 PNG.
  Selected screenshot options returned `unsupportedOnDevice` and wrote no file.
  An unknown UDID returned `targetNotFound`.
- On an ordinary iOS 27.0 simulator, `doctor` reported the shutdown state, then passed after
  boot. The ordinary `screenshot` route produced a decodable 1206 × 2622 PNG. The simulator
  was shut down again. This was a functional check, without a release timing comparison.
- Replayed both CoreDevice JSON shapes and all 23 captured RemoteXPC messages outside the
  repository. The reconstructed PNG matched the captured file byte for byte. The live
  socket and log lookup found the same RSD port.
- `swift test --disable-automatic-resolution --filter 'SelectedScreenshot|OutputSchemaTests'`
  passed all 13 existing tests.
- USB, iPad, multiple physical devices and negative phone readiness states were not exercised.
  The lock check reads passcode access and unlock since boot; it does not observe lock-screen
  visibility.

## Phase 2: input

- [x] `hid.indigo` client: digitizer (with `pointTwo`, `edge`), keyboard, button messages
- [x] Display size and orientation from `deviceinfo`; landscape coordinate conversion
- [x] Route tap, swipe, drag, touch, gesture, type, key, key-sequence, key-combo, button and batch to the device
- [x] `rotate` on devices through `devicecontrol`
- [x] Refusals: `swipe-from-right-edge`, `side-button`, `apple-pay`; `lock` needs `--allow-lock`
  (`--semantic-press` was refused here and became supported in Phase 4)
- [x] Proven on a phone: tap, swipe, type, home, rotate

Verification on 2026-11-09 from this worktree, based on `a0d07c3ab`:

- `swift build --disable-automatic-resolution` passed. Debug binary SHA-256
  `186d84c414e4b8370784ab635b6e2595f37ad3ffc95c443b4d1a8f08bace60ca`.
- On the iPhone 16 Pro Max with iOS 27.2 over the local network, coordinate taps hit Calculator keys
  in portrait and landscape. `rotate left` and `rotate right` changed the displayed orientation.
- One run of `type 42` dropped the final digit before the transport drain was added. On the updated
  build, three runs starting at 7 showed 742. Each run used a two-tap `batch` to restore the initial value.
- `button home` returned to the Home Screen. A downward `swipe` opened Spotlight. Screenshots confirmed
  `type axeverify`, `key 42`, `key-sequence --keycodes 28,30` and
  `key-combo --modifiers 225 --key 4` produced `axeverify`, `axeverif`, `axeverify1` and
  `axeverify1A`, respectively.
- Semantic press, the right edge preset, side button, Apple Pay and lock without `--allow-lock` returned
  `unsupportedOnDevice`. The actual lock action and all gesture variants were outside the live checks.
- On a warm iPhone 17 Pro simulator with iOS 27.0, the release configuration candidate
  (`220af9b8b246996a1ac2c2507c8de1b89a112187c7f06f0af580f534d57decc9`) was faster than signed
  v1.8.0 in all seven alternating pairs for each command. Median times for `tap -x 180 -y 30` were
  346 ms versus 879 ms. For `key 80` they were 140 ms versus 157 ms. This covers those two ordinary
  routes. It leaves selected mode, agent mode and Duo timing unverified.

- `swift test --disable-automatic-resolution --filter 'SelectedCompleteGestureTests|SelectedRotationTests|EdgeInsetTests|KeyTests|KeySequenceTests|KeyComboTests|BatchSelectedAdmissionTests|OutputSchemaTests'` passed all 57 tests.

## Phase 3: UI state from tree dumps

- [x] DTX client and `remoteAXService` reader (InitialDump plus AdditionalData pair, resend after 2.5 s)
- [x] One AXPTranslator token router shared by the simulator and device dispatchers
- [x] Tree-dump dispatcher; `describe-ui`, `--point`, element targeting, polling
- [x] Fail fast with `treeUnavailable` when a web alert blocks accessibility
- [x] Proven on a phone: describe-ui, tap by id, polling

Verification on 2026-11-09:

- The framework rebuild and `swift build --disable-automatic-resolution` passed.
  Debug binary SHA-256 `ad09ac13633c75c94aa3b71ea6985610220e1ab2ff4cd512797ceb22e9e981c6`.
- Replayed 14 saved tree pushes and accepted five valid pairs. The shared translator projected one
  saved Settings archive into one root with 15 nodes. A live DTX transport read returned 44 entries
  in 1.21 seconds before the phone locked.
- `swift test --disable-automatic-resolution --filter 'SelectedDescribePointTests|AccessibilityTargetResolverTests|OutputSchemaTests|SelectedScreenshotTests'`
  passed all 25 tests. `describe-ui` returned 134 Settings nodes on an iOS 27.0 simulator.
- The shared translator projected all four valid pairs in the saved `live_*` capture folders.
  The resulting trees contained 10, 12, 13 and 15 nodes.
- On the same warm iPhone 17 Pro iOS 27.0 simulator in Settings, ordinary `describe-ui --udid`
  returned the same 134 node identities in all seven alternating pairs. Median time was 229 ms for
  the release configuration candidate (`f45e9fc6a6da357b56f1e37c7c22ec83e57528be9dfa4de5587c3e07c817d035`)
  versus 831 ms for signed v1.8.0. The candidate was faster in all seven pairs.
- After unlock, the iPhone 16 Pro Max returned a 24-node Calculator tree. `describe-ui --point` matched
  the `Seven` button and `tap --id Seven` entered 7. Polling found `Eight` after Calculator reopened
  and entered 8.
- Built AxePlayground for iPhone with Xcode 27.2 beta 3 and installed it with its development profile.
  On Batch Test, `describe-ui --point` returned `batch-state-change-trigger`. Tapping that ID changed
  the state from Initial to State changed and exposed the next target.
- In Playground Duo Controls → Waits, `wait.target` was absent. Tapped `wait.start8`, then ran
  `tap --id wait.target --element-type Button --wait-timeout 22 --poll-interval 0.25`.
  It completed in 13.47 seconds. The app's `Documents/state.json` recorded target appearance and
  exactly one target callback.
- A visible Safari JavaScript alert still returned a tree on this phone. It did not reproduce the
  condition where the alert blocks pushes. The blocked case has saved-capture evidence for
  rejecting an incomplete and stale pair. Live `treeUnavailable` during a blocked web alert remains open.

## Phase 4: device broker and live requests

- [x] Per-device broker holding RSD, HID and accessibility, with the pushed tree cache
- [x] Forward translator cache misses through `processDataFromHost:`; `--semantic-press`

Verification on 2026-11-09:

- The framework and CLI builds passed. One broker process served a physical tree read, a
  tap to open Playground's text panel and the next tree read. The switch was visible, enabled
  and exposed as `AXCheckBox`.
- A live `processDataFromHost:` request for attribute 25 returned the exact `wait.sentinel`
  identifier. Its acknowledgement matched the outbound message ID. The separate reply
  matched request type, attribute, PID and object ID.
- An early semantic press changed the Playground switch and fired one callback, but AXe rejected
  the reply. A separate reverse probe confirmed that the physical press reply omits target identity.
  The broker now requires a pinned fresh tree, one pending action, the exact request acknowledgement,
  a positive native Boolean reply and fresh readback on the same checkbox.
- Final debug candidate SHA-256
  `dc36d61cc65e5e3f18f06d3d1ecd7928ab18c19182e698fd683d40c3eadb51b9`.
  One `tap --semantic-press --id feature.switch` returned `switchValueChangedObserved` with
  `nativeReplyAccepted` and one readback. Playground's state changed false → true and its
  callback count rose from 2 to 3. The same worker served the next `describe-ui`.
- The existing selected point, batch admission, screenshot, broker keyboard and output checks
  passed 32 tests during the broker work. Simulator device input continues to use its own route.

## Phase 5: video

- [x] `stream-video` by screenshots
- [x] Verify native RTP/H.264 through `displayservice`
- [x] `record-video` by screenshots

Verification on 2026-11-09:

- `swift build --disable-automatic-resolution` passed. Debug binary SHA-256
  `bfe1ba71c6d37177fdb04c0804b08130c384eb350f175c9ab1eaca769d097222`.
- On the same iPhone, launched Playground's Capture Markers at phase 0. Started
  `stream-video --format raw --fps 3 --scale 0.5 --udid <device>`, then tapped
  `media-pattern-next` by ID and confirmed phase 1 with `describe-ui`.
  SIGINT returned 0. ImageIO decoded 20 upright 660 × 1434 JPEGs and saw both
  expected color orders. The output rate was 1.86 FPS for this run.
- Repeated the marker change with `record-video --fps 3 --scale 0.5 --udid <device> --output <temporary MP4>`.
  SIGINT returned 0 and published the file. AVAssetReader decoded 21 upright
  660 × 1434 frames over 10.07 seconds with both expected color orders.
- `swift test --disable-automatic-resolution --filter 'SelectedStreamFrameTests|SelectedStreamOptionsTests|SelectedScreenshotTests|SelectedVideoRecordingTests|OutputSchemaTests'`
  passed all 29 existing tests during media integration.
- A structural probe identified RTP payload type 123 and a device-specific `0x92`
  settings packet. After the parser accepted that packet, `stream-video --format h264`
  returned Annex B video. The control reply reported 1328 × 2880 at 60 FPS.
  VideoToolbox decoded 433 upright 1328 × 2896 frames with the same marker change.
  The CLI reported `cleanupUnconfirmed` after SIGINT because the owned session
  was still listed at the four-second deadline.
- A longer run with candidate SHA-256
  `983907666a4c1f249e80343c7da1bd27f8b6954bbe7356ab50bd52e69c988c55`
  confirmed phase 1, but stopped writing bytes before the late output check.
  After SIGTERM, the CLI could not reconnect for the status read. The phone had
  negotiated a 20-second RTCP timeout. A second run on the same binary tapped
  the marker again after the timeout. AX read phase 2, but the video wrote no
  new bytes. The receiver-report candidate `7833802ba81f1cd7d7d9497cbfdd655a4d25fc0b07d5c9ab5554c23fa69f3bb5`
  also stopped output. The CLI reported a route error and could not confirm cleanup.
  A structural-only probe confirmed that the socket sent nine receiver reports.
  At 10.57 seconds the route to the negotiated peer changed from the CoreDevice
  tunnel to the default gateway. The next send returned `EHOSTUNREACH`.
  Repeating the probe with a successful `displayinfo` request every three seconds
  on the held RSD still lost the route at 10.43 seconds.
- Updated Playground's Capture Markers to present outside the navigation stack, hide system
  overlays, fill each quadrant to the screen edge, and show four asymmetric white squares.
  Built the app with Xcode 27.2 beta 3, installed it on the iPhone and launched
  `screen=media-pattern`. A fresh `screenshot --udid <device>` measured 1320 × 2868.
  ImageIO found all four squares at the expected positions and found the expected color
  at the first pixel of each of eight sampled edges.
- Repeated `stream-video --format raw --fps 3 --scale 0.5` and
  `record-video --fps 3 --scale 0.5` with the full-screen fixture and AXe candidate
  `7833802ba81f1cd7d7d9497cbfdd655a4d25fc0b07d5c9ab5554c23fa69f3bb5`.
  Both commands stopped cleanly on SIGINT. The 28 JPEG frames and 27 MP4 frames
  were 660 × 1434. Every decoded frame had all four squares in the expected positions
  and zero inset at the eight sampled edges. Both sequences showed phase 0 then 1.
  The same 29 existing media and output tests passed on this candidate. Both
  skill copies matched. The cached `skill-check` 1.2.0 CLI passed with no diagnostics.
- Seven read-only `devicectl device info details` calls kept the same tunnel up
  for a 27-second probe. The native command now refreshes that same route every
  three seconds and keeps the refresh active through owned-session cleanup.
- Final native candidate SHA-256
  `9a3a2384b41f5e45f3fa18f50a672202427ce878349b7e72fd353dd0dd85b2f0`.
  Ran `stream-video --format h264 --udid <device>` with the full-screen fixture,
  tapped `media-pattern-next` twice and confirmed phase 2 more than 20 seconds
  after phase 1. VideoToolbox decoded 740 upright 1328 × 2896 frames with all
  four squares in every frame and marker phases 0, 1 and 2 in order. The output
  had 9 pixels of padding on the right and 29 on the bottom at the sampled edges.
  SIGINT exited 0 after 19.38 seconds, after the exact owned session disappeared.

## Phase 6: docs and hardening

- [x] Physical-device reference and links in both skill copies, checked with `skill-check` 1.2.0
- [x] README, CLI help and CHANGELOG
- [x] Older CoreDevice JSON shape replay as recorded in Phase 1
- [x] USB on iPhone and iPad
- [x] Two physical devices at once (iPhone and iPad; no third device is available)
- [x] iPad: screenshots, `describe-ui` and native H.264
- [x] iPad: input, point lookups and screenshot video on a native `rot270` display, verified by physical rotation and orientation lock
- [x] iPad `rotate`, confirmed against the reported orientation; touches refuse while the display state lags
- [x] Opt-in `make e2e-devices` suite; fails before building when no device is paired
- [x] Concurrent use with Xcode Device Hub, with one native display stream at a time
- [x] Native H.264 reports `deviceStreamReplaced` when another client takes the display stream
- [x] `list-devices` reports an idle network tunnel as unchecked instead of blocked

On 2026-11-09, final CLI candidate SHA-256
`cf56e10222e05410d32f39dc1659cdf76a29071e0baa99028165e17a29e0ec7c`
passed the 29 existing media and output tests. `axe --help` listed physical-device
support and both skill trees matched. The native device run above preceded the help
and documentation changes.

`axe list-devices` found one physical iPhone over the local network. The Xcode
interaction tool listed no eligible physical targets and refused both the hardware
UDID and CoreDevice UUID.

### Device Hub, idle tunnel and hardware check (2026-11-09, later session)

Started from `a0d07c3ab` with the previous session's changes uncommitted. The debug
build first matched `cf56e102…`. Media runs used candidate SHA-256
`c0fd125810f24fe90b7cfde25eb7c39bbc7bba7c7bcfdc326851ed4d0beed118`. That section's final candidate
`93a44400688c3740ca791bc54df9732462f523d06f4f2207c43560e7381ade1d` changes only `list-devices`.
Marker checks used a local analyzer. It decoded PNG, length-prefixed JPEG, MP4 (AVAssetReader)
and Annex B H.264 (VideoToolbox). It found the content bounds, the phase from all four
quadrants, all four white squares with tile colour around them and none at mirrored
positions, and the eight edge samples. Playground was launched with
`devicectl device process launch --terminate-existing … --launch-arg screen=media-pattern`.

- Hardware: `devicectl list devices` reported one physical device, the iPhone 16 Pro Max
  over `localNetwork`. The other entries were simulators, which CoreDevice 689.2 now
  reports with `sameMachine` transport. `system_profiler SPUSBDataType` showed no iPhone
  or iPad. USB, iPad and multiple physical devices could not be exercised.
- Idle tunnel: at the start `list-devices` showed `deviceNotConnected` and
  `developerDiskImageUnavailable` as blocked, with a USB hint. CoreDevice reported the
  tunnel `disconnected`. A `devicectl device info details` call brought it up. The tunnel
  went idle again later. From that state, `doctor --udid` reconnected it through the same
  call and passed all six checks in 2.58 seconds. `list-devices` now reports those two checks
  for a paired device without an active connection as unchecked, pointing to `doctor`.
- Device Hub: Xcode 27.2 beta 3's `DeviceHub.app` listed the phone and mirrored Capture
  Markers through View Screen. Its session status showed one audio and one video session
  with the same client UUID. While the view was live, `doctor`, `screenshot`, `describe-ui`
  (all seven `media-pattern-*` IDs) and `tap --id media-pattern-next` worked, and the
  screenshot moved from phase 0 to 1 with all marker checks passing. Device Hub showed each change.
  Three paired timings with the view live against three with Device Hub closed:
  `describe-ui` about 2.96 s against 2.74 s, tap by ID 4.87 s against 4.66 s, and
  one coordinate tap 2.22 s against 1.22 s. Device Hub's session stayed up through the input.
- Screenshot media with the view live: `stream-video --format raw --fps 3 --scale 0.5`
  decoded 36 frames of 660 × 1434 with phases 1 then 2. `record-video` with the same options
  decoded 35 frames over 13.09 seconds with phases 2 then 3. Both stopped within 0.04 seconds
  of SIGINT with exit 0, and every frame passed. Device Hub's session status did not change.
- Native H.264 lost its stream in all four runs with the view live. The phone sends one display video
  stream at a time. Status reads every five seconds showed that starting AXe's stream
  removed Device Hub's video session while its audio session stayed. About 20 seconds
  later, Device Hub started a new audio and video pair. That pair replaced AXe's session.
  AXe received no more packets and exited 12 seconds later. The frames written before
  that decoded correctly. In one 818-frame run, 7 frames failed only because a notification
  banner covered the top-left square. AXe now reads the stream status when packets stop.
  When its session is gone and another video session exists, it exits with
  `deviceStreamReplaced` and names Device Hub's screen view. On `c0fd1258…` this occurred
  after 33.95 seconds with 315 valid frames. With Device Hub open but its screen view
  closed, native H.264 passed: 962 frames.
- Native H.264 control with Device Hub closed, on `c0fd1258…`: tapped `media-pattern-next`
  at 6 seconds and again 24 seconds later. VideoToolbox decoded 831 frames of 1328 × 2896, all
  passing, with phases 3, 0 and 1 in order. Padding was 8–9 pixels on the right and 29 on
  the bottom. SIGINT exited 0 after 19.62 seconds, and the status list was then empty. The
  same run on `cf56e102…` decoded 1135 frames and stopped in 20.80 seconds.
- Xcode interaction tool: served by the selected Xcode 27.0 RC. It still listed only
  simulators and refused the phone by name and hardware UDID. This held with the tunnel
  connected and with Xcode 27.0 RC's own Device Hub open and listing the phone. The cause is
  unknown. Device Hub itself is the concurrency target checked above.
- `swift test --disable-automatic-resolution --filter 'SelectedStreamFrameTests|SelectedStreamOptionsTests|SelectedScreenshotTests|SelectedVideoRecordingTests|OutputSchemaTests'`
  passed all 29 tests on that section's final candidate. Both skill copies match. `skill-check` 1.2.0
  validation passed with no diagnostics. Its optional security scan needs a `SNYK_TOKEN`
  and did not run.

### USB, iPad and two devices (2026-11-09, later session)

Hardware: the iPhone 16 Pro Max and an iPad Pro 11-inch (3rd generation, `iPad13,4`), both on
iOS 27.2 and both reported as `wired` by `devicectl`. Cam has no third physical device. The iPad
sits physically in landscape in a keyboard dock, and the iPhone was physically portrait.
Playground was built for the iPad with Xcode 27.2 beta 3 and installed with `devicectl`.
The media and concurrency runs below used `c0fd1258…`. The refusal candidate in this section is SHA-256
`5f59c09159da9c85c43f16c28da44f0e11ea72cb0389fc4035158898380cc952`; the next section replaces it.

- iPhone over USB: `doctor` passed in 0.86 s and 10 of 10 repeats. Screenshot 1320 × 2868.
  `describe-ui` returned the seven `media-pattern-*` IDs. `tap --id media-pattern-next` and a
  coordinate tap at its tree centre each advanced the marker. Native H.264 decoded 541 frames
  with phases 1, 2 and 3, and the second change came 24 seconds after the first. SIGINT exited 0 after 20.76 seconds.
  The raw stream decoded 35 frames and `record-video` 35 frames, all passing, each across one
  marker change.
- iPad over USB: the first `doctor` reported a connection reset; the next 14 runs passed.
  One Playground launch exited with CoreDevice error 10004; the retry worked. Screenshots were
  2778 × 1940 and upright in the physical landscape state, and all marker checks passed.
- iPad display: `getdisplayinfo` reported primary `nativeOrientation` `rot270`, native size
  2388 × 1668, current mode 2778 × 1940 at scale 2, and `currentOrientation` `rot0` in the
  physical state. AXe's parser required `rot0`, so `describe-ui`, every touch command, `rotate`
  and the screenshot stream and recording failed with "could not read the primary device display".
- iPad digitizer probe: Playground Tap Test, raw Indigo taps at normalized (0.2, 0.3), and
  orientation changed only by `devicecontrol` `OrientationRequest`. In all nine observations the
  digitizer used a 970 × 1389-point device-portrait frame. The UI result followed the reported
  sensor orientation: landscapeLeft matched `.landscapeFlipped`, landscapeRight matched
  `.landscape`, and both portrait orientations matched their enums. The display's
  `currentOrientation` did not. `rot0` appeared with both landscapeLeft and portrait, `rot270`
  with both portraitUpsideDown and landscapeRight, and the steady-state landscapeLeft value was
  `rot0` in one run and `rot90` in another. The device's own screenshot was sideways in the states
  where the value disagreed. A second opinion (`gpt-6-astra`) agreed that this evidence does not
  establish a safe interface-orientation source. The sensor can differ from the interface, and an
  AX-root aspect check cannot tell opposite orientations apart.
- Change: `PhysicalDeviceDisplay` now parses any native orientation as a raw snapshot. That
  snapshot holds mode size, scale, native and current orientation, and the sensor orientation on
  non-`rot0` panels. Point geometry is derived only for native `rot0`, unchanged from before. On
  other panels, coordinate and element taps, gestures, `describe-ui --point`, semantic press,
  `rotate` and the screenshot stream and recording return `unsupportedOnDevice` before any
  digitizer event, frame or file. Plain `describe-ui` compares the raw snapshot before and after the read.
- iPad on the refusal candidate: `describe-ui` returned the Playground tree in 4.23 s with a
  1389 × 970 application frame. `media-pattern-next` was at (636.5, 42, 116 × 44), consistent with
  the raw-tap result. `describe-ui --point`, `tap -x/-y`, `tap --id` with and without polling,
  `swipe`, `rotate left`, semantic press, the raw stream (0 bytes) and `record-video` (no file)
  each refused in 0.7–2.1 s. The marker phase was unchanged afterwards.
- iPad native H.264 on `c0fd1258…`: negotiated 2784 × 1952 at 60 FPS. Raw taps on
  `media-pattern-next` at 6 seconds and 24 seconds later produced 460 upright frames, all passing,
  with phases 1, 2 and 3. Padding was 6–7 pixels on the right and 13 on the bottom. SIGINT exited
  0 after 20.49 seconds. A first run decoded 157 correct frames at phase 0 only, because the probe's
  tap point sat below the button.
- Two devices at once: native H.264 ran on both together. The iPhone decoded 537 frames with phases
  1, 2 and 3 and exited 0 after 20.88 s. The iPad decoded 462 frames with phases 3, 0 and 1 and exited
  0 after 20.08 s. Three parallel screenshot pairs all passed. While four iPad screenshots ran, the
  iPhone completed two `describe-ui` plus `tap --id` pairs, and the marker moved 3 → 1.
- iPhone regression on the refusal candidate: `describe-ui`, `describe-ui --point`, `tap --id` and a
  coordinate tap each worked, with the marker advancing on both taps. `rotate left` gave an upright
  2868 × 1320 capture. A landscape `tap --id` advanced the marker. `rotate right` restored portrait.
  The raw stream decoded 28 frames and `record-video` 30, all passing.
- `swift test --disable-automatic-resolution --filter 'SelectedStreamFrameTests|SelectedStreamOptionsTests|SelectedScreenshotTests|SelectedVideoRecordingTests|OutputSchemaTests|SelectedDescribePointTests|AccessibilityTargetResolverTests|SelectedRotationTests|EdgeInsetTests|OrientationCoordinate'`
  passed 60 tests, and `--filter OrientationAwareCoordinates` passed 22. Both skill copies match,
  and `skill-check` 1.2.0 validation passed.

### iPad physical rotation and the final rule (2026-11-09, later session)

Cam undocked the iPad, with orientation lock off, and rotated it by hand. AXe sent no
`OrientationRequest`. In each settled position a capture script recorded display info before and
after, the Tap Test application frame, raw taps at normalized (0.2, 0.3) and (0.7, 0.6) read back from
the tree, and a screenshot. Portrait frame W × H = 970 × 1389 points.

| Front camera | Sensor field | `currentOrientation` | App frame | Taps (UI points) | Matches |
| --- | --- | --- | --- | --- | --- |
| top | portrait | `rot90` | 970 × 1389 | (194, 416), (679, 833) | `.portrait` |
| right | landscapeRight | `rot180` | 1389 × 970 | (972, 194), (555, 679) | `.landscape` |
| bottom | portraitUpsideDown | `rot270` | 970 × 1389 | (776, 972), (291, 555) | `.portraitUpsideDown` |
| left | landscapeLeft | `rot0` | 1389 × 970 | (416, 776), (833, 291) | `.landscapeFlipped` |
| top again | portrait | `rot90` | 970 × 1389 | (194, 416), (679, 833) | `.portrait` |

Every screenshot was upright and the before and after readings matched. Cam then locked the
interface with the camera on the left and turned the iPad 180° (camera right; the interface looked
upside down to Cam). The display still reported `rot0`, the app frame stayed 1389 × 970, taps
matched `.landscapeFlipped` and the screenshot was upright. The sensor field also reported
landscapeLeft and the lock flag false, so on this iPad that field follows the locked interface.

Rule: the interface rotation is `(currentOrientation + nativeOrientation) mod 360`, mapped with the
existing enum (90 `.landscape`, 180 `.portraitUpsideDown`, 270 `.landscapeFlipped`). The portrait point
frame is the current mode size with axes swapped for native `rot270`, divided by the scale. On the
iPhone (native `rot0`) this is the previous rule. That candidate enabled only native `rot0` and
`rot270`, and refused `rotate` unless the native orientation was `rot0`. The next section replaces both.

Candidate SHA-256 `7f88074b1be8287b0eafebe51bd7cd8af42ed6287bc09608929949c3eea3a507`:

- iPad, locked landscape and physically upside down: `tap -x/-y` at (300, 200), (1200, 900) and
  (50, 800) landed exactly. On Capture Markers, `describe-ui --point 694,64` returned
  `media-pattern-next` and `tap --id media-pattern-next` advanced the marker. The raw stream decoded
  27 upright 1389 × 970 frames with phases 1 then 2, and `record-video` decoded 28 frames with phases
  2 then 3, all passing. `rotate left` returned `unsupportedOnDevice`. One `describe-ui --point` on Tap
  Test returned `ambiguousPoint` where two tree branches overlap, unrelated to orientation.
- iPhone regression: ID and coordinate taps advanced the marker in portrait, an ID tap after
  `rotate left` advanced it in landscape, and `rotate right` restored portrait. The raw stream decoded
  28 frames, all passing. The 11 suites listed above plus `OrientationAwareCoordinates` passed
  82 tests.
- A rebuilt CLI could not use the previous build's broker (`deviceBrokerMismatch`) until that
  broker exited on its idle timeout about 55 seconds later.

### Software rotation on the iPad and the final rule (2026-11-09, later session)

Every observation below has the iPad undocked, physically portrait and with orientation lock off. A
turn is stale when the display reports a different orientation from the one the device reports.

- `devicecontrol` `OrientationRequest`, four right turns: one stale. After portraitUpsideDown →
  landscapeLeft the display stayed `rot270` for more than 20 seconds, and the iPad's own screenshot
  was sideways. Raw taps still followed the interface. Four left turns had no stale display value,
  but one screenshot was sideways while the display value was correct.
- Xcode Device Hub (27.2 beta 3) Rotate Left with its screen view open: eight of eight turns
  matched, and every screenshot had the right orientation. Device Hub offers no Rotate Right.
  FlowDeck 1.34.0 and the RocketSim CLI have no physical-device UI automation, so they could not be
  compared. Device Hub's Mac log showed no orientation messages and its binaries showed no
  matching request strings, so its exact request was not sampled.
- `OrientationRequest` right with Device Hub streaming: one of eight stale, again at
  portraitUpsideDown → landscapeLeft. A live stream does not prevent it.
- iPhone naming check: the device orientation in the reply maps to the display the same way on the
  iPhone (landscapeLeft `rot270`, landscapeRight `rot90`). Asked for portraitUpsideDown, the iPhone
  reported it while its interface and display stayed in landscape.

Conclusion: the stale display value is device-side and affects the shared rotation request, not
only AXe's use of it. Device Hub's left-only button avoided the failing transitions in these runs.

Final rule:

- All native orientations are accepted. The portrait frame swaps axes for native `rot90` or `rot270`.
  Interface rotation is `(currentOrientation + nativeOrientation) mod 360`. Native `rot90` and `rot180`
  follow from this rule but no device with those values was available.
- On panels whose native orientation is not `rot0`, every touch command, point lookup and screenshot
  video first compares `currentDeviceNonFlatOrientation` with the display. A mismatch returns
  `displayOrientationMismatch` without sending input. On the iPad that field matched the interface in
  every consistent state, including under orientation lock. iPhones are exempt because of the
  portraitUpsideDown case.
- `rotate` succeeds on every panel only when the display matches the device orientation in the reply.
  Otherwise it returns `rotationUnconfirmed` once the display has stood still for 2.5 seconds (changed
  later in this session from waiting the whole timeout).

Final candidate SHA-256 `a3ae30aee206dbb6c2770fa4038dd813e0bd618611b7ddddcc35248e02f4fa63`:

- iPad, `axe rotate right` with coordinate taps read back from Tap Test, over three runs of eight,
  five and four turns. Stale turns occurred on candidate `efea8f4e…` (same rule, earlier rotate loop).
  Stale turns returned `rotationUnconfirmed`, and the following taps returned
  `displayOrientationMismatch` without input. The readback stayed at the previous tap. In one run two
  consecutive turns were stale, and the display lagged exactly one step. The next turn recovered each
  time. In every confirmed orientation, `tap -x 300 -y 200` and `tap -x 900 -y 600` read back exactly.
  On the final candidate, four turns all confirmed and each `tap -x 700 -y 400` read back exactly.
- iPhone: `rotate left` confirmed landscape. A second `rotate left` asked for portraitUpsideDown and
  returned `rotationUnconfirmed`, and `rotate right` back to landscape now confirms. Before this
  change, that last step failed because the display had not changed. `tap --id` advanced the marker.
- The 82 existing tests passed. Both skill copies match and `skill-check` 1.2.0 validation passed.
- After the Device Hub session, the iPad's Playground stopped returning accessibility trees
  (`treeUnavailable`), even with a fresh broker. Relaunching Playground fixed it. The cause is unknown.

Remaining gaps at this point: devices with native `rot90` or `rot180` panels. Live `treeUnavailable` during
a blocked web alert, negative readiness states and the actual lock action were still open from earlier phases.

### Rebase, fixture tests and the device suite (2026-11-09, later session)

- Rebased `claude/device-support` onto `v2` (`6d85a4f7b`, which adds `axe displays` and plain Duo output).
  The working changes went into a temporary commit and were reset afterwards, so they are uncommitted
  again; `backup/device-support-pre-rebase` holds the pre-rebase state. Conflicts in `main.swift`,
  `CLIOutputInvocation.swift`, `Gesture.swift`, `Rotate.swift`, both `SKILL.md` copies and the CHANGELOG
  kept both sides. `Rotate` now runs the physical path before v2's simulator path; validation accepts a
  hardware UDID before v2's simulator UUID check. The IDBKit frameworks were rebuilt for v2's sources.
- Web alert: a Safari JavaScript alert opened through `devicectl --payload-url` on the iPad still returned
  full trees in 3.2–5.2 s, and an AXe coordinate tap closed it. Neither device reproduces a blocked tree.
- `Tests/PhysicalDeviceFixtureTests.swift` adds 21 tests. They cover the current and older CoreDevice
  JSON shapes, simulator filtering, an unpaired device, Developer Mode off, an idle tunnel and an error
  envelope; the RemoteXPC empty-dictionary bytes, string padding, every value type, framing and bad magic;
  and every iPad tap observation as display-rule expectations, the mismatch refusal, the iPhone
  upside-down exemption, native `rot90` axes and equality. Unpaired and Developer Mode off are covered
  here rather than on hardware. `CoreDeviceInventory` gained JSON entry points for this, and the
  `list-devices` idle mapping moved to `DeviceInspection.listChecks`.
- `make e2e-devices` (`scripts/run-e2e-devices.sh`, `scripts/test-physical-devices.py`,
  `scripts/fixtures/MediaPatternCheck.swift`) is described in [Playground testing](playground-testing.md#physical-devices).
  An unknown `AXE_E2E_DEVICES` UDID exits 1 in 0.6 s; a simulator-only or missing device list yields no
  devices, which exits 1 before building.

The first suite runs found these problems, now fixed:

- Native H.264 on the iPad in portrait gave sideways frames. Native frames keep the panel's orientation
  and AXe passes them through without re-encoding. AXe now states on stderr how many degrees clockwise to
  rotate them, from the display's `currentOrientation` (90° for the iPad in portrait, 0° for the iPhone in
  portrait and the iPad in camera-left landscape). The checker finds the rotation independently, and the
  suite requires the two to agree.
- `doctor` occasionally failed its screenshot-service check with "Connection reset by peer" on the first
  service-directory connection after an idle period: once on each device. `DeviceServiceDirectory.connect`
  now retries once after 0.5 s with a fresh port lookup.
- With the iPad software keyboard up, every tree read failed. Two causes were found from logged pushes and
  live lookups. First, the 2.5-second resubscribe fired between the InitialDump and its 238 KB
  AdditionalData, which arrived about 1.2 s later; it reset admission and discarded the pair. AXe now resubscribes
  only when no push has arrived. Second, projection asked the device for custom actions of each keyboard key
  (19 lookups of about 45 ms), and the last lookup ran out of the 6-second read bound. Custom actions
  missing from the pushed tree are now treated as none. The bound stays at 6 seconds. Measured afterwards:
  iPad keyboard screen 7.0 s cold (including broker start) and 3.5 s warm; iPhone 3.1 s cold and 1.8 s warm,
  previously 2.7 s warm.

Final run on CLI candidate built from this tree with Xcode 27.2 beta 3: `make e2e-devices` passed 19 of 19
checks on the iPhone and the iPad over USB, including both rotations (the iPhone had one unconfirmed turn,
an upside-down request it does not perform; the following tap was sent and landed, which the check
then accepted without saying so, corrected below), native H.264 at 0° and 90°, and the concurrent run. One earlier
run had an iPad native stream that wrote nothing after the first marker change and ended cleanly on SIGINT.
It did not recur in the two later iPad native runs, single and concurrent. 103 existing and fixture tests passed; both skill copies match
and `skill-check` 1.2.0 validation passed.

Lock check, same session, iPhone over USB: `button lock` without `--allow-lock` refused with the
unlock warning. With `--allow-lock` the phone locked (exit 0), and CoreDevice reported
`passcodeRequired: true`. `doctor` then reported `deviceLocked` blocked, with the screenshot check
unchecked, and `screenshot`, `tap` and `describe-ui` each refused with `deviceLocked`. The tree read's
message said "before sending input"; it now reads "before sending input or reading its screen". After Cam
unlocked the phone with Face ID, `doctor` passed all six checks, and a screenshot and tree read worked.

Remaining gap: devices with native `rot90` or `rot180` panels are untested.

### Review, performance-weighted fixes and quick benchmark (2026-11-09, later session)

`claude-fable-5-2` reviewed the device work against these documents, read-only, then re-triaged its
findings for their cost on the normal path: no fix may add a device round trip to an ordinary successful
command. Changes made from that triage:

- Fresh accessibility session: connecting already waits for a complete tree, and the first read then
  fetched a second one inside the same 6-second bound. The broker now uses the tree from the connection
  (`describe-ui`, element taps, and the first read of semantic press). This also stops a slow first read
  from failing and forcing every retry back onto a fresh session.
- Warm broker: every device command spawned `devicectl list devices` before reaching the broker, which
  re-reads the device details on each lease anyway. When this UDID's broker is already running (a local
  lock-file check), the CLI now skips that spawn. Media commands and the broker itself still read the full
  record.
- iPad orientation check: a reply without `currentDeviceNonFlatOrientation` now refuses on panels that are
  not `rot0`; a reported `unknown`, such as a device lying flat, is still accepted.
- A closed accessibility session is reconnected from local state; there is no probe before reuse.
- Lock: input after a quiet gap of 25 seconds or more in one command (a long batch `sleep`) reads the lock
  state again, which costs one `devicectl` call only in that case; input after the command's own
  `button lock` step is refused without a device call. `PhysicalLockRecheck` holds the timing rule, and
  unit tests show that input inside the gap never triggers a check.
- A broker that closes during the handshake while exiting on idle now counts as no broker; the client
  starts a new one once the old one has exited.
- `displays`, `shutdown`, `hinge`, `clipboard`, `slider` and agent mode refuse a hardware UDID with
  `unsupportedOnDevice` before any work.
- A live lookup that times out during projection keeps its own error instead of the blocking-alert message.
- `rotationLocked` now says the request was sent but had no effect. Native H.264 says when it could not
  confirm the orientation at the start, and a stream replaced before its first frame reports
  `deviceStreamReplaced`.
- Removed the unused tree-read code in `DeviceAccessibilityTransport.swift`.
- The e2e rotation check now requires the app frame to swap on each confirmed turn and counts refused and
  landed taps after unconfirmed turns separately; screenshots must be upright; decode failures are checked;
  tree-read retries are counted; stream commands are logged.

Left as is, by the triage: per-step lock checks, liveness probes before reusing connections, the
pre-build gate's pairing-only check, the 3% square tolerance, start-failure cleanup without the tunnel
refresh, normalized coordinates of exactly 1.0, and signed object IDs. These are rare and send no input.

`make bench-quick` (`scripts/bench-quick.py`, `scripts/run-bench-quick.sh`) follows the review's design and
is documented in [Playground testing](playground-testing.md#quick-performance-check). Building it found:
a selected tap timed for one build was served by a broker another build had left running, so the harness
now stops every broker for the target before each block; with three pairs a self-check flagged a 6 ms
difference, and with seven commands judged together a chance flag appeared about one run in five, so
verdicts need five pairs, a 3% floor, and a confirmation phase. Tap Test does not record selected taps in
its "Tap Location" label, so the landing check reads the raw tap.

Measurements on payloads, baseline `e2e-results/bench-quick/baselines/pre-review` (the device-support build
before these fixes, SHA-256 `d53b8ca1…`):

- Simulator self-check (AXe E2E iPhone iOS 27.2, 5 pairs): no difference on seven rows, resolution 3–8 ms,
  37 seconds.
- Final candidate (SHA-256 `1ac9c845c4a37b69f3e5b7827fc256565a4d8a4d22606a24ed56f7d867f5b333`) on that
  simulator: no difference on all seven rows; agent output unchanged at 773 bytes.
- Same candidate on the iPad Pro (USB, portrait, Tap Test): cold `describe-ui` 5.25 → 3.34 s, `tap`
  0.83 → 0.62 s and `key` 0.84 → 0.64 s, each faster in 5 of 5 pairs; warm `describe-ui` showed no
  consistent difference. A build with only the first two fixes measured the same, so the later fixes add
  nothing measurable. A device run takes about 4 minutes.
- iPhone 16 Pro Max (USB, portrait, Tap Test), after Cam dismissed an iOS 27.3 Software Update alert that
  had blocked it: cold `describe-ui` 4.09 → 2.66 s, warm `describe-ui` 2.62 → 2.29 s, `key` 0.83 → 0.62 s
  and `tap` 0.81 → 0.61 s, each faster in 5 of 5 pairs. RocketSim was mirroring the iPhone during this and
  the following runs.

`make e2e-devices` on the iPad alone with the revised checks passed 9 of 9: four confirmed turns, each swapping the
app frame; upright screenshots; native H.264 turned 90° as announced, with phases 3, 0 and 1; no tree-read retries.
`make e2e-devices` on both devices then passed 18 of 19: the iPhone's rotation check failed when a request
to turn upside down, which the iPhone does not perform, waited out the whole 8-second timeout and ended in a
CoreDevice timeout instead of `rotationUnconfirmed`: the last display read near the deadline was given too
little time. `rotate` now reports `rotationUnconfirmed` once the display has stood still for 2.5 seconds and
maps a read timeout to it. On the iPhone that request now returns in 3.16 s; confirmed turns took 0.7–1.4 s
warm. The rerun on the iPhone (payload SHA-256 `9a38c417b2fcf961734792dafec1922009510e1e9daee74f6e640085b07bc4eb`)
passed every check except a new frame-swap assertion that was itself wrong: after the unconfirmed
upside-down turn the interface stayed in one landscape, so the next confirmed turn went landscape to
landscape. The script now requires a swap only after a confirmed turn. The rotation check alone then
passed on both devices: the iPhone with three confirmed turns and one unconfirmed, after which the tap
landed exactly; the iPad with four confirmed. The concurrent check passed in the two-device run.
133 existing and fixture tests passed, including 3 new ones for the missing-orientation refusal and the
lock recheck. Both skill copies match and `skill-check` 1.2.0 validation passed. No release v1.8.0 payload
is on this Mac, so the simulator comparison is against the pre-review build, not the release.

Still unverified live: two-finger input, edge presets, drags, standalone `touch` and batches holding a
contact; the lock recheck after a real quiet gap; `rotate` under Orientation Lock on the final build.

