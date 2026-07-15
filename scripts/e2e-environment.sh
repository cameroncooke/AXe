#!/bin/bash

e2e_xcode_version() {
    DEVELOPER_DIR="$1" xcodebuild -version | awk 'NR == 1 { print $2 }'
}

e2e_xcode_build() {
    DEVELOPER_DIR="$1" xcodebuild -version | awk '/Build version/ { print $3 }'
}

# Build and run tests with the same selected Xcode; exact build IDs are provenance only.
configure_e2e_environment() {
    SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
    [[ -d "$SELECTED_DEVELOPER_DIR" ]] || return 1
    SELECTED_DEVELOPER_DIR="$(cd "$SELECTED_DEVELOPER_DIR" && pwd)"
    SELECTED_XCODE_VERSION="$(e2e_xcode_version "$SELECTED_DEVELOPER_DIR")"
    SELECTED_XCODE_MAJOR="${SELECTED_XCODE_VERSION%%.*}"
    [[ "$SELECTED_XCODE_MAJOR" -ge 26 ]] || return 1

    SELECTED_SWIFT="$(DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" xcrun --find swift)"
    export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
}

run_selected_swift() {
    DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" "$SELECTED_SWIFT" "$@"
}

select_e2e_simulator() {
    [[ -z "$SIMULATOR_UDID" ]] || return 0

    local xcode_minor="${SELECTED_XCODE_VERSION#*.}"
    xcode_minor="${xcode_minor%%.*}"
    local runtime_pattern="iOS-${SELECTED_XCODE_MAJOR}-${xcode_minor}"
    local simulator_json
    simulator_json="$(xcrun simctl list devices available -j)"
    SIMULATOR_UDID="$(jq -r \
        --arg name "$SIMULATOR_NAME" \
        --arg runtime "$runtime_pattern" \
        '[.devices | to_entries[]
          | select(.key | contains($runtime))
          | .value[]
          | select(.name == $name and .isAvailable == true)]
         | sort_by(if .state == "Booted" then 0 else 1 end)
         | .[0].udid // empty' <<< "$simulator_json")"
    if [[ -z "$SIMULATOR_UDID" ]]; then
        printf 'No available simulator named "%s" matched runtime %s. Available matching-runtime devices:\n' \
            "$SIMULATOR_NAME" "$runtime_pattern" >&2
        jq -r \
            --arg runtime "$runtime_pattern" \
            '.devices | to_entries[]
             | select(.key | contains($runtime))
             | .value[]
             | select(.isAvailable == true)
             | "  \(.name) (\(.udid), \(.state))"' <<< "$simulator_json" >&2
        return 1
    fi
    return 0
}

ensure_e2e_runtime_host() {
    [[ "$SELECTED_XCODE_MAJOR" -ge 27 ]] || return 0

    local device_hub_app="${SELECTED_DEVELOPER_DIR%/Contents/Developer}/Contents/Applications/DeviceHub.app"
    [[ -d "$device_hub_app" ]] || return 1
    if pgrep -x Simulator >/dev/null; then
        printf 'Simulator.app is running; quit it before testing Xcode 27 through Device Hub.\n' >&2
        return 1
    fi
    open -g "$device_hub_app"

    local attempts_remaining=5
    while [[ "$attempts_remaining" -gt 0 ]]; do
        pgrep -f "$device_hub_app/Contents/MacOS/DeviceHub" >/dev/null && return 0
        sleep 1
        attempts_remaining=$((attempts_remaining - 1))
    done
    return 1
}
