# Duo parallel work: 21 October 2026

Cam authorized isolated worktrees, simulator copies, coordinator review and local merges into main. No push or security scan upload is authorized. All three workstreams are complete and reviewed. Their commits are merged into local main. The implementation checklist remains the capability record.

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

## Remaining work

Core verification still includes outer90 nested scrolling, retained library pairs, held hardware buttons and wider role/option/transition cases. Source gaps include selected tap polling, arbitrary slider values and semantic switch activation. Agent screen selection, media during folding/rotation, explicit lock/wake/power and universal release packaging remain separate open items. The build report gives a concrete implementation and acceptance plan for each option/release gap. No full Duo parity or release-readiness claim is made.
