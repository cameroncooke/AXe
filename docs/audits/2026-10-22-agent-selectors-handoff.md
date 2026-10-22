# Agent selector checkpoint: 22 October 2026

Status: isolated on codex/duo-tap-wait, based on main4f684bec. Not merged or accepted as native Duo support.

Adds agent-only label substring, Foundation regex and decimal logical frame filtering. Fresh native resolution must identify one target with an existing unique exact native ID or label; existing screen/target admission remains authoritative. No cached-coordinate dispatch. No-flag requests reject the new options. Old brokers reject new selector payloads without a legacy target.

Decisions: retain normal Foundation regex syntax, including grouped alternatives. Limit query/pattern/frame bytes, candidate text, tree size and shared matching time. Foundation matching cancellation is cooperative; pattern compilation has a size cap but no cancellation API. Frame filters require the full target frame inside logical bounds. Detailed guide rules moved to linked agent references to keep both skill bodies below their validation limit.

Validation ran against the final source before this checkpoint, using Xcode27.0RC and the existing accepted native frameworks. Exact argv, source/framework hashes and binary hashes are in /Volumes/Developer/AXe/build_products/verification/agent-selectors-20261022.

- Five changed Swift files passed syntax parsing.
- Both guide directories passed strict offline skill-check and quick_validate. Security scan remains UNVERIFIED per Cam.
- Single-job arm64 build passed. The first attempt exposed old framework copies; staging the accepted hash-verified frameworks fixed the build without source downgrade.
- Twenty real CLI help/argument checks passed, with all action cases rejected before simulator access. These include grouped regex and decimal-frame parsing, invalid patterns/bounds and no-flag rejection. An initial general-error exit was corrected to a CLI usage error and rebuilt.
- Seventy-three existing checks in eight selected tap, polling, resolver and describe-ui suites passed. No new test suite was added.
- All14 unrelated main source states match their saved hashes.
- App footprint peak across the successful build/check runs:7.736GiB; simulator footprint4.223GiB; owned command0.412GiB. No resource stop; all guarded commands reaped.

Still required: native substring/regex/frame effects and release; missing/ambiguous/size/time no-input rejection; fold/rotation/PID/layout changes and fresh recovery; exact/ref/coordinate compatibility; direct older-broker rejection; main integration and combined-candidate proof. A frame-filtered match with no unique native ID/label remains unsupported. No simulator was booted or sent input in this checkpoint.
