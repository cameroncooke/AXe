#!/bin/bash
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

usage() {
  cat <<'USAGE'
Usage:
  scripts/diagnose-homebrew-linkage.sh (--package PATH | --root DIR)
    [--work-dir DIR] [--keep-work] [--strict]

What it does:
  - Extracts an AXe release artifact (tar.gz/tgz/zip) OR scans an already-extracted root directory
  - Finds all Mach-O files
  - Reports:
      * absolute install-name dependencies (e.g. /usr/local, /opt/homebrew)
      * Xcode toolchain rpaths (/Applications/Xcode...)
  - Runs a deterministic "header growth" probe on copies of each Mach-O:
      * install_name_tool -add_rpath <very-long-path>
      * for dylibs/framework binaries: install_name_tool -id <very-long-id>
    If either fails with "load commands do not fit", the binary likely lacks -headerpad_max_install_names.

Exit codes:
  - default: exits 0 always, prints findings
  - --strict: exits 1 if any headerpad failures or absolute dependencies are found

Examples:
  # Diagnose a release tarball:
  scripts/diagnose-homebrew-linkage.sh --package /tmp/AXe-macOS-v1.2.0.tar.gz --strict

  # Diagnose a notarized zip (AXe-Final-*.zip):
  scripts/diagnose-homebrew-linkage.sh --package ./AXe-Final-20251219-231208.zip

  # Diagnose an extracted directory:
  scripts/diagnose-homebrew-linkage.sh --root ./build_products/homebrew-test/work/AXe-Final-20251219-231208 --strict
USAGE
}

ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 2
  fi
}

PACKAGE_PATH=""
ROOT_DIR=""
WORK_DIR=""
KEEP_WORK="false"
STRICT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)
      shift
      PACKAGE_PATH="${1:-}"
      ;;
    --root)
      shift
      ROOT_DIR="${1:-}"
      ;;
    --work-dir)
      shift
      WORK_DIR="${1:-}"
      ;;
    --keep-work)
      KEEP_WORK="true"
      ;;
    --strict)
      STRICT="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift || true
done

if [[ -z "$PACKAGE_PATH" && -z "$ROOT_DIR" ]]; then
  echo "Error: must provide --package or --root" >&2
  usage
  exit 2
fi

ensure_command file
ensure_command find
ensure_command otool
ensure_command install_name_tool
ensure_command awk
ensure_command grep
ensure_command mktemp
ensure_command basename
ensure_command dirname

if [[ -n "$PACKAGE_PATH" && ! -f "$PACKAGE_PATH" ]]; then
  echo "Error: package not found: $PACKAGE_PATH" >&2
  exit 2
fi
if [[ -n "$ROOT_DIR" && ! -d "$ROOT_DIR" ]]; then
  echo "Error: root dir not found: $ROOT_DIR" >&2
  exit 2
fi

extract_package() {
  local pkg="$1"
  local out="$2"

  mkdir -p "$out"

  local ft
  ft="$(file -b "$pkg" || true)"

  if echo "$ft" | grep -qi "Zip archive data"; then
    ensure_command unzip
    unzip -q "$pkg" -d "$out"
    return 0
  fi

  if echo "$ft" | grep -qi "gzip compressed data"; then
    ensure_command tar
    tar -xzf "$pkg" -C "$out"
    return 0
  fi

  echo "Unsupported package type: $pkg ($ft)" >&2
  return 1
}

resolve_root() {
  local dir="$1"
  local top_dir_count
  local top_file_count
  top_dir_count="$(find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  top_file_count="$(find "$dir" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')"
  if [[ "$top_dir_count" -eq 1 && "$top_file_count" -eq 0 ]]; then
    find "$dir" -mindepth 1 -maxdepth 1 -type d | head -1
  else
    echo "$dir"
  fi
}

list_rpaths() {
  otool -l "$1" 2>/dev/null \
    | awk 'BEGIN{in_rpath=0} $0 ~ /cmd LC_RPATH/{in_rpath=1; next} in_rpath==1 && $0 ~ /path /{print $2; in_rpath=0}'
}

dylib_id() {
  otool -D "$1" 2>/dev/null | tail -n +2 | head -n 1 || true
}

echo ""
echo "AXe Homebrew Linkage Diagnostics"
echo "============================================================"

TMP_CREATED="false"
if [[ -n "$PACKAGE_PATH" ]]; then
  if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d)"
    TMP_CREATED="true"
  fi
  echo "Package: $PACKAGE_PATH"
  echo "Work dir: $WORK_DIR"
  echo "Extracting..."
  extract_package "$PACKAGE_PATH" "$WORK_DIR"
  ROOT_DIR="$(resolve_root "$WORK_DIR")"
fi

ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
echo "Scan root: $ROOT_DIR"
echo ""

MACHO_COUNT=0
ABS_DEP_HITS=0
XCODE_RPATH_HITS=0
HEADERPAD_FAILS=0

