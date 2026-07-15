#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG=""
TARGET=""
SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-}"
MATRIX_SCRIPT=""
WORK_DIR=""
PUBLISH=false
PRERELEASE=true
KEEP_WORK_DIR=true
PINNED_IDB_GIT_URL="https://github.com/cameroncooke/idb.git"
PINNED_IDB_SHA="1395103ca786ee990c70514e1f8bb75fa98cdd82"
PINNED_IDB_UPSTREAM_BASE_SHA="e682506725e9efefb9c43b8b917c0b12eb2a5939"
IDB_GIT_URL="${IDB_GIT_URL:-$PINNED_IDB_GIT_URL}"
IDB_SHA="${IDB_GIT_REF:-$PINNED_IDB_SHA}"
IDB_UPSTREAM_BASE_SHA="${IDB_UPSTREAM_BASE_REF:-$PINNED_IDB_UPSTREAM_BASE_SHA}"
EXPECTED_XCODE_26_BUILD="17F42"
EXPECTED_IOS_26_RUNTIME_BUILD="23F77"
EXPECTED_XCODE_27_BUILD="27A5218g"
EXPECTED_IOS_27_RUNTIME_BUILD="24A5380g"
WORK_DIR_MARKER_VALUE=""
WORK_DIR_IDENTITY=""

usage() {
  printf '%s\n' \
    "Usage:" \
    "  scripts/release-local.sh --tag vX.Y.Z --developer-dir PATH --matrix-script PATH [options]" \
    "" \
    "Options:" \
    "  --target SHA            Release target (default: HEAD)" \
    "  --work-dir PATH         Isolated local release directory" \
    "  --publish               Publish assets after every local gate passes" \
    "  --prerelease            Mark the GitHub release as a prerelease (default)" \
    "  --stable                Do not mark the GitHub release as a prerelease" \
    "  --keep-work-dir         Preserve build, stage, evidence, and assets (default)" \
    "  --cleanup-work-dir      Remove the work directory on exit" \
    "  -h, --help              Show this help" \
    "" \
    "The executable matrix script receives AXE_BIN_PATH, AXE_STAGE_DIR," \
    "AXE_UNIVERSAL_ARCHIVE, AXE_HOMEBREW_ARCHIVE, AXE_ARTIFACT_SHA256," \
    "and AXE_MATRIX_EVIDENCE_PATH. It must write schema_version 1 JSON evidence" \
    "for the exact Xcode 26.5/iOS 26.5 and Xcode 27 Beta 3/iOS 27 cells."
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || fail "Missing value for $option"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      require_value "$1" "${2:-}"
      TAG="$2"
      shift 2
      ;;
    --target)
      require_value "$1" "${2:-}"
      TARGET="$2"
      shift 2
      ;;
    --developer-dir)
      require_value "$1" "${2:-}"
      SELECTED_DEVELOPER_DIR="$2"
      shift 2
      ;;
    --matrix-script)
      require_value "$1" "${2:-}"
      MATRIX_SCRIPT="$2"
      shift 2
      ;;
    --work-dir)
      require_value "$1" "${2:-}"
      WORK_DIR="$2"
      shift 2
      ;;
    --publish)
      PUBLISH=true
      shift
      ;;
    --prerelease)
      PRERELEASE=true
      shift
      ;;
    --stable)
      PRERELEASE=false
      shift
      ;;
    --keep-work-dir)
      KEEP_WORK_DIR=true
      shift
      ;;
    --cleanup-work-dir)
      KEEP_WORK_DIR=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] \
  || fail "--tag must use vX.Y.Z or vX.Y.Z-prerelease format"
