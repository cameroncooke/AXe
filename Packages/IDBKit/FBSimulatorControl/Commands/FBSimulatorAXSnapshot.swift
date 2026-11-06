import FBControlCore
import Foundation

public enum FBSimulatorAXSnapshotError: Error, Sendable {
  case staleContext
  case wrongSimulator
  case invalidSelection
  case invalidRemoteOptions
  case emptyHierarchy
  case emptySelector
  case notFound
  case ambiguous(count: Int)
  case foreignReference
}

/// The JSON value exposed by AX. Preserve booleans, numbers and text without
/// assuming that a slider's display value uses its native control range.
public enum FBSimulatorAXValue: Codable, Sendable, Equatable {
  case null
  case boolean(Bool)
  case number(Double)
  case string(String)
  case array([FBSimulatorAXValue])
  case object([String: FBSimulatorAXValue])

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() { self = .null }
    else if let result = try? value.decode(Bool.self) { self = .boolean(result) }
    else if let result = try? value.decode(Double.self) { self = .number(result) }
    else if let result = try? value.decode(String.self) { self = .string(result) }
    else if let result = try? value.decode([Self].self) { self = .array(result) }
    else { self = .object(try value.decode([String: Self].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .boolean(let result): try value.encode(result)
    case .number(let result): try value.encode(result)
    case .string(let result): try value.encode(result)
    case .array(let result): try value.encode(result)
    case .object(let result): try value.encode(result)
    }
  }
}

/// AX fields used for exact selector resolution. No remote platform handles escape a read.
public struct FBSimulatorAXNode: Codable, Sendable {
  public let type: String?
  /// Optional values from the existing typed role getters; no role is inferred.
  public let role: String?
  public let roleDescription: String?
  public let subrole: String?
  public let identifier: String?
  public let nativeIdentity: FBSimulatorAXNativeIdentity?
  public let label: String?
  public let value: FBSimulatorAXValue?
  /// Read-only custom action labels. Names alone do not authorize input.
  public let customActionNames: [String]
  // Preserve the legacy Int-first scalar text before the public Double value loses precision.
  fileprivate let scalarSelectionValue: String?
  public let frame: CGRect?
  public let pid: Int32?
  public let discoveryMethod: String?
  /// Values returned by the typed AX getters. These do not prove keyboard input focus
  /// or a fresh native callback; absent fields remain nil when decoding older output.
  public let focused: Bool?
  public let enabled: Bool?
  public let hidden: Bool?
  public let children: [FBSimulatorAXNode]

