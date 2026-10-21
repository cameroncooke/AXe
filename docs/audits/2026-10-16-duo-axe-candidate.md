# Current AXe candidate for the Duo manual audit

Date: 16 October 2026.

A fresh debug arm64 build of the current AXe worktree completed. This candidate replaces reliance on the older prebuilt executable for the live audit. It does not add Duo support.

## Candidate identity

- Binary: /private/tmp/axe-duo-audit-20261016/build/out/Products/Debug/axe
- Version output: v1.8.0-1-g7163081-dirty
- SHA-256: 08dfa7f0720ff0659cd037517cb77a7789adf07ff4b7f97e7d11ac11ce64458e
- Branch: main
- HEAD: 7163081400b59f1df40bff44f3a94dded38eea9a
- Configuration: debug, arm64, product axe
- Source-manifest SHA-256: 1c2fac6ae6abb9fda37c59ef314341dff23769648a8740940562e4503fcf1526
- Tracked source-diff SHA-256: b42b73c4473b1166210915d24ecf5ccc5d4c4a7810a08e2280d76ccd5408d5b0

The source manifest includes Package.swift, Package.resolved, the version plugin, and all files under Sources, including new untracked source files and resources. The tracked diff contains the changes from HEAD in Sources, Package.swift, Package.resolved, and Plugins. The manifest before and after the build is identical. A dirty version string alone would not identify this candidate; use the binary and source hashes.

The pre-existing agent/accessibility/coordinate changes remain in place. No source, tests, skills, package pins, or framework inputs were changed. No tests ran. No simulator commands ran during candidate preparation. No commit or push was made.

## Build environment and pinned frameworks

Build toolchain: /Applications/Xcode-27.0.0-Release.Candidate.app/Contents/Developer, Xcode 27.0 RC build 27A266a. Compiler: Apple Swift 6.4, swiftlang-6.4.0.34.1, clang-2100.3.34.1.

This was the closest installed compiler to the existing framework evidence: Xcode 27.0 build 27A5237l, Swift 6.4, swiftlang-6.4.0.30.4. The framework package includes textual Swift interfaces. The current source compiled successfully with the RC compiler; no module compatibility workaround was needed.

IDB pin: 604c51013438f0c3603b720a05a44b7c5b8f286d from https://github.com/cameroncooke/idb.git. Its checkout was clean before and after the build. The build used the existing binary targets under build_products/XCFrameworks and did not rebuild IDB.

Swift Argument Parser used the existing resolved checkout: version 1.5.0, revision 41982a3656a71c768319979febd796c6fd111d5c. Existing .build/checkouts, .build/repositories, and .build/workspace-state.json were copied into the isolated scratch directory. Automatic package resolution was disabled.

The four framework executable files beside the new binary have the same SHA-256 values as their original XCFramework inputs. See [framework hashes](evidence/2026-10-16-duo/axe-candidate/framework-hashes.json). Keep the whole Products/Debug directory together when using this binary; it loads the adjacent framework bundles through rpaths.

## Exact build command

Working directory: /Volumes/Developer/AXe.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Release.Candidate.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/axe-duo-audit-20261016/module-cache \
xcrun swift build \
  --scratch-path /private/tmp/axe-duo-audit-20261016/build \
  --cache-path /private/tmp/axe-duo-audit-20261016/cache \
  --manifest-cache local \
  --disable-sandbox \
  --disable-automatic-resolution \
  --skip-update \
  --product axe \
  --configuration debug \
  --arch arm64 \
  > /private/tmp/axe-duo-audit-20261016/build-escalated.log 2>&1
```

The successful command ran outside the outer shell sandbox through approved tool escalation. The --disable-sandbox flag controls SwiftPM subprocess sandboxing; framework signature validation remained enabled.

The first attempt, with the same build options inside the outer shell sandbox, stopped because all four XCFramework signatures could not be verified. A direct signature check inside that sandbox also reported an invalid signature. The same FBSimulatorControl XCFramework passed this check outside it:

```sh
codesign --verify --deep --strict --verbose=4 \
  /Volumes/Developer/AXe/build_products/XCFrameworks/FBSimulatorControl.xcframework
```

It returned valid on disk and satisfies its Designated Requirement. The build then succeeded outside the shell sandbox with normal XCFramework validation. No signatures were removed or replaced. This was a sandbox-dependent validation failure, not evidence that the framework bytes needed repair.

## Verification

- Build exited 0 and reported Build complete! (13.83 secs).
- The candidate --version exited 0 and returned the version above.
- otool -L confirmed the expected four IDB-family framework dependencies.
- Source manifest before and after: identical.
- Original and copied framework executable hashes: identical for all four frameworks.
- Git status retained the pre-existing source/test changes and the audit documentation. IDB checkout remained clean.

This establishes compilation, process start for --version, and candidate provenance. It does not establish Xcode 27.2 or Duo runtime compatibility, successful input, accessibility, capture, or recording. Those are the next live checks. Use an explicit DEVELOPER_DIR for the intended runtime toolchain rather than changing global xcode-select as part of this audit.

## Saved evidence

- [Successful build log](evidence/2026-10-16-duo/axe-candidate/build-escalated.log)
- [Sandboxed build failure](evidence/2026-10-16-duo/axe-candidate/build.log)
- [Source manifest before](evidence/2026-10-16-duo/axe-candidate/source-manifest-before.sha256)
- [Source manifest after](evidence/2026-10-16-duo/axe-candidate/source-manifest-after.sha256)
- [Tracked source diff](evidence/2026-10-16-duo/axe-candidate/tracked-source.diff)
- [Framework hashes](evidence/2026-10-16-duo/axe-candidate/framework-hashes.json)

The executable remains in /private/tmp. Retain the complete Products/Debug directory if the audit must be repeated after temporary-directory cleanup.
