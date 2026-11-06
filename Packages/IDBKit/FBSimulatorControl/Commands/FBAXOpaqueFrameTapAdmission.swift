import CoreGraphics
import Foundation

/// Pure host assessment of the complete, unpaged current tree. Implementations
/// must not call native/UI APIs, await, send input or select another target.
public protocol FBSimulatorAXOpaqueFrameTapAdmissionGuard: Sendable {
  func validate(roots: [FBSimulatorAXNode], nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata?,
    target: FBSimulatorAXNode, point: CGPoint, observation: FBSimulatorHIDSessionObservation) throws
}

enum FBAXOpaqueFrameTapError: Error { case rejected(String) }

enum FBAXOpaqueFrameTapRules {
  enum PointRelationship: Equatable { case exactKey, knownOther, unmapped }

  /// Keep every occurrence. Availability, type or focus cannot hide a duplicate.
  static func keyCounts(in roots: [FBSimulatorAXNode],
    metadata: FBSimulatorAXNativeIdentityMetadata?) throws -> [FBSimulatorAXNativeIdentity: Int] {
    guard metadata?.complete == true else { throw FBAXOpaqueFrameTapError.rejected("Incomplete native frame-tap tree") }
    var counts: [FBSimulatorAXNativeIdentity: Int] = [:]
    var pending = roots.map { (node: $0, depth: 0) }
    var visited = 0
    while let item = pending.popLast() {
      guard visited < 4096, item.depth <= 64, let key = item.node.nativeIdentity,
            key.pid > 0, key.objectID > 0, item.node.pid == key.pid else {
        throw FBAXOpaqueFrameTapError.rejected("Invalid native frame-tap tree identity or bound")
      }
      visited += 1
      counts[key, default: 0] += 1
      pending += item.node.children.map { (node: $0, depth: item.depth + 1) }
    }
    return counts
  }

  static func relationship(pointRoots: [FBSimulatorAXNode], expectedPID: Int32, hitPID: Int32,
    target: FBSimulatorAXNode, point: CGPoint,
    counts: [FBSimulatorAXNativeIdentity: Int]) throws -> PointRelationship {
    guard expectedPID > 0, hitPID == expectedPID, pointRoots.count == 1,
          let hit = pointRoots.first, hit.pid == expectedPID,
          let key = hit.nativeIdentity, key.pid == expectedPID, key.objectID > 0,
          hit.enabled == true, hit.hidden == false, hit.focused != nil,
          hit.type?.isEmpty == false, hit.role?.isEmpty == false,
          let frame = hit.frame, valid(frame), frame.contains(point) else {
      throw FBAXOpaqueFrameTapError.rejected("Native point result is not a valid same-owner observation")
    }
    guard let occurrences = counts[key] else { return .unmapped }
    return occurrences == 1 && key == target.nativeIdentity ? .exactKey : .knownOther
  }

  static func requireUnchangedTree(_ original: [FBSimulatorAXNode], _ fresh: [FBSimulatorAXNode]) throws {
    guard original.count == fresh.count else { throw FBAXOpaqueFrameTapError.rejected("Native frame-tap root order changed") }
    var pending = Array(zip(original, fresh)).map { (left: $0.0, right: $0.1, depth: 0) }
    var visited = 0
    while let item = pending.popLast() {
      guard visited < 4096, item.depth <= 64,
            item.left.sameOpaqueFrameTapFields(as: item.right),
            item.left.children.count == item.right.children.count else {
        throw FBAXOpaqueFrameTapError.rejected("Ordered native frame-tap tree changed")
      }
      visited += 1
      pending += zip(item.left.children, item.right.children).map { (left: $0.0, right: $0.1, depth: item.depth + 1) }
    }
  }

  static func validateAuthority(original: FBSimulatorAXSnapshot, fresh: FBSimulatorAXSnapshot,
    expected: FBSimulatorAXNode, selector: FBSimulatorAXSelector,
    point: CGPoint, observation: FBSimulatorHIDSessionObservation) throws -> FBSimulatorAXNode {
    guard case .nativeObject(let identity, let type) = selector else {
      throw FBAXOpaqueFrameTapError.rejected("Fresh frame authority requires the explicit native selector")
    }
    try FBSimulatorAXSnapshot.requireSame(original.observation, observation)
    try FBSimulatorAXSnapshot.requireSame(fresh.observation, observation)
    let oldCounts = try keyCounts(in: original.roots, metadata: original.nativeIdentityMetadata)
    let counts = try keyCounts(in: fresh.roots, metadata: fresh.nativeIdentityMetadata)
    guard oldCounts[identity] == 1, counts[identity] == 1 else {
      throw FBAXOpaqueFrameTapError.rejected("Native frame-tap target is missing or ambiguous")
    }
    try requireUnchangedTree(original.roots, fresh.roots)
    let selected = try FBAXNativeObjectSelection.uniqueNode(in: fresh.roots, identity: identity, elementType: type)
    guard selected.sameOpaqueFrameTapFields(as: expected), selected.focused != nil,
          selected.role?.isEmpty == false else {
      throw FBAXOpaqueFrameTapError.rejected("Native frame-tap target changed")
    }
    try FBAXTargetValidationRules.opaqueTarget(selected, expectedPID: identity.pid, context: observation.displayContext)
    guard let frame = selected.frame, frame.contains(point) else { throw FBSimulatorAXTargetError.invalidPoint }
    return selected
  }

