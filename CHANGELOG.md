# Changelog

All notable changes to the AXe iOS testing framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added a repeatable serial Weather, Reminders and Contacts benchmark for AXe, FlowDeck and RocketSim. It records tool versions and hashes, task evidence, calls, time and returned tokens, with explicit acceptance of comparable successful AXe baselines. See [benchmark setup](benchmarks/README.md).

- Added opt-in agent phase timing. `AXE_TIMING=1` prints client and broker phases (display discovery, accessibility reads, snapshot builds, input and refresh) to standard error; `AXE_TIMING=/path.jsonl` appends JSON records. Standard output and requests without timing are unchanged.

- Show a bounded preview of cached scroll areas on compact first pages when their canonical rows are on a later page. Keep canonical rows/cursors, full/base and legacy output unchanged; perform no extra accessibility read. Requires a matched CLI and broker.

- Added explicit `type --agent --focus --snapshot-id --ref` to validate all text, physically focus the same current TextField and type with two phase receipts. Existing focus, identity, context, cleanup and no-replay checks remain; raw typing, default agent typing and reference batches are unchanged. Requires a matched CLI and broker.

- Added bounded read-only custom-action name previews for agent refs and complete JSON-array text through guarded `--text-field custom-actions` chunks. Names participate in freshness checks without adding tap or named-action authority. Raw output and existing rows remain unchanged. Requires a matched CLI, broker and native frameworks.

- Added guarded native-object identity for eligible agent refs without app accessibility IDs. A complete unique native read is required; identities stay private to the per-device RAM table. Existing semantic controls and raw commands retain their behavior. Opaque sliders, AXPress and pinch remain unsupported. Requires matched CLI, broker and runtime versions.

- Added snapshot-bound reference batches and inline `batch --agent --steps-json` input. Up to eight tap/type steps share initial reference validation, fresh target and layout checks, ordered receipts and one final capture. Native-ID/file batches and legacy commands remain available; a matched CLI and broker are required.

- Added agent output views: default `--view reading`, filtered `--view navigation`, and canonical `--view full`, with text or JSON representation. Added read-only `describe-ui --read-ref` field chunks for exact native labels, values and IDs, with explicit Unicode-scalar cursors. These changes require a matched CLI and broker; native framework protocol is unchanged.
- Add one repeatable 300-byte mixed-case Duo raw typing check to the canonical full Duo and keyboard/hardware plans. It verifies exact callback counts, unchanged touch/control state and lowercase input after modifiers. It stays separate from the 133-case agent group. Document the normal visible-software-keyboard prerequisite; no detector, hidden app route or mandatory vendor dependency is added.
- Added a tracked XcodeGen Playground project and one serial 50-case local iPhone/Duo check through the public CLI. It reads real app results for core controls and keyboard edits, Duo screen/hinge/rotation changes, held-input release and fresh taps, plus the separate optional agent interface and cache/reference checks. A visible Touch Monitor records real contacts. The runner reuses existing devices, records exact case results and CPU/memory samples, and rejects missing or skipped cases. See [Playground testing](docs/playground-testing.md).
- Add standalone selected and optional agent slider percentages with current target checks, guarded retained input and bounded native value feedback. Interior values use the current measured display context and require horizontal native scrubber geometry that increases from left to right; numeric 0/100 use the existing endpoint route before input. Raw sliders and endpoint batches stay unchanged. A matched CLI and native frameworks are required. RTL, custom and vertical Sliders remain unproved.
- Added optional `batch --agent --file` for 1...8 exact-ID tap/type steps on one app, with fresh target resolution, existing per-action input guards, ordered completion receipts and stop-on-failure without rollback or replay. Legacy and selected batches are unchanged. Native frameworks and RS/1 rows are unchanged.

- Added explicit `record-video --follow-active-display` for one-boot measured display changes, with per-frame context checks, bounded read-only transition recovery and a fixed aspect-fit canvas. Existing selected and legacy recording stay unchanged. Movie gap statistics are reported. Recording is low-rate and does not capture smooth animation.

- Added standalone `gesture pinch --agent` for a current area reference, with fresh checks on both starting-point hits before either touch starts. Existing target/scroll actions, raw presets and selected coordinate gestures remain unchanged. The complete pinch uses existing motion bounds, context checks and both-contact release; agent batches reject. Native frameworks and RS/1 output are unchanged.

- Added standalone `slider --agent --endpoint minimum|maximum` for current slider references, with fresh snapshot/PID/context, native target/value/domain checks and final owned-handle admission before each adjustment. Agent receipts include bounded semantic action counts and endpoint values. Existing raw percentages and selected selectors are unchanged; mixed options and agent batches reject. A matched CLI and rebuilt native frameworks are required.

- Added standalone `clipboard copy --stdin --udid <UUID>` to stage bounded exact UTF-8 bytes through public CoreDevice, with private exact readback and a JSON transport receipt (`inserted: false`). Shared clipboard replacement is explicit; no automatic Paste, retry, fallback or restore is added.

- Added standalone `gesture double-tap --agent` for a current tap-capable reference, with fresh target/point checks, bounded timing, context checks and owned release. Coordinates, other gesture payloads and agent batch use reject. Native frameworks and raw/selected gesture paths are unchanged.

- Added standalone `key-sequence --agent` for complete key presses on a current focused TextField reference, with snapshot/PID/focus checks and owned key release. Inter-key delay and sequence bounds apply before input; agent batch and focus-ID overrides reject. Raw/selected behavior and native frameworks are unchanged. Older brokers reject the new request kind.

- Added selected Siri, Lock and Apple Pay button commands and batch steps with measured context, optional boot checks and typed release evidence. Apple Pay keeps the native two-side-press adaptation and four-event receipt. Older brokers reject these requests; native frameworks and raw button routes are unchanged.

