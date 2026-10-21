# iPhone Duo live evidence audit

Date: 16 October 2026. This report reviews captured command results and images. It does not claim complete device support.

AXe can read accessibility data from this Duo simulator. Its current screenshot path does not produce correct images across display changes and rotations. All four closed-state captures are black. Three of four open-state captures have the wrong image orientation. Each command reports success.

## Candidate and environment

- AXe: fresh arm64 debug build, v1.8.0-1-g7163081-dirty. Binary SHA-256: 08dfa7f0720ff0659cd037517cb77a7789adf07ff4b7f97e7d11ac11ce64458e.
- Binary: /private/tmp/axe-duo-audit-20261016/build/out/Products/Debug/axe. See the [candidate report](2026-10-16-duo-axe-candidate.md) for source hashes, toolchain, and framework provenance.
- Runtime toolchain: /Applications/Xcode-27.2.0-Beta.3.app, build 27B5038j.
- Simulator: iPhone Duo, iOS 27.2 build 24B91011, UDID 3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463.
- FlowDeck: 1.33.0. RocketSim: 16.7.0, build 337. These live captures were made after activation.
- Original evidence: /private/tmp/axe-duo-live-20261016. A bounded evidence copy is under [live evidence](evidence/2026-10-16-duo/live/rotation-matrix.json). Preview URL credentials and licence data are excluded.

The main agent controlled the simulator. This review read the saved files, inspected images, and calculated image statistics. No simulator commands, source changes, tests, or commits were made by this review.

## Rotation and display selection

The matrix contains 42 command records: two pose requests, eight orientation requests, eight orientation reads, and 24 screenshots. All 42 commands exit 0. FlowDeck reports pose open at 180 degrees and closed at 0 degrees.

All eight orientation set results also report confirmed:false and visualOrientation:unknown. The subsequent orientation read returns the requested orientation. Thus the table labels are requests. They are not independent proof that the physical orientation was confirmed. The open-screen images do change layout. The closed-screen images do not change.

The Apple reference command uses an explicit display: display 3 when open and display 1 when closed. These IDs are specific to this simulator run. Do not hardcode them into AXe. RocketSim selects a visible screen without a display option in the captured screenshot commands.

| Pose / requested orientation | Apple PNG | AXe PNG | RocketSim PNG | Image result |
| --- | --- | --- | --- | --- |
| Open / portrait | 2853×2007 | 2007×2853 | 2853×2007 | AXe content is sideways; Apple and RocketSim are upright |
| Open / landscape-left | 2007×2853 | 2007×2853 | 2007×2853 | All upright; AXe and RocketSim have identical decoded RGB pixels |
| Open / landscape-right | 2007×2853 | 2007×2853 | 2007×2853 | AXe content is upside down; Apple and RocketSim are upright |
| Open / portrait-upside-down | 2853×2007 | 2007×2853 | 2853×2007 | AXe content is sideways; Apple and RocketSim are upright |
| Closed / each of the four requests | 1398×2034 | 2007×2853 | 1398×2034 | AXe is entirely black; Apple and RocketSim show upright Settings |

Dimensions alone do not establish correct orientation: landscape-left and landscape-right have the same dimensions, but AXe renders the latter upside down. The four closed Apple captures have identical decoded RGB pixels; the four closed RocketSim captures also have identical decoded RGB pixels. This is not four independent successful rotations. App orientation policy or incomplete orientation control could explain the unchanged closed display; this evidence does not identify the cause.

The four closed AXe images have RGB minima and maxima of zero for every channel. Their decoded RGB SHA-256 is ff08b88ca7114dfb0271512a4deb52885375a90ae9adfe6c65c50b9af251be48. The open landscape-left AXe and RocketSim images share decoded RGB SHA-256 43eb17b52ed606e3a186e30c693e358b38504897c68f9ad498640fd33374dec9. The hash covers the decoded RGB bytes; dimensions are recorded separately in [image statistics](evidence/2026-10-16-duo/live/image-statistics.json).

The exact commands are stored in the [matrix](evidence/2026-10-16-duo/live/rotation-matrix.json). Command forms were:

~~~text
flowdeck simulator pose set open|closed -S <udid> --json
flowdeck simulator orientation set <orientation> -S <udid> --json
flowdeck simulator orientation get -S <udid> --json
xcrun simctl io <udid> screenshot --display=3|1 <file.png>
<fresh-axe> screenshot --udid <udid> --output <file.png>
rocketsim screenshot --udid <udid>
~~~

## Other observed limits

FlowDeck's closed-state command, ui simulator screen -S <udid> --json --screenshot --output <file>, exits 1. It reports that it cannot choose between two displays and asks for --display=3 or --display=1. This establishes a failure in that CLI screenshot path on this device. It does not establish that every FlowDeck capture interface fails. No flow-closed.png was produced.

