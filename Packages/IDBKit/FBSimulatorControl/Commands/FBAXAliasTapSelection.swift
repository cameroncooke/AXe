import Foundation
import CoreGraphics

/// A consistent object class supplies tap identity, never gesture or focus ancestry.
/// A singleton does not enter this policy: its existing numeric/value contract is unchanged.
struct FBAXAliasTapSelection: Sendable {
  let identity: FBSimulatorAXNativeIdentity
  let elementType: String
  let node: FBSimulatorAXNode
  let paths: [[Int]]
  let digest: String

  static func select(in snapshot: FBSimulatorAXSnapshot, selector: FBSimulatorAXSelector,
    expectedPID: Int32) throws -> Self? {
    guard case .nativeObject(let identity, let type) = selector else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    // Count raw keys before any state/type filtering. No alias index is required
    // for the old singleton path, including singleton numeric values.
    var count = 0, visited = 0
    var pending = snapshot.roots.map { ($0, 0) }
    while let (node, depth) = pending.popLast() {
      guard depth <= 64, visited < 4096 else { throw FBSimulatorAXNativeObjectIndex.Failure.hierarchyBound }
      visited += 1
      if node.nativeIdentity == identity { count += 1 }
      pending += node.children.map { ($0, depth + 1) }
    }
    guard count > 1 else { return nil }
    let index = try FBSimulatorAXNativeObjectIndex(roots: snapshot.roots, metadata: snapshot.nativeIdentityMetadata)
    let resolved = try index.resolve(identity: identity, elementType: type, expectedPID: expectedPID)
    guard type != "Slider", resolved.node.focused != nil, resolved.node.role?.isEmpty == false,
          let digest = index.subtreeDigest(for: identity) else { throw FBSimulatorAXSnapshotError.invalidSelection }
    try FBAXTargetValidationRules.opaqueTarget(resolved.node, expectedPID: expectedPID,
      context: snapshot.observation.displayContext)
    return Self(identity: identity, elementType: type, node: resolved.node,
      paths: resolved.occurrences.map(\.path), digest: digest)
  }

  /// Within-capture consistency and the selected parent stay strict in both modes.
  /// This does not authorize input until the actual point selects its validation mode.
  func currentIndex(in fresh: FBSimulatorAXSnapshot) throws -> FBSimulatorAXNativeObjectIndex {
    let index = try FBSimulatorAXNativeObjectIndex(roots: fresh.roots, metadata: fresh.nativeIdentityMetadata)
    let resolved = try index.resolve(identity: identity, elementType: elementType, expectedPID: identity.pid)
    guard resolved.isAlias, resolved.occurrences.map(\.path) == paths,
          FBAXTargetValidationRules.sameOpaqueNode(resolved.node, node),
          try FBAXAliasDirectTreeRules.sameTypedFields(resolved.node, node) else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    return index
  }

  /// Descendant authority keeps the original exact keys and full class certificate.
  func validateFresh(_ fresh: FBSimulatorAXSnapshot, original: FBSimulatorAXSnapshot) throws -> FBSimulatorAXNativeObjectIndex {
    try FBSimulatorAXSnapshot.requireSame(original.observation, fresh.observation)
    try FBAXOpaqueFrameTapRules.requireUnchangedTree(original.roots, fresh.roots)
    let index = try currentIndex(in: fresh)
    guard index.subtreeDigest(for: identity) == digest else { throw FBSimulatorAXTargetError.targetMismatch }
    return index
  }

  /// Only an exact parent hit can use this comparison. It is not descendant authority.
  func validateDirectFresh(_ fresh: FBSimulatorAXSnapshot, original: FBSimulatorAXSnapshot,
    index: FBSimulatorAXNativeObjectIndex) throws {
    try FBSimulatorAXSnapshot.requireSame(original.observation, fresh.observation)
    let old = try FBSimulatorAXNativeObjectIndex(roots: original.roots, metadata: original.nativeIdentityMetadata)
    let selected = try old.resolve(identity: identity, elementType: elementType, expectedPID: identity.pid)
    guard selected.occurrences.map(\.path) == paths, old.subtreeDigest(for: identity) == digest else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    try FBAXAliasDirectTreeRules.compare(original.roots, fresh.roots,
      parentPaths: paths, expectedPID: identity.pid, old: old, fresh: index)
  }

