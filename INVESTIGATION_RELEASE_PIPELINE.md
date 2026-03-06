# Investigation: AXe Release Pipeline

## Summary
AXe’s build and distribution flow is understandable, but it is more complex than a typical CLI because it ships a universal executable, patched/private-framework-backed IDB frameworks, a SwiftPM resource bundle, a notarized direct-download archive, and a separately re-signed Homebrew installation layout. The real problem is not just that the system is complex; it is that release identity, build prerequisites, packaging shape, and Homebrew install behavior are decided in multiple places, so the pipeline relies on hidden contracts and duplicated logic.

## Symptoms
- Release and distribution required repeated trial-and-error to get Homebrew install/runtime behavior correct.
- Homebrew-installed AXe initially had invalid framework bundle seals after install.
- Release-note fallback and Homebrew smoke-test logic needed repeated fixes.
- The pipeline spans local Bash orchestration, GitHub Actions, patched upstream dependency builds, notarization, tap updates, and post-install signing.

## Investigation Log

### Phase 1 - Initial assessment
**Hypothesis:** The pipeline has duplicated logic, hidden coupling, and non-standard packaging/signing requirements.
**Findings:** Confirmed. AXe is not a normal single-binary CLI and the release system does not isolate that complexity behind one authoritative contract.
**Evidence:** See later sections.
**Conclusion:** Confirmed.

### Phase 2 - Release trigger and orchestration model
**Hypothesis:** There are two competing release control planes.
**Findings:** This was confirmed during the investigation, but has since been partially addressed. `scripts/release.sh` is now a tag-push helper only, and `workflow_dispatch` requires an explicit existing tag and checks out that exact ref. The remaining distinction is intentional: push-tag is the only shipping path, while manual runs are now verify-only.
**Evidence:**
- `AXe/.github/workflows/release.yml` still defines both `push.tags` and `workflow_dispatch`, but manual runs now require `github.event.inputs.tag` and use `ref:` during checkout.
- `AXe/scripts/release.sh` no longer dispatches the workflow or owns tap-target policy.
- `AXe/.github/workflows/release.yml` now limits GitHub release creation and tap updates to the push-triggered path.
**Conclusion:** Mostly resolved. AXe now has one canonical shipping path, but it still keeps a separate manual verification entry point.

### Phase 3 - Build graph and artifact dependency model
**Hypothesis:** AXe’s build prerequisites are modeled indirectly via side effects rather than explicit artifact dependencies.
**Findings:** Confirmed. SwiftPM depends on local XCFrameworks at fixed paths, but CI decides whether to build those XCFrameworks based on `idb_checkout` freshness, not on XCFramework existence or validity. Architecture verification is also skipped whenever the IDB build path is skipped.
**Evidence:**
- `AXe/Package.swift:48-63` hardcodes binary targets under `build_products/XCFrameworks/*.xcframework`.
- `AXe/.github/workflows/release.yml:115-139` restores and checks only `idb_checkout` freshness.
- `AXe/.github/workflows/release.yml:154-241` gates clone/build/install/strip/XCFramework/sign steps behind `steps.idb_check.outputs.needs_setup == 'true'`.
- `AXe/.github/workflows/release.yml:272-274` also gates architecture verification behind that same condition.
- `AXe/scripts/build.sh:270-287` creates XCFrameworks from built frameworks.
- `AXe/scripts/build.sh:478-543` builds the universal AXe executable and copies the resource bundle.
- `AXe/scripts/build.sh:579-622` verifies architectures for either Frameworks or XCFrameworks, but only when the caller invokes that function.
**Conclusion:** Confirmed. The build graph is implicit and side-effect-driven. The true dependency is “AXe build requires XCFrameworks,” but the workflow models it as “AXe build depends on IDB repo freshness.”

### Phase 4 - Packaging and runtime contract
**Hypothesis:** AXe’s runtime package shape has hidden requirements that leak into multiple layers of the pipeline.
**Findings:** Confirmed. AXe must ship `axe`, `Frameworks/`, and `AXe_AXe.bundle`; this is encoded separately in runtime code, build/package steps, smoke tests, and Homebrew formula generation.
**Evidence:**
- `AXe/Sources/AXe/Commands/Init.swift:84-88` loads bundled skill content with `Bundle.module.url(...)`, so `AXe_AXe.bundle` is mandatory at runtime.
- `AXe/scripts/build.sh:132-158` explicitly copies `AXe_AXe.bundle` from Swift build outputs.
- `AXe/scripts/build.sh:655-679` packages `axe`, `Frameworks`, and `AXe_AXe.bundle` into the notarization zip.
- `AXe/scripts/build.sh:743-757` and `AXe/scripts/build.sh:792-805` replace and repack the notarized executable, frameworks, and bundle.
- `AXe/.github/workflows/release.yml:400-431` smoke-tests the packaged CLI and Homebrew archive by checking `AXe_AXe.bundle` and running `init --print`.
- `AXe/scripts/release-dry-run.sh:21-36` synthesizes `Frameworks/` and `AXe_AXe.bundle`; `AXe/scripts/release-dry-run.sh:57-83` validates the same shape and the generated formula content.
- `AXe/scripts/generate-homebrew-formula.sh:64-75` installs `axe`, `Frameworks`, and `AXe_AXe.bundle` into Homebrew layout.
**Conclusion:** Confirmed. AXe has a non-standard runtime/distribution model, but the package contract is duplicated instead of centralized.

