@preconcurrency import CoreSimulator
import Darwin
import Foundation
@preconcurrency import XPC

public struct FBSimulatorHingeObservation: Sendable, Codable {
  public let channelID: String
  public let timestampUptime: Double
  public let receivedUptime: Double
  public let mechanicalDegrees: Double
  public let sensedDegrees: Double
  public let velocityDegreesPerSecond: Double
  public let minimumDegrees: Double
  public let maximumDegrees: Double
}

/// One channel observes changes for the feed lifetime. The service sends no stable
/// heartbeat; separate fixed one-shot reads provide periodic fresh-sample evidence.
final class FBSimulatorHIDMotionSubscription: @unchecked Sendable {
  private let connection: xpc_connection_t
  private let closed = FBSimulatorHIDFeedClosure()
  private let first = FBSimulatorBoundedResult<FBSimulatorHingeObservation>()

  init(simulator: FBSimulator, state: FBSimulatorHIDFeedState) throws {
    let channel = UUID()
    let request = try FBSimulatorHIDHingeWire.request(deviceID: simulator.udid, channel: channel)
    connection = try FBSimulatorHIDHingeWire.connect(simulator)
    let connection = self.connection
    let closed = self.closed
    let first = self.first
    let started = ProcessInfo.processInfo.systemUptime
    let queue = DispatchQueue(label: "com.facebook.FBSimulatorControl.hid-motion-feed")
    xpc_connection_set_target_queue(connection, queue)
    xpc_connection_set_event_handler(connection) { event in
      guard !closed.isClosed else { return }
      do {
        let samples = try FBSimulatorHIDHingeWire.samples(event, channel: channel, notBefore: started)
        for sample in samples {
          state.observeMotion(sample)
          first.finish(.success(sample))
        }
        if xpc_get_type(event) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(event) {
          xpc_dictionary_set_bool(reply, "CoreDevice.XPCMessageKey.cancellationRequested", closed.isClosed)
          xpc_connection_send_message(connection, reply)
        }
      } catch {
        if !closed.isClosed { state.fail("Motion subscription: \(error)"); first.finish(.failure(error)) }
      }
    }
    xpc_connection_resume(connection)
    xpc_connection_send_message_with_reply(connection, request, queue) { reply in
      guard !closed.isClosed else { return }
      if xpc_get_type(reply) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_value(reply, "CoreDevice.error") != nil {
        let error = FBSimulatorHIDHingeWire.failure("Motion service rejected or closed the request")
        state.fail("Motion subscription rejected"); first.finish(.failure(error))
      } else {
        // The original reply ends this stream. Fresh one-shot reads cannot replace its change watcher.
        state.motionSubscriptionCompleted()
        first.finish(.failure(FBSimulatorHIDHingeWire.failure("Motion subscription completed before close")))
      }
    }
  }

  func waitForFreshSample() async throws {
    _ = try await first.value(timeout: 3, operation: "Fresh motion subscription") { _ in }
  }

  func close() {
    guard closed.close() else { return }
    xpc_connection_cancel(connection)
    first.finish(.failure(CancellationError()))
  }
  deinit { close() }
}

/// The lock is only the bridge between XPC callbacks and explicit resource close.
private final class FBSimulatorHIDFeedClosure: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return value }
  func close() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !value else { return false }; value = true; return true
  }
}

enum FBSimulatorHIDHingeWire {
  static func failure(_ message: String) -> NSError { FBSimulatorError.describe(message).build() }

