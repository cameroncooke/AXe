import FBControlCore
import Foundation

public enum FBSimulatorAXAcquisitionOutcome: String, Codable, Sendable {
  case ready, notReady, cancelled, deadlineExceeded, requestTimedOut, processChanged, contextChanged, failed
  /// A point read found no accessibility element at the point. It is evidence of empty space,
  /// never of a target; callers decide whether the complete tree can account for the point.
  case noElementAtPoint
}

public struct FBSimulatorAXAcquisitionPolicy: Sendable {
  public let timeoutSeconds: Double
  public let maximumAttempts: Int
  public let retryDelaySeconds: Double
  public init(timeoutSeconds: Double = 8, maximumAttempts: Int = 4) throws {
    try self.init(timeoutSeconds: timeoutSeconds, maximumAttempts: maximumAttempts, retryDelaySeconds: 0)
  }
  public init(timeoutSeconds: Double, maximumAttempts: Int,
              retryDelaySeconds: Double) throws {
    guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 30,
          (1...8).contains(maximumAttempts), retryDelaySeconds.isFinite,
          retryDelaySeconds >= 0, retryDelaySeconds <= timeoutSeconds else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    self.timeoutSeconds = timeoutSeconds
    self.maximumAttempts = maximumAttempts
    self.retryDelaySeconds = retryDelaySeconds
  }
}

public struct FBSimulatorAXAcquisitionAttempt: Encodable, Sendable {
  public let index: Int
  public let startUptime: Double
  public let endUptime: Double
  public let rootPID: Int32
  public let outcome: FBSimulatorAXAcquisitionOutcome
  public let jsonData: Data?
  enum CodingKeys: String, CodingKey { case index, startUptime, endUptime, rootPID, outcome }
}

public struct FBSimulatorAXAcquisitionPhase: Encodable, Sendable {
  public let name: String
  public let uptime: Double
}

public struct FBSimulatorAXAcquisition: Sendable {
  public let snapshot: FBSimulatorAXSnapshot?
  public let outcome: FBSimulatorAXAcquisitionOutcome
  public let attempts: [FBSimulatorAXAcquisitionAttempt]
  public let phases: [FBSimulatorAXAcquisitionPhase]
  public let failureDescription: String?
}

/// One monotonic deadline. Cancellation wakes the current synchronous AX wait.
/// All mutable fields are under the lock; no platform AX handle is stored here.
final class FBAXAcquisitionBudget: @unchecked Sendable {
  private let lock = NSLock()
  private let deadline: DispatchTime
  private var terminal: FBSimulatorAXAcquisitionOutcome?
  private var waiters: [UUID: DispatchSemaphore] = [:]
  init(seconds: Double) { deadline = .now() + seconds }
  func stop(_ outcome: FBSimulatorAXAcquisitionOutcome) {
    lock.lock()
    if terminal == nil { terminal = outcome }
    let pending = Array(waiters.values)
    lock.unlock()
    pending.forEach { $0.signal() }
  }
  func check() throws {
    lock.lock()
    if terminal == nil && DispatchTime.now() >= deadline { terminal = .deadlineExceeded }
    let value = terminal
    lock.unlock()
    if let value { throw FBAXAcquisitionStop(outcome: value) }
  }
  func remainingSeconds() throws -> Double {
    lock.lock()
    let now = DispatchTime.now()
    if terminal == nil && now >= deadline { terminal = .deadlineExceeded }
    let value = terminal
    let remaining = now < deadline ? Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000 : 0
    lock.unlock()
    if let value { throw FBAXAcquisitionStop(outcome: value) }
    return remaining
  }
  /// Read-only readiness polling shares the original deadline and cancellation.
  func waitForReadiness(seconds: Double) async throws {
    try check()
    try Task.checkCancellation()
    let remaining = try remainingSeconds()
    try await Task.sleep(nanoseconds: UInt64(min(seconds, remaining) * 1_000_000_000))
    try check()
    try Task.checkCancellation()
  }
  func wait(_ signal: DispatchSemaphore, requestTimeout: Double, send: () -> Void) throws {
    try check()
    let token = UUID()
    lock.lock()
    if let value = terminal { lock.unlock(); throw FBAXAcquisitionStop(outcome: value) }
    waiters[token] = signal
    lock.unlock()
    defer { lock.lock(); waiters.removeValue(forKey: token); lock.unlock() }
    try check()
    send()
    let requestDeadline = DispatchTime.now() + requestTimeout
    let waitDeadline = min(deadline, requestDeadline)
    let result = signal.wait(timeout: waitDeadline)
    if result == .timedOut { stop(DispatchTime.now() >= deadline ? .deadlineExceeded : .requestTimedOut) }
    try check()
  }
}
struct FBAXAcquisitionStop: Error { let outcome: FBSimulatorAXAcquisitionOutcome }
/// The frontmost app answered, but the point request returned no element.
struct FBAXEmptyPoint: Error, CustomStringConvertible {
  var description: String { "No accessibility element at the requested point" }
}

