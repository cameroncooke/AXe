import Foundation

protocol FBSimulatorHingeReadinessBackend: Sendable {
  /// Must recheck expected boot/capability before a read and after success or a retryable failure.
  func read() async throws -> FBSimulatorHingeDisplayObservation
}

/// Observes display coherence after a completed hinge operation. Never sends a hinge or HID event.
public actor FBSimulatorHingeDisplayReadiness {
  public static let maximumAttempts = 16
  private let expected: FBSimulatorHingeReadinessRequest
  private let expectedBoot: String
  private let backend: any FBSimulatorHingeReadinessBackend
  private var busy = false
  private var finished = false

  init(expected: FBSimulatorHingeReadinessRequest, expectedBoot: String,
       backend: any FBSimulatorHingeReadinessBackend) {
    self.expected = expected; self.expectedBoot = expectedBoot; self.backend = backend
  }

  public func observe(after mechanical: FBSimulatorHingeReceipt) async -> FBSimulatorHingeReadinessReceipt {
    let started = ProcessInfo.processInfo.systemUptime
    var attempts: [FBSimulatorHingeReadinessAttempt] = []
    var previous: FBSimulatorHingeDisplayObservation?
    var last: FBSimulatorHingeDisplayObservation?
    func result(_ failure: FBSimulatorHingeReadinessError?, pair: [FBSimulatorHingeDisplayObservation] = []) -> FBSimulatorHingeReadinessReceipt {
      FBSimulatorHingeReadinessReceipt(outcome: failure == nil ? .coherent : .incomplete,
        expected: expected, expectedBootIdentity: expectedBoot, startedUptime: started,
        finishedUptime: ProcessInfo.processInfo.systemUptime, attempts: attempts,
        coherentObservations: pair, lastObservation: last, failure: failure, cleanup: failure?.cleanup ?? .confirmed)
    }
    guard !busy else { return result(.init(.busy, "Readiness observation is already running")) }
    guard !finished else { return result(.init(.closed, "Readiness observation is one-use")) }
    busy = true
    defer { busy = false; finished = true }
    guard mechanical.expectedBootIdentity == expectedBoot else {
      return result(.init(.bootChanged, "Mechanical receipt boot differs from the prepared observer"))
    }
    let deadline = started + expected.timeoutSeconds
    while attempts.count < Self.maximumAttempts {
      if Task.isCancelled { return result(.init(.cancelled, "Readiness was cancelled after mechanical completion")) }
      let now = ProcessInfo.processInfo.systemUptime
      guard now < deadline else { return result(.init(.deadline, "Display coherence deadline expired")) }
      let value = await Self.boundedRead(backend, remaining: deadline - now)
      let ended = ProcessInfo.processInfo.systemUptime
      let failure: FBSimulatorHingeReadinessError?
      switch value { case .success: failure = nil; case .failure(let error): failure = error }
      attempts.append(.init(index: attempts.count + 1, startedUptime: now, finishedUptime: ended, failure: failure))
      if let failure, failure.cleanup == .unconfirmed { return result(failure) }
      if let failure, !failure.permitsTransitionRetry { return result(failure) }
      if Task.isCancelled { return result(.init(.cancelled, "Readiness was cancelled; observer cleanup is confirmed")) }
      guard ended < deadline else { return result(.init(.deadline, "Display coherence deadline expired; observer cleanup is confirmed")) }
      switch value {
      case .failure(let failure):
        guard failure.permitsTransitionRetry else { return result(failure) }
        previous = nil
      case .success(let current):
        last = current
        guard abs(current.mechanicalBefore - mechanical.requestedDegrees) <= mechanical.toleranceDegrees,
              abs(current.mechanicalAfter - mechanical.requestedDegrees) <= mechanical.toleranceDegrees,
              current.velocityBefore == 0, current.velocityAfter == 0 else {
          return result(.init(.mechanicalTargetChanged, "Mechanical target or observed velocity changed after completion"))
        }
        if let previous, current.coherent(with: previous) {
          return result(nil, pair: [previous, current])
        }
        previous = current
      }
    }
    return result(.init(.attemptLimit, "Display coherence attempt limit reached"))
  }

  private enum ReadEvent: Sendable {
    case read(Result<FBSimulatorHingeDisplayObservation, FBSimulatorHingeReadinessError>)
    case timer
  }

  /// Cancellation never discards the read's cleanup result. The task group awaits both children.
  private static func boundedRead(_ backend: any FBSimulatorHingeReadinessBackend, remaining: Double)
    async -> Result<FBSimulatorHingeDisplayObservation, FBSimulatorHingeReadinessError> {
    await withTaskGroup(of: ReadEvent.self) { group in
      group.addTask {
        do { return .read(.success(try await backend.read())) }
        catch let error as FBSimulatorHingeReadinessError { return .read(.failure(error)) }
        catch { return .read(.failure(.init(error is CancellationError ? .cancelled : .unavailable, String(describing: error)))) }
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        return .timer
      }
      guard let first = await group.next() else { return .failure(.init(.unavailable, "Readiness task group returned no result")) }
      group.cancelAll()
      switch first {
      case .read(let value): return value
      case .timer:
        var readResult: Result<FBSimulatorHingeDisplayObservation, FBSimulatorHingeReadinessError>?
        for await event in group { if case .read(let value) = event { readResult = value } }
        if case .failure(let error) = readResult,
           error.cleanup == .unconfirmed || error.code == .bootChanged || error.code == .unsupported {
          return .failure(error)
        }
        return .failure(.init(Task.isCancelled ? .cancelled : .deadline, "Readiness deadline or cancellation reached; observer cleanup is confirmed"))
      }
    }
  }
}