- Added standalone `key-combo --agent` for complete modifier shortcuts on a current focused TextField reference, with snapshot/PID/focus checks and owned key release. Raw and selected combinations remain unchanged; agent batch and focus-ID overrides reject.

- Added standalone `key --agent` for one default key down/up on a current focused TextField reference, with snapshot/PID/focus checks and owned release. Duration, focus-ID overrides and batch use reject; raw and selected key behavior is unchanged.

- Added complete `touch --agent --ref` presses and timed holds with fresh native target/hit checks, owned release and snapshot refresh. Coordinate touch behavior is unchanged; partial contacts, retained tokens and batch agent use reject.

- Added `shutdown --udid <UUID>` for one simulator through public `simctl`, with confirmed Shutdown state, distinct `alreadyShutdown` output and no all-device alias. This is simulator lifecycle control, not guest lock or power-button input.

- Added optional `drag --agent` from an existing snapshot target/scroll reference to an explicit logical endpoint. The start uses fresh native target and hit validation; existing owned drag limits, context checks and release remain. Raw drag is unchanged, and batch use rejects.
- Added standalone selected `gesture two-finger-swipe` with independent straight start/end paths, shared duration/spacing and existing measured input/cleanup. Either finger may stay still. Simultaneous coincident contacts reject before input, including between samples. Batch and agent mode remain unsupported. Older brokers reject these requests.

- Added `hinge set closed|tabletop|open` as names for 0, 90 and 180 degrees. Numeric angles, options, JSON output, measured mechanical completion and separate screen readiness checks remain unchanged.
- Added agent-only `tap --label-contains`, `--label-regex` with Foundation regex syntax, and logical-point `--frame` filters for explicit selectors. Queries use bounded fresh native-tree resolution, reject ambiguity and retain exact native target/context checks before input. Existing exact/ref routes and no-flag behavior remain. Older brokers reject new selector payloads rather than ignore filters.
- Added optional agent-capture software-keyboard evidence from the existing selected app accessibility read, with separate signal counts and `likelyVisible` or `unknown` state. Missing evidence never reports the keyboard as hidden; raw no-flag output is unchanged.

- Added opt-in `--agent` snapshots and guarded reference actions on `describe-ui`, `tap`, `type` and `swipe`, with compact RS/1-style output, bounded broker state, immutable snapshot IDs and fresh context/target validation. Existing commands without the flag retain their raw output and coordinate route. Older brokers reject these requests.

- Added bounded wait/poll options for ordinary selected ID, label and value taps and individual batch tap steps. Only absent matches retry; device changes and disconnected clients stop the wait before a late tap. Older brokers reject these requests.

- Added `rotate left|right` for the verified Duo profile, with explicit active-screen and boot checks, one device-wide request, stable rotation readback and the common input lock. Older brokers reject these requests. App layout readiness requires a fresh UI read.
- Added local arm64 Duo display selection, measured coordinate transforms, guarded HID sessions, complete multi-touch gestures, native slider endpoints and hinge read/set with display readiness.
- Added selected text and key input with an explicit field/PID check before each key down and owned key release on interruption.
- Added `list-simulators --displays --udid` for measured display discovery and explicit `tap --semantic-press --id` for one native CheckBox on the inspected host framework image, with no mouse or HID fallback.
- Added selected `describe-ui --point` with oriented coordinates, exact foreground/result PID checks and one bounded point read.
- Added active-panel PNG screenshots with paired `--screen-id`/`--screen-uuid`, optional `--expected-boot`, context checks and a JSON receipt. Selected capture does not replace existing output files or fall back to another display; surface identity and frame presentation time remain unavailable.
- Added batch-level selected display input for complete tap, swipe, gesture, touch and keyboard steps, with fresh per-step guards, structured receipts and stop-on-failure behavior. Unsupported steps reject without legacy fallback; legacy batches remain unchanged.
- Added explicit `gesture --edge-inset` for the start of the four edge presets in legacy and selected routes, including batch steps. The opposite 20-point endpoint and existing defaults are unchanged. Explicit legacy insets require a path span of at least the effective delta; navigation effects still require separate verification.
- Added explicit selected-screen `record-video` with per-frame context checks, awaited signal stop and publication of completed MP4 files without replacing existing output. Selected clips require one fixed pose; recording across rotation or folding remains incomplete.
- Added fixed-pose selected `stream-video` for multipart JPEG, length-prefixed JPEG, concatenated JPEG and packed BGRA. The route shares validated capture ownership with selected recording, reports metadata on stderr and stops on context or output failure; legacy streaming is unchanged.
- Added selected batch `drag` steps through the existing guarded drag route, with standalone options and defaults, per-step fresh bounds and stop-on-failure receipts. Legacy batch drag remains unsupported.
- Added selected batch slider endpoint steps with exact ID/PID selection and semantic value-readback completion, including an already-at-endpoint result with no action. Unsupported options and failed receipts stop later steps; legacy batch slider remains unsupported.
- Added standalone selected `button home` with active-display context and optional exact boot guards, preserved hold durations and typed transport execution/cleanup evidence. Home remains a device-wide action.
- Added selected batch `button home` through the existing guarded Home request, with optional per-step boot and duration checks and typed release completion. Other buttons remain unsupported; a failed receipt stops later steps without replay.
- Added matched `bootIdentity` and a host-monotonic `readInterval` to `list-simulators --displays --udid` JSON, preserving its existing fields. This read evidence does not replace fresh input/capture checks or change default legacy capture.
- Added exact, case-sensitive `--element-type` filtering for ordinary selected ID/label taps and their batch steps, before uniqueness and final target validation. Selected protocol versioning prevents older brokers from ignoring the filter; legacy taps are unchanged.
- Added ordinary selected `tap --value` and matching batch steps, with legacy scalar text conversion, trimmed case-sensitive matching, optional exact type and strict fresh target checks. Coordinate-selector combinations and value-based semantic press remain unsupported.
- Added explicit `--tap-style physical` for ordinary selected coordinate and ID/label/value taps, including tap steps in selected batches, through the existing guarded touch path. Omitted style and legacy behavior are unchanged; semantic press rejects every explicit style.
- Added explicit `--tap-style simulator` for ordinary selected coordinate and ID/label/value taps and their batch steps. It uses the real `tapAt` down/up sequence without an inserted hold, while retaining target/context/cleanup guards and pre/post delays. Omitted/physical style and legacy behavior remain unchanged. Older brokers reject the typed style; exact timing parity is not guaranteed.

