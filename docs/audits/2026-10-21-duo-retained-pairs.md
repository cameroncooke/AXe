# Duo retained library pairs: bounded proof and idle-release gap

Date: 21 October 2026. No production code changed in this checkpoint.

The library can retain two contacts, move both, and release both. After an
external fold or rotation, the next old move sends no normal input and releases
the original owned pair. A fresh named Button tap then works in the new screen
space. **Automatic release while the caller is idle is missing.** Rotation left
both actual app contacts down during the one-second idle observation.

## Candidate and boundary

The Swift probe uses the existing library boundary:
`FBSimulatorHIDNativeFreshnessProvider.start`,
`FBSimulatorHIDSession.open(liveFreshnessProvider:)`, `beginTwoFinger`,
`moveTwoFinger`, `end`, `status`, `cleanupEvidence`, and `close`.
It adds no production input route. A separate process changes the hinge or
rotation through the existing device-state API. It sends no touch input.

| Item | Exact candidate |
| --- | --- |
| Worktree | `/Users/cameron/.codex/worktrees/duo-regression/AXe` |
| Proof source base | `f6e262d14cd944c91fabc615431474b546d97a0e` |
| CLI build source base | `f8bb51e9d64e87914fe020d6afff24c5c2ed2ace` |
| CLI SHA-256 | `a476d2aa0d62170c7223040a35f411c57851dff4b37c307a3bbc89ca9310f153` |
| FBSimulatorControl SHA-256 | `8a614ab3116b3d0b88e21086d8a16d0f39aa06f672dd92123b7fd00e7526b779` |
| Pair probe SHA-256 | `4a16372187123aecca149b8662252446029a58ba5f2b2a392470df1beaacc471` |
| IDB base | `604c51013438f0c3603b720a05a44b7c5b8f286d` plus the pinned foundation patch |
| Product | Debug, arm64, wire version 21 |
| Compiler | `/Applications/Xcode-27.0.0-Release.Candidate.app/Contents/Developer` |
| Runtime selection | `/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer` |
| Assigned Duo | `1DF98D02-3F41-4696-A99F-42DBD4369A73` |
| Fixture | Version 6, PID `12430` |
| Boot | `10440:1792585131:728010` |

The CLI and frameworks stay in the frozen worktree `.build/out/Products/Debug`.
`pairs-pins.json` records 20 source, tool, helper, and framework hashes, with
independent saved copies in `pairs-candidate`. The probe records the actual loaded
framework path. These results do not prove a release or universal build.

## Native results

Each case first reads the active panel and fresh accessibility geometry. The
fixture records two distinct actual contacts before and after their move. There
is no injected app state, contact reset, or input replay.

| Case | Actual start and move | Idle after change, before any next action | Next old request and fresh action |
| --- | --- | --- | --- |
| Normal, outer screen 1, portrait | Contacts 1 and 2 began and moved while both were down | No external change | End released both; token cleared; 3 normal paired primitives total; fresh Button count 0 to 1 |
| Open from hinge 0 to 180 degrees; outer screen 1 to inner screen 3 at 90 degrees | Contacts 4 and 5 began and moved while both were down | After 1 second, UIKit had canceled both contacts. Library still retained the pair; cleanup evidence was absent | First old move: `staleContext`, 0 normal events, confirmed owned paired release. Separate fresh Button count 1 to 2 |
| Inner screen 3, 90 to 180 degrees | Contacts 7 and 8 began and moved while both were down | After 1 second, both actual app contacts and library pair remained held; cleanup evidence was absent | First old move: `staleContext`, 0 normal events, confirmed owned paired release. Second old move: `invalidated`, 0 events, no second release. Fresh Button count 2 to 3 |

The rotation idle result is a native failure of automatic idle release. It must
not be counted as a complete retained-pair feature. The normal lifecycle and the
cleanup on the next stale move passed their stated checks.

For both changed cases, the release receipt binds the original boot, screen UUID,
native width and height, and scale before and after release. It records one
paired cleanup primitive, a successful `IndigoDigitizerEvent` enqueue, a completed
guest barrier, and a completed drain. Normal-event count stays at 2. Cleanup
events have separate evidence and do not increase that normal count.

