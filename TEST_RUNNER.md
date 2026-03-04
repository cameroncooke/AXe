# AXe Test Runner

The `test-runner.sh` script provides a comprehensive, automated solution for building and testing the AXe iOS testing framework.

## Features

✅ **Automated Build Process**
- Builds the AXe CLI executable (`swift build`)
- Builds and installs the AxePlayground app on iPhone 16 simulator
- Handles simulator setup and management

✅ **Comprehensive Testing**
- Runs individual test suites or entire test plan
- Sequential execution to prevent state conflicts
- Proper environment variable setup (`SIMULATOR_UDID`, `AXE_E2E=1`)

✅ **Flexible Options**
- Build-only mode for CI/CD pipelines
- Test-only mode for rapid iteration
- Clean build support
- Verbose output for debugging

## Prerequisites

- **Xcode**: Latest version with iOS simulator support
- **Swift**: For building the AXe CLI tool
- **iPhone 16 Simulator**: Must be available in Xcode Simulator

## Quick Start

```bash
# Make script executable (first time only)
chmod +x test-runner.sh

# Run everything (build + test)
./test-runner.sh

# Show help
./test-runner.sh --help
```

## Usage Examples

### Complete Build and Test Cycle
```bash
# Build AXe executable, install playground app, run all tests
./test-runner.sh

# Same as above but with clean build
./test-runner.sh --clean
```

### Test-Specific Workflows
```bash
# Build everything and run only swipe tests
./test-runner.sh SwipeTests

# Run only tap tests (skip building)
./test-runner.sh --tests-only TapTests

# Run all tests with verbose output
./test-runner.sh --verbose
```

### Build-Only Workflows
```bash
# Just build everything (useful for CI)
./test-runner.sh --build-only

# Clean build without running tests
./test-runner.sh --clean --build-only
```

## Available Test Suites

| Test Suite | Description |
|------------|-------------|
| `SwipeTests` | Swipe gesture testing with coordinate accuracy and direction detection |
| `TapTests` | Tap coordinate accuracy and timing |
| `KeyTests` | Keyboard input simulation |
| `TouchTests` | Low-level touch event sequences |
| `TypeTests` | Text input simulation |
| `ButtonTests` | Hardware button press simulation |
| `GestureTests` | Predefined gesture patterns |
| `ListSimulatorsTests` | Simulator discovery and listing |

## Command Line Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-b, --build-only` | Only build (skip tests) |
| `-t, --tests-only` | Only run tests (skip building) |
| `-c, --clean` | Clean build before building |
| `-s, --sequential` | Run tests sequentially (default) |
| `-v, --verbose` | Verbose output |

## Configuration

The script is pre-configured for:
- **Simulator**: iPhone 16 (UDID: `B34FF305-5EA8-412B-943F-1D0371CA17FF`)
- **App**: AxePlayground (`com.cameroncooke.AxePlayground`)
- **Project**: `AxePlaygroundApp/AxePlayground.xcodeproj`

To change these settings, edit the configuration section at the top of `test-runner.sh`.

## Test Environment

The script automatically sets up the following environment:
- `SIMULATOR_UDID`: Set to the configured iPhone 16 simulator
- `AXE_E2E=1`: Enables simulator E2E tests
- Sequential test execution (prevents state conflicts)
- Clean app state between test suites

## Troubleshooting

### Common Issues

**"Simulator not found"**
```bash
# List available simulators
xcrun simctl list devices | grep iPhone

# Update SIMULATOR_UDID in script if needed
```

**"Build failed"**
```bash
# Try a clean build
./test-runner.sh --clean --build-only

# Check Xcode and Swift installation
xcode-select --print-path
swift --version
```

**"Tests failed"**
```bash
# Run specific test suite with verbose output
./test-runner.sh --verbose SwipeTests

# Check if app is properly installed
xcrun simctl list apps B34FF305-5EA8-412B-943F-1D0371CA17FF
```

### Performance Notes

- **Sequential Testing**: Tests run sequentially by default to prevent state conflicts
- **Build Time**: Initial builds take longer; subsequent builds are incremental
- **Test Duration**: Full test suite takes ~5-10 minutes depending on system performance

## Integration with CI/CD

### GitHub Actions Example
```yaml
- name: Run AXe Tests
  run: |
    chmod +x test-runner.sh
    ./test-runner.sh --verbose
```

### Build-Only for Docker
```bash
# In containerized environments
./test-runner.sh --build-only
```

## Advanced Usage

### Custom Test Execution
```bash
# Run multiple specific test suites
./test-runner.sh SwipeTests && ./test-runner.sh TapTests

# Test-driven development workflow
./test-runner.sh --tests-only SwipeTests --verbose
```

### Debugging Failed Tests
```bash
# Run with maximum verbosity
./test-runner.sh --verbose --tests-only FailingTestSuite

# Check simulator state
xcrun simctl list devices
```

## Success Indicators

The script provides clear visual feedback:
- 🎯 **Blue**: Section headers
- ✅ **Green**: Success messages
- ℹ️ **Blue**: Information
- ⚠️ **Yellow**: Warnings
- ❌ **Red**: Errors

## Exit Codes

- `0`: Success
- `1`: Build or test failure
- `1`: Missing prerequisites
- `1`: Invalid command line arguments 