  static func requireStableUnmappedPoint(_ first: [FBSimulatorAXNode], _ second: [FBSimulatorAXNode],
    expectedPID: Int32, firstPID: Int32, secondPID: Int32, target: FBSimulatorAXNode,
    point: CGPoint, counts: [FBSimulatorAXNativeIdentity: Int]) throws {
    guard try relationship(pointRoots: first, expectedPID: expectedPID, hitPID: firstPID,
              target: target, point: point, counts: counts) == .unmapped,
          try relationship(pointRoots: second, expectedPID: expectedPID, hitPID: secondPID,
              target: target, point: point, counts: counts) == .unmapped else {
      throw FBAXOpaqueFrameTapError.rejected("Point representation became a known native object")
    }
    try requireUnchangedTree(first, second)
  }

  private static func valid(_ frame: CGRect) -> Bool {
    [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
      && frame.size.width > 0 && frame.size.height > 0
  }
}

extension FBSimulatorAXWorker {
  /// The unknown point is not an alias. The explicit host hook grants only a
  /// single fresh-frame tap after native completeness and stability checks.
  func validateOpaqueFrameTap(for simulator: FBSimulator, expectedPID: Int32,
    selector: FBSimulatorAXSelector, reference: FBSimulatorAXReference, point: CGPoint, nativePoint: CGPoint,
    original: FBSimulatorAXSnapshot, fresh: FBSimulatorAXSnapshot,
    initial: FBSimulatorAXSnapshot, initialPID: Int32, initialProof: FBAXOpaquePointReadSuccess,
    admission: any FBSimulatorAXOpaqueFrameTapAdmissionGuard,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDLiveFreshnessProvider,
    budget: FBAXAcquisitionBudget, started: Double) async throws -> FBSimulatorAXTargetValidation {
    var confirmedRoots: [FBSimulatorAXNode]?
    var confirmedPID: Int32?
    do {
      try budget.check(); try Task.checkCancellation()
      guard let first = initial.roots.first else { throw FBSimulatorAXTargetError.targetMismatch }
      try initialProof.requireSuccess(node: first)
      let target = try FBAXOpaqueFrameTapRules.validateAuthority(original: original, fresh: fresh,
        expected: reference.node, selector: selector, point: point, observation: observation)
      let counts = try FBAXOpaqueFrameTapRules.keyCounts(in: fresh.roots, metadata: fresh.nativeIdentityMetadata)
      guard try FBAXOpaqueFrameTapRules.relationship(pointRoots: initial.roots, expectedPID: expectedPID,
        hitPID: initialPID, target: target, point: point, counts: counts) == .unmapped else {
        throw FBSimulatorAXTargetError.targetMismatch
      }
      try provider.validateCurrentRevision(expected: observation)
      let request = FBAXTranslationRequest(kind: .point(nativePoint), pointDisplayID: observation.axDisplayID,
        displayContext: observation.displayContext)
      request.acquisitionBudget = budget
      let proof = FBAXOpaquePointReadSuccess(token: request.token, point: nativePoint,
        displayID: observation.axDisplayID, expectedPID: expectedPID)
      request.opaquePointReadSuccess = proof
      let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
      let handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
      defer { handle.close() }
      let confirmed = try serialize(handle, observation: observation, remoteContentOptions: nil, includeNativeIdentity: true)
      confirmedRoots = confirmed.roots; confirmedPID = handle.acquisitionPID
      guard let second = confirmed.roots.first else { throw FBSimulatorAXTargetError.targetMismatch }
      try proof.requireSuccess(node: second)
      try FBAXOpaqueFrameTapRules.requireStableUnmappedPoint(initial.roots, confirmed.roots,
        expectedPID: expectedPID, firstPID: initialPID, secondPID: handle.acquisitionPID,
        target: target, point: point, counts: counts)
      try budget.check(); try provider.validateCurrentRevision(expected: observation)
      try admission.validate(roots: fresh.roots, nativeIdentityMetadata: fresh.nativeIdentityMetadata,
        target: target, point: point, observation: observation)
      try budget.check(); try Task.checkCancellation()
      let finalRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      finalRequest.acquisitionBudget = budget
      let final = try await commands.accessibilityElementForAcquisition(request: finalRequest, worker: self)
      let finalPID = final.acquisitionPID; final.close()
      guard finalPID == expectedPID else { throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: finalPID) }
      try budget.check(); try Task.checkCancellation(); try provider.validateCurrentRevision(expected: observation)
      return .init(startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime,
        expectedPID: expectedPID, hitPID: initialPID, frontmostPID: finalPID, pointX: point.x, pointY: point.y,
        hit: first, confirmedHit: second, confirmedHitPID: handle.acquisitionPID,
        matchKind: "freshOpaqueFrameUnmappedPoint", verifiedTarget: target,
        relationshipTree: fresh.roots, nativeSwitchProof: nil)
    } catch {
      throw FBSimulatorAXTargetHitFailure(expectedPID: expectedPID, hitPID: initialPID,
        roots: initial.roots, freshRoots: fresh.roots, confirmedRoots: confirmedRoots,
        confirmedHitPID: confirmedPID, reason: String(reflecting: error))
    }
  }
}
