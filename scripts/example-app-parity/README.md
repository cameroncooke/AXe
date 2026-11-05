# Example app replay with AXe

This helper checks visible app tasks through AXe agent mode. It uses only the Python standard library (Python 3.9 or later; verified with system Python 3.9.6). It does not build, install or launch an app, delete its data, or change its source. Use one existing warm simulator and prepare the required normal app screen first.

## Run a plan

From the AXe checkout, use the verified fresh-observation Calculator baseline:

```sh
python3 -B scripts/verify-example-apps.py --axe /absolute/path/to/axe --udid SIM_UUID --out /absolute/new/evidence-directory --plan scripts/example-app-parity/calculator-refresh.json
```

Use the same selected Xcode as the app build, for example by setting DEVELOPER_DIR in the calling environment. The AXe path, simulator UUID, output directory and plan are required. The output directory must not exist. No AXe install path or build_products evidence path is built into the helper.

The helper has a 60-second timeout per CLI call. Set --timeout to change it. --max-pages defaults to 256; reaching that bound fails the check instead of omitting remaining controls.

CPU and memory monitoring is optional and supplied by the caller:

```sh
python3 -B scripts/verify-example-apps.py --axe /absolute/path/to/axe --udid SIM_UUID --out /absolute/new/evidence-directory --plan scripts/example-app-parity/calculator-refresh.json --guard /absolute/path/to/resource-guard.py --resource-probe /absolute/path/to/resource-probe
```

Supply both monitoring arguments together. The guard must accept --resource-probe, --owned-device, --timeout, --out and a command after --. It must write stdout, stderr and result.json with exitCode, reaped and stopReason into its output directory. Without these arguments, the helper runs AXe directly with a timeout. It does not monitor CPU or memory by itself.

## Included plans

- calculator.json is the known returned-reference regression case. It reuses the public replacement references and is not the verified baseline. It requires the ordinary Calculator to be in the foreground on the warm simulator. It first taps the normal C button through a compact reference and checks that the display is 0. It then checks all 19 buttons, tap, touch, a 500 ms hold and 5 + 3 = 8. A process restart is not required between runs. Static display text must match the text role; a button labelled 7 cannot satisfy the display assertion.
- calculator-refresh.json performs the same visible checks as calculator.json, but requests a fresh public agent capture before each input. This is a separate baseline with an extra read/token cost; it does not replay a failed input.
- calculator-arithmetic.json checks Clear, display 0, 5 + 3 and display 8 through fresh agent references. It keeps arithmetic app-effect proof separate from the larger controls plan.
- calculator-scroll.json starts after launching the same Calculator with its existing --snapshot-scroll-surface argument. It repeats the original small semantic swipe. Its text assertions establish the screen content, not the amount of scrolling.
- weather-locations.json starts at the default Weather screen and checks that the Locations sheet opens.
- weather-settings.json starts at the default Weather screen and checks that the Settings sheet opens.
- weather-precipitation.json recovers the Weather precipitation UI test. It starts on the normal San Francisco main screen, performs at most five completed upward swipes within the public main-scroll reference until a tap-capable PRECIP. button is visible, then taps it using a fresh reference and reads PRECIPITATION and LIGHTNING text.

The Calculator source is example_projects/iOS_Calculator and Weather is example_projects/Weather in XcodeBuildMCP. Their bundle IDs are io.sentry.calculatorapp and com.sentry.weather.Weather. Weather plans require the normal default screen before each run. The Calculator plan uses its normal Clear button and can run again on the existing foreground app. Use simctl install/launch outside this helper; do not add app-state injection or hidden test routes.

The smaller plans recover separate parts of the earlier work. The complete functional plan below covers the original RS/1 manual task in XcodeBuildMCP benchmarks/claude-ui/prompts/weather.md: change units and switches, type London, select it, then read the required weather and precipitation values. That complete task is distinct from the later UI output-contract suite. Add its visible steps to a plan only when their public agent targets are known. Do not add accessibility IDs to the sample app just to hide a tool limitation.

## Repeatable agent batch checks

Prepare the normal Calculator in the foreground on one existing warm simulator, then run:

```sh
python3 -B scripts/verify-agent-batches.py --axe /absolute/path/to/axe --udid SIM_UUID --out /absolute/new/batch-evidence-directory
```

Use the same DEVELOPER_DIR as the app. Add `--guard /absolute/path/to/resource-guard.py --resource-probe /absolute/path/to/resource-probe` for per-call CPU/memory checks, or run the helper under an existing outer guard. Without monitoring arguments, calls retain their timeout but the helper does not monitor resources. The current guard uses exit 2 for a completed child error; that is accepted only for the exact expected public refusal.

