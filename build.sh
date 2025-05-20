#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -e
set -o pipefail

if hash xcpretty 2>/dev/null; then
  HAS_XCPRETTY=true
fi

IDB_DIRECTORY=idb_checkout
BUILD_DIRECTORY=idb_build
OUTPUT_DIRECTORY=Frameworks

function ensure_idb_repo() {
  if [ ! -d $IDB_DIRECTORY ]; then
    echo "Creating $IDB_DIRECTORY directory and cloning idb repository..."
    git clone --depth 1 https://github.com/facebook/idb.git $IDB_DIRECTORY
    echo "idb repository cloned successfully."
  else
    echo "$IDB_DIRECTORY directory already exists."
  fi
}

function cleanup_output_directory() {
  echo "Cleaning up output directory: $OUTPUT_DIRECTORY"
  rm -rf "$OUTPUT_DIRECTORY"
  mkdir -p "$OUTPUT_DIRECTORY"
  echo "Output directory cleaned and recreated."
}

function invoke_xcodebuild() {
  local arguments=$@
  
  # Check if this is a create-xcframework command
  if [[ "$arguments" == *"-create-xcframework"* ]]; then
    # For create-xcframework, don't add build flags
    xcodebuild $arguments
  else
    # For all other commands (like build), add the build flags
    if [[ -n $HAS_XCPRETTY ]]; then
      # Try with xcpretty first, but fall back to direct xcodebuild if it fails
      if ! NSUnbufferedIO=YES xcodebuild SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES SWIFT_EMIT_MODULE_INTERFACE=YES SWIFT_INSTALL_OBJC_HEADER=YES $arguments | xcpretty -c; then
        echo "xcpretty encountered an error, falling back to direct xcodebuild..."
        xcodebuild SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES SWIFT_EMIT_MODULE_INTERFACE=YES SWIFT_INSTALL_OBJC_HEADER=YES $arguments
      fi
    else
      xcodebuild SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES SWIFT_EMIT_MODULE_INTERFACE=YES SWIFT_INSTALL_OBJC_HEADER=YES $arguments
    fi
  fi
}

function framework_build() {
  local name=$1

  # Check if XCFramework already exists
  if [ -d "$OUTPUT_DIRECTORY/$name.xcframework" ]; then
    echo "XCFramework for $name already exists, skipping build."
    return 0
  fi

  echo "Building framework: $name"
  
  # Special handling for CompanionLib which might need additional dependencies
  if [ "$name" == "CompanionLib" ]; then
    echo "CompanionLib requires additional dependencies. Making sure they are built first..."
    # Make sure dependencies are built first
    framework_build FBControlCore || exit 1
    framework_build FBSimulatorControl || exit 1
  fi
  
  # Check if the workspace exists
  if [ ! -f "$IDB_DIRECTORY/idb_companion.xcworkspace/contents.xcworkspacedata" ]; then
    echo "Error: idb_companion.xcworkspace not found in $IDB_DIRECTORY directory."
    echo "Contents of $IDB_DIRECTORY directory:"
    ls -la $IDB_DIRECTORY/
    exit 1
  fi
  
  # Check if the scheme exists
  local scheme_exists=$(cd $IDB_DIRECTORY/ && xcodebuild -workspace idb_companion.xcworkspace -list | grep -c "$name")
  if [ "$scheme_exists" -eq 0 ]; then
    echo "Warning: Scheme '$name' might not exist in the workspace. Attempting to build anyway..."
  fi
  
  if (cd $IDB_DIRECTORY/ && invoke_xcodebuild \
    -workspace idb_companion.xcworkspace \
    -scheme $name \
    -sdk macosx \
    -derivedDataPath ../$BUILD_DIRECTORY \
    build); then
    echo "Successfully built framework: $name"
    create_xcframework $name $OUTPUT_DIRECTORY || exit 1
  else
    echo "Error: Failed to build framework: $name"
    exit 1
  fi
}

function create_xcframework() {
  local name=$1
  local output_directory=$2
  local artifact="$BUILD_DIRECTORY/Build/Products/Debug/$name.framework"

  echo "Creating XCFramework for: $name"
  
  # Check if the framework exists
  if [ ! -d "$artifact" ]; then
    echo "Error: Framework not found at path: $artifact"
    exit 1
  fi

  # Create the XCFramework
  if invoke_xcodebuild \
    -create-xcframework \
    -framework $artifact \
    -output $output_directory/$name.xcframework; then
    echo "Successfully created XCFramework: $output_directory/$name.xcframework"
  else
    echo "Error: Failed to create XCFramework for: $name"
    exit 1
  fi
}

function all_frameworks_build() {
  echo "Building all frameworks..."
  
  # Build frameworks in dependency order - exit on first failure
  framework_build FBControlCore
  framework_build FBDeviceControl
  framework_build FBSimulatorControl
  framework_build IDBCompanionUtilities
  framework_build XCTestBootstrap
  
  # CompanionLib is handled specially in framework_build to avoid recursion
  # Only call it directly here if it wasn't already built as a dependency
  if [ ! -d "$OUTPUT_DIRECTORY/CompanionLib.xcframework" ]; then
    framework_build CompanionLib
  fi
  
  echo "All frameworks build process completed."
  echo "Generated XCFrameworks:"
  ls -la "$OUTPUT_DIRECTORY"
}

ensure_idb_repo
cleanup_output_directory
all_frameworks_build