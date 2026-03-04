#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_DIR="${WORK_DIR:-$ROOT_DIR/.release-dry-run}"
TAG="${TAG:-v0.0.0-dryrun}"
VERSION="${TAG#v}"
FORMULA_NAME="${FORMULA_NAME:-axe}"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/universal" "$WORK_DIR/arm64" "$WORK_DIR/x64" "$WORK_DIR/out"

echo "[release-dry-run] Preparing universal test binary"
BIN_PATH="/usr/bin/file"

if [[ ! -f "$BIN_PATH" ]]; then
  echo "[release-dry-run] ERROR: required system binary missing at $BIN_PATH"
  exit 1
fi

lipo -info "$BIN_PATH" | grep -q "arm64"
lipo -info "$BIN_PATH" | grep -q "x86_64"

cp "$BIN_PATH" "$WORK_DIR/universal/axe"
mkdir -p "$WORK_DIR/universal/Frameworks/Fake.framework"
cp "$BIN_PATH" "$WORK_DIR/universal/Frameworks/Fake.framework/Fake"

cp -R "$WORK_DIR/universal"/. "$WORK_DIR/arm64"/
cp -R "$WORK_DIR/universal"/. "$WORK_DIR/x64"/

thin_tree_for_arch() {
  local root_path="$1"
  local target_arch="$2"

  while IFS= read -r -d '' file_path; do
    if file "$file_path" | grep -q "Mach-O"; then
      local arch_info
      arch_info="$(lipo -info "$file_path" 2>/dev/null || true)"
      if [[ "$arch_info" == *"Non-fat file"* ]]; then
        if [[ "$arch_info" != *"$target_arch"* ]]; then
          echo "[release-dry-run] ERROR: non-fat binary mismatch for $target_arch: $file_path"
          exit 1
        fi
      else
        lipo -thin "$target_arch" "$file_path" -output "${file_path}.thin"
        mv "${file_path}.thin" "$file_path"
      fi
      codesign --remove-signature "$file_path" 2>/dev/null || true
    fi
  done < <(find "$root_path" -type f -print0)

  find "$root_path" -type d -name "*.framework" -print0 | while IFS= read -r -d '' bundle; do
    codesign --remove-signature "$bundle" 2>/dev/null || true
  done
}

thin_tree_for_arch "$WORK_DIR/arm64" "arm64"
thin_tree_for_arch "$WORK_DIR/x64" "x86_64"

lipo -info "$WORK_DIR/arm64/axe" | grep -q "arm64"
lipo -info "$WORK_DIR/x64/axe" | grep -q "x86_64"

ARM64_ARCHIVE="$WORK_DIR/out/AXe-macOS-homebrew-${TAG}-arm64.tar.gz"
X64_ARCHIVE="$WORK_DIR/out/AXe-macOS-homebrew-${TAG}-x64.tar.gz"

tar -czf "$ARM64_ARCHIVE" -C "$WORK_DIR/arm64" .
tar -czf "$X64_ARCHIVE" -C "$WORK_DIR/x64" .

ARM64_SHA="$(shasum -a 256 "$ARM64_ARCHIVE" | awk '{print $1}')"
X64_SHA="$(shasum -a 256 "$X64_ARCHIVE" | awk '{print $1}')"

FORMULA_CLASS="$(echo "$FORMULA_NAME" | awk -F'[-_]' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print $0}' OFS="")"
FORMULA_OUT="$WORK_DIR/out/${FORMULA_NAME}.rb"
BASE_URL="https://github.com/cameroncooke/AXe/releases/download/${TAG}"

{
  echo "class ${FORMULA_CLASS} < Formula"
  echo "  desc \"CLI tool for interacting with iOS Simulators via accessibility and HID APIs\""
  echo "  homepage \"https://github.com/cameroncooke/AXe\""
  echo "  license \"MIT\""
  echo "  version \"${VERSION}\""
  echo
  echo "  on_arm do"
  echo "    url \"${BASE_URL}/$(basename "$ARM64_ARCHIVE")\""
  echo "    sha256 \"${ARM64_SHA}\""
  echo "  end"
  echo
  echo "  on_intel do"
  echo "    url \"${BASE_URL}/$(basename "$X64_ARCHIVE")\""
  echo "    sha256 \"${X64_SHA}\""
  echo "  end"
  echo
  echo "  def install"
  echo "    libexec.install \"axe\", \"Frameworks\""
  echo "    bin.write_exec_script libexec/\"axe\""
  echo "  end"
  echo
  echo "  test do"
  echo "    assert_match version.to_s, shell_output(\"#{bin}/axe --version\")"
  echo "  end"
  echo "end"
} > "$FORMULA_OUT"

grep -q "on_arm do" "$FORMULA_OUT"
grep -q "on_intel do" "$FORMULA_OUT"
grep -q "libexec.install \"axe\", \"Frameworks\"" "$FORMULA_OUT"

echo "[release-dry-run] OK"
echo "[release-dry-run] arm64 archive: $ARM64_ARCHIVE"
echo "[release-dry-run] x64 archive: $X64_ARCHIVE"
echo "[release-dry-run] formula: $FORMULA_OUT"
