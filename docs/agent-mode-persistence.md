# Optional agent-mode references

The `--agent` flag adds compact RS/1 rows and saved references to the existing CLI. Commands without this flag keep their existing output and coordinate input.

## Read-only custom-action names

The broker retains exact provider custom-action names in its snapshot. Full canonical output keeps the ref-keyed `capture.customActions` map in base schema version 1. Reading and navigation use only `capture.customActionGroups` in the public adaptive schema, version 2: each group has `refs` and one ordered `names` preview. Every listed ref receives that exact preview. Group order follows the first published ref; ref order follows the rows. The map is not also returned in adaptive output. This is the first released optional metadata contract; earlier isolated Source22 adaptive maps are not the public contract.

Both forms keep at most four names, each at most 96 Unicode scalars. `capture.truncatedCustomActionRefs` marks omitted or clipped names per ref. Grouping uses exact name bytes and order, preserves duplicates and never removes descendant refs. Identical clipped previews do not prove identical complete arrays. Adaptive metadata belongs only to emitted refs and shares the existing 16 KiB capture budget and row cursor. Full captures keep the same preview bound. One short singleton group has more JSON overhead than a map; it still uses the same adaptive shape. Saved-output analysis of one 23-ref, four-name reading capture reduced 3221 to 2145 bytes; no token, model or new native result is claimed.

Read the complete JSON string array through `describe-ui --agent --snapshot-id <UUID> --read-ref <REF> --text-field custom-actions`. Join `data.detail.text` chunks using `nextOffset`, then decode the array. Every chunk uses the existing fresh snapshot checks. Changes to names invalidate the normalized hash and exact native fingerprint. Names add no input actions and no named-action execution. Existing raw output is unchanged. Use matched wire-54 CLI/broker and Native11 frameworks. Source preparation and later native verification are separate; no new simulator pass is claimed here.

## Current output verification — 1 November 2026

Output selection passed on CLI `be6a4f92` with native `b409f6e6`, wire 37. This exact build is installed as the local `axe` command.

- 21 output cases passed, including whole-output JSON parsing, parser and runtime errors, text errors, media destination paths, help/version and skill printing.
- Three literal-argument comparisons matched the previous CLI byte for byte. Successful JSON inventory, formatted hierarchy and the legacy hierarchy array passed.
- On Duo, a text capture supplied a reference for a JSON physical tap; its replacement reference supplied a text physical tap. Exactly two callbacks and zero held touches were observed. Text retained screen identity, boot, keyboard and other capture data.
- A selected two-step batch returned both native receipts in one JSON object, with exactly two callbacks and zero held touches.
- The existing host PID/reference 9, ordinary iPhone 6 + system prompt 1, and Duo 6 + system prompt 1 all passed with zero issues or skips.
- Nine console cases preserved large integers and finite floating-point extremes. Local skill checks and installed-command checks passed.

Heavy jobs ran one at a time with CPU and memory checks; no resource stop or owned guest crash was recorded. These are focused checks, not a new full 133-case run. The [master checklist](duo-implementation-checklist.md) links the exact receipts. The skill resources were frozen before verification; their pending proof notes are superseded by this dated record. The source is not committed. No push, publication or deployment occurred.

## Output format

Use `axe --output text describe-ui --agent --udid "$SIM_UUID"` for compact RS/1 text, or `axe --output json describe-ui --agent --udid "$SIM_UUID"` for JSON. Without an explicit format, `--agent` still returns one JSON result. Text includes the RS/1 header, snapshot and cache state, action information and compact reference rows. JSON keeps the existing `axe.output.agent-result` envelope; it is not wrapped in another command result. Snapshot IDs, refs, expiry, cache invalidation and input checks are independent of this choice.

