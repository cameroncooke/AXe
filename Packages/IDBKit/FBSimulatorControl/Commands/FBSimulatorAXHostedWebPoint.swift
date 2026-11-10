@_implementationOnly import AccessibilityPlatformTranslation
import Foundation
import CoreGraphics

public enum FBSimulatorAXHostedWebError: Error, Sendable {
  case rejected(String)
}

/// Experimental point admission. This is not recursive selector search or a
/// general foreign-process rule. The caller must hold the common device lease.
public actor FBSimulatorAXHostedWebPointOperation: FBSimulatorHIDInputAdmissionGuard {
  public let point: CGPoint
  private let simulator: FBSimulator
  private let expectedPID: Int32
  private let label: String
  private let observation: FBSimulatorHIDSessionObservation
  private let provider: any FBSimulatorHIDLiveFreshnessProvider
  private let budget: FBAXAcquisitionBudget
  private var reservation: FBAXTargetReservation?
  private var validating = false
  private var consumed = false
  private var evidence: Data?

  private init(simulator: FBSimulator, expectedPID: Int32, label: String, point: CGPoint,
               observation: FBSimulatorHIDSessionObservation,
               provider: any FBSimulatorHIDLiveFreshnessProvider, budget: FBAXAcquisitionBudget,
               reservation: FBAXTargetReservation) {
    self.simulator = simulator; self.expectedPID = expectedPID; self.label = label
    self.point = point; self.observation = observation; self.provider = provider
    self.budget = budget; self.reservation = reservation
  }

  /// Standard IDB validation once. No retry or context override.
  /// The same deadline covers open, session setup, and final admission.
  public static func open(for simulator: FBSimulator, expectedPID: Int32,
                          exactLabel: String, point: CGPoint,
                          observation: FBSimulatorHIDSessionObservation,
                          freshnessProvider: any FBSimulatorHIDLiveFreshnessProvider,
                          timeoutSeconds: Double = 8) throws -> FBSimulatorAXHostedWebPointOperation {
    try FBAXHostedWebPolicy.validateRequest(expectedPID: expectedPID, label: exactLabel,
      point: point, logicalSize: observation.displayContext.logicalSize,
      rotation: observation.displayContext.rotation.rawValue, timeout: timeoutSeconds)
    try Task.checkCancellation()
    let reservation = try FBAXTargetReservation.acquire()
    return .init(simulator: simulator, expectedPID: expectedPID, label: exactLabel, point: point,
      observation: observation, provider: freshnessProvider,
      budget: FBAXAcquisitionBudget(seconds: timeoutSeconds), reservation: reservation)
  }

  public func validate(observation: FBSimulatorHIDSessionObservation,
                       firstEvent: FBSimulatorHIDEvent) async throws {
    guard reservation != nil else { throw FBSimulatorAXTargetError.closed }
    guard !validating else { throw FBSimulatorAXTargetError.busy }
    guard !consumed else { throw FBSimulatorAXTargetError.alreadyValidated }
    validating = true; consumed = true
    defer { validating = false }
    try FBSimulatorAXSnapshot.requireSame(self.observation, observation)
    try FBAXTargetValidationRules.firstEvent(firstEvent, point: point)
    do {
      evidence = try await withTaskCancellationHandler(operation: {
        try await FBSimulatorAXWorker.shared.validateHostedWebPoint(for: simulator,
          expectedPID: expectedPID, label: label, point: point, observation: observation,
          provider: provider, budget: budget)
      }, onCancel: { budget.stop(.cancelled) })
      try budget.check(); try Task.checkCancellation()
    } catch let failure as FBSimulatorAXHostedWebFailure {
      evidence = failure.evidenceJSON
      throw failure
    }
  }

  public func evidenceJSON() -> Data? { evidence }
  /// Await the input operation, session close and feed close before this call.
  public func close() throws {
    guard !validating else { throw FBSimulatorAXTargetError.busy }
    reservation = nil
  }
}

public struct FBSimulatorAXHostedWebFailure: Error, Sendable {
  public let failureDescription: String
  public let evidenceJSON: Data
}

struct FBAXHostedWebPoint: Encodable, Sendable {
  let pid: Int32
  let objectID: String
  let role: String?
  let identifier: String?
  let label: String?
  let rawPlatformFrame: CGRect
  let windowContext: FBAXIdentityAttribute
  let display: FBAXIdentityAttribute
  let presenter: FBAXIdentityAttribute
  let requestsBoundToPoint: Bool