  enum CodingKeys: String, CodingKey {
    case type, identifier = "AXUniqueId", label = "AXLabel", value = "AXValue", frame, pid
    case discoveryMethod = "is_remote", children
    case focused, enabled, hidden
    case role, roleDescription = "role_description", subrole, nativeIdentity
    case customActionNames = "custom_actions"
  }
  private struct Frame: Codable { let x: Double; let y: Double; let width: Double; let height: Double }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    type = try values.decodeIfPresent(String.self, forKey: .type)
    role = try values.decodeIfPresent(String.self, forKey: .role)
    roleDescription = try values.decodeIfPresent(String.self, forKey: .roleDescription)
    subrole = try values.decodeIfPresent(String.self, forKey: .subrole)
    identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
    nativeIdentity = try values.decodeIfPresent(FBSimulatorAXNativeIdentity.self, forKey: .nativeIdentity)
    label = try values.decodeIfPresent(String.self, forKey: .label)
    value = try values.decodeIfPresent(FBSimulatorAXValue.self, forKey: .value)
    customActionNames = try values.decodeIfPresent([String].self, forKey: .customActionNames) ?? []
    scalarSelectionValue = try Self.decodeScalarSelectionValue(from: values)
    pid = try values.decodeIfPresent(Int32.self, forKey: .pid)
    discoveryMethod = try values.decodeIfPresent(String.self, forKey: .discoveryMethod)
    focused = try values.decodeIfPresent(Bool.self, forKey: .focused)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled)
    hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden)
    let value = try values.decodeIfPresent(Frame.self, forKey: .frame)
    frame = value.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    children = try values.decodeIfPresent([Self].self, forKey: .children) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(type, forKey: .type)
    try values.encodeIfPresent(role, forKey: .role)
    try values.encodeIfPresent(roleDescription, forKey: .roleDescription)
    try values.encodeIfPresent(subrole, forKey: .subrole)
    try values.encodeIfPresent(identifier, forKey: .identifier)
    try values.encodeIfPresent(nativeIdentity, forKey: .nativeIdentity)
    try values.encodeIfPresent(label, forKey: .label)
    try values.encodeIfPresent(value, forKey: .value)
    if !customActionNames.isEmpty { try values.encode(customActionNames, forKey: .customActionNames) }
    try values.encodeIfPresent(pid, forKey: .pid)
    try values.encodeIfPresent(discoveryMethod, forKey: .discoveryMethod)
    try values.encodeIfPresent(focused, forKey: .focused)
    try values.encodeIfPresent(enabled, forKey: .enabled)
    try values.encodeIfPresent(hidden, forKey: .hidden)
    if let frame {
      try values.encode(Frame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), forKey: .frame)
    }
    try values.encode(children, forKey: .children)
  }

  private static func decodeScalarSelectionValue(from values: KeyedDecodingContainer<CodingKeys>) throws -> String? {
    guard values.contains(.value), try !values.decodeNil(forKey: .value) else { return nil }
    if let value = try? values.decode(String.self, forKey: .value) { return value }
    if let value = try? values.decode(Int.self, forKey: .value) { return String(value) }
    if let value = try? values.decode(Double.self, forKey: .value) { return String(value) }
    if let value = try? values.decode(Bool.self, forKey: .value) { return String(value) }
    return nil
  }

  var flattened: [Self] { [self] + children.flatMap(\.flattened) }
}

public enum FBSimulatorAXSelector: Sendable {
  case identifier(String)
  case label(String)
  case identifierWithType(String, elementType: String)
  case labelWithType(String, elementType: String)
  case value(String)
  case valueWithType(String, elementType: String)
  case nativeObject(identity: FBSimulatorAXNativeIdentity, elementType: String)

  private var selectorText: String {
    switch self {
    case .identifier(let value), .label(let value), .value(let value),
         .identifierWithType(let value, _), .labelWithType(let value, _),
         .valueWithType(let value, _): return value
    case .nativeObject: return ""
    }
  }

  private var elementType: String? {
    switch self {
    case .identifier, .label, .value: return nil
    case .identifierWithType(_, let type), .labelWithType(_, let type),
         .valueWithType(_, let type), .nativeObject(_, let type): return type
    }
  }

  var usesNativeIdentity: Bool { if case .nativeObject = self { return true }; return false }

  func validate() throws {
    if case .nativeObject(let identity, let type) = self {
      try identity.validate()
      guard !type.isEmpty, type == type.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw FBSimulatorAXSnapshotError.invalidSelection
      }
      return
    }
    guard !selectorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FBSimulatorAXSnapshotError.emptySelector
    }
    if let elementType, elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
  }

  /// One predicate for snapshot resolution and both final target match paths.
  /// Type is exact; it filters the selected target, not a proven Button child.
  func matches(_ node: FBSimulatorAXNode) -> Bool {
    if case .nativeObject(let identity, let type) = self {
      return identity.pid > 0 && identity.objectID > 0 && node.nativeIdentity == identity
        && node.pid == identity.pid && node.type == type
    }
    let wanted = selectorText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else { return false }
    if let elementType {
      guard !elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            node.type == elementType else { return false }
    }
    let candidate: String?
    switch self {
    case .identifier, .identifierWithType: candidate = node.identifier
    case .label, .labelWithType: return Self.matchesLabel(node.label, query: selectorText)
    case .value, .valueWithType: candidate = node.scalarSelectionValue
    case .nativeObject: return false
    }
    return candidate?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
  }

  /// Shared by immutable selection and the owned exact-label handle search.
  static func matchesLabel(_ candidate: String?, query: String) -> Bool {
    let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return !wanted.isEmpty && candidate?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
  }
}

