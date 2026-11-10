/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

extension FBSimulator {

  // MARK: - Shared accessors

  func applicationCommands() throws -> FBSimulatorApplicationCommands {
    commandCache.resolve { FBSimulatorApplicationCommands.commands(with: self) }
  }

  func screenshotCommands() throws -> FBSimulatorScreenshotCommands {
    commandCache.resolve { FBSimulatorScreenshotCommands.commands(with: self) }
  }

  func fileCommands() throws -> FBSimulatorFileCommands {
    commandCache.resolve { FBSimulatorFileCommands.commands(with: self) }
  }

  func processSpawnCommands() throws -> FBSimulatorProcessSpawnCommands {
    commandCache.resolve { FBSimulatorProcessSpawnCommands.commands(with: self) }
  }

  func videoRecordingCommands() throws -> FBSimulatorVideoRecordingCommands {
    commandCache.resolve { FBSimulatorVideoRecordingCommands.commands(with: self) }
  }

  func launchCtlCommands() throws -> FBSimulatorLaunchCtlCommands {
    commandCache.resolve { FBSimulatorLaunchCtlCommands.commands(with: self) }
  }

  // MARK: - Sim-only accessors

  func lifecycleCommands() throws -> FBSimulatorLifecycleCommands {
    commandCache.resolve { FBSimulatorLifecycleCommands.commands(with: self) }
  }

  func accessibilityCommands() throws -> FBSimulatorAccessibilityCommands {
    commandCache.resolve { FBSimulatorAccessibilityCommands.commands(with: self) }
  }
}
