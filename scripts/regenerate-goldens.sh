#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ROOT="$ROOT_DIR/Tests/Goldens"
MODE="update"
AXE_BIN=""
SIMULATOR_UDID=""
MATRIX_ID=""
SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-}"
FIXTURE_SCREEN="tap-test"

usage() {
  printf '%s\n' \
    "Usage:" \
    "  scripts/regenerate-goldens.sh --axe PATH --udid UDID --matrix-id ID [options]" \
    "" \
    "Options:" \
    "  --developer-dir PATH   Select Xcode without changing xcode-select" \
    "  --fixture-screen NAME  AxePlayground screen (default: tap-test)" \
    "  --output-root PATH     Golden root (default: Tests/Goldens)" \
    "  --check                Compare generated contracts with checked-in goldens" \
    "  --update               Replace the matrix-scoped goldens (default)" \
    "  -h, --help             Show this help"
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
    --axe)
      require_value "$1" "${2:-}"
      AXE_BIN="$2"
      shift 2
      ;;
    --udid)
      require_value "$1" "${2:-}"
      SIMULATOR_UDID="$2"
      shift 2
      ;;
    --matrix-id)
      require_value "$1" "${2:-}"
      MATRIX_ID="$2"
      shift 2
      ;;
    --developer-dir)
      require_value "$1" "${2:-}"
      SELECTED_DEVELOPER_DIR="$2"
      shift 2
      ;;
    --fixture-screen)
      require_value "$1" "${2:-}"
      FIXTURE_SCREEN="$2"
      shift 2
      ;;
    --output-root)
      require_value "$1" "${2:-}"
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --check)
      MODE="check"
      shift
      ;;
    --update)
      MODE="update"
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

