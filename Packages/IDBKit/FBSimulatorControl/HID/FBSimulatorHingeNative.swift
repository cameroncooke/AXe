@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
import Foundation
import Darwin
import IOKit
@preconcurrency import XPC

public struct FBSimulatorHingeReadback: Codable, Sendable {
  public let simulatorUDID: String
  public let bootIdentity: String
  public let capability: FBSimulatorContextCapability
  public let sample: FBSimulatorHingeSample
}

actor NativeHingeBackend: FBSimulatorHingeBackend {
  private static let service = "com.apple.coredevice.feature.remote.hid.vendordefined"
  private let simulator: FBSimulator
  private var connection: xpc_connection_t?
  private let connectionFailure = HingeConnectionFailure()
  init(simulator: FBSimulator) { self.simulator = simulator }

  func validate(expectedBoot: String) throws {
    guard simulator.state == .booted else { throw FBSimulatorHingeFailure(reason: .bootChanged, detail: "Simulator is not booted", delivery: .notDispatched) }
    let capability = try FBSimulatorNativeContextReader.capability(for: simulator)
    guard capability.hinge == .supported else {
      throw FBSimulatorHingeFailure(reason: .unsupported, detail: capability.reason, delivery: .notDispatched)
    }
    guard try Self.bootIdentity(simulator.udid) == expectedBoot else {
      throw FBSimulatorHingeFailure(reason: .bootChanged, detail: "Simulator boot identity changed", delivery: .notDispatched)
    }
    if let failure = connectionFailure.read() {
      throw FBSimulatorHingeFailure(reason: .unavailable, detail: failure, delivery: .notDispatched)
    }
  }

  func sample() async throws -> FBSimulatorHingeSample {
    let value = try await FBSimulatorHingeReader.read(for: simulator)
    return FBSimulatorHingeSample(mechanicalDegrees: value.mechanicalDegrees, sensedDegrees: value.sensedDegrees,
      velocityDegreesPerSecond: value.velocityDegreesPerSecond, minimumDegrees: value.minimumDegrees,
      maximumDegrees: value.maximumDegrees, timestampUptime: value.timestampUptime, receivedUptime: value.receivedUptime)
  }

  func dispatch(degrees: Double) throws {
    try Task.checkCancellation()
    guard connection == nil else { throw FBSimulatorHingeFailure(reason: .busy, detail: "Vendor connection already used", delivery: .notDispatched) }
    try dispatchMessage(Self.message(degrees))
  }

  func dispatchOrientation(_ target: String) throws {
    try Task.checkCancellation()
    guard connection == nil else { throw unavailable("Vendor connection already used") }
    try dispatchMessage(Self.vendorMessage(source: "orientation-picker-control", type: "enum", value: target as NSString))
  }

  private func dispatchMessage(_ message: xpc_object_t) throws {
    let connection = try connect()
    self.connection = connection
    let failure = connectionFailure
    xpc_connection_set_event_handler(connection) { event in
      if xpc_get_type(event) == XPC_TYPE_ERROR { failure.record("Vendor XPC connection reported an error") }
      else { failure.record("Unexpected vendor service event; no reply schema is verified") }
    }
    xpc_connection_resume(connection)
    try Task.checkCancellation()
    xpc_connection_send_message(connection, message)
    // No guest barrier is sent. Keep this connection alive while the independent reader runs.
  }

  func close() {
    if let connection { xpc_connection_cancel(connection) }
    connection = nil
  }

  private func connect() throws -> xpc_connection_t {
    typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
    typealias Connect = @convention(c) (xpc_object_t) -> xpc_connection_t?
    typealias Enable = @convention(c) (xpc_connection_t) -> Void
    guard let handle = dlopen(nil, RTLD_NOW) else { throw unavailable("XPC symbols unavailable") }
    defer { dlclose(handle) }
    guard let ep = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
          let make = dlsym(handle, "xpc_connection_create_from_endpoint"),
          let enable = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else { throw unavailable("Simulator XPC endpoint functions unavailable") }
    var error: NSError?
    let port = simulator.device.lookup(Self.service, error: &error)
    guard port != 0, let endpoint = unsafeBitCast(ep, to: Endpoint.self)(port, 0, 0),
          let result = unsafeBitCast(make, to: Connect.self)(endpoint) else {
      throw unavailable(error?.localizedDescription ?? "Hinge vendor service unavailable")
    }
    unsafeBitCast(enable, to: Enable.self)(result)
    return result
  }

  private static func message(_ degrees: Double) throws -> xpc_object_t {
    try vendorMessage(source: "hinge-slider-control", type: "range", value: NSNumber(value: degrees))
  }

  private static func vendorMessage(source: String, type: String, value: NSObject) throws -> xpc_object_t {
    let payload: [String: NSObject] = ["provider": "com.apple.Virtualization.VirtualMachines" as NSString,
      "source": source as NSString, "type": type as NSString, "value": value]
    guard let serialized = IOCFSerialize(payload as CFDictionary, 1) else {
      throw FBSimulatorHingeFailure(reason: .unavailable, detail: "Cannot serialize vendor event", delivery: .notDispatched)
    }
    let data = serialized as Data
    let event = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(event, "usagePage", 0xFF61)
    xpc_dictionary_set_uint64(event, "usage", 0x5B)
    xpc_dictionary_set_uint64(event, "version", 0)
    data.withUnsafeBytes { xpc_dictionary_set_data(event, "data", $0.baseAddress, $0.count) }
    let envelope = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(envelope, "messageType", "IndigoVendorDefinedEvent")
    xpc_dictionary_set_bool(envelope, "isBarrier", false)
    xpc_dictionary_set_string(envelope, "featureIdentifier", service)
    xpc_dictionary_set_value(envelope, "payload", event)
    return envelope
  }

  static func bootIdentity(_ udid: String) throws -> String {
    let processes = FBProcessFetcher().processes(withProcessName: "launchd_sim").filter {
      $0.arguments.contains { $0.localizedCaseInsensitiveContains(udid) }
    }
    guard processes.count == 1, let process = processes.first else {
      throw FBSimulatorHingeFailure(reason: .bootChanged, detail: "Expected one launchd_sim for the device", delivery: .notDispatched)
    }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      throw FBSimulatorHingeFailure(reason: .bootChanged, detail: "Boot process identity unavailable", delivery: .notDispatched)
    }
    return "\(process.processIdentifier):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
  }
  private func unavailable(_ detail: String) -> FBSimulatorHingeFailure {
    FBSimulatorHingeFailure(reason: .unavailable, detail: detail, delivery: .notDispatched)
  }
}

