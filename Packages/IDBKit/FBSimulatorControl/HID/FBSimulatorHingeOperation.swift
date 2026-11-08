import Foundation

public struct FBSimulatorHingeRequest: Encodable, Sendable {
  public let degrees: Double
  public let expectedBootIdentity: String
  public let toleranceDegrees: Double
  public let timeoutSeconds: Double
  public init(degrees: Double, expectedBootIdentity: String, toleranceDegrees: Double = 0.5,
              timeoutSeconds: Double = 8) throws {
    guard degrees.isFinite, (0...180).contains(degrees), !expectedBootIdentity.isEmpty,
          toleranceDegrees.isFinite, (0...1).contains(toleranceDegrees),
          timeoutSeconds.isFinite, (0.5...15).contains(timeoutSeconds) else {
      throw FBSimulatorHingeFailure(reason: .invalidRequest, detail: "Angle 0...180, tolerance 0...1, timeout 0.5...15 and boot identity are required", delivery: .notDispatched)
    }
    self.degrees = degrees; self.expectedBootIdentity = expectedBootIdentity
    self.toleranceDegrees = toleranceDegrees; self.timeoutSeconds = timeoutSeconds
  }
}
public struct FBSimulatorHingeSample: Codable, Sendable {
  public let mechanicalDegrees: Double
  public let sensedDegrees: Double
  public let velocityDegreesPerSecond: Double
  public let minimumDegrees: Double
  public let maximumDegrees: Double
  public let timestampUptime: Double
  public let receivedUptime: Double
}
public enum FBSimulatorHingeDelivery: String, Codable, Sendable { case notDispatched, uncertain }
public enum FBSimulatorHingeFailureReason: String, Codable, Sendable {
  case invalidRequest, busy, closed, unsupported, bootChanged, unavailable, timeout, cancelled
}
public struct FBSimulatorHingeFailure: Error, Codable, Sendable {
  public let reason: FBSimulatorHingeFailureReason
  public let detail: String
  public var delivery: FBSimulatorHingeDelivery
  public var requestedDegrees: Double? = nil
  public var latestSample: FBSimulatorHingeSample? = nil
}
public struct FBSimulatorHingeReceipt: Codable, Sendable {
  public let requestedDegrees: Double
  public let expectedBootIdentity: String
  public let toleranceDegrees: Double
  public let before: FBSimulatorHingeSample
  public let matchingSamples: [FBSimulatorHingeSample]
  public let wasAlreadyWithinTolerance: Bool
  public let startedUptime: Double
  public let finishedUptime: Double
  public let guestWriteAcknowledged: Bool = false
  public let outcome = "observedMechanicalTarget"
}

/// One backend owns one vendor connection. Native reads must honor cancellation.
protocol FBSimulatorHingeBackend: Sendable {
  func validate(expectedBoot: String) async throws
  func sample() async throws -> FBSimulatorHingeSample
  func dispatch(degrees: Double) async throws
  func close() async
}

