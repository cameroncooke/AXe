#!/bin/bash

# AXe Test Runner Script
# Automates building AXe executable, playground app, and running tests

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SIMULATOR_NAME="iPhone 17 Pro"
SIMULATOR_UDID="B38FE93D-578B-454B-BE9A-C6FA0CE5F096"
PLAYGROUND_PROJECT="AxePlaygroundApp/AxePlayground.xcodeproj"
PLAYGROUND_SCHEME="AxePlayground"
BUNDLE_ID="com.cameroncooke.AxePlayground"

# Print colored messages
print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_header() {
    echo -e "\n${BLUE}================================================${NC}"
    echo -e "${BLUE}🎯 $1${NC}"
    echo -e "${BLUE}================================================${NC}\n"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] [TEST_FILTER]"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -b, --build-only    Only build AXe and playground app (skip tests)"
    echo "  -t, --tests-only    Only run tests (skip building)"
    echo "  -c, --clean         Clean build before building"
    echo "  -s, --sequential    Run suites one-by-one (single simulator-safe flow)"
    echo "  -v, --verbose       Verbose output"
    echo ""
    echo "Test Filters (optional):"
    echo "  SwipeTests          Run only swipe tests"
    echo "  TapTests            Run only tap tests"
    echo "  KeyTests            Run only key tests"
    echo "  TouchTests          Run only touch tests"
    echo "  TypeTests           Run only type tests"
    echo "  ButtonTests         Run only button tests"
    echo "  GestureTests        Run only gesture tests"
    echo "  ListSimulatorsTests Run only list simulators tests"
    echo ""
    echo "Examples:"
    echo "  $0                  # Build everything and run all tests"
    echo "  $0 SwipeTests       # Build everything and run only swipe tests"
    echo "  $0 -t SwipeTests    # Skip building, run only swipe tests"
    echo "  $0 -b               # Only build, skip tests"
    echo "  $0 -c               # Clean build and run all tests"
}

# Parse command line arguments
BUILD_ONLY=false
TESTS_ONLY=false
CLEAN_BUILD=false
SEQUENTIAL=true
VERBOSE=false
TEST_FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -b|--build-only)
            BUILD_ONLY=true
            shift
            ;;
        -t|--tests-only)
            TESTS_ONLY=true
            shift
            ;;
        -c|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        -s|--sequential)
            SEQUENTIAL=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        SwipeTests|TapTests|KeyTests|TouchTests|TypeTests|ButtonTests|GestureTests|ListSimulatorsTests)
            TEST_FILTER="$1"
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Function to check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"

    # Check if we're in the right directory
    if [[ ! -f "Package.swift" ]]; then
        print_error "Package.swift not found. Please run this script from the AXe project root."
        exit 1
    fi

    # Check if Xcode is available
    if ! command -v xcodebuild &> /dev/null; then
        print_error "xcodebuild not found. Please install Xcode."
        exit 1
    fi

    # Check if Swift is available
    if ! command -v swift &> /dev/null; then
        print_error "swift not found. Please install Swift."
        exit 1
    fi

    print_success "All prerequisites satisfied"
}

# Function to boot simulator
boot_simulator() {
    print_header "Setting Up Simulator"

    print_info "Checking simulator status..."
    SIMULATOR_STATUS=$(xcrun simctl list devices | grep "$SIMULATOR_UDID" | grep -o "Booted\|Shutdown" || echo "NotFound")

    if [[ "$SIMULATOR_STATUS" == "NotFound" ]]; then
        print_error "Simulator with UDID $SIMULATOR_UDID not found"
        print_info "Available simulators:"
        xcrun simctl list devices | grep "iPhone"
        exit 1
    fi

    if [[ "$SIMULATOR_STATUS" != "Booted" ]]; then
        print_info "Booting simulator $SIMULATOR_NAME..."
        xcrun simctl boot "$SIMULATOR_UDID"
        sleep 3
        print_success "Simulator booted"
    else
        print_success "Simulator already booted"
    fi
}

# Function to clean build
clean_build() {
    if [[ "$CLEAN_BUILD" == true ]]; then
        print_header "Cleaning Build"

        print_info "Cleaning Swift build..."
        swift package clean

        print_info "Cleaning Xcode build..."
        xcodebuild clean -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -destination "id=$SIMULATOR_UDID"

        print_success "Build cleaned"
    fi
}

# Function to build AXe executable
build_axe() {
    print_header "Building AXe Executable"

    print_info "Building AXe CLI tool..."
    if [[ "$VERBOSE" == true ]]; then
        swift build
    else
        swift build > /dev/null 2>&1
    fi

    # Verify the executable exists
    if [[ -f ".build/arm64-apple-macosx/debug/axe" ]]; then
        print_success "AXe executable built successfully"
        print_info "Location: .build/arm64-apple-macosx/debug/axe"
    else
        print_error "Failed to build AXe executable"
        exit 1
    fi
}