For ordinary commands, explicit JSON uses `schema: "axe.output.command-result"` and `schemaVersion: "1"`, plus `command`, `didError`, `data` and `nextSteps`. `data` can contain a typed `result`, multiple typed `results`, or text `messages`; absent values are omitted. On failure, `error` contains `code` and `message`. JSON failures use one stdout result and a nonzero exit, without a second plain error. Parse stdout for JSON. Diagnostic messages can remain on stderr; do not merge the streams when parsing. Existing output without `--output`, and command-specific `--json` flags, keep their meanings.

Prefer the format before the command. Non-media leaf placement is accepted when unambiguous. Keep screenshot and movie destination paths after their commands:

```sh
axe --output json screenshot --udid "$SIM_UUID" --output screen.png
axe --output json record-video --udid "$SIM_UUID" --output recording.mp4
```

Explicit format selection for `stream-video` is rejected before capture; normal binary streaming stays unchanged. Set `SIM_UUID` to an actual simulator UDID. An empty value, such as an unset variable in `--udid "$SIM_UUID"`, fails with a device validation error rather than selecting a simulator. Current output checks are recorded above. The earlier automatic-PID results below used the previous output contract.

## Previous automatic-PID verification — 1 November 2026

Automatic app selection passed on CLI `feba117c` and native `b409f6e6`, wire 37. The exact tested build is installed as the local `axe` command. Use:

```sh
axe describe-ui --agent --udid "$SIM_UUID"
```

No PID lookup is required. A new capture finds the active app or SpringBoard. Reference actions use the app saved with the snapshot. Optional `--expected-pid` must be positive and match. After Home or an app change, capture again and use the new references.

- PID/reference host checks: 9/9 passed.
- Ordinary iPhone: six automatic-app checks and one real system-prompt check passed.
- Duo: the same six checks passed on the partly open inner screen; the system-prompt check passed on the outer screen.
- Existing selected-input protocol checks: 169/169 cases in 51 test functions passed.
- Local installation, seven strict signatures and a normal installed capture without a PID passed.

The simulator checks verified separate CLI calls, saved references, cache validation and reuse, replacement, refusal after Home and app changes, physical button callbacks, exact text, ordered batch steps, optional PID checks and raw command compatibility. All recorded checks had zero issues or skips. See the [master checklist](duo-implementation-checklist.md) for exact receipts and limits.

These are focused checks, not a new complete 133-case run. The dated results below retain their original builds. The CLI resources were frozen before these checks; their pending proof notes describe that earlier state and are superseded by this section. Heavy jobs ran one at a time, without a resource stop or crash. Source changes remain uncommitted. No push, publication or deployment occurred.

## Automatic PID selection

When `--expected-pid` is omitted, a new agent capture selects the frontmost app, or SpringBoard on Home, from the same native app/display observation. A reference action uses the PID saved in its snapshot. Optional `--expected-pid <PID>` adds an assertion that must be positive and match that owner; zero and negative values reject. It does not launch an app or retarget an old reference.

Use `axe describe-ui --agent --udid <UDID>` again after Home or opening another app. No raw hierarchy read or PID lookup is required first. A changed app, layout or focus still refuses old references before input. Existing agent coordinate tap/swipe forms remain available with a current snapshot. Raw commands and public selected mode without `--agent` keep their existing PID rules.

Verification for automatic PID selection is pending as of 31 October 2026. The earlier candidate results below do not verify this change. Use matching wire-37 CLI/broker and native frameworks; recorded proof notes retain their original wire versions.

## Controls without an accessibility ID

AXe can keep an eligible control's exact native process/object UID as private reference authority when a complete native read proves one occurrence. Callers still pass only the snapshot ID and `eN` ref. AXe discovers and keeps the app PID internally; optional `--expected-pid` remains a caller assertion. Raw commands and public selected mode keep their existing PID rules.

The broker keeps the complete reference table and native identities in RAM for that device and broker instance. Object UIDs are exact private UInt64 values, not public accessibility IDs or identifiers valid across app or broker restarts. They are not sent to a model or written as a persistent reference cache. No new PID/UID CLI option is added. `read-ref --text-field id` can therefore be empty even when the ref has an available action.

