# Duo parallel work: 21 October 2026

Cam authorized isolated worktrees, simulator copies, coordinator review and local merges into main. No push or security scan upload is authorized. This record tracks this round; the implementation checklist remains the capability record.

## Resource limits

The Mac has 36 GiB of physical RAM. The common guard measures working memory and aggregate CPU. Limits are 8 GiB for the ChatGPT/Codex process group, 10 GiB for all simulator processes together and 4 GiB for each owned command group. Simulator CPU at least 1200% for 20 seconds stops owned work. At most two assigned guests may be booted, with staggered startup. At most one build may run, with two jobs. A stopped command must be reaped; its owner must shut down its guest after a resource stop.

The coordinator alone grants simulator and build slots. The extra continuous sampler stopped after a process-table read timed out during initial boot. Its failed record is preserved. Per-command guards continue to measure the combined process groups; the coordinator collects their samples, which avoids a further concurrent process scan. Workers do not share a guest, build directory, broker token or mutable IDB checkout. Existing runtime artifacts may be read from the saved candidate. Each native result must name the exact binary and source candidate.

## Assignments

| Workstream | Scope | State | Integration |
| --- | --- | --- | --- |
| Gestures and coordinates | Moving two-finger rotation during folding/device rotation; remaining outer landscape gesture and coordinate cases | Two twist interruptions and five outer270 cases passed; six further outer270 cases now assigned slot A | Worker4eeb969 reviewed and merged |
| Hinge and hardware | Selected side-button, supported lock/wake observations, measured hinge transitions and fresh input | Standalone/batch side-button,18 hinge checks and nine stale-panel rejection/refind cases passed; held keys running | Worker e3689e6b reviewed and merged |
| Build and regression | Build the isolated Duo source, focused existing checks, ordinary iPhone/iPad checks, exact API/release gap report | 111 test functions/14 suites, ten host boundary checks and20 ordinary iPhone/iPad actions passed; final saved review pending | Pending |

Unrelated Agent and AXeCore changes remain outside the Duo checkpoint. Existing failed cases remain failed. A completed bounded check does not close a broad feature row. Missing polling, numeric slider values, agent selection and universal release support require separate source work; this round must report those limits rather than infer support.

## Acceptance and merge

The coordinator reviews each worker diff and raw result, checks the candidate identity and resource record, then merges accepted commits into main. Build checks establish compilation only. Native input acceptance requires a real app effect and released input. The final handoff will state merged commits, completed checklist rows and exact remaining work.

Local source checkpoint: `f8bb51e9d64e87914fe020d6afff24c5c2ed2ace` on main. It contains Duo implementation/reports and excludes the unrelated agent edits and large raw evidence tree. SSH signing failed through 1Password; this local checkpoint is unsigned.

## Native resource probe

Repeated top/ps process-table reads timed out during startup. These failed monitor records are preserved; no memory limit was reached in them. New scripts/duo-resource-probe.c reads public libproc PID/PPID, ri_phys_footprint and cumulative CPU counters. Mach tick conversion uses the host timebase (125/3), as required by the [XNU fill_task_rusage implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c). No simulator state is changed.

The isolated probe matched1.1972seconds against1.1949seconds of POSIX process CPU. A touched48MiB allocation raised its footprint48.7MiB. Stable group totals were within0.14GiB of a separate top snapshot. Probe calls took0.006 to0.298seconds. scripts/guard-duo-command.py uses a5-second probe deadline, retains the same8/10/4GiB and sustainedCPU limits, and stops before launch if sampling is unavailable. An owned deadline stop and an unavailable-probe/no-child case both passed. This does not prove every kernel-failure or process-creation race.

Build the probe with `xcrun clang -Wall -Wextra -Werror scripts/duo-resource-probe.c -o <probe-path>`. Run `python3 -B scripts/guard-duo-command.py --resource-probe <probe-path> --out <new-evidence-directory> --timeout <seconds> -- <command...>`. The coordinator and workers resumed only after isolated validation. The continuous monitor now uses this small native probe as well.
