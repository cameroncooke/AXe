#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/test-homebrew-archive.sh --package /path/to/archive [--output-dir DIR]
                                       [--formula-name NAME] [--bin-name NAME]

Creates a local Homebrew archive by stripping signatures from the notarized package,
then generates a local formula pointing to the tarball for testing install behavior.
USAGE
}

ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

PACKAGE_ARCHIVE=""
OUTPUT_DIR="./build_products/homebrew-test"
FORMULA_NAME="axe-local"
BIN_NAME="axe-local"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package|--package-zip)
      shift
      PACKAGE_ARCHIVE="${1:-}"
      ;;
    --output-dir)
      shift
      OUTPUT_DIR="${1:-}"
      ;;
    --formula-name)
      shift
      FORMULA_NAME="${1:-}"
      ;;
    --bin-name)
      shift
      BIN_NAME="${1:-}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift || true
  done

if [[ -z "$PACKAGE_ARCHIVE" ]]; then
  echo "Missing --package" >&2
  usage
  exit 1
fi

if [[ ! -f "$PACKAGE_ARCHIVE" ]]; then
  echo "Package not found: $PACKAGE_ARCHIVE" >&2
  exit 1
fi

ensure_command tar
ensure_command file
ensure_command codesign
ensure_command otool
ensure_command awk
ensure_command grep
ensure_command install_name_tool
ensure_command basename

to_class_name() {
  echo "$1" | awk -F '[-_]' '{out=""; for (i=1;i<=NF;i++){ out=out toupper(substr($i,1,1)) substr($i,2) } print out }'
}

mkdir -p "$OUTPUT_DIR"
WORK_DIR="${OUTPUT_DIR}/work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
echo "Extracting package into $WORK_DIR"

# Extract the package (tar.gz or tgz only).
ARCHIVE_TYPE=$(file -b "$PACKAGE_ARCHIVE")
if echo "$ARCHIVE_TYPE" | grep -qi "gzip compressed data"; then
  tar -xzf "$PACKAGE_ARCHIVE" -C "$WORK_DIR"
else
  echo "Unsupported package format: $PACKAGE_ARCHIVE ($ARCHIVE_TYPE)" >&2
  exit 1
fi

if [[ -z "$(ls -A "$WORK_DIR")" ]]; then
  echo "Extraction produced no files. Contents of $WORK_DIR:" >&2
  ls -la "$WORK_DIR" >&2
  exit 1
fi

echo "Extracted files:"
find "$WORK_DIR" -maxdepth 2 -print

TOP_LEVEL_DIR_COUNT=$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
TOP_LEVEL_FILE_COUNT=$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')
if [[ "$TOP_LEVEL_DIR_COUNT" -eq 1 && "$TOP_LEVEL_FILE_COUNT" -eq 0 ]]; then
  PACKAGE_ROOT=$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
else
  PACKAGE_ROOT="$WORK_DIR"
fi

echo "Packaging from: $PACKAGE_ROOT"

echo "Stripping code signatures"
# Strip signatures to mirror Homebrew-friendly packaging.
while IFS= read -r -d '' file; do
  if file "$file" | grep -q "Mach-O"; then
    codesign --remove-signature "$file" 2>/dev/null || true
  fi
done < <(find "$WORK_DIR" -type f -print0)

find "$WORK_DIR" -type d -name "*.framework" -print0 | while IFS= read -r -d '' bundle; do
  codesign --remove-signature "$bundle" 2>/dev/null || true
  done

echo "Removing Xcode toolchain rpaths"
strip_xcode_rpaths() {
  local target="$1"
  local rpaths
  rpaths=$(otool -l "$target" | awk 'BEGIN{r=0} /LC_RPATH/{r=1} r==1 && /path/{print $2; r=0}' | grep "/Applications/Xcode" || true)
  if [[ -n "$rpaths" ]]; then
    while IFS= read -r path; do
      install_name_tool -delete_rpath "$path" "$target" || true
    done <<< "$rpaths"
  fi
}

if [[ -f "$PACKAGE_ROOT/axe" ]]; then
  strip_xcode_rpaths "$PACKAGE_ROOT/axe"