The identity mode is chosen when the table is published. Each opaque input needs a fresh complete native read, exact unique object/state checks and the existing app, display and native hit guards. Missing or duplicate object evidence refuses input. If optional identity traversal is incomplete, existing semantic-ID/label controls retain their current capabilities; affected unavailable refs can report `capture.unavailableReferences[ref]` as `nativeIdentityIncomplete`. A refused opaque ref never falls back to a label, path or coordinates.

Use the advertised action. An anonymous field must still be an enabled, visible, already focused native `TextField` with `typeText`; key DOWNs keep the current field/focus checks and owned key release. Existing TextView-like roles are not made editable by this feature. Opaque identity does not authorize sliders, AXPress or pinch, and it does not infer scroll support from a Group. Native-ID batch documents still require real app IDs; reference batches can use eligible refs from their original table. Reference expiry, replacement, shared callers and no replay remain as described below.

This contract requires matched CLI, broker and runtime versions. It is not a simulator acceptance result. Use the [master checklist](duo-implementation-checklist.md) for exact tested candidates and limits.

## Separate CLI calls

Each call starts a new CLI process. Calls for the same user, simulator, Xcode directory and wire-protocol version connect to one background AXe broker. That broker keeps one reference table in RAM. It does not save the table to disk.

1. Run `describe-ui --agent --udid <UDID>`.
2. Read the returned `snapshotID` and a row reference, such as `e13`.
3. Send both values with the next action:

   ```sh
   axe tap --agent --udid <UDID> \
     --snapshot-id <snapshotID> --ref e13
   ```

The row reference belongs to its snapshot. Do not use it with another snapshot ID. Before input, AXe reads the current app and checks the saved app PID, display, device layout and native hierarchy. A valid saved reference does not permit input at old coordinates without these checks.

## Lifetime and replacement

- A snapshot lasts for at most 60 seconds from capture. Use the returned `expiresInSeconds` value. Validation and unchanged-cache reads do not extend this deadline.
- The broker stays available while its current snapshot is valid. This does not extend the release deadline of a held touch or key.
- A plain new capture replaces the table, even if the visible screen did not change.
- `--since-screen-hash` can keep the current snapshot ID when a fresh read confirms the same app, display, layout and hierarchy. An unchanged response omits repeated rows.
- A successful action removes the old table and normally returns a replacement capture. Use that capture for the next action. If input completed but its replacement capture failed, obtain a fresh capture. Do not repeat the completed action.
- Other selected input or read requests invalidate the table. Raw keyboard requests routed through this broker also invalidate it before input. References also become unusable after expiry, app or layout changes, or a broker restart.

A compact screen hash does not contain every native property. If the native hierarchy changes while that hash stays equal, AXe must return a new snapshot ID. Use the returned ID and references.

## Multiple callers and refusal

All callers using the same broker share its one table. A new capture from caller B replaces caller A's capture. Caller A's old snapshot ID is refused before observation or input and cannot erase caller B's newer table. There is no separate table for each caller. Coordinate calls or captures when more than one agent uses the same simulator.

After a refusal, use the error code and `data.cache.requiresRefresh` to decide the next call. A stale reference must not be retried as coordinate input. Request a fresh capture when required. References do not survive a broker restart.

At the eight-request capacity limit, the isolated fix returns terminal busy before it reads a new request body. That refusal must not enter startup recovery and send input later. A busy refusal does not permit an automatic input retry.

## Keyboard connection reuse

No-flag `type`, `key`, `key-combo` and `key-sequence` on Duo and verified ordinary DTUHID profiles use the selected broker's input owner. Other profiles keep their existing route. Raw text parsing, literal/file/stdin loading, repeated modifier order and plain command output remain. The boot, display and device layout are checked before input. Raw keyboard input still goes to the current focused app. Exact app-PID and field-focus checks apply to selected and `--agent` input. A matched native framework is required; raw command flags remain unchanged.