/// One exact Button chain, selected by structure rather than assumed object aliases.
/// Raw nodes remain unchanged. The returned index belongs only to this bounded read.
public struct FBSimulatorAXButtonLeafSelection: Sendable {
  public let node: FBSimulatorAXNode
  public let matchingIndices: [Int]
  public var index: Int { matchingIndices[matchingIndices.count - 1] }

  public static func resolve(in roots: [FBSimulatorAXNode], selector: FBSimulatorAXSelector) -> Self? {
    switch selector {
    case .identifier, .label, .identifierWithType, .labelWithType: break
    case .value, .valueWithType, .nativeObject: return nil
    }
    var nodes: [FBSimulatorAXNode] = []
    var paths: [[Int]] = []
    var complete = true
    func walk(_ node: FBSimulatorAXNode, path: [Int]) {
      guard path.count <= 65, nodes.count < 4096 else { complete = false; return }
      nodes.append(node); paths.append(path)
      for (index, child) in node.children.enumerated() { walk(child, path: path + [index]) }
    }
    for (index, root) in roots.enumerated() { walk(root, path: [index]) }
    guard complete else { return nil }
    let matches = nodes.indices.filter { selector.matches(nodes[$0]) }
    guard matches.count > 1, let first = matches.first, let last = matches.last else { return nil }
    let original = nodes[first]
    guard original.type == "Button", original.role == "AXButton", original.enabled == true,
          original.hidden == false, let pid = original.pid, pid > 0,
          let identifier = original.identifier, !identifier.isEmpty,
          identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
          let label = original.label, !label.isEmpty,
          label == label.trimmingCharacters(in: .whitespacesAndNewlines),
          let frame = original.frame,
          [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
          frame.width > 0, frame.height > 0,
          nodes.filter({ $0.identifier == identifier }).count == matches.count else { return nil }
    for (offset, index) in matches.enumerated() {
      let node = nodes[index]
      guard node.type == original.type, node.role == original.role, node.subrole == original.subrole,
            node.identifier == identifier, node.label == label, node.value == original.value,
            node.frame == frame, node.pid == pid, node.enabled == true, node.hidden == false else { return nil }
      if offset + 1 < matches.count {
        guard node.children.count == 1, paths[matches[offset + 1]] == paths[index] + [0] else { return nil }
      } else if !node.children.isEmpty { return nil }
    }
    return Self(node: nodes[last], matchingIndices: matches)
  }
}

/// A reference is tied to one measured snapshot, not a stable identity across transitions.
public struct FBSimulatorAXReference: Sendable {
  public let node: FBSimulatorAXNode
  public let observation: FBSimulatorHIDSessionObservation
  public let snapshotID: UUID
  let buttonLeafChainCount: Int

  init(node: FBSimulatorAXNode, observation: FBSimulatorHIDSessionObservation, snapshotID: UUID,
    buttonLeafChainCount: Int = 1) {
    self.node = node; self.observation = observation; self.snapshotID = snapshotID
    self.buttonLeafChainCount = buttonLeafChainCount
  }
}

/// Immutable result with explicit screen, boot, pose and coordinate identity.
/// Lookup validates measured context again. A returned point is not an atomic input operation;
/// the caller must use the same observation in a fresh input session before sending it.
public struct FBSimulatorAXSnapshot: Sendable {
  public let observation: FBSimulatorHIDSessionObservation
  public let snapshotID: UUID
  public let roots: [FBSimulatorAXNode]
  public let jsonData: Data
  public let nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata?

  init(observation: FBSimulatorHIDSessionObservation, jsonData: Data) throws {
    try self.init(observation: observation, jsonData: jsonData, nativeIdentityMetadata: nil)
  }