  static func connect(_ simulator: FBSimulator) throws -> xpc_connection_t {
    typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
    typealias Connect = @convention(c) (xpc_object_t) -> xpc_connection_t?
    typealias Enable = @convention(c) (xpc_connection_t) -> Void
    guard let handle = dlopen(nil, RTLD_NOW),
          let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
          let connectSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
          let enableSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
      throw failure("Simulator XPC functions unavailable")
    }
    var error: NSError?
    let port = simulator.device.lookup("com.apple.coredevice.feature.monitormotion", error: &error)
    guard port != 0,
          let endpoint = unsafeBitCast(endpointSymbol, to: Endpoint.self)(port, 0, 0),
          let connection = unsafeBitCast(connectSymbol, to: Connect.self)(endpoint) else {
      throw error ?? failure("Motion service unavailable")
    }
    unsafeBitCast(enableSymbol, to: Enable.self)(connection)
    return connection
  }

  static func request(deviceID: String, channel: UUID) throws -> xpc_object_t {
    return try request(deviceID: deviceID, channel: channel, changeThreshold: 0.1)
  }

  /// One-shot reads use zero change threshold; live subscriptions keep 0.1 degrees.
  static func request(deviceID: String, channel: UUID, changeThreshold: Double) throws -> xpc_object_t {
    guard let version = Bundle(path: "/Library/Developer/PrivateFrameworks/CoreDevice.framework")?
      .object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
      throw failure("CoreDevice version metadata unavailable")
    }
    var bytes = channel.uuid
    let sideChannel = withUnsafePointer(to: &bytes) { pointer in
      pointer.withMemoryRebound(to: UInt8.self, capacity: 16) { xpc_uuid_create($0) }
    }
    let unit = dictionary(["symbol": string("°"),
      "converter": dictionary(["coefficient": xpc_double_create(1), "constant": xpc_double_create(0)])])
    let interval = xpc_array_create(nil, 0)
    xpc_array_append_value(interval, xpc_int64_create(0))
    xpc_array_append_value(interval, xpc_uint64_create(100_000_000_000_000_000))
    let input = dictionary([
      "actualInput": dictionary([
        "changeThreshold": dictionary(["value": xpc_double_create(changeThreshold), "unit": unit]),
        "updateInterval": interval]),
      "streamProxy": dictionary(["sideChannel": sideChannel])])
    let components = xpc_array_create(nil, 0)
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { throw failure("CoreDevice version is empty") }
    for part in parts {
      guard let value = UInt64(part) else { throw failure("CoreDevice version is not numeric") }
      xpc_array_append_value(components, xpc_uint64_create(value))
    }
    return dictionary([
      "CoreDevice.actionIdentifier": string("com.apple.coredevice.action.streamhingeangle"),
      "CoreDevice.deviceIdentifier": string(deviceID),
      "CoreDevice.invocationIdentifier": string(UUID().uuidString),
      "CoreDevice.CoreDeviceDDIProtocolVersion": xpc_int64_create(1),
      "CoreDevice.coreDeviceVersion": dictionary(["components": components,
        "originalComponentsCount": xpc_int64_create(Int64(parts.count)), "stringValue": string(version)]),
      "CoreDevice.input": input])
  }

  static func samples(_ event: xpc_object_t, channel: UUID, notBefore: Double) throws -> [FBSimulatorHingeObservation] {
    guard xpc_get_type(event) == XPC_TYPE_DICTIONARY,
          let channelText = xpc_dictionary_get_string(event, "XPCSideChannel.uniqueIdentifier"),
          String(cString: channelText) == channel.uuidString else {
      throw failure("Motion event has a missing or unexpected channel")
    }
    let status = try child(event, "CoreDevice.XPCMessageKey.sideChannelStatus", XPC_TYPE_DICTIONARY)
    let pushing = try child(status, "pushing", XPC_TYPE_DICTIONARY)
    let elements = try child(pushing, "elements", XPC_TYPE_ARRAY)
    let count = xpc_array_get_count(elements)
    guard count <= 64 else { throw failure("Motion sample batch is too large") }
    var accepted: [FBSimulatorHingeObservation] = []
    for index in 0..<count {
      let item = xpc_array_get_value(elements, index)
      guard xpc_get_type(item) == XPC_TYPE_DICTIONARY else {
        throw failure("Motion sample is not a dictionary")
      }
      let valid = try child(item, "isAngleValid", XPC_TYPE_BOOL)
      let velocityValid = xpc_bool_get_value(try child(item, "isVelocityValid", XPC_TYPE_BOOL))
      guard xpc_bool_get_value(valid) else {
        throw failure("Motion sample reports invalid angle or velocity (\(invalidSampleDetail(item)))")
      }
      let timestamp = try number(item, "timestamp")
      let received = ProcessInfo.processInfo.systemUptime
      guard timestamp <= received else { throw failure("Motion sample timestamp is in the future") }
      guard timestamp >= notBefore else { continue }
      let minimum = try quantity(item, "minAngle", unit: "°")
      let maximum = try quantity(item, "maxAngle", unit: "°")
      let mechanical = try quantity(item, "mechanicalAngle", unit: "°")
      let sensed = try quantity(item, "angle", unit: "°")
      // The iOS 27.1 Duo runtime marks every velocity invalid, at rest or not, while its angles are
      // valid (reported against CoreDevice 651.32). AXe never relies on velocity alone: each check that
      // wants a hinge at rest (`FBSimulatorLitInactivePolicy`, `FBSimulatorHingeDisplayReadiness`) also
      // proves the angle stayed the same across reads. An unreported velocity is therefore read as 0.
      let velocity = velocityValid ? try quantity(item, "velocity", unit: "°/s") : 0
      guard minimum <= maximum, (minimum...maximum).contains(mechanical), (minimum...maximum).contains(sensed) else {
        throw failure("Hinge sample is outside its reported range")
      }
      let observation = FBSimulatorHingeObservation(channelID: channel.uuidString,
        timestampUptime: timestamp, receivedUptime: received, mechanicalDegrees: mechanical,
        sensedDegrees: sensed, velocityDegreesPerSecond: velocity,
        minimumDegrees: minimum, maximumDegrees: maximum)
      accepted.append(observation)
    }
    return accepted
  }

  /// What a refused sample carried, so a report from another runtime shows which flag and values it sent.
  static func invalidSampleDetail(_ item: xpc_object_t) -> String {
    var parts = ["isAngleValid", "isVelocityValid"].map { "\($0)=\(xpc_dictionary_get_bool(item, $0))" }
    for (key, unit) in [("angle", "°"), ("mechanicalAngle", "°"), ("velocity", "°/s"), ("minAngle", "°"), ("maxAngle", "°")] {
      parts.append("\(key)=\((try? quantity(item, key, unit: unit)).map { String($0) } ?? "unreadable")")
    }
    return parts.joined(separator: ", ")
  }

  static func quantity(_ object: xpc_object_t, _ key: String, unit expected: String) throws -> Double {
    let quantity = try child(object, key, XPC_TYPE_DICTIONARY)
    let unit = try child(quantity, "unit", XPC_TYPE_DICTIONARY)
    let converter = try child(unit, "converter", XPC_TYPE_DICTIONARY)
    guard let symbol = xpc_dictionary_get_string(unit, "symbol"), String(cString: symbol) == expected,
          try number(converter, "coefficient") == 1, try number(converter, "constant") == 0 else {
      throw failure("Hinge quantity has unsupported units")
    }
    return try number(quantity, "value")
  }

  static func number(_ object: xpc_object_t, _ key: String) throws -> Double {
    let value = xpc_double_get_value(try child(object, key, XPC_TYPE_DOUBLE))
    guard value.isFinite else { throw failure("Hinge number is not finite") }
    return value
  }

  static func child(_ object: xpc_object_t, _ key: String, _ type: xpc_type_t) throws -> xpc_object_t {
    guard let value = xpc_dictionary_get_value(object, key), xpc_get_type(value) == type else {
      throw failure("Missing or invalid motion field: \(key)")
    }
    return value
  }

  static func dictionary(_ fields: [String: xpc_object_t]) -> xpc_object_t {
    let result = xpc_dictionary_create(nil, nil, 0)
    for (key, value) in fields { xpc_dictionary_set_value(result, key, value) }
    return result
  }
  static func string(_ value: String) -> xpc_object_t { xpc_string_create(value) }
}
