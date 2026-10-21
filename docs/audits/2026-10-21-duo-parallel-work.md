# Duo parallel work: 21 October 2026

Cam authorized isolated worktrees, simulator copies, coordinator review and local merges into main. No push or security scan upload is authorized. The first parallel round and the three continuation checks below are complete within their stated limits. Their reviewed commits are merged into local main. The implementation checklist remains the capability record.

## Resource limits

The Mac has 36 GiB of physical RAM. The common guard measures working memory and aggregate CPU. Limits are 8 GiB for the ChatGPT/Codex process group, 10 GiB for all simulator processes together and 4 GiB for each owned command group. Simulator CPU at least 1200% for 20 seconds stops owned work. At most two assigned guests may be booted, with staggered startup. At most one build may run, with two jobs. A stopped command must be reaped; its owner must shut down its guest after a resource stop.

The coordinator alone grants simulator and build slots. The extra continuous sampler stopped after a process-table read timed out during initial boot. Its failed record is preserved. After the isolated probe checks, both per-command guards and the continuous monitor used the small public libproc probe. Workers do not share a guest, build directory, broker token or mutable IDB checkout. Existing runtime artifacts may be read from the saved candidate. Each native result must name the exact binary and source candidate.

## Assignments

| Workstream | Scope | State | Integration |
| --- | --- | --- | --- |
| Gestures and coordinates | Moving two-finger rotation during folding/device rotation; remaining outer landscape gesture and coordinate cases | Complete: two twist interruptions and eleven outer270 cases passed | Workers 4eeb969/10cfccc1 merged via 692fc013/628a4ecb |
| Hinge and hardware | Selected side-button, supported lock/wake observations, measured hinge transitions and fresh input | Complete: side-button, 18 hinge checks, nine stale-screen rejection/refind cases and two held-Space cleanup/refind sequences | Workers e3689e6b/80322d1b merged via f6690cb7/ea1de03a |
| Build and regression | Build the isolated Duo source, focused existing checks, ordinary iPhone/iPad checks, exact API/release gap report | Complete: 111 test functions/14 suites, ten host checks and 20 ordinary iPhone/iPad actions passed | Worker 33f48784 including def31458 merged via 86dafa84 |

Unrelated Agent and AXeCore changes remain outside the Duo checkpoint. Existing failed cases remain failed. A completed bounded check does not close a broad feature row. Missing polling, numeric slider values, agent selection and universal release support require separate source work; this round must report those limits rather than infer support.

## Acceptance and merge

The coordinator reviews each worker diff and raw result, checks the candidate identity and resource record, then merges accepted commits into main. Build checks establish compilation only. Native input acceptance requires a real app effect and released input. The accepted scope and remaining work are below.

Local source checkpoint: `f8bb51e9d64e87914fe020d6afff24c5c2ed2ace` on main. It contains Duo implementation/reports and excludes the unrelated agent edits and large raw evidence tree. SSH signing failed through 1Password; this local checkpoint is unsigned.

## Native resource probe

Repeated top/ps process-table reads timed out during startup. These failed monitor records are preserved; no memory limit was reached in them. New scripts/duo-resource-probe.c reads public libproc PID/PPID, ri_phys_footprint and cumulative CPU counters. Mach tick conversion uses the host timebase (125/3), as required by the [XNU fill_task_rusage implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c). No simulator state is changed.

The isolated probe matched1.1972 seconds against1.1949 seconds of POSIX process CPU. A touched48 MiB allocation raised its footprint48.7 MiB. Stable group totals were within0.14 GiB of a separate top snapshot. Probe calls took0.006 to0.298 seconds. scripts/guard-duo-command.py uses a5-second probe deadline, retains the same8/10/4 GiB and sustainedCPU limits, and stops before launch if sampling is unavailable. An owned deadline stop and an unavailable-probe/no-child case both passed. This does not prove every kernel-failure or process-creation race.

