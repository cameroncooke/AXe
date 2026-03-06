#!/usr/bin/env bash

set -euo pipefail

# Shared payload helper
# shellcheck source=./release-payload.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-payload.sh"

EXPECTED_FRAMEWORKS=(
  "FBControlCore"
  "XCTestBootstrap"
  "FBSimulatorControl"
  "FBDeviceControl"
)

usage() {
  cat <<'EOF'
Usage:
  scripts/release-artifacts.sh extract-stage --package-zip ZIP --stage-dir DIR
  scripts/release-artifacts.sh stage-build-output --build-output-dir DIR --stage-dir DIR
  scripts/release-artifacts.sh verify-stage --stage-dir DIR
  scripts/release-artifacts.sh create-universal-archive --stage-dir DIR --archive PATH
  scripts/release-artifacts.sh create-homebrew-archive --stage-dir DIR --archive PATH
  scripts/release-artifacts.sh smoke-test-stage --stage-dir DIR
  scripts/release-artifacts.sh smoke-test-archive --archive PATH
EOF
}

fail() {
  echo "❌ $*" >&2
  exit 1
}

require_arg() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "Missing required argument: $name"
}

verify_arch() {
  local binary_path="$1"
  local expected_arch="$2"

  [[ -f "$binary_path" ]] || fail "Binary not found: $binary_path"

  local arch_info
  arch_info="$(lipo -info "$binary_path" 2>/dev/null || true)"
  [[ "$arch_info" == *"$expected_arch"* ]] || fail "Missing architecture '$expected_arch' in $binary_path"
}

strip_signatures() {
  local stage_dir="$1"

  while IFS= read -r -d '' file_path; do
    if file "$file_path" | grep -q "Mach-O"; then
      codesign --remove-signature "$file_path" 2>/dev/null || true
    fi
  done < <(find "$stage_dir" -type f -print0)

  while IFS= read -r -d '' bundle_path; do
    codesign --remove-signature "$bundle_path" 2>/dev/null || true
  done < <(find "$stage_dir" \( -type d -name "*.framework" -o -type d -name "*.bundle" \) -print0)
}

copy_stage_payload() {
  local source_dir="$1"
  local stage_dir="$2"

  copy_release_payload "$source_dir" "$stage_dir"
}

extract_stage() {
  local package_zip="$1"
  local stage_dir="$2"
  local extract_root

  [[ -f "$package_zip" ]] || fail "Package zip not found: $package_zip"

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"

  extract_root="$(mktemp -d "${TMPDIR:-/tmp}/axe-release-stage.XXXXXX")"

  ditto -x -k "$package_zip" "$extract_root"

  local top_level_dir_count
  local top_level_file_count
  local package_root

  top_level_dir_count="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  top_level_file_count="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')"

  if [[ "$top_level_dir_count" -eq 1 && "$top_level_file_count" -eq 0 ]]; then
    package_root="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d | head -1)"
  else
    package_root="$extract_root"
  fi

  copy_stage_payload "$package_root" "$stage_dir"
  rm -rf "$extract_root"
  echo "✅ Extracted staged payload to $stage_dir"
}

stage_build_output() {
  local build_output_dir="$1"
  local stage_dir="$2"

  copy_stage_payload "$build_output_dir" "$stage_dir"
  echo "✅ Materialized staged payload from build output to $stage_dir"
}

verify_stage() {
  local stage_dir="$1"
  local framework_name
  local framework_path
  local framework_binary

  [[ -d "$stage_dir" ]] || fail "Stage directory not found: $stage_dir"
  [[ -x "$stage_dir/axe" ]] || fail "Stage is missing executable axe"
  [[ -d "$stage_dir/Frameworks" ]] || fail "Stage is missing Frameworks directory"
  [[ -d "$stage_dir/AXe_AXe.bundle" ]] || fail "Stage is missing AXe_AXe.bundle"

  verify_arch "$stage_dir/axe" "arm64"
  verify_arch "$stage_dir/axe" "x86_64"

  for framework_name in "${EXPECTED_FRAMEWORKS[@]}"; do
    framework_path="$stage_dir/Frameworks/${framework_name}.framework"
    [[ -d "$framework_path" ]] || fail "Missing framework in staged payload: ${framework_name}.framework"
    framework_binary="$(resolve_framework_binary "$framework_path" "$framework_name" || true)"
    [[ -n "$framework_binary" ]] || fail "Could not locate binary for framework ${framework_name}"
    verify_arch "$framework_binary" "arm64"
    verify_arch "$framework_binary" "x86_64"
  done

  echo "✅ Verified staged payload contract and architectures"
}

create_archive() {
  local stage_dir="$1"
  local archive_path="$2"
  local strip_before_archive="$3"
  local archive_root

  verify_stage "$stage_dir"

  archive_root="$(mktemp -d "${TMPDIR:-/tmp}/axe-release-archive.XXXXXX")"

  cp -R "$stage_dir"/. "$archive_root"/

  if [[ "$strip_before_archive" == "true" ]]; then
    strip_signatures "$archive_root"
  fi

  rm -f "$archive_path"
  mkdir -p "$(dirname "$archive_path")"
  tar -czf "$archive_path" -C "$archive_root" .
  rm -rf "$archive_root"
  echo "✅ Created archive: $archive_path"
}

smoke_test_stage() {
  local stage_dir="$1"

  verify_stage "$stage_dir"
  "$stage_dir/axe" --version >/dev/null
  "$stage_dir/axe" init --print | grep -q "name: axe"
  echo "✅ Smoke-tested staged payload"
}

smoke_test_archive() {
  local archive_path="$1"
  local stage_dir

  [[ -f "$archive_path" ]] || fail "Archive not found: $archive_path"

  stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/axe-release-smoke.XXXXXX")"

  tar -xzf "$archive_path" -C "$stage_dir"
  smoke_test_stage "$stage_dir"
  rm -rf "$stage_dir"
  echo "✅ Smoke-tested archive: $archive_path"
}

command_name="${1:-}"
shift || true

package_zip=""
build_output_dir=""
stage_dir=""
archive_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-zip)
      package_zip="${2:-}"
      shift 2
      ;;
    --build-output-dir)
      build_output_dir="${2:-}"
      shift 2
      ;;
    --stage-dir)
      stage_dir="${2:-}"
      shift 2
      ;;
    --archive)
      archive_path="${2:-}"
      shift 2
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

case "$command_name" in
  extract-stage)
    require_arg --package-zip "$package_zip"
    require_arg --stage-dir "$stage_dir"
    extract_stage "$package_zip" "$stage_dir"
    ;;
  stage-build-output)
    require_arg --build-output-dir "$build_output_dir"
    require_arg --stage-dir "$stage_dir"
    stage_build_output "$build_output_dir" "$stage_dir"
    ;;
  verify-stage)
    require_arg --stage-dir "$stage_dir"
    verify_stage "$stage_dir"
    ;;
  create-universal-archive)
    require_arg --stage-dir "$stage_dir"
    require_arg --archive "$archive_path"
    create_archive "$stage_dir" "$archive_path" false
    ;;
  create-homebrew-archive)
    require_arg --stage-dir "$stage_dir"
    require_arg --archive "$archive_path"
    create_archive "$stage_dir" "$archive_path" true
    ;;
  smoke-test-stage)
    require_arg --stage-dir "$stage_dir"
    smoke_test_stage "$stage_dir"
    ;;
  smoke-test-archive)
    require_arg --archive "$archive_path"
    smoke_test_archive "$archive_path"
    ;;
  ''|-h|--help|help)
    usage
    ;;
  *)
    fail "Unknown command: $command_name"
    ;;
esac
