/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * This source code is licensed under the MIT license found in the LICENSE file.
 */

@_implementationOnly @preconcurrency import CoreSimDeviceIO
@preconcurrency import CoreSimulator
import Foundation

/// One host screen-properties snapshot. This does not identify the active panel.
public struct FBSimulatorDisplayInfo: Sendable {
  public let screenID: UInt32
  public let uniqueID: String?
  public let name: String?
  public let deviceName: String?
  public let nativePixelSize: CGSize
  public let scale: Double
  public let propertiesSeed: UInt32
  public let rawScreenType: UInt64
  /// Host UI orientation. It is not a guest CADisplay rotation value.
  public let rawUIOrientation: UInt32
  public let rawPowerState: Int32
  public let rawBacklightState: Int32?
  public let backlightBrightnessFactor: Double?
}

/// A runtime before iOS 27 has one built-in display. The host names it "PurpleMain" where later
/// runtimes give every display a UUID, and the guest display report gives it no uniqueId at all
/// (measured on iOS 26.5 with Xcode 27 and CoreDevice 689.2). Both sides take this fixed UUID for
/// that one display, so the same identity checks apply to it as to any other panel.
public enum FBSimulatorLegacyDisplay {
  public static let hostName = "PurpleMain"
  public static let uuid = UUID(uuidString: "5E1F0B6A-26D5-4C0E-9A7B-3D2C1F0E9A26")!
  /// The guest report has no backlight state to give for this display; "unknown" is all it says.
  public static let backlightState = "notReported"
}

extension FBSimulatorDisplayInfo {
  /// The display's UUID, or the fixed one for the legacy built-in display.
  var panelUUID: UUID? {
    guard let uniqueID else { return nil }
    return UUID(uuidString: uniqueID) ?? (uniqueID == FBSimulatorLegacyDisplay.hostName ? FBSimulatorLegacyDisplay.uuid : nil)
  }
}

/// Reads fresh runtime data. It does not infer a panel from its ID, size or hinge angle.
public enum FBSimulatorDisplayDiscovery {
  public static func displays(for simulator: FBSimulator) async throws -> [FBSimulatorDisplayInfo] {
    try await displays(for: simulator, timeout: 3)
  }

  public static func displays(for simulator: FBSimulator, timeout: TimeInterval) async throws -> [FBSimulatorDisplayInfo] {
    guard timeout.isFinite, timeout > 0, timeout <= 30 else {
      throw FBSimulatorError.describe("Display discovery timeout must be in (0, 30] seconds").build()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    try Task.checkCancellation()
    guard let io = simulator.device.io, let ports = io.ioPorts() else {
      throw FBSimulatorError.describe("Simulator IO ports are unavailable").build()
    }
    var result: [FBSimulatorDisplayInfo] = []
    var foundAdapter = false
    for port in ports {
      guard let adapter = port.descriptor as? any SimScreenAdapter else { continue }
      guard adapter.responds(to: #selector(SimScreenAdapter.enumerateScreens(withCompletionQueue:completionHandler:))) else {
        throw FBSimulatorError.describe("Screen adapter does not support enumeration").build()
      }
      foundAdapter = true
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { throw FBSimulatorError.describe("Display discovery timed out").build() }
      let snapshots = try await snapshots(from: adapter, timeout: remaining)
      result.append(contentsOf: snapshots)
    }
    guard foundAdapter else {
      throw FBSimulatorError.describe("No runtime screen adapter is available").build()
    }
    var identifiers = Set<UInt32>()
    for display in result {
      guard identifiers.insert(display.screenID).inserted else {
        throw FBSimulatorError.describe("Screen ID \(display.screenID) is ambiguous across runtime adapters").build()
      }
    }
    return result.sorted { $0.screenID < $1.screenID }
  }

  public static func display(for simulator: FBSimulator, screenID: UInt32) async throws -> FBSimulatorDisplayInfo {
    let available = try await displays(for: simulator)
    guard let selected = available.first(where: { $0.screenID == screenID }) else {
      throw FBSimulatorError.describe("Screen ID \(screenID) was not found in the current runtime").build()
    }
    return selected
  }

  private static func snapshots(from adapter: any SimScreenAdapter, timeout: TimeInterval) async throws -> [FBSimulatorDisplayInfo] {
    let result = FBSimulatorBoundedResult<[FBSimulatorDisplayInfo]>()
    return try await result.value(timeout: timeout, operation: "Display enumeration") { finish in
      adapter.enumerateScreens(withCompletionQueue: DispatchQueue.global(qos: .userInitiated)) { screens, error in
        if let error { finish(.failure(error)); return }
        guard let screens else {
          finish(.failure(FBSimulatorError.describe("Screen enumeration returned no result").build()))
          return
        }
        do { finish(.success(try screens.map { try snapshot(of: $0) })) }
        catch { finish(.failure(error)) }
      }
    }
  }

  static func snapshot(of screen: any SimScreen) throws -> FBSimulatorDisplayInfo {
    guard screen.responds(to: #selector(getter: SimScreen.screenProperties)),
      let properties = screen.screenProperties
    else {
      throw FBSimulatorError.describe("Runtime screen properties or mode are unavailable").build()
    }
    return try snapshot(properties: properties)
  }

  static func snapshot(properties: any SimScreenProperties) throws -> FBSimulatorDisplayInfo {
    guard let mode = properties.currentMode else {
      throw FBSimulatorError.describe("Runtime screen mode is unavailable").build()
    }
    let pixelSize = properties.pixelSize
    let scale = mode.preferredUIScale
    guard pixelSize.width.isFinite, pixelSize.height.isFinite,
      pixelSize.width > 0, pixelSize.height > 0, scale.isFinite, scale > 0
    else {
      throw FBSimulatorError.describe("Runtime screen has invalid pixel dimensions or scale").build()
    }
    let backlight = properties.backlight
    return FBSimulatorDisplayInfo(
      screenID: properties.screenID,
      uniqueID: properties.uniqueId,
      name: properties.name,
      deviceName: properties.deviceName,
      nativePixelSize: pixelSize,
      scale: scale,
      propertiesSeed: properties.seed,
      rawScreenType: properties.screenType,
      rawUIOrientation: properties.uiOrientation,
      rawPowerState: properties.powerState,
      rawBacklightState: backlight?.state,
      backlightBrightnessFactor: backlight?.brightnessFactor)
  }
}

/// Owns the one continuation shared by callback, timeout, and caller cancellation.
/// A late Apple callback is ignored. Enumeration has no verified cancellation API.
final class FBSimulatorBoundedResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, Error>?
  private var continuation: CheckedContinuation<Value, Error>?

  func finish(_ result: Result<Value, Error>) {
    lock.lock()
    guard self.result == nil else { lock.unlock(); return }
    self.result = result
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(with: result)
  }

  private func install(_ pending: CheckedContinuation<Value, Error>) -> Bool {
    lock.lock()
    if let result { lock.unlock(); pending.resume(with: result); return false }
    continuation = pending
    lock.unlock()
    return true
  }

  func value(timeout: TimeInterval, operation: String,
             timeoutError: (@Sendable () -> Error)? = nil,
             start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
    try await withTaskCancellationHandler(operation: {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { pending in
        guard install(pending) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
          self.finish(.failure(timeoutError?() ?? FBSimulatorError.describe("\(operation) timed out").build()))
        }
        start { self.finish($0) }
      }
    }, onCancel: { self.finish(.failure(CancellationError())) })
  }
}