- Added explicit `--tap-style automatic` for ordinary selected taps and their batch steps. Coordinates use simulator `tapAt`; selectors use the existing switch/toggle classification on the resolved target and recheck the style choice before the first down. Target/context/cleanup guards remain strict, with no legacy redirection or retry after failure. Older brokers reject it; omitted, physical and simulator behavior remain unchanged. This does not establish full switch support or exact timing parity.

- Added selected batch `sleep` as a cancellable host wait for finite non-negative durations, with typed wait receipts, no input lease and fresh guards on the next input step. Legacy sleep behavior is unchanged.
- Added optional exact, case-sensitive `--element-type` filtering for selected slider ID endpoints and their batch steps. Global ID uniqueness and native Slider role, value-domain and fresh-target checks remain required. Older brokers reject these requests; legacy slider behavior is unchanged.

- Added exact-label selection for selected slider endpoints and their batch steps. Labels match case-sensitively after whitespace/newline trimming, with duplicate matches rejected before the optional type filter. A native Slider can be selected without an ID; PID, context, frame, domain and fresh owned-target checks remain required. Older brokers reject these requests. ID selection and legacy behavior are unchanged.

- Added selected batch `type --stdin` through the existing bounded text loader and keyboard guards. Text is read at its ordered step; invalid input stops later steps. The synchronous EOF read has no deadline or cancellation while blocked; use batch `--step` or `--file` so stdin remains available for text.

- Added selected `button side-button` and matching batch steps with active-context and optional boot guards, preserved duration, and typed transport execution/cleanup evidence. Older brokers reject these requests. This does not prove lock, wake, power or security state; Home and legacy routes are unchanged.

- Added full-package Playground groups for reference lifetime, broker restarts, cache invalidation after raw edits, equal-hash native changes, retained keyboard ownership and concurrent raw input. Direct groups remain separate from the standalone matrix.

- Added `--output text|json` for explicit command result formatting. Agent text uses compact RS/1; agent JSON keeps its existing envelope. Ordinary JSON uses one versioned command result, including failures. Existing no-format output and command-specific `--json` remain. Put formatting before screenshot/movie commands to preserve their `--output` paths; explicit formatted streaming rejects before capture.

### Changed

- Group identical ordered custom-action previews in adaptive `capture.customActionGroups`, with every published ref retained. Canonical/full keeps its `customActions` map. Both forms preserve name bounds, per-ref truncation and guarded full readback; input and freshness checks are unchanged. The unreleased public adaptive schema remains version 2.

- Use public adaptive agent schema 2 for reading/navigation output while preserving canonical schema 1 in full view and all no-flag raw commands. Compact rows merge capabilities without renumbering refs, cap displayed cells, and return explicit page cursors. Row limits now apply to one global page across targets, scrolling and text. Unchanged replies retain only current snapshot identity, sequence and displayed expiry after the existing live checks.

- Make `--expected-pid` optional with `--agent`: a new capture discovers the frontmost app or SpringBoard from one native observation, while references keep their saved PID. A supplied PID must be positive and match. App, layout and focus checks, coordinate forms and raw commands remain. A matched CLI, broker and native frameworks are required.

- Removed the new Duo `--ax-preparation` option and retained AX-preparation layer. Selected reads and physical target checks keep the normal IDB accessibility-readiness check, including the original short-lived bootstrap where required by the existing runtime policy. Original v1.8.0 IDB bootstrap behavior, native slider/switch identity sessions and HID input remain unchanged. Older requests reject; matched rebuilt native frameworks are required.