extension FBSimulatorAXSnapshot {
  /// Explicit bounded acquisition. Each empty response is retained in the result.
  /// A changed PID fails immediately; this operation never waits for another app.
  /// A verified empty first response can use the existing preparation within the same budget.
  public static func acquire(
    for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    policy: FBSimulatorAXAcquisitionPolicy
  ) async throws -> FBSimulatorAXAcquisition {
    guard expectedPID > 0 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    let budget = FBAXAcquisitionBudget(seconds: policy.timeoutSeconds)
    return await withTaskCancellationHandler(operation: {
      await FBSimulatorAXWorker.shared.acquire(for: simulator, expectedPID: expectedPID,
        observation: observation, provider: freshnessProvider, policy: policy, budget: budget)
    }, onCancel: { budget.stop(.cancelled) })
  }

  /// Discover and bind one frontmost process within the same bounded acquisition.
  /// Process changes fail the read; later attempts never bind a different app.
  public static func acquireFrontmost(
    for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    policy: FBSimulatorAXAcquisitionPolicy
  ) async throws -> FBSimulatorAXAcquisition {
    let budget = FBAXAcquisitionBudget(seconds: policy.timeoutSeconds)
    return await withTaskCancellationHandler(operation: {
      await FBSimulatorAXWorker.shared.acquireBound(for: simulator, expectedPID: nil,
        observation: observation, provider: freshnessProvider, policy: policy, budget: budget)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

extension FBSimulatorAXWorker {
  func acquire(for simulator: FBSimulator, expectedPID: Int32,
               observation: FBSimulatorHIDSessionObservation,
               provider: any FBSimulatorHIDFreshnessProvider,
               policy: FBSimulatorAXAcquisitionPolicy,
               budget: FBAXAcquisitionBudget) async -> FBSimulatorAXAcquisition {
    await acquireBound(for: simulator, expectedPID: expectedPID, observation: observation,
      provider: provider, policy: policy, budget: budget)
  }

  func acquireBound(for simulator: FBSimulator, expectedPID: Int32?,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDFreshnessProvider,
    policy: FBSimulatorAXAcquisitionPolicy, budget: FBAXAcquisitionBudget) async -> FBSimulatorAXAcquisition {
    await acquireBound(for: simulator, expectedPID: expectedPID, observation: observation,
      provider: provider, policy: policy, budget: budget, includeNativeIdentity: false)
  }

  func acquireBound(for simulator: FBSimulator, expectedPID: Int32?,
               observation: FBSimulatorHIDSessionObservation,
               provider: any FBSimulatorHIDFreshnessProvider,
               policy: FBSimulatorAXAcquisitionPolicy,
               budget: FBAXAcquisitionBudget, includeNativeIdentity: Bool) async -> FBSimulatorAXAcquisition {
    var boundPID = expectedPID
    var phases: [FBSimulatorAXAcquisitionPhase] = []
    var attempts: [FBSimulatorAXAcquisitionAttempt] = []
    var snapshot: FBSimulatorAXSnapshot?
    var outcome: FBSimulatorAXAcquisitionOutcome = .notReady
    var failure: String?
    var pendingAttempt: (index: Int, start: Double, pid: Int32, data: Data?)?
    func phase(_ name: String) {
      let uptime = ProcessInfo.processInfo.systemUptime
      phases.append(.init(name: name, uptime: uptime))
      simulator.logger?.log("AX acquisition phase=\(name) uptime=\(uptime)")
    }
    phase("start")
    do {
      try Task.checkCancellation()
      try budget.check()
      try await validateSelection(simulator, observation: observation, provider: provider)
      try budget.check()
      let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
      phase("standard-read")
      try budget.check(); try Task.checkCancellation()
      try commands.validateAccessibility(bootstrap: false)
      try budget.check()
      try Task.checkCancellation()
      if policy.maximumAttempts == 1 {
        phase("single-attempt-preparation-start")
        try prepareAccessibility(for: simulator, budget: budget)
        phase("single-attempt-preparation-finished")
      } else {
        phase("direct-first-read")
      }
      for index in 1...policy.maximumAttempts {
        try budget.check()
        try Task.checkCancellation()
        try FBSimulatorAXSnapshot.requireSame(observation, try await provider.observation())
        try budget.check()
        let started = ProcessInfo.processInfo.systemUptime
        let request = FBAXTranslationRequest(kind: .frontmostApplication,
          pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
        request.acquisitionBudget = budget
        pendingAttempt = (index, started, 0, nil)
        phase("attempt-\(index)-start")
        let handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
        defer { handle.close() }
        try budget.check()
        let pid = handle.acquisitionPID
        pendingAttempt?.pid = pid
        if boundPID == nil, pid > 0 { boundPID = pid }
        guard let expectedPID = boundPID, pid == expectedPID else {
          attempts.append(.init(index: index, startUptime: started, endUptime: ProcessInfo.processInfo.systemUptime,
            rootPID: pid, outcome: .processChanged, jsonData: nil))
          pendingAttempt = nil
          throw FBAXAcquisitionStop(outcome: .processChanged)
        }
        let candidate = try serialize(handle, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity)
        pendingAttempt?.data = candidate.jsonData
        try budget.check()
        // A new root request detects process switches during serialization.
        let verifyRequest = FBAXTranslationRequest(kind: .frontmostApplication,
          pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
        verifyRequest.acquisitionBudget = budget
        let verifyHandle = try await commands.accessibilityElementForAcquisition(request: verifyRequest, worker: self)
        let verifiedPID = verifyHandle.acquisitionPID
        verifyHandle.close()
        try budget.check()
        guard verifiedPID == expectedPID else {
          attempts.append(.init(index: index, startUptime: started, endUptime: ProcessInfo.processInfo.systemUptime,
            rootPID: verifiedPID, outcome: .processChanged, jsonData: candidate.jsonData))
          pendingAttempt = nil
          throw FBAXAcquisitionStop(outcome: .processChanged)
        }
        try FBSimulatorAXSnapshot.requireSame(observation, try await provider.observation())
        try budget.check()
        try Task.checkCancellation()
        let ready = candidate.roots.contains { $0.pid == expectedPID && !$0.children.isEmpty }
        attempts.append(.init(index: index, startUptime: started, endUptime: ProcessInfo.processInfo.systemUptime,
          rootPID: pid, outcome: ready ? .ready : .notReady, jsonData: candidate.jsonData))
        pendingAttempt = nil
        phase("attempt-\(index)-\(ready ? "ready" : "notReady")")
        handle.close()
        if ready { snapshot = candidate; outcome = .ready; break }
        if index == 1, policy.maximumAttempts > 1,
           candidate.roots.count == 1, let root = candidate.roots.first,
           root.pid == expectedPID, root.type == "Application",
           root.frame == .zero, root.children.isEmpty {
          // Both root reads and the current display context matched before preparation.
          // The next read is an existing policy attempt, not a hidden extra request.
          phase("empty-root-preparation-start")
          try prepareAccessibility(for: simulator, budget: budget)
          phase("empty-root-preparation-finished")
        }
        if index < policy.maximumAttempts, policy.retryDelaySeconds > 0,
           candidate.roots.count == 1, let root = candidate.roots.first,
           root.pid == expectedPID, root.type == "Application",
           root.frame == .zero, root.children.isEmpty {
          try FBSimulatorAXSnapshot.requireSame(observation, try await provider.observation())
          try budget.check()
          phase("empty-root-retry-wait-start")
          try await budget.waitForReadiness(seconds: policy.retryDelaySeconds)
          try FBSimulatorAXSnapshot.requireSame(observation, try await provider.observation())
          try budget.check()
          phase("empty-root-retry-wait-finished")
        }
        // The next bounded attempt obtains a new handle and a fresh context read.
        // No relaunch, bridge restart, or passive status promotion occurs.
      }
    } catch {
      snapshot = nil
      failure = String(reflecting: error)
      if let stopped = error as? FBAXAcquisitionStop { outcome = stopped.outcome }
      else if error is CancellationError { outcome = .cancelled }
      else if let selection = error as? FBSimulatorAXSnapshotError,
              case .staleContext = selection { outcome = .contextChanged }
      else { outcome = .failed }
    }
    if let pendingAttempt {
      attempts.append(.init(index: pendingAttempt.index, startUptime: pendingAttempt.start,
        endUptime: ProcessInfo.processInfo.systemUptime, rootPID: pendingAttempt.pid,
        outcome: outcome, jsonData: pendingAttempt.data))
    }
    phase("standard-read-finished")
    if outcome == .ready {
      do { try budget.check(); try Task.checkCancellation() }
      catch {
        snapshot = nil
        outcome = (error as? FBAXAcquisitionStop)?.outcome ?? .cancelled
        failure = String(reflecting: error)
      }
    }
    return .init(snapshot: snapshot, outcome: outcome, attempts: attempts,
      phases: phases, failureDescription: failure)
  }
}


extension FBSimulatorAXSnapshot {
  /// One read-only point query in oriented logical coordinates. The foreground
  /// application and the point result must both belong to expectedPID. No remote
  /// ownership inference or input is permitted. The read is direct; runtime preparation
  /// and one repeat of every check run only after a direct read fails for another reason.
  public static func acquire(
    at point: CGPoint, for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    policy: FBSimulatorAXAcquisitionPolicy
  ) async throws -> FBSimulatorAXAcquisition {
    guard expectedPID > 0 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    _ = try FBAXPointReadRules.nativePoint(point, observation: observation)
    let reservation = try FBAXTargetReservation.acquire()
    defer { withExtendedLifetime(reservation) {} }
    let budget = FBAXAcquisitionBudget(seconds: policy.timeoutSeconds)
    return await withTaskCancellationHandler(operation: {
      await FBSimulatorAXWorker.shared.acquirePoint(point, for: simulator, expectedPID: expectedPID,
        observation: observation, provider: freshnessProvider, budget: budget)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

/// Point reads use the existing AX transform. A successful read is not an input
/// target reference and does not establish ownership of a separate process.
enum FBAXPointReadRules {
  static func nativePoint(_ point: CGPoint, observation: FBSimulatorHIDSessionObservation) throws -> CGPoint {
    let size = observation.displayContext.logicalSize
    guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
          point.x < size.width, point.y < size.height else {
      throw FBSimulatorAXTargetError.invalidPoint
    }
    let transform = FBAXTranslationRequest(kind: .point(point), pointDisplayID: observation.axDisplayID,
      displayContext: observation.displayContext)
    return try transform.nativePoint(from: point)
  }

  static func frontmost(_ pid: Int32, expectedPID: Int32) throws {
    guard expectedPID > 0, pid == expectedPID else {
      throw FBAXAcquisitionStop(outcome: .processChanged)
    }
  }

  static func directHit(_ roots: [FBSimulatorAXNode], expectedPID: Int32, hitPID: Int32) throws {
    guard expectedPID > 0, hitPID == expectedPID else {
      throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: hitPID)
    }
    guard roots.count == 1, roots.first?.pid == expectedPID else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
  }
}

extension FBSimulatorAXWorker {
  func acquirePoint(_ point: CGPoint, for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDFreshnessProvider,
    budget: FBAXAcquisitionBudget) async -> FBSimulatorAXAcquisition {
    await acquirePoint(point, for: simulator, expectedPID: expectedPID, observation: observation,
      provider: provider, budget: budget, includeNativeIdentity: false)
  }

  func acquirePoint(_ point: CGPoint, for simulator: FBSimulator, expectedPID: Int32,
                    observation: FBSimulatorHIDSessionObservation,
                    provider: any FBSimulatorHIDFreshnessProvider,
                    budget: FBAXAcquisitionBudget, includeNativeIdentity: Bool) async -> FBSimulatorAXAcquisition {
    var phases: [FBSimulatorAXAcquisitionPhase] = []
    var snapshot: FBSimulatorAXSnapshot?
    var data: Data?
    var rootPID: Int32 = 0
    var outcome: FBSimulatorAXAcquisitionOutcome = .failed
    var failure: String?
    let started = ProcessInfo.processInfo.systemUptime
    func phase(_ name: String) {
      phases.append(.init(name: name, uptime: ProcessInfo.processInfo.systemUptime))
    }
    phase("point-read-start")
    do {
      try Task.checkCancellation()
      try budget.check()
      let native = try FBAXPointReadRules.nativePoint(point, observation: observation)
      try await validateSelection(simulator, observation: observation, provider: provider)
      try budget.check()
      let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
      phase("standard-read")
      try budget.check(); try Task.checkCancellation()
      try commands.validateAccessibility(bootstrap: false)
      try budget.check()
      // Direct first, as whole-tree reads are. Runtime preparation runs only after a direct
      // read fails for a reason other than process, context, cancellation or deadline, and
      // the one retry repeats every check below within the same budget.
      func readHit() async throws -> FBSimulatorAXSnapshot {
        rootPID = try await pointReadFrontmostPID(commands, observation: observation, budget: budget)
        try FBAXPointReadRules.frontmost(rootPID, expectedPID: expectedPID)
        phase("frontmost-before-matched")
        let request = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
          displayContext: observation.displayContext)
        request.acquisitionBudget = budget
        try budget.check()
        try Task.checkCancellation()
        let handle: FBAccessibilityElement
        do { handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self) }
        catch let accessibility as FBAccessibilityError {
          // The frontmost app read above succeeded, so accessibility is answering. No element
          // at this point is empty space; preparation cannot change that.
          if case .noTranslationObject = accessibility { throw FBAXEmptyPoint() }
          throw accessibility
        }
        defer { handle.close() }
        try budget.check()
        let hitPID = handle.acquisitionPID
        guard hitPID == expectedPID else {
          throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: hitPID)
        }
        let candidate = try serialize(handle, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity)
        data = candidate.jsonData
        try FBAXPointReadRules.directHit(candidate.roots, expectedPID: expectedPID, hitPID: hitPID)
        return candidate
      }
      let candidate: FBSimulatorAXSnapshot
      do {
        phase("direct-point-read")
        candidate = try await readHit()
      } catch let error where Self.pointReadMayNeedPreparation(error) {
        try budget.check()
        try FBSimulatorAXSnapshot.requireSame(observation, try await provider.observation())
        phase("point-preparation-start")
        try prepareAccessibility(for: simulator, budget: budget)
        phase("point-preparation-finished")
        data = nil
        candidate = try await readHit()
      }
      phase("point-read-matched")
      try budget.check()
      let afterPID = try await pointReadFrontmostPID(commands, observation: observation, budget: budget)
      try FBAXPointReadRules.frontmost(afterPID, expectedPID: expectedPID)
      phase("frontmost-after-matched")
      try await validateSelection(simulator, observation: observation, provider: provider)
      try budget.check()
      try Task.checkCancellation()
      snapshot = candidate
      outcome = .ready
    } catch {
      failure = String(reflecting: error)
      if let stopped = error as? FBAXAcquisitionStop { outcome = stopped.outcome }
      else if error is CancellationError { outcome = .cancelled }
      else if let selection = error as? FBSimulatorAXSnapshotError,
              case .staleContext = selection { outcome = .contextChanged }
      else if error is FBAXEmptyPoint { outcome = .noElementAtPoint }
      else { outcome = .failed }
    }
    phase("standard-read-finished")
    if outcome == .ready {
      do { try budget.check(); try Task.checkCancellation() }
      catch {
        snapshot = nil
        outcome = (error as? FBAXAcquisitionStop)?.outcome ?? .cancelled
        failure = String(reflecting: error)
      }
    }
    return .init(snapshot: snapshot, outcome: outcome,
      attempts: [.init(index: 1, startUptime: started, endUptime: ProcessInfo.processInfo.systemUptime,
        rootPID: rootPID, outcome: outcome, jsonData: data)],
      phases: phases, failureDescription: failure)
  }

  /// A changed process, wrong hit owner, changed context, cancellation or spent budget is final.
  static func pointReadMayNeedPreparation(_ error: Error) -> Bool {
    if error is CancellationError || error is FBAXAcquisitionStop { return false }
    if let selection = error as? FBSimulatorAXSnapshotError, case .staleContext = selection { return false }
    if let target = error as? FBSimulatorAXTargetError, case .wrongPID = target { return false }
    if error is FBAXEmptyPoint { return false }
    return true
  }

  /// Keep the existing runtime preparation and its five-second ceiling, but all
  /// session phases must also fit within the acquisition's remaining deadline.
  private func prepareAccessibility(for simulator: FBSimulator, budget: FBAXAcquisitionBudget) throws {
    try budget.check()
    try Task.checkCancellation()
    guard FBSimulatorAccessibilityCommands.requiresAccessibilityBootstrap(for: simulator.osVersion.version) else { return }
    let remaining = min(5, try budget.remainingSeconds())
    do {
      try FBSimulatorControlFrameworkLoader.bootstrapAccessibility(
        forSimulatorDevice: simulator.device, timeout: remaining, logger: simulator.logger)
    } catch {
      try budget.check()
      try Task.checkCancellation()
      throw error
    }
    try budget.check()
    try Task.checkCancellation()
  }

  private func pointReadFrontmostPID(_ commands: FBSimulatorAccessibilityCommands,
                                    observation: FBSimulatorHIDSessionObservation,
                                    budget: FBAXAcquisitionBudget) async throws -> Int32 {
    try budget.check()
    try Task.checkCancellation()
    let request = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    request.acquisitionBudget = budget
    let handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
    defer { handle.close() }
    try budget.check()
    return handle.acquisitionPID
  }
}

extension FBSimulatorAXSnapshot {
  /// A bounded focus read for a verified live keyboard operation.
  /// The caller retains full authoritative context checks before input and after drain.
  /// Every call reads a new root and field; no AX handle or cached field is reused.
  public static func readFocusedTextField(
    for simulator: FBSimulator, expectedPID: Int32, identifier: String,
    observation: FBSimulatorHIDSessionObservation,
    liveFreshnessProvider: any FBSimulatorHIDLiveFreshnessProvider,
    timeoutSeconds: Double
  ) async throws -> FBSimulatorAXNode {
    guard expectedPID > 0, !identifier.isEmpty, identifier.utf8.count <= 4096,
          identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
          timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 8 else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let budget = FBAXAcquisitionBudget(seconds: timeoutSeconds)
    return try await withTaskCancellationHandler(operation: {
      try await FBSimulatorAXWorker.shared.readFocusedTextField(for: simulator,
        expectedPID: expectedPID, identifier: identifier, observation: observation,
        provider: liveFreshnessProvider, budget: budget)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

extension FBSimulatorAXWorker {
  func readFocusedTextField(for simulator: FBSimulator, expectedPID: Int32,
                           identifier: String, observation: FBSimulatorHIDSessionObservation,
                           provider: any FBSimulatorHIDLiveFreshnessProvider,
                           budget: FBAXAcquisitionBudget) async throws -> FBSimulatorAXNode {
    try Task.checkCancellation()
    try budget.check()
    guard simulator.udid == observation.simulatorUDID else { throw FBSimulatorAXSnapshotError.wrongSimulator }
    try provider.validateCurrentRevision(expected: observation)
    let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
    try budget.check(); try Task.checkCancellation()
    try commands.validateAccessibility(bootstrap: false)
    try budget.check()
    // Read the current root and exact focused field directly. Remote automation
    // preparation is not a focus or recipient check.
    let request = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    request.acquisitionBudget = budget
    let handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
    defer { handle.close() }
    try budget.check()
    try FBAXPointReadRules.frontmost(handle.acquisitionPID, expectedPID: expectedPID)
    let field = try handle.focusedTextField(identifier: identifier, expectedPID: expectedPID, budget: budget)
    handle.close()
    try provider.validateCurrentRevision(expected: observation)
    let afterPID = try await pointReadFrontmostPID(commands, observation: observation, budget: budget)
    try FBAXPointReadRules.frontmost(afterPID, expectedPID: expectedPID)
    try provider.validateCurrentRevision(expected: observation)
    try budget.check()
    try Task.checkCancellation()
    return field
  }
}

extension FBSimulatorAXSnapshot {
  public static func acquire(for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation, freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    policy: FBSimulatorAXAcquisitionPolicy, includeNativeIdentity: Bool) async throws -> FBSimulatorAXAcquisition {
    if !includeNativeIdentity { return try await acquire(for: simulator, expectedPID: expectedPID,
      observation: observation, freshnessProvider: freshnessProvider, policy: policy) }
    guard expectedPID > 0 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    let budget = FBAXAcquisitionBudget(seconds: policy.timeoutSeconds)
    return await withTaskCancellationHandler(operation: {
      await FBSimulatorAXWorker.shared.acquireBound(for: simulator, expectedPID: expectedPID,
        observation: observation, provider: freshnessProvider, policy: policy, budget: budget, includeNativeIdentity: true)
    }, onCancel: { budget.stop(.cancelled) })
  }

  public static func acquireFrontmost(for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider, policy: FBSimulatorAXAcquisitionPolicy,
    includeNativeIdentity: Bool) async throws -> FBSimulatorAXAcquisition {
    if !includeNativeIdentity { return try await acquireFrontmost(for: simulator, observation: observation,
      freshnessProvider: freshnessProvider, policy: policy) }
    let budget = FBAXAcquisitionBudget(seconds: policy.timeoutSeconds)
    return await withTaskCancellationHandler(operation: {
      await FBSimulatorAXWorker.shared.acquireBound(for: simulator, expectedPID: nil,
        observation: observation, provider: freshnessProvider, policy: policy, budget: budget, includeNativeIdentity: true)
    }, onCancel: { budget.stop(.cancelled) })
  }

  public static func acquire(at point: CGPoint, for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation, freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    policy: FBSimulatorAXAcquisitionPolicy, includeNativeIdentity: Bool) async throws -> FBSimulatorAXAcquisition {
    if !includeNativeIdentity { return try await acquire(at: point, for: simulator, expectedPID: expectedPID,
      observation: observation, freshnessProvider: freshnessProvider, policy: policy) }
    guard expectedPID > 0 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    _ = try FBAXPointReadRules.nativePoint(point, observation: observation)
    let reservation = try FBAXTargetReservation.acquire()
    defer { withExtendedLifetime(reservation) {} }
    let budget = FBAXAcquisitionBudget(seconds: policy.timeoutSeconds)
    return await withTaskCancellationHandler(operation: {
      await FBSimulatorAXWorker.shared.acquirePoint(point, for: simulator, expectedPID: expectedPID,
        observation: observation, provider: freshnessProvider, budget: budget, includeNativeIdentity: true)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

extension FBSimulatorAXSnapshot {
  public static func readFocusedTextField(for simulator: FBSimulator, expectedPID: Int32,
    identity: FBSimulatorAXNativeIdentity, observation: FBSimulatorHIDSessionObservation,
    liveFreshnessProvider: any FBSimulatorHIDLiveFreshnessProvider,
    timeoutSeconds: Double) async throws -> FBSimulatorAXNode {
    try identity.validate()
    guard identity.pid == expectedPID, timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 8 else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let budget = FBAXAcquisitionBudget(seconds: timeoutSeconds)
    return try await withTaskCancellationHandler(operation: {
      try await FBSimulatorAXWorker.shared.readFocusedTextField(for: simulator,
        expectedPID: expectedPID, identity: identity, observation: observation,
        provider: liveFreshnessProvider, budget: budget)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

extension FBSimulatorAXWorker {
  func readFocusedTextField(for simulator: FBSimulator, expectedPID: Int32,
    identity: FBSimulatorAXNativeIdentity, observation: FBSimulatorHIDSessionObservation,
    provider: any FBSimulatorHIDLiveFreshnessProvider, budget: FBAXAcquisitionBudget) async throws -> FBSimulatorAXNode {
    try budget.check(); try Task.checkCancellation()
    try identity.validate()
    guard simulator.udid == observation.simulatorUDID, identity.pid == expectedPID else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    try provider.validateCurrentRevision(expected: observation)
    let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
    try commands.validateAccessibility(bootstrap: false)
    try budget.check()
    let request = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    request.acquisitionBudget = budget
    let handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
    defer { handle.close() }
    try budget.check()
    try FBAXPointReadRules.frontmost(handle.acquisitionPID, expectedPID: expectedPID)
    let field = try handle.focusedTextField(identity: identity, expectedPID: expectedPID,
      logicalSize: observation.displayContext.logicalSize, budget: budget)
    handle.close()
    try provider.validateCurrentRevision(expected: observation)
    let afterPID = try await pointReadFrontmostPID(commands, observation: observation, budget: budget)
    try FBAXPointReadRules.frontmost(afterPID, expectedPID: expectedPID)
    try provider.validateCurrentRevision(expected: observation)
    try budget.check(); try Task.checkCancellation()
    return field
  }
}

extension FBSimulatorAXWorker {
  func acquire(for simulator: FBSimulator, expectedPID: Int32, observation: FBSimulatorHIDSessionObservation,
    provider: any FBSimulatorHIDFreshnessProvider, policy: FBSimulatorAXAcquisitionPolicy,
    budget: FBAXAcquisitionBudget, includeNativeIdentity: Bool) async -> FBSimulatorAXAcquisition {
    await acquireBound(for: simulator, expectedPID: expectedPID, observation: observation,
      provider: provider, policy: policy, budget: budget, includeNativeIdentity: includeNativeIdentity)
  }
}

extension FBSimulatorAXSnapshot {
  /// One bounded read of the frontmost application's PID on the observed display, without
  /// serializing its tree. A caller that has no expected PID binds this one; every later target
  /// and frontmost check still requires it, so a process change fails rather than retargets.
  public static func frontmostApplicationPID(for simulator: FBSimulator,
    observation: FBSimulatorHIDSessionObservation, freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    timeoutSeconds: Double = 4) async throws -> Int32 {
    guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 8 else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let budget = FBAXAcquisitionBudget(seconds: timeoutSeconds)
    return try await withTaskCancellationHandler(operation: {
      try await FBSimulatorAXWorker.shared.frontmostApplicationPID(for: simulator, observation: observation,
        provider: freshnessProvider, budget: budget)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

extension FBSimulatorAXWorker {
  func frontmostApplicationPID(for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    provider: any FBSimulatorHIDFreshnessProvider, budget: FBAXAcquisitionBudget) async throws -> Int32 {
    try Task.checkCancellation()
    try budget.check()
    try await validateSelection(simulator, observation: observation, provider: provider)
    let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
    try commands.validateAccessibility(bootstrap: false)
    try budget.check()
    let pid: Int32
    do {
      pid = try await pointReadFrontmostPID(commands, observation: observation, budget: budget)
    } catch let error where Self.pointReadMayNeedPreparation(error) {
      // Same rule as the point read: preparation runs only after a direct read fails.
      try FBSimulatorAXSnapshot.requireSame(observation, try await provider.observation())
      try prepareAccessibility(for: simulator, budget: budget)
      pid = try await pointReadFrontmostPID(commands, observation: observation, budget: budget)
    }
    guard pid > 0 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    try FBSimulatorAXSnapshot.requireSame(observation, try await provider.observation())
    try budget.check()
    try Task.checkCancellation()
    return pid
  }
}
