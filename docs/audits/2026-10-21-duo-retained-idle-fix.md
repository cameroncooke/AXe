# Duo retained-input idle release: isolated fix and native proof

Date: 21 October 2026. This fixes the missing owned idle release found in
`2026-10-21-duo-retained-pairs.md`. It does not establish complete Duo support.

## Problem and change

The original library checked for a changed device before the next caller action.
It did not check while a caller held retained contacts and sent no new request.
The saved rotation failure showed two real app contacts still down after one
second. Folding canceled the app contacts, but the library still retained its
pair and token. Those original failures remain unchanged.

The isolated `FBSimulatorHIDSession` change adds one weak-reference task only when
a live retained contact and token exist. Every 50 ms it checks the existing local
live feed. It starts no full context, accessibility, or process read. A caller
operation keeps ownership of admission; the monitor skips that operation and
the caller keeps its existing freshness checks.

On a changed idle feed, the actor owns admission and uses the existing interruption
and cleanup code. That code sends releases on the original connection and keeps
the existing identity, guest barrier, drain, timeout, and uncertain-result rules.
It clears contacts and token before invalidation. End, close, interruption, or
loss of retained input stops the task. A generation identity prevents an old
task from operating on a later retained contact. The task does not retain the
session across sleeps.

`close()` waits only for an owned idle cleanup already in progress. It still
rejects concurrent caller execution as busy. This prevents the public single-touch
owner from treating the library's idle cleanup as a failed close and entering
quarantine. Cleanup completes and signals waiting closes before the monitor task
is canceled. There is one release attempt, not a second UP from each close.

Only the library session source changes in production. No public command, option,
wire version, timeout, private-framework configuration, or owner policy changed.

## Exact isolated candidate

| Item | Value |
| --- | --- |
| Worktree | `/Users/cameron/.codex/worktrees/duo-pair-idle/AXe` |
| Branch | `codex/duo-pair-idle` |
| Source base | `17cd69c7adc6db27a6317697b215adb76c46e9fd` plus the tracked patch change |
| IDB base | `604c51013438f0c3603b720a05a44b7c5b8f286d` in the isolated worktree checkout |
| CLI SHA-256 | `09afcf56b664c5712f37f91f18252f64c56552a3eb917e5aef76b30e74c062bc` |
| FBSimulatorControl SHA-256 | `de27c2cedaeeef2415a0a257c9fa417dd62cbf7fea000a2b1c27f232a574fe3d` |
| Session source SHA-256 | `b66ada2cc80ef8c142fa39fc6da973954e9723c298199be747dfd7d7ed54cb5b` |
| Pair probe SHA-256 | `1b31a36e64bc02e9b26ae14522bb09c6e6c794c404fd73e27780a4fa8d326b9e` |
| Fixture executable SHA-256 | `a6f06c6f7be48ba97ef28cb1f89ed626fa7f6c40bec3e2054f59cdbeed12afe7` |
| Product | Debug, arm64, wire 21 |
| Compiler | `/Applications/Xcode-27.0.0-Release.Candidate.app/Contents/Developer` |
| Simulator runtime selection | `/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer` |
| Owned Duo | `1DF98D02-3F41-4696-A99F-42DBD4369A73` |

Runtime products are in the new worktree `.build/out/Products/Debug`. The old
regression worktree, CLI, probe, frameworks, and original proof were not changed.
The pre-boot manifest `pairs-idle-pins.json` freezes 19 source, runtime, helper,
tool, and fixture files with independent copies. Each native case saves another
set before it launches native commands. The final saved-evidence validator has
separate provenance; its hash is not added to that pre-boot manifest.

No XcodeGen executable was available. The generated project was copied from
the main IDB checkout, original SHA-256
`366a059dbc9ade481d2feda4fa11b4cd1f454cf9c7ff29be8faf08c0a77dbc0a`.
Four local project entries include the new focused test file. The existing
`project.yml` already includes the entire test directory. This is a copied and
locally extended project, not a regenerated project. See
`pairs-idle-project-provenance.json`.

The tracked foundation patch keeps its previous header, section order, and every
unchanged section byte for byte. Its regenerated session section and new test
section are the only changes. Reverse-apply validation and all 61 source hashes
passed. All 60 old source files except the intended session change retain their
previous content. The new test source is part of the patch.

## Focused and existing checks

The one-job arm64 framework build passed in 52.37 seconds. The library checks
passed in 11.90 seconds: 17 Swift Testing functions with 22 argument cases, plus
9 existing XCTest transport cases, for 31 cases total.

The new suite covers live single and paired idle release, no full-read polling,
two close calls joining one idle cleanup, busy rejection during normal caller
execution, stopped checks after end and close, weak session lifetime, preserved
uncertain cleanup, and the unchanged non-live retained-input contract. Existing
keyboard admission, held-delay interruption, and event transport checks also ran.

The isolated CLI build passed in 27.56 seconds. The accepted pair probe source was
compiled against the new framework in 1.85 seconds. All exact commands are saved
in the matching guard `started.json` files.

## Native checks

Each pair first started two distinct actual app contacts and moved both while
both remained down. Each changed case saved `pre-next-command.json` before
allowing any old move, end, or close.

