import Foundation
import CoreGraphics

/// A named CheckBox row can expose a separate unnamed leaf control. The row keeps
/// selector authority. Its actual child point must hit that child or the exact
/// owned parent whose point-read subtree reproduces the same unique child.
struct FBAXCheckBoxChildSelection: Sendable {
  let parent: FBSimulatorAXNode
  let child: FBSimulatorAXNode
  let point: CGPoint
  private let parentPath: [Int]
  private let usesNativeIdentity: Bool

  static func select(in roots: [FBSimulatorAXNode], parent expected: FBSimulatorAXNode,
    selector: FBSimulatorAXSelector, expectedPID: Int32,
    context: FBSimulatorHIDDisplayContext) throws -> Self? {
    guard expected.type == "CheckBox" else { return nil }
    let childControls = expected.children.filter { $0.type == "CheckBox" }
    guard !childControls.isEmpty else { return nil }
    try selector.validate()
    let entries = try entries(in: roots)
    if case .nativeObject(let identity, let type) = selector {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: roots, identity: identity, elementType: type)
    }
    let matches = entries.filter { selector.matches($0.node) }
    guard matches.count == 1, let entry = matches.first,
          sameNode(entry.node, expected, nativeIdentity: selector.usesNativeIdentity), !entry.unavailable,
          expectedPID > 0, expected.pid == expectedPID,
          expected.role == "AXCheckBox", expected.enabled == true, expected.hidden == false,
          let frame = expected.frame, valid(frame), childControls.count == 1,
          let child = childControls.first,
          child.type == "CheckBox", child.role == "AXCheckBox", child.children.isEmpty,
          child.identifier?.isEmpty != false, child.label?.isEmpty != false,
          child.pid == expectedPID, child.enabled == true, child.hidden == false,
          binaryValue(expected.value), child.value == expected.value,
          let childFrame = child.frame, valid(childFrame),
          entries.filter({ selector.usesNativeIdentity
            ? child.nativeIdentity != nil && $0.node.nativeIdentity == child.nativeIdentity
            : sameIdentity($0.node, child) }).count == 1 else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    let point = CGPoint(x: childFrame.midX, y: childFrame.midY)
    // Native child frames may extend slightly beyond the row. Exact ancestry and
    // the point in both frames are required; whole-frame containment is not assumed.
    guard frame.contains(point), childFrame.contains(point),
          point.x >= 0, point.y >= 0,
          point.x < context.logicalSize.width, point.y < context.logicalSize.height else {
      throw FBSimulatorAXTargetError.invalidPoint
    }
    return Self(parent: expected, child: child, point: point, parentPath: entry.path, usesNativeIdentity: selector.usesNativeIdentity)
  }

  /// Reproduce the original parent/child relationship from a fresh complete tree,
  /// then require the exact child or its exact owned parent from the point read.
  func validate(in roots: [FBSimulatorAXNode], hitRoots: [FBSimulatorAXNode],
    selector: FBSimulatorAXSelector, expectedPID: Int32, hitPID: Int32,
    context: FBSimulatorHIDDisplayContext) throws -> FBSimulatorAXNode {
    guard hitPID == expectedPID else {
      throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: hitPID)
    }
    guard usesNativeIdentity == selector.usesNativeIdentity else { throw FBSimulatorAXTargetError.targetMismatch }
    if case .nativeObject(let identity, let type) = selector {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: roots, identity: identity, elementType: type)
    }
    let matches = try Self.entries(in: roots).filter { selector.matches($0.node) }
    guard matches.count == 1, let freshParent = matches.first?.node,
          let fresh = try Self.select(in: roots, parent: freshParent, selector: selector,
            expectedPID: expectedPID, context: context),
          parentPath == fresh.parentPath,
          Self.sameNode(parent, fresh.parent, nativeIdentity: usesNativeIdentity), Self.sameNode(child, fresh.child, nativeIdentity: usesNativeIdentity),
          point == fresh.point,
          hitRoots.count == 1, let hit = hitRoots.first,
          let frame = hit.frame, Self.valid(frame), frame.contains(point) else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    if Self.sameNode(child, hit, nativeIdentity: usesNativeIdentity), hit.children.isEmpty {
      return fresh.parent
    }
    // The native point API can return this named row at its real child point.
    // Its own returned subtree must reproduce the exact child; an overlapping
    // parent frame, a Group or another row cannot supply this evidence.
    guard Self.sameNode(parent, hit, nativeIdentity: usesNativeIdentity), selector.matches(hit),
          let owned = try Self.select(in: hitRoots, parent: hit, selector: selector,
            expectedPID: expectedPID, context: context),
          Self.sameNode(child, owned.child, nativeIdentity: usesNativeIdentity), point == owned.point else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    return fresh.parent
  }

  /// Called only after both point reads have passed validate(in:hitRoots:...).
  func matchKind(initialHit: FBSimulatorAXNode, confirmedHit: FBSimulatorAXNode) -> String {
    let initialParent = Self.sameNode(parent, initialHit, nativeIdentity: usesNativeIdentity)
    let confirmedParent = Self.sameNode(parent, confirmedHit, nativeIdentity: usesNativeIdentity)
    if initialParent && confirmedParent { return "uniqueCheckBoxChildParentHit" }
    if initialParent || confirmedParent { return "uniqueCheckBoxChildMixedHit" }
    return "uniqueCheckBoxChild"
  }

  private struct Entry {
    let node: FBSimulatorAXNode
    let path: [Int]
    let unavailable: Bool
  }

  private static func entries(in roots: [FBSimulatorAXNode]) throws -> [Entry] {
    var result: [Entry] = []
    func collect(_ node: FBSimulatorAXNode, path: [Int], unavailable: Bool) throws {
      guard path.count <= 65, result.count < 4096 else {
        throw FBSimulatorAXSnapshotError.invalidSelection
      }
      let unavailable = unavailable || node.hidden == true || node.enabled == false
      result.append(Entry(node: node, path: path, unavailable: unavailable))
      for (index, child) in node.children.enumerated() {
        try collect(child, path: path + [index], unavailable: unavailable)
      }
    }
    for (index, root) in roots.enumerated() {
      try collect(root, path: [index], unavailable: false)
    }
    return result
  }

  private static func sameNode(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode) -> Bool {
    sameIdentity(left, right) && left.roleDescription == right.roleDescription &&
      left.value == right.value && left.enabled == right.enabled && left.hidden == right.hidden &&
      left.focused == right.focused && left.children.count == right.children.count
  }


  private static func sameNode(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode,
    nativeIdentity: Bool) -> Bool {
    sameNode(left, right) && (!nativeIdentity || FBAXTargetValidationRules.sameOpaqueNode(left, right))
  }

  private static func sameIdentity(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode) -> Bool {
    FBAXTargetValidationRules.sameSignature(left, right) && left.role == right.role &&
      left.subrole == right.subrole
  }

  private static func binaryValue(_ value: FBSimulatorAXValue?) -> Bool {
    guard let value else { return false }
    switch value {
    case .boolean: return true
    case .number(let number): return number == 0 || number == 1
    case .string(let text): return text == "0" || text == "1"
    default: return false
    }
  }

  private static func valid(_ frame: CGRect) -> Bool {
    [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite) &&
      frame.size.width > 0 && frame.size.height > 0
  }
}

