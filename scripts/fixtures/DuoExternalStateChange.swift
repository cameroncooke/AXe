import AppKit
import CoreSimulator
import Darwin
import Foundation
import IOKit
import XPC
import FBControlCore
import FBSimulatorControl

final class ChangeReporter: NSObject, FBEventReporter {
  var metadata: [String: String] = [:]
  func report(_ event: FBEventReporterSubject) {}
  func addMetadata(_ metadata: [String: String]) {}
}
enum ChangeError: Error { case invalid(String) }
struct ChangeReceipt: Encodable {
  let mode: String
  let startedUptime: Double
  let finishedUptime: Double
  let before: FBSimulatorContextReadback?
  let hinge: FBSimulatorHingeReceipt?
  let rotation: FBSimulatorRotationReceipt?
  let write: IndependentHingeWriteReceipt?
  let vendorProtocol: IndependentVendorProtocolReceipt?
  let connectionHold: IndependentConnectionHoldReceipt?
}

/// Isolated simulator-state operator. This sends no touch input and takes no AXe input lock.
/// The deliberate overlap represents a user folding/turning the device during an AXe gesture.
@main struct DuoExternalStateChange {
  @MainActor static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      guard ((args.count == 7 && ["fold", "fold-write", "rotate"].contains(args[0]))
        || ((args.count == 9 || (args.count == 10 && args[9] == "state-wait=30")) && args[0] == "fold-write-held")
        || (args.count == 11 && args[0] == "rotate-write-held" && args[9] == "state-wait=30"
          && ["rotation-from=0", "rotation-from=90", "rotation-from=180", "rotation-from=270"].contains(args[10]))),
            let screen = UInt32(args[2]), let uuid = UUID(uuidString: args[3]),
            UUID(uuidString: args[6]) != nil,
            let angle = Double(args[4]), angle.isFinite else {
        throw ChangeError.invalid("Expected fold/fold-write/rotate, boot, screen, UUID, fold angle, marker path, owned device UUID")
      }
      let rotationWrite = args[0] == "rotate-write-held"
      guard rotationWrite ? [0.0, 90, 180, 270].contains(angle) : (0...180).contains(angle) else {
        throw ChangeError.invalid("Requested state is outside the verified range")
      }
      let orientation: String?
      if rotationWrite {
        guard let from = Int(args[10].dropFirst("rotation-from=".count)) else {
          throw ChangeError.invalid("Expected the measured rotation before the one right-turn write")
        }
        orientation = try IndependentHingeWriter.rotationTarget(from: from, requested: angle, screenID: screen)
      } else { orientation = nil }
      let held = args[0] == "fold-write-held" || rotationWrite
      if held {
        guard args[7].hasPrefix("/"), args[8].hasPrefix("/") else {
          throw ChangeError.invalid("Held control paths must be absolute")
        }
      }
      let lifetime = held
        ? try IndependentConnectionLifetime(readyURL: URL(fileURLWithPath: args[7]),
            releaseURL: URL(fileURLWithPath: args[8]), stateWaitSeconds: args.count >= 10 ? 30 : nil) : nil
      let protocolOnly = args[0] == "fold-write" || held
      let logger = FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: true, withDebugLogging: false)
      FBControlCoreGlobalConfiguration.defaultLogger = logger
      try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
      let control = try FBSimulatorControl.withConfiguration(FBSimulatorControlConfiguration(
        deviceSetPath: nil, logger: logger, reporter: ChangeReporter()))
      guard let simulator = control.set.allSimulators.first(where: {
        UUID(uuidString: $0.udid) == UUID(uuidString: args[6])
      }), simulator.state == .booted else { throw ChangeError.invalid("Explicit Duo is not booted") }
      let reader = FBSimulatorNativeContextReader(simulator: simulator,
        screenID: screen, screenUniqueID: uuid)
      let before: FBSimulatorContextReadback?
      if protocolOnly {
        try IndependentHingeWriter.validate(simulator, expectedBoot: args[1])
        before = nil
      } else {
        let observed = try await reader.read()
        guard observed.observation.bootIdentity == args[1] else { throw ChangeError.invalid("Boot changed") }
        before = observed
      }
      let started = ProcessInfo.processInfo.systemUptime
      let marker = try JSONSerialization.data(withJSONObject: ["startedUptime": started, "mode": args[0]])
      try marker.write(to: URL(fileURLWithPath: args[5]), options: .withoutOverwriting)
      var hinge: FBSimulatorHingeReceipt?
      var rotation: FBSimulatorRotationReceipt?
      var write: IndependentHingeWriteReceipt?
      var vendorProtocol: IndependentVendorProtocolReceipt?
      var connectionHold: IndependentConnectionHoldReceipt?
      if protocolOnly {
        let result = try await IndependentHingeWriter.send(simulator, degrees: angle, orientation: orientation,
          expectedBoot: args[1], startedUptime: started, lifetime: lifetime)
        write = result.write
        vendorProtocol = result.vendorProtocol
        connectionHold = result.connectionHold
      } else if args[0] == "fold" {
        hinge = try await FBSimulatorHingeNative.operation(for: simulator).set(
          FBSimulatorHingeRequest(degrees: angle, expectedBootIdentity: args[1], toleranceDegrees: 0.5, timeoutSeconds: 8))
      } else {
        rotation = try await FBSimulatorRotationNative.rotate(for: simulator,
          screenID: screen, screenUUID: uuid, expectedBootIdentity: args[1], direction: .right)
      }
      let value = ChangeReceipt(mode: args[0], startedUptime: started,
        finishedUptime: ProcessInfo.processInfo.systemUptime, before: before, hinge: hinge, rotation: rotation,
        write: write, vendorProtocol: vendorProtocol, connectionHold: connectionHold)
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      FileHandle.standardOutput.write(try encoder.encode(value))
      FileHandle.standardOutput.write(Data([10]))
    } catch {
      FileHandle.standardError.write(Data((String(reflecting: error) + "\n").utf8))
      exit(2)
    }
  }
}

