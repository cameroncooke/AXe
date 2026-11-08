#!/bin/bash
# Run the whole Playground end-to-end suite with one command: every group on a dedicated
# iPhone, iPad and iPhone Duo simulator.
#
# Usage: scripts/run-e2e.sh            (or: make e2e)
#
# The script finds the dedicated simulators by name and creates any that are missing, on the
# newest installed runtime that both supports the device type and the selected Xcode's iOS SDK
# supports. It never erases or replaces an existing simulator. It turns hardware keyboard input
# off on each one (the documented software keyboard prerequisite) with FlowDeck when FlowDeck is
# installed, builds the AXe runtime payload, copies it out of build_products/ (which later builds
# delete), and runs scripts/test-playground-matrix.py.
#
# Without an iPhone Duo device type and runtime, the iPhone and iPad groups still run, and the
# script exits 2 so the result cannot pass for a full run. Install the iPhone Duo simulator in
# Xcode's Components settings for full coverage.
#
# Environment:
#   DEVELOPER_DIR            Xcode to build and test with (default: xcode-select -p)
#   AXE_E2E_IPHONE_UDID      Use this iPhone simulator instead of "AXe E2E iPhone iOS <version>"
#   AXE_E2E_IPAD_UDID        Use this iPad simulator instead of "AXe E2E iPad iOS <version>"
#   AXE_E2E_DUO_UDID         Use this iPhone Duo simulator instead of "AXe E2E Duo iOS <version>"
#   AXE_E2E_RESULTS          Results folder (default: e2e-results/ in the repository)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export PATH="/opt/homebrew/bin:$PATH"
RUN="${AXE_E2E_RESULTS:-$ROOT/e2e-results}/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN"
echo "Results: $RUN"

SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"

# Prints the UDID of the dedicated simulator of this device type on the newest installed runtime
# that the selected Xcode's iOS SDK supports, creating it when missing. Simulator runtimes ship
# with an Xcode, so a newer runtime belongs to a newer Xcode. The name includes the runtime
# version. Prints nothing when no such runtime supports the device type.
simulator() {
    local name="$1" device_type="$2"
    xcrun simctl list -j devices available >"$RUN/devices.json"
    xcrun simctl list -j runtimes available >"$RUN/runtimes.json"
    local found
    found="$(python3 - "$RUN" "$name" "$device_type" "$SDK_VERSION" <<'PY'
import json, sys
run, name, device_type, sdk = sys.argv[1:]
version = lambda text: [int(part) for part in text.split('.')]
runtimes = [r for r in json.load(open(run + '/runtimes.json'))['runtimes']
            if r.get('isAvailable') and r.get('platform') == 'iOS' and version(r['version']) <= version(sdk)
            and any(t.get('identifier') == device_type for t in r.get('supportedDeviceTypes', []))]
runtimes.sort(key=lambda r: (version(r['version']), r['buildversion']))
if runtimes:
    runtime = runtimes[-1]
    full_name = name + ' iOS ' + runtime['version']
    devices = json.load(open(run + '/devices.json'))['devices'].get(runtime['identifier'], [])
    matches = [d['udid'] for d in devices if d['name'] == full_name
               and d.get('deviceTypeIdentifier') == device_type and d.get('isAvailable')]
    print('existing', matches[0]) if matches else print('create', runtime['identifier'], full_name)
PY
)"
    case "$found" in
        existing\ *) echo "${found#existing }" ;;
        create\ *)
            local rest="${found#create }" runtime full_name
            runtime="${rest%% *}"
            full_name="${rest#* }"
            echo "Creating simulator \"$full_name\" ($device_type, $runtime)" >&2
            xcrun simctl create "$full_name" "$device_type" "$runtime" ;;
        *) ;;
    esac
}

IPHONE="${AXE_E2E_IPHONE_UDID:-$(simulator "AXe E2E iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro)}"
IPAD="${AXE_E2E_IPAD_UDID:-$(simulator "AXe E2E iPad" com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4)}"
DUO="${AXE_E2E_DUO_UDID:-$(simulator "AXe E2E Duo" com.apple.CoreSimulator.SimDeviceType.iPhone-Duo)}"
if [[ -z "$IPHONE" || -z "$IPAD" ]]; then
    echo "No installed iOS $SDK_VERSION-or-older runtime supports the iPhone 18 Pro or iPad Air 11-inch (M4) simulator." >&2
    exit 1
fi
echo "iPhone $IPHONE  iPad $IPAD  Duo ${DUO:-unavailable}"

if command -v flowdeck >/dev/null; then
    # FlowDeck changes the keyboard setting only on a booted simulator.
    for udid in "$IPHONE" "$IPAD" $DUO; do
        xcrun simctl boot "$udid" 2>/dev/null || true
        xcrun simctl bootstatus "$udid" -b >/dev/null
        flowdeck simulator keyboard hardware off --simulator "$udid" --json >"$RUN/keyboard-$udid.json"
    done
else
    echo "FlowDeck is not installed: turn hardware keyboard input off on each test simulator in Device Hub." >&2
fi

echo "Building the AXe runtime payload"
/bin/bash scripts/build.sh frameworks-if-needed >"$RUN/build.log" 2>&1
AXE_BUILD_ARCHS="$(uname -m)" /bin/bash scripts/build.sh executable >>"$RUN/build.log" 2>&1
mkdir "$RUN/payload"
for item in axe Frameworks AXe_AXe.bundle; do
    ditto "build_products/$item" "$RUN/payload/$item"
done

matrix() {
    python3 scripts/test-playground-matrix.py --axe "$RUN/payload/axe" --developer-dir "$DEVELOPER_DIR" \
        --iphone "$IPHONE" --ipad "$IPAD" "$@"
}

if [[ -n "$DUO" ]]; then
    matrix --duo "$DUO" --suite all --output "$RUN/matrix"
    echo "Full suite passed on iPhone, iPad and iPhone Duo: $RUN/matrix"
else
    # --only checks just the named device, so the Duo argument is a placeholder.
    placeholder="00000000-0000-0000-0000-000000000000"
    matrix --duo "$placeholder" --only iphone --output "$RUN/matrix-iphone"
    matrix --duo "$placeholder" --only ipad --output "$RUN/matrix-ipad"
    echo "iPhone and iPad passed, but no iPhone Duo simulator is installed, so Duo was not tested." >&2
    exit 2
fi