  /// A direct native hit is exact. A Button descendant must have the same owned
  /// lineage in EVERY raw occurrence, with no occurrence outside this object class.
  func match(pointRoots: [FBSimulatorAXNode], hitPID: Int32, point: CGPoint,
    index: FBSimulatorAXNativeObjectIndex) throws -> String {
    let selector = FBSimulatorAXSelector.nativeObject(identity: identity, elementType: elementType)
    do {
      let hit = try FBAXTargetValidationRules.hit(pointRoots, expected: node, selector: selector,
        expectedPID: identity.pid, hitPID: hitPID, point: point)
      guard hit.sameOpaqueFrameTapFields(as: node),
            try FBAXAliasDirectTreeRules.sameTypedFields(hit, node) else { throw FBSimulatorAXTargetError.targetMismatch }
      return "consistentAliasDirect"
    } catch FBSimulatorAXTargetError.targetMismatch {
      guard elementType == "Button", hitPID == identity.pid, pointRoots.count == 1,
            let hit = pointRoots.first, let hitKey = hit.nativeIdentity, let hitType = hit.type,
            hitType != "Button", hitKey != identity, hit.pid == identity.pid,
            let targetFrame = node.frame, let hitFrame = hit.frame,
            targetFrame.contains(point), targetFrame.contains(hitFrame), hitFrame.contains(point) else {
        throw FBSimulatorAXTargetError.targetMismatch
      }
      let actual = try index.resolve(identity: hitKey, elementType: hitType, expectedPID: identity.pid)
      guard FBAXTargetValidationRules.sameOpaqueNode(actual.node, hit),
            actual.node.sameOpaqueFrameTapFields(as: hit) else {
        throw FBSimulatorAXTargetError.targetMismatch
      }
      var lineage: [FBSimulatorAXNativeIdentity]?
      var targetPaths = Set<[Int]>()
      for occurrence in actual.occurrences {
        let owners = occurrence.ancestorIndices.filter { index.nodes[$0].nativeIdentity == identity }
        guard owners.count == 1, let owner = owners.first,
              let ownerOffset = occurrence.ancestorIndices.firstIndex(of: owner) else {
          throw FBSimulatorAXTargetError.targetMismatch
        }
        // An unrelated nested Button cannot borrow the outer Button's authority.
        let descendants = Array(occurrence.ancestorIndices.dropFirst(ownerOffset + 1))
        guard descendants.allSatisfy({ index.nodes[$0].type != "Button" }) else {
          throw FBSimulatorAXTargetError.targetMismatch
        }
        let keys = descendants.compactMap { index.nodes[$0].nativeIdentity } + [hitKey]
        guard keys.count == descendants.count + 1, lineage == nil || lineage == keys else {
          throw FBSimulatorAXTargetError.targetMismatch
        }
        lineage = keys
        let ownerPath = Array(occurrence.path.prefix(ownerOffset + 1))
        guard targetPaths.insert(ownerPath).inserted else { throw FBSimulatorAXTargetError.targetMismatch }
      }
      guard targetPaths == Set(paths) else { throw FBSimulatorAXTargetError.targetMismatch }
      return "consistentAliasButtonDescendant"
    }
  }
}

