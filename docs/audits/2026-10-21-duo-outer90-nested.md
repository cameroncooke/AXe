# Duo outer90 nested scrolling

Date: 21 October 2026. Both assigned nested-scroll cases passed on a clean replacement Duo. No product change or build was needed. The original audit guest remains shut down with its input quarantine intact after a failed cold rotation setup.

## Verified scope

At closed outer1/AX1/HID1, rotation90 and hinge0:

| Case | Native result |
| --- | --- |
| Nested up | One complete80-point vertical contact moved the nested list0 to70. All30 accessibility row frames moved by exactly the measured offset, within0.5 logical point. |
| Nested down | The reverse80-point contact moved the list70 to0. All30 row frames returned. |

Both cases kept the page offset at173, preserved the other controls and pad state, matched the current app PID/container, reached the requested contact endpoints and released the contact. Final accessibility geometry and selected-screen context matched the initial description. There were zero held touches.

The entire list frame was visible before each action. One separate public page swipe began on the ordinary StaticText feature.switchLabel and moved the page0 to173. It did not scroll the nested list, invoke a pad/control recognizer or change other controls. No fixture state was injected or reset. The actual page/contact traces and fresh final frames were checked before nested input.

## Candidate and replacement

- Main workstream base: f6e262d14cd944c91fabc615431474b546d97a0e. Product source and canonical binaries unchanged.
- CLI SHA256: 5f4e71958447de644fea1e2a2844518d7b177598e9050393cd56374e039e17c4.
- FBSimulatorControl SHA256: 8a614ab3116b3d0b88e21086d8a16d0f39aa06f672dd92123b7fd00e7526b779. Wire21, Debug arm64.
- Clean device created through simctl: AXe Duo Nested Continuation, UDID1DF98D02-3F41-4696-A99F-42DBD4369A73. Same iPhone-Duo type and iOS27.2-iPhone19-4 runtime as the original. It was not a state clone.
- Existing normal UIKit fixture6 installed unchanged. Executable SHA256: a6f06c6f7be48ba97ef28cb1f89ed626fa7f6c40bec3e2054f59cdbeed12afe7.
- Accepted boot8436:1792584942:96752, PID9100, screen UUIDF295194B-EEF6-4F11-98C6-316A1B28F941. These are historical identities after shutdown.

The fixture was launched and its current UI/AX tree read at portrait before one public rotate-right operation selected outer90. A new catalogue and AX description then bound the two scrolling cases. The initial state had zero held touches. This is ordinary app and simulator setup, not an input replay.

## Failed original setup remains failed

On the original audit UDID3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463, a cold public rotation operation sent one device request but did not observe its requested selected rotation twice within the existing budget. Its receipt is failedNoReplay with uncertain delivery and a persisted uncertainRotationDelivery quarantine. A later catalogue observed outer90. The following read-only AX setup was rejected before input by ownership quarantine, with zero HID events. No nested gesture ran on that guest.

The original was shut down. Its quarantine was copied for evidence and left unchanged in place. No rotation was replayed and no timeout changed. The current source blocks input when that record exists; it has no public CLI recovery command. A reboot alone does not clear the record. The coordinator authorized a clean duplicate for the bounded scrolling work. The successful replacement cases do not recover the original or regrade its failed rotation. The cold setup failure's cause remains unproved.

## Evidence and verification

Evidence root: /Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/outer90-nested.

Accepted case folders: outer90-nested-up/check and outer90-nested-down/check. Normal page preparation: expose-list/check. Failed original setup: turn90 and setup. original-quarantine.json is an unchanged copy with its original path/hash recorded separately. All command arguments, owned child exits, state traces, AX descriptions and resource samples are saved.

Latest exact saved-data command from the gesture worktree, exit0:

    /usr/bin/python3 -B scripts/check-duo-outer90-nested-evidence.py --current --evidence-root /Volumes/Developer/AXe/build_products/verification/parallel-duo-continuation-20261021/outer90-nested

It sends no input. It checks89 source/runtime files, one fixture executable, eight tools, actual contact/effect grading, all30 row displacements in both directions, normal page setup, original failed receipts and the preserved quarantine. The two accepted cases each have successful wrapper results and reaped child processes. The failed original setup wrappers keep their nonzero exits. Prior evidence and tool pins were not changed.

## Resources and handoff

The shared public libproc guard measured combined ChatGPT/Codex and all simulators. Limits stayed8GiB app,10GiB simulators,4GiB owned commands, with20-second sustained CPU limits of1200percent for simulators and400percent for owned commands. At most two guests were booted; this worker sent one action at a time. No build ran.

Including the preflight sample, peaks were app7.338GiB, all simulators8.127GiB and simulator CPU1362.1percent. CPU peaks were brief. No memory, CPU, time or monitor stop occurred. These totals include the other worker and are not per-guest estimates.

The replacement shut down immediately after the second case and its slot passed back to the coordinator. The saved final catalogue had only the other worker's guest booted; both this replacement and the original were shut down. Final combined sample: app7.016GiB, simulators3.963GiB/23.3percent CPU. The original quarantine remains a separate recovery issue.

This closes the specified outer90 nested up/down cells. Wider options, retained pairs, hardware-button input and release packaging remain separate work. No production, skill or central checklist change in this branch. No push or security upload. Security scanning remains UNVERIFIED per Cam.
