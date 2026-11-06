import AppKit
import Foundation

public enum FBSimulatorSliderError: Error, Sendable {
  case invalidDomain, unsupportedValueDomain, invalidSelection, staleContext, busy
  case unsupportedAction, noProgress, wrongDirection, actionLimit, deadline, cancelled
  case beforeDispatchFailure(String), deliveryUncertain(String)
  case inconsistentReadValue
}
public enum FBSimulatorSliderEndpoint: String, Codable, Sendable { case minimum, maximum }
public enum FBSimulatorSliderAction: String, Codable, Sendable {
  case increment, decrement
  public var declaredName: String {
    self == .increment ? NSAccessibility.Action.increment.rawValue : NSAccessibility.Action.decrement.rawValue
  }
}
public struct FBSimulatorSliderDomain: Codable, Sendable, Equatable {
  public let minimum: Double
  public let maximum: Double
  public init(minimum: Double, maximum: Double) throws {
    guard minimum.isFinite, maximum.isFinite, minimum < maximum,
          (maximum - minimum).isFinite else { throw FBSimulatorSliderError.invalidDomain }
    self.minimum = minimum; self.maximum = maximum
  }
  private enum CodingKeys: String, CodingKey { case minimum, maximum }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(minimum: values.decode(Double.self, forKey: .minimum),
      maximum: values.decode(Double.self, forKey: .maximum))
  }
  public func nativeValue(percent: Double) throws -> Double {
    guard percent.isFinite, (0...100).contains(percent) else { throw FBSimulatorSliderError.invalidDomain }
    return minimum + (maximum - minimum) * (percent / 100)
  }
  public func percent(nativeValue: Double) throws -> Double {
    guard contains(nativeValue) else { throw FBSimulatorSliderError.invalidDomain }
    return (nativeValue - minimum) / (maximum - minimum) * 100
  }
  public func contains(_ value: Double) -> Bool { value.isFinite && value >= minimum && value <= maximum }
  public var tolerance: Double { (maximum - minimum) * 0.0007 }
}
public enum FBSimulatorSliderAttributeState: String, Codable, Sendable {
  case value, null, notAdvertised, unsupportedCollection, unsupportedValue
  case unavailable = "nil"
}
public struct FBSimulatorSliderAttribute: Codable, Sendable {
  public let state: FBSimulatorSliderAttributeState
  public let value: FBSimulatorAXValue?
  public let objectType: String?
}
public struct FBSimulatorSliderAttributes: Codable, Sendable {
  public let advertisedAttributes: [String]
  public let declaredActions: [String]
  public let attributes: [String: FBSimulatorSliderAttribute]
  public func number(_ key: NSAccessibility.Attribute) -> Double? {
    guard let attribute = attributes[key.rawValue], attribute.state == .value,
          case .number(let value) = attribute.value, value.isFinite else { return nil }
    return value
  }
}
public struct FBSimulatorSliderCapabilities: Codable, Sendable {
  public let snapshotID: UUID
  public let observation: FBSimulatorContextObservation
  public let node: FBSimulatorAXNode
  public let raw: FBSimulatorSliderAttributes
  public let geometryStatus: String
  public func requireDomain() throws -> FBSimulatorSliderDomain {
    guard let minimum = raw.number(.minValue), let maximum = raw.number(.maxValue),
          let value = raw.number(.value) else { throw FBSimulatorSliderError.unsupportedValueDomain }
    let domain = try FBSimulatorSliderDomain(minimum: minimum, maximum: maximum)
    guard domain.contains(value), node.value == .number(value) else { throw FBSimulatorSliderError.invalidDomain }
    return domain
  }
  /// A read-only physical sample can wait for value coherence only after target and domain admission.
  /// Missing, invalid or changed target data still fails immediately.
  func requirePhysicalFeedbackTarget(as expected: Self) throws {
    guard try observation.sessionObservation() == expected.observation.sessionObservation(),
          node.identifier == expected.node.identifier, node.type == "Slider", node.pid == expected.node.pid,
          node.frame == expected.node.frame else { throw FBSimulatorSliderError.staleContext }
    guard node.enabled == true, node.hidden == false else { throw FBSimulatorSliderError.invalidSelection }
    guard let minimum = raw.number(.minValue), let maximum = raw.number(.maxValue),
          let value = raw.number(.value) else { throw FBSimulatorSliderError.unsupportedValueDomain }
    let domain = try FBSimulatorSliderDomain(minimum: minimum, maximum: maximum)
    guard domain == (try expected.requireDomain()) else { throw FBSimulatorSliderError.staleContext }
    guard domain.contains(value), case .number(let nodeValue) = node.value,
          domain.contains(nodeValue) else { throw FBSimulatorSliderError.invalidDomain }
    guard nodeValue == value else { throw FBSimulatorSliderError.inconsistentReadValue }
  }