### Phase 5 - Homebrew-specific complexity
**Hypothesis:** The Homebrew flow intentionally differs from the direct-download flow, and that special handling is a major complexity source.
**Findings:** Confirmed. The workflow explicitly strips signatures from the Homebrew payload because Homebrew mutates installed contents and re-signs locally. This is deliberate, but it means Homebrew users are running a materially different trust/runtime path than direct-download users. The previous staging-formula drift called out here has since been corrected so staging and production now share the same generated install/signing structure.
**Evidence:**
- `AXe/.github/workflows/release.yml` creates a separate Homebrew archive from the verified staged payload.
- `AXe/scripts/release-artifacts.sh` strips signatures from Mach-O files and bundles before tarballing the Homebrew archive.
- `AXe/scripts/generate-homebrew-formula.sh:64-78` defines a Homebrew `post_install` signing step for frameworks and `libexec/axe`.
- `homebrew-axe/Formula/axe.rb` and `homebrew-axe-staging/Formula/axe.rb` now match the generator contract structurally.
- Runtime experiments during this investigation showed that Homebrew-installed AXe uses embedded frameworks successfully against a real simulator, but only after the formula’s signing logic was corrected.
**Conclusion:** Confirmed. Homebrew support is not incidental; it is a first-class, non-standard distribution mode with its own signing and packaging contract.

### Phase 6 - Release notes and tap-update policy drift
**Hypothesis:** Policy is duplicated across scripts and workflow code.
**Findings:** Partially confirmed. Release-note fallback/version selection is still split between Bash helpers, the JS release-notes generator, and inline workflow logic. Tap-target defaults have been simplified so push-tag releases now derive tap targets only in CI, and `scripts/release.sh` no longer owns tap policy.
**Evidence:**
- `AXe/scripts/release.sh` still prepares changelog release notes and identifies fallback versions locally.
- `AXe/scripts/generate-github-release-notes.mjs:1-168` owns CHANGELOG extraction/rendering and install text, but not full fallback/version policy.
- `AXe/.github/workflows/release.yml` still repeats fallback-version selection inline in Node.
- `AXe/.github/workflows/release.yml` now derives tap targets only from the release version on push runs.
**Conclusion:** Improved, but not fully resolved. Release-note policy still has multiple owners.

### Phase 7 - Validation depth
**Hypothesis:** The release pipeline validates package shape more than shipped product behavior.
**Findings:** Mostly confirmed. The workflow checks archive structure, `init --print`, install mechanics, and release asset creation, but it does not run a real simulator-facing command in CI.
**Evidence:**
- `AXe/.github/workflows/release.yml:400-511` smoke-tests archive shape, `init --print`, and Homebrew install.
- No CI step executes a real simulator control path such as `list-simulators`, `describe-ui`, `tap`, or `screenshot` against a booted simulator.
- During this investigation, I manually validated the Homebrew-installed binary against a real booted iPhone simulator using `describe-ui`, `screenshot`, and `tap`, and those are the tests that exposed the real packaging/signing issues.
**Conclusion:** Confirmed. CI validates packaging shape and shallow runtime smoke, but not the actual product behavior the user buys AXe for.

## Root Cause
The root cause is not “notarization is hard” or “Homebrew is weird” in isolation. The real root cause is that AXe has a genuinely non-standard runtime/distribution model, but the repository does not contain a single authoritative release/build/package contract.

Concretely:
- AXe is a universal CLI that depends on locally built binary XCFrameworks (`AXe/Package.swift:48-63`), runtime-loaded private-framework-backed simulator code (`AXe/scripts/build.sh:478-543`), and a SwiftPM resource bundle required by `Bundle.module` (`AXe/Sources/AXe/Commands/Init.swift:84-88`).
- The release pipeline compensates for that complexity in multiple layers: local Bash release orchestration (`AXe/scripts/release.sh`), CI workflow branching (`AXe/.github/workflows/release.yml`), package shaping (`AXe/scripts/build.sh`, `AXe/scripts/release-dry-run.sh`), Homebrew formula generation (`AXe/scripts/generate-homebrew-formula.sh`), and committed tap formulas (`homebrew-axe/Formula/axe.rb`, `homebrew-axe-staging/Formula/axe.rb`).
- Because each layer owns only part of the contract, hidden coupling appears everywhere: tag selection is separate from checkout, XCFramework prerequisites are inferred from repo freshness instead of artifact existence, package shape is duplicated, and Homebrew staging can drift from production.

That is why the system required repeated trial-and-error: multiple layers were compensating independently for the same non-standard runtime packaging problem.

## Recommendations
1. **Finish centralizing release metadata and notes policy.** One script should own version selection, release-note fallback, asset names, and install text. Evidence: `AXe/scripts/release.sh`, `AXe/scripts/generate-github-release-notes.mjs`, `AXe/.github/workflows/release.yml`.
2. **Keep the build graph explicit.** Release CI should continue to cache/restore XCFramework outputs directly and verify them unconditionally. Do not regress to tying AXe build validity to `idb_checkout` freshness.
3. **Continue treating the staged payload contract as canonical.** `axe + Frameworks + AXe_AXe.bundle` should remain the single source for archive creation, smoke tests, and formula generation.
4. **Keep formula generation single-source.** Production and staging should continue to be regenerated from the same template/parameters; do not allow structural drift back in.
5. **Add one real simulator-facing release smoke test.** A minimal real command against a controlled booted simulator would still improve confidence beyond package-shape and install-path validation.

## Preventive Measures
- Treat release metadata, packaging shape, and Homebrew formula generation as code-owned contracts with one source of truth each.
- Add a CI assertion that staging and production formulas are generated from the same template or differ only by explicit, reviewed parameters.
- Add a release guardrail that fails if `workflow_dispatch` does not check out the requested ref/tag explicitly.
- Add one simulator-facing smoke test for the packaged artifact, not just package-shape checks.
- Document the intentional difference between direct-download notarized artifacts and Homebrew-installed ad-hoc-signed artifacts.
