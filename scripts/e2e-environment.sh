#!/bin/bash

EXPECTED_BUILD_XCODE_VERSION="26.5"
EXPECTED_BUILD_XCODE_BUILD="17F42"

e2e_xcode_version() {
    DEVELOPER_DIR="$1" xcodebuild -version | awk 'NR == 1 { print $2 }'
}

e2e_xcode_build() {
    DEVELOPER_DIR="$1" xcodebuild -version | awk '/Build version/ { print $3 }'
}

find_build_developer_dir() {
    if [[ -n "${AXE_BUILD_DEVELOPER_DIR:-}" ]]; then
        if [[ "$(e2e_xcode_version "$AXE_BUILD_DEVELOPER_DIR")" != "$EXPECTED_BUILD_XCODE_VERSION" ||
              "$(e2e_xcode_build "$AXE_BUILD_DEVELOPER_DIR")" != "$EXPECTED_BUILD_XCODE_BUILD" ]]; then
            return 1
        fi
        printf '%s\n' "$AXE_BUILD_DEVELOPER_DIR"
        return
    fi

    if [[ "$RUNTIME_XCODE_VERSION" == "$EXPECTED_BUILD_XCODE_VERSION" &&
          "$RUNTIME_XCODE_BUILD" == "$EXPECTED_BUILD_XCODE_BUILD" ]]; then
        printf '%s\n' "$RUNTIME_DEVELOPER_DIR"
        return
    fi

    local candidate
    for candidate in /Applications/Xcode-26.5*.app/Contents/Developer; do
        [[ -d "$candidate" ]] || continue
        if [[ "$(e2e_xcode_version "$candidate")" == "$EXPECTED_BUILD_XCODE_VERSION" &&
              "$(e2e_xcode_build "$candidate")" == "$EXPECTED_BUILD_XCODE_BUILD" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    return 1
}

configure_e2e_environment() {
    RUNTIME_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
    [[ -d "$RUNTIME_DEVELOPER_DIR" ]] || return 1
    RUNTIME_DEVELOPER_DIR="$(cd "$RUNTIME_DEVELOPER_DIR" && pwd)"
    RUNTIME_XCODE_VERSION="$(e2e_xcode_version "$RUNTIME_DEVELOPER_DIR")"
    RUNTIME_XCODE_BUILD="$(e2e_xcode_build "$RUNTIME_DEVELOPER_DIR")"
    RUNTIME_XCODE_MAJOR="${RUNTIME_XCODE_VERSION%%.*}"

    BUILD_DEVELOPER_DIR="$(find_build_developer_dir)" || return 1
    [[ -d "$BUILD_DEVELOPER_DIR" ]] || return 1
    BUILD_DEVELOPER_DIR="$(cd "$BUILD_DEVELOPER_DIR" && pwd)"
    BUILD_SWIFT="$(DEVELOPER_DIR="$BUILD_DEVELOPER_DIR" xcrun --find swift)"
    BUILD_SDKROOT="$(DEVELOPER_DIR="$BUILD_DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path)"
    export DEVELOPER_DIR="$RUNTIME_DEVELOPER_DIR"
}

build_swift() {
    DEVELOPER_DIR="$BUILD_DEVELOPER_DIR" "$BUILD_SWIFT" "$@"
}

run_runtime_swift_test() {
    SDKROOT="$BUILD_SDKROOT" \
    DEVELOPER_DIR="$RUNTIME_DEVELOPER_DIR" \
        "$BUILD_SWIFT" test --skip-build --no-parallel "$@"
}

select_e2e_simulator() {
    [[ -z "$SIMULATOR_UDID" ]] || return

    local runtime_pattern="iOS-${RUNTIME_XCODE_MAJOR}-"
    if [[ "$RUNTIME_XCODE_VERSION" == "26.5" ]]; then
        runtime_pattern="iOS-26-5"
    fi
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
}

ensure_e2e_runtime_host() {
    [[ "$RUNTIME_XCODE_MAJOR" -ge 27 ]] || return

    local device_hub_app="${RUNTIME_DEVELOPER_DIR%/Contents/Developer}/Contents/Applications/DeviceHub.app"
    [[ -d "$device_hub_app" ]] || return 1
    if pgrep -x Simulator >/dev/null; then
        printf 'Simulator.app is running; quit it before testing Xcode 27 through Device Hub.\n' >&2
        return 1
    fi
    open -g "$device_hub_app"

    local attempts_remaining=5
    while [[ "$attempts_remaining" -gt 0 ]]; do
        pgrep -f "$device_hub_app/Contents/MacOS/DeviceHub" >/dev/null && return
        sleep 1
        attempts_remaining=$((attempts_remaining - 1))
    done
    return 1
}
