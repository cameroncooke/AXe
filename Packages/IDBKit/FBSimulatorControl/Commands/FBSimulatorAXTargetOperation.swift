import Foundation
import CoreGraphics
import Darwin
import ObjectiveC

/// Runs once inside the session's input reservation, after its full context read.
/// It validates only; it must not call back into the same HID session.
public protocol FBSimulatorHIDInputAdmissionGuard: Sendable {
  func validate(observation: FBSimulatorHIDSessionObservation,
                firstEvent: FBSimulatorHIDEvent) async throws
}

public enum FBSimulatorAXTargetError: Error, Sendable {
  case busy, closed, alreadyValidated, invalidPoint, wrongFirstEvent
  case wrongPID(expected: Int32, actual: Int32)
  case targetMismatch, frameChanged
}

public struct FBSimulatorAXTargetOpenFailure: Error, Sendable {
  public let acquisition: FBSimulatorAXAcquisition
  public let failureDescription: String?
}

public struct FBSimulatorAXTargetHitFailure: Error, Encodable, Sendable {
  public let expectedPID: Int32
  public let hitPID: Int32
  public let roots: [FBSimulatorAXNode]
  public let freshRoots: [FBSimulatorAXNode]?
  public let confirmedRoots: [FBSimulatorAXNode]?
  public let confirmedHitPID: Int32?
  public let reason: String
}

public struct FBSimulatorAXTargetValidation: Encodable, Sendable {
  public let startedUptime: Double
  public let finishedUptime: Double
  public let expectedPID: Int32
  public let hitPID: Int32
  public let frontmostPID: Int32
  public let pointX: Double
  public let pointY: Double
  public let hit: FBSimulatorAXNode
  public let confirmedHit: FBSimulatorAXNode?
  public let confirmedHitPID: Int32?
  public let matchKind: String
  public let verifiedTarget: FBSimulatorAXNode
  public let relationshipTree: [FBSimulatorAXNode]?
  public let nativeSwitchProof: FBSimulatorAXNativeSwitchProof?
}