[[ -n "$SELECTED_DEVELOPER_DIR" ]] || fail "Set DEVELOPER_DIR or pass --developer-dir"
[[ -d "$SELECTED_DEVELOPER_DIR" ]] || fail "Developer directory not found: $SELECTED_DEVELOPER_DIR"
[[ -x "$MATRIX_SCRIPT" ]] || fail "--matrix-script must point to an executable file"
SELECTED_DEVELOPER_DIR="$(cd "$SELECTED_DEVELOPER_DIR" && pwd)"
MATRIX_SCRIPT="$(cd "$(dirname "$MATRIX_SCRIPT")" && pwd)/$(basename "$MATRIX_SCRIPT")"
if [[ -n "$WORK_DIR" && "$WORK_DIR" != /* ]]; then
  WORK_DIR="$PWD/$WORK_DIR"
fi
[[ "$IDB_SHA" == "$PINNED_IDB_SHA" ]] \
  || fail "IDB_GIT_REF must match the pinned fork revision: $PINNED_IDB_SHA"
[[ "$IDB_GIT_URL" == "$PINNED_IDB_GIT_URL" ]] \
  || fail "IDB_GIT_URL must match the pinned fork: $PINNED_IDB_GIT_URL"
[[ "$IDB_UPSTREAM_BASE_SHA" == "$PINNED_IDB_UPSTREAM_BASE_SHA" ]] \
  || fail "IDB_UPSTREAM_BASE_REF must match the verified base: $PINNED_IDB_UPSTREAM_BASE_SHA"

for command in codesign find gh git jq node shasum stat tar tee xcodebuild; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
done

cd "$ROOT_DIR"

SELECTED_XCODE_VERSION="$(DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" xcodebuild -version | awk 'NR == 1 { print $2 }')"
SELECTED_XCODE_BUILD="$(DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" xcodebuild -version | awk '/Build version/ { print $3 }')"
[[ "$SELECTED_XCODE_VERSION" == "26.5" && "$SELECTED_XCODE_BUILD" == "$EXPECTED_XCODE_26_BUILD" ]] \
  || fail "Release payload must be built with Xcode 26.5 ($EXPECTED_XCODE_26_BUILD), got $SELECTED_XCODE_VERSION ($SELECTED_XCODE_BUILD)"

[[ -z "$(git status --porcelain)" ]] || fail "Working tree must be clean before a local release"
TARGET="${TARGET:-$(git rev-parse HEAD)}"
git cat-file -e "$TARGET^{commit}" 2>/dev/null || fail "Release target is not a local commit: $TARGET"
TARGET="$(git rev-parse "$TARGET^{commit}")"
HEAD_SHA="$(git rev-parse HEAD)"
[[ "$TARGET" == "$HEAD_SHA" ]] || fail "Release target must match the checked-out clean HEAD"

if $PUBLISH; then
  [[ "$(git branch --show-current)" == "main" ]] || fail "Publishing a local release requires the main branch"
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
fi

VERSION="${TAG#v}"
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/axe-local-release.XXXXXX")"
else
  [[ ! -e "$WORK_DIR" ]] || fail "Work directory already exists: $WORK_DIR"
  mkdir -p "$WORK_DIR"
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
[[ "$WORK_DIR" != "/" ]] || fail "Refusing to use the filesystem root as a work directory"
WORK_DIR_MARKER_VALUE="axe-release-workdir:$HEAD_SHA:$$"
printf '%s\n' "$WORK_DIR_MARKER_VALUE" > "$WORK_DIR/.axe-release-workdir"
WORK_DIR_IDENTITY="$(stat -f '%d:%i' "$WORK_DIR")"

remove_owned_work_dir() {
  [[ -n "$WORK_DIR" && "$WORK_DIR" != "/" ]] || fail "Refusing unsafe work directory cleanup"
  [[ ! -L "$WORK_DIR" && -d "$WORK_DIR" ]] || fail "Release work directory changed type before cleanup: $WORK_DIR"
  [[ "$(stat -f '%d:%i' "$WORK_DIR")" == "$WORK_DIR_IDENTITY" ]] \
    || fail "Release work directory identity changed before cleanup: $WORK_DIR"
  [[ -f "$WORK_DIR/.axe-release-workdir" ]] \
    || fail "Release work directory ownership marker is missing: $WORK_DIR"
  [[ "$(< "$WORK_DIR/.axe-release-workdir")" == "$WORK_DIR_MARKER_VALUE" ]] \
    || fail "Release work directory ownership marker changed: $WORK_DIR"
  rm -r "$WORK_DIR"
}

cleanup() {
  if ! $KEEP_WORK_DIR && [[ -d "$WORK_DIR" ]]; then
    remove_owned_work_dir
  fi
}
trap cleanup EXIT

BUILD_OUTPUT_DIR="$WORK_DIR/build-products"
DERIVED_DATA_PATH="$WORK_DIR/derived-data"
IDB_CHECKOUT_DIR="$WORK_DIR/idb-checkout"
TEMP_DIR="$WORK_DIR/notarization"
STAGE_DIR="$WORK_DIR/stage"
ASSET_DIR="$WORK_DIR/assets"
BUILD_LOG="$WORK_DIR/build.log"
MATRIX_EVIDENCE="$WORK_DIR/matrix-evidence.json"
RELEASE_NOTES="$WORK_DIR/github-release-body.md"
mkdir -p "$TEMP_DIR" "$ASSET_DIR"

node scripts/generate-github-release-notes.mjs \
  --version "$VERSION" \
  --fallback none \
  --out "$RELEASE_NOTES"

export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
export BUILD_OUTPUT_DIR DERIVED_DATA_PATH IDB_CHECKOUT_DIR TEMP_DIR
export IDB_GIT_URL IDB_GIT_REF="$IDB_SHA"
export IDB_UPSTREAM_BASE_REF="$IDB_UPSTREAM_BASE_SHA"

printf 'Building and notarizing with %s (%s)\n' \
  "$(xcodebuild -version | head -1)" \
  "$(xcodebuild -version | awk '/Build version/ { print $3 }')"

set +e
scripts/build.sh build 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS=${PIPESTATUS[0]}
set -e
[[ "$BUILD_STATUS" -eq 0 ]] || fail "Local release build failed"
grep -q 'status: Accepted' "$BUILD_LOG" || fail "Build log does not contain accepted notarization evidence"

IDB_BUILD_EVIDENCE="$BUILD_OUTPUT_DIR/XCFrameworks/IDB_BUILD_EVIDENCE.txt"
[[ -f "$IDB_BUILD_EVIDENCE" && ! -L "$IDB_BUILD_EVIDENCE" ]] \
  || fail "IDB build evidence is missing or is a symlink: $IDB_BUILD_EVIDENCE"
grep -Fxq "IDB_SHA=$IDB_SHA" "$IDB_BUILD_EVIDENCE" \
  || fail "IDB build evidence does not match the pinned SHA"
grep -Fxq "IDB_GIT_URL=$IDB_GIT_URL" "$IDB_BUILD_EVIDENCE" \
  || fail "IDB build evidence does not match the pinned fork URL"
grep -Fxq "IDB_UPSTREAM_BASE_SHA=$IDB_UPSTREAM_BASE_SHA" "$IDB_BUILD_EVIDENCE" \
  || fail "IDB build evidence does not match the verified upstream base"
grep -Fxq "DEVELOPER_DIR=$SELECTED_DEVELOPER_DIR" "$IDB_BUILD_EVIDENCE" \
  || fail "IDB build evidence does not match the selected developer directory"
grep -Eq "^XCODE_VERSION=Xcode 26\\.5 Build version ${EXPECTED_XCODE_26_BUILD}[[:space:]]*$" "$IDB_BUILD_EVIDENCE" \
  || fail "IDB build evidence does not match Xcode 26.5 ($EXPECTED_XCODE_26_BUILD)"
IDB_BUILD_EVIDENCE_SHA256="$(shasum -a 256 "$IDB_BUILD_EVIDENCE" | awk '{ print $1 }')"

PACKAGE_ZIPS=()
while IFS= read -r package_path; do
  PACKAGE_ZIPS+=("$package_path")
done < <(find "$TEMP_DIR" -maxdepth 1 -type f -name 'AXe-Final-*.zip' -print)
[[ "${#PACKAGE_ZIPS[@]}" -eq 1 ]] || fail "Expected exactly one notarized final package in $TEMP_DIR"
PACKAGE_ZIP="${PACKAGE_ZIPS[0]}"

scripts/release-artifacts.sh extract-stage --package-zip "$PACKAGE_ZIP" --stage-dir "$STAGE_DIR"
scripts/release-artifacts.sh verify-stage --stage-dir "$STAGE_DIR"

codesign --verify --deep --strict "$STAGE_DIR/axe"
while IFS= read -r framework_path; do
  codesign --verify --deep --strict "$framework_path"
done < <(find "$STAGE_DIR/Frameworks" -maxdepth 1 -type d -name '*.framework' -print)
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$STAGE_DIR/axe" 2>&1)"
grep -q 'Authority=Developer ID Application:' <<< "$SIGNATURE_DETAILS" \
  || fail "Staged executable is not signed with Developer ID Application"
grep -q 'flags=.*runtime' <<< "$SIGNATURE_DETAILS" \
  || fail "Staged executable is missing hardened runtime"

UNIVERSAL_ARCHIVE="$ASSET_DIR/AXe-macOS-${TAG}-universal.tar.gz"
HOMEBREW_ARCHIVE="$ASSET_DIR/AXe-macOS-homebrew-${TAG}.tar.gz"
scripts/release-artifacts.sh create-universal-archive --stage-dir "$STAGE_DIR" --archive "$UNIVERSAL_ARCHIVE"
scripts/release-artifacts.sh create-homebrew-archive --stage-dir "$STAGE_DIR" --archive "$HOMEBREW_ARCHIVE"
scripts/release-artifacts.sh smoke-test-stage --stage-dir "$STAGE_DIR"
scripts/release-artifacts.sh smoke-test-archive --archive "$UNIVERSAL_ARCHIVE"
scripts/release-artifacts.sh smoke-test-archive --archive "$HOMEBREW_ARCHIVE"

ARTIFACT_SHA256="$(shasum -a 256 "$UNIVERSAL_ARCHIVE" | awk '{ print $1 }')"
HOMEBREW_SHA256="$(shasum -a 256 "$HOMEBREW_ARCHIVE" | awk '{ print $1 }')"
AXE_PAYLOAD_SHA256="$(shasum -a 256 "$STAGE_DIR/axe" | awk '{ print $1 }')"
STAGE_SHA256="$(COPYFILE_DISABLE=1 tar -cf - -C "$STAGE_DIR" . | shasum -a 256 | awk '{ print $1 }')"

AXE_BIN_PATH="$STAGE_DIR/axe" \
AXE_STAGE_DIR="$STAGE_DIR" \
AXE_UNIVERSAL_ARCHIVE="$UNIVERSAL_ARCHIVE" \
AXE_HOMEBREW_ARCHIVE="$HOMEBREW_ARCHIVE" \
AXE_ARTIFACT_SHA256="$ARTIFACT_SHA256" \
AXE_PAYLOAD_SHA256="$AXE_PAYLOAD_SHA256" \
AXE_MATRIX_EVIDENCE_PATH="$MATRIX_EVIDENCE" \
DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" \
  "$MATRIX_SCRIPT"

scripts/release-artifacts.sh verify-stage --stage-dir "$STAGE_DIR"
scripts/release-artifacts.sh smoke-test-archive --archive "$UNIVERSAL_ARCHIVE"
scripts/release-artifacts.sh smoke-test-archive --archive "$HOMEBREW_ARCHIVE"
[[ "$(shasum -a 256 "$UNIVERSAL_ARCHIVE" | awk '{ print $1 }')" == "$ARTIFACT_SHA256" ]] \
  || fail "Matrix validation modified the universal archive"
[[ "$(shasum -a 256 "$HOMEBREW_ARCHIVE" | awk '{ print $1 }')" == "$HOMEBREW_SHA256" ]] \
  || fail "Matrix validation modified the Homebrew archive"
[[ "$(shasum -a 256 "$STAGE_DIR/axe" | awk '{ print $1 }')" == "$AXE_PAYLOAD_SHA256" ]] \
  || fail "Matrix validation modified the staged AXe payload"
[[ "$(COPYFILE_DISABLE=1 tar -cf - -C "$STAGE_DIR" . | shasum -a 256 | awk '{ print $1 }')" == "$STAGE_SHA256" ]] \
  || fail "Matrix validation modified the staged release payload"

[[ -s "$MATRIX_EVIDENCE" ]] || fail "Matrix script did not create evidence at $MATRIX_EVIDENCE"
jq -e \
  --arg commit "$HEAD_SHA" \
  --arg idb_fork_url "$IDB_GIT_URL" \
  --arg idb "$IDB_SHA" \
  --arg idb_upstream_base "$IDB_UPSTREAM_BASE_SHA" \
  --arg artifact "$ARTIFACT_SHA256" \
  --arg payload "$AXE_PAYLOAD_SHA256" \
  --arg xcode26 "$EXPECTED_XCODE_26_BUILD" \
  --arg ios26 "$EXPECTED_IOS_26_RUNTIME_BUILD" \
  --arg xcode27 "$EXPECTED_XCODE_27_BUILD" \
  --arg ios27 "$EXPECTED_IOS_27_RUNTIME_BUILD" \
  '
    def sha256: type == "string" and test("^[0-9a-f]{64}$");
    def passed_artifact:
      type == "object" and
      (.result == "pass") and
      (.artifact_sha256 | sha256);
    def exact_cell($xcode_version; $xcode_build; $runtime_version; $runtime_build):
      type == "object" and
      (.xcode == {version: $xcode_version, build: $xcode_build}) and
      (.runtime == {platform: "iOS", version: $runtime_version, build: $runtime_build}) and
      (.simulator.udid | type == "string" and length > 0) and
      (.simulator.device_type | type == "string" and length > 0) and
      (.commands | passed_artifact) and
      (.media | passed_artifact) and
      (.goldens | passed_artifact);
    .schema_version == 1 and
    .result == "pass" and
    .source == {axe_commit: $commit} and
    .payload == {sha256: $payload} and
    .archives.universal_sha256 == $artifact and
    .idb == {
      fork_url: $idb_fork_url,
      sha: $idb,
      upstream_base_sha: $idb_upstream_base
    } and
    (.cells | type == "array" and length == 2) and
    ([.cells[] | select(exact_cell("26.5"; $xcode26; "26.5"; $ios26))] | length == 1) and
    ([.cells[] | select(exact_cell("27.0 Beta 3"; $xcode27; "27.0"; $ios27))] | length == 1)
  ' "$MATRIX_EVIDENCE" >/dev/null || fail "Matrix evidence is incomplete or does not match this artifact"

MANIFEST="$ASSET_DIR/AXe-macOS-${TAG}-manifest.json"
jq -n -S \
  --arg tag "$TAG" \
  --arg axe_commit "$HEAD_SHA" \
  --arg idb_fork_url "$IDB_GIT_URL" \
  --arg idb_sha "$IDB_SHA" \
  --arg idb_upstream_base_sha "$IDB_UPSTREAM_BASE_SHA" \
  --arg idb_build_evidence_sha256 "$IDB_BUILD_EVIDENCE_SHA256" \
  --arg build_xcode_version "$SELECTED_XCODE_VERSION" \
  --arg build_xcode_build "$SELECTED_XCODE_BUILD" \
  --arg package_sha256 "$(shasum -a 256 "$PACKAGE_ZIP" | awk '{ print $1 }')" \
  --arg axe_payload_sha256 "$AXE_PAYLOAD_SHA256" \
  --arg universal_archive "$(basename "$UNIVERSAL_ARCHIVE")" \
  --arg universal_sha256 "$ARTIFACT_SHA256" \
  --arg homebrew_archive "$(basename "$HOMEBREW_ARCHIVE")" \
  --arg homebrew_sha256 "$HOMEBREW_SHA256" \
  --slurpfile matrix "$MATRIX_EVIDENCE" \
  '{
    tag: $tag,
    axe_commit: $axe_commit,
    idb_sha: $idb_sha,
    idb_build_evidence: {
      sha256: $idb_build_evidence_sha256,
      fork_url: $idb_fork_url,
      upstream_base_sha: $idb_upstream_base_sha,
      xcode: {version: $build_xcode_version, build: $build_xcode_build}
    },
    notarized_package_sha256: $package_sha256,
    axe_payload_sha256: $axe_payload_sha256,
    universal_archive: {name: $universal_archive, sha256: $universal_sha256},
    homebrew_archive: {name: $homebrew_archive, sha256: $homebrew_sha256},
    matrix: $matrix[0]
  }' > "$MANIFEST"

if $PUBLISH; then
  [[ -z "$(git status --porcelain)" ]] || fail "Working tree changed during local release validation"
  [[ "$(git rev-parse HEAD)" == "$HEAD_SHA" ]] || fail "HEAD changed during local release validation"
  [[ "$(git branch --show-current)" == "main" ]] || fail "Publishing a local release requires the main branch"
  REMOTE_MAIN_SHA="$(git ls-remote origin refs/heads/main | awk '{ print $1 }')"
  [[ "$REMOTE_MAIN_SHA" == "$HEAD_SHA" ]] || fail "Release target no longer matches origin/main"
  [[ -z "$(git ls-remote origin "refs/tags/$TAG")" ]] || fail "Remote tag already exists: $TAG"
  if gh release view "$TAG" >/dev/null 2>&1; then
    fail "GitHub release already exists: $TAG"
  fi
  RELEASE_ARGS=(
    --title "Release $TAG"
    --notes-file "$RELEASE_NOTES"
    --target "$HEAD_SHA"
  )
  if $PRERELEASE; then
    RELEASE_ARGS+=(--prerelease)
  fi
  gh release create "$TAG" "${RELEASE_ARGS[@]}" \
    "$UNIVERSAL_ARCHIVE" "$HOMEBREW_ARCHIVE" "$MANIFEST"
  printf 'Published local release %s\n' "$TAG"
else
  printf 'All local release gates passed; publication was not requested.\n'
fi

printf 'Assets: %s\n' "$ASSET_DIR"
printf 'Matrix evidence: %s\n' "$MATRIX_EVIDENCE"
printf 'Manifest: %s\n' "$MANIFEST"