A complete keyboard command can return its native connection only after all keys are released, the input has drained and its context is still current. A later CLI process can borrow that connection with a new session and empty input state. Failed or uncertain input, cancellation and layout changes discard the connection. A reference table and a native input connection have separate lifetimes.

A new connection still needs the existing guest readiness reply before it sends input. The two-second reply limit has not increased. Reuse avoids repeated connection creation after successful commands; it does not guarantee that a slow first connection will succeed. See the [measured failure and fix](audits/2026-10-29-keyboard-reliability.md).

### Private raw-input payload lifetime

The reference table remains in RAM. A raw keyboard request uses a separate temporary event file so long input is not limited by the socket size. This is not a saved accessibility table. The contents can reveal the typed text. The file has mode 0600 inside the owned 0700 broker directory. The request carries its identity, inode, size and digest. The broker checks the exact file and complete event sequence, then removes that inode before native input. The client also attempts to remove only its owned inode after normal completion, error or caught cancellation.

Abrupt process death before consumption, or a cleanup error, can leave a private payload file. No automatic stale-file pruning is claimed. Cancellation closes the socket write side and waits for the broker's owned cleanup reply. Lost or uncertain input is not replayed. Zero touch contacts alone do not prove that every key was released.

## Previous accepted build — 30 October 2026

The current isolated candidate is CLI `ddca4cc6`, native `a42360f5`, source `becb4de5`, host `da5bcfb7`. Its keyboard/slider unit 24, layout 12 and raw keyboard 4 passed with zero issues or skips. Native transport/feed 18 and legacy keyboard 9 are separate host proofs. One public popup/Escape proof preserved text and edits and ended with a fresh physical Button callback and zero contacts; it adds no suite cases.

The complete current ordinary 133 and Duo 133 each passed with zero issues or skips on this same candidate. They are separate complete runs. V1/V2 failures keep their own receipts. Source is committed as `9eb7cbee`, and the exact tested build is installed locally. The [installed CLI check](/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/final-combined-local-install-v3-plan/installed-prefix-smoke/run-v1/result.json) passed separate capture and validation calls, then one physical reference tap with one callback and full release. The existing two-second readiness limit can still reject a slow first keyboard connection with zero input. See the [audit](audits/2026-10-29-keyboard-reliability.md) for exact causes and limits.

## Earlier verification record — superseded

Isolated candidate: CLI `8a994931` / native `553acba2`, selected wire 36. The [signed payload](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/runtime-ready.json) passed seven strict signature checks. FINAL7 changes one production file from FINAL6 to refuse input when all broker request slots are full. Source checkpoints and delivery have separate receipts; no release acceptance is claimed. Earlier FINAL5/FINAL6 results below use CLI `a9f3d8c1`; they are not new-candidate full passes.

