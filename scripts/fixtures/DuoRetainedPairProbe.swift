import AppKit
import Darwin
import Foundation
import FBControlCore
import FBSimulatorControl

final class PairReporter: NSObject, FBEventReporter {
  var metadata: [String: String] = [:]
  func report(_ event: FBEventReporterSubject) {}
  func addMetadata(_ metadata: [String: String]) {}
}

enum PairProbeError: Error { case invalid(String) }

struct PairPoint: Codable {
  let x: Double
  let y: Double
  var value: CGPoint { CGPoint(x: x, y: y) }
}

struct PairProbeConfiguration: Decodable {
  let simulatorUDID: String
  let bootIdentity: String
  let screenID: UInt32
  let screenUUID: UUID
  let helperPath: String
  let first: PairPoint
  let second: PairPoint
  let movedFirst: PairPoint
  let movedSecond: PairPoint
  let staleFirst: PairPoint
  let staleSecond: PairPoint
  let coordinationDirectory: String
  let mode: String
  let hingeDegrees: Double
}

struct PairStatus: Encodable {
  let state: String
  let hasRetainedContact: Bool
  let normalEnqueuedEventCount: Int
  let lastCleanup: String
  init(_ value: FBSimulatorHIDSessionStatus) {
    state = value.state.rawValue
    hasRetainedContact = value.hasRetainedContact
    normalEnqueuedEventCount = value.enqueuedEventCount
    lastCleanup = value.lastCleanup.rawValue
  }
}

struct PairOperation: Encodable {
  let outcome: String?
  let error: String?
  let normalEventDelta: Int
  let tokenReturned: Bool?
  let sameOriginalToken: Bool?
}

struct PairStage: Encodable {
  let stage: String
  let uptime: Double
  let frameworkPath: String
  let status: PairStatus
  let operation: PairOperation?
  let cleanupEvidence: FBSimulatorHIDCleanupEvidence?
  let feedValidation: String?
}

struct PairChange: Encodable {
  let mode: String
  let startedUptime: Double
  let finishedUptime: Double
  let before: FBSimulatorContextReadback
  let hinge: FBSimulatorHingeReceipt?
  let rotation: FBSimulatorRotationReceipt?
}