- Build IDB from a tracked patch against the exact fork base without discarding unexpected source changes. Builds accept `arm64`, `x86_64` or both.
- Added `scripts/build.sh debug-helper` to stage the signed simulator helper beside the SwiftPM debug executable.
- Admit reference taps, swipes, drags, pinches, holds and double-taps on the owned native operation's own complete tree, as reference batch taps already do, instead of a separate pre-description compared with it. The owned tree must still have the table's exact native fingerprint, target identity, frame and context; the native point, PID, live-context and hit checks before input are unchanged. Typing and sliders keep their pre-description. Reference actions and post-action replacement reads use the table's display, whose full context read admits that panel again; a replaced active panel is discovered only after that read fails. Owned admission rejections before input now return their typed code (for example `screenChanged`) instead of `nativeActionFailed`. A tap or swipe drops about 1.3 to 1.7 s of repeated reads. `AXE_TIMING` now lists each full context read inside an accessibility read and the path guard's reads.
- Read guest display identity, geometry, rotation and active state with one in-process CoreDevice `displayinfo` request instead of a `devicectl` child and the `cadisplay-context` guest helper. Full context reads and display discovery drop from about 200 ms to 8-28 ms; an iPhone 18 Pro agent tap drops from about 5.3 s to 2.4 s. Host catalogue, boot identity, hinge and selected-panel checks are unchanged, and the response is validated by the same active-panel rules without a CoreDevice version pin. Requires rebuilt native frameworks.
- Classify simulators by the built-in touch displays their device type declares instead of an exact profile allowlist. One integrated digitizer is a rigid device; two require native hinge samples on every full read and fail before input without them; other sets are refused. The iPhone Duo now works on the installed Xcode 27.2 profile 407 for agent, selected, hinge and rotation commands. Requires rebuilt native frameworks.
- Cut agent and broker input overhead. A broker-owned DTUHID connection no longer sleeps 380 ms after each gesture; every disconnect instead waits out that window after the last send. A refusal before any event returns its untouched connection for reuse. Admission tree reads go direct first, with runtime preparation only after an empty tree, and point reads prepare only after a failed direct read. Snapshot-bound coordinate taps and paths admit on the operation's own tree instead of a separate description. The fixed 300 ms pause before a replacement snapshot is removed; a large screen change is confirmed by two equal reads, and the swipe settle no longer pauses before its first baseline read. On iPhone 18 Pro, agent reference and coordinate taps drop from about 1.8 s to 1.0 s (v1.8.0 tap: 1.27 s). Duo taps take 1.0-1.1 s on either panel. Requires a matched CLI, broker and rebuilt native frameworks.
- Route ordinary `tap` on DTUHID devices through the broker's retained input connection, as on the Duo. Repeated plain taps take about 0.15-0.2 s instead of opening a new guest connection and draining before exit (about 1.9-2.3 s). Physical-style plain taps on this route hold for 0.1 seconds, as selected, agent and Duo taps do. Ordinary `swipe`, `drag`, gesture presets and complete `touch --down --up` take the same route: each previously opened a guest connection (about 0.6 s) and drained it before exit (about 0.4 s), plus a 0.45 s accessibility bootstrap for the orientation probe. On iPhone 18 Pro a swipe drops from 3.5 s to 1.2 s (v1.8.0: 1.9 s), a drag from 3.3 s to 1.7 s (v1.8.0: 2.5 s), a touch from 2.0 s to 0.25 s (v1.8.0: 1.1 s) and a gesture preset to 0.7 s (v1.8.0: 1.25 s); the Duo matches. Presets keep their 390×844 default dimensions on rigid devices, and a partial `touch --down` or `--up` keeps its existing route.
- Read plain `describe-ui` and `describe-ui --point` directly, as selected and agent reads do. Simulator runtimes 27 and later ran a short-lived accessibility bootstrap before every plain read (about 0.15 s on iPhone 18 Pro and 0.45 s on the Duo, whose remote automation session takes longer to start); it now runs only after an empty tree or a failed point read. Output is unchanged. A plain read takes about 0.55 s on both devices instead of 0.60 s and 0.95 s, and a point read about 0.1 s. Requires rebuilt native frameworks.
- Read each accessibility element's attributes in one translator request instead of one request per attribute. The element's children arrive in the same answer; custom action names keep their own read, because the batched value omitted a keyboard key's actions in comparison reads. A missing answer or an unexpected value falls back to the original accessor. Output is unchanged: plain trees (255 iPhone and 212 Duo elements) and agent captures were identical to the per-attribute reads. On iPhone 18 Pro and the Duo, a plain or agent description drops from about 0.5 s to 0.3 s, an agent reference tap from about 1.1 s to 0.75 s, and an agent swipe with its settled snapshot from about 2.6 s to 2.0 s. Requires rebuilt native frameworks.
- Keep AXe's IDB frameworks in the repository as `Packages/IDBKit` instead of cloning a pinned IDB fork and applying `patches/idb-duo-foundation.patch`. The package holds `FBControlCore`, `FBSimulatorControl`, the private headers they compile against and their tests, with AXe's changes already applied; edit them directly. `scripts/build.sh` generates their project with XcodeGen, and the release workflow caches frameworks by the package's source tree instead of the fork revision. `FBDeviceControl` and `XCTestBootstrap` are no longer built or shipped: AXe never used them, and the simulator REPL and XCTest commands that needed `XCTestBootstrap` are removed. The `IDB_CHECKOUT_DIR`, `IDB_GIT_URL`, `IDB_GIT_REF` and `IDB_UPSTREAM_BASE_REF` build settings are gone.
- `make build`, `make test`, `make e2e` and the benchmarks rebuild the IDBKit frameworks only when they are stale: when `Packages/IDBKit`'s content, the selected Xcode or the requested architectures differ from those recorded at their last build (`scripts/build.sh frameworks-if-needed`). `make build` and `make test` previously never built them, so they failed without frameworks and silently linked stale ones after an IDBKit change; `make e2e` rebuilt them, about 10 minutes, on every run.
- `./benchmarks/run` builds the current source and measures that build; `config.local.json` no longer names an AXe executable. The CLI is always rebuilt; the frameworks only when they are stale, as for `make build`. Each run copies the exact binary, frameworks and resources beside its results, so a later build cannot change what a report measured. `--axe PATH` measures a specific build instead. The runner, grader and task hashes are unchanged, so new results still compare with the existing baselines.
- A default `./benchmarks/run` no longer measures FlowDeck or RocketSim again when history already has a measured run of the current version for every selected app; it prints the reused run IDs and measures AXe. `--tools` or `--rerun-competitors` measures them again.
- Fixed Reminders benchmark preparation blocking every second run with "Expected list overview is not visible". After the delete confirmation it read the screen once, as soon as the tap returned, while the list detail was still popping to the overview. It now reads until the overview appears, within 5 s, outside the benchmark clock. Its label tap on "Delete List" during the menu animation was the other cause, now absorbed by the agent in-call retry.

### Fixed