| Case | Evidence and result |
| --- | --- |
| Normal retained pair | Contacts 1/2, outer screen 1, portrait, hinge 0. Begin, move, end: 3 normal paired primitives; token clear; both contacts released; fresh named Button callback increased by one. |
| External opening | Contacts 4/5, hinge 0 to 180, outer screen 1 to inner screen 3 at 90 degrees. During idle: actual held count 0; library invalidated with no retained contact; 1 owned paired UP, original target identity, guest barrier and drain confirmed. Cleanup finished at uptime 174885.6443, before idle snapshot 174886.8203. Both later old moves rejected with 0 normal events and no second release. Fresh Button callback increased by one. |
| External rotation | Contacts 7/8, inner screen 3, 90 to 180 degrees. During idle: actual held count 0; library invalidated with no retained contact; 1 owned paired UP with original identity, guest barrier and drain. Cleanup finished at 174953.3453, before idle snapshot 174955.7874. Both later old moves rejected with 0 normal events and unchanged cleanup. Fresh Button callback increased by one. |
| Public retained-single owner | Fresh boot, PID 42772, outer screen 1, portrait to 90 degrees. Public `touch` began and moved contact 1. The app reported Cancelled and 0 held contacts before the next request. The old token rejected with 0 events; the same broker remained usable without quarantine. A fresh named Button callback increased by one. Both tap points were exactly 297,161, the center of fresh frame 12,142,570,38; the tap ended. The fixture PID was checked again afterward. |

Pair cases used fixture PID 34158 and boot `33000:1792588088:725500`. The final
public case used boot `42408:1792588925:652140`. All named taps used a new active
panel lookup and a fresh accessibility frame. The saved validator checks each
actual point against that frame with a strict error below 0.5 logical point.
All final app contact counts were zero. The assigned guest was shut down.

The public event description hides the pair direction:
`TwoFingerTouch <hidden>`. The UP claim is bound to the exact pinned cleanup
source, which passes `.up` and maps the pair to `twoFingerTouch`. Token clearing
is also bound to that source and the retained state and old-request results.
The public single-owner case does not expose the library's idle cleanup receipt;
its proof is the actual release, clean old-token rejection, same broker, fresh
tap, and focused close-join checks.

## Preserved failures and readiness

- Two tiny probe compilation attempts were held before the compiler because the
  fresh app sample was at or above the approved 7 GiB starting threshold.
- The next probe compilation used the wrong SwiftPM framework directory and
  failed before input. The corrected `.build/out/Products/Debug` path passed.
- Public-single version 1 supplied `--expected-pid` to raw `touch`, which does
  not have that option. The parser rejected it before any touch. The corrected
  driver keeps PID binding for discovery and named taps and checks the PID again.
- The next fresh boot timed out while creating the simulator accessibility
  automation session. Its receipt is `failedBeforeInput`, cleanup `notNeeded`,
  event count 0. No touch began. The guest was shut down.

The final authorized fresh case kept all source and timeouts unchanged. A bounded
read-only phase required simulator CPU below 200 percent for 10 seconds, with a
60-second deadline. It completed in 38.61 seconds with 10.17 seconds stable and
2.20 percent CPU at the last sample. Exactly one selected accessibility readiness
read then passed in 4.82 seconds with 0 input events. The unchanged corrected
driver then passed the public case in 12.27 seconds. No uncertain input was replayed.

## Resources, integration and limits

All heavy and native commands used the common public-libproc guard. Limits stayed
at app 8 GiB, all simulators 10 GiB, and owned command 4 GiB. Sustained CPU limits
stayed at 1200/400 percent over 20 seconds. Builds used one job with all guests
off and a separate starting app gate below 7 GiB. Native input required a fresh
app sample below 7.75 GiB. Only the assigned guest ran in this round.

Across the fix per-command guard records, sampled peaks were app 7.829 GiB, all simulator groups
4.885 GiB, and owned command 0.477 GiB. No resource limit stop occurred. The last
shutdown sample was app 7.144 GiB and simulator groups 0.595 GiB. These are sampled
physical footprints, not RSS sums.

The worker kept the main ignored IDB checkout read only and confirmed all 60
previous source pins. After source merge `664686f5`, the coordinator saved recovery
copies and advanced only the session, the new focused test source and the accepted
four-line generated project entry. The existing `/bin/bash scripts/build.sh setup`
command passed all 61 new source hashes and the reverse patch check. The record is
`main-idb-integration.json` in the evidence root. Existing binary products stay
unchanged; no main rebuild with unrelated Agent edits was attempted.

This evidence covers the stated retained-input gap and regression paths. It does
not prove every Duo pose or every public feature. Fresh Debug compiled modules
were used; distribution interfaces, universal release, notarization and release
remain unverified. The security scan remains UNVERIFIED.

## Saved verification

Evidence root:
`/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021`.

Run from this worktree; this starts no simulator and sends no input:

```sh
/usr/bin/python3 -B scripts/verify-duo-retained-idle-evidence.py \
  /Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021 \
  --current
```

The first saved check passed in 0.20 seconds. Its result is
`pairs-idle-main-result.json`, status `RETAINED_IDLE_FIX_BOUNDED_NATIVE_VERIFIED`.
The validator retains the failed attempts as failed and checks the fresh public
tap coordinates and final PID. Omit `--current` to validate the saved copies
without requiring the original runtime paths to remain unchanged.