Build the probe with `xcrun clang -Wall -Wextra -Werror scripts/duo-resource-probe.c -o <probe-path>`. Run `python3 -B scripts/guard-duo-command.py --resource-probe <probe-path> --out <new-evidence-directory> --timeout <seconds> -- <command...>`. The coordinator and workers resumed only after isolated validation. The continuous monitor now uses this small native probe as well.

## Completed scope

- Moving two-finger twists stopped after a fold or device turn. Both touches released. Each case then found and tapped the current Button.
- Eleven outer270 cases passed: tap, hold, double tap, swipe, drag, pinch, twist, two-finger tap/hold and nested scrolling in both directions. The nested list moved 0 to70 to0 while the page stayed173.
- Selected standalone and batch side-button completed and released. Both changed the visible screen to date/clock wallpaper. No security-lock or power claim is made.
- Eighteen hinge observations included nine real screen switches. Each switch rejected input on the old screen with zero events, then found and tapped the Button on the current screen. The114/115-degree boundary is a measured session result, not a fixed product threshold.
- Held Space was interrupted once by opening and once by device rotation. Each returned owned release/drain, repeat stopped, and a new Button tap passed. The original fold wrapper remains failed because it required one character despite normal key repeat. Its separate read-only stability and first fresh tap are retained as bounded evidence. An independent OS key-up timestamp remains unavailable.
- The isolated Duo source built and passed 111 existing checks in14 suites. Twenty native portrait actions passed across ordinary iPhone/iPad and legacy/selected routes: Button tap,80-point swipe,field focus,literal text and Return. Ten host checks confirmed help and explicit rejection of unsupported options.

Checklist cells D03.MOVINGROTATION, D07, D08.NESTED.OUTER270, D09.OUTER270, D04.BOUNDARY, D11.HELDKEY, D12.SIDE.SELECTED and D16.CORE.CURRENT record these bounded results. Broad feature rows stay open for their stated gaps. The native candidate did not need a new product fix in this round. New tracked changes are verification tools, reports and the resource guard.

## Final verification and resources

On 21 October 2026, all five saved-data validators passed from the merged main checkout. Their exact commands and exit codes are saved in [final-validators.json](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/final-validators.json). Raw receipts, actual app effects, released contacts, candidate hashes and worker diffs were checked before each merge. No simulator input was repeated by these validators.

Across 114 saved guard records and 1170 samples, peak working memory was 7.096 GiB for the app group, 9.747 GiB for all simulators and 0.559 GiB for an owned command. The maximum simulator CPU sample was 1617.3 percent; no sustained CPU stop or memory stop occurred. These are sampled process-group totals, not a performance guarantee. The old top/ps monitor failed three times and those records remain. The separate deadline and missing-probe stops were intentional guard checks. All owned guard children were reaped.

Final host simctl inventory exited 0 and contained no booted guests. The first sandbox inventory could not connect to CoreSimulator; it sent no input. The separate host read passed. The native continuous monitor then exited 0 without signals and was reaped. Its last sample was app 6.361 GiB and simulator support 0.523 GiB/0.7percentCPU. [Full resource record](/Volumes/Developer/AXe/build_products/verification/parallel-duo-20261021/parallel-resource-summary.json).

The three worktrees remain attached to preserve the exact pinned build artifacts for saved-data validation. No worker, simulator check or monitor is left running. Unrelated Agent/AXeCore edits remain outside these commits. Local commits and merges are unsigned because 1Password SSH signing failed; no push occurred. Security scanning stays UNVERIFIED.

## Continuation: nested scrolling, retained pairs and held buttons

Cam requested these three checks in parallel, with native proof before a library merge. All three bounded checks are reviewed and merged. The retained-pair check exposed a native idle-release fault. Its isolated fix passed the framework build, CLI build, 31 focused cases, three native pair cases and one public retained-single regression before merge.