- Fill compact agent reading pages from the captured snapshot without a second simulator read. Explicit page requests still validate the current UI.
- Support the measured DeviceKit 689.2 display report and the iPhone 18 Pro simulator profile 407 with its verified model and display ID. If the report omits the active flag, accept one lit primary built-in display that matches the host catalogue. Multiple built-in displays require an explicit state for each display and exactly one active display.

- Publish agent swipe references only after two exact native observations agree. If the bounded check does not confirm a stable view, retain the completed-input receipt and require a fresh read without replaying input. Existing input guards remain. Requires a matched CLI and broker.

- Recognize verified numeric keyboards and use measured docked bounds for agent swipe planning. Preserve exact target, identity, context and cleanup guards. Requires a matched CLI and broker.
- Include visible labelled image content in agent reading/full observations without adding tap authority.

- Preserve exact agent label and value whitespace in full and compact snapshots, and invalidate cached references after whitespace-only changes. Keep search normalization and raw legacy output unchanged. Requires a matched CLI and broker.

- Stop advertising navigation continuation pages when only static text remains; keep reading/full cursors and pages with more controls unchanged.

- Keep explicitly formatted screenshot success output on stdout without a second plain stderr message. Default screenshot output and selected capture are unchanged.

- Omit misleading native totals and initial offset zero from terminal compact agent pages. Preserve explicit nonzero offsets, real continuation cursors, page-fill evidence and warnings; full/base and legacy output are unchanged.

- Fixed legacy physical taps returning success without changing real controls after the contact was shortened to 100 ms. They now use one 250 ms contact, with the transport drain after release and the existing release-only cleanup.

- Fixed omitted `tap --agent --tap-style` using the automatic style instead of the documented physical default. Explicit styles and legacy commands are unchanged.

- Fixed physical single `--agent` Button reference taps failing when a unique semantic label and a row-level point result used different accessibility representations. After the existing reference checks, eligible Buttons bind the same fresh native object for the unchanged guarded input path. Reference batches and nested permission Button chains are unchanged.

- Fixed extra delay in legacy physical taps by sending the complete press in one event sequence. Release cleanup remains available after failed delivery.

- Keep guarded keyboard input on the same focused field when its editing bounds change after the first owned key. Native field identity, focus, state and display checks still run before each later key.
- Tap a named CheckBox row at its unique native child control, with fresh parent/child and point-hit checks.
- Omit duplicate `totalSteps`, `rolledBack: false`, per-step request IDs, receipt kinds that equal the step action, receipt `replayed: false` and superseded `batchInProgress` caches only from complete successful compact batches with a usable fresh final capture. Full and failure output retain these fields.
- Start agent reference swipes on an eligible current text descendant inside the selected area when the standard start lacks one. The requested stroke and fresh native target, point, hierarchy and context checks remain.
- Check each reference batch tap against one fresh tree owned by the native operation, replacing the extra controller read and two-tree fingerprint comparison. Original plan, layout, PID, context and capability checks and native input guards remain.

- Allow reference batches to continue when standalone result text changes its glyph bounds. Button, container and control-child geometry stays bound to the original layout; fresh native admission still applies before each action.

- Allow focused TextFields to share an accessibility ID with non-text containers and controls. The ID must still identify exactly one TextField before focus, process and state checks; per-key native validation remains required. This needs the matching rebuilt native framework.

- Bound compact top-level and batch-step agent error messages to 1024 Unicode scalars, preserving their prefix/suffix and explicit truncation metadata. Typed codes, cleanup, quarantine, context and recovery fields are unchanged; full view retains complete messages.

- Use measured selected-display bounds for agent viewport visibility, including pre-input path and slider checks, so a stale portrait Application root cannot hide in-bounds inner-landscape controls. Raw builder callers keep their existing inferred viewport.
- Remove repeated device context and native-proven redundant Button child labels from compact agent output. Full native text, selector matching, fingerprints, input safety and exact readback remain in the broker.

- Fixed one exact accessibility focus-read disconnect by allowing one fresh guarded read within the existing deadline. No key or action is replayed; PID, focus, context and target checks remain.

- Fixed stale Duo input observations by renewing hinge samples and display observations separately from the change listener. Existing freshness and read limits remain.

- Fixed precision-slider planning admitting a path without its minimum pacing and confirmation time. Later corrections use the measured slope directly; action, release, tolerance and motion bounds remain.

- Fixed a full selected-broker request queue closing the next client without a terminal refusal. It now sends busy before reading the request body, so readiness recovery cannot send delayed first input after another action ends. Capacity, protocol version and I/O limits are unchanged.

- Fixed repeated raw keyboard commands creating a new simulator input connection after selected input. Complete legacy keyboard commands can now retain one healthy connection on verified DTUHID profiles, with a new session for each call. Reuse requires confirmed key release, drained input and current context; errors, cancellation and layout changes discard it. Input order, guest-reply limits, existing profile routes and no-replay rules remain. This requires the matching rebuilt native framework.

- Route no-flag keyboard input on Duo and verified ordinary DTUHID profiles through the same broker input owner as selected and agent controls. The selected protocol carries the exact legacy event stream by private file identity, without a selected-text limit or new whole-command deadline. Parsing and plain output remain.


- Keep the Playground screen awake while active so idle-reference checks can run without Auto-Lock. Normal idle behavior returns when the app is inactive.

- Fixed optional `--agent` references being lost when the background broker stopped after 30 idle seconds. The broker now stays available while its current 60-second snapshot is valid. Existing retained-input release deadlines remain unchanged.

- Fixed a rejected old `--agent` snapshot ID clearing another caller's newer reference table. The old request still sends no input; the newer references remain subject to fresh app, display and hierarchy checks.

- Fixed Duo display discovery rejecting an inactive virtual display. Built-in screen identity, geometry and active-screen checks remain.

