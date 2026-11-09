#!/bin/bash
# Run the physical-device end-to-end checks on every connected iPhone and iPad.
#
# Usage: scripts/run-e2e-devices.sh      (or: make e2e-devices)
#
# Opt-in and separate from make e2e: it needs paired, unlocked devices with Developer Mode on.
# It exits 1 before building anything when no physical iPhone or iPad is paired. It then builds the
# AXe runtime payload, builds the AXe Playground for iOS devices with automatic signing, installs it
# on each device, compiles scripts/fixtures/MediaPatternCheck.swift and runs
# scripts/test-physical-devices.py. Each check reads its result back from the device. Keep the
# devices unlocked and awake; the rotation check turns each device's interface through four
# orientations and back. Run this from one Mac at a time per device.
#
# Environment:
#   DEVELOPER_DIR                       Xcode to build with (default: xcode-select -p). The Playground
#                                       needs the iOS 27.1 SDK or later.
#   AXE_E2E_DEVICES                     Space-separated hardware UDIDs to test (default: every paired device)
#   AXE_E2E_SKIP_ROTATION=1             Leave device orientation unchanged
#   AXE_E2E_ALLOW_PROVISIONING_UPDATES=1  Let Xcode register devices and update profiles while signing
#   AXE_E2E_RESULTS                     Results folder (default: e2e-results/ in the repository)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
RUN="${AXE_E2E_RESULTS:-$ROOT/e2e-results}/devices-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN"

# Fail early, before any build, when no physical iPhone or iPad is paired.
xcrun devicectl list devices -q -j "$RUN/devicectl.json" >/dev/null 2>&1 || true
DEVICES="$(python3 - "$RUN/devicectl.json" "${AXE_E2E_DEVICES:-}" <<'PY'
import json, sys
path, wanted = sys.argv[1], sys.argv[2].split()
try:
    devices = json.load(open(path))['result']['devices']
except (OSError, KeyError, ValueError):
    devices = []
found = []
for device in devices:
    properties = device.get('properties') or {}
    hardware = properties.get('hardware') or device.get('hardwareProperties') or {}
    connection = properties.get('connection') or device.get('connectionProperties') or {}
    physical = (hardware.get('fidelity') or hardware.get('reality')) == 'physical'
    family = hardware.get('productFamily') or hardware.get('deviceType')
    if physical and family in ('iPhone', 'iPad') and connection.get('pairingState') == 'paired' \
            and connection.get('transportType') != 'sameMachine' and hardware.get('udid'):
        found.append(hardware['udid'])
missing = [udid for udid in wanted if udid not in found]
if missing:
    sys.exit('Not paired or not connected: ' + ' '.join(missing))
print(' '.join(wanted or found))
PY
)"
if [[ -z "$DEVICES" ]]; then
    echo "No paired physical iPhone or iPad is connected. Connect one by USB or the local network," >&2
    echo "unlock it, enable Developer Mode and pair it in Xcode, then run make e2e-devices again." >&2
    exit 1
fi
echo "Results: $RUN"
echo "Devices: $DEVICES"

echo "Building the AXe runtime payload"
/bin/bash scripts/build.sh frameworks-if-needed >"$RUN/build.log" 2>&1
AXE_BUILD_ARCHS="$(uname -m)" /bin/bash scripts/build.sh executable >>"$RUN/build.log" 2>&1
mkdir "$RUN/payload"
for item in axe Frameworks AXe_AXe.bundle; do
    ditto "build_products/$item" "$RUN/payload/$item"
done

echo "Building the AXe Playground for iOS devices"
provisioning=()
[[ "${AXE_E2E_ALLOW_PROVISIONING_UPDATES:-}" == 1 ]] && provisioning=(-allowProvisioningUpdates)
if ! xcodebuild -project AxePlaygroundApp/AxePlayground.xcodeproj -scheme AxePlayground -configuration Debug \
        -destination 'generic/platform=iOS' -derivedDataPath "$RUN/playground" ${provisioning[@]+"${provisioning[@]}"} \
        build >"$RUN/playground-build.log" 2>&1; then
    grep -E "error:|requires a provisioning profile|not included" "$RUN/playground-build.log" | head -20 >&2
    echo "The Playground build failed. See $RUN/playground-build.log. Device builds need a signing team" >&2
    echo "whose profile includes each device; AXE_E2E_ALLOW_PROVISIONING_UPDATES=1 lets Xcode add them." >&2
    exit 1
fi
APP="$RUN/playground/Build/Products/Debug-iphoneos/AxePlayground.app"

for udid in $DEVICES; do
    echo "Installing the Playground on $udid"
    xcrun devicectl device install app --device "$udid" "$APP" >"$RUN/install-$udid.log" 2>&1 || {
        tail -5 "$RUN/install-$udid.log" >&2
        echo "Could not install the Playground on $udid." >&2
        exit 1
    }
done

echo "Compiling the marker checker"
xcrun swiftc -O -parse-as-library -o "$RUN/MediaPatternCheck" scripts/fixtures/MediaPatternCheck.swift \
        >"$RUN/checker-build.log" 2>&1 || {
    grep -E "error:" "$RUN/checker-build.log" | head -10 >&2
    echo "Could not compile the marker checker. See $RUN/checker-build.log." >&2
    exit 1
}

arguments=(--axe "$RUN/payload/axe" --checker "$RUN/MediaPatternCheck" --output "$RUN/checks")
for udid in $DEVICES; do arguments+=(--device "$udid"); done
[[ "${AXE_E2E_SKIP_ROTATION:-}" == 1 ]] && arguments+=(--skip-rotation)
python3 scripts/test-physical-devices.py "${arguments[@]}"