/// A direct native parent hit does not depend on the lifetime of unselected child
/// objects. Every ordered typed field remains bound; identities outside the exact
/// parent copies stay strict. No node/path is removed or used as input authority.
enum FBAXAliasDirectTreeRules {
  static func compare(_ original: [FBSimulatorAXNode], _ current: [FBSimulatorAXNode],
    parentPaths: [[Int]], expectedPID: Int32, old: FBSimulatorAXNativeObjectIndex,
    fresh: FBSimulatorAXNativeObjectIndex) throws {
    guard original.count == current.count else { throw FBSimulatorAXTargetError.targetMismatch }
    func inside(_ path: [Int]) -> Bool {
      parentPaths.contains { path.count > $0.count && path.starts(with: $0) }
    }
    var forward: [FBSimulatorAXNativeIdentity: FBSimulatorAXNativeIdentity] = [:]
    var reverse: [FBSimulatorAXNativeIdentity: FBSimulatorAXNativeIdentity] = [:]
    var pending = original.indices.map { (original[$0], current[$0], [$0]) }
    var visited = 0
    while let (left, right, path) = pending.popLast() {
      guard visited < 4096, path.count <= 65,
            left.children.count == right.children.count,
            let oldKey = left.nativeIdentity, let newKey = right.nativeIdentity,
            try sameTypedFields(left, right) else { throw FBSimulatorAXTargetError.targetMismatch }
      visited += 1
      if inside(path) {
        // A key rename cannot split or merge the equality relation inside the class.
        guard forward[oldKey] == nil || forward[oldKey] == newKey,
              reverse[newKey] == nil || reverse[newKey] == oldKey else {
          throw FBSimulatorAXTargetError.targetMismatch
        }
        forward[oldKey] = newKey; reverse[newKey] = oldKey
        if oldKey != newKey {
          let before = old.occurrences(for: oldKey), after = fresh.occurrences(for: newKey)
          guard oldKey.pid == expectedPID, newKey.pid == expectedPID,
                !before.isEmpty, !after.isEmpty,
                before.allSatisfy({ inside($0.path) }), after.allSatisfy({ inside($0.path) }) else {
            throw FBSimulatorAXTargetError.targetMismatch
          }
        }
      } else if oldKey != newKey { throw FBSimulatorAXTargetError.targetMismatch }
      pending += left.children.indices.map { (left.children[$0], right.children[$0], path + [$0]) }
    }
  }

  static func sameTypedFields(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode) throws -> Bool {
    guard exactValue(left.value), exactValue(right.value) else { throw FBSimulatorAXNativeObjectIndex.Failure.unprovableValue }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(Fields(left)) == encoder.encode(Fields(right))
  }

  private static func exactValue(_ value: FBSimulatorAXValue?) -> Bool {
    guard let value else { return true }
    // Preserve the existing admission's scalar-only comparison boundary. The
    // shared per-capture index has a broader read certificate, not input authority.
    switch value {
    case .number, .array, .object: return false
    case .null, .boolean, .string: return true
    }
  }

  private struct RawFrame: Encodable {
    let x: Double, y: Double, width: Double, height: Double
    init(_ frame: CGRect) {
      x = frame.origin.x; y = frame.origin.y
      width = frame.size.width; height = frame.size.height
    }
  }

  private struct Fields: Encodable {
    let type: String?, role: String?, roleDescription: String?, subrole: String?
    let identifier: String?, label: String?, discoveryMethod: String?
    let value: FBSimulatorAXValue?
    let customActionNames: [String]
    let frame: RawFrame?
    let pid: Int32?, nativePID: Int32?
    let focused: Bool?, enabled: Bool?, hidden: Bool?
    init(_ node: FBSimulatorAXNode) {
      type = node.type; role = node.role; roleDescription = node.roleDescription; subrole = node.subrole
      identifier = node.identifier; label = node.label; discoveryMethod = node.discoveryMethod
      value = node.value; customActionNames = node.customActionNames; frame = node.frame.map(RawFrame.init)
      pid = node.pid; nativePID = node.nativeIdentity?.pid
      focused = node.focused; enabled = node.enabled; hidden = node.hidden
    }
  }
}