| Check | Result | Test source / host | Evidence |
| --- | --- | --- | --- |
| Complete ordinary-iPhone agent run | **133 passed; zero issues or skips** | FINAL5 `eaf6f6f8` / `9b8dd89a` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-iphone-full-v1/result.json), 2002.62 seconds |
| Amended ordinary checks | **1 + 6 + 1 passed; zero issues or skips** | FINAL6 `b506332f` / `baeea9a1` | [Reference recovery](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-iphone-raw-mutation-v1/result.json), [concurrent input](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-raw-admission-v1/result.json), [held touch](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-raw-keyboard-ownership-v1/result.json) |
| Amended Duo reference recovery | **1 passed; zero issues or skips** | FINAL6 `b506332f` / `baeea9a1` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-duo-raw-mutation-v1/result.json) |
| Complete Duo agent run v1 | **Failed: 132 clean cases; 1 failed; zero skips** | FINAL6 `b506332f` / `baeea9a1` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-duo-full-v1/result.json), 2557.88 seconds |
| Duo typing after service recovery | **8 passed; zero issues or skips** | FINAL6 `b506332f` / `baeea9a1` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-focused-after-service-recovery-v1/result.json), 160.47 seconds |
| Complete Duo repeat after service recovery | **Failed: 129 clean cases; 4 failed; zero skips** | FINAL6 `b506332f` / `baeea9a1` | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-duo-full-v2/result.json), 2512.05 seconds |
| FINAL7 host checks | **186 passed; zero issues or skips** | FINAL7 `ea9f7785` / `527051ef` | Six disjoint groups, linked below |
| FINAL7 request-capacity check | **SAFE_BUSY_REFUSAL; physical recovery passed** | FINAL7 `ea9f7785`; standalone CLI proof | [Result](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/saturation-v1/result.json), 14.2 seconds |
| FINAL7 concurrent input and held-touch ownership | **6 + 1 passed; zero issues or skips** | FINAL7 `ea9f7785` / `527051ef` | [Admission6](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-raw-admission-v1/result.json), [ownership1](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-raw-keyboard-ownership-v1/result.json) |
| FINAL7 complete simulator acceptance | **Not accepted; no new complete full run** | FINAL7 `ea9f7785` / `527051ef` | Strict full133 gates remain open |

The failed runs remain separate. FINAL6 full v1 failed one stdin AX focus admission before input (`DTXProxyChannel Code 1`,0 events, `cleanup=notNeeded`, no replay). Its [first eight-case repeat](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-focused-after-dtx-v1/result.json) passed 3 and failed 5 during setup. The [unchanged group passed 8/8 after service recovery](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/run-focused-after-service-recovery-v1/result.json). Full v2 then failed rotation preparation before dispatch and three display-catalogue preparations. Neither full run recorded a resource stop or crash; the original HID keyboard-startup timeout did not recur. No passing complete Duo run is accepted.

A [direct Apple display query timed out](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/dtx-device-catalogue-fault-v1/result.json), then [passed in 0.13 seconds](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/dtx-device-catalogue-fault-v2/result.json) without a restart. FlowDeck pose/AX, RocketSim hinge and sim-use AX reads passed in that interval; those read-only results do not prove equivalent input admission. Saved [motion accounting](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-diagnostic-v1/guest-motion-accounting.json) shows 17.88-second AXe and 21.68-second RocketSim completion delays and older invocation traffic. Their cause is unproved. The source checkpoint keeps native `553acba2`. A separate native-only candidate `c946160e`, with the same CLI `8a994931`, passed an [actual public hinge-read proof](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-v1/actual-library-proof-v1.json). Its serving process loaded the exact new library. The guest received the cancel reply, stopped angle updates and completed the original request before the connection closed. This one observed order does not prove the cause of the earlier long delays or full resource release for every request. The unchanged [typing8](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-type-v1/result.json), [typing-to-drag1](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-drag-v1/result.json) and [layout2](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-hinge-completion-layout-v1/result.json) checks passed on this native library, with no issues or skips. The [nine existing native host checks passed](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/hinge-request-completion-native-v1/native-host9-v1/acceptance.json), with the new library proved in the loaded-image trace. One new complete Duo133 run is in progress; no result is accepted yet. The native candidate is not integrated or accepted as a full Duo pass.

The [actual ninth-client reproduction](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/selected-broker-saturation-proof-v1/run-v2/result.json) proved delayed first input after the active owner ended. FINAL7 sends a terminal busy response before it reads that client's request body. The [same physical check on the fix](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/saturation-v1/result.json) passed in 14.2 seconds: no ninth-client text, joined owner release, two quiet seconds, then fresh text and one released Button tap. This proves the isolated capacity fix; it is separate from the keyboard connection-startup fix and is not a full-suite or current-main simulator pass.