- Fixed selected keys, held touches and pinch gestures continuing after their CLI command exits. The broker now cancels the request and waits for owned input release without replay.

- Fixed initial IDB source setup checking patch-added files before applying the tracked patch. Git identity and exact source checks remain required.

- Fixed selected focused typing repeatedly serializing the full accessibility tree. Per-key PID, focus, frame and context checks now use the existing exact-field read. Selected and optional `--agent` keyboard input allow eight seconds for input work plus at most 20 seconds of validated requested delays in one deadline (28 seconds at most), with each field read capped at eight seconds.

- Fixed Duo keyboard failures closing the connection before owned key-up cleanup could complete. The connection now remains available only for owned releases after input stops, with no replay. Ordinary Duo `key`, `key-combo` and `key-sequence` use the same owned keyboard path as `type`.

- Keep child control identifiers distinct in grouped Playground screens.

- Fixed `scripts/build.sh sign-executable` leaving the copied resource bundle unsigned. It now signs and strictly verifies `AXe_AXe.bundle` before the existing CLI signing step.

- Fixed release extraction failing on framework links whose targets are absent. Metadata cleanup now acts on the links. Public post_install re-signs the CLI, helper and frameworks ad hoc.

- Fixed selected `tap --semantic-press` treating a true native reply as switch success. It now requires fresh Boolean value change on the same target within the original budget, preserves native reply/delivery evidence and rejects older reply-only success at the caller. No action is retried; physical taps are unchanged.

- Fixed ordinary batch validation errors showing a generic system error instead of the command message. Cleanup and input receipts are unchanged.

- Fixed ordinary Duo standalone typing to use the existing measured owned session, including startup readiness, context checks, signal cancellation and key cleanup. Literal/file/stdin loading, US mapping, plain output and other-device routes are preserved.

- Fixed ordinary Duo batches to use one measured input owner, preserving ordered touch/key state, typing chunks and repeated modifier events. Changed context or input failure stops later input; blocked step stdin is cancellable, and owned input closes before exit.

- Fixed ordinary iPhone Duo `touch` routing to use the measured active display and owned contact stream. A down starts or moves one contact; up ends at its supplied point without an added move. Successful downs remain owned for up to 60 idle seconds; an orphan up sends zero HID events. Explicit selected tokens and other-device routes remain separate. Older brokers reject these requests.

- Fixed no-flag iPhone Duo swipes and drags missing the inner display in landscape. Both now use measured display context and their existing event factories, with host pre/post waits, logical coordinates and normal output. A Duo-only limit rejects paths above 100,000 movement steps before allocation; drag retains its 1...1,000-step limit. Older brokers reject these requests.

- Fixed no-flag iPhone Duo taps missing the inner display in landscape by using measured active-display context. Logical coordinates, legacy selectors/styles, waits/delays and plain text output remain; other-device routes are unchanged. Older brokers reject these requests.

- Fixed Homebrew installations omitting the selected-screen helper. The formula now installs and signs `cadisplay-context`; release checks require the helper in the package.

- Fixed selected slider ID requests failing when an earlier element had a longer ID with the same prefix. Native handle lookup now uses exact, unique ID matching; duplicate and wrong-role requests still reject before action.
- Fixed live library retained touches staying held while the caller is idle after folding or rotation. Single and paired contacts now release on the original connection; `close()` waits for owned automatic cleanup and preserves uncertain-release failures.
- Fixed selected input holding contacts through fold or rotation changes during long delays and between retained-touch commands. The owner releases on the original connection, rejects old tokens and keeps uncertain cleanup blocked.
- Fixed selected exact-ID physical taps on UIKit switches whose point hit is an unnamed child. Native identity, screen and parent checks now validate that child before input.
- Fixed selected display discovery and input admission for iPad mini (A17 Pro) simulator profile 405.
- Fixed compressed video streams returning PNG bytes as JPEG at default quality and scale. Invalid or incomplete image data is now rejected.
- Handle `SIGINT` and `SIGTERM` during selected PNG capture by cancelling and awaiting the operation. Accepted early cancellation publishes no PNG; unconfirmed cleanup remains an error.
- Fixed finite positive legacy swipes shorter than the effective delta producing non-finite coordinates by using at least one step.
- Fixed the build artifact check rejecting AXe-owned accessibility type names. It now matches complete private identifiers while retaining required module and fork-feature checks.

- Fixed selected slider reads accepting a matching descendant in place of the owned target. ID and label reads now require the owned root itself to match before each action and final read.

- Fixed optional `--agent` output omitting existing AX owner-mismatch evidence. Optional `data.observation` reports expected/observed PID, acquisition outcome and bounded attempts, with explicit fresh-capture guidance and no automatic owner change or input replay. Existing flags are unchanged.

- Fixed universal builds rejected by the Duo arm64 guard and AX linker stub tags. The build now uses SDK-backed exports and matching simulator helper slices, with slice and platform checks.

- Fixed Duo slider verification using the input deadline after the contact had ended. Input keeps its 15-second limit; confirmed released input now has one fixed two-second read-only settlement and final verification window. The no-flag interior route reuses the first frontmost app PID, and independent native context probes overlap within the same identity and pose checks.

- Fixed no-flag Duo scroll presets using legacy geometry after rotation. Presets now use the measured active display and existing owned input.

- Fixed completed raw touches keeping selected and agent input busy. The raw helper now opens input when a request needs it, releases ownership after a completed UP, and keeps one session while a finger remains down.

- Fixed selected and agent taps on Photos permission buttons represented by matching parent and child Buttons. Native identity and hit checks select the current child; separate duplicate controls still reject.