/// One explicit operation owns acquisition and final target validation across awaits.
/// close() is required after the HID operation has completed. A reference must not
/// survive a device/app transition. This reservation covers this new API, not legacy
/// callers which invoke snapshot/read/point APIs directly in the same process.
public actor FBSimulatorAXTargetOperation: FBSimulatorHIDInputAdmissionGuard {
  public let acquisition: FBSimulatorAXAcquisition
  public let snapshot: FBSimulatorAXSnapshot
  public let reference: FBSimulatorAXReference
  public let point: CGPoint
  private let simulator: FBSimulator
  private let provider: any FBSimulatorHIDLiveFreshnessProvider
  private let expectedPID: Int32
  private let selector: FBSimulatorAXSelector
  private let budget: FBAXAcquisitionBudget
  private let checkBoxChild: FBAXCheckBoxChildSelection?
  private let opaqueFrameTapAdmission: (any FBSimulatorAXOpaqueFrameTapAdmissionGuard)?
  private var aliasTapSelection: FBAXAliasTapSelection?
  private var reservation: FBAXTargetReservation?
  private var validating = false
  private var consumed = false
  private var validation: FBSimulatorAXTargetValidation?
  private var failure: String?
  private var rejectedHit: FBSimulatorAXTargetHitFailure?

  private init(simulator: FBSimulator, provider: any FBSimulatorHIDLiveFreshnessProvider,
               expectedPID: Int32, selector: FBSimulatorAXSelector,
               acquisition: FBSimulatorAXAcquisition, snapshot: FBSimulatorAXSnapshot,
               reference: FBSimulatorAXReference, point: CGPoint,
               budget: FBAXAcquisitionBudget, reservation: FBAXTargetReservation,
               checkBoxChild: FBAXCheckBoxChildSelection?,
               opaqueFrameTapAdmission: (any FBSimulatorAXOpaqueFrameTapAdmissionGuard)?) {
    self.simulator = simulator; self.provider = provider; self.expectedPID = expectedPID
    self.selector = selector; self.acquisition = acquisition; self.snapshot = snapshot
    self.reference = reference; self.point = point; self.budget = budget; self.reservation = reservation
    self.checkBoxChild = checkBoxChild
    self.opaqueFrameTapAdmission = opaqueFrameTapAdmission
  }

  /// The optional point permits an explicit hit location. The final hit must still
  /// match the selected node; supplying a point cannot bypass the target check.
  public static func open(for simulator: FBSimulator, expectedPID: Int32,
                          selector: FBSimulatorAXSelector,
                          observation: FBSimulatorHIDSessionObservation,
                          freshnessProvider: any FBSimulatorHIDLiveFreshnessProvider,
                          policy: FBSimulatorAXAcquisitionPolicy,
                          point: CGPoint? = nil) async throws -> FBSimulatorAXTargetOperation {
    try await open(for: simulator, expectedPID: expectedPID, selector: selector,
      observation: observation, freshnessProvider: freshnessProvider, policy: policy,
      includeNativeIdentity: false, point: point)
  }

  public static func open(for simulator: FBSimulator, expectedPID: Int32,
                          selector: FBSimulatorAXSelector,
                          observation: FBSimulatorHIDSessionObservation,
                          freshnessProvider: any FBSimulatorHIDLiveFreshnessProvider,
                          policy: FBSimulatorAXAcquisitionPolicy, includeNativeIdentity: Bool,
                          point: CGPoint? = nil) async throws -> FBSimulatorAXTargetOperation {
    try await open(for: simulator, expectedPID: expectedPID, selector: selector,
      observation: observation, freshnessProvider: freshnessProvider, policy: policy,
      includeNativeIdentity: includeNativeIdentity, opaqueFrameTapAdmission: nil, point: point)
  }

  /// Only the host's explicit physical single-tap path installs this pure guard.
  public static func open(for simulator: FBSimulator, expectedPID: Int32,
                          selector: FBSimulatorAXSelector,
                          observation: FBSimulatorHIDSessionObservation,
                          freshnessProvider: any FBSimulatorHIDLiveFreshnessProvider,
                          policy: FBSimulatorAXAcquisitionPolicy, includeNativeIdentity: Bool,
                          opaqueFrameTapAdmission: (any FBSimulatorAXOpaqueFrameTapAdmissionGuard)?,
                          point: CGPoint? = nil) async throws -> FBSimulatorAXTargetOperation {
    try await openCore(for: simulator, expectedPID: expectedPID, selector: selector,
      observation: observation, freshnessProvider: freshnessProvider, policy: policy,
      includeNativeIdentity: includeNativeIdentity, opaqueFrameTapAdmission: opaqueFrameTapAdmission,
      point: point, allowConsistentAliases: false)
  }

  /// Explicit single-tap route. Original singleton selection and validation stay unchanged.
  public static func openForNativeObjectTap(for simulator: FBSimulator, expectedPID: Int32,
    selector: FBSimulatorAXSelector, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDLiveFreshnessProvider,
    policy: FBSimulatorAXAcquisitionPolicy,
    opaqueFrameTapAdmission: (any FBSimulatorAXOpaqueFrameTapAdmissionGuard)?) async throws -> FBSimulatorAXTargetOperation {
    guard selector.usesNativeIdentity else { throw FBSimulatorAXSnapshotError.invalidSelection }
    return try await openCore(for: simulator, expectedPID: expectedPID, selector: selector,
      observation: observation, freshnessProvider: freshnessProvider, policy: policy,
      includeNativeIdentity: true, opaqueFrameTapAdmission: opaqueFrameTapAdmission,
      point: nil, allowConsistentAliases: true)
  }

  private static func openCore(for simulator: FBSimulator, expectedPID: Int32,
    selector: FBSimulatorAXSelector, observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDLiveFreshnessProvider,
    policy: FBSimulatorAXAcquisitionPolicy, includeNativeIdentity: Bool,
    opaqueFrameTapAdmission: (any FBSimulatorAXOpaqueFrameTapAdmissionGuard)?,
    point: CGPoint?, allowConsistentAliases: Bool) async throws -> FBSimulatorAXTargetOperation {
    try selector.validate()
    guard opaqueFrameTapAdmission == nil || selector.usesNativeIdentity else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    guard expectedPID > 0 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    if case .nativeObject(let identity, _) = selector, identity.pid != expectedPID {
      throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: identity.pid)
    }
    let reservation = try FBAXTargetReservation.acquire()
    let budget = FBAXAcquisitionBudget(seconds: policy.timeoutSeconds)
    return try await withTaskCancellationHandler(operation: {
      let acquisition = await FBSimulatorAXWorker.shared.acquire(for: simulator,
        expectedPID: expectedPID, observation: observation, provider: freshnessProvider,
        policy: policy, budget: budget, includeNativeIdentity: includeNativeIdentity || selector.usesNativeIdentity)
      guard acquisition.outcome == .ready, let snapshot = acquisition.snapshot else {
        throw FBSimulatorAXTargetOpenFailure(acquisition: acquisition, failureDescription: acquisition.failureDescription)
      }
      do {
        try budget.check()
        let alias = allowConsistentAliases
          ? try FBAXAliasTapSelection.select(in: snapshot, selector: selector, expectedPID: expectedPID) : nil
        let reference: FBSimulatorAXReference
        if let alias {
          try FBSimulatorAXSnapshot.requireSame(observation, try await freshnessProvider.observation())
          reference = FBSimulatorAXReference(node: alias.node, observation: observation, snapshotID: snapshot.snapshotID)
        } else {
          reference = try await snapshot.resolve(selector, freshnessProvider: freshnessProvider)
        }
        try budget.check()
        guard let frame = reference.node.frame else { throw FBSimulatorAXTargetError.invalidPoint }
        if selector.usesNativeIdentity {
          try FBAXTargetValidationRules.opaqueTarget(reference.node, expectedPID: expectedPID,
            context: observation.displayContext)
        }
        let child: FBAXCheckBoxChildSelection?
        if point == nil && alias == nil {
          child = try FBAXCheckBoxChildSelection.select(in: snapshot.roots,
            parent: reference.node, selector: selector, expectedPID: expectedPID,
            context: observation.displayContext)
        } else {
          child = nil
        }
        let chosen = try FBAXTargetValidationRules.point(point ?? child?.point,
          frame: frame, context: observation.displayContext)
        try Task.checkCancellation()
        let operation = FBSimulatorAXTargetOperation(simulator: simulator, provider: freshnessProvider,
          expectedPID: expectedPID, selector: selector, acquisition: acquisition,
          snapshot: snapshot, reference: reference, point: chosen, budget: budget,
          reservation: reservation, checkBoxChild: child, opaqueFrameTapAdmission: opaqueFrameTapAdmission)
        if let alias { await operation.installAliasTapSelection(alias) }
        return operation
      } catch {
        throw FBSimulatorAXTargetOpenFailure(acquisition: acquisition, failureDescription: String(reflecting: error))
      }
    }, onCancel: { budget.stop(.cancelled) })
  }

  private func installAliasTapSelection(_ selection: FBAXAliasTapSelection?) {
    aliasTapSelection = selection
  }

  public func validate(observation: FBSimulatorHIDSessionObservation,
                       firstEvent: FBSimulatorHIDEvent) async throws {
    guard reservation != nil else { throw FBSimulatorAXTargetError.closed }
    guard !validating else { throw FBSimulatorAXTargetError.busy }
    guard !consumed else { throw FBSimulatorAXTargetError.alreadyValidated }
    validating = true; consumed = true
    defer { validating = false }
    do {
      try FBSimulatorAXSnapshot.requireSame(snapshot.observation, observation)
      try FBAXTargetValidationRules.firstEvent(firstEvent, point: point)
      try budget.check()
      validation = try await withTaskCancellationHandler(operation: {
        if let aliasTapSelection {
          return try await FBSimulatorAXWorker.shared.validateAliasTap(for: simulator,
            selection: aliasTapSelection, original: snapshot, point: point,
            observation: observation, provider: provider, budget: budget)
        }
        return try await FBSimulatorAXWorker.shared.validateTarget(for: simulator,
          expectedPID: expectedPID, selector: selector, reference: reference, point: point,
          observation: observation, provider: provider, budget: budget, checkBoxChild: checkBoxChild,
          includeNativeIdentity: snapshot.nativeIdentityMetadata != nil,
          opaqueFrameTapAdmission: opaqueFrameTapAdmission, originalSnapshot: snapshot)
      }, onCancel: { budget.stop(.cancelled) })
      try budget.check()
      try Task.checkCancellation()
    } catch {
      failure = String(reflecting: error)
      rejectedHit = error as? FBSimulatorAXTargetHitFailure
      throw error
    }
  }

  public func validationReceipt() -> FBSimulatorAXTargetValidation? { validation }
  public func failureDescription() -> String? { failure }
  public func rejectedHitReceipt() -> FBSimulatorAXTargetHitFailure? { rejectedHit }

  /// The caller must first await execute/cancellation and session close.
  /// A concurrent close cannot release the AX reservation while validation runs.
  public func close() throws {
    guard !validating else { throw FBSimulatorAXTargetError.busy }
    reservation = nil
  }
}

