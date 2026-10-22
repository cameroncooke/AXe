# Agent keyboard evidence checkpoint: 22 October 2026

Status: isolated on codex/duo-regression, based on main4f684bec. Not merged or accepted as native Duo support.

Agent captures add keyboard evidence from the existing bounded selected-app tree, with likelyVisible or unknown state and distinct signal counts. Hidden ancestry and off-screen frames are excluded. Absence does not mean OS keyboard-hidden state; this does not prove focus or alter typing. Fresh, reused, paged and post-action captures share the same builder. Exact native fingerprint/context checks retain cache validity. No raw output or native query is added.

Decisions: keep the useful sim-use signal heuristic but expose its uncertainty. Do not let it authorize typing. Preserve its Apache2 source attribution and distribute pinned LICENSE/NOTICE with an adaptation record, without changing AXe root MIT licence. Package.swift copies the new licence resource folder.

Validation ran against final source before this checkpoint. Exact argv, framework hashes and records: /Volumes/Developer/AXe/build_products/verification/agent-keyboard-20261022.

- Three changed/new Swift files passed syntax parsing.
- Both guide directories passed strict offline skill-check and quick_validate; security scan remains UNVERIFIED per Cam.
- Single-job arm64 build passed with existing accepted native frameworks.
- All three licence/notice/adaptation files were found byte-identical in the built AXe resource bundle.
- App footprint peak7.754GiB; simulator4.223GiB; owned command0.296GiB. No resource stop; guarded commands reaped.

Native acceptance remains open: keyboard show/hide with fresh captures; unchanged/paged/replacement captures; folding/rotation/cache changes; non-Latin and hardware-keyboard cases; ordinary Buttons that resemble keys; raw-output comparison; combined main integration. No simulator or native capture ran. Existing input-suite results from the separate selector candidate do not count as detector tests.
