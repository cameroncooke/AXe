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

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/universal/Frameworks/Fake.framework" "$WORK_DIR/universal/AXe_AXe.bundle" "$WORK_DIR/out" "$WORK_DIR/homebrew"

echo "[release-dry-run] Preparing universal test binary"
BIN_PATH="/usr/bin/file"

if [[ ! -f "$BIN_PATH" ]]; then
  echo "[release-dry-run] ERROR: required system binary missing at $BIN_PATH"
  exit 1
fi

lipo -info "$BIN_PATH" | grep -q "arm64"
lipo -info "$BIN_PATH" | grep -q "x86_64"

cp "$BIN_PATH" "$WORK_DIR/universal/axe"
cp "$BIN_PATH" "$WORK_DIR/universal/Frameworks/Fake.framework/Fake"
printf 'name: axe\n' > "$WORK_DIR/universal/AXe_AXe.bundle/manifest.txt"

UNIVERSAL_ARCHIVE="$WORK_DIR/out/AXe-macOS-${TAG}-universal.tar.gz"
HOMEBREW_ARCHIVE="$WORK_DIR/out/AXe-macOS-homebrew-${TAG}.tar.gz"
FORMULA_OUT="$WORK_DIR/out/${FORMULA_NAME}.rb"

tar -czf "$UNIVERSAL_ARCHIVE" -C "$WORK_DIR/universal" .
mkdir -p "$WORK_DIR/out/universal-extract"
tar -xzf "$UNIVERSAL_ARCHIVE" -C "$WORK_DIR/out/universal-extract"
test -f "$WORK_DIR/out/universal-extract/axe"
test -d "$WORK_DIR/out/universal-extract/Frameworks/Fake.framework"
test -f "$WORK_DIR/out/universal-extract/Frameworks/Fake.framework/Fake"
test -d "$WORK_DIR/out/universal-extract/AXe_AXe.bundle"

cp -R "$WORK_DIR/universal"/. "$WORK_DIR/homebrew"/

while IFS= read -r -d '' file_path; do
  if file "$file_path" | grep -q "Mach-O"; then
    codesign --remove-signature "$file_path" 2>/dev/null || true
  fi
done < <(find "$WORK_DIR/homebrew" -type f -print0)

find "$WORK_DIR/homebrew" \( -type d -name "*.framework" -o -type d -name "*.bundle" \) -print0 | while IFS= read -r -d '' bundle; do
  codesign --remove-signature "$bundle" 2>/dev/null || true
done

tar -czf "$HOMEBREW_ARCHIVE" -C "$WORK_DIR/homebrew" .
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
grep -q 'def post_install' "$FORMULA_OUT"

echo "[release-dry-run] OK"
echo "[release-dry-run] universal archive: $UNIVERSAL_ARCHIVE"
echo "[release-dry-run] homebrew archive: $HOMEBREW_ARCHIVE"
echo "[release-dry-run] formula: $FORMULA_OUT"