  init(observation: FBSimulatorHIDSessionObservation, jsonData: Data,
    nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata?) throws {
    self.nativeIdentityMetadata = nativeIdentityMetadata
    self.observation = observation
    self.snapshotID = UUID()
    self.jsonData = jsonData
    let decoder = JSONDecoder()
    if let array = try? decoder.decode([FBSimulatorAXNode].self, from: jsonData) {
      roots = array
    } else {
      roots = [try decoder.decode(FBSimulatorAXNode.self, from: jsonData)]
    }
  }

  public func resolve(_ selector: FBSimulatorAXSelector,
                      freshnessProvider: any FBSimulatorHIDFreshnessProvider) async throws -> FBSimulatorAXReference {
    try Self.requireSame(observation, try await freshnessProvider.observation())
    try selector.validate()
    if case .nativeObject(let identity, let type) = selector {
      guard nativeIdentityMetadata?.complete == true else { throw FBSimulatorAXSnapshotError.invalidSelection }
      let node = try FBAXNativeObjectSelection.uniqueNode(in: roots, identity: identity, elementType: type)
      return FBSimulatorAXReference(node: node, observation: observation, snapshotID: snapshotID)
    }
    let matches = roots.flatMap(\.flattened).filter { selector.matches($0) }
    guard !matches.isEmpty else { throw FBSimulatorAXSnapshotError.notFound }
    if matches.count > 1 {
      guard let selected = FBSimulatorAXButtonLeafSelection.resolve(in: roots, selector: selector) else {
        throw FBSimulatorAXSnapshotError.ambiguous(count: matches.count)
      }
      return FBSimulatorAXReference(node: selected.node, observation: observation, snapshotID: snapshotID,
        buttonLeafChainCount: selected.matchingIndices.count)
    }
    return FBSimulatorAXReference(node: matches[0], observation: observation, snapshotID: snapshotID)
  }

  public func validate(_ reference: FBSimulatorAXReference,
                       freshnessProvider: any FBSimulatorHIDFreshnessProvider) async throws {
    guard reference.snapshotID == snapshotID, reference.observation == observation else {
      throw FBSimulatorAXSnapshotError.foreignReference
    }
    try Self.requireSame(observation, try await freshnessProvider.observation())
  }

  static func requireSame(_ expected: FBSimulatorHIDSessionObservation,
                          _ actual: FBSimulatorHIDSessionObservation) throws {
    guard expected == actual else { throw FBSimulatorAXSnapshotError.staleContext }
  }

  /// Reads on the dedicated AX worker; only immutable data leaves that worker.
  public static func read(
    for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    remoteContentOptions: FBAccessibilityRemoteContentOptions? = nil
  ) async throws -> Self {
    try await FBSimulatorAXWorker.shared.read(for: simulator, observation: observation,
      freshnessProvider: freshnessProvider, remoteContentOptions: remoteContentOptions)
  }

  public static func atPoint(
    _ point: CGPoint, for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider
  ) async throws -> Self {
    try await FBSimulatorAXWorker.shared.atPoint(point, for: simulator,
      observation: observation, freshnessProvider: freshnessProvider)
  }