The helper imports Replay from verify-example-apps.py. It reuses whole-stdout JSON decoding, compact paging, row lookup and raw call evidence. It checks all 19 buttons; inline Clear with visible display 0; one four-action batch for 5 + 3 = 8; invalid later-ref refusal before any completed step with display 8 unchanged; old-table refusal followed by successful read-ref and paging on the newer table; and the file reference form with visible display 0. If Clear exposes no native ID, the separate native ID file check is explicitly skipped. No ID or coordinate fallback is invented.

The current helpers check the public adaptive success contract: completed count, ordered step action/status, input outcome, event count, cleanup and batch-level no-replay evidence. After complete success with a fresh final capture, duplicate totals, rollback false, request IDs and per-receipt replay false are omitted. A receipt kind equal to its action is also omitted; typeText stays distinct from type. Failure receipts retain those fields. The Weather switch helper requests full view and still requires the complete base fields. The recorded V5 results below used the earlier contract. V6 ran the updated checks successfully as recorded below.

These are helper assertions, not recorded pass results. Unexpected failure stops the run. Expected refusals must have complete actual JSON, a nonzero child exit, the exact error code, zero completed steps and no action receipts. The original failed call record remains. This establishes public prevalidation evidence plus unchanged visible state, not an independent OS event inventory. No input is retried.

Each run saves both helper sources and hashes, its fixed check plan, every actual batch document and hash, all CLI argv/stdout/stderr, and the result. `PASS_WITH_SKIPS` keeps the native ID gap visible. A failed strict layout check remains a failure; the helper does not refresh and replay that input. It performs no build, install, launch or app-state change outside the named public batch actions.

## Repeatable Weather switch and search checks

Build, install and launch the unchanged Weather app before these checks. Use one existing warm simulator, the same DEVELOPER_DIR as the build, an explicit tested AXe path and a new output directory per run. These helpers use normal public controls and do not build, reset or launch the app.

For switches, open Weather Settings with Atmospheric animations and Severe weather alerts visible and on:

```sh
python3 -B scripts/verify-weather-switches.py --axe /absolute/path/to/axe --udid SIM_UUID --out /absolute/new/weather-switch-evidence
```

The helper reads both values as 1, sends one two-step reference batch and requires both returned full-capture values to be 0. Add --prepare-on to turn each off switch on once through an observed public tap before the check. Each preparation tap and readback remains in the evidence. It does not handle Reduce transparency below the visible area or prove all seven settings.

For search, start on the normal main Weather screen. Supply its exact visible location button label (for example San Francisco):

```sh
python3 -B scripts/verify-weather-search.py --axe /absolute/path/to/axe --udid SIM_UUID --location-label 'San Francisco' --out /absolute/new/weather-search-evidence
```

Add --from-settings only when Settings is already open; it first taps the normal Close button. The helper opens Locations, clears existing search text if present, focuses the field if needed and proves it is empty. It types London once in one public batch, then requires the actual field value London and one tap-capable London, England result. It does not select that result or complete the original Weather task.

Both helpers accept the same --guard and --resource-probe pair, --timeout and --max-pages options as the replay helper. Resource monitoring requires both monitoring arguments or an outer guard. They save their own source, imported replay source, batch JSON, hashes and complete per-call evidence. An action failure stops the run without replay.

On 2 November 2026, final benchmark runtime V5 (CLI SHA-256 d6f2b0f63013903e4f0e7f83f3bb5bd171bd8aa3c26225b140ba66419b2b2656) passed the Calculator batch helper with six checks and one explicit native-ID skip in 15 calls. The Weather switch helper passed in three calls, and the search helper passed in 11 calls including normal setup. All three recorded zero input retries. These results are separate from the earlier installed V5 candidate below; the final benchmark candidate was not installed locally.

## Repeatable offscreen Weather setting check

Start on the normal London main screen with Celsius selected and Reduce transparency on. Do not expand Settings with another tool. Run the existing public replay plan:

```sh
python3 -B scripts/verify-example-apps.py --axe /absolute/path/to/axe --udid SIM_UUID --out /absolute/new/weather-scroll-setting-evidence --plan scripts/example-app-parity/weather-scroll-setting.json
```