/// Snapshot of the state event's host-send drain. Guest barriers do not acknowledge event semantics.
/// The parent must still measure the actual state after input stops.
struct IndependentHingeWriteReceipt: Encodable {
  let outcome = "writeEnqueued"
  let stage = "hostSendDrain"
  let hostSendDrainedUptime: Double
  let requestedDegrees: Double
  let source: String
  let expectedBootIdentity: String
  let simulatorUDID: String
  let vendorEventCount = 1
  let hostSendDrained = true
  let guestWriteAcknowledged = false
  let mechanicalTargetObserved = false
}

/// A raw non-error XPC reply confirms only the standalone vendor-barrier exchange.
struct IndependentVendorBarrierReceipt: Encodable {
  let phase: String
  let connectionID: String
  let requestEnqueuedUptime: Double
  let replyReceivedUptime: Double
  let replyType: String
  let remainingBudgetSecondsAtRequest: Double
  let replyReceived = true
  let replyWasXPCError = false
}

struct IndependentVendorProtocolReceipt: Encodable {
  let activation = "xpc_connection_activate"
  let connectionIdentitySource = "fixture-owned-connection-token"
  let connectionID: String
  let startedUptime: Double
  let deadlineUptime: Double
  let preBarrier: IndependentVendorBarrierReceipt
  let eventEnqueuedUptime: Double
  let eventHostSendDrainedUptime: Double
  let postBarrier: IndependentVendorBarrierReceipt
  let finishedUptime: Double
  let vendorEventCount = 1
  let eventAcknowledged = false
  let mechanicalTargetObserved = false
}

/// An external user action takes no AXe input lease and starts no motion reader.
private enum IndependentHingeWriter {
  private static let service = "com.apple.coredevice.feature.remote.hid.vendordefined"