/// The lock protects the process-wide reservation, not AX execution. Its lease is
/// immutable and release is synchronous, including failed opens and deallocation.
final class FBAXTargetReservation: @unchecked Sendable {
  private static let lock = NSLock()
  private static var owner: UUID?
  private let identifier: UUID
  private init(_ identifier: UUID) { self.identifier = identifier }
  static func acquire() throws -> FBAXTargetReservation {
    lock.lock(); defer { lock.unlock() }
    guard owner == nil else { throw FBSimulatorAXTargetError.busy }
    let identifier = UUID(); owner = identifier
    return FBAXTargetReservation(identifier)
  }
  deinit {
    Self.lock.lock(); defer { Self.lock.unlock() }
    if Self.owner == identifier { Self.owner = nil }
  }
}

enum FBAXTargetValidationRules {
  static func point(_ supplied: CGPoint?, frame: CGRect,
                    context: FBSimulatorHIDDisplayContext) throws -> CGPoint {
    let values = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
    guard values.allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else {
      throw FBSimulatorAXTargetError.invalidPoint
    }
    let result = supplied ?? CGPoint(x: frame.midX, y: frame.midY)
    let size = context.logicalSize
    guard result.x.isFinite, result.y.isFinite, result.x >= 0, result.y >= 0,
          result.x < size.width, result.y < size.height else { throw FBSimulatorAXTargetError.invalidPoint }
    return result
  }
  static func firstEvent(_ event: FBSimulatorHIDEvent, point: CGPoint) throws {
    guard case let .touch(.down, x, y) = event, x == point.x, y == point.y else {
      throw FBSimulatorAXTargetError.wrongFirstEvent
    }
  }
  static func hit(_ roots: [FBSimulatorAXNode], expected: FBSimulatorAXNode,
                  selector: FBSimulatorAXSelector, expectedPID: Int32,
                  hitPID: Int32, point: CGPoint) throws -> FBSimulatorAXNode {
    guard hitPID == expectedPID else { throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: hitPID) }
    // A descendant of an unrelated container is not a successful point hit.
    guard roots.count == 1, let hit = roots.first, hit.pid == expectedPID else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    if selector.usesNativeIdentity, !sameOpaqueNode(hit, expected) {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    guard selector.matches(hit),
          hit.identifier == expected.identifier, hit.type == expected.type else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    guard let frame = hit.frame, frame == expected.frame else { throw FBSimulatorAXTargetError.frameChanged }
    guard frame.contains(point) else { throw FBSimulatorAXTargetError.targetMismatch }
    return hit
  }

  /// Exact structural evidence, not a label-to-ancestor heuristic. The signature
  /// must be unique in both the selected subtree and the complete fresh tree.
  static func descendantHit(_ roots: [FBSimulatorAXNode], freshRoots: [FBSimulatorAXNode],
                            expected: FBSimulatorAXNode, selector: FBSimulatorAXSelector,
                            expectedPID: Int32, hitPID: Int32, point: CGPoint) throws -> FBSimulatorAXNode {
    guard hitPID == expectedPID else { throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: hitPID) }
    guard roots.count == 1, let actual = roots.first, actual.pid == expectedPID,
          let actualType = actual.type, !actualType.isEmpty else { throw FBSimulatorAXTargetError.targetMismatch }
    try selector.validate()
    let all = freshRoots.flatMap(\.flattened)
    if case .nativeObject(let identity, let type) = selector {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: freshRoots, identity: identity, elementType: type)
    }
    let targets = all.filter { selector.matches($0) }
    guard !targets.isEmpty else { throw FBSimulatorAXSnapshotError.notFound }
    guard targets.count == 1 else { throw FBSimulatorAXSnapshotError.ambiguous(count: targets.count) }
    let target = targets[0]
    guard (selector.usesNativeIdentity ? sameOpaqueNode(target, expected) : sameSignature(target, expected)), target.pid == expectedPID,
          target.type == "Button", let frame = target.frame, let childFrame = actual.frame,
          validFrame(frame), validFrame(childFrame), frame.contains(point),
          childFrame.contains(point), frame.contains(childFrame) else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    let descendants = target.children.flatMap(\.flattened).filter {
      selector.usesNativeIdentity ? sameOpaqueNode($0, actual) : sameSignature($0, actual)
    }
    let globalMatches = all.filter {
      selector.usesNativeIdentity ? $0.nativeIdentity == actual.nativeIdentity : sameSignature($0, actual)
    }
    guard descendants.count == 1, globalMatches.count == 1 else { throw FBSimulatorAXTargetError.targetMismatch }
    return target
  }
  /// This only selects the candidate. Native token ancestry must prove the
  /// relationship; frame containment alone never admits a switch tap.
  static func nativeSwitchTarget(_ roots: [FBSimulatorAXNode], freshRoots: [FBSimulatorAXNode],
    expected: FBSimulatorAXNode, selector: FBSimulatorAXSelector,
    expectedPID: Int32, hitPID: Int32, point: CGPoint) throws -> FBSimulatorAXNode {
    guard hitPID == expectedPID, roots.count == 1, let hit = roots.first,
          hit.pid == expectedPID, hit.type == "Group", hit.identifier?.isEmpty != false,
          let hitFrame = hit.frame, validFrame(hitFrame), hitFrame.contains(point) else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    try selector.validate()
    let matches = freshRoots.flatMap(\.flattened).filter { selector.matches($0) }
    guard matches.count == 1, let target = matches.first, sameSignature(target, expected),
          target.type == "CheckBox", target.pid == expectedPID, target.identifier?.isEmpty == false,
          let frame = target.frame, validFrame(frame), frame.contains(point) else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    return target
  }

  static func opaqueTarget(_ node: FBSimulatorAXNode, expectedPID: Int32,
    context: FBSimulatorHIDDisplayContext) throws {
    guard let key = node.nativeIdentity, key.pid == expectedPID, node.pid == expectedPID,
          key.objectID > 0, node.enabled == true, node.hidden == false,
          let frame = node.frame, validFrame(frame),
          CGRect(origin: .zero, size: context.logicalSize).contains(frame) else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
  }

  static func sameOpaqueNode(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode) -> Bool {
    guard let identity = left.nativeIdentity, identity.pid > 0, identity.objectID > 0 else { return false }
    return right.nativeIdentity == identity && left.pid == identity.pid && right.pid == identity.pid
      && sameSignature(left, right) && left.role == right.role && left.subrole == right.subrole
      && left.roleDescription == right.roleDescription && left.value == right.value && left.focused == right.focused
      && left.frame.map(validFrame) == true && right.frame.map(validFrame) == true
      && left.enabled == true && right.enabled == true && left.hidden == false && right.hidden == false
  }

  static func sameSignature(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode) -> Bool {
    left.pid == right.pid && left.type == right.type && left.identifier == right.identifier &&
      left.label == right.label && left.frame == right.frame
  }
  private static func validFrame(_ frame: CGRect) -> Bool {
    [frame.origin.x,frame.origin.y,frame.size.width,frame.size.height].allSatisfy(\.isFinite) &&
      frame.size.width > 0 && frame.size.height > 0
  }
}