  public func requireValue() throws -> Double {
    _ = try requireDomain()
    guard let value = raw.number(.value) else { throw FBSimulatorSliderError.unsupportedValueDomain }
    return value
  }
  public func requireSameTarget(as expected: Self, includeValue: Bool) throws {
    guard try observation.sessionObservation() == expected.observation.sessionObservation(),
          node.identifier == expected.node.identifier, node.type == "Slider", node.pid == expected.node.pid,
          node.frame == expected.node.frame, try requireDomain() == expected.requireDomain() else {
      throw FBSimulatorSliderError.staleContext
    }
    if includeValue, try requireValue() != expected.requireValue() { throw FBSimulatorSliderError.staleContext }
  }
}
public struct FBSimulatorSliderActionReceipt: Codable, Sendable {
  public let action: FBSimulatorSliderAction
  public let verifiedBeforeAction: FBSimulatorSliderCapabilities
  public let callStartedUptime: Double
  public let callReturnedUptime: Double
  public let guestAcknowledged: Bool
}

/// Optional reference admission. Runs synchronously while the AX worker owns the native handle.
/// Existing selector callers omit it. A guard must not perform input or escape platform handles.
public protocol FBSimulatorSliderAdmissionGuard: Sendable {
  func validateScreen(_ roots: [FBSimulatorAXNode], observation: FBSimulatorHIDSessionObservation,
    allowingValueChange: Bool) throws
  func validateTarget(_ capabilities: FBSimulatorSliderCapabilities, allowingValueChange: Bool) throws
}

public protocol FBSimulatorSliderEndpointBackend: Sendable {
  func prepare(operationID: UUID, deadline: Double) async throws
  func finish(operationID: UUID) async
  func readFinal(deadline: Double) async throws -> FBSimulatorSliderCapabilities
  func diagnosticPhases(operationID: UUID) async -> [FBSimulatorSliderPhaseEvent]
  func read(deadline: Double) async throws -> FBSimulatorSliderCapabilities
  func readFeedback(deadline: Double) async throws -> FBSimulatorSliderCapabilities
  func step(_ action: FBSimulatorSliderAction, expected: FBSimulatorSliderCapabilities, deadline: Double) async throws -> FBSimulatorSliderActionReceipt
}
public extension FBSimulatorSliderEndpointBackend {
  func prepare(operationID: UUID, deadline: Double) async throws {
    try FBSimulatorSliderEndpointController.check(deadline)
  }
  func finish(operationID: UUID) async {}
  func diagnosticPhases(operationID: UUID) async -> [FBSimulatorSliderPhaseEvent] { [] }
  func readFinal(deadline: Double) async throws -> FBSimulatorSliderCapabilities {
    try await read(deadline: deadline)
  }
  func readFeedback(deadline: Double) async throws -> FBSimulatorSliderCapabilities {
    try await read(deadline: deadline)
  }
}

enum FBSimulatorSliderSelection: Sendable {
  case identifier(String)
  case label(String)

  var text: String {
    switch self { case .identifier(let value), .label(let value): return value }
  }

  func matches(_ node: FBSimulatorAXNode) -> Bool {
    switch self {
    case .identifier(let value): return node.identifier == value
    case .label(let value): return FBSimulatorAXSelector.label(value).matches(node)
    }
  }

  func matchesType(_ node: FBSimulatorAXNode, elementType: String) -> Bool {
    switch self {
    case .identifier(let value): return FBSimulatorAXSelector.identifierWithType(value, elementType: elementType).matches(node)
    case .label(let value): return FBSimulatorAXSelector.labelWithType(value, elementType: elementType).matches(node)
    }
  }
}

