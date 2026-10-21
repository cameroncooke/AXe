# Duo parallel work: 21 October 2026

Cam authorized isolated worktrees, simulator copies, coordinator review and local merges into main. No push or security scan upload is authorized. This record tracks this round; the implementation checklist remains the capability record.

## Resource limits

The Mac has 36 GiB of physical RAM. The common guard measures working memory and aggregate CPU. Limits are 8 GiB for the ChatGPT/Codex process group, 10 GiB for all simulator processes together and 4 GiB for each owned command group. Simulator CPU at least 1200% for 20 seconds stops owned work. At most two assigned guests may be booted, with staggered startup. At most one build may run, with two jobs. A stopped command must be reaped; its owner must shut down its guest after a resource stop.

The coordinator alone grants simulator and build slots. Workers do not share a guest, build directory, broker token or mutable IDB checkout. Existing runtime artifacts may be read from the saved candidate. Each native result must name the exact binary and source candidate.

## Assignments

| Workstream | Scope | State | Integration |
| --- | --- | --- | --- |
| Gestures and coordinates | Moving two-finger rotation during folding/device rotation; remaining outer landscape gesture and coordinate cases | Preparing isolated worktree | Pending |
| Hinge and hardware | Selected side-button, supported lock/wake observations, measured hinge transitions and fresh input | Preparing isolated worktree | Pending |
| Build and regression | Build the isolated Duo source, focused existing checks, ordinary iPhone/iPad checks, exact API/release gap report | Preparing isolated worktree | Pending |

Unrelated Agent and AXeCore changes remain outside the Duo checkpoint. Existing failed cases remain failed. A completed bounded check does not close a broad feature row. Missing polling, numeric slider values, agent selection and universal release support require separate source work; this round must report those limits rather than infer support.

## Acceptance and merge

The coordinator reviews each worker diff and raw result, checks the candidate identity and resource record, then merges accepted commits into main. Build checks establish compilation only. Native input acceptance requires a real app effect and released input. The final handoff will state merged commits, completed checklist rows and exact remaining work.
