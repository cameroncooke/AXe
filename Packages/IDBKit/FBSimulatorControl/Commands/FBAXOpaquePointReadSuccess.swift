@_implementationOnly @preconcurrency import AccessibilityPlatformTranslation
import CoreFoundation
import CoreGraphics
import Foundation

/// Immutable callback facts only. No framework object escapes the AX worker.
struct FBAXOpaquePointRequestFact: Equatable, Sendable {
  let requestIdentity: ObjectIdentifier
  let translationIdentity: ObjectIdentifier
  let token: String
  let translationToken: String?
  let requestType: UInt64
  let attributeType: UInt64
  let actionType: UInt64
  let clientType: UInt64
  let translationPID: Int32
  let translationObjectID: UInt64
  let point: CGPoint
  let displayID: UInt32
  let parameterKeys: [String]

  static func capture(_ request: AXPTranslatorRequest?, token: String) -> Self? {
    guard let request, let translation = request.translation, let parameters = request.parameters,
          parameters.count == 2, parameters.keys.compactMap({ $0 as? String }).count == parameters.count,
          let rawPoint = parameters["point"] as? NSValue,
          ["{CGPoint=dd}", "{_NSPoint=dd}"].contains(String(cString: rawPoint.objCType)),
          let number = parameters["displayId"] as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
          number.decimalValue > Decimal.zero, number.decimalValue <= Decimal(UInt32.max),
          number.decimalValue == Decimal(number.uint32Value) else { return nil }
    return .init(requestIdentity: ObjectIdentifier(request), translationIdentity: ObjectIdentifier(translation),
      token: token, translationToken: translation.bridgeDelegateToken,
      requestType: request.requestType, attributeType: request.attributeType, actionType: request.actionType,
      clientType: request.clientType, translationPID: translation.pid, translationObjectID: translation.objectID,
      point: rawPoint.pointValue, displayID: number.uint32Value,
      parameterKeys: parameters.keys.compactMap { $0 as? String }.sorted())
  }
}

/// One success proof, separate from the bounded diagnostic routing ledger.
struct FBAXOpaquePointSuccessState {
  let token: String
  let point: CGPoint
  let displayID: UInt32
  let expectedPID: Int32
  private(set) var callbacks = 0
  private(set) var sends = 0
  private(set) var replies = 0
  private var binding: FBAXOpaquePointRequestFact?
  private var replyIdentity: FBSimulatorAXNativeIdentity?
  private var accepted = false
  private var failed = false

  init(token: String, point: CGPoint, displayID: UInt32, expectedPID: Int32) {
    self.token = token; self.point = point; self.displayID = displayID; self.expectedPID = expectedPID
  }

  mutating func willSend(_ actual: FBAXOpaquePointRequestFact?, devicePresent: Bool) throws {
    callbacks += 1
    guard !failed, callbacks == 1, sends == 0, devicePresent,
          displayID > 0, expectedPID > 0, point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
          let actual, actual.token == token, actual.translationToken == token,
          actual.requestType == 6, actual.attributeType == 0, actual.actionType == 0,
          actual.translationPID == 0, actual.translationObjectID > 0,
          actual.point == point, actual.displayID == displayID,
          actual.parameterKeys == ["displayId", "point"] else {
      failed = true; throw FBAXOpaqueFrameTapError.rejected("Native point request binding is missing, changed or repeated")
    }
    binding = actual; sends = 1
  }

  mutating func didReply(_ actual: FBAXOpaquePointRequestFact?, nativeResponsePresent: Bool,
    error: UInt64?, identity: FBSimulatorAXNativeIdentity?) {
    replies += 1
    guard !failed, callbacks == 1, sends == 1, replies == 1,
          actual == binding, nativeResponsePresent, error == 0,
          let identity, identity.pid == expectedPID, identity.objectID > 0 else {
      failed = true; return
    }
    replyIdentity = identity; accepted = true
  }

  mutating func stop() { failed = true }

  func requireSuccess(identity: FBSimulatorAXNativeIdentity?) throws {
    guard !failed, accepted, callbacks == 1, sends == 1, replies == 1,
          let identity, identity == replyIdentity else {
      throw FBAXOpaqueFrameTapError.rejected("Native point lacks one successful exact owned reply")
    }
  }
}

/// The synchronous Sendable bridge can enter this lock owner. All mutable state
/// is private and accessed under this one lock. No actor-owned state is bypassed.
final class FBAXOpaquePointReadSuccess: @unchecked Sendable {
  private let lock = NSLock()
  private var state: FBAXOpaquePointSuccessState

  init(token: String, point: CGPoint, displayID: UInt32, expectedPID: Int32) {
    state = .init(token: token, point: point, displayID: displayID, expectedPID: expectedPID)
  }

  func willSend(_ request: AXPTranslatorRequest?, token: String, devicePresent: Bool) throws {
    guard request?.requestType == 6 else { return }
    let actual = FBAXOpaquePointRequestFact.capture(request, token: token)
    lock.lock(); defer { lock.unlock() }
    try state.willSend(actual, devicePresent: devicePresent)
  }

  func didReply(_ request: AXPTranslatorRequest?, token: String, response: AXPTranslatorResponse?) {
    guard request?.requestType == 6 else { return }
    let actual = FBAXOpaquePointRequestFact.capture(request, token: token)
    let identity = (response?.resultData as? AXPTranslationObject).map {
      FBSimulatorAXNativeIdentity(pid: $0.pid, objectID: $0.objectID)
    }
    lock.lock(); defer { lock.unlock() }
    state.didReply(actual, nativeResponsePresent: response != nil, error: response.map { $0.error }, identity: identity)
  }

  func stop() { lock.lock(); defer { lock.unlock() }; state.stop() }

  func requireSuccess(node: FBSimulatorAXNode) throws {
    lock.lock(); defer { lock.unlock() }
    try state.requireSuccess(identity: node.nativeIdentity)
  }
}