/// Selector uniqueness is checked before the optional type filter.
/// Used for both the tree read and the owned-handle read before dispatch.
enum FBSimulatorSliderTargetSelection {
  static func resolve(roots: [FBSimulatorAXNode], identifier: String, expectedPID: Int32,
    elementType: String?) throws -> FBSimulatorAXNode {
    try resolve(roots: roots, selection: .identifier(identifier), expectedPID: expectedPID, elementType: elementType)
  }

  static func resolve(roots: [FBSimulatorAXNode], selection: FBSimulatorSliderSelection, expectedPID: Int32,
    elementType: String?) throws -> FBSimulatorAXNode {
    let matches = roots.flatMap(\.flattened).filter { selection.matches($0) }
    guard matches.count == 1, let node = matches.first else { throw FBSimulatorSliderError.invalidSelection }
    try validate(node, selection: selection, expectedPID: expectedPID, elementType: elementType)
    return node
  }

  /// Nested serialization of an owned handle has exactly one actual handle root.
  /// Descendants cannot supply identity for capabilities or dispatch on that root.
  static func ownedRoot(roots: [FBSimulatorAXNode], selection: FBSimulatorSliderSelection, expectedPID: Int32,
    elementType: String?) throws -> FBSimulatorAXNode {
    guard roots.count == 1, let root = roots.first else { throw FBSimulatorSliderError.invalidSelection }
    try validate(root, selection: selection, expectedPID: expectedPID, elementType: elementType)
    // Retain the prior duplicate-selector rejection within the owned subtree.
    guard roots.flatMap(\.flattened).filter({ selection.matches($0) }).count == 1 else {
      throw FBSimulatorSliderError.invalidSelection
    }
    return root
  }

  private static func validate(_ node: FBSimulatorAXNode, selection: FBSimulatorSliderSelection,
    expectedPID: Int32, elementType: String?) throws {
    guard selection.matches(node), node.type == "Slider", node.pid == expectedPID,
          let frame = node.frame,
          [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite),
          frame.size.width > 0, frame.size.height > 0 else { throw FBSimulatorSliderError.invalidSelection }
    if let elementType {
      guard selection.matchesType(node, elementType: elementType) else { throw FBSimulatorSliderError.invalidSelection }
    }
  }
}