private final class HingeConnectionFailure: @unchecked Sendable {
  private let lock = NSLock()
  private var failure: String?
  func record(_ value: String) { lock.lock(); defer { lock.unlock() }; if failure == nil { failure = value } }
  func read() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
}

public enum FBSimulatorHingeNative {
  public static func operation(for simulator: FBSimulator) -> FBSimulatorHingeOperation {
    FBSimulatorHingeOperation(backend: NativeHingeBackend(simulator: simulator))
  }
  public static func read(for simulator: FBSimulator, expectedBootIdentity: String? = nil) async throws -> FBSimulatorHingeReadback {
    try Task.checkCancellation()
    let backend = NativeHingeBackend(simulator: simulator)
    let boot = try NativeHingeBackend.bootIdentity(simulator.udid)
    if let expectedBootIdentity, expectedBootIdentity != boot {
      throw FBSimulatorHingeFailure(reason: .bootChanged, detail: "Simulator boot identity differs from the request", delivery: .notDispatched)
    }
    try await backend.validate(expectedBoot: boot)
    let sample = try await backend.sample()
    try await backend.validate(expectedBoot: boot)
    try FBSimulatorHingeOperation.validateSample(sample)
    try Task.checkCancellation()
    return FBSimulatorHingeReadback(simulatorUDID: simulator.udid, bootIdentity: boot,
      capability: try FBSimulatorNativeContextReader.capability(for: simulator), sample: sample)
  }
}

public enum FBSimulatorRotationDirection: String, Codable, Sendable {
  case left, right
}

public struct FBSimulatorRotationReceipt: Codable, Sendable {
  public let direction: FBSimulatorRotationDirection
  public let vendorTarget: String
  public let before: FBSimulatorContextObservation
  public let after: FBSimulatorContextObservation
  public let matchingObservationCount: Int
  public let vendorEventCount: Int
}

public struct FBSimulatorRotationFailure: Error, Codable, Sendable {
  public let detail: String
  public let delivery: FBSimulatorHingeDelivery
  public let before: FBSimulatorContextObservation?
  public init(detail: String, delivery: FBSimulatorHingeDelivery, before: FBSimulatorContextObservation?) {
    self.detail = String(detail.prefix(1024)); self.delivery = delivery; self.before = before
  }
}