| Workstream | Result | Local integration |
| --- | --- | --- |
| Outer90 nested scrolling | Both 80-point paths passed. The list moved 0 to 70 to 0, all 30 AX row frames matched, the page stayed 173 and both contacts released. | Worker d3f3ac59 merged via abdffd29; D08.NESTED now records all seven supported fixed poses. |
| Held Home and side button | Four library interruptions and two public CLI interruptions passed. Each had owned typed release, drain, original-target identity and a separate fresh Button callback. | Worker 63237a66 merged via 3b7cdc64; bounded D12.HELD verified by fbee2034. |
| Retained library pairs | Normal begin/move/end passed. After opening or rotation, both contacts released during idle before any next move/end/close. Four old requests sent zero normal events. Three fresh Button taps and one public retained-single rotation/refind case passed. | Original fault cf06e393 merged via 17cd69c7; proved source fix 44876b1a merged via 664686f5. D09.RETAINED is verified for these cases. |

Reports: [nested scrolling](2026-10-21-duo-outer90-nested.md), [held hardware](2026-10-21-duo-held-hardware.md), [original retained pairs](2026-10-21-duo-retained-pairs.md), and [proved idle fix](2026-10-21-duo-retained-idle-fix.md). Candidate pins and raw evidence are in build_products/verification/parallel-duo-continuation-20261021. Saved-data validators send no simulator input.

The original audit guest remains shut down and quarantined after a cold rotation did not reach the requested state. No touch was attempted on that uncertain context. A fresh assigned guest supplied the nested proof. The separate outer Home rotation setup also did not reach a changed state; the held Home released normally. Its cause remains unproved. Neither original record was replayed or relabeled as a pass.

The retained-pair fold wrapper first failed on a privacy-safe primitive description check. The raw release receipt is retained, and a separate fresh Button check supplies its new-screen tail. Rotation supplies the repeated-old-token check. Later saved-data grading corrections preserve the original failed records.

The idle fix uses the existing local feed at 50 ms intervals only while live input is retained. It releases on the original connection. Close waits only for owned idle cleanup; normal concurrent caller execution still rejects as busy. Root reviewed the complete session change and focused checks, confirmed every unrelated foundation patch section was byte-identical, and checked the raw native contacts, original-target identity, guest barrier/drain and fresh AX coordinates before merge. The replay-free checker also passed independently.

The public regression first stopped at a bad tool option, then on a new boot at Apple's accessibility-session startup. Both sent zero touch events. The final fresh case used the same fix and corrected driver, unchanged timeouts, a bounded CPU readiness read, and one successful accessibility preparation read. It then passed the real public touch sequence. These results do not establish the cause of the earlier startup timeout. All original failed records remain failed.

Main's ignored IDB cache was first verified against all 60 previous pins. Root saved recovery copies, then advanced only the session, the new focused check source and the exact four-line generated project entry. All 61 new source pins and the reverse patch check passed through the existing command /bin/bash scripts/build.sh setup. See build_products/verification/parallel-duo-continuation-20261021/main-idb-integration.json and main-idb-setup-check. No compiled product was replaced. The accepted Debug CLI/framework remain in the idle-fix worktree; a main rebuild with the unrelated Agent edits was not attempted. Project copying is not an XcodeGen regeneration or release proof.

All owned guests were shut down. Final host inventory found zero booted guests; the original quarantine hash stayed unchanged. Both continuous samplers exited normally and were reaped. Per-command guards remained active for saved checks. Across this continuation, sampled peak footprints were app 7.849 GiB, all simulators 8.131 GiB and command 0.477 GiB. Simulator CPU peaked at 1581 percent for a sample; no sustained CPU stop or memory stop occurred. No guard child remained unreaped. The final resource ledger is build_products/verification/parallel-duo-continuation-20261021/continuation-resource-summary.json.

Security scanning and universal release remain UNVERIFIED. Local commits and merges are unsigned; no push occurred. Worktrees remain attached to preserve the pinned candidate builds.

## Remaining work

The requested outer90 nested paths, retained-pair idle fix and six bounded held-button cases are complete. Wider role, option and transition combinations remain open. Source gaps include selected tap polling, arbitrary slider values and native semantic switch activation. Agent screen selection, media during folding/rotation, explicit lock/wake/power and universal release packaging remain separate open items. The build report gives a concrete implementation and acceptance plan for each option/release gap. No full Duo parity or release-readiness claim is made.