extension FBSimulatorAXWorker {
  // Keep the original overload for existing native callers and exported symbols.
  func validateTarget(for simulator: FBSimulator, expectedPID: Int32,
                      selector: FBSimulatorAXSelector, reference: FBSimulatorAXReference,
                      point: CGPoint, observation: FBSimulatorHIDSessionObservation,
                      provider: any FBSimulatorHIDLiveFreshnessProvider,
                      budget: FBAXAcquisitionBudget) async throws -> FBSimulatorAXTargetValidation {
    try await validateTarget(for: simulator, expectedPID: expectedPID, selector: selector,
      reference: reference, point: point, observation: observation, provider: provider,
      budget: budget, checkBoxChild: nil)
  }

  func validateTarget(for simulator: FBSimulator, expectedPID: Int32,
                      selector: FBSimulatorAXSelector, reference: FBSimulatorAXReference,
                      point: CGPoint, observation: FBSimulatorHIDSessionObservation,
                      provider: any FBSimulatorHIDLiveFreshnessProvider,
                      budget: FBAXAcquisitionBudget,
                      checkBoxChild: FBAXCheckBoxChildSelection?) async throws -> FBSimulatorAXTargetValidation {
    try await validateTarget(for: simulator, expectedPID: expectedPID, selector: selector,
      reference: reference, point: point, observation: observation, provider: provider,
      budget: budget, checkBoxChild: checkBoxChild, includeNativeIdentity: false)
  }

  func validateTarget(for simulator: FBSimulator, expectedPID: Int32,
                      selector: FBSimulatorAXSelector, reference: FBSimulatorAXReference,
                      point: CGPoint, observation: FBSimulatorHIDSessionObservation,
                      provider: any FBSimulatorHIDLiveFreshnessProvider,
                      budget: FBAXAcquisitionBudget,
                      checkBoxChild: FBAXCheckBoxChildSelection?, includeNativeIdentity: Bool) async throws -> FBSimulatorAXTargetValidation {
    try await validateTarget(for: simulator, expectedPID: expectedPID, selector: selector,
      reference: reference, point: point, observation: observation, provider: provider, budget: budget,
      checkBoxChild: checkBoxChild, includeNativeIdentity: includeNativeIdentity,
      opaqueFrameTapAdmission: nil, originalSnapshot: nil)
  }