  /// Isolated read-only diagnostic; one exact selected slider, immutable output.
  public static func sliderCapabilities(for simulator: FBSimulator,
    observation: FBSimulatorHIDSessionObservation, freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    identifier: String, expectedPID: Int32) async throws -> Data {
    try await FBSimulatorAXWorker.shared.sliderCapabilities(for: simulator, observation: observation,
      provider: freshnessProvider, identifier: identifier, expectedPID: expectedPID)
  }
}

/// Blocking lazy AX callbacks run on this private serial queue, not MainActor or
/// the cooperative pool. The executor reference is nonisolated only to satisfy
/// Actor's executor contract; all operation state remains actor-owned.
private final class FBSimulatorAXExecutor: SerialExecutor {
  private let queue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.ax.snapshot")
  func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
  func enqueue(_ job: UnownedJob) {
    queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }
}

actor FBSimulatorAXWorker {
  static let shared = FBSimulatorAXWorker()
  static let snapshotKeys: Set<FBAXKeys> = [.label, .value, .uniqueID, .type, .frameDict, .pid, .isRemote,
    .focused, .enabled, .hidden, .role, .roleDescription, .subrole, .customActions]
  var sliderLeases = FBSimulatorSliderLeaseTable<FBSimulatorSliderAcquisitionLease>()
  private let executor = FBSimulatorAXExecutor()
  nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

  func sliderCapabilities(for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    provider: any FBSimulatorHIDFreshnessProvider, identifier: String, expectedPID: Int32) async throws -> Data {
    guard !identifier.isEmpty, expectedPID > 0 else { throw FBSimulatorAXSnapshotError.emptySelector }
    try Task.checkCancellation()
    try await validateSelection(simulator, observation: observation, provider: provider)
    let request = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    let root = try await FBSimulatorAccessibilityCommands(simulator: simulator)
      .accessibilityElementForSnapshot(request: request, worker: self)
    let data: Data = try {
      defer { root.close() }
      let snapshot = try serialize(root, observation: observation, remoteContentOptions: nil)
      let matches = snapshot.roots.flatMap(\.flattened).filter { $0.identifier == identifier }
      guard matches.count == 1, let node = matches.first, node.type == "Slider", node.pid == expectedPID else {
        throw FBSimulatorAXSnapshotError.invalidSelection
      }
      let selected = try root.findElement(withValue: identifier, forKey: .uniqueID, depth: 64)
      defer { selected.close() }
      guard try selected.stringValue(forSearchableKey: .uniqueID) == identifier else {
        throw FBSimulatorAXSnapshotError.invalidSelection
      }
      return try selected.sliderCapabilityData()
    }()
    try await validateSelection(simulator, observation: observation, provider: provider)
    try Task.checkCancellation()
    return data
  }

  /// Reads the selected frontmost tree, optionally with bounded remote grid discovery.
  func read(
    for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    remoteContentOptions: FBAccessibilityRemoteContentOptions? = nil
  ) async throws -> FBSimulatorAXSnapshot {
    try Task.checkCancellation()
    if let options = remoteContentOptions {
      guard options.gridStepSize.isFinite, options.gridStepSize > 0,
            options.maxPoints > 0, options.maxPoints <= 256 else {
        throw FBSimulatorAXSnapshotError.invalidRemoteOptions
      }
    }
    try await validateSelection(simulator, observation: observation, provider: freshnessProvider)
    let request = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    let handle = try await FBSimulatorAccessibilityCommands(simulator: simulator)
      .accessibilityElementForSnapshot(request: request, worker: self)
    defer { handle.close() }
    let result = try serialize(handle, observation: observation, remoteContentOptions: remoteContentOptions)
    try FBSimulatorAXSnapshot.requireSame(observation, try await freshnessProvider.observation())
    try Task.checkCancellation()
    guard result.roots.contains(where: { !$0.children.isEmpty }) else {
      throw FBSimulatorAXSnapshotError.emptyHierarchy
    }
    return result
  }

  /// Takes oriented logical coordinates, then uses the proved native AX point transform.
  func atPoint(
    _ point: CGPoint, for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider
  ) async throws -> FBSimulatorAXSnapshot {
    try Task.checkCancellation()
    try await validateSelection(simulator, observation: observation, provider: freshnessProvider)
    let request = FBAXTranslationRequest(kind: .point(point), pointDisplayID: observation.axDisplayID,
                                         displayContext: observation.displayContext)
    let native = try request.nativePoint(from: point)
    let nativeRequest = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID)
    let handle = try await FBSimulatorAccessibilityCommands(simulator: simulator)
      .accessibilityElementForSnapshot(request: nativeRequest, worker: self)
    defer { handle.close() }
    let result = try serialize(handle, observation: observation, remoteContentOptions: nil)
    try FBSimulatorAXSnapshot.requireSame(observation, try await freshnessProvider.observation())
    try Task.checkCancellation()
    return result
  }

