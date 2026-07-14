<img src="banner.png" alt="AXe" width="600"/>

AXe is a comprehensive CLI tool for interacting with iOS Simulators using Apple's HID (Human Interface Device) functionality.

[![CI](https://github.com/cameroncooke/AXe/actions/workflows/release.yml/badge.svg)](https://github.com/cameroncooke/AXe/actions/workflows/release.yml)
[![Licence: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Install

```bash
brew tap cameroncooke/axe
brew install axe
```

Or install in one command:

```bash
brew install cameroncooke/axe/axe
```

Verify the CLI:

```bash
axe --help
axe list-simulators
```

## Xcode compatibility

AXe supports Xcode 26.5 (build `17F42`) with iOS 26.5 (`23F77`) and Xcode 27 Beta 3 (build `27A5218g`) with iOS 27 (`24A5380g`). Xcode 27 simulator automation is validated through Device Hub; Simulator.app is not required.

Release artifacts remain built with the pinned Xcode 26.5 toolchain and run unchanged with either supported Xcode selected. The validated release-shaped payload has SHA-256 `583bc18685e9e8f57b8ddb00366c5659f2ed8998d918b6eef2172c4139eb30fd`.

## E2E development

`make e2e` builds AXe with the pinned Xcode 26.5 toolchain and runs the simulator tests against the Xcode selected by `DEVELOPER_DIR` or `xcode-select`. When Xcode 27 is selected, the runner starts Device Hub, chooses an available iOS 27 iPhone 17 Pro, and boots it with `simctl`.

Set `AXE_BUILD_DEVELOPER_DIR` to override the build toolchain location; it must point to Xcode 26.5 build `17F42`.

## Basic usage

```bash
# Find a booted simulator UDID
axe list-simulators
export UDID=<UDID>

# Inspect the current UI
axe describe-ui --udid "$UDID"

# Interact with the simulator
axe tap --label "Continue" --udid "$UDID"
axe type 'Hello world' --udid "$UDID"
axe screenshot --output ./screen.png --udid "$UDID"
```

## Documentation

Full documentation is available at [axe-cli.com/docs](https://axe-cli.com/docs).

## Disclaimer

AXe is an independent open-source iOS Simulator automation project and is not affiliated with, endorsed by, or associated with Deque Systems or its axe® accessibility products.

## Licence

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Third-party licensing notices, including Meta's IDB MIT attribution, are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