ABS_DEP_REPORT="$(mktemp)"
XCODE_RPATH_REPORT="$(mktemp)"
HEADERPAD_REPORT="$(mktemp)"

LONG_RPATH="/opt/homebrew/opt/axe/libexec/Frameworks/THIS_IS_A_VERY_LONG_RPATH_INTENDED_TO_FORCE_LOAD_COMMAND_GROWTH_AND_TRIGGER_HEADERPAD_LIMITS_0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ"
LONG_ID="/opt/homebrew/opt/axe/libexec/Frameworks/THIS_IS_A_VERY_LONG_INSTALL_NAME_INTENDED_TO_FORCE_LOAD_COMMAND_GROWTH_AND_TRIGGER_HEADERPAD_LIMITS_0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ/libWhatever.dylib"

echo "Finding Mach-O files..."
while IFS= read -r -d '' f; do
  if file "$f" 2>/dev/null | grep -q "Mach-O"; then
    MACHO_COUNT=$((MACHO_COUNT + 1))

    deps="$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)"
    if echo "$deps" | grep -qE '^(/usr/local|/opt/homebrew)'; then
      ABS_DEP_HITS=$((ABS_DEP_HITS + 1))
      {
        echo "== $f"
        echo "$deps" | grep -E '^(/usr/local|/opt/homebrew)' || true
        echo ""
      } >> "$ABS_DEP_REPORT"
    fi

    rpaths="$(list_rpaths "$f" || true)"
    if echo "$rpaths" | grep -q "/Applications/Xcode"; then
      XCODE_RPATH_HITS=$((XCODE_RPATH_HITS + 1))
      {
        echo "== $f"
        echo "$rpaths" | grep "/Applications/Xcode" || true
        echo ""
      } >> "$XCODE_RPATH_REPORT"
    fi

    tmp1="$(mktemp)"
    cp "$f" "$tmp1"
    err1="$( (install_name_tool -add_rpath "$LONG_RPATH" "$tmp1") 2>&1 )" || true
    rm -f "$tmp1"
    if echo "$err1" | grep -qi "load commands do not fit"; then
      HEADERPAD_FAILS=$((HEADERPAD_FAILS + 1))
      {
        echo "== $f"
        echo "Probe: install_name_tool -add_rpath <LONG> failed:"
        echo "$err1"
        echo ""
      } >> "$HEADERPAD_REPORT"
    fi

    id="$(dylib_id "$f")"
    if [[ -n "$id" ]]; then
      tmp2="$(mktemp)"
      cp "$f" "$tmp2"
      err2="$( (install_name_tool -id "$LONG_ID" "$tmp2") 2>&1 )" || true
      rm -f "$tmp2"
      if echo "$err2" | grep -qi "load commands do not fit"; then
        HEADERPAD_FAILS=$((HEADERPAD_FAILS + 1))
        {
          echo "== $f"
          echo "Probe: install_name_tool -id <LONG> failed:"
          echo "$err2"
          echo ""
        } >> "$HEADERPAD_REPORT"
      fi
    fi
  fi
done < <(find "$ROOT_DIR" -type f -print0)

echo ""
echo "Summary"
echo "------------------------------------------------------------"
echo "Mach-O files found:                      $MACHO_COUNT"
echo "Files w/ /usr/local or /opt/homebrew deps: $ABS_DEP_HITS"
echo "Files w/ Xcode toolchain rpaths:         $XCODE_RPATH_HITS"
echo "Headerpad probe failures:                $HEADERPAD_FAILS"
echo ""

if [[ "$ABS_DEP_HITS" -gt 0 ]]; then
  echo "Absolute dependency hits (/usr/local, /opt/homebrew)"
  echo "------------------------------------------------------------"
  cat "$ABS_DEP_REPORT"
fi

if [[ "$XCODE_RPATH_HITS" -gt 0 ]]; then
  echo "Xcode toolchain rpath hits (/Applications/Xcode...)"
  echo "------------------------------------------------------------"
  cat "$XCODE_RPATH_REPORT"
fi

if [[ "$HEADERPAD_FAILS" -gt 0 ]]; then
  echo "Headerpad probe failures ('load commands do not fit')"
  echo "------------------------------------------------------------"
  cat "$HEADERPAD_REPORT"
  echo "Recommendation: rebuild the failing binaries with -Wl,-headerpad_max_install_names"
  echo ""
fi

rm -f "$ABS_DEP_REPORT" "$XCODE_RPATH_REPORT" "$HEADERPAD_REPORT"

if [[ "$TMP_CREATED" == "true" && "$KEEP_WORK" != "true" ]]; then
  rm -rf "$WORK_DIR"
fi

if [[ "$STRICT" == "true" ]]; then
  if [[ "$ABS_DEP_HITS" -gt 0 || "$HEADERPAD_FAILS" -gt 0 ]]; then
    exit 1
  fi
fi

exit 0
