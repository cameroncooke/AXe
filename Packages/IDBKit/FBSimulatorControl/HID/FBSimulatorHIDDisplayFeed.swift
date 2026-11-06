@_implementationOnly @preconcurrency import CoreSimDeviceIO
@preconcurrency import CoreSimulator
import Foundation

/// Immutable Objective-C handles cross the enumeration callback boundary. Their mutable screen
/// state is read through Apple's API; feed state itself is serialized by FBSimulatorHIDFeedState.
private final class FBSimulatorHIDScreenHandles: @unchecked Sendable {
  private let screens: [any SimScreen]
  init(screens: [any SimScreen]) { self.screens = screens }
  func values() -> [any SimScreen] { screens }
}

final class FBSimulatorHIDDisplayFeed: @unchecked Sendable {
  private let screens: [any SimScreen]
  private let registration = UUID()
  private let lock = NSLock()
  private var closed = false

  private init(screens: [any SimScreen], state: FBSimulatorHIDFeedState) throws {
    self.screens = screens
    let queue = DispatchQueue(label: "com.facebook.FBSimulatorControl.hid-display-feed")
    for screen in screens {
      guard screen.responds(to: #selector(SimScreen.registerScreenCallbacks(with:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:))),
            screen.responds(to: #selector(SimScreen.unregisterScreenCallbacks(with:))) else {
        throw FBSimulatorError.describe("Runtime screen callbacks are unavailable").build()
      }
    }
    for screen in screens {
      screen.registerScreenCallbacks(with: registration, callbackQueue: queue, frameCallback: {},
        surfacesChangedCallback: { _, _ in }, propertiesChangedCallback: { properties in
          do { state.observeDisplayCallback(try FBSimulatorDisplayDiscovery.snapshot(properties: properties)) }
          catch { state.fail("Display callback: \(error)") }
        })
    }
  }

  static func start(for simulator: FBSimulator, state: FBSimulatorHIDFeedState) async throws -> FBSimulatorHIDDisplayFeed {
    guard let io = simulator.device.io, let ports = io.ioPorts() else {
      throw FBSimulatorError.describe("Simulator IO ports are unavailable").build()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    var all: [any SimScreen] = []
    for port in ports {
      guard let adapter = port.descriptor as? any SimScreenAdapter else { continue }
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { throw FBSimulatorError.describe("Display callback setup timed out").build() }
      let result = FBSimulatorBoundedResult<FBSimulatorHIDScreenHandles>()
      let handles = try await result.value(timeout: remaining, operation: "Display callback setup") { finish in
        adapter.enumerateScreens(withCompletionQueue: DispatchQueue.global(qos: .userInitiated)) { screens, error in
          if let error { finish(.failure(error)); return }
          guard let screens else {
            finish(.failure(FBSimulatorError.describe("Screen enumeration returned no result").build())); return
          }
          finish(.success(FBSimulatorHIDScreenHandles(screens: screens)))
        }
      }
      all.append(contentsOf: handles.values())
    }
    guard !all.isEmpty else { throw FBSimulatorError.describe("No screens to observe").build() }
    try Task.checkCancellation()
    // Registration precedes the first authoritative properties and guest-state snapshots.
    return try FBSimulatorHIDDisplayFeed(screens: all, state: state)
  }

  func close() {
    lock.lock()
    guard !closed else { lock.unlock(); return }
    closed = true
    lock.unlock()
    for screen in screens { screen.unregisterScreenCallbacks(with: registration) }
  }
  deinit { close() }
}