The plan opens Settings, uses at most three reference swipes to find Reduce transparency, reads 1, taps it, reads 0 and closes Settings. The V6 run passed ten checks in nine calls using exactly one six-event swipe, with no input replay or FlowDeck setup. It ended on London with 11 visible. This proves scrolling and use of the offscreen control, not the original task's required final value on or all seven settings together. Use the normal control to establish the stated starting value before another run; the helper does not reset app data.

V6 also repeated the six Calculator batch checks in 15 calls with one explicit native-ID skip. Its host checks passed 83 tests in 13 suites; the unchanged native V3b candidate passed 15 tests in two suites. The candidate CLI SHA-256 is 0e4a1c5be0f771c9216cd4f5c68a61128879b6687a69c3bcc7bd8bbca5b324ed. The earlier V5 seven-setting attempt and separately FlowDeck-expanded tail remain separate evidence; neither is a complete task pass.

## Verify all seven final Weather settings

Start after the search check with London selected and the Locations sheet open. The field must contain London, Celsius/m/s/inHg/km must already be selected, Atmospheric animations and Severe weather alerts must be off, and Reduce transparency must be off. Prepare these states through normal app controls. Then run:

```sh
python3 -B scripts/verify-example-apps.py --axe /absolute/path/to/axe --udid SIM_UUID --out /absolute/new/weather-seven-settings-evidence --plan scripts/example-app-parity/weather-seven-settings.json
```

The unchanged plan passed 18 checks in nine calls on V6. It read the four selected units and both off switches, used one AXe swipe to find Reduce transparency, changed 0 to 1 and closed Settings to London and 11. Its SHA-256 is bf3833cd4211bc88b21a26299e3770115c6973b9439b8c22baf1d4beee493507. This verifies all seven final settings; it is not a fresh full-task benchmark because earlier normal UI actions prepared the other states. V6 separately repeated the London search check in 11 calls with exactly 14 input events and a visible London result.

## Run the complete original Weather UI task

Use the unchanged Weather app on one existing warm ordinary portrait iPhone simulator at 402 × 874 logical points. Terminate and relaunch only the app through its normal lifecycle to restore its in-memory defaults. Do not continue the already changed London session. Confirm a usable first agent capture before the replay. The required starting screen is the top of San Francisco/current location, with °F, mph, mb and mi, both first switches on, Reduce transparency off and an empty Locations query. No simulator creation or app-data injection is needed.

```sh
python3 -B scripts/verify-example-apps.py --axe /absolute/path/to/axe --udid SIM_UUID --out /absolute/new/weather-original-evidence --plan scripts/example-app-parity/weather-original-functional.json
```

On V6, this unchanged plan passed all 52 checks in 54 CLI calls with zero input retries. It changed all seven settings from defaults, entered and selected London, read the requested main weather values and read every precipitation detail value. It sent no further input after opening the detail page. The first fresh capture attempt had failed before input; a later warm run of the same plan passed. This proves functional coverage, not startup reliability or model efficiency. Explicit fresh reads, paging and checks make the 54-call total different from the historical 14-call model target. Build/install and normal app restart are outside this replay.

The plan SHA-256 is f0ea431802f9def65db5a057b19d7690a854d7b8c0c0fbab6af975e71bc7a12a. Use the same optional resource tools described above. The recorded run has 54 saved guard receipts with no guard stop, unreaped call or recorded crash.

## Check app switching and a failed final capture

Prepare Home with one unique visible app icon. For the verified failure path, open Safari normally first, then return to Home so Safari is warm. The helper defaults to Settings; --app-icon selects the exact visible icon label. For the recorded Safari case, use:

```sh
python3 -B scripts/verify-agent-handoff.py --axe /absolute/path/to/axe --udid SIM_UUID --app-icon Safari --out /absolute/new/safari-handoff-evidence
```

The helper captures Home, taps the chosen reference once in one public batch and inspects the actual result. It requires the completed tap receipt to remain when the final capture fails, then requests a fresh agent capture without a caller PID. The optional --expected-home-pid only asserts the independently observed test precondition; it is not passed to AXe. The same optional guard/probe pair is supported. No action is replayed.

The warm Safari V6 case passed two checks in three calls. It retained the two-event completed receipt when the final read reported Home-to-Safari process change; the next capture returned Safari with 39 rows and a new snapshot. A cold first case completed its final capture normally and stayed UNPROVED for this specific failure path. The helper does not force a failure, retry input, add delays or use hooks. The Settings icon mismatch remains a separate open fault.

## Earlier recorded verification