  static func read(_ value: FBAXPlatformElement, token: String, budget: FBAXAcquisitionBudget,
                   routing: FBAXIdentityRoutingRecorder) throws -> Self {
    try budget.check(); try Task.checkCancellation()
    guard let element = value as? AXPMacPlatformElement, let translation = element.translation else {
      throw FBSimulatorAXHostedWebError.rejected("Missing typed point translation")
    }
    element.axSetBridgeDelegateToken(token)
    let pid = translation.pid, objectID = String(translation.objectID)
    let role = element.axRole(); try budget.check()
    let identifier = element.axIdentifier(); try budget.check()
    let label = element.axLabel(); try budget.check()
    let frame = element.axFrame(); try budget.check()
    guard [role, identifier, label].allSatisfy({ $0.map { $0.utf8.count <= 1024 } ?? true }) else {
      throw FBSimulatorAXHostedWebError.rejected("Point text exceeds evidence limit")
    }
    let reader = FBAXIdentityRecorder(budget: budget, identifiers: [], labels: [], routing: routing)
    let context = try reader.attribute(element, token: token, attribute: 12, guestAttribute: nil)
    let display = try reader.attribute(element, token: token, attribute: 63, guestAttribute: 2123)
    let presenter = try reader.attribute(element, token: token, attribute: 65, guestAttribute: nil)
    let snapshot = routing.snapshot()
    let bound = [(context, "12"), (display, "63"), (presenter, "65")].allSatisfy {
      FBAXHostedWebPolicy.boundRequest($0.0, attribute: $0.1, pid: pid,
        objectID: objectID, token: token, receipts: snapshot.receipts)
    }
    guard translation.pid == pid, String(translation.objectID) == objectID else {
      throw FBSimulatorAXHostedWebError.rejected("Point translation changed during reads")
    }
    return .init(pid: pid, objectID: objectID, role: role, identifier: identifier, label: label,
      rawPlatformFrame: frame, windowContext: context, display: display, presenter: presenter,
      requestsBoundToPoint: bound)
  }
}

enum FBAXHostedWebPolicy {
  /// Shared request setup used by both actual point arms and local gate checks.
  static func pointRequest(nativePoint: CGPoint, displayID: UInt32,
                           displayContext: FBSimulatorHIDDisplayContext?,
                           budget: FBAXAcquisitionBudget, routing: FBAXIdentityRoutingRecorder,
                           rootContext: FBAXRawNumber) throws -> (FBAXTranslationRequest, FBAXPointContextGate) {
    let request = FBAXTranslationRequest(kind: .point(nativePoint), pointDisplayID: displayID,
      displayContext: displayContext)
    request.acquisitionBudget = budget; request.identityRoutingRecorder = routing
    request.identityRoutingSource = "point"
    let gate = try FBAXPointContextGate(mode: .absent, rootContext: rootContext,
      rootResponseValid: true, token: request.token, point: nativePoint, displayID: displayID)
    request.identityPointContextGate = gate
    return (request, gate)
  }

  static func validateRequest(expectedPID: Int32, label: String, point: CGPoint,
                              logicalSize: CGSize, rotation: Int, timeout: Double) throws {
    guard expectedPID > 0, !label.isEmpty, label.utf8.count <= 256,
          [0, 90, 180, 270].contains(rotation), timeout.isFinite, timeout > 0, timeout <= 8,
          point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
          point.x < logicalSize.width, point.y < logicalSize.height else {
      throw FBSimulatorAXHostedWebError.rejected("Invalid request or unsupported quarter-turn rotation")
    }
  }

  static func number(_ raw: FBAXIdentityAttribute, attribute: String) throws -> UInt32 {
    guard raw.state == "nativeResponse", raw.bridgeObserved, raw.nativeResponsePresent == true,
          raw.translatorResponsePresent, raw.responseError == "0", raw.responseAttribute == attribute,
          raw.firstBridgeSequence == raw.lastBridgeSequence,
          ["uint32", "numericZeroUnknownMeaning"].contains(raw.value.state),
          let text = raw.value.decimalValue, let number = UInt32(text), String(number) == text else {
      throw FBSimulatorAXHostedWebError.rejected("No single successful numeric native reply for attribute " + attribute)
    }
    return number
  }