/// A measured target is not a write acknowledgment or proof of future stability.
/// No automatic retry of a write, restore, panel selection or power operation.
public actor FBSimulatorHingeOperation {
  private let backend: any FBSimulatorHingeBackend
  private var busy = false
  private var finished = false
  init(backend: any FBSimulatorHingeBackend) { self.backend = backend }

  public func set(_ request: FBSimulatorHingeRequest) async throws -> FBSimulatorHingeReceipt {
    guard !busy else { throw FBSimulatorHingeFailure(reason: .busy, detail: "Another hinge operation is active", delivery: .notDispatched) }
    guard !finished else { throw FBSimulatorHingeFailure(reason: .closed, detail: "Create a new operation after each result", delivery: .notDispatched) }
    busy = true
    defer { busy = false; finished = true }
    let state = FBSimulatorHingeProgress()
    let started = ProcessInfo.processInfo.systemUptime
    do {
      let receipt = try await withThrowingTaskGroup(of: FBSimulatorHingeReceipt.self) { group in
        group.addTask { try await Self.run(request, backend: self.backend, state: state, started: started) }
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(request.timeoutSeconds * 1_000_000_000))
          throw FBSimulatorHingeFailure(reason: .timeout, detail: "Hinge readback deadline expired", delivery: .notDispatched)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
      }
      await backend.close()
      return receipt
    } catch {
      await backend.close()
      let progress = await state.snapshot()
      var failure = error as? FBSimulatorHingeFailure ?? FBSimulatorHingeFailure(
        reason: error is CancellationError ? .cancelled : .unavailable,
        detail: String(describing: error), delivery: .notDispatched)
      failure.delivery = progress.attempted ? .uncertain : .notDispatched
      failure.requestedDegrees = request.degrees
      failure.latestSample = progress.latest
      throw failure
    }
  }

  private static func run(_ request: FBSimulatorHingeRequest, backend: any FBSimulatorHingeBackend,
                          state: FBSimulatorHingeProgress, started: Double) async throws -> FBSimulatorHingeReceipt {
    try Task.checkCancellation()
    try await backend.validate(expectedBoot: request.expectedBootIdentity)
    let before = try await backend.sample()
    await state.record(before)
    try validateSample(before)
    guard (before.minimumDegrees...before.maximumDegrees).contains(request.degrees) else {
      throw FBSimulatorHingeFailure(reason: .invalidRequest, detail: "Requested angle is outside the measured range", delivery: .notDispatched)
    }
    try await backend.validate(expectedBoot: request.expectedBootIdentity)
    try Task.checkCancellation()
    // Mark before entering dispatch: cancellation at this boundary cannot prove no delivery.
    await state.markAttempted()
    try await backend.dispatch(degrees: request.degrees)
    let dispatched = ProcessInfo.processInfo.systemUptime
    var matches: [FBSimulatorHingeSample] = []
    var latestTimestamp = before.timestampUptime
    while true {
      try Task.checkCancellation()
      try await backend.validate(expectedBoot: request.expectedBootIdentity)
      let sample: FBSimulatorHingeSample
      do { sample = try await backend.sample() }
      catch is FBSimulatorHingeReadTimeout {
        // A slow read sends nothing. Read again; the request timeout still bounds the operation.
        continue
      }
      await state.record(sample)
      try validateSample(sample)
      try await backend.validate(expectedBoot: request.expectedBootIdentity)
      guard sample.timestampUptime >= dispatched, sample.timestampUptime > latestTimestamp else {
        throw FBSimulatorHingeFailure(reason: .unavailable, detail: "Hinge sample is not fresh after dispatch", delivery: .uncertain)
      }
      latestTimestamp = sample.timestampUptime
      guard sample.minimumDegrees == before.minimumDegrees, sample.maximumDegrees == before.maximumDegrees else {
        throw FBSimulatorHingeFailure(reason: .unavailable, detail: "Hinge range changed", delivery: .uncertain)
      }
      if abs(sample.mechanicalDegrees - request.degrees) <= request.toleranceDegrees {
        matches.append(sample)
      } else { matches.removeAll() }
      if matches.count == 2 {
        try Task.checkCancellation()
        return FBSimulatorHingeReceipt(requestedDegrees: request.degrees, expectedBootIdentity: request.expectedBootIdentity,
          toleranceDegrees: request.toleranceDegrees, before: before, matchingSamples: matches,
          wasAlreadyWithinTolerance: abs(before.mechanicalDegrees - request.degrees) <= request.toleranceDegrees,
          startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime)
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  static func validateSample(_ sample: FBSimulatorHingeSample) throws {
    let values = [sample.mechanicalDegrees, sample.sensedDegrees, sample.velocityDegreesPerSecond,
      sample.minimumDegrees, sample.maximumDegrees, sample.timestampUptime, sample.receivedUptime]
    guard values.allSatisfy({ $0.isFinite }), sample.minimumDegrees <= sample.maximumDegrees,
          (sample.minimumDegrees...sample.maximumDegrees).contains(sample.mechanicalDegrees),
          (sample.minimumDegrees...sample.maximumDegrees).contains(sample.sensedDegrees),
          sample.timestampUptime <= sample.receivedUptime else {
      throw FBSimulatorHingeFailure(reason: .unavailable, detail: "Invalid hinge sample", delivery: .notDispatched)
    }
  }
}
private actor FBSimulatorHingeProgress {
  var attempted = false
  var latest: FBSimulatorHingeSample?
  func markAttempted() { attempted = true }
  func record(_ sample: FBSimulatorHingeSample) { latest = sample }
  func snapshot() -> (attempted: Bool, latest: FBSimulatorHingeSample?) { (attempted, latest) }
}