/// Device-wide rotation. The caller must hold the same device input lease used for touches.
/// The selected panel is an admission/readback target, not an independently rotated display.
public enum FBSimulatorRotationNative {
  @MainActor
  public static func rotate(for simulator: FBSimulator, screenID: UInt32, screenUUID: UUID,
                            expectedBootIdentity: String, direction: FBSimulatorRotationDirection,
                            timeoutSeconds: Double = 8) async throws -> FBSimulatorRotationReceipt {
    let backend = NativeHingeBackend(simulator: simulator)
    var before: FBSimulatorContextObservation?
    var dispatched = false
    do {
      guard timeoutSeconds.isFinite, (0.5...15).contains(timeoutSeconds) else {
        throw FBSimulatorContextError.unavailable("Rotation timeout must be in 0.5...15 seconds")
      }
      try Task.checkCancellation()
      try await backend.validate(expectedBoot: expectedBootIdentity)
      let reader = FBSimulatorNativeContextReader(simulator: simulator,
        screenID: screenID, screenUniqueID: screenUUID)
      let initial = try await reader.read()
      before = initial.observation
      guard initial.observation.bootIdentity == expectedBootIdentity else {
        throw FBSimulatorContextError.unavailable("Rotation boot identity changed before dispatch")
      }
      let plan = try target(direction: direction, readback: initial)
      // Compact replies have a fixed count of observations. Reserve capacity before the write.
      guard try JSONEncoder().encode(initial.observation).count <= 4096 else {
        throw FBSimulatorContextError.unavailable("Rotation observation exceeds reply capacity")
      }
      try await backend.validate(expectedBoot: expectedBootIdentity)
      try await backend.dispatchOrientation(plan.vendor)
      dispatched = true
      let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
      var previous: FBSimulatorHIDSessionObservation?
      var matches = 0
      while ProcessInfo.processInfo.systemUptime < deadline {
        try Task.checkCancellation()
        try await backend.validate(expectedBoot: expectedBootIdentity)
        do {
          let current = try await reader.read().observation
          guard current.bootIdentity == expectedBootIdentity,
                current.screenID == initial.observation.screenID,
                current.screenUniqueID == initial.observation.screenUniqueID,
                current.poseRevision == initial.observation.poseRevision else {
            throw FBSimulatorContextError.unavailable("Boot, selected screen or hinge changed during rotation")
          }
          let observed = try current.sessionObservation()
          if current.rotation == plan.rotation {
            matches = previous == observed ? matches + 1 : 1
            previous = observed
          } else { matches = 0; previous = nil }
          if matches == 2 { break }
        } catch FBSimulatorContextError.changedDuringRead {
          matches = 0; previous = nil
        } catch let error as ActivePanelReadError where error.childFailure == nil &&
            error.validationFailure == .selectedRotationMismatch && error.receipt?.exitConfirmed == true {
          // The two readers can straddle the orientation change. Observe again; never resend.
          matches = 0; previous = nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      guard matches == 2 else {
        throw FBSimulatorContextError.unavailable("Requested selected rotation was not observed twice. The frontmost app may not support that orientation; the iPhone home screen is portrait only")
      }
      await backend.close()
      try await Task.sleep(nanoseconds: 250_000_000)
      let after = try await reader.read().observation
      guard try after.sessionObservation() == previous else {
        throw FBSimulatorContextError.unavailable("Rotation did not persist after vendor connection close")
      }
      return FBSimulatorRotationReceipt(direction: direction, vendorTarget: plan.vendor,
        before: initial.observation, after: after, matchingObservationCount: matches, vendorEventCount: 1)
    } catch {
      await backend.close()
      throw FBSimulatorRotationFailure(detail: String(describing: error),
        delivery: dispatched ? .uncertain : .notDispatched, before: before)
    }
  }

  private static func target(direction: FBSimulatorRotationDirection,
                             readback: FBSimulatorContextReadback) throws -> (rotation: Int, vendor: String) {
    let capability = readback.capability
    // The vendor mapping is a property of the Duo's two-panel layout, measured on profiles 405
    // and 407. Panel IDs, not the profile version, select it.
    guard capability.deviceTypeIdentifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
          capability.hinge == .supported, capability.integratedDigitizerIDs == [1, 3] else {
      throw FBSimulatorContextError.unavailable("Rotation mapping is not verified for this device profile")
    }
    let outer = readback.observation.screenID == 1
    let positions = outer ? [0, 90, 270] : [0, 90, 180, 270]
    guard let index = positions.firstIndex(of: readback.observation.rotation) else {
      throw FBSimulatorContextError.unavailable("Current panel rotation is not supported")
    }
    let step = direction == .right ? 1 : positions.count - 1
    let rotation = positions[(index + step) % positions.count]
    // Vendor values describe physical device orientation. Inner UI has a 90-degree offset.
    let physical = (rotation + (outer ? 0 : 270)) % 360
    let vendor: String
    switch physical {
    case 0: vendor = "portrait"
    case 90: vendor = "landscape-right"
    case 180: vendor = "pud"
    default: vendor = "landscape-left"
    }
    return (rotation, vendor)
  }
}