fi

if [[ -d "$PACKAGE_ROOT/Frameworks" ]]; then
  while IFS= read -r -d '' file; do
    if file "$file" | grep -q "Mach-O"; then
      strip_xcode_rpaths "$file"
    fi
  done < <(find "$PACKAGE_ROOT/Frameworks" -type f -print0)
fi

echo "Ad-hoc signing binaries for execution"
if [[ -f "$PACKAGE_ROOT/axe" ]]; then
  codesign --force --sign - "$PACKAGE_ROOT/axe"
fi

if [[ -d "$PACKAGE_ROOT/Frameworks" ]]; then
  while IFS= read -r -d '' file; do
    if file "$file" | grep -q "Mach-O"; then
      codesign --force --sign - "$file"
    fi
  done < <(find "$PACKAGE_ROOT/Frameworks" -type f -print0)

  find "$PACKAGE_ROOT/Frameworks" -type d -name "*.framework" -print0 | \
    while IFS= read -r -d '' bundle; do
      codesign --force --sign - --deep "$bundle"
    done
fi

OUTPUT_DIR_ABS="$(cd "$OUTPUT_DIR" && pwd)"
ARCHIVE_PATH="${OUTPUT_DIR_ABS}/AXe-macOS-homebrew-local.tar.gz"
rm -f "$ARCHIVE_PATH"
echo "Creating tar.gz artifact"
tar -czf "$ARCHIVE_PATH" -C "$PACKAGE_ROOT" .

SHA256=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')

FORMULA_CLASS="$(to_class_name "$FORMULA_NAME")"
FORMULA_PATH="${OUTPUT_DIR_ABS}/${FORMULA_NAME}.rb"
{
  printf 'class %s < Formula\n' "$FORMULA_CLASS"
  printf '%s\n' '  desc "AXe simulator automation CLI"'
  printf '%s\n' '  homepage "https://github.com/cameroncooke/AXe"'
  printf '  url "file://%s"\n' "$ARCHIVE_PATH"
  printf '%s\n' '  version "local"'
  printf '  sha256 "%s"\n' "$SHA256"
  printf '\n'
  printf '%s\n' '  def install'
  printf '%s\n' '    libexec.install Dir["*"]'
  printf '    bin.install_symlink libexec/"axe" => "%s"\n' "$BIN_NAME"
  printf '%s\n' '  end'
  printf '%s\n' 'end'
} > "$FORMULA_PATH"

printf '%s\n' "Created:"
printf '%s\n' "- ${ARCHIVE_PATH}"
printf '%s\n' "- ${FORMULA_PATH}"
printf '%s\n' ""
printf '%s\n' "Next steps:"
printf '%s\n' "1) TAP_DIR=\$(mktemp -d /tmp/${FORMULA_NAME}-tap.XXXX)"
printf '%s\n' "2) mkdir -p \"\$TAP_DIR/Formula\" && cp \"${FORMULA_PATH}\" \"\$TAP_DIR/Formula/${FORMULA_NAME}.rb\""
printf '%s\n' "3) (cd \"\$TAP_DIR\" && git init -q && git add Formula/${FORMULA_NAME}.rb && git -c commit.gpgsign=false commit -m \"Add ${FORMULA_NAME}\" -q)"
printf '%s\n' "4) brew tap local/${FORMULA_NAME} \"\$TAP_DIR\""
printf '%s\n' "5) brew reinstall local/${FORMULA_NAME}/${FORMULA_NAME}"
printf '%s\n' "6) which ${BIN_NAME}"
printf '%s\n' "7) codesign -dv --verbose=4 \"\$(which ${BIN_NAME})\" 2>&1 | head -n 20"
printf '%s\n' "8) spctl -a -vv \"\$(which ${BIN_NAME})\" 2>&1"
printf '%s\n' "9) xattr -l \"\$(which ${BIN_NAME})\" 2>/dev/null || true"
printf '%s\n' ""
printf '%s\n' "To uninstall:"
printf '%s\n' "- brew uninstall ${FORMULA_NAME}"