/// One immutable selected simulator target. No AX platform handle leaves its worker.
public actor FBSimulatorSliderBackend: FBSimulatorSliderEndpointBackend {
  private let simulator: FBSimulator
  private let observation: FBSimulatorHIDSessionObservation
  private let provider: any FBSimulatorHIDFreshnessProvider
  private let selection: FBSimulatorSliderSelection
  private let elementType: String?
  private let pid: Int32
  private let admissionGuard: (any FBSimulatorSliderAdmissionGuard)?
  private var adjustmentReturned = false
  private var physicalValueFeedback = false
  private var operationID: UUID?
  private var live: FBSimulatorHIDNativeFreshnessProvider?
  private var phases: [FBSimulatorSliderPhaseEvent] = []
  private func phase(_ name: String) {
    phases.append(FBSimulatorSliderPhaseEvent(phase: name, uptime: ProcessInfo.processInfo.systemUptime))
  }
  private var diagnosticOperationID: UUID?
  public func diagnosticPhases(operationID: UUID) -> [FBSimulatorSliderPhaseEvent] {
    diagnosticOperationID == operationID ? phases : []
  }

  public init(simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider, identifier: String, expectedPID: Int32,
    admissionGuard: (any FBSimulatorSliderAdmissionGuard)? = nil) {
    self.simulator = simulator; self.observation = observation; self.provider = freshnessProvider
    self.selection = .identifier(identifier); self.pid = expectedPID
    self.elementType = nil
    self.admissionGuard = admissionGuard
  }

  public init(simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider, identifier: String, expectedPID: Int32,
    elementType: String?,
    admissionGuard: (any FBSimulatorSliderAdmissionGuard)? = nil) {
    self.simulator = simulator; self.observation = observation; self.provider = freshnessProvider
    self.selection = .identifier(identifier); self.pid = expectedPID
    self.elementType = elementType
    self.admissionGuard = admissionGuard
  }
  public init(simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider, label: String, expectedPID: Int32,
    elementType: String? = nil,
    admissionGuard: (any FBSimulatorSliderAdmissionGuard)? = nil) {
    self.simulator = simulator; self.observation = observation; self.provider = freshnessProvider
    self.selection = .label(label); self.pid = expectedPID
    self.elementType = elementType
    self.admissionGuard = admissionGuard
  }

  public func prepare(operationID: UUID, deadline: Double) async throws {
    guard self.operationID == nil else { throw FBSimulatorSliderError.busy }
    self.operationID = operationID
    adjustmentReturned = false
    physicalValueFeedback = false
    phases = []
    diagnosticOperationID = operationID
    phase("backend-ownership-start")
    do {
      try FBSimulatorSliderEndpointController.check(deadline)
      try await FBSimulatorAXWorker.shared.claimSliderLease(for: simulator, token: operationID)
      try FBSimulatorSliderEndpointController.check(deadline)
      phase("backend-feed-start")
      let feed = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator, authoritativeProvider: provider)
      live = feed
      phase("backend-feed-returned")
      guard feed.initialObservation == observation else { throw FBSimulatorSliderError.staleContext }
      try feed.validateCurrentRevision(expected: observation)
      try FBSimulatorSliderEndpointController.check(deadline)
      phase("backend-ax-admission-start")
      try await FBSimulatorAXWorker.shared.prepareSliderLease(for: simulator, token: operationID,
        deadline: deadline)
      phase("backend-ax-admission-returned")
      try feed.validateCurrentRevision(expected: observation)
      try FBSimulatorSliderEndpointController.check(deadline)
    } catch {
      await finish(operationID: operationID)
      throw error
    }
  }

  public func finish(operationID: UUID) async {
    guard self.operationID == operationID else { return }
    phase("backend-feed-close-start")
    await live?.closeAndWait()
    phase("backend-feed-close-returned")
    live = nil
    await FBSimulatorAXWorker.shared.closeSliderLease(for: simulator, token: operationID)
    self.operationID = nil
    physicalValueFeedback = false
  }

  private func boundFeed(deadline: Double) throws -> (UUID, FBSimulatorHIDNativeFreshnessProvider) {
    try FBSimulatorSliderEndpointController.check(deadline)
    guard let operationID, let live else { throw FBSimulatorSliderError.invalidSelection }
    try live.validateCurrentRevision(expected: observation)
    return (operationID, live)
  }

  public func read(deadline: Double) async throws -> FBSimulatorSliderCapabilities {
    let (token, feed) = try boundFeed(deadline: deadline)
    phase("backend-target-read-start")
    let result = try await FBSimulatorAXWorker.shared.sliderOperation(for: simulator, observation: observation,
      feed: feed, token: token, selection: selection, expectedPID: pid, elementType: elementType,
      deadline: deadline, action: nil, expected: nil, admissionGuard: admissionGuard,
      allowingValueChange: adjustmentReturned || physicalValueFeedback)
    phase("backend-target-read-returned")
    return result
  }

  /// A full current-screen admission inside the physical owner's fixed settle window.
  /// This does not perform input or accept a partially read value.
  public func readPhysicalAdmission(expected: FBSimulatorSliderCapabilities,
    deadline: Double) async throws -> FBSimulatorSliderCapabilities {
    guard physicalValueFeedback, !adjustmentReturned else { throw FBSimulatorSliderError.invalidSelection }
    let (token, feed) = try boundFeed(deadline: deadline)
    phase("backend-physical-admission-start")
    let value = try await FBSimulatorAXWorker.shared.sliderOperation(for: simulator, observation: observation,
      feed: feed, token: token, selection: selection, expectedPID: pid, elementType: elementType,
      deadline: deadline, action: nil, expected: nil, admissionGuard: admissionGuard,
      allowingValueChange: true, physicalAdmission: expected)
    guard operationID == token else { throw FBSimulatorSliderError.invalidSelection }
    try FBSimulatorSliderEndpointController.check(deadline)
    try feed.validateCurrentRevision(expected: observation)
    phase("backend-physical-admission-returned")
    return value
  }

  /// Read-only feedback after this operation changed the selected Slider.
  /// Full screen admission remains required before every further input path.
  public func readFeedback(deadline: Double) async throws -> FBSimulatorSliderCapabilities {
    guard adjustmentReturned || physicalValueFeedback else { throw FBSimulatorSliderError.invalidSelection }
    let (token, feed) = try boundFeed(deadline: deadline)
    phase("backend-feedback-read-start")
    let value = try await FBSimulatorAXWorker.shared.sliderFeedback(for: simulator, observation: observation,
      feed: feed, token: token, selection: selection, expectedPID: pid, elementType: elementType,
      deadline: deadline, admissionGuard: admissionGuard, physicalValueFeedback: physicalValueFeedback)
    guard operationID == token else { throw FBSimulatorSliderError.invalidSelection }
    try FBSimulatorSliderEndpointController.check(deadline)
    try feed.validateCurrentRevision(expected: observation)
    phase("backend-feedback-read-returned")
    return value
  }

  public func readFinal(deadline: Double) async throws -> FBSimulatorSliderCapabilities {
    let (_, feed) = try boundFeed(deadline: deadline)
    phase("backend-final-context-start")
    guard try await feed.observation() == observation else { throw FBSimulatorSliderError.staleContext }
    phase("backend-final-context-returned")
    return try await read(deadline: deadline)
  }

  /// Admit value changes caused by one real guarded pickup owned by this operation.
  /// Endpoint adjustments cannot enter this phase, and this phase cannot perform endpoint steps.
  public func beginPhysicalValueFeedback(operationID: UUID,
    session: FBSimulatorHIDSession, beginReceipt: FBSimulatorHIDSessionReceipt,
    deadline: Double) async throws {
    guard self.operationID == operationID, !adjustmentReturned, !physicalValueFeedback else {
      throw FBSimulatorSliderError.invalidSelection
    }
    let (_, feed) = try boundFeed(deadline: deadline)
    try await session.validateSliderValuePickup(beginReceipt, expected: observation)
    try FBSimulatorSliderEndpointController.check(deadline)
    try feed.validateCurrentRevision(expected: observation)
    physicalValueFeedback = true
    phase("physical-owned-value-feedback-start")
  }

  public func step(_ action: FBSimulatorSliderAction, expected: FBSimulatorSliderCapabilities, deadline: Double) async throws -> FBSimulatorSliderActionReceipt {
    guard !physicalValueFeedback else { throw FBSimulatorSliderError.unsupportedAction }
    let started = ProcessInfo.processInfo.systemUptime
    do {
      let (token, feed) = try boundFeed(deadline: deadline)
      // Full active-panel, boot, catalog, guest rotation and pose admission before every action.
      phase("backend-action-context-start")
      guard try await feed.observation() == observation else { throw FBSimulatorSliderError.staleContext }
      phase("backend-action-context-returned")
      try FBSimulatorSliderEndpointController.check(deadline)
      phase("backend-action-target-and-dispatch-start")
      let verified = try await FBSimulatorAXWorker.shared.sliderOperation(for: simulator, observation: observation,
        feed: feed, token: token, selection: selection, expectedPID: pid, elementType: elementType,
        deadline: deadline, action: action, expected: expected, admissionGuard: admissionGuard,
        allowingValueChange: adjustmentReturned || physicalValueFeedback)
      adjustmentReturned = true
      phase("backend-action-target-and-dispatch-returned")
      return FBSimulatorSliderActionReceipt(action: action, verifiedBeforeAction: verified, callStartedUptime: started,
        callReturnedUptime: ProcessInfo.processInfo.systemUptime, guestAcknowledged: false)
    } catch let error as FBSimulatorSliderError { throw error }
    catch { throw FBSimulatorSliderError.beforeDispatchFailure(String(describing: error)) }
  }
}

