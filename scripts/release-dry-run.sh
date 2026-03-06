#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_DIR="${WORK_DIR:-$ROOT_DIR/.release-dry-run}"
TAG="${TAG:-v0.0.0-dryrun}"
VERSION="${TAG#v}"
FORMULA_NAME="${FORMULA_NAME:-axe}"
FORMULA_CLASS="$(echo "$FORMULA_NAME" | awk -F'[-_]' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print $0}' OFS="")"
HOMEPAGE="${HOMEPAGE:-https://github.com/cameroncooke/AXe}"
CANONICAL_FORMULA_PATH="${CANONICAL_FORMULA_PATH:-./scripts/fixtures/homebrew-formula.expected.rb}"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

STAGE_DIR="$WORK_DIR/stage"
PACKAGE_ROOT="$WORK_DIR/package-root/AXe-Final-dryrun"
OUT_DIR="$WORK_DIR/out"
UNIVERSAL_ARCHIVE="$OUT_DIR/AXe-macOS-${TAG}-universal.tar.gz"
HOMEBREW_ARCHIVE="$OUT_DIR/AXe-macOS-homebrew-${TAG}.tar.gz"
FORMULA_OUT="$OUT_DIR/${FORMULA_NAME}.rb"

mkdir -p \
  "$PACKAGE_ROOT/Frameworks/FBControlCore.framework" \
  "$PACKAGE_ROOT/Frameworks/XCTestBootstrap.framework" \
  "$PACKAGE_ROOT/Frameworks/FBSimulatorControl.framework" \
  "$PACKAGE_ROOT/Frameworks/FBDeviceControl.framework" \
  "$PACKAGE_ROOT/AXe_AXe.bundle" \
  "$OUT_DIR"

echo "[release-dry-run] Preparing universal test binary"
BIN_PATH="/usr/bin/file"

if [[ ! -f "$BIN_PATH" ]]; then
  echo "[release-dry-run] ERROR: required system binary missing at $BIN_PATH"
  exit 1
fi

lipo -info "$BIN_PATH" | grep -q "arm64"
lipo -info "$BIN_PATH" | grep -q "x86_64"

cp "$BIN_PATH" "$PACKAGE_ROOT/axe"
cp "$BIN_PATH" "$PACKAGE_ROOT/Frameworks/FBControlCore.framework/FBControlCore"
cp "$BIN_PATH" "$PACKAGE_ROOT/Frameworks/XCTestBootstrap.framework/XCTestBootstrap"
cp "$BIN_PATH" "$PACKAGE_ROOT/Frameworks/FBSimulatorControl.framework/FBSimulatorControl"
cp "$BIN_PATH" "$PACKAGE_ROOT/Frameworks/FBDeviceControl.framework/FBDeviceControl"
printf 'name: axe\n' > "$PACKAGE_ROOT/AXe_AXe.bundle/manifest.txt"

PACKAGE_ZIP="$WORK_DIR/AXe-Final-dryrun.zip"
ditto -c -k --keepParent "$PACKAGE_ROOT" "$PACKAGE_ZIP"

./scripts/release-artifacts.sh extract-stage \
  --package-zip "$PACKAGE_ZIP" \
  --stage-dir "$STAGE_DIR"

./scripts/release-artifacts.sh verify-stage --stage-dir "$STAGE_DIR"
./scripts/release-artifacts.sh create-universal-archive --stage-dir "$STAGE_DIR" --archive "$UNIVERSAL_ARCHIVE"
./scripts/release-artifacts.sh create-homebrew-archive --stage-dir "$STAGE_DIR" --archive "$HOMEBREW_ARCHIVE"

UNIVERSAL_VERIFY_DIR="$WORK_DIR/verify-universal"
HOMEBREW_VERIFY_DIR="$WORK_DIR/verify-homebrew"
mkdir -p "$UNIVERSAL_VERIFY_DIR" "$HOMEBREW_VERIFY_DIR"
tar -xzf "$UNIVERSAL_ARCHIVE" -C "$UNIVERSAL_VERIFY_DIR"
tar -xzf "$HOMEBREW_ARCHIVE" -C "$HOMEBREW_VERIFY_DIR"
./scripts/release-artifacts.sh verify-stage --stage-dir "$UNIVERSAL_VERIFY_DIR"
./scripts/release-artifacts.sh verify-stage --stage-dir "$HOMEBREW_VERIFY_DIR"

HOMEBREW_SHA="$(shasum -a 256 "$HOMEBREW_ARCHIVE" | awk '{print $1}')"