  static func boundRequest(_ raw: FBAXIdentityAttribute, attribute: String, pid: Int32,
                           objectID: String, token: String, receipts: [FBAXRoutingReceipt]) -> Bool {
    let found = receipts.filter { $0.sequence == raw.firstBridgeSequence }
    guard raw.firstBridgeSequence == raw.lastBridgeSequence, found.count == 1, let receipt = found.first else { return false }
    let request = receipt.request
    return receipt.nativeRequestDispatched && request.requestType == "2" && request.attributeType == attribute &&
      request.translationPID == String(pid) && request.translationObjectID == objectID && request.token == token &&
      (attribute == "63" ? request.genericParameter.decimalValue == "2123" : request.genericParameter.state == "absent")
  }

  static func root(_ value: FBAXIdentityContext, expectedPID: Int32, selectedDisplay: UInt32,
                   token: String, receipts: [FBAXRoutingReceipt]) throws -> UInt32 {
    guard value.translationPID == String(expectedPID), let objectID = value.translationObjectID,
          boundRequest(value.windowContext, attribute: "12", pid: expectedPID, objectID: objectID, token: token, receipts: receipts),
          boundRequest(value.display, attribute: "63", pid: expectedPID, objectID: objectID, token: token, receipts: receipts) else {
      throw FBSimulatorAXHostedWebError.rejected("Root attribute request identity differs")
    }
    let context = try number(value.windowContext, attribute: "12")
    let display = try number(value.display, attribute: "63")
    guard context > 0, display == 0 || display == selectedDisplay else {
      throw FBSimulatorAXHostedWebError.rejected("Root context unavailable or display conflicts")
    }
    return context
  }