[[ -x "$AXE_BIN" ]] || fail "AXe executable not found or not executable: $AXE_BIN"
[[ -n "$SIMULATOR_UDID" ]] || fail "--udid is required"
[[ "$MATRIX_ID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--matrix-id must contain only letters, numbers, '.', '_' or '-'"
[[ "$MATRIX_ID" != "." && "$MATRIX_ID" != ".." ]] || fail "--matrix-id cannot be '.' or '..'"
[[ -n "$SELECTED_DEVELOPER_DIR" ]] || fail "Set DEVELOPER_DIR or pass --developer-dir"
[[ -d "$SELECTED_DEVELOPER_DIR" ]] || fail "Developer directory not found: $SELECTED_DEVELOPER_DIR"

for command in diff jq shasum stat xcodebuild xcrun; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
done

export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
export LC_ALL=C

SIMULATOR_JSON="$(xcrun simctl list devices -j)"
SIMULATOR_STATE="$(jq -r --arg udid "$SIMULATOR_UDID" '[.devices[][] | select(.udid == $udid) | .state][0] // empty' <<< "$SIMULATOR_JSON")"
[[ "$SIMULATOR_STATE" == "Booted" ]] || fail "Simulator $SIMULATOR_UDID must be booted under $DEVELOPER_DIR"

RUNTIME_BUILD="$(xcrun simctl getenv "$SIMULATOR_UDID" SIMULATOR_RUNTIME_BUILD_VERSION)"
DEVICE_NAME="$(jq -r --arg udid "$SIMULATOR_UDID" '[.devices[][] | select(.udid == $udid) | .name][0] // empty' <<< "$SIMULATOR_JSON")"
XCODE_VERSION_OUTPUT="$(xcodebuild -version)"
XCODE_VERSION="$(awk 'NR == 1 { print }' <<< "$XCODE_VERSION_OUTPUT")"
XCODE_BUILD="$(awk '/Build version/ { print $3 }' <<< "$XCODE_VERSION_OUTPUT")"
AXE_SHA256="$(shasum -a 256 "$AXE_BIN" | awk '{ print $1 }')"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/axe-goldens.XXXXXX")"
GENERATED_DIR="$WORK_DIR/$MATRIX_ID"
STABLE_DIR="$GENERATED_DIR/stable"
WORK_DIR_MARKER_VALUE="axe-goldens-workdir:$AXE_SHA256:$$"
printf '%s\n' "$WORK_DIR_MARKER_VALUE" > "$WORK_DIR/.axe-goldens-workdir"
WORK_DIR_IDENTITY="$(stat -f '%d:%i' "$WORK_DIR")"
mkdir -p "$STABLE_DIR/cases" "$STABLE_DIR/hierarchy"

safe_remove_work_dir() {
  [[ -n "$WORK_DIR" && "$WORK_DIR" != "/" && ! -L "$WORK_DIR" && -d "$WORK_DIR" ]] \
    || fail "Refusing unsafe temporary work directory cleanup: $WORK_DIR"
  [[ "$(stat -f '%d:%i' "$WORK_DIR")" == "$WORK_DIR_IDENTITY" ]] \
    || fail "Temporary work directory identity changed: $WORK_DIR"
  [[ -f "$WORK_DIR/.axe-goldens-workdir" ]] \
    || fail "Temporary work directory ownership marker is missing: $WORK_DIR"
  [[ "$(< "$WORK_DIR/.axe-goldens-workdir")" == "$WORK_DIR_MARKER_VALUE" ]] \
    || fail "Temporary work directory ownership marker changed: $WORK_DIR"
  rm -r "$WORK_DIR"
}

cleanup() {
  if [[ -d "$WORK_DIR" ]]; then
    safe_remove_work_dir
  fi
}
trap cleanup EXIT

capture_case() {
  local name="$1"
  shift
  local case_dir="$STABLE_DIR/cases/$name"
  mkdir -p "$case_dir"

  printf 'axe ' > "$case_dir/argv.txt"
  printf '%q ' "$@" >> "$case_dir/argv.txt"
  printf '\n' >> "$case_dir/argv.txt"

  set +e
  "$AXE_BIN" "$@" > "$case_dir/stdout.txt" 2> "$case_dir/stderr.txt"
  local status=$?
  set -e
  printf '%s\n' "$status" > "$case_dir/exit-code.txt"
}

capture_stdin_case() {
  local name="$1"
  local input="$2"
  shift 2
  local case_dir="$STABLE_DIR/cases/$name"
  mkdir -p "$case_dir"

  printf 'axe ' > "$case_dir/argv.txt"
  printf '%q ' "$@" >> "$case_dir/argv.txt"
  printf '\n' >> "$case_dir/argv.txt"
  printf '%s' "$input" > "$case_dir/stdin.txt"

  set +e
  printf '%s' "$input" | "$AXE_BIN" "$@" > "$case_dir/stdout.txt" 2> "$case_dir/stderr.txt"
  local status=${PIPESTATUS[1]}
  set -e
  printf '%s\n' "$status" > "$case_dir/exit-code.txt"
}

capture_case version --version
capture_case help --help

SUBCOMMANDS=(
  batch button describe-ui drag gesture init key key-combo key-sequence
  list-simulators record-video screenshot slider stream-video swipe tap touch type
)
for subcommand in "${SUBCOMMANDS[@]}"; do
  capture_case "help-$subcommand" "$subcommand" --help
done

# Every public subcommand gets the same parser-level unknown-option contract.
# Command-specific validation cases below cover typed values, stdin, and output paths.
for subcommand in "${SUBCOMMANDS[@]}"; do
  capture_case "error-$subcommand-unknown-option" "$subcommand" --axe-invalid-option
done

VALIDATION_CASES=(
  "batch-source|batch|--udid|invalid|--step|tap -x 1 -y 1|--stdin"
  "button-value|button|invalid-button|--udid|invalid"
  "describe-ui-point|describe-ui|--udid|invalid|--point|nope"
  "drag-duration|drag|--start-x|0|--start-y|0|--end-x|1|--end-y|1|--duration|-1|--udid|invalid"
  "gesture-value|gesture|invalid-gesture|--udid|invalid"
  "init-client|init|--client|invalid-client"
  "key-value|key|256|--udid|invalid"
  "key-combo-value|key-combo|--modifiers|invalid|--key|1|--udid|invalid"
  "key-sequence-value|key-sequence|--keycodes|invalid|--udid|invalid"
  "list-simulators-value|list-simulators|unexpected"
  "record-video-fps|record-video|--udid|invalid|--fps|0"
  "screenshot-output|screenshot|--udid|invalid|--output"
  "slider-value|slider|--id|slider|--value|101|--udid|invalid"
  "stream-video-format|stream-video|--udid|invalid|--format|invalid"
  "swipe-duration|swipe|--start-x|0|--start-y|0|--end-x|1|--end-y|1|--duration|-1|--udid|invalid"
  "tap-coordinates|tap|-x|not-a-number|-y|1|--udid|invalid"
  "touch-mode|touch|-x|1|-y|1|--udid|invalid"
  "type-source|type|literal|--stdin|--udid|invalid"
)
for row in "${VALIDATION_CASES[@]}"; do
  IFS='|' read -r -a fields <<< "$row"
  case_name="${fields[0]}"
  capture_case "validation-$case_name" "${fields[@]:1}"
done

capture_stdin_case stdin-batch-empty "" batch --udid invalid --stdin
capture_stdin_case stdin-type-unsupported "💥" type --udid invalid --stdin
capture_case output-record-video-missing-value record-video --udid invalid --output
capture_case output-screenshot-missing-value screenshot --udid invalid --output
capture_case output-stream-video-stdout-format stream-video --udid invalid --format invalid

xcrun simctl get_app_container "$SIMULATOR_UDID" com.cameroncooke.AxePlayground app >/dev/null \
  || fail "AxePlayground is not installed on simulator $SIMULATOR_UDID"
xcrun simctl terminate "$SIMULATOR_UDID" com.cameroncooke.AxePlayground >/dev/null 2>&1 || true
xcrun simctl launch "$SIMULATOR_UDID" com.cameroncooke.AxePlayground --launch-arg "screen=$FIXTURE_SCREEN" >/dev/null
sleep 2

set +e
"$AXE_BIN" describe-ui --udid "$SIMULATOR_UDID" \
  > "$STABLE_DIR/hierarchy/raw.json" \
  2> "$STABLE_DIR/hierarchy/stderr.txt"
HIERARCHY_STATUS=$?
set -e
printf '%s\n' "$HIERARCHY_STATUS" > "$STABLE_DIR/hierarchy/exit-code.txt"
[[ "$HIERARCHY_STATUS" -eq 0 ]] || fail "describe-ui failed while generating hierarchy schema"

jq -S '
  def normalized_path($path):
    $path | map(if type == "number" then "[]" else tostring end) | join(".");
  ([{path: "$", type: type}] +
    [paths as $path |
      {path: ("$." + normalized_path($path)), type: (getpath($path) | type)}]) |
  sort_by(.path, .type) | unique_by([.path, .type])
' "$STABLE_DIR/hierarchy/raw.json" > "$STABLE_DIR/hierarchy/schema-types.json"
rm "$STABLE_DIR/hierarchy/raw.json"

jq -n -S \
  --arg matrix_id "$MATRIX_ID" \
  --arg xcode_version "$XCODE_VERSION" \
  --arg xcode_build "$XCODE_BUILD" \
  --arg runtime_build "$RUNTIME_BUILD" \
  --arg fixture_screen "$FIXTURE_SCREEN" \
  '{
    schema_version: 1,
    matrix_id: $matrix_id,
    xcode_version: $xcode_version,
    xcode_build: $xcode_build,
    runtime_build: $runtime_build,
    fixture_screen: $fixture_screen
  }' > "$GENERATED_DIR/contract.json"

STABLE_MANIFEST="$WORK_DIR/stable-manifest.txt"
while IFS= read -r stable_path; do
  printf '%s  %s\n' \
    "$(shasum -a 256 "$stable_path" | awk '{ print $1 }')" \
    "${stable_path#"$GENERATED_DIR/"}"
done < <(find "$GENERATED_DIR" -type f ! -name 'provenance.json' -print | sort) \
  > "$STABLE_MANIFEST"
STABLE_SHA256="$(shasum -a 256 "$STABLE_MANIFEST" | awk '{ print $1 }')"

jq -n -S \
  --arg axe_sha256 "$AXE_SHA256" \
  --arg simulator_udid "$SIMULATOR_UDID" \
  --arg device_name "$DEVICE_NAME" \
  --arg stable_sha256 "$STABLE_SHA256" \
  '{
    schema_version: 1,
    axe_payload_sha256: $axe_sha256,
    simulator: {udid: $simulator_udid, device_name: $device_name},
    stable_contract_sha256: $stable_sha256
  }' > "$GENERATED_DIR/provenance.json"

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"
[[ "$OUTPUT_ROOT" != "/" ]] || fail "Refusing to use the filesystem root as the golden output root"
DESTINATION_DIR="$OUTPUT_ROOT/$MATRIX_ID"
[[ "$(dirname "$DESTINATION_DIR")" == "$OUTPUT_ROOT" ]] \
  || fail "Golden destination escaped the output root: $DESTINATION_DIR"