  static func validate(_ simulator: FBSimulator, expectedBoot: String) throws {
    guard simulator.state == .booted else { throw ChangeError.invalid("Explicit Duo is not booted") }
    let capability = try FBSimulatorNativeContextReader.capability(for: simulator)
    guard capability.hinge == .supported,
          capability.deviceTypeIdentifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
          capability.modelIdentifier == "iPhone19,4", capability.profileVersion == "405",
          capability.integratedDigitizerIDs == [1, 3] else {
      throw ChangeError.invalid("Independent hinge wire is not verified for this device profile")
    }
    let processes = FBProcessFetcher().processes(withProcessName: "launchd_sim").filter {
      $0.arguments.contains { $0.localizedCaseInsensitiveContains(simulator.udid) }
    }
    guard processes.count == 1, let process = processes.first else {
      throw ChangeError.invalid("Expected one launchd_sim for the explicit device")
    }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size,
          "\(process.processIdentifier):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" == expectedBoot else {
      throw ChangeError.invalid("Boot changed before the independent write")
    }
  }

  static func send(_ simulator: FBSimulator, degrees: Double, orientation: String?, expectedBoot: String,
                   startedUptime: Double, lifetime: IndependentConnectionLifetime?) async throws
    -> (write: IndependentHingeWriteReceipt, vendorProtocol: IndependentVendorProtocolReceipt,
        connectionHold: IndependentConnectionHoldReceipt?) {
    let deadline = startedUptime + 8
    try Task.checkCancellation()
    try requireTime(deadline)
    try validate(simulator, expectedBoot: expectedBoot)
    let message = try message(degrees, orientation: orientation)
    let connection = try connect(simulator)
    defer { xpc_connection_cancel(connection) }
    let connectionID = UUID().uuidString
    let queue = DispatchQueue(label: "com.cameroncooke.AXe.fixture-hinge-write")
    let completion = IndependentWriteCompletion()
    xpc_connection_set_target_queue(connection, queue)
    xpc_connection_set_event_handler(connection) { event in
      if xpc_get_type(event) == XPC_TYPE_ERROR {
        completion.finish("The independent vendor connection reported XPC_TYPE_ERROR")
      }
      // Unsolicited non-error events are not a verified handshake or angle acknowledgement.
    }
    xpc_connection_activate(connection)
    let preBarrier = try barrier(connection, queue: queue, phase: "beforeWrite",
      connectionID: connectionID, deadline: deadline, completion: completion)
    try Task.checkCancellation()
    try validate(simulator, expectedBoot: expectedBoot)
    try completion.check()
    try requireTime(deadline)
    let eventEnqueued = ProcessInfo.processInfo.systemUptime
    xpc_connection_send_message(connection, message)
    xpc_connection_send_barrier(connection) { completion.finish(nil) }
    let eventDrained = try completion.wait(deadline: deadline)
    let write = IndependentHingeWriteReceipt(hostSendDrainedUptime: eventDrained, requestedDegrees: degrees,
      source: orientation == nil ? "hinge-slider-control" : "orientation-picker-control",
      expectedBootIdentity: expectedBoot, simulatorUDID: simulator.udid)
    let postBarrier = try barrier(connection, queue: queue, phase: "afterWrite",
      connectionID: connectionID, deadline: deadline, completion: completion)
    try Task.checkCancellation()
    try completion.check()
    try validate(simulator, expectedBoot: expectedBoot)
    try requireTime(deadline)
    let protocolReceipt = IndependentVendorProtocolReceipt(connectionID: connectionID, startedUptime: startedUptime,
      deadlineUptime: deadline, preBarrier: preBarrier, eventEnqueuedUptime: eventEnqueued,
      eventHostSendDrainedUptime: eventDrained, postBarrier: postBarrier,
      finishedUptime: ProcessInfo.processInfo.systemUptime)
    let held = try await lifetime?.wait(simulator, degrees: degrees, expectedBoot: expectedBoot,
      write: write, protocolReceipt: protocolReceipt, completion: completion)
    try Task.checkCancellation()
    try completion.check()
    if let seconds = lifetime?.stateWaitSeconds {
      guard ProcessInfo.processInfo.systemUptime < startedUptime + seconds else {
        throw ChangeError.invalid("Caller state wait exceeded its advertised deadline")
      }
    } else { try requireTime(deadline) }
    return (write, protocolReceipt, held)
  }