FINAL7 host checks passed 186 distinct cases with zero issues or skips: [broker/lifetime67](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-unit-v1/result.json), [input boundary63](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-boundary-v1/result.json), [legacy keyboard12](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-legacy-keyboard-v1/result.json), [transport routes11](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-transport-routes-v1/result.json), [rigid schema20](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-rigid-schema-v1/result.json) and [display discovery13](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7/run-host-display-discovery-v1/result.json). Source `ea9f7785` and host `527051ef` are bound to CLI `8a994931` / native `553acba2`. The [nine native host checks](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/keyboard-startup-native-host-v2/root-acceptance.json) remain separate.

The [earlier FINAL5 Duo run](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v5/run-duo-full-v1/result.json) executed 133 cases and failed one recovery tap on a control outside its visible scroll area. Its unchanged repeat reproduced that fixture error. Three test-only corrections also updated the exact busy-error assertions. The nine focused passes above remain separate results. They do not change the failed full run or create a new ordinary-iPhone full pass. The [keyboard audit](audits/2026-10-29-keyboard-reliability.md) keeps the failures and exact receipts.

Current physical keyboard checks passed five separate raw calls on one connection, the original key-sequence group (7), Duo text sources (12), five modifier/cancellation/busy cases, raw long text (1), and raw folding/rotation interruption (4). The [keyboard audit](audits/2026-10-29-keyboard-reliability.md) links their exact receipts.

Source integration: the [reversible 57-file checkpoint](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v1/receipt.json) is applied, with 45 changed files and 12 unchanged files. The 14 unrelated work files, managed IDB source, Git index, main runtime and installed CLI remain unchanged. A [fresh offline main compile passed in 39.77 seconds](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/source-checkpoint-v1/compile-only.json). That result proves compilation only; it does not prove simulator acceptance. **Release acceptance remains blocked by the failed full Duo runs**. The strict readiness promoter was not run. The audit is a separate guarded document addition. No local installation, push, publication or deployment is claimed.

The 133-case agent group does not test every action in every Duo screen and orientation. No live foreign-user-ID injection was performed. The `postActionRefreshFailed`, `postActionRefreshQuarantined` and `batchRefreshFailed` branches were not separately forced on this hardware; source and host checks do not prove those live branches. These are evidence limits, not missing core commands. Apple Pay payment screens and Intel execution are excluded. Cold-start stress and unreproduced empty-screen recovery stay deferred.

## Repeat the candidate checks

