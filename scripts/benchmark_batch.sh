#!/usr/bin/env bash
set -euo pipefail

UDID="${UDID:-}"
AXE_PATH="${AXE_PATH:-.build/arm64-apple-macosx/debug/axe}"
ITERATIONS="${ITERATIONS:-30}"
ROUNDS="${ROUNDS:-7}"
APP_BUNDLE="${APP_BUNDLE:-com.cameroncooke.AxePlayground}"
SCREEN="${SCREEN:-tap-test}"

usage() {
  cat <<EOF
Usage: $0 --udid <simulator-udid> [--iterations N] [--rounds N] [--axe-path PATH]

Benchmarks equivalent non-batched vs batched workflows on AxePlayground.

Defaults:
  iterations: ${ITERATIONS}
  rounds: ${ROUNDS}
  axe-path: ${AXE_PATH}
  screen: ${SCREEN}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)
      UDID="$2"
      shift 2
      ;;
    --iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    --rounds)
      ROUNDS="$2"
      shift 2
      ;;
    --axe-path)
      AXE_PATH="$2"
      shift 2
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
done

if [[ -z "$UDID" ]]; then
  echo "Missing required --udid" >&2
  usage
  exit 1
fi

if [[ ! -x "$AXE_PATH" ]]; then
  echo "Axe binary not found or not executable at: $AXE_PATH" >&2
  exit 1
fi

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || ! [[ "$ROUNDS" =~ ^[0-9]+$ ]]; then
  echo "--iterations and --rounds must be positive integers" >&2
  exit 1
fi

if (( ITERATIONS <= 0 || ROUNDS <= 0 )); then
  echo "--iterations and --rounds must be greater than zero" >&2
  exit 1
fi

launch_playground() {
  xcrun simctl terminate "$UDID" "$APP_BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$APP_BUNDLE" --launch-arg "screen=$SCREEN" >/dev/null
  sleep 2
}

run_non_batch_once() {
  for _ in $(seq 1 "$ITERATIONS"); do
    "$AXE_PATH" tap -x 180 -y 360 --udid "$UDID" >/dev/null 2>&1
    "$AXE_PATH" tap -x 220 -y 420 --udid "$UDID" >/dev/null 2>&1
  done
}

run_batch_once() {
  for _ in $(seq 1 "$ITERATIONS"); do
    "$AXE_PATH" batch --udid "$UDID" --step "tap -x 180 -y 360" --step "tap -x 220 -y 420" >/dev/null 2>&1
  done
}

measure_run_seconds() {
  local fn="$1"
  local start end
  start=$(python3 -c 'import time; print(time.perf_counter())')
  "$fn"
  end=$(python3 -c 'import time; print(time.perf_counter())')
  python3 - <<PY
start=$start
end=$end
print(f"{end-start:.6f}")
PY
}

# Warm-up to reduce first-run effects.
launch_playground
run_non_batch_once
launch_playground
run_batch_once

non_batch_results=()
batch_results=()

for _ in $(seq 1 "$ROUNDS"); do
  launch_playground
  non_batch_results+=("$(measure_run_seconds run_non_batch_once)")
done

for _ in $(seq 1 "$ROUNDS"); do
  launch_playground
  batch_results+=("$(measure_run_seconds run_batch_once)")
done

python3 - "$ITERATIONS" "${non_batch_results[*]}" "${batch_results[*]}" <<'PY'
import statistics
import sys

iterations = int(sys.argv[1])
nb_values = [float(v) for v in sys.argv[2].split()]
b_values = [float(v) for v in sys.argv[3].split()]

nb_mean = statistics.mean(nb_values)
nb_median = statistics.median(nb_values)
b_mean = statistics.mean(b_values)
b_median = statistics.median(b_values)

print("Benchmark: two-tap workflow (non-batch vs batch)")
print(f"Rounds: {len(nb_values)}, Iterations per round: {iterations}")
print(f"non_batch_mean_s={nb_mean:.4f}")
print(f"non_batch_median_s={nb_median:.4f}")
print(f"batch_mean_s={b_mean:.4f}")
print(f"batch_median_s={b_median:.4f}")
print(f"mean_speedup={(nb_mean / b_mean):.2f}x")
print(f"median_speedup={(nb_median / b_median):.2f}x")
print(f"non_batch_per_iter_ms={(nb_mean/iterations)*1000:.2f}")
print(f"batch_per_iter_ms={(b_mean/iterations)*1000:.2f}")
print(f"raw_non_batch_s={','.join(f'{v:.4f}' for v in nb_values)}")
print(f"raw_batch_s={','.join(f'{v:.4f}' for v in b_values)}")
PY