/// One reservation table, owned by the AX worker. No cross-process exclusion is implied.
struct FBSimulatorSliderLeaseTable<Value> {
  private struct Entry {
    let token: UUID
    var value: Value
  }
  private var entries: [String: Entry] = [:]
  mutating func claim(device: String, token: UUID, value: Value) throws {
    guard entries[device] == nil else { throw FBSimulatorSliderError.busy }
    entries[device] = Entry(token: token, value: value)
  }
  func value(device: String, token: UUID) throws -> Value {
    guard let entry = entries[device], entry.token == token else {
      throw FBSimulatorSliderError.invalidSelection
    }
    return entry.value
  }
  mutating func update(device: String, token: UUID, value: Value) throws {
    _ = try self.value(device: device, token: token)
    entries[device] = Entry(token: token, value: value)
  }
  mutating func release(device: String, token: UUID) -> Value? {
    guard let entry = entries[device], entry.token == token else { return nil }
    entries.removeValue(forKey: device)
    return entry.value
  }
}

/// Only the AX worker can use or close this request-owning handle.
struct FBSimulatorSliderOwnedSelection {
  let id = UUID()
  let element: FBAccessibilityElement
  let baseline: FBSimulatorSliderCapabilities
}

struct FBSimulatorSliderAcquisitionLease {
  let commands: FBSimulatorAccessibilityCommands
  var prepared: Bool
  var readRevision = UUID()
  var selected: FBSimulatorSliderOwnedSelection?
}

