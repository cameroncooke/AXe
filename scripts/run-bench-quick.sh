#!/bin/bash
# Build the current tree as a payload and time it against a baseline payload with scripts/bench-quick.py.
#
# Usage: AXE_BENCH_UDID=<udid> AXE_BENCH_BASELINE=<path/to/payload/axe> make bench-quick
#
# Environment:
#   AXE_BENCH_UDID       simulator UDID or physical device hardware UDID (required)
#   AXE_BENCH_BASELINE   baseline payload binary (required). Simulators: the latest release payload.
#                        Devices: a pinned payload under e2e-results/bench-quick/baselines/.
#   AXE_BENCH_CANDIDATE  skip the build and time this payload binary instead
#   AXE_BENCH_ARGS       extra flags for bench-quick.py, for example "--pairs 7 --full"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
: "${AXE_BENCH_UDID:?Set AXE_BENCH_UDID to the simulator or device UDID}"
: "${AXE_BENCH_BASELINE:?Set AXE_BENCH_BASELINE to the baseline payload binary}"

CANDIDATE="${AXE_BENCH_CANDIDATE:-}"
if [[ -z "$CANDIDATE" ]]; then
    OUT="$ROOT/e2e-results/bench-quick/candidate"
    mkdir -p "$ROOT/e2e-results/bench-quick"
    echo "Building the candidate payload"
    /bin/bash scripts/build.sh frameworks-if-needed >"$ROOT/e2e-results/bench-quick/build.log" 2>&1
    AXE_BUILD_ARCHS="$(uname -m)" /bin/bash scripts/build.sh executable >>"$ROOT/e2e-results/bench-quick/build.log" 2>&1
    rm -rf "$OUT"
    mkdir -p "$OUT"
    for item in axe Frameworks AXe_AXe.bundle; do
        ditto "build_products/$item" "$OUT/$item"
    done
    CANDIDATE="$OUT/axe"
fi

# shellcheck disable=SC2086
exec python3 scripts/bench-quick.py --baseline "$AXE_BENCH_BASELINE" --candidate "$CANDIDATE" \
    --udid "$AXE_BENCH_UDID" ${AXE_BENCH_ARGS:-}