./scripts/generate-homebrew-formula.sh \
  --formula-class "$FORMULA_CLASS" \
  --homepage "$HOMEPAGE" \
  --version "$VERSION" \
  --url "${HOMEPAGE}/releases/download/${TAG}/$(basename "$HOMEBREW_ARCHIVE")" \
  --sha256 "$HOMEBREW_SHA" \
  > "$FORMULA_OUT"

grep -q 'depends_on macos: :sonoma' "$FORMULA_OUT"
grep -q 'libexec.install "axe", "Frameworks", "AXe_AXe.bundle"' "$FORMULA_OUT"
grep -q 'bin.write_exec_script libexec/"axe"' "$FORMULA_OUT"
grep -q 'def post_install' "$FORMULA_OUT"

tmp_dir="$WORK_DIR/normalized-formulas"
mkdir -p "$tmp_dir"
normalize_formula() {
  local input_path="$1"
  perl \
    -pe 's/^  desc ".*"$/  desc "<normalized>"/;' \
    -pe 's/^  version ".*"$/  version "<normalized>"/;' \
    -pe 's/^  url ".*"$/  url "<normalized>"/;' \
    -pe 's/^  sha256 ".*"$/  sha256 "<normalized>"/;' \
    "$input_path"
}

normalize_formula "$FORMULA_OUT" > "$tmp_dir/generated.rb"
normalize_formula "$CANONICAL_FORMULA_PATH" > "$tmp_dir/canonical.rb"

cmp -s "$tmp_dir/generated.rb" "$tmp_dir/canonical.rb"

node <<'NODE'
const { execFileSync } = require('node:child_process');

function resolve(mode, ref, sha, runNumber) {
  const output = execFileSync('node', ['scripts/release-context.mjs', '--mode', mode, '--requested-ref', ref, '--commit-sha', sha, '--run-number', runNumber], { encoding: 'utf8' });
  return Object.fromEntries(output.trim().split('\n').map((line) => line.split('=')));
}

const productionShipping = resolve('production-shipping', 'refs/tags/v1.5.2', 'abcdef0123456789', '42');
if (productionShipping.publishRelease !== 'true' || productionShipping.updateTapTarget !== 'production' || productionShipping.stageSource !== 'notarized-package') {
  throw new Error('production-shipping context is invalid');
}

const productionVerify = resolve('production-verify', 'refs/tags/v1.5.2-beta.1', 'abcdef0123456789', '42');
if (productionVerify.publishRelease !== 'false' || productionVerify.uploadArtifacts !== 'true' || productionVerify.updateTapTarget !== 'none') {
  throw new Error('production-verify context is invalid');
}

const stagingPublish = resolve('staging-publish', 'refs/heads/main', 'abcdef0123456789', '42');
if (stagingPublish.publishRelease !== 'true' || stagingPublish.uploadArtifacts !== 'false' || stagingPublish.updateTapTarget !== 'staging' || stagingPublish.stageSource !== 'build-output') {
  throw new Error('staging-publish context is invalid');
}

const stagingValidate = resolve('staging-validate', 'refs/heads/feature/release-work', 'abcdef0123456789', '42');
if (stagingValidate.publishRelease !== 'false' || stagingValidate.uploadArtifacts !== 'true' || stagingValidate.updateTapTarget !== 'none' || stagingValidate.notesMode !== 'none' || stagingValidate.stageSource !== 'build-output') {
  throw new Error('staging-validate context is invalid');
}
NODE

grep -q '^  pull_request:$' .github/workflows/release-staging.yml
grep -q "description: 'Exact ref to build for staging (branch, tag, or SHA)'" .github/workflows/release-staging.yml
grep -q '^        required: true$' .github/workflows/release-staging.yml
grep -q '^        default: validate$' .github/workflows/release-staging.yml
grep -q '^  staging-validate:$' .github/workflows/release-staging.yml
grep -q '^  staging-publish:$' .github/workflows/release-staging.yml
grep -q "mode: staging-validate" .github/workflows/release-staging.yml
grep -q "mode: staging-publish" .github/workflows/release-staging.yml
grep -q "github.event_name == 'pull_request' && github.sha" .github/workflows/release-staging.yml
! grep -q 'defaults to main' .github/workflows/release-staging.yml
! grep -q "github.event_name == 'pull_request' && github.event.pull_request.head.sha" .github/workflows/release-staging.yml

echo "[release-dry-run] OK"
echo "[release-dry-run] universal archive: $UNIVERSAL_ARCHIVE"
echo "[release-dry-run] homebrew archive: $HOMEBREW_ARCHIVE"
echo "[release-dry-run] formula: $FORMULA_OUT"