extension FBSimulatorAXWorker {
  func claimSliderLease(for simulator: FBSimulator, token: UUID) throws {
    try sliderLeases.claim(device: simulator.udid, token: token,
      value: FBSimulatorSliderAcquisitionLease(commands: FBSimulatorAccessibilityCommands(simulator: simulator),
        prepared: false))
  }
  func prepareSliderLease(for simulator: FBSimulator, token: UUID, deadline: Double) throws {
    try FBSimulatorSliderEndpointController.check(deadline)
    var lease = try sliderLeases.value(device: simulator.udid, token: token)
    try FBSimulatorSliderEndpointController.check(deadline)
    lease.prepared = true
    try sliderLeases.update(device: simulator.udid, token: token, value: lease)
  }
  func closeSliderLease(for simulator: FBSimulator, token: UUID) {
    sliderLeases.release(device: simulator.udid, token: token)?.selected?.element.close()
  }
  func sliderLease(for simulator: FBSimulator, token: UUID) throws -> FBSimulatorSliderAcquisitionLease {
    let lease = try sliderLeases.value(device: simulator.udid, token: token)
    guard lease.prepared else { throw FBSimulatorSliderError.invalidSelection }
    return lease
  }

  private func retainSliderSelection(_ element: FBAccessibilityElement,
    baseline: FBSimulatorSliderCapabilities, for simulator: FBSimulator, token: UUID, revision: UUID) throws {
    var lease = try sliderLease(for: simulator, token: token)
    guard lease.readRevision == revision, lease.selected == nil else {
      throw FBSimulatorSliderError.invalidSelection
    }
    lease.selected = FBSimulatorSliderOwnedSelection(element: element, baseline: baseline)
    try sliderLeases.update(device: simulator.udid, token: token, value: lease)
  }

  private func sliderFeedbackFrontmostPID(for simulator: FBSimulator,
    observation: FBSimulatorHIDSessionObservation, feed: FBSimulatorHIDNativeFreshnessProvider,
    token: UUID, selectedID: UUID, expectedPID: Int32, deadline: Double) async throws {
    try FBSimulatorSliderEndpointController.check(deadline)
    try feed.validateCurrentRevision(expected: observation)
    let lease = try sliderLease(for: simulator, token: token)
    guard lease.selected?.id == selectedID else { throw FBSimulatorSliderError.invalidSelection }
    let budget = FBAXAcquisitionBudget(seconds: deadline - ProcessInfo.processInfo.systemUptime)
    let request = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    request.acquisitionBudget = budget
    let handle = try await withTaskCancellationHandler(operation: {
      try await lease.commands.accessibilityElementForSliderLease(request: request, worker: self)
    }, onCancel: { budget.stop(.cancelled) })
    defer { handle.close() }
    try budget.check()
    try FBSimulatorSliderEndpointController.check(deadline)
    guard try sliderLease(for: simulator, token: token).selected?.id == selectedID,
          handle.acquisitionPID == expectedPID else { throw FBSimulatorSliderError.invalidSelection }
    try feed.validateCurrentRevision(expected: observation)
  }