AXe describe-ui exits 0 in the closed state and returns a root frame of 466×678 points. This matches the outer display's 1398×2034 pixels at scale 3. Thus a black screenshot does not mean that AXe has no accessibility support at all. The evidence does not prove that every node, hit point, or action uses the correct display.

An earlier RocketSim duo hinge read exits 1 with code simulator_not_booted and reason hinge_not_ready. The message says the simulator did not report a valid angle in time. This establishes a timeout for that attempt, not an actually unbooted device or a general lack of hinge support. A FlowDeck closed pose read returns a valid angle of 0 and posture closed.

## Read-command timing

State: open Duo, requested landscape-left, Settings. Each tool has five warm-up runs and 30 measured runs. Median is the mean of the two centre samples. P95 uses nearest rank. The values below were recalculated from the stored 30 samples per tool.

| Command | Median seconds | P95 seconds | Median stdout bytes | Nonzero exits |
| --- | ---: | ---: | ---: | ---: |
| AXe describe-ui --udid <udid> | 1.0541 | 1.0892 | 595057 | 0/30 |
| FlowDeck ui simulator screen -S <udid> --json | 0.7777 | 1.1001 | 7359 | 0/30 |
| RocketSim elements --udid <udid> --agent | 0.2595 | 0.7062 | 1291 | 0/30 |

[Raw timings and exact commands](evidence/2026-10-16-duo/live/read-benchmark.json).

These are wall times for three different read commands. AXe returns a large raw tree, FlowDeck returns a smaller tree, and RocketSim uses its agent format. The outputs and work are not equivalent. The AXe build is debug; the other tools are distributed builds. Do not turn these values into a speed ranking for equivalent work or complete agent tasks. Output byte counts are not token counts. CPU, memory, energy, cold start, concurrent load, cache policy, semantic accuracy, and complete task latency were not measured. Single screenshot timings from the rotation matrix are also not a valid speed comparison, because AXe often returns incorrect pixels.

## Excluded input baselines

The first Settings-label comparison does not use a valid common starting state. AXe reports two matching elements and explicitly performs no tap. This is a selector ambiguity result. FlowDeck then opens Settings. The next RocketSim label tap reports element_not_found after the screen has already changed. An intervening AXe home command exits 0, but that exit status does not prove that the Home Screen was restored. Do not count the RocketSim result as a failure to tap the original Settings icon.

An earlier AXe Accessibility-label attempt prints a successful tap message. Its saved post-action image still shows the General panel. That success message is not proof that the intended page opened. It needs a known pre-action state and a verified post-action state.

The empty flow-named-open.json is not evidence of success or failure. The separate input repeat below replaces this invalid comparison.

## Input repeat with verified starting screens

Each tool received a separate FlowDeck Home-button reset. Apple simctl captured the active display before and after each tap. All six before images were inspected and show the Home Screen with the Settings icon. The open case requests portrait and uses display 3; the closed case requests portrait and uses display 1. Both orientation requests remain unconfirmed in the FlowDeck response.

| Tool | Open result | Closed result |
| --- | --- | --- |
| AXe tap --label Settings | Exit 1; two AX matches; no tap; Home Screen remains | Exit 1; two AX matches; no tap; Home Screen remains |
| FlowDeck ui simulator tap Settings | Exit 0; Settings General opens | Exit 0; Settings General opens |
| RocketSim interact tap --label Settings | Exit 0 and ok:true; screen_changed:false; Home Screen remains | Exit 0 and screen_changed:true; Settings General opens |

The label task is verified for FlowDeck in both states and RocketSim in the closed state. RocketSim did not complete the open-state task in this attempt, despite ok:true. AXe correctly reports that it refused an ambiguous selector. This does not prove that coordinate input or selection by ID fails; those require separate checks. Each cell is one attempt, not a reliability rate or an input performance benchmark.

See [input command evidence](evidence/2026-10-16-duo/live/input-repeat.json) and the before/after PNGs in that directory. Raw preview URL credentials were removed from the stored JSON.

## Pose confirmation and failure after a state change

The [pose repeat](evidence/2026-10-16-duo/live/pose-confirmation-repeat.json) distinguishes state changes from confirmation:

- FlowDeck pose set angle 90 exits 1 after 32.08 seconds because confirmation times out. The next pose read exits 0 and reports angle 94.616081 degrees, mechanical angle 90 degrees, valid angle and velocity, zero velocity, and partially-folded posture. This is evidence of a partial fold after a failed confirmation. It is not proof that the reported angle equals 90 degrees.
- RocketSim duo hinge during that partial fold exits 1 with hinge_not_ready. The displayed simulator_not_booted code does not establish the actual boot state.
- FlowDeck pose set closed then exits 0. RocketSim duo pose open exits 1 with wait_timeout after 2.90 seconds. The next FlowDeck read reports valid angle 180, mechanical angle 180, and open posture. Thus RocketSim's failure result did not mean that no state change occurred.