  func validateTarget(for simulator: FBSimulator, expectedPID: Int32,
                      selector: FBSimulatorAXSelector, reference: FBSimulatorAXReference,
                      point: CGPoint, observation: FBSimulatorHIDSessionObservation,
                      provider: any FBSimulatorHIDLiveFreshnessProvider,
                      budget: FBAXAcquisitionBudget,
                      checkBoxChild: FBAXCheckBoxChildSelection?, includeNativeIdentity: Bool,
                      opaqueFrameTapAdmission: (any FBSimulatorAXOpaqueFrameTapAdmissionGuard)?,
                      originalSnapshot: FBSimulatorAXSnapshot?) async throws -> FBSimulatorAXTargetValidation {
    try budget.check(); try Task.checkCancellation()
    let started = ProcessInfo.processInfo.systemUptime
    // execute already completed the authoritative read. Do not put another slow
    // full-context read between the final hit/PID check and the first input.
    try provider.validateCurrentRevision(expected: observation)
    let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
    try budget.check()
    let rootRequest = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    rootRequest.acquisitionBudget = budget
    let root = try await commands.accessibilityElementForAcquisition(request: rootRequest, worker: self)
    let rootPID = root.acquisitionPID; root.close()
    guard rootPID == expectedPID else { throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: rootPID) }
    try budget.check()
    let transform = FBAXTranslationRequest(kind: .point(point), pointDisplayID: observation.axDisplayID,
      displayContext: observation.displayContext)
    let native = try transform.nativePoint(from: point)
    let request = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
      displayContext: observation.displayContext)
    request.acquisitionBudget = budget
    let pointSuccess: FBAXOpaquePointReadSuccess?
    if selector.usesNativeIdentity, opaqueFrameTapAdmission != nil {
      pointSuccess = FBAXOpaquePointReadSuccess(token: request.token, point: native,
        displayID: observation.axDisplayID, expectedPID: expectedPID)
      request.opaquePointReadSuccess = pointSuccess
    } else { pointSuccess = nil }
    let handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
    defer { handle.close() }
    let hitPID = handle.acquisitionPID
    let result = try serialize(handle, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity || selector.usesNativeIdentity)
    try budget.check()
    if let checkBoxChild {
      return try await validateCheckBoxChild(for: simulator, expectedPID: expectedPID, selector: selector,
        selection: checkBoxChild, nativePoint: native, initialHit: handle, initialSnapshot: result,
        observation: observation, provider: provider, budget: budget, started: started, includeNativeIdentity: includeNativeIdentity || selector.usesNativeIdentity)
    }
    if reference.buttonLeafChainCount > 1 {
      return try await validateButtonLeafTarget(for: simulator, expectedPID: expectedPID, selector: selector,
        reference: reference, point: point, nativePoint: native, initialHit: handle, initialSnapshot: result,
        observation: observation, provider: provider, budget: budget, started: started,
        includeNativeIdentity: includeNativeIdentity)
    }
    let hit: FBSimulatorAXNode
    var target = reference.node
    var confirmedHit: FBSimulatorAXNode?
    var confirmedHitPID: Int32?
    var matchKind = "direct"
    var freshRoots: [FBSimulatorAXNode]?
    var confirmedRoots: [FBSimulatorAXNode]?
    var nativeSwitch: FBAXNativeSwitchClient?
    var nativeSwitchPoint: FBAXSimulatorDeviceToken?
    var nativeSwitchProof: FBSimulatorAXNativeSwitchProof?
    defer { nativeSwitch?.close() }
    do {
      do {
        hit = try FBAXTargetValidationRules.hit(result.roots, expected: reference.node,
          selector: selector, expectedPID: expectedPID, hitPID: hitPID, point: point)
        // The direct hit already passed the selector, PID, frame and point checks.
        target = hit
      } catch FBSimulatorAXTargetError.targetMismatch {
        // Only the mismatch path can establish a structural Button-child relation.
        // Wrong PID or changed direct-target frame retains the V14 rejection.
        let treeRequest = FBAXTranslationRequest(kind: .frontmostApplication,
          pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
        treeRequest.acquisitionBudget = budget
        let treeHandle = try await commands.accessibilityElementForAcquisition(request: treeRequest, worker: self)
        defer { treeHandle.close() }
        let treePID = treeHandle.acquisitionPID
        guard treePID == expectedPID else { throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: treePID) }
        let tree = try serialize(treeHandle, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity || selector.usesNativeIdentity)
        freshRoots = tree.roots
        if selector.usesNativeIdentity, tree.nativeIdentityMetadata?.complete != true {
          throw FBSimulatorAXSnapshotError.invalidSelection
        }
        try budget.check(); try Task.checkCancellation()
        if selector.usesNativeIdentity, let admission = opaqueFrameTapAdmission {
          let counts = try FBAXOpaqueFrameTapRules.keyCounts(in: tree.roots, metadata: tree.nativeIdentityMetadata)
          if try FBAXOpaqueFrameTapRules.relationship(pointRoots: result.roots, expectedPID: expectedPID,
            hitPID: hitPID, target: reference.node, point: point, counts: counts) == .unmapped {
            guard let originalSnapshot, let pointSuccess else { throw FBSimulatorAXTargetError.targetMismatch }
            return try await validateOpaqueFrameTap(for: simulator, expectedPID: expectedPID, selector: selector,
              reference: reference, point: point, nativePoint: native, original: originalSnapshot, fresh: tree,
              initial: result, initialPID: hitPID, initialProof: pointSuccess, admission: admission,
              observation: observation, provider: provider, budget: budget, started: started)
          }
        }
        if reference.node.type == "CheckBox" {
          guard !selector.usesNativeIdentity else { throw FBSimulatorAXTargetError.targetMismatch }
          target = try FBAXTargetValidationRules.nativeSwitchTarget(result.roots, freshRoots: tree.roots,
            expected: reference.node, selector: selector, expectedPID: expectedPID, hitPID: hitPID, point: point)
          guard let identifier = target.identifier, !identifier.isEmpty, let frame = target.frame else {
            throw FBSimulatorAXTargetError.targetMismatch
          }
          let token = try treeHandle.simulatorSwitchToken(identifier: identifier, frame: frame, pid: expectedPID, budget: budget)
          let pointToken = try handle.simulatorPointToken(budget: budget)
          let client = try FBAXNativeSwitchClient(simulator: simulator, identifier: identifier, frame: frame,
            displayID: observation.axDisplayID, token: token, budget: budget)
          nativeSwitch = client
          nativeSwitchPoint = pointToken
          nativeSwitchProof = try client.validate(pointToken: pointToken, point: point)
        } else {
          target = try FBAXTargetValidationRules.descendantHit(result.roots, freshRoots: tree.roots,
            expected: reference.node, selector: selector, expectedPID: expectedPID, hitPID: hitPID, point: point)
        }
        treeHandle.close()
        // A fresh tree cannot validate an old point hit by itself. Read the same
        // selected point once more and require the same complete signature.
        let confirmRequest = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
          displayContext: observation.displayContext)
        confirmRequest.acquisitionBudget = budget
        let confirmHandle = try await commands.accessibilityElementForAcquisition(request: confirmRequest, worker: self)
        defer { confirmHandle.close() }
        let confirmedPID = confirmHandle.acquisitionPID
        confirmedHitPID = confirmedPID
        let confirmation = try serialize(confirmHandle, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity || selector.usesNativeIdentity)
        confirmedRoots = confirmation.roots
        try budget.check(); try Task.checkCancellation()
        guard confirmation.roots.count == 1, let confirmed = confirmation.roots.first,
              let first = result.roots.first,
              (selector.usesNativeIdentity ? FBAXTargetValidationRules.sameOpaqueNode(first, confirmed)
                : FBAXTargetValidationRules.sameSignature(first, confirmed)) else {
          throw FBSimulatorAXTargetError.targetMismatch
        }
        if let nativeSwitch {
          guard confirmedPID == expectedPID,
                let initial = nativeSwitchPoint,
                try confirmHandle.simulatorPointToken(budget: budget) == initial else {
            throw FBSimulatorAXTargetError.targetMismatch
          }
          nativeSwitchProof = try nativeSwitch.validate(pointToken: initial, point: point)
          matchKind = "nativeCheckBoxAncestor"
        } else {
          _ = try FBAXTargetValidationRules.descendantHit(confirmation.roots, freshRoots: tree.roots,
            expected: reference.node, selector: selector, expectedPID: expectedPID, hitPID: confirmedPID, point: point)
          matchKind = "uniqueButtonDescendant"
        }
        hit = first; confirmedHit = confirmed
        confirmHandle.close()
      }
    } catch let failure as FBSimulatorAXTargetHitFailure { throw failure }
    catch {
      throw FBSimulatorAXTargetHitFailure(expectedPID: expectedPID, hitPID: hitPID,
        roots: result.roots, freshRoots: freshRoots, confirmedRoots: confirmedRoots, confirmedHitPID: confirmedHitPID, reason: String(reflecting: error))
    }
    let verify = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    verify.acquisitionBudget = budget
    let verified = try await commands.accessibilityElementForAcquisition(request: verify, worker: self)
    let frontmostPID = verified.acquisitionPID; verified.close()
    guard frontmostPID == expectedPID else { throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: frontmostPID) }
    try budget.check(); try Task.checkCancellation()
    try provider.validateCurrentRevision(expected: observation)
    return .init(startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime,
      expectedPID: expectedPID, hitPID: hitPID, frontmostPID: frontmostPID,
      pointX: point.x, pointY: point.y, hit: hit, confirmedHit: confirmedHit, confirmedHitPID: confirmedHitPID,
      matchKind: matchKind, verifiedTarget: target, relationshipTree: freshRoots, nativeSwitchProof: nativeSwitchProof)
  }
}


