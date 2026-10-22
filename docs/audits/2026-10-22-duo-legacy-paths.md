# Duo no-flag swipe and drag checkpoint

Date: 22 October 2026. Base main: 55939716fdb619e33528b94a3b2e5c643e6134bf. Branch: codex/agent-mode. Status: isolated checkpoint; not accepted for main integration.

## Checklist

- [x] Reproduce ordinary swipe and drag failures at inner display 3, rotation 270. Both exit successfully with no touch or app effect; selected controls at the same logical points work.
- [x] Route ordinary Duo swipe/drag through the measured owner, with the existing event factories and original logical points. Other-device routes stay in place.
- [x] Preserve swipe floor-based spacing, initial dwell and repeated end anchor; preserve drag steps and 0.05-second end holds. Keep host pre/post waits and normal output.
- [x] Require the verified Duo profile and matched captured context in the broker. Reuse the owned session, live context feed and client-disconnect cancellation.
- [x] Build candidate v2 and complete one review/fix round. The missing server-side profile gate was fixed and reviewed again.
- [x] Observe actual app movement, correct endpoints and touch release in all 14 swipe/drag cases across the seven supported poses on v2.
- [x] Observe the 1000-step drag, nominal 1001-move swipe, and 11-second movement with 10-second pre/post waits.
- [x] Pass 164 existing checks in 18 suites, with one compiler job. Both guide directories pass strict offline validation. Security scanning remains UNVERIFIED per Cam.
- [ ] Repeat acceptance on a stable simulator. PosterBoard was crashing during this guest session.
- [ ] Complete a path beyond the prior 120-second response timeout.
- [ ] Prove the new no-flag path stops and releases during folding, rotation and client signals, then find and tap the element again.
- [ ] Prove ordinary-device route compatibility and direct-wire non-Duo rejection.
- [ ] Integrate into main, build that combined tree and prove its affected native paths.

## Candidate and evidence

Candidate v2 CLI SHA256: bc248eea9c9f1b6445e01b8ccda5ee72bedc4ed373ce76b99af36e12d7ad00e4. Native framework inputs are unchanged. Internal selected wire25 rejects wire24. Source pins, exact argv, app state and touch traces are under build_products/verification/legacy-paths-20261022/.

Records: baseline/verification.json; green-v2/verification.json; options/verification.json; build-2/result.json; existing-tests/stdout; tests.json; skill-validation.json; candidate-v2-pins.json. The first v1 matrix is retained separately. No injected fixture state or hidden product route was used. Fixture v6 binary SHA256: a6f06c6f7be48ba97ef28cb1f89ed626fa7f6c40bec3e2054f59cdbeed12afe7.

The new compact Duo swipe request has a 100000-move allocation ceiling. Existing drag1...1000 steps remain. Original selected-path and ordinary primitive limits are unchanged. The response wait for this legacy path is its requested movement duration plus120seconds; other selected requests keep120seconds. That calculation is source/build reviewed; native completion beyond120seconds remains pending. No new automated test was added.

These context checks do not add app/PID or UI-layout freshness. Equal sampled contexts do not prove no complete out-and-back change occurred between reads.

## Simulator incident

Cam reported repeated PosterBoard crashes and a flashing Chrome Handoff Dock icon. The repeated crash reports identify the audit guest 1DF98D02-3F41-4696-A99F-42DBD4369A73 and the same EXC_BREAKPOINT in Apple's PRPosterDescriptor _initWithPath during wallpaper-store setup. Reports predate this candidate; the exact bad file and cause are not established. The guest was shut down immediately.

A fresh stock Duo EEEC0A86-3285-422E-98D8-9F54DCEF09D4 had no observed PosterBoard report in a30-second idle check without AXe or the fixture. Its bootstatus output nevertheless said Data Migration Failed despite exit0. This is not accepted as a healthy boot. It was shut down. A new ignored crash-aware guard can stop an owned guest on a new PosterBoard report; its first-crash branch has not yet been exercised by a real new crash. No further native input ran after the incident.

Chrome's main process65610 had been running since21October10:09:41. This task sent no Chrome launch/navigation command. Cam confirmed the Handoff icon stopped after both audit Duo guests were off. This strongly links the flicker to simulator activity; the exact Handoff origin is not proven. No global Handoff setting was changed. A read-only Dock inspection timed out.

Incident records: incident-status.json, incident-crash-summary.json, incident-stop.json, incident-booted-devices.json, incident-handoff-summary.json, fresh-idle-commands.json and fresh-idle-guard/. The installed native Xcode bundle reports27.2. The unrelated running iPhone18Pro was preserved.

## Resources and integration

Fixed limits remained8GiB for the app group,10GiB for all simulator processes and4GiB for the owned command group. Sustained20-second CPU stops remain1200percent for simulators and400percent for owned commands. Resource peaks: app 7.832GiB; all simulators 7.247GiB; owned commands 0.323GiB. All guarded children were reaped. CPU/memory limits did not detect the service crash loop; crash detection is now a separate requirement.

No path change is merged into main. Its14 unrelated file states are preserved. No push. This checkpoint is a recovery point, not a readiness claim.