extension FBSimulatorAXWorker {
  /// The existing owned budget, context feed and HID reservation remain authoritative.
  /// No frame-only/unknown-point hook or semantic retry is used for an alias.
  func validateAliasTap(for simulator: FBSimulator, selection: FBAXAliasTapSelection,
    original: FBSimulatorAXSnapshot, point: CGPoint, observation: FBSimulatorHIDSessionObservation,
    provider: any FBSimulatorHIDLiveFreshnessProvider,
    budget: FBAXAcquisitionBudget) async throws -> FBSimulatorAXTargetValidation {
    let started = ProcessInfo.processInfo.systemUptime
    var initialRoots: [FBSimulatorAXNode] = []
    var freshRoots: [FBSimulatorAXNode]?
    var confirmedRoots: [FBSimulatorAXNode]?
    var hitPID: Int32 = 0
    var confirmedPID: Int32?
    do {
      try budget.check(); try Task.checkCancellation()
      try FBSimulatorAXSnapshot.requireSame(original.observation, observation)
      try provider.validateCurrentRevision(expected: observation)
      let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
      let rootRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      rootRequest.acquisitionBudget = budget
      let root = try await commands.accessibilityElementForAcquisition(request: rootRequest, worker: self)
      defer { root.close() }
      guard root.acquisitionPID == selection.identity.pid else {
        throw FBSimulatorAXTargetError.wrongPID(expected: selection.identity.pid, actual: root.acquisitionPID)
      }
      let tree = try serialize(root, observation: observation, remoteContentOptions: nil, includeNativeIdentity: true)
      freshRoots = tree.roots
      let index = try selection.currentIndex(in: tree)
      root.close()
      try budget.check(); try provider.validateCurrentRevision(expected: observation)
      let transform = FBAXTranslationRequest(kind: .point(point), pointDisplayID: observation.axDisplayID,
        displayContext: observation.displayContext)
      let native = try transform.nativePoint(from: point)
      let request = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
        displayContext: observation.displayContext)
      request.acquisitionBudget = budget
      let hitHandle = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
      defer { hitHandle.close() }
      hitPID = hitHandle.acquisitionPID
      let initial = try serialize(hitHandle, observation: observation, remoteContentOptions: nil, includeNativeIdentity: true)
      initialRoots = initial.roots
      let kind = try selection.match(pointRoots: initial.roots, hitPID: hitPID, point: point, index: index)
      switch kind {
      case "consistentAliasDirect":
        try selection.validateDirectFresh(tree, original: original, index: index)
      case "consistentAliasButtonDescendant":
        _ = try selection.validateFresh(tree, original: original)
      default: throw FBSimulatorAXTargetError.targetMismatch
      }
      hitHandle.close()
      try budget.check(); try Task.checkCancellation(); try provider.validateCurrentRevision(expected: observation)
      let confirmRequest = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
        displayContext: observation.displayContext)
      confirmRequest.acquisitionBudget = budget
      let confirmation = try await commands.accessibilityElementForAcquisition(request: confirmRequest, worker: self)
      defer { confirmation.close() }
      confirmedPID = confirmation.acquisitionPID
      let confirmed = try serialize(confirmation, observation: observation, remoteContentOptions: nil, includeNativeIdentity: true)
      confirmedRoots = confirmed.roots
      guard try selection.match(pointRoots: confirmed.roots, hitPID: confirmation.acquisitionPID,
              point: point, index: index) == kind,
            let hit = initial.roots.first, let confirmedHit = confirmed.roots.first,
            FBAXTargetValidationRules.sameOpaqueNode(hit, confirmedHit),
            hit.sameOpaqueFrameTapFields(as: confirmedHit) else {
        throw FBSimulatorAXTargetError.targetMismatch
      }
      confirmation.close()
      try budget.check(); try provider.validateCurrentRevision(expected: observation)
      let verifyRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      verifyRequest.acquisitionBudget = budget
      let verify = try await commands.accessibilityElementForAcquisition(request: verifyRequest, worker: self)
      let frontmostPID = verify.acquisitionPID
      verify.close()
      guard frontmostPID == selection.identity.pid else {
        throw FBSimulatorAXTargetError.wrongPID(expected: selection.identity.pid, actual: frontmostPID)
      }
      try budget.check(); try Task.checkCancellation(); try provider.validateCurrentRevision(expected: observation)
      return .init(startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime,
        expectedPID: selection.identity.pid, hitPID: hitPID, frontmostPID: frontmostPID,
        pointX: point.x, pointY: point.y, hit: hit, confirmedHit: confirmedHit,
        confirmedHitPID: confirmedPID, matchKind: kind, verifiedTarget: selection.node,
        relationshipTree: tree.roots, nativeSwitchProof: nil)
    } catch {
      throw FBSimulatorAXTargetHitFailure(expectedPID: selection.identity.pid, hitPID: hitPID,
        roots: initialRoots, freshRoots: freshRoots, confirmedRoots: confirmedRoots,
        confirmedHitPID: confirmedPID, reason: String(reflecting: error))
    }
  }
}
