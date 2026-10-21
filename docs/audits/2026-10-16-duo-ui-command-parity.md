# iPhone Duo UI command parity — 2026-10-16

## Scope and evidence

This report compares UI automation contracts in the installed tools. It does not compare video or screenshot quality. A command listed here is available in help; this does not prove that it works in each Duo pose or orientation. New live results belong in [the main audit](2026-10-16-iphone-duo-audit.md) and its linked live evidence.

Versions checked:

- FlowDeck: `/Users/cameron/.local/bin/flowdeck --version` returned `1.33.0 [fac60d]`.
- RocketSim: `/Applications/RocketSim.app/Contents/Info.plist` returned version `16.7.0`, build `337` through PlistBuddy. Help came from `/opt/homebrew/bin/rocketsim`.
- AXe: local candidate version `v1.8.0-1-g7163081-dirty`, from `axe --version`, at `/private/tmp/axe-duo-audit-20261016/build/out/Products/Debug/axe`. Repository HEAD was `7163081400b59f1df40bff44f3a94dded38eea9a`, on `main`, with pre-existing uncommitted source changes. Source evidence is not a released-version claim.

No interactions, licence queries, tests, or simulator controls were run for this command inspection. RocketSim help required execution outside the nested sandbox because its App Sandbox cannot initialize inside it. All final help calls succeeded.

In the tables, **F** means `flowdeck ui simulator`; append `-S <UDID> --json`. **R** means `rocketsim`; append `--udid <UDID>`. These abbreviations are for the report only. “Not advertised” means that no dedicated command or option appeared in the inspected installed help. It does not prove that no other product interface can perform that action.

## Installed competitor contracts

| Action | FlowDeck 1.33.0 | RocketSim 16.7.0 |
| --- | --- | --- |
| Read elements | `F screen`; `--interactive-elements`; `--since-hash HASH` returns unchanged when the hash matches | `R elements --agent-mode nav\|act\|debug`; `--since HASH` returns unchanged plus sequence when the hash matches; `R screen` gives compact state |
| Find or query | `F find TARGET [--by-id\|--by-role] [--contains]`; target can be label, ID, or role | No separate find command advertised. Actions accept `--label TEXT --type TYPE --value TEXT --index N`. Label/value use contains; type matches. Index is 1-based reading order and requires `--screen` |
| Select and activate | `F tap TARGET [--by-id]`; `--ref eN` resolves against the latest active-session snapshot | `R interact activate --id ID` or selectors uses AXPress. `interact focus` uses a semantic tap. IDs come from `elements --agent` and are temporary |
| Coordinate tap | `F tap --point x,y --geometry points` | `R interact tap X Y` |
| Long press | `F tap TARGET` or `--point x,y`, with `--duration SECONDS` | `R interact long-press X Y` or selectors/ID, with `--duration SECONDS`, default 1 s |
| Double tap | `F double-tap TARGET [--by-id]` or `--point x,y` | Dedicated double-tap command not advertised. Two batch taps do not have a documented double-tap timing guarantee |
| Swipe | `F swipe up\|down\|left\|right` or `--from x,y --to x,y`; `--duration` default 0.3 s; `--distance` is screen fraction 0.05–0.95, default 0.4 | `R interact swipe --from x,y --to x,y` or `--direction up\|down\|left\|right\|back\|notification-center\|control-center`; `--id ID --direction DIR` starts at an element; `--duration` default 0.3 s |
| Scroll | `F scroll --direction DIR --speed 0…100 --distance FRACTION`; distance defaults to 0.85. `--until LABEL\|id:IDENTIFIER --timeout MS` scrolls to a target; timeout default 20000 ms | `R interact scroll --id ID --direction DIR --pages N`; pages default 1, max 10; `--duration` is per-page duration, default 0.3 s, range 0.05–3 s. Help says endpoints stay inside the target frame |
| Drag | `F swipe --from x,y --to x,y --hold SECONDS --duration SECONDS`; help explicitly names drag-to-reorder | Coordinate swipe is available; dedicated drag command and initial hold option not advertised |
| Slider | Semantic slider-value setter not advertised; coordinate swipe is available | Semantic slider-value setter not advertised; coordinate swipe is available |
| Pinch | `F pinch in\|out --scale SCALE --point x,y --duration SECONDS`; defaults: scale 0.5 in or 2 out, duration 0.5 s | Pinch command not advertised |
| Two-finger rotation | `F rotate ANGLE` or `--angle -45`; `--point x,y --radius R --duration SECONDS`; positive angle is clockwise; radius default 80, duration 0.5 s | Rotation gesture command not advertised |
| Two-finger tap or hold | Touch-count option not advertised | `R interact tap … --touches 2`; `interact long-press … --touches 2`. Alias: `--number-of-touches`. This is simultaneous touch count, not double tap |
| Low-level touch | `F touch down x,y`; `F touch up x,y`. Move command and finger-ID option not advertised | Low-level touch commands not advertised |
| Type and erase | `F type TEXT [--clear] [--mask]`; `F erase [--characters N]`; `F hide-keyboard`. Type acts on the focused field | `R interact type TEXT`, or `--stdin`, or `--file FILE` (UTF-8). Optional `--id ID` focuses first. Help specifies HID keyboard |
| Keyboard keys | `F key HID_CODE [--hold SECONDS]`; `--sequence CODE,CODE` | HID key command not advertised |
| Hardware buttons | `flowdeck simulator button NAME [--hold SECONDS]`: home, swipe-home, lock, siri, applepay, app-switcher, side-button, volumeup, volumedown; optional `--dry-run` | `R interact button NAME`: apple-pay, home, lock, side, siri. `--duration` valid for lock/side/siri; Siri has a built-in 0.75 s default |
| Back | `F back` | `R interact swipe --direction back` |
| Wait | `F wait TARGET --timeout SECONDS --poll MS`; defaults 30 s / 500 ms; `--gone`, `--enabled`, `--stable`, or `--focused` | `R wait element` with ID or label/type/value; `wait screen-changed --from HASH\|latest`; `wait keyboard --state visible\|hidden`; defaults 5 s / 200 ms via `--timeout` and `--poll-interval-ms`; also `wait time` |
| Assert | `F assert visible\|hidden\|enabled\|disabled TARGET [--by-id]`; `assert text TARGET --expected TEXT [--contains]`; text is exact unless contains is set | Dedicated assert command not advertised; wait predicates cover some presence/state checks |
| Batch | `F batch --steps JSON` or `--file FILE`. Re-finds label/ID targets on each screen, auto-scrolls off-screen targets, stops at first failure, returns step results and final tree | `R do --step "interact …" --step "wait …"`; sequential; refreshes snapshot between steps; `--refresh-policy safe\|smart`, default safe; optional `--continue-on-error`; nonzero exit if any step fails |