Use the FINAL7 frozen host and runtime on the existing warm audit simulators. Resolve the current service failure before another full run. Confirm the [software-keyboard prerequisite](playground-testing.md#software-keyboard-prerequisite). Run one group at a time with CPU and memory checks and a new output label. The [current host and admission commands](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/selected-broker-cap-build-helpers-v1/acceptance-commands.json) keep all 186 host cases separate from simulator checks. The nine native cases use their recorded package.

```sh
AXE_PROOF_DIR=/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v7
AXE_RESOURCE_GUARD=/Volumes/Developer/AXe/build_products/verification/resource-policy-20261026/guarded-resources-v7.py
AXE_RESOURCE_PROBE=/Volumes/Developer/AXe/build_products/verification/duo-complete-20261024/final-public-693-v1/resource-probe

python3 -B "$AXE_RESOURCE_GUARD" --resource-probe "$AXE_RESOURCE_PROBE" \
  --owned-device 419D3218-79E5-46DE-80C0-E58126A88252 \
  --out "$AXE_PROOF_DIR/guard-iphone133-repeat" --timeout 5400 -- \
  python3 -B "$AXE_PROOF_DIR/run-checks.py" iphone --label iphone133-repeat

python3 -B "$AXE_RESOURCE_GUARD" --resource-probe "$AXE_RESOURCE_PROBE" \
  --owned-device 74728DCF-FDCF-43F0-BF13-FF41BC169F13 \
  --out "$AXE_PROOF_DIR/guard-duo133-repeat" --timeout 5400 -- \
  python3 -B "$AXE_PROOF_DIR/run-checks.py" duo-agent --label duo133-repeat
```

These are repeat commands, not test results. The [executed focused command record](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/agent-final-proof-v6/follow-up-commands-owned-v2.json) records the four focused groups and the current Duo full-run command. Its eight ordinary cases are not a new ordinary full run.

The FINAL7 runner checks source/runtime hashes and sets `AXE_BIN_PATH` to its actual signed executable: `agent-final-proof-v7/runtime/axe`. The [capacity proof commands](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/selected-broker-cap-build-helpers-v1/physical-commands.bound.json) require `SAFE_BUSY_REFUSAL`; a successful reproduction of delayed input is not fix acceptance. The broker-restart check needs the actual path to identify its own worker by executable, simulator, user and process start time before SIGTERM; an installation wrapper is not sufficient.

The runner saves commands, environment, runtime identities, XML, case events and app artifacts. Acceptance requires one start and one end for each expected case, with zero issues or skips. Preserve failed runs. Additional direct suites and their device scope are in the [Playground guide](playground-testing.md#reference-and-raw-input-follow-up-checks).

## Earlier verification record — unchanged

The record below retains the candidate and date used at the time. It does not accept the current build.


Verification is in progress on 28 October 2026 against CLI `9fcfabcd` and native framework `0be5aea4`.

- Passed: 58 broker and lifetime cases in 35 test functions, and 63 input and selector cases in 23 test functions. No failures, missing cases or skips. [Broker results](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/run-unit-ledger-final/result.json), [input results](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/run-boundary-ledger-final/result.json).
- Passed: the same snapshot remains usable after 35 seconds without a CLI request; validation does not renew it; the original deadline expires it; old input is refused; a fresh reference physically taps the Button. [Idle check](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/run-iphone-idle-isolated/result.json).
- Passed: all six keyboard observation, paging, reuse and dismissal cases on the dedicated ordinary iPhone. [Keyboard results](../build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028/run-iphone-keyboard-isolated/result.json).
- Pending: the full 130-case ordinary-iPhone run, including all 124 existing cases and six new reference cases.
- Pending: Duo reference lifecycle, fold and rotation checks on this candidate.

The first full attempt stopped to correct seven old wrong-PID expectations. The next attempt stopped at zero contacts after a read found Handful on the shared audit iPhone. Its failures remain saved. The current run uses the existing dedicated AXe Isolated Control iPhone. The Playground uses the public idle-timer setting to stay awake while active. No AXe setup service or longer input timeout was added.

The earlier four passing agent checks did not cover the full reference lifetime. The installed earlier build lost its table within 35 idle seconds. These are historical results, not acceptance of the current fix. See the [previous report](../build_products/verification/duo-recovery-20261027/agent-mode-persistence-20261028/REPORT.md).

## Repeat the candidate checks

Use the saved runner for the isolated candidate. Run one group at a time on the existing warm test simulators, with CPU and memory checks. Each run needs a new label because the runner preserves earlier output directories.

```sh
AXE_PROOF_DIR=/Volumes/Developer/AXe/build_products/verification/duo-recovery-20261027/agent-persistence-fix-20261028
python3 -B "$AXE_PROOF_DIR/run-checks.py" unit --label unit-repeat
python3 -B "$AXE_PROOF_DIR/run-checks.py" iphone --label iphone-repeat
python3 -B "$AXE_PROOF_DIR/run-checks.py" duo-lifecycle --label duo-lifecycle-repeat
python3 -B "$AXE_PROOF_DIR/run-checks.py" duo-layout --label duo-layout-repeat
```

The runner checks the saved source and binary hashes. It sets `AXE_BIN_PATH` to the actual candidate executable at `$AXE_PROOF_DIR/runtime/axe`. The broker-restart test requires that actual binary path so it can identify its own worker before sending SIGTERM. A wrapper path is not sufficient. The restart test sends no signal if the binary, simulator, user or process start time cannot be confirmed.

The runner writes the exact command, environment, XML results and event stream under its labelled output directory. Read those results before marking cases complete. The commands above are repeat instructions, not passing test results.