extension FBSimulatorAXWorker {
  /// The chain is exceptional selection evidence, not a duplicate-object alias.
  /// Keep current native root/point requests owned until all identity checks finish.
  private func validateButtonLeafTarget(for simulator: FBSimulator, expectedPID: Int32,
    selector: FBSimulatorAXSelector, reference: FBSimulatorAXReference, point: CGPoint, nativePoint: CGPoint,
    initialHit: FBAccessibilityElement, initialSnapshot: FBSimulatorAXSnapshot,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDLiveFreshnessProvider,
    budget: FBAXAcquisitionBudget, started: Double, includeNativeIdentity: Bool) async throws -> FBSimulatorAXTargetValidation {
    var freshRoots: [FBSimulatorAXNode]?
    var confirmedRoots: [FBSimulatorAXNode]?
    var confirmedPID: Int32?
    do {
      try budget.check(); try Task.checkCancellation()
      try provider.validateCurrentRevision(expected: observation)
      let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
      let request = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      request.acquisitionBudget = budget
      let root = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
      defer { root.close() }
      guard root.acquisitionPID == expectedPID else {
        throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: root.acquisitionPID)
      }
      let tree = try serialize(root, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity)
      freshRoots = tree.roots
      guard let chain = FBSimulatorAXButtonLeafSelection.resolve(in: tree.roots, selector: selector),
            chain.matchingIndices.count == reference.buttonLeafChainCount,
            FBAXTargetValidationRules.sameSignature(chain.node, reference.node),
            chain.node.role == reference.node.role, chain.node.subrole == reference.node.subrole,
            chain.node.value == reference.node.value else { throw FBSimulatorAXTargetError.targetMismatch }
      let admission = try root.buttonLeafAdmission(expected: chain.node,
        matchingCount: reference.buttonLeafChainCount, budget: budget)
      let hit = try FBAXTargetValidationRules.hit(initialSnapshot.roots, expected: chain.node,
        selector: selector, expectedPID: expectedPID, hitPID: initialHit.acquisitionPID, point: point)
      try initialHit.validateButtonLeafPoint(admission, orientedPoint: point)
      try budget.check(); try provider.validateCurrentRevision(expected: observation)
      let confirmRequest = FBAXTranslationRequest(kind: .point(nativePoint), pointDisplayID: observation.axDisplayID,
        displayContext: observation.displayContext)
      confirmRequest.acquisitionBudget = budget
      let confirmation = try await commands.accessibilityElementForAcquisition(request: confirmRequest, worker: self)
      defer { confirmation.close() }
      confirmedPID = confirmation.acquisitionPID
      let confirmed = try serialize(confirmation, observation: observation, remoteContentOptions: nil, includeNativeIdentity: includeNativeIdentity)
      confirmedRoots = confirmed.roots
      let confirmedHit = try FBAXTargetValidationRules.hit(confirmed.roots, expected: chain.node,
        selector: selector, expectedPID: expectedPID, hitPID: confirmation.acquisitionPID, point: point)
      try confirmation.validateButtonLeafPoint(admission, orientedPoint: point)
      try budget.check(); try provider.validateCurrentRevision(expected: observation)
      let verifyRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      verifyRequest.acquisitionBudget = budget
      let verify = try await commands.accessibilityElementForAcquisition(request: verifyRequest, worker: self)
      let frontmostPID = verify.acquisitionPID
      verify.close()
      guard frontmostPID == expectedPID else {
        throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: frontmostPID)
      }
      try admission.requireCurrentLeaf()
      try budget.check(); try Task.checkCancellation()
      try provider.validateCurrentRevision(expected: observation)
      return .init(startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime,
        expectedPID: expectedPID, hitPID: initialHit.acquisitionPID, frontmostPID: frontmostPID,
        pointX: point.x, pointY: point.y, hit: hit, confirmedHit: confirmedHit,
        confirmedHitPID: confirmation.acquisitionPID, matchKind: "singleChildButtonLeaf",
        verifiedTarget: chain.node, relationshipTree: tree.roots, nativeSwitchProof: nil)
    } catch {
      throw FBSimulatorAXTargetHitFailure(expectedPID: expectedPID, hitPID: initialHit.acquisitionPID,
        roots: initialSnapshot.roots, freshRoots: freshRoots, confirmedRoots: confirmedRoots,
        confirmedHitPID: confirmedPID, reason: String(reflecting: error))
    }
  }
}

// Native switch ancestry stays on the AX worker. Device tokens are values, not
// cached platform objects, and can only be used inside the current admission.
struct FBAXSimulatorDeviceToken: Equatable, Sendable {
  let pid: Int32
  let element: UInt64
  let elementID: UInt64

  init(data: Data, expectedPID: Int32) throws {
    guard data.count == 20 else { throw FBAXNativeSwitchError.rejected("Unsupported simulator token length") }
    pid = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }.littleEndian
    element = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }.littleEndian
    elementID = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) }.littleEndian
    guard pid == expectedPID, pid > 0, element > 0, elementID > 0 else {
      throw FBAXNativeSwitchError.rejected("Simulator token identity differs")
    }
  }
}

enum FBAXNativeSwitchError: Error {
  case rejected(String)
}

public struct FBSimulatorAXNativeSwitchProof: Encodable, Sendable {
  public let pid: Int32
  public let displayID: UInt32
  public let windowContextID: UInt64
  public let ancestorCount: Int
}