extension FBSimulatorAXWorker {
  /// Separate from the existing Button and named UISwitch paths. Keep both native
  /// point reads and a final parent-tree read inside the same admission budget.
  func validateCheckBoxChild(for simulator: FBSimulator, expectedPID: Int32,
    selector: FBSimulatorAXSelector, selection: FBAXCheckBoxChildSelection,
    nativePoint: CGPoint, initialHit: FBAccessibilityElement, initialSnapshot: FBSimulatorAXSnapshot,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDLiveFreshnessProvider,
    budget: FBAXAcquisitionBudget, started: Double) async throws -> FBSimulatorAXTargetValidation {
    try await validateCheckBoxChild(for: simulator, expectedPID: expectedPID, selector: selector,
      selection: selection, nativePoint: nativePoint, initialHit: initialHit, initialSnapshot: initialSnapshot,
      observation: observation, provider: provider, budget: budget, started: started, includeNativeIdentity: false)
  }

  func validateCheckBoxChild(for simulator: FBSimulator, expectedPID: Int32,
    selector: FBSimulatorAXSelector, selection: FBAXCheckBoxChildSelection,
    nativePoint: CGPoint, initialHit: FBAccessibilityElement, initialSnapshot: FBSimulatorAXSnapshot,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDLiveFreshnessProvider,
    budget: FBAXAcquisitionBudget, started: Double, includeNativeIdentity: Bool) async throws -> FBSimulatorAXTargetValidation {
    var freshRoots: [FBSimulatorAXNode]?
    var confirmedRoots: [FBSimulatorAXNode]?
    var confirmedPID: Int32?
    do {
      try budget.check(); try Task.checkCancellation()
      let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
      let treeRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      treeRequest.acquisitionBudget = budget
      let root = try await commands.accessibilityElementForAcquisition(request: treeRequest, worker: self)
      defer { root.close() }
      guard root.acquisitionPID == expectedPID else {
        throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: root.acquisitionPID)
      }
      let tree = try serialize(root, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity || selector.usesNativeIdentity)
      freshRoots = tree.roots
      if selector.usesNativeIdentity, tree.nativeIdentityMetadata?.complete != true { throw FBSimulatorAXSnapshotError.invalidSelection }
      _ = try selection.validate(in: tree.roots, hitRoots: initialSnapshot.roots,
        selector: selector, expectedPID: expectedPID, hitPID: initialHit.acquisitionPID,
        context: observation.displayContext)
      try budget.check(); try provider.validateCurrentRevision(expected: observation)
      let pointRequest = FBAXTranslationRequest(kind: .point(nativePoint), pointDisplayID: observation.axDisplayID,
        displayContext: observation.displayContext)
      pointRequest.acquisitionBudget = budget
      let confirmation = try await commands.accessibilityElementForAcquisition(request: pointRequest, worker: self)
      defer { confirmation.close() }
      confirmedPID = confirmation.acquisitionPID
      let confirmed = try serialize(confirmation, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity || selector.usesNativeIdentity)
      confirmedRoots = confirmed.roots
      _ = try selection.validate(in: tree.roots, hitRoots: confirmed.roots,
        selector: selector, expectedPID: expectedPID, hitPID: confirmation.acquisitionPID,
        context: observation.displayContext)
      try budget.check(); try provider.validateCurrentRevision(expected: observation)
      // A second full parent tree rejects a reparent, state or geometry change
      // between the first relationship read and the confirmed point hit.
      let finalRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      finalRequest.acquisitionBudget = budget
      let finalRoot = try await commands.accessibilityElementForAcquisition(request: finalRequest, worker: self)
      defer { finalRoot.close() }
      guard finalRoot.acquisitionPID == expectedPID else {
        throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: finalRoot.acquisitionPID)
      }
      let finalTree = try serialize(finalRoot, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity || selector.usesNativeIdentity)
      freshRoots = finalTree.roots
      if selector.usesNativeIdentity, finalTree.nativeIdentityMetadata?.complete != true { throw FBSimulatorAXSnapshotError.invalidSelection }
      let target = try selection.validate(in: finalTree.roots, hitRoots: confirmed.roots,
        selector: selector, expectedPID: expectedPID, hitPID: confirmation.acquisitionPID,
        context: observation.displayContext)
      try budget.check(); try Task.checkCancellation()
      try provider.validateCurrentRevision(expected: observation)
      return .init(startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime,
        expectedPID: expectedPID, hitPID: initialHit.acquisitionPID, frontmostPID: finalRoot.acquisitionPID,
        pointX: selection.point.x, pointY: selection.point.y, hit: initialSnapshot.roots[0],
        confirmedHit: confirmed.roots[0], confirmedHitPID: confirmation.acquisitionPID,
        matchKind: selection.matchKind(initialHit: initialSnapshot.roots[0], confirmedHit: confirmed.roots[0]),
        verifiedTarget: target,
        relationshipTree: finalTree.roots, nativeSwitchProof: nil)
    } catch {
      throw FBSimulatorAXTargetHitFailure(expectedPID: expectedPID, hitPID: initialHit.acquisitionPID,
        roots: initialSnapshot.roots, freshRoots: freshRoots, confirmedRoots: confirmedRoots,
        confirmedHitPID: confirmedPID, reason: String(reflecting: error))
    }
  }
}