On 2 November 2026, the returned-reference variant completed its first three checks. The next tap on 7, using the public replacement from Clear, was refused with screenChanged before that tap sent input. The earlier Clear tap did run. That failed attempt remains recorded; the plan was not replaced with a fresh-read variant and marked as passing.

The final helper passed calculator-refresh.json with 17 checks in 22 CLI calls and the warm weather-precipitation.json run with four checks in seven calls, including one actual completed swipe. Both runs used V5 CLI 1ca9609a on 2 November 2026. Their saved helper.py files and the current source have the same SHA-256: ca05382ee2218ac27cd44efbfc00fa0315a96fa4b2974c7545436e8132fb5622.

The earlier calculator-arithmetic.json run passed nine checks in ten calls. Keep that result separate from the two final-helper runs. Fresh observations before input add calls and tokens; those successful runs do not convert the returned-reference failure above into a pass or establish its cause.

Settings and Locations were exercised with the prototype helper. Their standalone plans have not each run with the final helper. A prototype precipitation continuation reached the details after five completed swipes; the final warm plan needed one. The first prototype used the wrong main-screen button label (PRECIPITATION instead of PRECIP.); that was a helper query error, not an AXe result.

## Plan operations

A plan is a JSON array of steps, or an object with a steps array. Optional name/provenance fields describe the recovered source. Supported operations:

| op | Fields | Check or input |
| --- | --- | --- |
| expect | contains: text array; optional role/label/value | Each substring occurs in the selected visible row labels or values. |
| text_is | text | One text-role row has that exact label. Button text does not count. |
| buttons | labels: text array | Every named tap-capable button appears across all pages. |
| value or row_value | label, role, equals | One selected row has the exact displayed value. |
| tap | Row query; optional physical:true | One agent reference tap. |
| type | Row query, text | Type once through a typeText-capable agent reference. |
| swipe | Row query, direction; optional distance/duration | One semantic swipe within a swipe-capable reference. Defaults: distance 0.7, duration 0.4 seconds. |
| touch or hold | Row query; optional delay | One complete down/up pair. Defaults: touch 0.05 seconds; hold 0.5 seconds. |
| capture | No target fields | Obtain a fresh public agent capture. |
| scroll_until | target and scroll row queries; direction; optional max_swipes/distance/duration | Find a tap-capable target in at most five completed swipes. |

A row query can use exact label, role, value or ref fields. label_prefix matches a literal, nonempty label prefix. It must identify one compatible row among the pages inspected. Action lookup reads later pages only if the target is absent. Set scan_all:true when global query uniqueness must be checked. Button coverage always reads all pages. Page cursors must advance and keep the same snapshot UUID.

Successful actions reuse their public replacement captures. Set refresh:true on a step to request a new observation first. Read assertions can set timeout in seconds to wait for a visible predicate. Only predicate failures can cause additional read-only observations; CLI errors, invalid pages and resource failures stop the run. Action failures always stop the run. The helper never replays input automatically.

scroll_until reads a fresh public capture before each gesture. Its target query must identify a tap-capable row; its scroll query must identify a swipe-capable area. max_swipes is an integer from 0 through 5 (default 5). direction, distance and duration have the same rules as swipe. Only a completed swipe with a usable public replacement capture permits another swipe. Input errors stop the plan; they are never retried. The next physical tap can use refresh:true, as the included precipitation plan does.

All decisions use compact agent rows and references. There is no fallback to raw hierarchy, coordinates, app data or source state. If agent output omits a needed field or control, the plan fails. A separate observer may verify an app effect, but its private information must not select targets for this replay.

## Evidence and limits

Each run saves its exact helper file as helper.py before execution, a copy of its plan, manifest.json, latest-rows.json and result.json. The helper hash in result.json refers to that saved copy, so later source edits do not remove the source used by the run. Every CLI call has a raw directory with complete stdout/stderr and call.json. Guard receipts and output are retained when monitoring is enabled. Failures retain the actual public action receipt and error, including cases where input completion is unknown. No output is trimmed to make JSON parsing pass.

The result records hashes for the invoked executable file, helper, plan and optional monitoring tools. If --axe names a shell wrapper, the file hash is the wrapper hash; record the payload hash separately. Nothing is committed or published by the helper.

A successful input receipt alone does not prove the app changed. Keep visible display, sheet or value assertions after actions. This script does not run XcodeBuildMCP, launch Claude, provision a simulator or certify the entire historical suite.

For token comparisons, count every agent-visible stdout result in the manifest, including paging, failed attempts and readback. Keep setup/build output outside the interaction boundary and name the tokenizer. Do not compare only the first screen capture.