  func validateSelection(
    _ simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    provider: any FBSimulatorHIDFreshnessProvider
  ) async throws {
    guard simulator.udid == observation.simulatorUDID else { throw FBSimulatorAXSnapshotError.wrongSimulator }
    try FBSimulatorAXSnapshot.requireSame(observation, try await provider.observation())
    let display = try await FBSimulatorDisplayDiscovery.display(for: simulator, screenID: observation.screenID)
    guard display.uniqueID == observation.screenUniqueID,
          display.nativePixelSize == observation.displayContext.nativePixelSize,
          display.scale == observation.displayContext.scale else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
  }

  func serialize(_ handle: FBAccessibilityElement,
                                observation: FBSimulatorHIDSessionObservation,
                                remoteContentOptions: FBAccessibilityRemoteContentOptions?) throws -> FBSimulatorAXSnapshot {
    try Task.checkCancellation()
    let response = try handle.serialize(with: FBAccessibilityRequestOptions(
      nestedFormat: true, keys: Self.snapshotKeys,
      remoteContentOptions: remoteContentOptions))
    // The existing serializer boundary is untyped. Convert once; all lookup data is typed.
    let data = try JSONSerialization.data(withJSONObject: response.elements)
    try Task.checkCancellation()
    return try FBSimulatorAXSnapshot(observation: observation, jsonData: data)
  }
}

// Additive opt-in APIs preserve all legacy read entry points and wire keys.
extension FBSimulatorAXSnapshot {
  public static func read(for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    remoteContentOptions: FBAccessibilityRemoteContentOptions? = nil,
    includeNativeIdentity: Bool) async throws -> Self {
    if !includeNativeIdentity {
      return try await read(for: simulator, observation: observation,
        freshnessProvider: freshnessProvider, remoteContentOptions: remoteContentOptions)
    }
    return try await FBSimulatorAXWorker.shared.read(for: simulator, observation: observation,
      freshnessProvider: freshnessProvider, remoteContentOptions: remoteContentOptions, includeNativeIdentity: true)
  }

  public static func atPoint(_ point: CGPoint, for simulator: FBSimulator,
    observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    includeNativeIdentity: Bool) async throws -> Self {
    if !includeNativeIdentity {
      return try await atPoint(point, for: simulator, observation: observation, freshnessProvider: freshnessProvider)
    }
    return try await FBSimulatorAXWorker.shared.atPoint(point, for: simulator,
      observation: observation, freshnessProvider: freshnessProvider, includeNativeIdentity: true)
  }
}

extension FBSimulatorAXWorker {
  func serialize(_ handle: FBAccessibilityElement, observation: FBSimulatorHIDSessionObservation,
    remoteContentOptions: FBAccessibilityRemoteContentOptions?, includeNativeIdentity: Bool) throws -> FBSimulatorAXSnapshot {
    if !includeNativeIdentity { return try serialize(handle, observation: observation, remoteContentOptions: remoteContentOptions) }
    let identities = FBAXNativeIdentityCollector()
    let response = try handle.serialize(with: FBAccessibilityRequestOptions(nestedFormat: true,
      keys: Self.snapshotKeys, remoteContentOptions: remoteContentOptions), nativeIdentity: identities)
    let data = try JSONSerialization.data(withJSONObject: response.elements)
    try Task.checkCancellation()
    return try FBSimulatorAXSnapshot(observation: observation, jsonData: data,
      nativeIdentityMetadata: identities.metadata)
  }