- Fixed selected and agent Slider corrections using positions before native pixel rounding. Feedback now uses the effective display pixel points. No-flag interior percentages on verified profiles reuse the shared owned path, with the existing 0.07 percentage-point acceptance limit. Selector lookup, polling, plain output and numeric endpoints are preserved. Unverified rigid profiles and rigid Sliders without stable IDs keep their previous route.

- Fixed selected and agent accessibility errors omitting the existing native acquisition failure reason. The error message now keeps that detail without a read retry or input replay.

- Fixed no-flag Duo gesture presets with omitted screen dimensions using fixed portrait geometry. Default paths now use the measured active-display dimensions after rotation or folding; explicit dimensions are unchanged.
- Fixed slider endpoint checks marking completed input as uncertain when a later read fails. Input without confirmed readback remains uncertain; the 15-second limit and final checks are unchanged.

- Fixed Duo hinge confirmation timing out after a fold. Confirmation still requires two fresh matching readings within the existing time limit.

- Fixed stale `--agent` references returning unrelated accessibility errors. Saved snapshot and current screen checks now run before the app read, so old targets are refused without input and require a fresh snapshot.


- Fixed short raw key and key-combo calls losing HID readiness between CLI processes by reusing the raw input broker. Explicit key holds keep their existing path. Concurrent raw requests are refused before they can wait and run late; retained touch release remains available.

- Fixed whole-tree accessibility reads spending their limit on repeated readiness preparation. Reads now try direct acquisition first and permit one existing bounded preparation only after the same app and screen return an empty tree. Point, focus and single-attempt paths keep their earlier behavior.

- Fixed broker-owned selected gestures opening a second native input connection after typed input. Default-edge HID actions can use one healthy native connection, with a fresh session, context checks and input state for each action. Retained input keeps its same session until close; only proved complete, drained and released input can return a connection for reuse. Failed or uncertain input and layout changes discard it. The complete raw keyboard route uses the same ownership policy where its measured profile is supported; other profiles keep their existing route.

- Fixed display discovery rejecting the measured iPhone18Pro405/DeviceKit651.28 report when an unused virtual display omits its active flag. Built-in identity, geometry, primary-screen and strict schema checks remain. Duo rules are unchanged.

- Fixed the Photos permission test leaving a prompt after an exact zero-input screen-change refusal. It permits one fresh observation and request only when the receipt proves no input and the same app state remains, within the original deadline. Cleanup cannot change a failed test to a pass.

- Fixed one-shot Duo hinge reads closing the guest connection before the motion request completed. A read now waits for a fresh sample, the cancellation reply to drain and the original request to finish within the existing three-second limit. The two-sample fold confirmation rule is unchanged.

- Fixed uncertain state-only rotation keeping the common input lease after its sender closed. Only operations that cannot retain keys or contacts release that lease; unknown input cleanup remains quarantined.

- Fixed selected UI description depending on continuous motion-feed startup. Read-only description now uses the existing fresh one-shot native context; input retains its live freshness checks.

- Fixed Duo input admitting a display report taken mid-fold, when the incoming panel is active while the outgoing one is still lit (about 150-240 ms). Any lit inactive display now reads as a changing context, and the normal transition retry applies.

- Fixed follow-active recording treating in-process display-info refusals as unrecoverable. A confirmed request with no child process is accepted for the existing transition recovery.

- Fixed agent replacement snapshots read during a screen transition containing both the old and new screens. A large change is confirmed by two equal reads before publication; in-place changes publish at once.

- Fixed agent swipes refusing a start point in the blank part of a scroll area, where accessibility reports no element. The fresh tree must show that only the area, its ancestors and passive content containers cover the start; a covered or nested start still refuses before input. Point reads no longer prepare and retry when the point is empty.

- Fixed agent swipes on scroll areas never returning a replacement snapshot. The linear path released at full speed, so the content kept decelerating for about 1.8 s, past the settle window, and every swipe ended with `postActionRefreshFailed`. Agent ref and coordinate swipes now slow to rest before lift-off (cubic ease-out over the same events, endpoints and duration), so the content stops with the finger and moves about the requested distance. The pause between compared replacement reads drops from 300 ms to 100 ms. On iPhone 18 Pro and the Duo, an agent swipe with its settled snapshot takes about 2.4-2.7 s, and a tap that changes screens 1.8-2.5 s instead of 2.3-2.7 s; a read 1.5 s later matched every published snapshot. Raw, selected, preset and Duo plain swipes keep their linear release. Requires a matched CLI and broker.

- Fixed plain `describe-ui --point` on an unfolded iPhone Duo failing with "No translation object returned" (v1.8.0 returned an unrelated enclosing group). The default display query hit-tested the outer panel; on the Duo the point is now read on the measured active panel with its display transform, as selected point reads are. Rigid devices keep the default query. Requires rebuilt native frameworks.

- Fixed the release smoke tests failing on `axe init --print | grep -q`. The early `grep` exit sent SIGPIPE to `axe` while it was still writing the 35 KB skill text, which fails the pipeline under `pipefail`; the checks now read the whole output.

- Fixed an Indigo HID send after disconnect never completing. The legacy client freed the message and returned without calling back, so the caller waited forever; it now fails with `clientDisposed`. Requires rebuilt native frameworks.

### Removed

- Removed the `cadisplay-context` simulator helper, its build, signing, packaging and Homebrew install, the `scripts/build.sh debug-helper` command and the `devicectl` display-report decoder. Display state is read in-process through CoreDevice, so selected input, capture and recording no longer need a helper beside AXe. Requires rebuilt native frameworks.

## [v1.8.0] - 2026-07-20

### Added