  static func link(_ value: FBAXHostedWebPoint, expectedPID: Int32, label: String,
                   logicalPoint: CGPoint, selectedDisplay: UInt32, rootContext: UInt32) throws {
    let frame = value.rawPlatformFrame
    guard value.requestsBoundToPoint, value.pid > 0, value.pid != expectedPID,
          value.role == "AXLink", value.label == label,
          [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy({ $0.isFinite }),
          frame.width > 0, frame.height > 0, frame.contains(logicalPoint) else {
      throw FBSimulatorAXHostedWebError.rejected("Point is not the exact hosted link")
    }
    let host = FBAXRegisteredHostEvidence.evaluate(raw: value.presenter, cached: nil, expectedPID: expectedPID)
    guard host.usableHostPID == expectedPID else { throw FBSimulatorAXHostedWebError.rejected("Registered host differs or is unknown") }
    let display = try number(value.display, attribute: "63")
    let context = try number(value.windowContext, attribute: "12")
    guard display == 0 || display == selectedDisplay, context == 0 || context == rootContext else {
      throw FBSimulatorAXHostedWebError.rejected("Nonzero point display/context conflicts with fresh selection")
    }
  }

  static func samePoint(_ first: FBAXHostedWebPoint, _ second: FBAXHostedWebPoint) throws {
    guard first.pid == second.pid, first.objectID == second.objectID,
          first.role == second.role, first.identifier == second.identifier,
          first.label == second.label, first.rawPlatformFrame == second.rawPlatformFrame else {
      throw FBSimulatorAXHostedWebError.rejected("Repeated point identity changed")
    }
  }
}

private struct FBAXHostedWebEvidence: Encodable {
  let schema = 2
  let frameSpace = "orientedLogicalDisplayPoints"
  let rotation: Int
  let expectedPID: Int32
  let logicalPoint: CGPoint
  let nativePoint: CGPoint
  let rootBefore: FBAXIdentityContext?
  let rootAfter: FBAXIdentityContext?
  let points: [FBAXHostedWebPoint]
  let pointDispatches: [FBAXPointContextSnapshot]
  let routing: FBAXRoutingSnapshot
  let startedUptime: Double
  let finishedUptime: Double
  let admissionAccepted: Bool
  let failure: String?
  let inputDispatchedByValidation = false
  let limit = "Experimental quarter-turn hosted AXLink point admission; each pose needs separate native acceptance. Zero node display/context stays unknown. No tree membership or guest atomicity claim."
}

extension FBSimulatorAXWorker {
  func validateHostedWebPoint(for simulator: FBSimulator, expectedPID: Int32, label: String,
    point: CGPoint, observation: FBSimulatorHIDSessionObservation,
    provider: any FBSimulatorHIDLiveFreshnessProvider, budget: FBAXAcquisitionBudget) async throws -> Data {
    let started = ProcessInfo.processInfo.systemUptime
    let routing = FBAXIdentityRoutingRecorder()
    let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
    let native = try FBAXTranslationRequest(kind: .point(point), pointDisplayID: observation.axDisplayID,
      displayContext: observation.displayContext).nativePoint(from: point)
    var before: FBAXIdentityContext?
    var after: FBAXIdentityContext?
    var points: [FBAXHostedWebPoint] = []
    var gates: [FBAXPointContextSnapshot] = []
    func data(accepted: Bool, failure: String?) throws -> Data {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      let bytes = try encoder.encode(FBAXHostedWebEvidence(rotation: observation.displayContext.rotation.rawValue,
        expectedPID: expectedPID, logicalPoint: point,
        nativePoint: native, rootBefore: before, rootAfter: after, points: points,
        pointDispatches: gates, routing: routing.snapshot(), startedUptime: started,
        finishedUptime: ProcessInfo.processInfo.systemUptime, admissionAccepted: accepted, failure: failure))
      guard bytes.count <= 512_000 else { throw FBSimulatorAXHostedWebError.rejected("Admission evidence exceeds limit") }
      return bytes
    }
    do {
      try budget.check(); try Task.checkCancellation()
      // Session execute already performed a full authoritative read. It owns inFlight.
      try provider.validateCurrentRevision(expected: observation)
      try budget.check(); try Task.checkCancellation()
      try commands.validateAccessibility()
      try budget.check()
      let rootRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      rootRequest.acquisitionBudget = budget; rootRequest.identityRoutingRecorder = routing
      rootRequest.identityRoutingSource = "hostedRootBefore"
      let root = try await commands.accessibilityElementForAcquisition(request: rootRequest, worker: self)
      defer { root.close() }
      guard root.acquisitionPID == expectedPID else { throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: root.acquisitionPID) }
      let firstRoot = try root.identityRootContext(budget: budget, routing: routing); before = firstRoot
      let rootContext = try FBAXHostedWebPolicy.root(firstRoot, expectedPID: expectedPID,
        selectedDisplay: observation.axDisplayID, token: rootRequest.token, receipts: routing.snapshot().receipts)
      root.close()
      for index in 0..<2 {
        try budget.check(); try Task.checkCancellation()
        let (request, gate) = try FBAXHostedWebPolicy.pointRequest(nativePoint: native,
          displayID: observation.axDisplayID, displayContext: observation.displayContext,
          budget: budget, routing: routing, rootContext: firstRoot.windowContext.value)
        defer { gates.append(gate.snapshot()) }
        let hit = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
        defer { hit.close() }
        try gate.requireComplete()
        let value = try hit.hostedWebPoint(budget: budget, routing: routing)
        points.append(value)
        try gate.requireComplete()
        try FBAXHostedWebPolicy.link(value, expectedPID: expectedPID, label: label, logicalPoint: point,
          selectedDisplay: observation.axDisplayID, rootContext: rootContext)
        if index == 1 { try FBAXHostedWebPolicy.samePoint(points[0], value) }
        hit.close()
      }
      let finalRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      finalRequest.acquisitionBudget = budget; finalRequest.identityRoutingRecorder = routing
      finalRequest.identityRoutingSource = "hostedRootAfter"
      let final = try await commands.accessibilityElementForAcquisition(request: finalRequest, worker: self)
      defer { final.close() }
      guard final.acquisitionPID == expectedPID else { throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: final.acquisitionPID) }
      let finalRoot = try final.identityRootContext(budget: budget, routing: routing); after = finalRoot
      let finalContext = try FBAXHostedWebPolicy.root(finalRoot, expectedPID: expectedPID,
        selectedDisplay: observation.axDisplayID, token: finalRequest.token, receipts: routing.snapshot().receipts)
      guard finalContext == rootContext, finalRoot.translationObjectID == firstRoot.translationObjectID else {
        throw FBSimulatorAXHostedWebError.rejected("Root context or identity changed")
      }
      final.close()
      let snapshot = routing.snapshot()
      guard !snapshot.truncated, snapshot.unfinishedReceiptCount == 0 else {
        throw FBSimulatorAXHostedWebError.rejected("Incomplete bridge evidence")
      }
      let bytes = try data(accepted: true, failure: nil)
      try budget.check(); try Task.checkCancellation()
      try provider.validateCurrentRevision(expected: observation)
      return bytes
    } catch {
      throw FBSimulatorAXHostedWebFailure(failureDescription: String(reflecting: error),
        evidenceJSON: try data(accepted: false, failure: String(reflecting: error)))
    }
  }
}