  func read(for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    remoteContentOptions: FBAccessibilityRemoteContentOptions?, includeNativeIdentity: Bool) async throws -> FBSimulatorAXSnapshot {
    if !includeNativeIdentity {
      return try await read(for: simulator, observation: observation,
        freshnessProvider: freshnessProvider, remoteContentOptions: remoteContentOptions)
    }
    try Task.checkCancellation()
    try await validateSelection(simulator, observation: observation, provider: freshnessProvider)
    let budget = FBAXAcquisitionBudget(seconds: 8)
    let request = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    request.acquisitionBudget = budget
    let handle = try await FBSimulatorAccessibilityCommands(simulator: simulator)
      .accessibilityElementForSnapshot(request: request, worker: self)
    defer { handle.close() }
    let result = try serialize(handle, observation: observation, remoteContentOptions: remoteContentOptions,
      includeNativeIdentity: true)
    try FBSimulatorAXSnapshot.requireSame(observation, try await freshnessProvider.observation())
    try budget.check(); try Task.checkCancellation()
    guard result.roots.contains(where: { !$0.children.isEmpty }) else { throw FBSimulatorAXSnapshotError.emptyHierarchy }
    return result
  }

  func atPoint(_ point: CGPoint, for simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider, includeNativeIdentity: Bool) async throws -> FBSimulatorAXSnapshot {
    if !includeNativeIdentity { return try await atPoint(point, for: simulator, observation: observation, freshnessProvider: freshnessProvider) }
    try Task.checkCancellation()
    try await validateSelection(simulator, observation: observation, provider: freshnessProvider)
    let transform = FBAXTranslationRequest(kind: .point(point), pointDisplayID: observation.axDisplayID,
      displayContext: observation.displayContext)
    let native = try transform.nativePoint(from: point)
    let request = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
      displayContext: observation.displayContext)
    let budget = FBAXAcquisitionBudget(seconds: 8)
    request.acquisitionBudget = budget
    let handle = try await FBSimulatorAccessibilityCommands(simulator: simulator)
      .accessibilityElementForSnapshot(request: request, worker: self)
    defer { handle.close() }
    let result = try serialize(handle, observation: observation, remoteContentOptions: nil, includeNativeIdentity: true)
    try FBSimulatorAXSnapshot.requireSame(observation, try await freshnessProvider.observation())
    try budget.check(); try Task.checkCancellation()
    return result
  }
}

// Exact private comparison for opaque frame-tap admission only. Keep the shared
// semantic fingerprint unchanged, including its existing child-order policy.
extension FBSimulatorAXNode {
  func sameOpaqueFrameTapFields(as other: Self) -> Bool {
    Self.sameOpaqueFrameTapText(type, other.type) && Self.sameOpaqueFrameTapText(role, other.role)
      && Self.sameOpaqueFrameTapText(roleDescription, other.roleDescription)
      && Self.sameOpaqueFrameTapText(subrole, other.subrole)
      && Self.sameOpaqueFrameTapText(identifier, other.identifier) && nativeIdentity == other.nativeIdentity
      && Self.sameOpaqueFrameTapText(label, other.label) && sameExactOpaqueFrameTapValue(as: other)
      && frame?.origin == other.frame?.origin && frame?.size == other.frame?.size
      && pid == other.pid && Self.sameOpaqueFrameTapText(discoveryMethod, other.discoveryMethod)
      && focused == other.focused && enabled == other.enabled && hidden == other.hidden
  }

  /// Foundation can round numbers during both Double and Int decoding. This
  /// route has no exact numeric evidence, so all numeric/compound values refuse.
  private func sameExactOpaqueFrameTapValue(as other: Self) -> Bool {
    switch (value, other.value) {
    case (nil, nil), (.some(.null), .some(.null)): return true
    case (.some(.boolean(let left)), .some(.boolean(let right))): return left == right
    case (.some(.string(let left)), .some(.string(let right))):
      return left.utf8.elementsEqual(right.utf8)
    default: return false
    }
  }

  private static func sameOpaqueFrameTapText(_ left: String?, _ right: String?) -> Bool {
    switch (left, right) {
    case (nil, nil): return true
    case (.some(let left), .some(let right)): return left.utf8.elementsEqual(right.utf8)
    default: return false
    }
  }
}