/// Owns one native read session. It never asks Apple's global point lookup to
/// choose a display: both identities come from the selected AXP request tokens.
private final class FBAXNativeSwitchClient {
  private typealias Factory = @convention(c) (AnyClass, Selector, NSObject) -> Unmanaged<NSObject>?
  private typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>
  private typealias ObjectGet = @convention(c) (NSObject, Selector) -> Unmanaged<NSObject>?
  private typealias UIntGet = @convention(c) (NSObject, Selector) -> UInt64
  private typealias PIDGet = @convention(c) (NSObject, Selector) -> Int32
  private typealias PIDFactory = @convention(c) (AnyClass, Selector, Int32) -> Unmanaged<NSObject>?
  private typealias BoolFactory = @convention(c) (AnyClass, Selector, Bool) -> Unmanaged<NSObject>?
  private typealias SnapshotCall = @convention(c) (NSObject, Selector, NSObject, NSArray, NSObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSObject>?
  private typealias AttributeCall = @convention(c) (NSObject, Selector, NSObject, NSArray, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSObject>?
  private typealias NativeInit = @convention(c) (NSObject, Selector, NSObject?, UInt64, UInt64, Int32, UInt64, UInt64) -> Unmanaged<NSObject>?
  private typealias VoidCall = @convention(c) (NSObject, Selector) -> Void

  private let budget: FBAXAcquisitionBudget
  private let device: NSObject
  private let session: NSObject
  private let client: NSObject
  private let target: NSObject
  private let expectedPID: Int32
  private let identifier: String
  private let expectedFrame: CGRect
  private let displayID: UInt32
  private let windowContextID: NSNumber
  private let identityKind: UInt64
  private let origin: UInt64
  private let attributeNames: [NSString]
  private var closed = false

  private static func method(_ object: NSObject, _ name: String, _ encoding: String) throws -> IMP {
    try method(type(of: object), name, encoding, isClassMethod: false)
  }

  private static func method(_ cls: AnyClass, _ name: String, _ encoding: String, isClassMethod: Bool) throws -> IMP {
    let selector = NSSelectorFromString(name)
    let result = isClassMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector)
    guard let result, method_getTypeEncoding(result).map({ String(cString: $0) }) == encoding else {
      throw FBAXNativeSwitchError.rejected("Native method or ABI unavailable: " + name)
    }
    return method_getImplementation(result)
  }

  private static func object(_ receiver: NSObject, _ name: String) throws -> NSObject {
    let call = unsafeBitCast(try method(receiver, name, "@16@0:8"), to: ObjectGet.self)
    guard let value = call(receiver, NSSelectorFromString(name))?.takeUnretainedValue() else {
      throw FBAXNativeSwitchError.rejected("Native object unavailable: " + name)
    }
    return value
  }

  private static func number(_ receiver: NSObject, _ name: String) throws -> UInt64 {
    unsafeBitCast(try method(receiver, name, "Q16@0:8"), to: UIntGet.self)(receiver, NSSelectorFromString(name))
  }

  private static func pid(_ receiver: NSObject) throws -> Int32 {
    unsafeBitCast(try method(receiver, "processIdentifier", "i16@0:8"), to: PIDGet.self)(receiver, NSSelectorFromString("processIdentifier"))
  }

  private static func invalidate(_ session: NSObject) {
    guard let method = try? method(session, "invalidate", "v16@0:8") else { return }
    unsafeBitCast(method, to: VoidCall.self)(session, NSSelectorFromString("invalidate"))
  }

  init(simulator: FBSimulator, identifier: String, frame: CGRect,
       displayID: UInt32, token: FBAXSimulatorDeviceToken, budget: FBAXAcquisitionBudget) throws {
    try budget.check()
    try FBSimulatorControlFrameworkLoader.accessibilityAutomationFrameworks.loadPrivateFrameworks(simulator.logger)
    guard !identifier.isEmpty, let deviceClass = NSClassFromString("XCUIDevice") else {
      throw FBAXNativeSwitchError.rejected("Named native switch classes are unavailable")
    }
    let factory = try Self.method(deviceClass, "iOSDeviceForSimulatorDevice:", "@24@0:8@16", isClassMethod: true)
    guard let device = unsafeBitCast(factory, to: Factory.self)(deviceClass,
      NSSelectorFromString("iOSDeviceForSimulatorDevice:"), simulator.device)?.takeUnretainedValue(),
      try Self.object(device, "uniqueIdentifier").description.uppercased() == simulator.udid.uppercased() else {
      throw FBAXNativeSwitchError.rejected("Native device identity differs")
    }
    let session = try Self.object(device, "remoteAutomationSession")
    var transferred = false
    defer { if !transferred { Self.invalidate(session) } }
    let client = try Self.object(device, "accessibilityInterface")
    guard let elementClass = NSClassFromString("XCAccessibilityElement"),
          let snapshotClass = NSClassFromString("XCElementSnapshot") else {
      throw FBAXNativeSwitchError.rejected("Native accessibility classes unavailable")
    }
    let appFactory = try Self.method(elementClass, "elementWithProcessIdentifier:", "@20@0:8i16", isClassMethod: true)
    guard let application = unsafeBitCast(appFactory, to: PIDFactory.self)(elementClass,
      NSSelectorFromString("elementWithProcessIdentifier:"), token.pid)?.takeUnretainedValue() else {
      throw FBAXNativeSwitchError.rejected("Native application identity unavailable")
    }
    let attributeFactory = try Self.method(snapshotClass, "requiredAXAttributesForElementSnapshotHierarchyOnMacOS:", "@20@0:8B16", isClassMethod: true)
    guard let set = unsafeBitCast(attributeFactory, to: BoolFactory.self)(snapshotClass,
      NSSelectorFromString("requiredAXAttributesForElementSnapshotHierarchyOnMacOS:"), false)?.takeUnretainedValue() as? NSSet else {
      throw FBAXNativeSwitchError.rejected("Native snapshot attribute set unavailable")
    }
    let parameters = try Self.object(client, "defaultParameters")
    try budget.check()
    var snapshotError: NSError?
    let snapshotCall = unsafeBitCast(try Self.method(client, "requestSnapshotForElement:attributes:parameters:error:", "@48@0:8@16@24@32^@40"), to: SnapshotCall.self)
    guard let result = snapshotCall(client, NSSelectorFromString("requestSnapshotForElement:attributes:parameters:error:"), application,
      set.allObjects as NSArray, parameters, &snapshotError)?.takeUnretainedValue(), snapshotError == nil else {
      throw FBAXNativeSwitchError.rejected("Native snapshot failed: \(String(describing: snapshotError))")
    }
    try budget.check()
    guard try Self.number(Self.object(result, "runtimeIssues"), "count") == 0 else {
      throw FBAXNativeSwitchError.rejected("Native snapshot has runtime issues")
    }
    var found: [NSObject] = []
    var count = 0
    func walk(_ snapshot: NSObject, depth: Int) throws {
      try budget.check()
      guard depth <= 32, count < 512 else { throw FBAXNativeSwitchError.rejected("Native snapshot bound exceeded") }
      count += 1
      if try Self.object(snapshot, "identifier").description == identifier {
        // XCUIElementTypeSwitch is 40 in the installed public Apple header.
        guard try Self.number(snapshot, "elementType") == 40 else {
          throw FBAXNativeSwitchError.rejected("Native target is not a Switch")
        }
        found.append(try Self.object(snapshot, "accessibilityElement"))
      }
      guard let children = try Self.object(snapshot, "children") as? [NSObject] else {
        throw FBAXNativeSwitchError.rejected("Native snapshot children unavailable")
      }
      for child in children { try walk(child, depth: depth + 1) }
    }
    try walk(Self.object(result, "rootElementSnapshot"), depth: 0)
    guard found.count == 1, let target = found.first,
          try Self.pid(target) == token.pid,
          try Self.number(target, "elementOrHash") == token.element,
          try Self.number(target, "elementID") == token.elementID else {
      throw FBAXNativeSwitchError.rejected("Selected token differs from the independent native switch identity")
    }
    var names: [NSString] = []
    for symbol in ["XC_kAXXCAttributeParent", "XC_kAXXCAttributeFrame", "XC_kAXXCAttributeIdentifier", "XC_kAXXCAttributeWindowDisplayId", "XC_kAXXCAttributeWindowContextId"] {
      guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol),
            let name = address.assumingMemoryBound(to: NSString?.self).pointee else {
        throw FBAXNativeSwitchError.rejected("Native attribute constant unavailable: " + symbol)
      }
      names.append(name)
    }
    self.budget = budget; self.device = device; self.session = session
    self.client = client; self.target = target; self.expectedPID = token.pid
    self.identifier = identifier; self.expectedFrame = frame; self.displayID = displayID
    self.attributeNames = names
    identityKind = try Self.number(target, "elementType")
    origin = try Self.number(target, "originPlatform")
    // This first read supplies the window identity; subsequent reads must match it.
    let initial = try Self.attributes(client: client, element: target, names: names)
    guard initial[names[2]] as? String == identifier,
          try Self.frame(initial, names: names) == frame,
          (initial[names[3]] as? NSNumber)?.uint32Value == displayID,
          let context = initial[names[4]] as? NSNumber, context.uint64Value > 0 else {
      throw FBAXNativeSwitchError.rejected("Native target frame, window or display differs")
    }
    windowContextID = context
    try budget.check()
    transferred = true
  }

