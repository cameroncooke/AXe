<img src="banner.png" alt="AXe" width="600"/>

AXe is a comprehensive CLI tool for interacting with iOS Simulators using Apple's HID (Human Interface Device) functionality.

[![CI](https://github.com/cameroncooke/AXe/actions/workflows/release.yml/badge.svg)](https://github.com/cameroncooke/AXe/actions/workflows/release.yml)
[![Licence: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Install

```bash
brew tap cameroncooke/axe
brew install axe
```

Or install in one command:

```bash
brew install cameroncooke/axe/axe
```

Verify the CLI:

```bash
axe --help
axe list-simulators
```

## Install the AI skill

`axe init` installs the skill bundled with your AXe binary for the AI clients it detects. To keep the skill updated as releases ship, install it from this repository's marketplace instead.

Claude Code:

```bash
claude plugin marketplace add cameroncooke/AXe
claude plugin install axe@axe
```

Codex:

```bash
codex plugin marketplace add cameroncooke/AXe
codex plugin add axe@axe
```

The marketplace serves the skill for the latest release, so keep the AXe CLI on the latest release too. It reads the case-sensitive `Skills/CLI` path; clients that require a lowercase `skills/` directory are unsupported.

## Xcode compatibility

AXe supports Xcode 26 and Xcode 27. Xcode 27 simulator automation uses Device Hub; Simulator.app is not required.

Release artifacts are built once with the Xcode version selected by the release environment and run unchanged with either supported Xcode selected. Compatibility was validated with Xcode 26.5 (build `17F42`) and iOS 26.5 (`23F77`), and with Xcode 27 Beta 3 (build `27A5218g`) and iOS 27 (`24A5380g`).

AXe keeps its own copy of the two IDB frameworks it uses, `FBControlCore` and `FBSimulatorControl`, in [Packages/IDBKit](Packages/IDBKit/README.md). Edit those sources directly; there is no IDB checkout or patch. `scripts/build.sh` generates their Xcode project with XcodeGen and builds the XCFrameworks AXe links. The default `AXE_BUILD_ARCHS="arm64 x86_64"` builds a universal CLI and IDB frameworks. Set `AXE_BUILD_ARCHS=arm64` or `AXE_BUILD_ARCHS=x86_64` for one architecture. Build checks require the requested slices.

## E2E development

`make build`, `make test` and `make e2e` rebuild the IDBKit XCFrameworks first when `Packages/IDBKit`, the selected Xcode or the requested architectures changed since their last build; otherwise they reuse them. `make e2e` then builds AXe and runs the whole Playground suite with the Xcode selected by `DEVELOPER_DIR` or `xcode-select` on dedicated iPhone 18 Pro, iPad Air 11-inch (M4) and iPhone Duo simulators, creating any that are missing; the Duo reboots before each of its groups. The Playground app needs the iOS 27.1 SDK or later (Xcode 27.1+) for its Duo hinge view, and a failed Playground build prints its errors. XcodeGen is required to generate the IDBKit project. Without an iPhone Duo simulator it runs the iPhone and iPad groups and exits 2. See [Playground testing](docs/playground-testing.md) for the simulator overrides and for rerunning single groups.

For repeated local Playground checks, reuse the requested warm simulator. Do not create a fresh simulator for each check. A warm-session pass does not prove cold-start readiness.

To validate a release payload unchanged under another supported Xcode, first build the test bundle with that Xcode, then run `AXE_BIN_PATH=/path/to/release/axe ./test-runner.sh --tests-only`. The supplied executable must retain its packaged frameworks beside it.

For local Duo work on Apple silicon, use `AXE_BUILD_ARCHS=arm64`. Selected input reads the display state in-process; no simulator helper binary is built or required.

For release signing, `scripts/build.sh sign-executable` signs and strictly verifies the copied `AXe_AXe.bundle` before signing `axe`. The bundle uses the configured signing identity and timestamp, without executable entitlements; the CLI signing options stay unchanged.

## Benchmarks

The complete benchmark application is in [benchmarks/](benchmarks/README.md):
runner, grading logic, task rules, tool adapters, bundled model runner, Weather
app, baseline selection and versioned result history. It compares AXe with its
best passing baseline and with FlowDeck and RocketSim on the original Weather,
Contacts and Reminders tasks. Each result records tool versions and hashes,
task checks, calls, elapsed time, returned text tokens and images.

Run from this repository:

```sh
./benchmarks/run setup
# Set Xcode, a warm simulator and the FlowDeck/RocketSim paths in benchmarks/config.local.json.
# Each run builds and measures the current AXe source.
./benchmarks/run doctor
./benchmarks/run
./benchmarks/run history
```

For a smaller run or the benchmark application's checks:

```sh
./benchmarks/run --tools axe --scenarios weather
./benchmarks/run test
```

Reports are retained under [benchmarks/history/](benchmarks/history/).
[benchmarks/baselines.json](benchmarks/baselines.json) keeps accepted AXe baselines;
acceptance is explicit. Failed or unverified runs cannot replace a baseline.
Code, task definitions, grading rules and report history belong in Git. Local
settings, dependencies and large raw artifacts are ignored. The suite does not
replace the installed AXe CLI or require a separate XcodeBuildMCP checkout.

See [benchmark setup and commands](benchmarks/README.md) for configuration,
comparison, acceptance and measurement rules.

## Basic usage

```bash
# Find a booted simulator UDID
axe list-simulators
export UDID=<UDID>

# Inspect the current UI
axe describe-ui --udid "$UDID"

# Interact with the simulator
axe tap --label "Continue" --udid "$UDID"
axe type 'Hello world' --udid "$UDID"
axe screenshot --output ./screen.png --udid "$UDID"
```

## Output format

Without `--output`, existing commands keep their output. `--agent` returns one agent JSON result by default. Select compact RS/1 text or JSON explicitly with the root option:

```bash
axe --output text describe-ui --agent --udid "$SIM_UUID"
axe --output json describe-ui --agent --udid "$SIM_UUID"
axe --output json list-simulators
axe --output json screenshot --udid "$SIM_UUID" --output screen.png
```

Set `SIM_UUID` to one simulator UDID from `axe list-simulators`. Agent calls require `--udid`; an empty or missing value is an error. AXe does not choose a device.

Agent JSON uses the `axe.output.agent-result` envelope. Default reading and optional navigation views use public adaptive schema version `"2"`; `--view full` returns canonical base schema version `"1"`. Ordinary commands with `--output json` use `axe.output.command-result`, schema version `"1"`, with `command`, `didError`, `data` and `nextSteps`. `data.result` holds one typed result, `data.results` holds multiple results, and optional `data.messages` holds text. A failure adds `error.code` and `error.message`, writes one JSON result to stdout and exits nonzero without a second plain error. Inspect action receipts before any repeat; formatting does not replay input. Parse stdout for JSON. Diagnostic messages can remain on stderr; do not merge the streams when parsing.

Put the format before the command. Leaf placement also works where unambiguous, such as `axe describe-ui --output json ...`. After `screenshot` or `record-video`, `--output` still means a destination path. `stream-video` rejects an explicit output format before capture; its normal binary stream is unchanged. Existing command-specific `--json` flags keep their meanings.

## Simulator shutdown

Use `axe shutdown --udid <UUID>` to shut down exactly one simulator through the public `simctl` command. Names and the `booted` and `all` aliases are rejected. This command is simulator lifecycle control, not a guest lock or power-button action. It does not select a display or accept agent/batch options.

Success prints JSON with `source: "simctl"`, `udid`, `initialState`, `finalState: "Shutdown"` and `outcome`. `shutdownCompleted` requires a fresh state read after the one shutdown request. `alreadyShutdown` means the initial read found that state, with no shutdown request. The command has a shared 60-second budget for child commands and state observation. A failure or interruption does not undo a shutdown that has started; inspect the simulator state before another request. Success records the observed state, not a guarantee against a later boot by another client.

```bash
axe shutdown --udid "$UDID"
```

## Clipboard copy

Use `axe clipboard copy --stdin --udid <UUID>` to stage 1...65536 valid UTF-8 bytes in one booted simulator clipboard. Stdin ends at EOF and preserves every byte, including line endings and combining characters. Names, `booted` and `all` aliases reject; AXe does not boot the device.

```bash
printf '%s' 'AXe sample' | axe clipboard copy --stdin --udid "$UDID"
```

The command sends one public CoreDevice copy, then one exact readback, with no retry or fallback. Success prints only a JSON receipt: `source: "appleCoreDevicePasteboard"`, `operation: "copy"`, `outcome: "stagedAndVerified"`, `simulatorUDID`, `utf8Length`, `sha256`, `verified: true`, `inserted: false`, `clipboardReplaced: true` and `sharedClipboardMayChange: true`. It does not insert text or change the existing US HID `type` command. No agent, selected-screen or batch options apply.

This replaces the general clipboard and can affect the Mac or other devices through sharing. AXe does not save prior content or restore it. Raw child streams and unexpected readback stay private. A failed or interrupted copy can already have changed the clipboard; preserve the result and do not replay automatically. Readback is an observation, not an atomic clipboard or recipient guarantee. Each child has a 30-second bound; CoreDevice copy/readback use `--timeout 8`. Stdin waits for EOF without a deadline and observes cancellation. SIGINT/SIGTERM cancel and await owned child cleanup; SIGKILL cleanup is not guaranteed.

Get a fresh UI capture before separate app actions and verify the actual destination. AXe does not add automatic Paste or general app/menu support; do not use Cmd+V as a fallback. [Full clipboard contract](Skills/CLI/axe/references/clipboard-reference.md).

## Agent mode (experimental)

Add `--agent` to `describe-ui`, `tap`, `type`, `swipe`, `drag`, `key`, `key-combo`, `key-sequence`, `slider`, `gesture double-tap`, `gesture pinch` or complete reference `touch` for provider-free stateful control. Commands without the flag retain raw accessibility output and logical coordinate semantics. This mode is separate from `axe agent <goal>` and does not need a model or API key.

```bash
axe describe-ui --agent --udid "$UDID"
# Use the returned snapshot ID and element ref.
axe tap --agent --udid "$UDID" \
  --snapshot-id "$SNAPSHOT_ID" --ref "$REF"
axe type 'Hello' --agent --udid "$UDID" \
  --snapshot-id "$SNAPSHOT_ID" --ref "$FOCUSED_FIELD_REF"
axe swipe --agent --udid "$UDID" \
  --snapshot-id "$SNAPSHOT_ID" --ref "$SCROLL_REF" --direction up --distance 0.5
axe drag --agent --udid "$UDID" \
  --snapshot-id "$SNAPSHOT_ID" --ref "$REF" --end-x "$END_X" --end-y "$END_Y"
```

Capture discovers the measured active display unless an explicit selected pair is supplied. Without `--expected-pid`, it discovers the frontmost app or SpringBoard on Home from the same native observation. References and snapshot validation use the PID saved at capture. Optional `--expected-pid <PID>` is a positive assertion and must match; zero and negative values reject. No raw hierarchy read or PID lookup is required first. After Home or opening another app, take a new agent capture. Old references still refuse app, layout or focus changes.

Native-object references require matched CLI, broker and runtime versions.

Each CLI call connects to the same per-device broker for the current user, Xcode directory and protocol version. Its reference table stays in RAM across calls; it is not saved to disk. Reuse the returned snapshot ID and ref until replacement or expiry. New captures, input, app/display/layout changes and broker restart can invalidate them. No caller PID lookup is needed; optional `--expected-pid` is only an assertion. See the [agent reference](Skills/CLI/axe/references/agent-reference.md).

Numeric keyboard evidence is heuristic. It requires complete native identity metadata, one focused editable field, a verified OS keyplane, all ten digits and Delete. Docked occlusion uses the measured native keyboard ancestor, not fixed coordinates. Full keyboard signals include optional `numericKeyCount` only when that evidence is verified; alphabetic output keeps its current shape. This evidence clips planning bounds and grants no input authority.

The default `--view reading` returns compact `ref|actions|role|label|value` rows, snapshot identity, selected-screen geometry, keyboard evidence, cache status and action receipts. Multiple actions on one row are comma-separated. It omits only native-proven redundant Button child labels; full labels, values, IDs and selectors remain in the broker. `--view navigation` omits static-text rows but keeps control, slider, scroll and gesture references. `--view full` returns canonical schema 1, including the original six-column rows and full device evidence. Ordinary commands without `--agent` keep raw output.

```bash
axe describe-ui --agent --view navigation --udid "$UDID"
axe describe-ui --agent --view full --udid "$UDID"
# Use page.nextOffset from a compact capture, with its same snapshot.
axe describe-ui --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" \
  --row-offset "$NEXT_OFFSET" --row-limit 64
# Read the exact native ID, or a bounded chunk of a label/value, without input.
axe describe-ui --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" \
  --read-ref "$REF" --text-field id
axe describe-ui --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" \
  --read-ref "$REF" --text-field label --text-offset 0 --text-limit 1024
```

Displayed labels and values keep their exact whitespace, including leading, trailing and repeated spaces. JSON escapes line breaks and tabs without changing their content. The existing row convention displays a literal pipe (`|`) as a slash (`/`); use `--read-ref --text-field label|value` for the exact original field, including delimiters. Search and selector normalization are separate from display text. Whitespace-only display changes change the screen hash and invalidate old references.

Compact cells display at most 160 Unicode scalars. A clipped cell contains 159 scalars followed by an ellipsis, and `truncatedFields` identifies its reference and field. `truncatedFields.displayScalarLength` counts scalars in the complete display cell; `data.detail.totalLength` counts the exact native field and can differ when a row uses the pipe display convention. Read-ref returns exact raw text in `data.detail`, with `totalLength` and an explicit `nextOffset` when more remains. Its offsets count Unicode scalars, not UTF-8 bytes or displayed characters. Limits are 1...4096 scalars per chunk (default 1024). Use `label` (default), `value` or `id` as `--text-field`. Reading requires the same valid snapshot and a fresh native app/display/tree check; it does not renew expiry or authorize input. Hash polling, row paging and action targets cannot be mixed with read-ref. Full view can return large text; prefer chunks for one complete field.

`--since-screen-hash <hash>` still reads the current UI before reporting it unchanged. Compact unchanged replies keep the snapshot ID, sequence, rounded-down expiry and `unchanged: true`; retain the hash from the matching capture. Reuse of an unchanged snapshot checks the exact native read as well as normalized screen data. Input admission compares what can affect the action: visible labels, values, frames and controls, plus the exact target. Hidden nodes, nodes wholly off the display and empty inert groups do not refuse input. No view changes references, native selectors, stale-input checks or the 60-second expiry. Successful actions return the replacement capture in the selected view, read once, straight after the action. Use a matched CLI, broker and native framework; output format does not extend reference authority. See the [agent output reference](Skills/CLI/axe/references/agent-reference.md#output-format).

Full agent captures include `keyboard` evidence from the selected app's existing accessibility read. Compact changed/replacement captures return its state string; compact unchanged replies omit repeated screen and keyboard fields. `state: "likelyVisible"` means visible Button IDs or labels match keyboard-key signals; `"unknown"` means no supported evidence was found, not that the keyboard is hidden. `source: "accessibility-key-signals"`, `scope: "selected-application"` and the four `signals` fields (`idChromeCount`, `globeSeen`, `letterKeyCount`, `chromeKeyCount`) show the basis. Counts use distinct matching IDs, labels and Latin letters. This heuristic adds no native query, does not prove keyboard focus and does not change typing checks.

References belong to one immutable snapshot and expire with the broker cache. Reference and coordinate actions require `--snapshot-id`; a ref alone is not a stable identifier. The runtime reads current context and accessibility data before input. A changed boot, app, display, hinge, rotation or geometry invalidates old state. A changed screen refuses input before anything is sent; the reply carries the current screen as a new capture, and when the chosen target is unchanged on it the action completes there within the same call; an ID, label or value action resolves on that fresh read and runs again (`action.retried: true`, at most five times while the screen keeps changing). A reference batch stopped before one of its steps sent input carries the current screen the same way. Choose the next ref from the newest capture; AXe never reuses old coordinates. After an action, use its replacement capture or read a new snapshot. Cache loss and uncertain input require a fresh observation; delivered input is never replayed automatically, and a failure that reports delivered events (`failedNoReplay`) must not be resubmitted.

After a failed AX acquisition, an optional `--agent` result can include `data.observation`: `expectedPID`, optional `observedPID`, `outcome` and at most eight scalar `attempts` (`index`, `startUptime`, `endUptime`, `rootPID`, `outcome`). It reuses the existing read without copying AX roots or adding a query. If `processChanged` names a different PID, confirm the visible owner, then take a new capture with `describe-ui --agent --udid "$UDID"`. Supply `--expected-pid "$OBSERVED_PID"` only when you need to assert that owner. AXe does not retarget an existing reference or replay its action. The evidence can also follow a completed action whose refresh failed; inspect its action receipt and do not replay completed input. Existing flags and input rules are unchanged.

Agent `drag` starts at the fresh native centre of an existing `targets` or `scroll` reference. Supply `--snapshot-id`, `--ref`, `--end-x` and `--end-y`; endpoints use decimal logical points, not screen fractions. The endpoint can leave the target frame but must stay inside the current selected display. Native point and tree reads must prove the start belongs to that target; choose the innermost scroll area when needed. Defaults remain 0.6-second movement, 60 steps and 0.05-second holds at each end. Duration is finite in (0,10], steps are 1...1000, each pre/post delay is 0...10 and total requested delay including holds is at most 20 seconds. Start coordinates, explicit selectors and batch steps are rejected. This does not expose new pad or slider references, or prove which control receives the endpoint. Stale or uncertain actions are never replayed. Use a matched CLI and broker; an older broker cannot decode the new drag action kind.

Agent `touch` presses and holds a current element reference with `--down --up`: `axe touch --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref e4 --down --up --delay 0.7`. Omit `--delay` for a 0.1-second press; an explicit delay must be finite and in (0,10] seconds. The current native target and point hit are checked before physical input. Existing context-change detection, owned release, cache invalidation and no-replay rules remain. Coordinates, partial down/up, retained tokens and batch use reject. No new pad or slider references are exposed. A requested hold duration does not prove the app's long-press effect.

Agent `key` sends one default key down/up to a current focused TextField reference. For Backspace, use `axe key 42 --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref "$FOCUSED_FIELD_REF"`. Keycodes remain 0...255 HID codes. The referenced field must already be focused, enabled and visible, with a currently advertised `typeText` action. Snapshot, target, PID, display and per-key focus checks use the existing keyboard owner. Key-up cleanup can release after focus loss. Explicit `--duration`, `--focus-id` and batch use reject; this adds no retained keys, combinations or implicit focus. Raw and selected key routes remain unchanged. Use the replacement capture or refresh after the action; never replay uncertain input. Older brokers reject the new keyPress kind. Focus checks and HID delivery are not atomic recipient control.

Agent `key-combo` sends one complete modifier shortcut to a current focused TextField reference: `axe key-combo --modifiers 225 --key 4 --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref "$FOCUSED_FIELD_REF"` requests Shift+A. Use 1...8 distinct HID modifier codes in 224...231 and a different target key in 0...255. Modifiers go down in the given order and up in reverse order. The same snapshot, field, PID, context and per-key focus checks apply; owned cleanup releases keys after interruption. No focus-ID override, timing override, retained key or agent batch is supported. Raw and selected combinations are unchanged. Use the replacement capture or refresh; do not replay uncertain input. The new keyCombo request kind preserves the single-key contract and rejects on older brokers.

Agent `key-sequence` sends complete key presses to one current focused TextField reference. For two Backspaces, use `axe key-sequence --keycodes 42,42 --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref "$FOCUSED_FIELD_REF"`. Supply 1...100 HID codes in 0...255. Each key is released before the next; `--delay` is finite in 0...5 seconds (default 0.1), with at most 20 seconds of total requested delay. The existing snapshot, PID, field, context and per-key focus checks apply. No implicit focus, retained keys, focus-ID override or agent batch is supported. Raw and selected sequences are unchanged. Use the replacement capture or refresh after input, and never replay uncertain input.

Agent `gesture double-tap` uses a current tap-capable reference: `axe gesture double-tap --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref "$REF"`. AXe resolves its fresh native activation point and checks the target and point hit before input. Defaults are `--hold 0.06` and `--interval 0.1`; both must be finite and in (0,10] seconds. Each pre/post delay is 0...10 seconds, with at most 20 seconds total including both holds and the interval. Coordinates, other gesture geometry, dimension overrides, duration/delta and agent batch use reject. Context checks and owned release apply through the two taps, but the app can change between them; this does not guarantee one unchanged recipient or recognition. Refresh after input and verify the app effect. Raw presets and selected coordinate gestures are unchanged. Use a matched CLI and broker.

Agent `slider` moves a current `sliderEndpoint` reference to its native minimum or maximum: `axe slider --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref "$SLIDER_REF" --endpoint minimum`. Only visible, enabled Sliders with a unique native ID or label receive this row. The row does not prove that the native domain or adjustment action is available; the request checks both. Snapshot/PID/context, initial screen, target identity, label, frame, value and readiness checks precede adjustment. Each fresh full tree rechecks the slider identity and inherited visibility. Every adjustment rechecks the owned native handle and its current domain/value; only this operation's returned adjustments permit the original value to change. Existing limits remain 20 actions within 15 seconds, with endpoint reads at 0.6 and 5 seconds. `action.slider` records semantic action counts, delivery, endpoint and bounded numeric samples: zero HID events does not mean zero adjustments. Verify the app callback separately. Selectors, type overrides, non-default polling and agent batch use reject. Standalone `--value` also uses this row; see [selected slider percentages](Skills/CLI/axe/references/slider-reference.md). No-flag percentages use the routes described below; selected selector endpoints keep their behavior. The new row does not enable slider tap/drag references. Use the replacement capture or refresh; uncertain actions are never replayed. Older brokers reject this request; use matching rebuilt native frameworks.

Agent `gesture pinch` uses one current area reference, `--radius` and `--scale`; its centre comes from the fresh area frame. Both starting-point hits must belong to that area and pass fresh checks before either touch starts. Existing target and scroll actions remain available; eligible areas absent from targets gain `pinchWithin` rows. Paths stay inside the area and current display. The shared eight-second admission budget and existing motion/context/release limits apply. There is no app-PID monitor during motion or atomic recipient guarantee. Coordinates, other gesture payloads, retained input and agent batches reject. Raw presets and selected coordinate pinch are unchanged. Read the [pinch contract](Skills/CLI/axe/references/agent-reference.md#pinch-inside-an-area-by-its-agent-reference) for syntax, bounds and failure handling.

Typing keeps the existing US keyboard mapping and 256-byte limit. Default agent typing requires an already focused field. Use `axe type 'Hello' --agent --focus --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref "$FIELD_REF"` to make one guarded physical focus tap and type in one call. Whole text is validated before focus. The same field is read again after keyboard layout changes, then existing per-key focus/owner/context checks apply. Inspect both phase receipts; partial input is not rolled back or replayed. `--focus-id`, raw typing and reference batches keep their current behavior. [Exact focus-and-type contract](Skills/CLI/axe/references/agent-reference.md#focus-a-field-and-type-in-one-command). Ref swipes use bounded current element geometry; `up` moves the finger up. Agent ref and coordinate swipes slow to rest before lift-off, so the content moves about the requested distance without a fling and the reply carries the settled screen; raw swipes keep their linear release. Coordinate tap/swipe forms remain available with an agent snapshot, but do not prove an AX recipient. Other commands keep their existing interfaces and do not yet accept `--agent`. The existing native input and touch-release checks remain authoritative.

Keep agent captures within 4096 nodes and depth 64. `--row-limit` now bounds one global page of at most 64 source rows across targets, scrolling and text; `--row-offset` is in 0...12288. Follow compact `capture.page.nextOffset` or canonical `capture.nextRowOffset` with the same snapshot. Compact row merging, text filtering and the byte budget can return fewer rows, so do not derive the cursor from their count. Stop paging when the cursor is absent. Terminal compact pages omit native totals and initial offset zero; an explicitly requested nonzero offset remains. Page-fill diagnostics and refresh warnings remain; full view keeps the base fields. Agent typing and key input limit each focused-field read to 512 nodes, depth 32, 1 MiB of field output and eight seconds. One global deadline allows eight seconds for input work plus validated requested delays of at most 20 seconds (28 seconds at most); it does not reset for each key. For nested scrolling, select the innermost scroll area that receives the gesture. Compact first pages can show up to four cached scroll refs in `capture.areas` when their canonical scroll rows are on a later page. This is a preview, not a complete list or a replacement cursor; follow `page.nextOffset` for all rows. It adds no accessibility read. Use a matched CLI and broker.

Use only actions advertised by the current reference. Eligible native controls without a unique ID or label can use broker-owned native object identity when a complete native read proves it unique. The native tree and object UID remain internal; `read-ref --text-field id` still returns only the app's real accessibility ID and can be empty. Typing still requires an already focused, enabled, visible native `TextField` with `typeText`. Opaque identity does not add slider, AXPress or pinch support, and a Group alone does not prove a scroll area.

Agent `tap` also accepts `--label-contains <text>` for a case-sensitive literal substring or `--label-regex <pattern>` for Foundation `NSRegularExpression` syntax. Regex searches the native label; use `^` and `$` to anchor it. Groups and alternation such as `^(Save|Done)$` are supported. Matching is case-sensitive by default; Foundation inline options apply. Use exactly one of `--id`, `--label`, `--value`, `--label-contains`, `--label-regex`, `--ref` or a coordinate pair. An explicit selector can use the exact `--element-type` filter.

Use one optional `--frame 'minX=12.5,maxY=500.25'` with any explicit selector. Keys are `minX`, `maxX`, `minY` and `maxY`; values are finite non-negative logical UI points, including decimals. Omitted edges use the current screen bounds. The complete native element frame must fit the resulting positive rectangle within the current screen. Relative screen fractions, repeated keys, refs and coordinate targets are rejected. These three new options require `--agent` and apply only to `tap`.

```bash
axe tap --agent --udid "$UDID" \
  --label-contains 'Save' --element-type Button --frame 'minY=100.5,maxY=500.25'
axe tap --agent --udid "$UDID" \
  --label-regex '^(Save|Done)$' --element-type Button
```

The new queries allow 512 UTF-8 bytes, with regex patterns limited to 128 bytes and frame specifications to 256 bytes. Each candidate ID/label/value is limited to 4096 bytes; total candidate text is limited to 256 KiB under the existing 4096-node tree limit. Selection shares a 100 ms budget, with cooperative Foundation progress cancellation for regex matching. Pattern compilation has a byte cap and invalid-pattern rejection; Foundation does not expose compilation cancellation. A bound failure, no match or more than one match sends no input. Narrow the query instead of retrying unchanged. AXe resolves the fresh native tree, requires a unique exact native ID or label, then repeats the existing context, native-screen and target checks before input. A geometric match never authorizes cached-coordinate input. An older broker rejects a new selector payload instead of ignoring its filters.

### Phase timing (diagnostic)

Set `AXE_TIMING=1` to print a phase table to standard error after each agent command. It lists client connect and exchange time, then the broker's display discovery, accessibility reads, snapshot builds, input and post-action refresh, with start offsets and durations in milliseconds. Set `AXE_TIMING=/absolute/path.jsonl` to append one `axe.timing` JSON record per command instead. Standard output is unchanged in both modes. The broker records phases only for requests that ask for them. A broker started by an older build returns no phases; the table says so. Timing is dropped before it could make a response exceed its size bound.

```bash
AXE_TIMING=1 axe tap --agent --udid "$UDID" --snapshot-id "$SNAPSHOT_ID" --ref "$REF"
AXE_TIMING=/tmp/axe-timing.jsonl axe describe-ui --agent --udid "$UDID"
```

## Agent batches

Use `axe batch --agent --udid "$UDID" --file steps.json` for 1...8 ordered tap/type steps addressed by exact native IDs. The JSON form is `{"steps":[{"action":"tap","id":"field"},{"action":"type","id":"field","text":"AB"}]}`. Without a PID assertion, the batch discovers its initial owner once and keeps it for all steps. AXe resolves each ID again, requires the field to be focused before typing, and stops after failed input/refresh or changed app/device context. Add `"focus": true` to a type step, by ID or by ref, to make the guarded focus tap of `type --focus` first, so one batch can fill a form: `{"snapshotID":"<UUID>","steps":[{"action":"type","ref":"e7","text":"Ada","focus":true},{"action":"type","ref":"e9","text":"Lovelace","focus":true}]}`. In a reference batch, a completed focus step is a declared layout change: later targets must be the same controls with only their positions changed, and the new screen becomes the layout later steps must keep. Earlier effects remain; there is no rollback or replay. One agent-result contains compact step receipts and the final usable capture. Raw and selected batches remain unchanged. Read the [batch contract](Skills/CLI/axe/references/agent-reference.md#run-a-small-ordered-agent-batch) for bounds, ownership and failure handling.

## Selected Duo input

Ordinary `tap`, `touch`, `swipe` and `drag` without mode flags use the measured active display on the iPhone Duo. Coordinates remain logical UI points. Tap keeps legacy selector matching, styles and wait/poll options. Swipe and drag keep their existing event factories, movement duration, swipe delta and drag steps/holds. Their pre/post delays run on the host; normal text output remains. AXe checks boot, panel, hinge, orientation and geometry before input. These pose checks do not add an app/PID or UI-layout guard. Duo paths above 100,000 movement steps reject before event allocation; `drag --steps` retains its existing 1...1,000 limit. Ordinary `tap`, `swipe`, `drag`, gesture presets and complete `touch --down --up` on other devices that use the DTUHID transport take the same broker route, so repeated input reuses one connection instead of opening and draining a new one per command. Their presets keep the 390×844 default dimensions, and a partial `touch --down` or `--up` keeps its existing route. Ordinary Duo typing and [batches](#ordinary-duo-batches) use owned input as described below.

Ordinary Duo `touch -x <X> -y <Y> --down` starts one contact if none is held; another `--down` moves that contact. `--up` ends it at the point supplied to that command, without adding a move first. `--down --up` keeps the default 0.1-second hold; `--delay 0...10` sets that hold, and zero adds no delay. The broker keeps a successful down after the command exits and releases it after 60 seconds without an accepted touch request. Folding, rotation or context loss invalidates the stream and releases its input on the original connection. An up with no owned contact sends zero HID events; its internal outcome is `noOwnedContact`. It cannot release selected-token input. Read the UI again before a new contact after a change; do not replay uncertain input. Explicit selected retained touch still requires its receipt token and keeps its existing end-at-last-held-point behavior and 30-second idle limit. Standalone touch state does not transfer to a batch.

AXe supports explicit display selection on `describe-ui`, `tap`, `slider`, `touch`, `swipe`, `drag`, `gesture`, `type`, `key`, `key-sequence`, `key-combo` and `button home|side-button|siri|lock|apple-pay`. Pass `--input-mode selected --screen-id <ID> --screen-uuid <UUID>`. Use the display ID and UUID from a fresh device display read; do not assume that the primary display is active. Selected AX operations also require the current frontmost app PID through `--expected-pid`. No selected failure falls back to legacy input.

Selected AX reads and physical target checks use the normal IDB accessibility-readiness check. There is no new preparation option or retained preparation layer. Reads go to the device directly; the short-lived bootstrap for simulator runtimes 27 and later runs only after a direct read returns an empty tree or a point read fails, and the same checks then repeat within the original deadline. Plain `describe-ui`, including `--point`, follows the same rule; its output is unchanged. On runtimes 27 and later, plain accessibility reads (`describe-ui`, selector taps, batches and `slider`) first wait, for up to 60 seconds after a boot, until the simulator reports a lit built-in display: a read made earlier can stop the simulator's accessibility working until it is rebooted. Native slider and semantic-switch operations keep their separate identity sessions; physical touch input remains HID. Use a matching CLI, broker and rebuilt native frameworks; older requests reject.

```bash
axe describe-ui --udid "$UDID" --input-mode selected \
  --screen-id "$SCREEN_ID" --screen-uuid "$SCREEN_UUID" --expected-pid "$APP_PID"
axe list-simulators --displays --udid "$UDID"
axe tap --id <identifier> --udid "$UDID" --input-mode selected \
  --screen-id "$SCREEN_ID" --screen-uuid "$SCREEN_UUID" --expected-pid "$APP_PID"
axe hinge read --udid "$UDID"
axe hinge set 90 --udid "$UDID" --expected-boot <boot-identity-from-read>
```

`hinge set` also accepts the exact names `closed` (0 degrees), `tabletop` (90 degrees) and `open` (180 degrees). For example, use `axe hinge set tabletop --udid "$UDID" --expected-boot <boot-identity-from-read>`. Names are case-sensitive. Numeric angles from 0 through 180, including fractions, remain supported. Each name uses the same native request and measured mechanical completion as its numeric angle, with the same options and JSON output. A name does not select a screen or request readiness observation. Use both `--wait-for-screen-id` and `--wait-for-screen-uuid` for separate active-screen readiness observation, then read the UI before input.

Use `axe rotate left|right --udid <UDID> --screen-id <ID> --screen-uuid <UUID> --expected-boot <BOOT_ID>` to turn the Duo. Read the boot and active screen pair first. This device-wide action uses the common input lock and rejects held touches. It sends one request, observes two matching selected-screen positions, and checks that the position remains after the connection closes. `--timeout` sets the observation budget (0.5...15 seconds, default 8); native reads have separate bounds. The Duo supports all four inner positions and skips upside-down portrait on the outer screen. Read the UI again before input. App layout readiness is not guaranteed. Do not replay a failed or uncertain request. An uncertain send holds the input lock and saves a recovery record. This command is separate from the two-finger `gesture rotate` and is not a batch step.

Selected gestures include `pinch`, `double-tap`, `rotate`, `two-finger-tap`, `two-finger-hold` and standalone `two-finger-swipe`. Read `axe gesture --help` for their explicit geometry and timing. Input uses the selected screen's current logical coordinates. A fold or rotation invalidates old context; read the UI again before the next action. Hinge mechanical completion alone does not prove that the destination screen is ready.

For `two-finger-swipe`, give first start `-x/-y`, second start `--x2/--y2`, and both endpoints `--end-x/--end-y/--end-x2/--end-y2`. Both straight paths use one `--duration` (default 0.6 seconds) and maximum `--delta` spacing (default 5 logical points); either finger may stay still. Coincident logical contact positions, including between samples, reject before input; spatial crossings at different times remain allowed. The existing selected gesture limits and cleanup apply. Batch and agent mode reject this new gesture. Read `axe gesture --help` for bounds.

The four edge presets accept `--edge-inset <points>` to change only the start distance from the named edge. The value must be finite and positive and leave an inward path. The opposite endpoint stays 20 logical points from its edge; default start inset 20, duration 0.3 seconds and delta 50 remain unchanged. For example, `swipe-from-left-edge --edge-inset 1` on a 951-point-wide display moves from x=1 to x=931. This option is available in legacy and selected commands and their batch steps; scroll and complete multi-touch gestures reject it. Selected paths use fresh display bounds. With an explicit inset, legacy input also requires the remaining path span to be at least the effective delta (50 by default); choose a smaller explicit delta for a shorter path. Selected input retains its safe single-step handling for short paths. This changes geometry only: it does not select a Back action, guarantee navigation, retry input or provide a fallback.

Selected `describe-ui --point X,Y` reads one element at oriented logical display coordinates. It requires the selected screen and current `--expected-pid`. The foreground app before and after the read, and the point result itself, must match that PID. Foreign or hosted-process results are rejected. This read sends no input and does not create a retained tap target.

Ordinary Duo `type` keeps literal, `--file` and `--stdin` loading, US key mapping and plain output. It sends the existing event sequence through one measured owned session, with startup readiness, continuous context checks, signal cancellation and owned key release. The command remains stateless and adds no PID/focus guard or selected text limit. Input can be partial on failure; never replay it. Other-device typing and optional agent behavior are unchanged.

Selected keyboard input also requires `--expected-pid <PID> --focus-id <exact-field-ID>`. The field must already be a focused, enabled, visible `TextField`; AXe does not focus it implicitly. Focus and context are checked before each key down. Key-up cleanup bypasses the focus check. Selected literal/file/stdin text is limited to 256 UTF-8 bytes using the existing US keyboard mapping. Each complete sequence is limited to 1024 events and 20 seconds of requested delay. One global deadline allows eight seconds for input work plus those validated delays (28 seconds at most). Each focused-field read is capped at eight seconds; the deadline does not reset for each key. This does not provide an atomic OS keyboard-recipient guarantee. A failure can follow partial input; do not replay it automatically.

Selected slider control requires exactly one `--id <ID>` or `--label <Label>`, plus exactly one `--endpoint minimum|maximum` or `--value <0...100>`. Interior values require a native Slider with horizontal scrubber geometry that increases from left to right, in the current measured display context. Numeric 0 and 100 select the existing semantic endpoint route before input. The physical route uses one guarded contact and bounded native value feedback, with no endpoint search or replay. RTL, custom and vertical Sliders remain unproved. [Selector rules, input bounds and receipts](Skills/CLI/axe/references/slider-reference.md). Explicit selected retained touch operations use the receipt's token through `--contact-token`; read `axe touch --help` for complete and retained forms.

On the iPhone Duo, and on other simulators for a slider with a stable accessibility ID, no-flag `slider --value` uses the current measured display, a fresh frontmost app PID and the existing owned native value-feedback route for values strictly between 0 and 100. Numeric 0 and 100 there use the semantic endpoint route, as selected mode does. It requires matching native frameworks. The original 15-second native action budget and final raw AX tolerance and stability checks remain. Stdout remains plain text. Other cases use the existing direct drag. A failed request is not replayed.

`list-simulators --displays --udid <UDID>` reports the measured integrated display catalogue, active panel, native size, scale and orientation for one booted simulator. It validates host identities and geometry against the device display read. The existing top-level fields are retained, with `bootIdentity` matched before/after discovery and `readInterval` containing `startedUptime` and `finishedUptime` in host monotonic seconds. These times bound the full discovery read; they are not frame timestamps or times to compare across machines. The result is an observation, not a lease or admission token. Selected input and capture still perform fresh checks. No new option is required, and default legacy capture is unchanged.

The selected-display path classifies a device by the built-in touch displays its device type declares, not by profile version or model. One integrated digitizer is a rigid device with no hinge request. Two require native hinge samples on every full read, so a two-panel device without a working hinge fails before input. Other sets are refused. AXe reads the active panel, rotation and geometry from the simulator's own CoreDevice display report, and still checks display identity, geometry, rotation and boot against the host catalogue.

Ordinary selected `tap --id`, `tap --label` and `tap --value` accept optional `--element-type <Type>`, for example `--element-type Button` when that type appears in a fresh description. The filter is exact and case-sensitive, with no aliases or type-name trimming; empty or whitespace-only types reject. AXe applies it before uniqueness checks and again to the final selected target before input. For a Button hit through a proved StaticText descendant, the filter applies to the Button target, not the child. The current screen pair, expected PID and hit checks still apply. Coordinates and `--semantic-press` reject this option and polling. Selected requests require a matched CLI and broker; older requests reject. Tap routes on other devices are unchanged.

Ordinary selected ID/label/value taps accept `--wait-timeout <seconds>` greater than zero through 30 and `--poll-interval <seconds>` from 0.05 through 30 (default 0.25). Without a positive wait, only the default interval is valid. AXe retries only an absent match, under the original screen, hinge, rotation, boot and input lease. Duplicate matches, a wrong PID, acquisition errors, cancellation or changed device state stop before input. A match proceeds through the existing final target validation and one tap; final validation or input failure is not retried. The receipt records attempts, elapsed time and outcome. Put polling inside a selected batch tap step, for example `--step 'tap --id ready --expected-pid <PID> --wait-timeout 5'`. Batch-level polling remains rejected. A closed client connection cancels an active wait; input already sent is not undone, and this does not add whole-batch signal handling. A wait of zero keeps the immediate path.

Ordinary selected coordinate or ID/label/value taps accept explicit `--tap-style physical`, `--tap-style simulator` or `--tap-style automatic`. Omitted style and explicit `physical` keep the existing guarded touch path. Explicit `simulator` uses the real `tapAt` down/up sequence with no inserted hold. Explicit `automatic` uses that simulator sequence for coordinates. For selectors, it uses the existing `AccessibilityElement.isSwitchLikeControl` rule on the resolved target: physical for switch/toggle-like controls, simulator otherwise. The style choice is checked again on the fresh validated target before the first down; a changed choice rejects before input. This does not add legacy descendant/sibling redirection or retry another style after failure. Selector taps retain exact ID/label/value/type, current/final target and expected PID checks; coordinates have fresh selected bounds but no PID or AX target guard. Pre/post delays, context checks, owned release and cleanup remain in effect. Put the style inside a selected batch tap step, for example `--step 'tap --id <ID> --tap-style automatic --expected-pid <PID>'`; the same builder and guards apply. Non-default batch-level styles (`physical` or `simulator`) and non-default batch-level wait/poll options remain rejected. Explicit batch-level `automatic` is accepted as the existing default but does not change selected step style; a step with no style keeps the physical 0.1-second hold. `--semantic-press` rejects every explicit style. This is not full switch support or exact legacy timing parity. Verify the app effect separately; there is no semantic/legacy fallback or automatic replay.

Selected `tap --value <text>` uses the legacy scalar text conversion for AXValue: String first, then Int, Double and Bool converted to text. Missing, null, array and object values do not match. Both the query and scalar text trim surrounding whitespace/newlines, then compare case-sensitively; query text is not parsed as a number. For example, `true` differs from `TRUE`, and query `1.0` does not equal scalar text `1`. Empty or whitespace-only queries reject. Optional exact `--element-type` filters before strict uniqueness; selected matching does not prefer an actionable duplicate. The value must still match at the current and final guarded target checks. Keep the measured pair and expected PID, and verify the app effect separately. Values cannot be combined with coordinates, another selector or `--semantic-press`; there is no fallback.

Selected selector taps remain HID taps. They do not perform semantic AXPress when a hit cannot be proved. For one exact native `CheckBox`, `tap --semantic-press --id <ID>` sends one AXPress with the selected options and `--expected-pid`. Coordinates, labels, values, delays and explicit styles reject. The inspected host AccessibilityPlatformTranslation image UUID is required. AXe has no HID or mouse fallback on this route, but the native action may produce guest touch events.

Semantic press keeps its toggle contract. Before the single action, AXe reads a strict Boolean, numeric 0/1 or exact string `"0"`/`"1"` from the current native target. After a successful native reply, it takes at most four fresh read-only samples, separated by 100 ms when unchanged, within the original eight-second transaction budget. Every sample must retain the exact native target, PID, window, display and selected context. Success is `switchValueChangedObserved`; unchanged, unsupported or unavailable values and changed context fail without another action. The optional receipt fields `stateBefore`, `stateAfter` and `readbackCount` record the values and completed samples. Native `reply` and `delivery` remain separate. Older broker replies without valid changed-state evidence fail at the caller, with their raw receipt preserved.

Observed AX value change does not prove that the action caused it or that the app emitted a callback. `guestEffectProved` remains false. Verify the real switch state and `valueChanged` effect separately. Zero AXe HID events does not mean zero guest input. Never replay a failed or uncertain semantic action. Physical switch taps and commands without this flag are unchanged.

Full keyboard, switch, media selection, batch and agent coverage remain incomplete. Commands without selected options retain their legacy route, except ordinary Duo `tap`, `touch`, `swipe`, `drag`, `type` and `batch`, and ordinary `tap`, `swipe`, `drag`, gesture presets and complete `touch` on other DTUHID devices, as described here. Selected options inside a legacy batch step still reject before legacy conversion; selected batches use batch-level selection.

## Selected Home button

Selected `button home` is available standalone or in a selected batch:

```bash
axe button home --udid "$UDID" --input-mode selected \
  --screen-id "$SCREEN_ID" --screen-uuid "$SCREEN_UUID" --expected-boot "$BOOT_ID"
```

Use the pair from a fresh active-display read. The screen pair guards the current context; Home acts on the whole device, not one display or app. Optional `--expected-boot` requires an exact match before the input connection opens. With no `--duration`, AXe sends down/up with no requested hold. An explicit duration must be finite, greater than zero and at most 10 seconds; fractional values such as `0.2` retain their meaning.

The JSON response can include `home` execution and cleanup evidence: phase, planned/sent counts, release/drain flags, interruption and any cleanup release records. It is absent when no execution evidence exists. These fields describe the owned transport; they are not an OS held-button inventory or proof that Home is visible. The final pose check is unchanged and can fail after Home has acted. Preserve the result and inspect the device separately; never replay a failed or uncertain request automatically.

Selected batches use the same Home request and guards. A selected Home step in a legacy batch rejects before legacy conversion. The legacy Home route is unchanged; the other selected device buttons are described below.

## Selected device buttons

Use `axe button <side-button|siri|lock|apple-pay> --udid <UDID> --input-mode selected --screen-id <ID> --screen-uuid <UUID>` with a fresh active-panel pair. Optional `--expected-boot <BOOT_ID>` must match exactly before the input connection opens. All buttons act on the whole device; the screen pair guards admission, not button routing to a display or app. Omitted `--duration` sends down/up with no requested hold. Explicit duration must be finite, greater than zero and at most 10 seconds, including fractions such as `0.2`.

Response `button` identifies the requested `kind` and contains available `execution` phase, planned/sent counts, release/drain flags, interruption and cleanup records. Home keeps its existing `home` response. Siri, Lock and side-button require two transport primitives. Apple Pay uses the existing native adaptation: two side-button down/up pairs, four transport primitives and a 0.15-second gap. A supplied duration is split equally between the two holds. Delays do not count as primitives. This does not prove that the payment screen opens.

These records do not prove visible Siri, lock, wake, power, security state or an OS held-button inventory. `lock` is button input, not simulator shutdown or a secure-lock guarantee. The final context check stays strict and can fail after a button acts. Preserve a failed or uncertain result; do not replay it or send another button as a fallback. Inspect the visible effect separately.

Selected batches accept the same four names, for example `--step 'button apple-pay --duration 0.2'`. Completion requires the requested kind, its exact primitive count and clean typed execution/release evidence. A failure stops later steps. Selected options in a legacy batch still reject; raw button routes and defaults are unchanged. Selected requests use a separate broker endpoint; older requests reject before admission. Device-button transport is unchanged.

## Ordinary Duo batches

AXe routes ordinary no-flag `batch` through one measured Duo display, native session and common input lease for the whole ordered run, including host waits. It preserves the existing command list, selectors, tap styles, cache/poll settings, type chunks and normal text output. Points stay logical and are transformed once. Other devices keep their existing batch route.

A changed pose/context, native failure or cancellation stops later input without replay or a replacement session. `--continue-on-error` permits pre-input step errors only while the same session remains valid; input from an earlier step stays owned. Batch completion or failure closes remaining input, including a final down. No contact transfers to a standalone command. Step `type --stdin` observes cancellation/context while waiting without an EOF deadline and keeps the existing line-join behavior. Initial batch `--stdin` still reads the step list before input ownership. SIGINT/SIGTERM cancel and await the owned operation; SIGKILL cleanup is not guaranteed.

Use matched AXe and native artifacts and verify real app effects. This route adds no app/PID, focus or UI-layout guard.

## Selected batches

Set the UDID, input mode and display pair at batch level. Do not repeat or override them in a step:

```bash
axe batch --udid "$UDID" --input-mode selected \
  --screen-id "$SCREEN_ID" --screen-uuid "$SCREEN_UUID" \
  --step "tap --id $FIELD_ID --expected-pid $APP_PID" \
  --step "type 'Hello' --expected-pid $APP_PID --focus-id $FIELD_ID"
```

Selected batches support coordinate or ID/label/value `tap`, `slider` endpoints, `swipe`, `drag`, existing `gesture` forms except `two-finger-swipe`, complete `touch --down --up`, literal/file/stdin `type`, `key`, `key-sequence`, `key-combo` and `button home|side-button|siri|lock|apple-pay`. ID/label/value tap steps accept `--element-type` through the same request builder and final target checks as standalone selected tap. Each selector tap needs its current `--expected-pid` and uses the normal IDB accessibility-readiness check. Each keyboard step needs `--expected-pid` and `--focus-id` for an already focused, enabled, visible TextField; keyboard checks use the existing bridge. An earlier tap does not waive the later focus check.

Selected batch `type --stdin` reads the process standard input once at that ordered step, before sending its keyboard request. Supply the step list with batch `--step` or `--file`, then pipe the text to AXe and close the pipe. The text must contain 1–256 UTF-8 bytes and use the existing US keyboard mapping; bytes and newlines are not trimmed or truncated. The synchronous read waits for EOF, has no deadline and cannot observe task cancellation while blocked. AXe checks task cancellation again after the read and before send. The normal current PID, focus and per-key checks still apply. Invalid or empty input stops later steps; earlier effects remain and input is not replayed. Batch-level `--stdin` consumes the same stream as the step list first, so a nested `type --stdin` sees EOF and rejects empty text. A second stdin text step also sees EOF after the first successful read; there is no separate text stream.

A selected `drag` step accepts `--start-x`, `--start-y`, `--end-x`, `--end-y`, `--duration`, `--steps`, `--pre-delay` and `--post-delay`, with the same validation and defaults as standalone selected drag (0.6-second movement and 60 steps). Coordinates are oriented logical display points. The owner checks the complete path against fresh selected bounds before input. This coordinate route does not accept selectors or `--expected-pid` and does not prove which app receives the drag. Legacy batch drag remains unsupported.

A selected `slider` step requires exactly one `--id` or `--label`, `--endpoint minimum|maximum` and positive `--expected-pid`. It inherits the batch screen pair. It uses native semantic endpoint control with zero HID events. A clean `endpointObserved` receipt completes the step after value readback; `alreadyAtEndpoint` completes without a new action. Neither outcome is a touch-release receipt or proof of an app callback. Optional `--element-type` uses the same builder and fresh native checks as standalone selected slider. Filtered completion also requires matching bounded native type evidence in the recorded samples and actions. Label steps use the same trimmed, case-sensitive matching and duplicate-before-type checks as standalone selected slider, including targets without an ID. Percentage `--value` and non-default wait/poll options are not supported. Legacy batch slider remains unsupported.

A selected `button home` step inherits the batch screen pair and uses the existing selected Home request. Optional per-step `--expected-boot` must match exactly; optional `--duration` follows the standalone rule above, including positive fractions through 10 seconds and no requested hold when omitted. For example, use `--step "button home --expected-boot $BOOT_ID --duration 0.2"`. Home acts on the whole device; the active pair guards admission, not display-specific button routing. Batch completion requires matching typed Home execution and close evidence, two sent events, release and drain. It does not prove visible Home or an OS held-button inventory. A context failure can follow the Home effect; retain that failed receipt and do not replay it.

Selected `sleep <seconds>` waits on the host with no input lease or broker request. It accepts every finite non-negative Double duration, including zero, with no total cap. AXe measures monotonic elapsed time and uses bounded cancellable waits; this is not a readiness or exact timing guarantee. The JSON step receipt has a `hostWait` object with `requestedSeconds`, `elapsedSeconds`, `outcome` and an error when present; request ID and broker response are absent. A completed wait has status `completed`; interruption or wait-owner failure has `waitInterrupted` or `waitFailed` and stops later steps. SIGINT/SIGTERM handling applies only during the wait, cancels and awaits the owned wait task, then restores prior signal dispositions. This is not whole-batch signal handling or an atomic signal-boundary guarantee. Output failure also stops the batch. The next input step uses its normal fresh context/target/focus guards; sleep does not preserve or prove device state, reserve the device or inspect other processes' held input.

Each input step uses the guarded selected owner with fresh context and target or focus reads. No legacy HID session or batch AX cache is used. Stdout contains one JSON line per attempted step, with its index, command, request ID, status and full broker response when available. Input status is `completed`, `rejectedBeforeSend`, `failedResponse` or `outcomeUnknown`. Host wait statuses are described above. For HID steps, completion describes input transport, not the app effect. Slider completion uses its semantic endpoint receipt as described above. Any step or receipt-output failure stops later steps. Earlier steps are not undone, and uncertain input is not replayed. Steps are parsed in order; this is not all-or-nothing validation.

Selected batch does not yet support retained touch/token chaining, `tap --semantic-press` or other commands. These steps reject explicitly. `--continue-on-error` and non-default legacy cache, chunk, batch-level tap-style or batch-level polling settings also reject; per-step ordinary tap supports `--tap-style` values `physical`, `simulator` and `automatic`. Explicit batch-level `--tap-style automatic` has the same effect as omission: it does not set the selected step style. A tap step without its own style keeps the physical 0.1-second hold. Other default legacy settings do not enable those features in selected mode. Batch `--file` and `--stdin` still read the step list.

The selected common lease covers each operation, not the whole batch. Other input can occur between steps. A foreground change, fold or rotation requires fresh state; the batch does not choose another display or infer a new PID. Ordinary Duo batch ownership is described [above](#ordinary-duo-batches).

## Selected PNG screenshots

Use the paired display ID and UUID from a fresh `list-simulators --displays` read:

```bash
axe screenshot --udid "$UDID" --screen-id "$SCREEN_ID" \
  --screen-uuid "$SCREEN_UUID" --output ./selected.png
# Optional: reject a different boot, using the identity from hinge read
axe screenshot --udid "$UDID" --screen-id "$SCREEN_ID" \
  --screen-uuid "$SCREEN_UUID" --expected-boot "$BOOT_ID" --output ./selected-boot.png
```

This PNG route accepts only the measured active panel. Both selection options are required; it does not use `--input-mode` or `--expected-pid`. It rejects a changed context or invalid selection without choosing another display or using legacy capture.

Selected capture does not replace an existing output file. On success, stdout contains a JSON receipt with `source: "appleSimctlSelectedPNG"`, the output path, pixel dimensions, before/after context reads and the capture child receipt. `surfaceIdentity` and `framePresentationTime` are `"unavailable"`. Context reads and live change checks bound the capture; they do not make the frame and context an atomic observation.

For selected capture, `SIGINT` and `SIGTERM` request cancellation. AXe waits for the operation to return, including its cleanup path. Cancellation accepted before output publication produces no PNG. A late signal can arrive after publication. Unconfirmed cleanup remains an error; this does not guarantee cleanup after parent termination or `SIGKILL`.

Without the screen pair, `screenshot` retains its legacy capture, output replacement and path-only stdout.

## Selected video recording

```bash
axe record-video --udid "$UDID" --screen-id "$SCREEN_ID" \
  --screen-uuid "$SCREEN_UUID" --expected-boot "$BOOT_ID" --output ./selected.mp4
```

The paired screen options select one measured active panel. Each frame uses the selected PNG capture and must match the first frame's boot, display identity, orientation, hinge pose and geometry. A changed context or capture error fails the recording; it does not retarget another screen or continue with stale frames. Use the separate follow-active mode below when the selected panel can change.

`SIGINT` and `SIGTERM` request a normal stop. AXe cancels and awaits any in-flight capture, finishes the validated frames and publishes the completed MP4 without replacing an existing destination. A stop before the first accepted frame, task cancellation or unconfirmed cleanup produces no successful output. A late signal can arrive after publication. Parent termination and `SIGKILL` cleanup are not guaranteed.

The input lease covers each capture, not the entire recording. Input can run between frames; an overlapping input request can receive a busy error. FPS is a requested maximum; context validation and capture can reduce the actual rate. Surface identity and native frame presentation time are unavailable. Success prints a JSON receipt. Without the screen pair or follow-active flag, recording retains its legacy route and path-only stdout.

## Follow the active display while recording

```bash
axe record-video --udid "$UDID" --follow-active-display \
  --expected-boot "$BOOT_ID" --output ./active.mp4
```

This explicit mode follows freshly measured active display IDs and UUIDs on one simulator boot. It rejects `--screen-id` and `--screen-uuid`. Every individual frame still requires unchanged before/after context. The first accepted frame fixes the video size; later upright images fit inside it with black bars, without stretching or cropping.

Typed lock or transition failures permit bounded fresh read-only attempts after cleanup. Quarantine, reboot, uncertain cleanup and other capture errors stop the recording. Timestamps preserve host elapsed time; a player may hold the previous frame across gaps. JSON reports accepted frames, observed context changes, maximum frame gap and recovery waits. This does not promise smooth transition animation or the requested FPS. Existing selected and legacy routes remain unchanged.

Follow-active recording is low-rate capture, not smooth animation capture. See the [full recording contract](Skills/CLI/axe/references/recording-reference.md).

## Selected video streams

`stream-video` accepts the same paired `--screen-id` and `--screen-uuid` options, with optional `--expected-boot`. Use a fresh measured active-panel pair. Do not add `--input-mode` or `--expected-pid`.

```bash
axe stream-video --udid "$UDID" --screen-id "$SCREEN_ID" \
  --screen-uuid "$SCREEN_UUID" --expected-boot "$BOOT_ID" \
  --format raw --fps 5 --scale 0.5 > selected-stream.raw 2> selected-stream.log
```

Stdout contains only stream bytes. Metadata, frame counts and the final summary go to stderr. Select the matching decoder:

- `mjpeg`: multipart JPEG with declared boundary `mjpegstream`, `--mjpegstream` part delimiters, exact Content-Length and a closing delimiter on normal completion.
- `raw`: a four-byte unsigned big-endian JPEG length followed by that JPEG.
- `ffmpeg`: concatenated standalone JPEG images. AXe does not start an ffmpeg process.
- `bgra`: headerless, tightly packed top-to-bottom BGRA pixels with premultiplied alpha, `width * 4` bytes per row and `width * height * 4` bytes per frame. Read width, height and row size from stderr metadata. Quality does not alter BGRA pixels.

Scaling uses the already upright PNG dimensions, rounded down with a minimum of one pixel. Each frame must match the first frame's device, boot, screen, geometry, scale, rotation and hinge pose. A change or capture error stops the stream without a retry, new target or legacy fallback. The common input lease covers capture only; input can run between frames, and overlapping input can receive busy. This is a fixed-pose stream, not continuous coverage of folds or rotations. FPS is a requested maximum; the summary reports achieved host write rate. Surface identity and display presentation time are unavailable, and frame/context checks are not atomic.

`SIGINT` and `SIGTERM` request normal stop and awaited capture cleanup. A packet already started must finish within its existing five-second output deadline or fail. A successful MJPEG stop also writes the closing delimiter. Backpressure, a closed consumer, task cancellation or uncertain cleanup can leave partial output; retain the error and do not retry by appending to it. Confirm actual process exit as well as the summary. The output deadline bounds userspace waits, not stalled kernel calls, image encoding or all SDK cleanup. Parent termination and SIGKILL cleanup are not guaranteed. Without the screen pair, legacy streaming remains unchanged.

## Agentic simulator automation

The experimental `agent` command turns a natural-language goal into validated AXe actions using TypeSafe AI's Jev model. It uses the simulator's accessibility hierarchy rather than screenshots and executes one bounded action at a time.

```bash
export TYPESAFE_API_KEY=<TYPE_SAFE_API_KEY>
export UDID=<BOOTED_SIMULATOR_UDID>

axe agent "Open Settings and turn on Airplane Mode" --udid "$UDID"
axe agent "Open Notes and create a note saying 'Buy milk'" --udid "$UDID"
```

Quoted text in a goal can be entered without another model call. Goals requiring a value that is not explicit can use an optional OpenAI-compatible text helper:

```bash
export TEXT_MODEL_API_KEY=<TEXT_MODEL_API_KEY>
export TEXT_MODEL_BASE_URL=https://api.deepseek.com/v1
export TEXT_MODEL=deepseek-chat
```

See [`docs/agent.md`](docs/agent.md) for the architecture, configuration, supported operations, tracing and limitations.

## Documentation

Full documentation is available at [axe-cli.com/docs](https://axe-cli.com/docs).

## Disclaimer

AXe is an independent open-source iOS Simulator automation project and is not affiliated with, endorsed by, or associated with Deque Systems or its axe® accessibility products.

## Licence

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Third-party licensing notices, including Meta's IDB MIT attribution, are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

The keyboard signal detector is adapted from sim-use commit `c02295ed` under Apache 2.0. Its [licence and upstream NOTICE](Sources/AXe/Resources/licenses/sim-use) are included in AXe's resource bundle, with the source and changes listed in `ADAPTATION.md`. AXe's root MIT licence is unchanged.