  /// Read fresh attributes from this operation's selected handle. This cannot admit input.
  /// Full screen and unique-selector admission still precede every later adjustment or path.
  func sliderFeedback(for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    feed: FBSimulatorHIDNativeFreshnessProvider, token: UUID, selection: FBSimulatorSliderSelection,
    expectedPID: Int32, elementType: String?, deadline: Double,
    admissionGuard: (any FBSimulatorSliderAdmissionGuard)?,
    physicalValueFeedback: Bool) async throws -> FBSimulatorSliderCapabilities {
    try FBSimulatorSliderEndpointController.check(deadline)
    try feed.validateCurrentRevision(expected: observation)
    let lease = try sliderLease(for: simulator, token: token)
    guard let selected = lease.selected, selected.element.acquisitionPID == expectedPID else {
      throw FBSimulatorSliderError.invalidSelection
    }
    try await sliderFeedbackFrontmostPID(for: simulator, observation: observation, feed: feed,
      token: token, selectedID: selected.id, expectedPID: expectedPID, deadline: deadline)
    let snapshot = try serialize(selected.element, observation: observation, remoteContentOptions: nil)
    let node = try FBSimulatorSliderTargetSelection.ownedRoot(roots: snapshot.roots,
      selection: selection, expectedPID: expectedPID, elementType: elementType)
    guard node.enabled == true, node.hidden == false else { throw FBSimulatorSliderError.invalidSelection }
    let raw = try JSONDecoder().decode(FBSimulatorSliderAttributes.self, from: selected.element.sliderCapabilityData())
    let context = FBSimulatorContextObservation(simulatorUDID: observation.simulatorUDID,
      bootIdentity: observation.bootIdentity, screenID: observation.screenID, screenUniqueID: observation.screenUniqueID,
      axDisplayID: observation.axDisplayID, nativePixelWidth: observation.displayContext.nativePixelSize.width,
      nativePixelHeight: observation.displayContext.nativePixelSize.height, scale: observation.displayContext.scale,
      rotation: observation.displayContext.rotation.rawValue, poseRevision: observation.poseRevision)
    let value = FBSimulatorSliderCapabilities(snapshotID: snapshot.snapshotID, observation: context,
      node: node, raw: raw, geometryStatus: "unknown")
    if physicalValueFeedback { try value.requirePhysicalFeedbackTarget(as: selected.baseline) }
    try admissionGuard?.validateTarget(value, allowingValueChange: true)
    try value.requireSameTarget(as: selected.baseline, includeValue: false)
    try FBSimulatorSliderEndpointController.check(deadline)
    try feed.validateCurrentRevision(expected: observation)
    try await sliderFeedbackFrontmostPID(for: simulator, observation: observation, feed: feed,
      token: token, selectedID: selected.id, expectedPID: expectedPID, deadline: deadline)
    try FBSimulatorSliderEndpointController.check(deadline)
    try feed.validateCurrentRevision(expected: observation)
    return value
  }