  private static func attributes(client: NSObject, element: NSObject, names: [NSString]) throws -> NSDictionary {
    var error: NSError?
    let call = unsafeBitCast(try method(client, "attributesForElement:attributes:error:", "@40@0:8@16@24^@32"), to: AttributeCall.self)
    guard let values = call(client, NSSelectorFromString("attributesForElement:attributes:error:"), element,
      names as NSArray, &error)?.takeUnretainedValue() as? NSDictionary, error == nil else {
      throw FBAXNativeSwitchError.rejected("Native attributes failed: \(String(describing: error))")
    }
    return values
  }

  private static func frame(_ values: NSDictionary, names: [NSString]) throws -> CGRect {
    guard let value = values[names[1]] as? [String: NSNumber],
          let x = value["X"], let y = value["Y"], let w = value["Width"], let h = value["Height"] else {
      throw FBAXNativeSwitchError.rejected("Native frame unavailable")
    }
    let frame = CGRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
    guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else {
      throw FBAXNativeSwitchError.rejected("Native frame invalid")
    }
    return frame
  }

  func validate(pointToken: FBAXSimulatorDeviceToken, point: CGPoint) throws -> FBSimulatorAXNativeSwitchProof {
    try budget.check()
    guard !closed, pointToken.pid == expectedPID, expectedFrame.contains(point),
          let cls = NSClassFromString("XCAccessibilityElement") else {
      throw FBAXNativeSwitchError.rejected("Native point or session differs")
    }
    let allocation = try Self.method(cls, "alloc", "@16@0:8", isClassMethod: true)
    let initializer = try Self.method(cls, "initWithToken:elementOrHash:elementID:pid:elementType:originPlatform:", "@60@0:8@16Q24Q32i40Q44Q52", isClassMethod: false)
    let allocated = unsafeBitCast(allocation, to: Allocate.self)(cls, NSSelectorFromString("alloc"))
    guard let hit = unsafeBitCast(initializer, to: NativeInit.self)(allocated.takeUnretainedValue(),
      NSSelectorFromString("initWithToken:elementOrHash:elementID:pid:elementType:originPlatform:"), nil,
      pointToken.element, pointToken.elementID, pointToken.pid, identityKind, origin)?.takeRetainedValue() else {
      throw FBAXNativeSwitchError.rejected("Native point identity unavailable")
    }
    func read(_ element: NSObject) throws -> NSDictionary {
      try budget.check()
      guard try Self.pid(element) == expectedPID else { throw FBAXNativeSwitchError.rejected("Native ancestry PID differs") }
      let values = try Self.attributes(client: client, element: element, names: attributeNames)
      try budget.check()
      guard values[attributeNames[4]] as? NSNumber == windowContextID,
            (values[attributeNames[3]] as? NSNumber)?.uint32Value == displayID else {
        throw FBAXNativeSwitchError.rejected("Native ancestry crosses a window or display")
      }
      return values
    }
    let selected = try read(target)
    guard selected[attributeNames[2]] as? String == identifier,
          try Self.frame(selected, names: attributeNames) == expectedFrame else {
      throw FBAXNativeSwitchError.rejected("Native switch changed")
    }
    let hitValues = try read(hit)
    guard try Self.frame(hitValues, names: attributeNames).contains(point) else {
      throw FBAXNativeSwitchError.rejected("Native hit frame misses the selected point")
    }
    var current: NSObject? = hit
    var chain: [NSObject] = []
    for _ in 0..<12 {
      guard let element = current, !chain.contains(where: { $0.isEqual(element) }) else {
        throw FBAXNativeSwitchError.rejected("Native ancestry ended or repeated")
      }
      let values = try read(element)
      chain.append(element)
      if element.isEqual(target) {
        return .init(pid: expectedPID, displayID: displayID, windowContextID: windowContextID.uint64Value, ancestorCount: chain.count)
      }
      current = values[attributeNames[0]] as? NSObject
    }
    throw FBAXNativeSwitchError.rejected("Selected point has no bounded native switch ancestor")
  }

  func close() {
    guard !closed else { return }
    closed = true
    Self.invalidate(session)
  }
  deinit { close() }
}