### Batch details

FlowDeck's installed `batch --examples` lists these JSON actions: `tap`, `double_tap`, `type`, `swipe`, `scroll`, `wait`, `key`, `assert`. A tap target accepts `target` plus `by_id`, or `point` as an x,y string. Type accepts `text` plus `clear`. Wait accepts `target`, `condition`, `timeout_ms`, and `by_id`. Batch assert searches label/value text and can auto-scroll; `condition: absent` asserts absence. Do not assume that the batch schema accepts every standalone gesture option.

RocketSim takes each step as the text after `rocketsim` on the command line. Its help says it refreshes the snapshot store between steps because element IDs are temporary. Smart refresh skips redundant refreshes before read/wait steps after an interaction has returned fresh state. This is sequential execution, not an atomic transaction or rollback guarantee.

## AXe commands and source limits

AXe source was inspected by the source-audit worker and checked against the local candidate help for `tap`, `drag`, `slider`, `gesture`, and `batch`. All commands below require `--udid <UDID>`. The public registry is [main.swift](../../Sources/AXe/main.swift#L16).

| Action | AXe contract | Relevant limit |
| --- | --- | --- |
| Read or find | `axe describe-ui`; `axe describe-ui --point x,y` probes a point | No standalone find/select/ref command advertised. The point probe directly calls accessibility lookup without the shared orientation transform. See [DescribeUI](../../Sources/AXe/Commands/DescribeUI.swift#L12) and [AccessibilityFetcher](../../Sources/AXe/Utilities/AccessibilityFetcher.swift#L51) |
| Tap | `axe tap -x X -y Y` or `--id ID`, `--label TEXT`, `--value TEXT`; optional `--element-type TYPE`, `--wait-timeout S`, `--poll-interval S`, `--tap-style automatic\|simulator\|physical` | Exact trimmed selector matches; duplicate matches fail. No regex, index, display selector, or hash precondition advertised. Coordinates take precedence. Source uses a computed frame centre or switch trailing point, not a supplied OS activation point, despite help wording. See [Tap](../../Sources/AXe/Commands/Tap.swift#L124) and [resolver](../../Sources/AXe/Utilities/AccessibilityTargetResolver.swift#L71) |
| Long press | `axe touch -x X -y Y --down --up --delay 1` | Real held touch, delay max 10 s. Separate down/up is supported through the retained HID broker. Declared flags are `-x/-y`; help examples that say `--x/--y` are inaccurate. See [Touch](../../Sources/AXe/Commands/Touch.swift#L21) |
| Double tap | Two tap steps can be put in `axe batch` | Named double-tap command and a guaranteed double-tap cadence are not advertised |
| Swipe | `axe swipe --start-x X --start-y Y --end-x X --end-y Y [--duration S --delta D]` | Maps endpoints once before the IDB swipe; no selector endpoint option. See [Swipe](../../Sources/AXe/Commands/Swipe.swift#L84) |
| Drag | `axe drag --start-x X --start-y Y --end-x X --end-y Y [--duration S --steps N]` | Explicit down/move/up events; defaults 0.6 s / 60 steps, max 1000 steps. Not an accepted batch command. See [Drag](../../Sources/AXe/Commands/Drag.swift#L75) and [HIDInteractor](../../Sources/AXe/Utilities/HIDInteractor.swift#L131) |
| Scroll and edge gestures | `axe gesture scroll-up\|scroll-down\|scroll-left\|scroll-right\|swipe-from-left-edge\|swipe-from-right-edge\|swipe-from-top-edge\|swipe-from-bottom-edge`; optional `--screen-width W --screen-height H --duration S --delta D --pre-delay S --post-delay S` | Defaults to 390 × 844 points. Source bypasses the shared orientation transform and sends preset coordinates directly. No semantic scroll-until command advertised. See [Gesture](../../Sources/AXe/Commands/Gesture.swift#L172) and [batch conversion](../../Sources/AXe/Utilities/Batch/Command+BatchConvertible.swift#L160) |
| Slider | `axe slider --id ID` or `--label TEXT`, plus `--value 0…100 [--element-type Slider --wait-timeout S --poll-interval S]` | Horizontal frame-derived drag, then normalized AXValue polling with tolerance 0.0007 and 0.3 s stability. This checks a postcondition. Vertical and right-to-left sliders are not generalized. Not exposed in batch or agent actions. See [Slider](../../Sources/AXe/Commands/Slider.swift#L106) |
| Pinch and multi-touch | Public command not advertised | The internal IDB fork implements pinch and two-finger touch, but AXe exposes no public entry point. Sequential single touches are not simultaneous contacts. See [HID events](../../idb_checkout/FBSimulatorControl/HID/FBSimulatorHIDEvent.swift#L285) |
| Type | `axe type TEXT`, `--stdin`, or `--file FILE` | Focus must already be correct. US HID map; unsupported Unicode is rejected before events are sent. No text readback postcondition. See [Type](../../Sources/AXe/Commands/Type.swift#L100) and [TextToHIDEvents](../../Sources/AXe/Utilities/TextToHIDEvents.swift#L47) |
| Keyboard keys | `axe key HIDCODE [--duration S]`; `axe key-sequence --keycodes A,B [--delay S]`; `axe key-combo --modifiers A,B --key C` | Codes 0–255; sequence max 100 keys; combo max 8 modifiers, released in reverse order. See [Key](../../Sources/AXe/Commands/Key.swift#L27), [KeySequence](../../Sources/AXe/Commands/KeySequence.swift#L20), [KeyCombo](../../Sources/AXe/Commands/KeyCombo.swift#L32) |
| Hardware buttons | `axe button home\|lock\|side-button\|siri\|apple-pay [--duration S]` | Volume/camera buttons not advertised. DTU transport rejects the special Apple Pay event and suggests two side-button presses, so transport support is not equivalent. See [Button](../../Sources/AXe/Commands/Button.swift#L60) and [DTU transport](../../idb_checkout/FBSimulatorControl/HID/FBSimulatorDTUHIDTransport.swift#L158) |
| Wait and assert | Tap/slider have selector `--wait-timeout`; batch has `sleep SECONDS` | Dedicated read-only wait/assert commands not advertised. Selector polling retries not-found only; ambiguity fails immediately. External tree polling can implement checks. See [AccessibilityPoller](../../Sources/AXe/Utilities/AccessibilityPoller.swift#L73) |
| Batch | `axe batch --step "tap …" --step "type …"`, or `--file FILE`, or `--stdin`; `--ax-cache perBatch\|perStep\|none`; optional `--continue-on-error` | One HID session, sequential steps. Accepted commands: tap, swipe, gesture, touch, type, button, key, key-sequence, key-combo, sleep. No drag, slider, find, or assert step. Default perBatch cache can retain an old root if the selector still matches. See [Batch](../../Sources/AXe/Commands/Batch.swift#L103), [parser](../../Sources/AXe/Utilities/Batch/BatchStepParser.swift#L4), [context](../../Sources/AXe/Utilities/Batch/BatchContext.swift#L45) |

### AXe agent is a narrower interface

The agent action set is `OPEN_APP`, `TAP`, `TYPE_TEXT`, `CLEAR_TEXT`, `SCROLL_DOWN`, `SCROLL_UP`, `PRESS_RETURN`, `WAIT`, `DONE`, and `BLOCKED`. It does not expose all CLI gestures. Agent WAIT is a fixed 250 ms delay. Type/clear target and tap the field, then use keyboard events; clear uses select-all/backspace. See [AgentModels](../../Sources/AXeCore/AgentModels.swift#L3) and [SimulatorAgentExecutor](../../Sources/AXe/Agent/SimulatorAgentExecutor.swift#L117).

The agent can re-find a changed target by semantic fields and reads state after an action. It has no explicit expected-outcome ASSERT operation. The inspected state does not carry a display/hinge/orientation generation, and the mapping cache key uses only viewport size. A same-size orientation or display change can therefore retain an old transform. This is a source-level limitation, not proof that every such transition fails. See [AgentFreshness](../../Sources/AXeCore/AgentFreshness.swift#L28), [runner](../../Sources/AXe/Agent/SimulatorAgentRunner.swift#L192), and [mapping cache](../../Sources/AXe/Agent/SimulatorAgentExecutor.swift#L221).

AXe reads orientation from fixed screen ID 1 and infers coordinate mapping from the AX root aspect and that screen orientation. Its screenshot fallback has no display selector. The DTU transport retains device-type main-screen size/scale for touch normalization; the touch target defaults to 0, whose display meaning is unproved here. Broker readiness tracks boot identity, not pose/orientation. These are source assumptions that require Duo validation, not proof of incorrect taps in each state. See [orientation reader](../../Sources/AXe/Utilities/SimulatorOrientationReader.swift#L55), [mapping](../../Sources/AXe/Utilities/OrientationAwareCoordinates.swift#L145), [DTU transport](../../idb_checkout/FBSimulatorControl/HID/FBSimulatorDTUHIDTransport.swift#L75), [DTU model](../../idb_checkout/FBSimulatorControl/HID/DTUHIDModels.swift#L54), and [broker readiness](../../Sources/AXe/Utilities/HIDBrokerReadiness.swift#L6).

### Practical parity gaps

- AXe has a checked slider-value action and explicit drag, plus keyboard combinations. The inspected competitor help does not advertise equivalent semantic slider setters.
- FlowDeck exposes the broadest standalone gesture set here: named double tap, pinch, and two-finger rotation, plus scroll-until and assertions.
- RocketSim exposes AXPress activation, two-touch tap/hold, element-index selection, and an explicit caller-supplied snapshot guard.
- AXe's read-only query, stable target references, wait/assert, and public multi-touch interfaces have gaps. Its gesture presets and default batch cache also need review for changing Duo geometry.
- Existing primitives can build some missing actions, but a scripted approximation must not be reported as a documented or verified equivalent.

## Rotation, folding, and stale input

FlowDeck documents coordinates in points from FlowDeck screenshots, without @2x/@3x scaling. RocketSim's inspected X/Y help does not specify pixel-versus-point units or its rotation transform. Neither inspected action contract exposes an inner/outer display selector.

FlowDeck returns a settled tree, element refs, and `screen_hash` after many actions by default; `--no-screen` suppresses that result. A result after the action is not a guard against stale input before it. No caller-supplied action hash precondition is advertised. Its `--ref eN` resolves against the latest active-session snapshot; the help does not promise that a ref from an older snapshot retains its identity after rotation.

RocketSim offers `--screen <8-hex HASH>` on tap, activate, focus, long-press, swipe, scroll, and type. The help promises `snapshot_changed` if the screen changes beyond the resolved hash. `--screen latest` binds to the current snapshot; it does not prove correspondence with an earlier screenshot. The help does not define whether the hash includes orientation, active display, or hinge state. Do not infer full Duo geometry protection from the existence of this guard. The help describes ID/selector guards; protection for raw coordinates is not established here.

`flowdeck simulator orientation set portrait|landscape-left|landscape-right|portrait-upside-down -S <UDID> --json` waits for visual confirmation unless `--no-wait` is set. That confirms orientation at that step; it does not make a later input atomic with the confirmed state. Its two-finger `ui simulator rotate` command is a gesture, not a device-orientation setter.

A reliable Duo input check must establish the active display, its logical bounds, orientation, and element state before input, then verify the intended result. Rotation or folding can invalidate coordinates and element references. Command availability alone does not prove that a tool preserves these relationships through a transition. Live validation should separate label/ID activation, raw coordinates, long press, scroll, drag, slider, multi-touch, and keyboard input; success in one class does not establish the others.

## Verification record

Read the installed help for the top-level CLI and each command listed above. For FlowDeck, also read `ui simulator batch --examples`, `simulator button --help`, and `simulator orientation set --help`. For RocketSim, also read `do --help`, `elements --help`, `screen --help`, and each `wait` predicate help. These reads establish the installed contract only. No new live action result is claimed in this report.