@main struct DuoRetainedPairProbe {
  @MainActor static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.count == 2, ["pair", "change", "short-factory"].contains(arguments[0]) else {
        throw PairProbeError.invalid("Expected pair|change|short-factory and one configuration file")
      }
      let configuration = try JSONDecoder().decode(PairProbeConfiguration.self,
        from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
      guard UUID(uuidString: configuration.simulatorUDID) != nil,
            ["normal", "fold", "rotate"].contains(configuration.mode),
            configuration.hingeDegrees.isFinite, (0...180).contains(configuration.hingeDegrees) else {
        throw PairProbeError.invalid("Invalid explicit simulator or change mode")
      }
      let logger = FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: true, withDebugLogging: false)
      FBControlCoreGlobalConfiguration.defaultLogger = logger
      try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
      let control = try FBSimulatorControl.withConfiguration(FBSimulatorControlConfiguration(
        deviceSetPath: nil, logger: logger, reporter: PairReporter()))
      guard let simulator = control.set.allSimulators.first(where: {
        UUID(uuidString: $0.udid) == UUID(uuidString: configuration.simulatorUDID)
      }), simulator.state == .booted else { throw PairProbeError.invalid("Assigned simulator is not booted") }
      if arguments[0] == "change" {
        try await change(configuration, simulator: simulator)
      } else if arguments[0] == "short-factory" {
        try await shortFactory(configuration, simulator: simulator)
      } else {
        try await pair(configuration, simulator: simulator)
      }
    } catch {
      FileHandle.standardError.write(Data((String(reflecting: error) + "\n").utf8))
      exit(2)
    }
  }

  @MainActor static func emit(_ name: String, session: FBSimulatorHIDSession,
                              operation: PairOperation? = nil, validation: String? = nil) async throws {
    let value = PairStage(stage: name, uptime: ProcessInfo.processInfo.systemUptime,
      frameworkPath: Bundle(for: FBSimulator.self).bundleURL.path,
      status: PairStatus(await session.status()), operation: operation,
      cleanupEvidence: await session.cleanupEvidence(), feedValidation: validation)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
  }

  static func waitFor(_ name: String, configuration: PairProbeConfiguration, seconds: Double = 15) async throws {
    let file = URL(fileURLWithPath: configuration.coordinationDirectory).appendingPathComponent(name)
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !FileManager.default.fileExists(atPath: file.path) {
      if FileManager.default.fileExists(atPath: URL(fileURLWithPath: configuration.coordinationDirectory).appendingPathComponent("abort.ready").path) {
        throw PairProbeError.invalid("Driver stopped the case; release owned input without replay")
      }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw PairProbeError.invalid("Timed out waiting for " + name + "; no replay")
      }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
  }

  @MainActor static func pair(_ configuration: PairProbeConfiguration, simulator: FBSimulator) async throws {
    let feed = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator,
      helperURL: URL(fileURLWithPath: configuration.helperPath),
      screenID: configuration.screenID, screenUniqueID: configuration.screenUUID)
    guard feed.initialObservation.bootIdentity == configuration.bootIdentity else {
      await feed.closeAndWait(); throw PairProbeError.invalid("Boot changed before pair session")
    }
    let session = try await FBSimulatorHIDSession.open(for: simulator,
      observation: feed.initialObservation, liveFreshnessProvider: feed)
    do {
      let begin = try await session.beginTwoFinger(first: configuration.first.value, second: configuration.second.value)
      guard let token = begin.token else { throw PairProbeError.invalid("Pair begin returned no token") }
      try await emit("began", session: session, operation: PairOperation(outcome: begin.outcome.rawValue,
        error: nil, normalEventDelta: begin.enqueuedEventCount, tokenReturned: true, sameOriginalToken: true))
      try await waitFor("move.ready", configuration: configuration)
      let moved = try await session.moveTwoFinger(token, first: configuration.movedFirst.value, second: configuration.movedSecond.value)
      try await emit("moved", session: session, operation: PairOperation(outcome: moved.outcome.rawValue,
        error: nil, normalEventDelta: moved.enqueuedEventCount, tokenReturned: moved.token != nil, sameOriginalToken: moved.token == token))
      try await waitFor("finish.ready", configuration: configuration, seconds: 25)
      if configuration.mode == "normal" {
        let ended = try await session.end(token)
        try await emit("ended", session: session, operation: PairOperation(outcome: ended.outcome.rawValue,
          error: nil, normalEventDelta: ended.enqueuedEventCount, tokenReturned: ended.token != nil, sameOriginalToken: ended.token == token))
      } else {
        // Read-only idle observation. It must not call move, end or close first.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var validation = "current"
        do { try feed.validateCurrentRevision(expected: feed.initialObservation) }
        catch { validation = String(reflecting: error) }
        try await emit("idleAfterChange", session: session, validation: validation)
        try await waitFor("stale-move.ready", configuration: configuration)
        for attempt in 1...2 {
          if attempt == 2 { try await waitFor("second-stale.ready", configuration: configuration) }
          let before = await session.status()
          var failure: String?
          var receipt: FBSimulatorHIDSessionReceipt?
          do { receipt = try await session.moveTwoFinger(token, first: configuration.staleFirst.value, second: configuration.staleSecond.value) }
          catch { failure = String(reflecting: error) }
          let after = await session.status()
          try await emit("oldMove" + String(attempt), session: session,
            operation: PairOperation(outcome: receipt?.outcome.rawValue, error: failure,
              normalEventDelta: after.enqueuedEventCount - before.enqueuedEventCount,
              tokenReturned: receipt.map { $0.token != nil }, sameOriginalToken: receipt.map { $0.token == token }))
        }
      }
      if configuration.mode != "normal" {
        let beforeEnd = await session.status()
        var failure: String?
        do { _ = try await session.end(token) }
        catch { failure = String(reflecting: error) }
        let afterEnd = await session.status()
        try await emit("oldEnd", session: session, operation: PairOperation(outcome: nil, error: failure,
          normalEventDelta: afterEnd.enqueuedEventCount - beforeEnd.enqueuedEventCount,
          tokenReturned: nil, sameOriginalToken: nil))
      }
      let beforeClose = await session.status()
      let closed = try await session.close()
      let afterClose = await session.status()
      try await emit("closed", session: session, operation: PairOperation(outcome: closed.outcome.rawValue,
        error: nil, normalEventDelta: afterClose.enqueuedEventCount - beforeClose.enqueuedEventCount,
        tokenReturned: closed.token != nil, sameOriginalToken: closed.token == token))
      await feed.closeAndWait()
    } catch {
      let failure = String(reflecting: error)
      _ = try? await session.close()
      await feed.closeAndWait()
      try? await emit("failedAfterCleanup", session: session,
        operation: PairOperation(outcome: nil, error: failure, normalEventDelta: 0,
          tokenReturned: nil, sameOriginalToken: nil))
      throw error
    }
  }

  @MainActor static func shortFactory(_ configuration: PairProbeConfiguration, simulator: FBSimulator) async throws {
    let feed = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator,
      helperURL: URL(fileURLWithPath: configuration.helperPath), screenID: configuration.screenID, screenUniqueID: configuration.screenUUID)
    guard feed.initialObservation.bootIdentity == configuration.bootIdentity else {
      await feed.closeAndWait(); throw PairProbeError.invalid("Boot changed before short factory")
    }
    let session = try await FBSimulatorHIDSession.open(for: simulator, observation: feed.initialObservation, liveFreshnessProvider: feed)
    do {
      let first = configuration.first
      let second = configuration.second
      guard hypot(second.x - first.x, second.y - first.y) == 1 else { throw PairProbeError.invalid("Expected one-point factory path") }
      let event = FBSimulatorHIDEvent.swipe(first.x, yStart: first.y, xEnd: second.x, yEnd: second.y, delta: 50, duration: 0.3)
      _ = try FBSimulatorHIDSession.preflight(event, observation: feed.initialObservation)
      let receipt = try await session.execute(event)
      guard receipt.enqueuedEventCount == 4 else { throw PairProbeError.invalid("Short factory did not enqueue four balanced primitives") }
      try await emit("shortFactoryCompleted", session: session, operation: PairOperation(outcome: receipt.outcome.rawValue,
        error: nil, normalEventDelta: receipt.enqueuedEventCount, tokenReturned: receipt.token != nil, sameOriginalToken: nil))
      _ = try await session.close()
      await feed.closeAndWait()
    } catch {
      _ = try? await session.close()
      await feed.closeAndWait()
      throw error
    }
  }

  /// External device-state write only. It neither sends touch input nor takes an AXe input lease.
  @MainActor static func change(_ configuration: PairProbeConfiguration, simulator: FBSimulator) async throws {
    guard configuration.mode != "normal" else { throw PairProbeError.invalid("Normal case has no external change") }
    let helper = URL(fileURLWithPath: configuration.helperPath)
    let reader = FBSimulatorNativeContextReader(simulator: simulator, helperURL: helper,
      screenID: configuration.screenID, screenUniqueID: configuration.screenUUID)
    let before = try await reader.read()
    guard before.observation.bootIdentity == configuration.bootIdentity else { throw PairProbeError.invalid("Boot changed before external change") }
    let started = ProcessInfo.processInfo.systemUptime
    var hinge: FBSimulatorHingeReceipt?
    var rotation: FBSimulatorRotationReceipt?
    if configuration.mode == "fold" {
      hinge = try await FBSimulatorHingeNative.operation(for: simulator).set(
        FBSimulatorHingeRequest(degrees: configuration.hingeDegrees, expectedBootIdentity: configuration.bootIdentity,
          toleranceDegrees: 0.5, timeoutSeconds: 8))
    } else {
      rotation = try await FBSimulatorRotationNative.rotate(for: simulator, helperURL: helper,
        screenID: configuration.screenID, screenUUID: configuration.screenUUID,
        expectedBootIdentity: configuration.bootIdentity, direction: .right)
    }
    let value = PairChange(mode: configuration.mode, startedUptime: started,
      finishedUptime: ProcessInfo.processInfo.systemUptime, before: before, hinge: hinge, rotation: rotation)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value)); FileHandle.standardOutput.write(Data([10]))
  }
}
