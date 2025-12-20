# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AXe is a comprehensive CLI tool for interacting with iOS Simulators using Apple's Accessibility APIs and HID (Human Interface Device) functionality. It's built on top of Meta's idb frameworks and provides a clean, modern Swift interface for simulator automation.

## Development Commands

### Building the Project

```bash
# Build with Swift Package Manager (recommended for development)
swift build

# Run directly without building
swift run axe [command]

# Build release version
swift build -c release

# Build frameworks from IDB (only needed if updating IDB dependencies)
./scripts/build.sh frameworks
```

### Testing Commands

```bash
# Run the playground app to test functionality
open AxePlaygroundApp/AxePlayground.xcodeproj

# Test a specific command
swift run axe tap -x 100 -y 200 --udid [SIMULATOR_UDID]

# Get simulator UDID
xcrun simctl list devices
```

## Testing with AxePlaygroundApp

AxePlaygroundApp is an iOS test application that provides visual feedback for AXe command testing. It includes multiple test screens for different interaction types.

### Available Test Screens

- `tap-test`: Displays tap coordinates and count
- `swipe-test`: Shows swipe start/end coordinates and direction
- `text-input`: Text field for typing validation
- `key-press`: Individual key press validation
- `key-sequence`: Key sequence validation
- `gesture-presets`: Gesture detection and validation
- `touch-control`: Touch down/up/move event tracking

### Launching to Specific Test Screens

```bash
# Terminate any existing instance
xcrun simctl terminate [SIMULATOR_UDID] com.cameroncooke.AxePlayground

# Launch directly to a specific test screen
xcrun simctl launch [SIMULATOR_UDID] com.cameroncooke.AxePlayground --launch-arg "screen=tap-test"

# Example workflow for tap testing
xcrun simctl launch B34FF305-5EA8-412B-943F-1D0371CA17FF com.cameroncooke.AxePlayground --launch-arg "screen=tap-test"
sleep 2  # Wait for app to load
swift run axe tap -x 200 -y 400 --udid B34FF305-5EA8-412B-943F-1D0371CA17FF

# Capture result for validation
swift run axe describe-ui --udid B34FF305-5EA8-412B-943F-1D0371CA17FF > result.json
```

### Test Screen Views in AxePlaygroundApp

The playground app includes these view files:
- `TapTestView.swift`: Validates tap coordinates and counts
- `SwipeTestView.swift`: Tracks swipe gestures
- `TextInputView.swift`: Text input validation
- `KeyPressView.swift`: Individual key press testing
- `KeySequenceView.swift`: Key sequence testing
- `GesturePresetsView.swift`: Gesture preset validation
- `TouchControlView.swift`: Touch event sequences

## Architecture Overview

### Command Structure
The project uses Apple's ArgumentParser framework with async/await support. Each command:
1. Extends `AsyncParsableCommand`
2. Validates input in `validate()`
3. Executes logic in async `run()`
4. Uses common setup via `AsyncParsableCommand+Setup` extension

### Key Components

**HIDInteractor** (`Sources/AXe/Utilities/HIDInteractor.swift`):
- Central component for simulator interaction
- Uses `@MainActor` for thread safety
- Bridges Swift async/await with FBFuture APIs

**FutureBridge** (`Sources/AXe/Utilities/FutureBridge.swift`):
- Critical adapter between Objective-C FBFuture and Swift async/await
- Type-safe conversions for NSArray, NSDictionary, NSNumber, etc.
- Handles cancellation and error propagation

**AccessibilityFetcher** (`Sources/AXe/Utilities/AccessibilityFetcher.swift`):
- Retrieves UI hierarchy from simulators
- Returns structured JSON for automation

### Framework Dependencies
The project depends on Meta's idb frameworks, included as XCFrameworks:
- FBControlCore
- FBSimulatorControl
- FBDeviceControl
- XCTestBootstrap

These are in `build_products/XCFrameworks/` and are automatically handled by Swift Package Manager.

## Current Issues & Next Steps

### Race Condition Investigation (from INVESTIGATION.md)

The project has a known race condition when using FBSimulatorControl directly. Based on investigation, the issue stems from differences between how CompanionLib handled HID events vs our direct approach:

**Key Differences Found:**
1. **Serial Queue Synchronization**: CompanionLib used a dedicated serial queue for operations
2. **Private Framework Loading**: CompanionLib explicitly loaded private frameworks before HID operations
3. **Target Initialization**: CompanionLib used `warmUp: true` which may initialize important state

**Priority Fixes Needed:**
1. Add private framework loading before HID operations
2. Implement serial queue synchronization for HID operations
3. Investigate target warmup functionality
4. Ensure HID connection persistence

### Adding New Commands

1. Create new file in `Sources/AXe/Commands/`
2. Extend `AsyncParsableCommand`
3. Add validation logic in `validate()`
4. Implement async `run()` method
5. Register command in `main.swift`

Example structure:
```swift
struct MyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "my-command",
        abstract: "Description of command"
    )
    
    @Option var parameter: String
    
    func validate() throws {
        // Validation logic
    }
    
    func run() async throws {
        try await performGlobalSetup()
        let logger = try AxeLogger()
        // Command implementation
    }
}
```

### Important Patterns

**Error Handling**: Always validate inputs before execution. Use `CLIError` for command-specific errors.

**Async/Await**: All commands and utilities use Swift concurrency. Use `FutureBridge` when interfacing with FBFuture-based APIs.

**Logging**: Use `AxeLogger` for consistent output. Pass logger instance through method calls.

**Simulator Targeting**: Always verify simulator exists before interaction using `SimulatorUtilities`.

## Testing Strategy

The project includes comprehensive test plans in `Docs/`:
- `AXE_COMPREHENSIVE_TEST_PLAN.md`: Detailed test cases for all commands
- `USAGE_EXAMPLES.md`: Real-world usage patterns and examples

Key testing components:
- **AxePlaygroundApp**: iOS test app providing visual feedback for automation testing
- Test screens for each interaction type (tap, swipe, text, gestures, etc.)
- Exact validation of coordinates, text, and timing

## Building for Distribution

The `scripts/build.sh` script handles the complete build process including:
- Building IDB frameworks
- Creating XCFrameworks
- Building AXe executable
- Code signing with Developer ID
- Apple notarization

For releases, use: `./scripts/create-release.sh`

## Command Reference

### Available Commands
- `describe-ui`: Extract accessibility information
- `list-simulators`: List available simulators
- `tap`: Tap at coordinates with timing control
- `swipe`: Swipe gestures with customizable parameters
- `type`: Type text via direct input, stdin, or file
- `key`: Press individual keys by HID keycode
- `key-sequence`: Execute key sequences
- `touch`: Low-level touch down/up events
- `button`: Hardware button simulation
- `gesture`: Gesture presets (scroll, swipe patterns)

### Gesture Presets
- Scrolling: `scroll-up`, `scroll-down`, `scroll-left`, `scroll-right`
- Navigation: `swipe-from-left-edge`, `swipe-from-right-edge`, etc.

All commands support `--pre-delay` and `--post-delay` for timing control.