# Function to build and install playground app
build_playground_app() {
    print_header "Building and Installing Playground App"

    # Terminate existing app instance
    print_info "Terminating existing app instance..."
    xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" 2>/dev/null || true

    # Build the app (not build-for-testing since this is a regular app)
    print_info "Building AxePlayground app..."
    if [[ "$VERBOSE" == true ]]; then
        xcodebuild build \
            -project "$PLAYGROUND_PROJECT" \
            -scheme "$PLAYGROUND_SCHEME" \
            -destination "id=$SIMULATOR_UDID"
    else
        xcodebuild build \
            -project "$PLAYGROUND_PROJECT" \
            -scheme "$PLAYGROUND_SCHEME" \
            -destination "id=$SIMULATOR_UDID" \
            -quiet > /dev/null 2>&1
    fi

    # Find the built app path using TARGET_BUILD_DIR + FULL_PRODUCT_NAME (more semantically correct)
    print_info "Getting app bundle path..."
    BUILD_SETTINGS=$(xcodebuild -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -destination "id=$SIMULATOR_UDID" -showBuildSettings)
    TARGET_BUILD_DIR=$(echo "$BUILD_SETTINGS" | grep "TARGET_BUILD_DIR" | head -1 | sed 's/.*= //')
    FULL_PRODUCT_NAME=$(echo "$BUILD_SETTINGS" | grep "FULL_PRODUCT_NAME" | head -1 | sed 's/.*= //')
    APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

    if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
        print_error "Built app not found at: $APP_PATH"
        print_info "TARGET_BUILD_DIR: $TARGET_BUILD_DIR"
        print_info "FULL_PRODUCT_NAME: $FULL_PRODUCT_NAME"
        exit 1
    fi

    # Install the app
    print_info "Installing AxePlayground app on simulator..."
    if [[ "$VERBOSE" == true ]]; then
        xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
    else
        xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH" > /dev/null 2>&1
    fi

    print_success "Playground app built and installed successfully"
    print_info "App path: $APP_PATH"
}

# Function to run tests
run_tests() {
    print_header "Running Tests"

    # Set up environment
    export SIMULATOR_UDID="$SIMULATOR_UDID"
    export AXE_E2E=1

    print_info "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, AXE_E2E=$AXE_E2E"

    run_swift_test() {
        local filter="$1"
        local cmd="swift test --filter $filter"

        if [[ "$VERBOSE" == true ]]; then
            cmd="$cmd --verbose"
        fi

        print_info "Test command: $cmd"
        eval "$cmd"
    }

    if [[ -n "$TEST_FILTER" ]]; then
        print_info "Running test filter: $TEST_FILTER"
        echo ""
        if run_swift_test "$TEST_FILTER"; then
            print_success "Selected tests passed"
        else
            print_error "Selected tests failed"
            exit 1
        fi
        return
    fi

    if [[ "$SEQUENTIAL" == true ]]; then
        print_info "Running E2E suites one-by-one to avoid simulator contention"
        local suites=(
            "BatchTests"
            "ButtonTests"
            "DescribeUITests"
            "GestureTests"
            "InitTests"
            "KeyComboTests"
            "KeySequenceTests"
            "KeyTests"
            "ListSimulatorsTests"
            "RecordVideoTests"
            "StreamVideoDebugTests"
            "StreamVideoTests"
            "SwipeTests"
            "TapTests"
            "TouchTests"
            "TypeTests"
        )

        echo ""
        for suite in "${suites[@]}"; do
            print_header "Running $suite"
            if ! run_swift_test "$suite"; then
                print_error "$suite failed"
                exit 1
            fi
        done

        print_success "All test suites passed"
        return
    fi

    print_info "Running all tests"
    local test_cmd="swift test"
    if [[ "$VERBOSE" == true ]]; then
        test_cmd="$test_cmd --verbose"
    fi

    print_info "Test command: $test_cmd"
    echo ""
    if eval "$test_cmd"; then
        print_success "All tests passed"
    else
        print_error "Some tests failed"
        exit 1
    fi
}

# Function to show summary
show_summary() {
    print_header "Summary"

    if [[ "$BUILD_ONLY" == true ]]; then
        print_success "Build completed successfully"
        print_info "AXe executable: .build/arm64-apple-macosx/debug/axe"
        print_info "Playground app installed on: $SIMULATOR_NAME ($SIMULATOR_UDID)"
    elif [[ "$TESTS_ONLY" == true ]]; then
        if [[ -n "$TEST_FILTER" ]]; then
            print_success "Test suite '$TEST_FILTER' completed successfully"
        else
            print_success "All test suites completed successfully"
        fi
    else
        print_success "Build and test cycle completed successfully"
        print_info "AXe executable: .build/arm64-apple-macosx/debug/axe"
        print_info "Playground app: Installed and tested on $SIMULATOR_NAME"
        if [[ -n "$TEST_FILTER" ]]; then
            print_info "Test suite: $TEST_FILTER"
        else
            print_info "Test coverage: All test suites"
        fi
    fi
}

# Main execution
main() {
    print_header "AXe Test Runner"
    print_info "Starting automated build and test cycle..."

    # Always check prerequisites
    check_prerequisites

    # Always boot simulator (needed for both building and testing)
    boot_simulator

    if [[ "$TESTS_ONLY" != true ]]; then
        clean_build
        build_axe
        build_playground_app
    fi

    if [[ "$BUILD_ONLY" != true ]]; then
        run_tests
    fi

    show_summary
}

# Run main function
main "$@"