  func sliderOperation(for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    feed: FBSimulatorHIDNativeFreshnessProvider, token: UUID, selection: FBSimulatorSliderSelection, expectedPID: Int32,
    elementType: String?, deadline: Double, action: FBSimulatorSliderAction?, expected: FBSimulatorSliderCapabilities?,
    admissionGuard: (any FBSimulatorSliderAdmissionGuard)? = nil,
    allowingValueChange: Bool = false,
    physicalAdmission: FBSimulatorSliderCapabilities? = nil) async throws -> FBSimulatorSliderCapabilities {
    try FBSimulatorSliderEndpointController.check(deadline)
    guard !selection.text.isEmpty, expectedPID > 0,
          physicalAdmission == nil || (action == nil && allowingValueChange) else {
      throw FBSimulatorSliderError.invalidSelection
    }
    try feed.validateCurrentRevision(expected: observation)
    try FBSimulatorSliderEndpointController.check(deadline)
    let request = FBAXTranslationRequest(kind: .frontmostApplication, pointDisplayID: observation.axDisplayID,
      displayContext: observation.displayContext)
    var lease = try sliderLease(for: simulator, token: token)
    lease.selected?.element.close()
    lease.selected = nil
    let revision = UUID()
    lease.readRevision = revision
    try sliderLeases.update(device: simulator.udid, token: token, value: lease)
    let root = try await lease.commands.accessibilityElementForSliderLease(request: request, worker: self)
    defer { root.close() }
    guard try sliderLease(for: simulator, token: token).readRevision == revision else {
      throw FBSimulatorSliderError.invalidSelection
    }
    let snapshot = try serialize(root, observation: observation, remoteContentOptions: nil)
    guard !snapshot.roots.isEmpty, snapshot.roots.allSatisfy({ $0.pid == expectedPID }) else {
      throw FBSimulatorSliderError.invalidSelection
    }
    try admissionGuard?.validateScreen(snapshot.roots, observation: observation,
      allowingValueChange: allowingValueChange)
    let node = try FBSimulatorSliderTargetSelection.resolve(roots: snapshot.roots,
      selection: selection, expectedPID: expectedPID, elementType: elementType)
    let selected = try root.findSliderElement(matching: selection, depth: 64, deadline: deadline)
    var retained = false
    defer { if !retained { selected.close() } }
    switch selection {
    case .identifier(let identifier):
      guard try selected.stringValue(forSearchableKey: .uniqueID) == identifier else { throw FBSimulatorSliderError.invalidSelection }
    case .label(let label):
      guard try FBSimulatorAXSelector.matchesLabel(selected.stringValue(forSearchableKey: .label), query: label) else {
        throw FBSimulatorSliderError.invalidSelection
      }
    }
    let context = FBSimulatorContextObservation(simulatorUDID: observation.simulatorUDID,
      bootIdentity: observation.bootIdentity, screenID: observation.screenID, screenUniqueID: observation.screenUniqueID,
      axDisplayID: observation.axDisplayID, nativePixelWidth: observation.displayContext.nativePixelSize.width,
      nativePixelHeight: observation.displayContext.nativePixelSize.height, scale: observation.displayContext.scale,
      rotation: observation.displayContext.rotation.rawValue, poseRevision: observation.poseRevision)
    func capabilities(_ node: FBSimulatorAXNode) throws -> FBSimulatorSliderCapabilities {
      let raw = try JSONDecoder().decode(FBSimulatorSliderAttributes.self, from: selected.sliderCapabilityData())
      return FBSimulatorSliderCapabilities(snapshotID: snapshot.snapshotID, observation: context,
        node: node, raw: raw, geometryStatus: "unknown")
    }
    let treeValue = try capabilities(node)
    if let physicalAdmission { try treeValue.requirePhysicalFeedbackTarget(as: physicalAdmission) }
    try admissionGuard?.validateTarget(treeValue, allowingValueChange: allowingValueChange)
    // Both selectors bind every sample to the actual owned root, never a descendant.
    let currentSnapshot = try serialize(selected, observation: observation, remoteContentOptions: nil)
    let currentNode = try FBSimulatorSliderTargetSelection.ownedRoot(roots: currentSnapshot.roots,
      selection: selection, expectedPID: expectedPID, elementType: elementType)
    let value = try capabilities(currentNode)
    if let physicalAdmission { try value.requirePhysicalFeedbackTarget(as: physicalAdmission) }
    try admissionGuard?.validateTarget(value, allowingValueChange: allowingValueChange)
    if physicalAdmission != nil {
      try value.requireSameTarget(as: treeValue, includeValue: false)
      guard try value.requireValue() == treeValue.requireValue() else {
        throw FBSimulatorSliderError.inconsistentReadValue
      }
    } else {
      try value.requireSameTarget(as: treeValue, includeValue: true)
    }
    try feed.validateCurrentRevision(expected: observation)
    try FBSimulatorSliderEndpointController.check(deadline)
    guard let action else {
      try retainSliderSelection(selected, baseline: value, for: simulator, token: token, revision: revision)
      retained = true
      return value
    }
    guard let expected else { throw FBSimulatorSliderError.invalidSelection }
    try value.requireSameTarget(as: expected, includeValue: true)
    // Re-read the owned selected handle immediately before dispatch.
    let finalSnapshot = try serialize(selected, observation: observation, remoteContentOptions: nil)
    let finalNode = try FBSimulatorSliderTargetSelection.ownedRoot(roots: finalSnapshot.roots,
      selection: selection, expectedPID: expectedPID, elementType: elementType)
    let final = try capabilities(finalNode)
    try final.requireSameTarget(as: expected, includeValue: true)
    guard final.raw.declaredActions.contains(action.declaredName) else { throw FBSimulatorSliderError.unsupportedAction }
    try admissionGuard?.validateTarget(final, allowingValueChange: allowingValueChange)
    try FBSimulatorSliderEndpointController.check(deadline)
    try feed.validateCurrentRevision(expected: observation)
    // Native action returns void: a return is not an app acknowledgment.
    try selected.sliderAdjust(action, deadline: deadline)
    do {
      try FBSimulatorSliderEndpointController.check(deadline)
      try feed.validateCurrentRevision(expected: observation)
      try FBSimulatorSliderEndpointController.check(deadline)
      try retainSliderSelection(selected, baseline: final, for: simulator, token: token, revision: revision)
      retained = true
    } catch { throw FBSimulatorSliderError.deliveryUncertain(String(describing: error)) }
    return final
  }
}
