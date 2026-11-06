import Foundation

public struct FBSimulatorSliderSample: Codable, Sendable {
  public let phase: String
  public let elapsedSeconds: Double
  public let capabilities: FBSimulatorSliderCapabilities
}
public struct FBSimulatorSliderPhaseEvent: Codable, Sendable {
  public let phase: String
  public let uptime: Double
}
public struct FBSimulatorSliderEndpointReceipt: Codable, Sendable {
  public let outcome: String
  public let reason: String?
  public let delivery: String
  public let endpoint: FBSimulatorSliderEndpoint
  public let actionAttempts: Int
  public let actionsReturned: Int
  public let startedUptime: Double
  public let deadlineUptime: Double
  public let elapsedSeconds: Double
  public let samples: [FBSimulatorSliderSample]
  public let actionReceipts: [FBSimulatorSliderActionReceipt]
  public let phaseEvents: [FBSimulatorSliderPhaseEvent]
  public let physicalGeometry: String
}
/// Semantic AX endpoint control only. No HID, setter, replay or thumb inference.
public actor FBSimulatorSliderEndpointController {
  private var running = false
  public init() {}
  static func check(_ deadline: Double) throws {
    if Task.isCancelled { throw FBSimulatorSliderError.cancelled }
    guard deadline.isFinite, ProcessInfo.processInfo.systemUptime < deadline else {
      throw FBSimulatorSliderError.deadline
    }
  }
  public func run(endpoint: FBSimulatorSliderEndpoint,
    backend: any FBSimulatorSliderEndpointBackend, budgetSeconds: Double = 15, maximumActions: Int = 20,
    observer: (@Sendable (FBSimulatorSliderSample) async throws -> Void)? = nil
  ) async -> FBSimulatorSliderEndpointReceipt {
    let start = ProcessInfo.processInfo.systemUptime
    let deadline = start + budgetSeconds
    let operationID = UUID()
    var outcome = "failed"
    var reason: String?
    var delivery = "notDispatched"
    var attempts = 0
    var returned = 0
    var awaitingReadback = false
    var samples: [FBSimulatorSliderSample] = []
    var actions: [FBSimulatorSliderActionReceipt] = []
    var phases = [FBSimulatorSliderPhaseEvent(phase: "budget-start", uptime: start)]
    func phase(_ value: String) { phases.append(FBSimulatorSliderPhaseEvent(phase: value, uptime: ProcessInfo.processInfo.systemUptime)) }
    func receipt(_ outcome: String, _ reason: String? = nil, delivery: String) -> FBSimulatorSliderEndpointReceipt {
      FBSimulatorSliderEndpointReceipt(outcome: outcome, reason: reason, delivery: delivery, endpoint: endpoint,
        actionAttempts: attempts, actionsReturned: returned, startedUptime: start, deadlineUptime: deadline,
        elapsedSeconds: ProcessInfo.processInfo.systemUptime - start, samples: samples, actionReceipts: actions, phaseEvents: phases, physicalGeometry: "unknown")
    }
    guard !running else { return receipt("failed", "busy", delivery: "notDispatched") }
    running = true
    defer { running = false }
    do {
      guard budgetSeconds.isFinite, budgetSeconds > 0, budgetSeconds <= 15,
            maximumActions > 0, maximumActions <= 20 else { throw FBSimulatorSliderError.invalidDomain }
      try Self.check(deadline)
      phase("setup-start")
      try await backend.prepare(operationID: operationID, deadline: deadline)
      try Self.check(deadline)
      phase("setup-returned")
      phase("initial-read-start")
      var current = try await backend.read(deadline: deadline)
      phase("initial-read-returned")
      let initial = current
      let domain = try current.requireDomain()
      let target = endpoint == .minimum ? domain.minimum : domain.maximum
      let direction: FBSimulatorSliderAction = endpoint == .minimum ? .decrement : .increment
      var value = try current.requireValue()
      let already = abs(value - target) <= domain.tolerance
      func record(_ name: String, _ capability: FBSimulatorSliderCapabilities) async throws {
        let sample = FBSimulatorSliderSample(phase: name, elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
          capabilities: capability)
        samples.append(sample)
        phase(name + "-observer-start")
        try await observer?(sample)
        phase(name + "-observer-returned")
        try Self.check(deadline)
      }
      try await record("initial", current)
      while abs(value - target) > domain.tolerance {
        guard attempts < maximumActions else { throw FBSimulatorSliderError.actionLimit }
        guard current.raw.declaredActions.contains(direction.declaredName) else { throw FBSimulatorSliderError.unsupportedAction }
        try Self.check(deadline)
        attempts += 1
        awaitingReadback = true
        phase("action-\(attempts)-start")
        do { actions.append(try await backend.step(direction, expected: current, deadline: deadline)) }
        catch let error as FBSimulatorSliderError {
          if case .deliveryUncertain = error { throw error }
          // Backend contract: other typed errors are before native dispatch.
          awaitingReadback = false
          throw error
        }
        returned += 1
        phase("action-\(attempts)-returned")
        try Self.check(deadline)
        phase("action-\(attempts)-read-start")
        let next = try await backend.readFeedback(deadline: deadline)
        phase("action-\(attempts)-read-returned")
        try next.requireSameTarget(as: initial, includeValue: false)
        let nextValue = try next.requireValue()
        awaitingReadback = false
        try await record("after-action-\(returned)", next)
        guard nextValue != value else { throw FBSimulatorSliderError.noProgress }
        let progress = direction == .increment ? nextValue - value : value - nextValue
        guard progress > 0 else { throw FBSimulatorSliderError.wrongDirection }
        current = next; value = nextValue
      }
      // Both final observations share the original operation budget.
      let reachedAt = ProcessInfo.processInfo.systemUptime
      for delay in [0.6, 5.0] {
        try Self.check(deadline)
        let wait = max(0, reachedAt + delay - ProcessInfo.processInfo.systemUptime)
        guard reachedAt + delay < deadline else { throw FBSimulatorSliderError.deadline }
        phase("settled-\(delay)-wait-start")
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        phase("settled-\(delay)-read-start")
        // Input already has a coherent readback. Final checks do not dispatch input.
        let settled = try await backend.readFinal(deadline: deadline)
        phase("settled-\(delay)-read-returned")
        try settled.requireSameTarget(as: initial, includeValue: false)
        guard abs(try settled.requireValue() - target) <= domain.tolerance else { throw FBSimulatorSliderError.noProgress }
        awaitingReadback = false
        try await record("settled-\(delay)", settled)
      }
      try Self.check(deadline)
      phase("complete")
      outcome = already ? "alreadyAtEndpoint" : "endpointObserved"
      delivery = returned == 0 ? "notDispatched" : "valueObserved"
    } catch {
      phase("failed: " + String(describing: error))
      let uncertain: Bool
      if case FBSimulatorSliderError.deliveryUncertain = error { uncertain = true }
      else { uncertain = awaitingReadback }
      reason = String(describing: error)
      delivery = uncertain ? "uncertain" : returned == 0 ? "notDispatched" : "valueObserved"
    }
    phase("cleanup-start")
    await backend.finish(operationID: operationID)
    phase("cleanup-returned")
    phases.append(contentsOf: await backend.diagnosticPhases(operationID: operationID))
    phases.sort { $0.uptime < $1.uptime }
    if outcome != "failed" {
      do { try Self.check(deadline) }
      catch { outcome = "failed"; reason = String(describing: error) }
    }
    return receipt(outcome, reason, delivery: delivery)
  }
}