- Added Xcode 27 and iOS 27 simulator automation through Device Hub without requiring Simulator.app, while retaining Xcode 26 support ([#60](https://github.com/cameroncooke/AXe/pull/60) by [@jkaunert](https://github.com/jkaunert)). See [Xcode compatibility](README.md#xcode-compatibility).

### Changed

- Strengthened release supply-chain integrity with immutable, verified IDB sources and stricter validation of release inputs and signing identities.

### Fixed

- Fixed BGRA video streams ignoring the requested `--fps` value and running at an uncapped frame rate.
- Fixed release archives failing strict Gatekeeper verification because of embedded filesystem metadata.
- Fixed commands exposing low-level simulator errors instead of actionable failure messages.

Various other internal improvements to stability, performance, and code quality.

## [v1.7.1] - 2026-06-02

### Added

- Added AxePlayground alert, sheet, context menu, modal navigation, and long-scroll fixtures for UI automation regression coverage.

## [v1.7.0] - 2026-05-11

### Added

- Added `axe slider --id/--label --value 0...100` for selector-based slider setting with orientation-aware HID dragging and AXValue tolerance verification/failure reporting.
- Added `axe drag --start-x/--start-y --end-x/--end-y` for raw point-to-point low-level HID drag validation using explicit touch move events.

### Changed

- Changed `axe slider` to use the shared composite low-level HID drag path with AXValue tolerance verification instead of retrying with correction gestures.

### Fixed

- Fixed `describe-ui` and selector-based `tap --label` exposing and activating real SwiftUI `TabView` tab items, navigation search fields, toolbar segmented picker items, and generated navigation back buttons from the CoreSimulator accessibility bridge. Also fixed selector decoding when the accessibility tree contains numeric `AXValue` fields such as sliders.
- Fixed `tap`, `touch`, `swipe`, and matching batch steps dispatching logical UI coordinates directly to FBSimulatorHIDEvent without landscape rotation or letterbox correction, causing interactions to land in the wrong location in rotated landscape simulators and portrait-hardware landscape-only apps. AXe now detects the simulator UI orientation automatically instead of requiring callers to pass landscape flags ([#5](https://github.com/cameroncooke/AXe/issues/5) by [@Nitewriter](https://github.com/Nitewriter))
- Fixed selector-based `tap` and batch tap steps so UIKit `UISwitch` and SwiftUI `Toggle` controls can be activated reliably, including when a matched row or label contains a single switch/toggle control. Added `--tap-style` so switch/toggle taps can use physical touch automatically while normal taps keep the simulator `tapAt` path by default ([#46](https://github.com/cameroncooke/AXe/pull/46)).
- Fixed element comparison in `AccessibilityTargetResolver` to prevent distinct elements with the same type and frame but lacking labels/values from being incorrectly identified as identical during ancestor tree traversal.

## [v1.6.0] - 2026-04-05

### Added

- Added `--value` targeting for `tap`, allowing elements to be matched by their accessibility value in addition to `--id` and `--label`. Added `--element-type` filtering to narrow matches by element type (e.g., button, text field) ([#40](https://github.com/cameroncooke/AXe/pull/40) by [@andresdefi](https://github.com/andresdefi)).
- Added `--wait-timeout` and `--poll-interval` options to `tap` for waiting until a matching element appears before tapping ([#40](https://github.com/cameroncooke/AXe/pull/40) by [@andresdefi](https://github.com/andresdefi)).

### Fixed

- Fixed `describe-ui` to expose and implement the documented `--point` option in command help and runtime behavior ([#38](https://github.com/cameroncooke/AXe/issues/38))

## [v1.5.0] - 2026-03-04

### Added

- Added `batch` command for executing ordered multi-step interaction workflows in a single invocation, with sequential execution that supports multi-screen flows, built-in `sleep` delays, accessibility caching, and configurable text submission strategies ([#25](https://github.com/cameroncooke/AXe/pull/25)). See [BATCHING.md](BATCHING.md).
- Added `axe init` command to install, uninstall, or print the AXe skill for AI clients (`claude`, `agents`) or a custom destination ([#25](https://github.com/cameroncooke/AXe/pull/25)).

### Fixed

- Fixed Homebrew installation on Intel Macs by producing architecture-specific release artifacts ([#27](https://github.com/cameroncooke/AXe/pull/27), [#21](https://github.com/cameroncooke/AXe/issues/21))
- Fixed `tap --label` resolving ambiguous matches by preferring actionable elements over read-only ones ([#28](https://github.com/cameroncooke/AXe/pull/28))

## [v1.4.0] - 2026-02-08

### Added

- AxePlayground Touch Control now shows long-press count and last long-press coordinates, making gesture automation easier to validate.

### Fixed

- Improved long-press reliability for `axe touch`: `--down --up --delay` now consistently behaves like a real press-and-hold gesture.

## [v1.3.0] - 2026-01-28

- Add `key-combo` command for atomic modifier+key presses (e.g., Cmd+A, Cmd+Shift+Z) Thanks to @jpsim for the contribution!

## [v1.2.0] - 2025-12-19

-Add support for screenshot capture to PNG
-Add tap by label or accessibility id in addition to existing x/y coordinates
-Fix FBProcess duplication warnings

Special thanks to @aliceisjustplaying and @onevcat for their execellent contributions!

## [v1.1.1] - 2025-09-22

-Pin IDB version to address access control issues on new versions


## [v1.1.0] - 2025-09-21

- Add support for streaming and video capture (thanks to @pepicrft for the contribution!)


## [v1.0.0] - 2025-06-01

- Initial release of AXe
- Complete CLI tool for iOS Simulator automation
- Support for tap, swipe, type, key, touch, button, and gesture commands
- Built on Meta's idb frameworks with Swift async/await
- Comprehensive test suite with AxePlaygroundApp
- Gesture presets and timing controls
- Accessibility API integration

## [v0.1.1] - 2025-09-21
- README updates

## [v0.1.0] - 2025-05-27

- Initial release of AXe