The public primitive description is `TwoFingerTouch <hidden>`. It hides the
direction. The paired UP claim is bound to the pinned library source:
`cleanupContacts` appends `Self.event(contacts, direction: .up)`, and the pair
case maps to `twoFingerTouch` with that direction. The report does not infer UP
from the hidden description alone.

Every fresh Button tap uses a new panel lookup and accessibility frame, matches
the expected PID, changes the real callback count by one, and ends its contact.
The final app readback has zero held contacts. The guest was then shut down.

## Preserved failures and limits

The original fold driver failed after the first old move. Its description check
expected the wrong letter case. The raw receipt already contained the successful
paired cleanup. The stopped probe ran owned close, closed its live feed, and was
reaped. The original wrapper result stays failed.

The fold was not repeated. The corrected source-bound check grades the saved
receipt. A separate public fresh Button check completes its new-screen tail.
`pairs-fold-joined-result.json` records that boundary. **The second old-token
request did not run in the fold case.** Rotation supplies that check.

The first two saved-evidence validator runs also failed because of validator
assumptions: one incorrectly expected rotation to cancel the app contacts; the
next expected a post-rejection file that the stopped fold driver never wrote.
Those failed command records remain in `pairs-evidence-check` and
`pairs-evidence-check-v2`. Version 3 checks the exact saved boundaries and passed.
No new native action was used to resolve these grading errors.

This is three bounded cases, not all pose, screen, contact-count, or API coverage.
No automatic idle-release fix is included. The security scan remains UNVERIFIED.

## Tools and repeatable saved-evidence check

- `scripts/probes/DuoRetainedPairProbe.swift`: standalone existing-library probe;
  explicit guest, boot, panel, and marker gates; owned close on driver abort.
- `scripts/verify-duo-retained-pairs.py`: one native case per command; no retries;
  real contact readback, stale requests, fresh public Button action, PID checks.
- `scripts/verify-duo-retained-pairs-evidence.py`: saved-evidence validation only;
  starts no simulator and sends no input.

Evidence root:
`/Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021`.

Run from the proof worktree:

```sh
/usr/bin/python3 -B scripts/verify-duo-retained-pairs-evidence.py \
  /Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021 \
  --current
```

Omit `--current` to check the saved copies without requiring the original runtime
paths to remain unchanged. The result is `pairs-main-result.json`, status
`RETAINED_PAIR_BOUNDED_PROOF_WITH_IDLE_GAP`. The validator checks original failed
receipts too; its success does not change their status.

Exact native commands and process identities are in each case's process receipts
and each guard's `started.json`. Probe compile commands are in
`pairs-compile-v1/started.json` and `pairs-compile-v2/started.json`. The v1 source,
binary, and original driver are preserved separately. Only v2 probe ran input.

## Resource control

All builds and native command groups used the common guard and public libproc
resource probe. Caps stayed at 8 GiB for the app group, 10 GiB for all simulator
groups, and 4 GiB for the owned command. Sustained CPU caps stayed at 1200 percent
for simulators and 400 percent for the owned command over 20 seconds. Before
each new pair, a separate sample required app memory below 7.75 GiB.

No command reached a resource stop. Across all pinned build/setup/native groups,
sampled peaks were app 7.536 GiB, all simulators 8.107 GiB, and owned command
0.042 GiB. The maximum shared simulator sample during the four input groups was
7.523 GiB. These are sampled physical-footprint values, not summed RSS.

The saved-evidence v3 check completed in 0.09 seconds, exit 0, with no input or
simulator start. It sampled app 6.630 GiB and simulator groups 0.593 GiB.

## Next isolated fix acceptance

Use the existing local live feed to detect the stale retained session while the
caller is idle. Serialize cleanup with begin, move, end, and close. Preserve the
existing original-target identity, barrier, drain, and uncertain-cleanup rules.

For each fold and rotation case, first prove two actual contacts began and moved.
Then prove the library releases both owned contacts, clears retained state, and
records confirmed cleanup **before any new move, end, or close**. Only after that,
an old request must reject with zero events and a fresh named Button must work.
The normal lifecycle and relevant existing checks must still pass. This fix must
use a new worktree, build, and isolated dependency source so the evidence above
stays unchanged.