AXe should report requested angle, measured angle, mechanical angle, validity, sample time, and confirmation outcome separately. Define angle tolerance and the measurement used for confirmation. A timeout must tell the caller that state can have changed. A blind retry can otherwise repeat an action already applied.

## Recording across a fold

The saved [recording trace](evidence/2026-10-16-duo/live/video-trace.json) uses an open → closed → open sequence driven by FlowDeck. AXe records at requested 10 FPS. RocketSim records at requested 10 FPS for 12 seconds with --bezel none. Both record commands exit 0 and produce readable MP4 files.

| Tool / path | Duration | Track dimensions | Track nominal FPS | Inspected frames near 1 / 5 / 9 seconds |
| --- | ---: | --- | ---: | --- |
| AXe record-video | 10.84 s | 2006×2852 | 9.6864 | Sideways Settings / black / sideways Settings |
| RocketSim video record --bezel none | 12.9067 s | 2006×2852 | 10.0723 | Sideways Settings / black / sideways Settings |

Both tracks have an identity preferred transform. The sampled open content is sideways; the sampled closed content is black. Neither of these two raw CLI paths provides a correct visible-display recording for the complete sequence. This does not establish the behaviour of RocketSim's bezel or Duo composition modes.

The [AVFoundation analysis](evidence/2026-10-16-duo/live/video-analysis.json) records requested and actual sample times. Its [inspection program](evidence/2026-10-16-duo/live/inspect-fold-video.swift) reads all compressed sample timestamps and decodes three image samples per recording. The three samples are not a full frame-by-frame visual review. Unsorted presentation timestamps from a compressed sample reader can reflect decode order; they do not alone prove a playback-order fault or dropped frames. Track nominal FPS is metadata, not a measured rendering performance guarantee. The trace does not record enough event timestamps to measure precise fold-to-frame latency.

A separate RocketSim --bezel device3d run also exits 0. It produces a 12.6183-second, 2852×2036 track with nominal 10 FPS and identity transform. The decoded frames at exactly 1 and 9 seconds show upright Settings within the open device bezel. The frame at 5 seconds shows a black display within the same open bezel; it does not show outer-screen content or a closed device model. This establishes a limit in this recorded CLI sequence. It does not establish that every RocketSim GUI composition mode fails. See the [3D trace](evidence/2026-10-16-duo/live/video-3d-trace.json) and rocketsim-3d-fold sample images in the evidence directory.

FlowDeck simulator record with its default display exits 1 because it cannot choose between two displays. A request with --display 3 is rejected: the wrapper accepts internal or external. The saved --display internal attempt returns success:false with the same two-display ambiguity. These results establish a CLI display-selection limit for those forms only. They do not prove that every FlowDeck recording interface fails. See [default attempt](evidence/2026-10-16-duo/live/pose-confirmation-repeat.json), [numeric display rejection](evidence/2026-10-16-duo/live/flow-display3-record.txt), and [internal display failure](evidence/2026-10-16-duo/live/flow-internal-record.json).

## Source link and proposed work

The observed capture failures agree with risks in the [source audit](2026-10-16-axe-duo-source-audit.md): fixed screen selection, a framebuffer path that selects the first displayClass 0 descriptor, and orientation state tied to screen ID 1. This agreement supports further investigation. It does not prove which line caused each live result.

AXe needs one display-state model that owns display identity, active state, native pixel size, point scale, UI orientation, and hinge state. Capture, accessibility, coordinate conversion, and input must use the same state generation. A fold or rotation must invalidate dependent cached data. A command must distinguish request acceptance from a verified state change. Error results must identify ambiguous displays, stale frames, unsupported operations, and unconfirmed state.

Before claiming complete coverage, verify named poses and arbitrary angles, both displays, all supported app rotations, open/close while capture or input is active, correct post-action state, drag and multi-touch, typing and hardware buttons, recording through a size change, screen stream resize events, agent observation freshness, app background/foreground changes, simulator restart, and version compatibility. Use a known app that reports its own scene and geometry as a reference. The present evidence does not cover these cases in full, physical Duo hardware, or all iOS/Xcode versions.

## Handoff

The main agent reports that it shut down only the audit simulator, UDID 3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463, after the last recording. Cam's existing Duo simulator was not changed by that shutdown. No more live checks are planned in this audit. The repository retains the full [AXe recording](evidence/2026-10-16-duo/live/axe-fold.mp4), [RocketSim plain recording](evidence/2026-10-16-duo/live/rocketsim-fold.mp4), and [RocketSim 3D recording](evidence/2026-10-16-duo/live/rocketsim-3d-fold.mp4), plus decoded sample frames, command traces, and metadata.
