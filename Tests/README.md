# AXe Tests

Clean, simple test structure following KISS principles.

## Structure

Each AXe command has its own dedicated test file:

- `ListSimulatorsTests.swift` - Tests for `list-simulators` command
- `DescribeUITests.swift` - Tests for `describe-ui` command  
- `TapTests.swift` - Tests for `tap` command
- `SwipeTests.swift` - Tests for `swipe` command
- `TypeTests.swift` - Tests for `type` command
- `KeyTests.swift` - Tests for `key` and `key-sequence` commands
- `TouchTests.swift` - Tests for `touch` command
- `ButtonTests.swift` - Tests for `button` command
- `GestureTests.swift` - Tests for `gesture` command

## Running Tests

Use Swift's built-in testing system:

```bash
# Run all tests
swift test

# Run specific test files
swift test --filter TapTests
swift test --filter SwipeTests
swift test --filter TypeTests
swift test --filter KeyTests
swift test --filter TouchTests
swift test --filter ButtonTests
swift test --filter GestureTests
swift test --filter ListSimulatorsTests
swift test --filter DescribeUITests

# Run with verbose output
swift test --verbose
```

## Test Requirements

- All tests require a booted iOS simulator
- Get your simulator UDID with: `axe list-simulators` or `xcrun simctl list devices`
- Some tests use the AxePlaygroundApp for validation
- Each test file is self-contained and executable

## Test Philosophy

- **KISS**: Keep It Simple, Stupid
- **One responsibility**: Each file tests exactly one command
- **No code generation**: All tests are explicit and readable
- **Self-contained**: Each test file includes its own utilities
- **Executable**: Each test file can be run independently

## Individual Test Files

Each test file can be run directly:

```bash
swift test --filter TapTests
swift test --filter SwipeTests
```

## Test Coverage

All tests validate:
- ✅ Command execution (exit codes)
- ✅ Basic functionality
- ✅ Edge cases and error conditions
- ✅ Integration with AxePlaygroundApp where applicable
- ✅ Input validation and error handling