  private static func barrier(_ connection: xpc_connection_t, queue: DispatchQueue, phase: String,
                              connectionID: String, deadline: Double,
                              completion: IndependentWriteCompletion) throws -> IndependentVendorBarrierReceipt {
    try Task.checkCancellation()
    try completion.check()
    try requireTime(deadline)
    let request = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_bool(request, "isBarrier", true)
    let reply = IndependentBarrierCompletion()
    let enqueued = ProcessInfo.processInfo.systemUptime
    xpc_connection_send_message_with_reply(connection, request, queue) { reply.receive($0) }
    let received = try reply.wait(deadline: deadline, phase: phase)
    try Task.checkCancellation()
    try completion.check()
    try requireTime(deadline)
    return IndependentVendorBarrierReceipt(phase: phase, connectionID: connectionID,
      requestEnqueuedUptime: enqueued, replyReceivedUptime: received.uptime, replyType: received.type,
      remainingBudgetSecondsAtRequest: deadline - enqueued)
  }

  private static func requireTime(_ deadline: Double) throws {
    guard ProcessInfo.processInfo.systemUptime <= deadline else {
      throw ChangeError.invalid("Independent vendor protocol exceeded8seconds")
    }
  }

  private static func connect(_ simulator: FBSimulator) throws -> xpc_connection_t {
    typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
    typealias Connect = @convention(c) (xpc_object_t) -> xpc_connection_t?
    typealias Enable = @convention(c) (xpc_connection_t) -> Void
    guard let handle = dlopen(nil, RTLD_NOW) else { throw ChangeError.invalid("XPC symbols unavailable") }
    defer { dlclose(handle) }
    guard let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
          let connectSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
          let enableSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
      throw ChangeError.invalid("Verified simulator XPC functions unavailable")
    }
    var error: NSError?
    let port = simulator.device.lookup(service, error: &error)
    guard port != 0,
          let endpoint = unsafeBitCast(endpointSymbol, to: Endpoint.self)(port, 0, 0),
          let connection = unsafeBitCast(connectSymbol, to: Connect.self)(endpoint) else {
      throw ChangeError.invalid(error?.localizedDescription ?? "Hinge vendor service unavailable")
    }
    unsafeBitCast(enableSymbol, to: Enable.self)(connection)
    return connection
  }

  /// Matches the verified Duo405 right-turn map in FBSimulatorRotationNative.target.
  static func rotationTarget(from current: Int, requested: Double, screenID: UInt32) throws -> String {
    let positions: [Int]
    if screenID == 1 { positions = [0, 90, 270] }
    else if screenID == 3 { positions = [0, 90, 180, 270] }
    else { throw ChangeError.invalid("Rotation target is not a verified Duo panel") }
    guard let index = positions.firstIndex(of: current),
          requested == Double(positions[(index + 1) % positions.count]) else {
      throw ChangeError.invalid("Requested rotation is not one right turn from the measured panel rotation")
    }
    let physical = (Int(requested) + (screenID == 1 ? 0 : 270)) % 360
    switch physical {
    case 0: return "portrait"
    case 90: return "landscape-right"
    case 180: return "pud"
    default: return "landscape-left"
    }
  }

  private static func message(_ degrees: Double, orientation: String?) throws -> xpc_object_t {
    let source = orientation == nil ? "hinge-slider-control" : "orientation-picker-control"
    let kind = orientation == nil ? "range" : "enum"
    let value: NSObject
    if let orientation { value = orientation as NSString }
    else { value = NSNumber(value: degrees) }
    let payload: [String: NSObject] = ["provider": "com.apple.Virtualization.VirtualMachines" as NSString,
      "source": source as NSString, "type": kind as NSString, "value": value]
    guard let serialized = IOCFSerialize(payload as CFDictionary, 1) else {
      throw ChangeError.invalid("Cannot serialize the independent vendor event")
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
}


struct IndependentConnectionHoldReceipt: Encodable {
  let outcome = "releasedByCaller"
  let connectionHeldUntilRelease = true
  let mechanicalTargetObserved = false
  let releaseToken: String
  let connectionID: String
  let readyUptime: Double
  let releaseReceivedUptime: Double
  let releaseReason: String
  let stateWaitBudgetSeconds: Double?
  let stateWaitDeadlineUptime: Double?
}

private struct IndependentProtocolReady: Encodable {
  let state = "protocolReadyConnectionHeld"
  let releaseToken: String
  let connectionID: String
  let expectedBootIdentity: String
  let simulatorUDID: String
  let requestedDegrees: Double
  let readyUptime: Double
  let deadlineUptime: Double
  let write: IndependentHingeWriteReceipt
  let vendorProtocol: IndependentVendorProtocolReceipt
  let stateWaitBudgetSeconds: Double?
  let stateWaitDeadlineUptime: Double?
}

private struct IndependentConnectionRelease: Decodable {
  enum Reason: String, Decodable { case targetObserved, abort }
  let state: String
  let releaseToken: String
  let connectionID: String
  let expectedBootIdentity: String
  let simulatorUDID: String
  let requestedDegrees: Double
  let reason: Reason
}

/// Explicit artifact IPC only. The caller owns all sensor reads; this owner keeps one connection alive.
private struct IndependentConnectionLifetime {
  let readyURL: URL
  let releaseURL: URL
  let stateWaitSeconds: Double?

  init(readyURL: URL, releaseURL: URL, stateWaitSeconds: Double? = nil) throws {
    guard stateWaitSeconds == nil || stateWaitSeconds == 30 else {
      throw ChangeError.invalid("Only the explicit30second state wait is supported")
    }
    guard readyURL.path.hasPrefix("/"), releaseURL.path.hasPrefix("/"), readyURL != releaseURL,
          readyURL.deletingLastPathComponent() == releaseURL.deletingLastPathComponent() else {
      throw ChangeError.invalid("Ready and release paths must be distinct absolute files in one output directory")
    }
    try Self.requireAbsent(readyURL)
    try Self.requireAbsent(releaseURL)
    self.readyURL = readyURL; self.releaseURL = releaseURL; self.stateWaitSeconds = stateWaitSeconds
  }

  func wait(_ simulator: FBSimulator, degrees: Double, expectedBoot: String,
            write: IndependentHingeWriteReceipt, protocolReceipt: IndependentVendorProtocolReceipt,
            completion: IndependentWriteCompletion) async throws -> IndependentConnectionHoldReceipt {
    try Task.checkCancellation()
    try completion.check()
    let token = UUID().uuidString
    let ready = ProcessInfo.processInfo.systemUptime
    let stateDeadline = stateWaitSeconds.map { protocolReceipt.startedUptime + $0 }
    let holdDeadline = stateDeadline ?? protocolReceipt.deadlineUptime
    guard ready < protocolReceipt.deadlineUptime else { throw ChangeError.invalid("Protocol-ready deadline expired") }
    let receipt = IndependentProtocolReady(releaseToken: token, connectionID: protocolReceipt.connectionID,
      expectedBootIdentity: expectedBoot, simulatorUDID: simulator.udid, requestedDegrees: degrees,
      readyUptime: ready, deadlineUptime: protocolReceipt.deadlineUptime, write: write, vendorProtocol: protocolReceipt,
      stateWaitBudgetSeconds: stateWaitSeconds, stateWaitDeadlineUptime: stateDeadline)
    try Self.requireAbsent(readyURL)
    try Self.requireAbsent(releaseURL)
    let temporary = readyURL.deletingLastPathComponent().appendingPathComponent(".protocol-ready-" + UUID().uuidString)
    try JSONEncoder().encode(receipt).write(to: temporary, options: .withoutOverwriting)
    defer { _ = temporary.path.withCString { unlink($0) } }
    guard temporary.path.withCString({ from in readyURL.path.withCString { link(from, $0) } }) == 0 else {
      throw ChangeError.invalid("Cannot atomically publish the exclusive protocol-ready file")
    }
    _ = temporary.path.withCString { unlink($0) }
    while true {
      try Task.checkCancellation()
      try completion.check()
      let remaining = holdDeadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { throw ChangeError.invalid("Caller did not release the vendor connection before its advertised deadline") }
      var info = stat()
      let found = releaseURL.path.withCString { lstat($0, &info) }
      if found == 0 {
        guard info.st_mode & S_IFMT == S_IFREG else { throw ChangeError.invalid("Release file is not regular") }
        let release = try JSONDecoder().decode(IndependentConnectionRelease.self, from: Data(contentsOf: releaseURL))
        guard release.state == "releaseVendorConnection", release.releaseToken == token,
              release.connectionID == protocolReceipt.connectionID, release.expectedBootIdentity == expectedBoot,
              release.simulatorUDID == simulator.udid, release.requestedDegrees == degrees else {
          throw ChangeError.invalid("Release file does not match this one-use connection token and target")
        }
        try IndependentHingeWriter.validate(simulator, expectedBoot: expectedBoot)
        try completion.check()
        try Task.checkCancellation()
        let received = ProcessInfo.processInfo.systemUptime
        guard received < holdDeadline else { throw ChangeError.invalid("Caller release arrived after its advertised deadline") }
        guard release.reason == .targetObserved else { throw ChangeError.invalid("Caller aborted the held vendor connection") }
        return IndependentConnectionHoldReceipt(releaseToken: token, connectionID: protocolReceipt.connectionID,
          readyUptime: ready, releaseReceivedUptime: received, releaseReason: release.reason.rawValue,
          stateWaitBudgetSeconds: stateWaitSeconds, stateWaitDeadlineUptime: stateDeadline)
      }
      guard errno == ENOENT else { throw ChangeError.invalid("Cannot inspect the caller release file") }
      try await Task.sleep(nanoseconds: UInt64(min(0.02, remaining) * 1_000_000_000))
    }
  }

  private static func requireAbsent(_ url: URL) throws {
    var info = stat()
    let result = url.path.withCString { lstat($0, &info) }
    guard result != 0, errno == ENOENT else { throw ChangeError.invalid("Control files must be new and absent") }
  }
}

/// The XPC callback queue is independent of the main actor that waits for its bounded host drain.
private final class IndependentWriteCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var finished = false
  private var failure: String?
  private var drainedUptime: Double?

  func finish(_ error: String?) {
    lock.lock()
    if let error, failure == nil { failure = error }
    guard !finished else { lock.unlock(); return }
    finished = true
    if error == nil { drainedUptime = ProcessInfo.processInfo.systemUptime }
    lock.unlock()
    semaphore.signal()
  }

  func wait(deadline: Double) throws -> Double {
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0, semaphore.wait(timeout: .now() + min(3, remaining)) == .success else {
      throw ChangeError.invalid("Independent vendor host-send drain timed out")
    }
    try check()
    lock.lock()
    let drained = drainedUptime
    lock.unlock()
    guard let drained, drained <= deadline else {
      throw ChangeError.invalid("Independent vendor host-send drain exceeded its deadline")
    }
    return drained
  }

  func check() throws {
    lock.lock()
    let error = failure
    lock.unlock()
    if let error { throw ChangeError.invalid(error) }
  }
}

/// The reply callback owns only this locked result; late replies cannot change a timed-out phase.
private final class IndependentBarrierCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var finished = false
  private var reply: (type: String, uptime: Double)?
  private var failure: String?

  func receive(_ object: xpc_object_t) {
    let uptime = ProcessInfo.processInfo.systemUptime
    let type = xpc_get_type(object)
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    if type == XPC_TYPE_ERROR { failure = "Vendor barrier returned XPC_TYPE_ERROR" }
    else { reply = (String(cString: xpc_type_get_name(type)), uptime) }
    lock.unlock()
    semaphore.signal()
  }

  func wait(deadline: Double, phase: String) throws -> (type: String, uptime: Double) {
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    let signalled = remaining > 0 && semaphore.wait(timeout: .now() + remaining) == .success
    lock.lock()
    finished = true
    let value = reply
    let error = failure
    lock.unlock()
    guard signalled else { throw ChangeError.invalid(phase + " vendor barrier reply timed out") }
    if let error { throw ChangeError.invalid(phase + ": " + error) }
    guard let value, value.uptime <= deadline else {
      throw ChangeError.invalid(phase + " vendor barrier reply was absent or late")
    }
    return value
  }
}