if [[ "$MODE" == "check" ]]; then
  [[ ! -L "$DESTINATION_DIR" && -d "$DESTINATION_DIR" ]] \
    || fail "Golden matrix does not exist or is a symlink: $DESTINATION_DIR"
  jq -e \
    --arg payload "$AXE_SHA256" \
    --arg stable "$STABLE_SHA256" \
    '.schema_version == 1 and .axe_payload_sha256 == $payload and .stable_contract_sha256 == $stable' \
    "$DESTINATION_DIR/provenance.json" >/dev/null \
    || fail "Checked-in provenance does not match the exact payload and stable contract"
  diff -u "$DESTINATION_DIR/contract.json" "$GENERATED_DIR/contract.json"
  diff -ru "$DESTINATION_DIR/stable" "$GENERATED_DIR/stable"
  printf 'Goldens match: %s\n' "$DESTINATION_DIR"
  exit 0
fi

BACKUP_DIR=""
BACKUP_IDENTITY=""
if [[ -d "$DESTINATION_DIR" ]]; then
  [[ ! -L "$DESTINATION_DIR" ]] || fail "Refusing to replace symlinked golden matrix: $DESTINATION_DIR"
  BACKUP_DIR="$(mktemp -d "$OUTPUT_ROOT/.axe-golden-backup.$MATRIX_ID.XXXXXX")"
  rmdir "$BACKUP_DIR"
  mv "$DESTINATION_DIR" "$BACKUP_DIR"
  BACKUP_IDENTITY="$(stat -f '%d:%i' "$BACKUP_DIR")"
fi
if ! mv "$GENERATED_DIR" "$DESTINATION_DIR"; then
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    mv "$BACKUP_DIR" "$DESTINATION_DIR"
  fi
  fail "Failed to install generated goldens"
fi
if [[ -n "$BACKUP_DIR" ]]; then
  [[ ! -L "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] \
    || fail "Golden backup changed type before cleanup: $BACKUP_DIR"
  [[ "$(stat -f '%d:%i' "$BACKUP_DIR")" == "$BACKUP_IDENTITY" ]] \
    || fail "Golden backup identity changed before cleanup: $BACKUP_DIR"
  [[ "$(dirname "$BACKUP_DIR")" == "$OUTPUT_ROOT" ]] \
    || fail "Golden backup escaped the output root: $BACKUP_DIR"
  [[ "$(basename "$BACKUP_DIR")" == .axe-golden-backup."$MATRIX_ID".* ]] \
    || fail "Golden backup name is not owned by this run: $BACKUP_DIR"
  rm -r "$BACKUP_DIR"
fi
printf 'Updated goldens: %s\n' "$DESTINATION_DIR"
