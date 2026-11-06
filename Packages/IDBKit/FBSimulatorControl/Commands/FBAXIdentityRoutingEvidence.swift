@_implementationOnly @preconcurrency import AccessibilityPlatformTranslation
import CoreFoundation
import Foundation

/// The only untyped boundary is the Objective-C resultData/NSDictionary value.
/// No framework object or unbounded object description enters the evidence.
struct FBAXRawNumber: Encodable, Sendable {
  let state: String
  let className: String?
  let objcType: String?
  let decimalValue: String?

  static func inspect(_ value: Any?) -> Self {
    guard let value else { return .init(state: "absent", className: nil, objcType: nil, decimalValue: nil) }
    let name = String(String(reflecting: type(of: value)).prefix(128))
    guard let number = value as? NSNumber else {
      return .init(state: "wrongType", className: name, objcType: nil, decimalValue: nil)
    }
    let encoding = String(cString: number.objCType)
    func result(_ state: String, _ decimal: String? = nil) -> Self {
      .init(state: state, className: name, objcType: String(encoding.prefix(32)), decimalValue: decimal)
    }
    guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return result("boolean") }
    guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q", "f", "d"].contains(encoding) else {
      return result("unsupportedNumericEncoding")
    }
    // NSDecimalNumber can contain fractions that Double and NSNumber.compare lose.
    if let decimalNumber = number as? NSDecimalNumber {
      var decimal = decimalNumber.decimalValue
      guard !decimal.isNaN else { return result("nonFinite") }
      guard decimal >= Decimal.zero else { return result("negative") }
      var integral = Decimal.zero
      NSDecimalRound(&integral, &decimal, 0, .down)
      guard integral == decimal else { return result("fractional") }
      guard integral <= Decimal(UInt32.max) else { return result("outOfUInt32Range") }
      let integer = decimalNumber.uint32Value
      return result(integer == 0 ? "numericZeroUnknownMeaning" : "uint32", String(integer))
    }
    let numeric = number.doubleValue
    guard numeric.isFinite else { return result("nonFinite") }
    guard numeric >= 0 else { return result("negative") }
    guard numeric.rounded(.towardZero) == numeric else { return result("fractional") }
    guard numeric <= Double(UInt32.max) else { return result("outOfUInt32Range") }
    let integer = UInt32(numeric)
    guard number.compare(NSNumber(value: integer)) == .orderedSame else { return result("fractional") }
    return result(integer == 0 ? "numericZeroUnknownMeaning" : "uint32", String(integer))
  }
}

struct FBAXRawPoint: Encodable, Sendable {
  let state: String
  let objcType: String?
  let x: Double?
  let y: Double?

  static func inspect(_ value: Any?) -> Self {
    guard let value else { return .init(state: "absent", objcType: nil, x: nil, y: nil) }
    guard let point = value as? NSValue else { return .init(state: "wrongType", objcType: nil, x: nil, y: nil) }
    let encoding = String(cString: point.objCType)
    guard encoding == "{CGPoint=dd}" || encoding == "{_NSPoint=dd}" else {
      return .init(state: "wrongEncoding", objcType: String(encoding.prefix(64)), x: nil, y: nil)
    }
    let decoded = point.pointValue
    guard decoded.x.isFinite, decoded.y.isFinite else {
      return .init(state: "nonFinite", objcType: encoding, x: nil, y: nil)
    }
    return .init(state: "point", objcType: encoding, x: decoded.x, y: decoded.y)
  }
}

struct FBAXRoutingRequest: Encodable, Sendable {
  let token: String
  let source: String
  let requestType: String
  let attributeType: String
  let clientType: String
  let translationPID: String?
  let translationObjectID: String?
  let point: FBAXRawPoint
  let displayID: FBAXRawNumber
  let contextID: FBAXRawNumber
  let genericParameter: FBAXRawNumber
}

struct FBAXRoutingReply: Encodable, Sendable {
  let nativeResponsePresent: Bool
  let error: String?
  let attribute: String?
  let rawValue: FBAXRawNumber
}

struct FBAXRoutingReceipt: Encodable, Sendable {
  let sequence: Int
  let request: FBAXRoutingRequest
  let startedUptime: Double
  let finishedUptime: Double
  let outcome: String
  let nativeRequestDispatched: Bool
  let reply: FBAXRoutingReply?
}

struct FBAXIdentityAttribute: Encodable, Sendable {
  let state: String
  let nativeResponsePresent: Bool?
  let translatorResponsePresent: Bool
  let responseError: String?
  let responseAttribute: String?
  let value: FBAXRawNumber
  let firstBridgeSequence: Int
  let lastBridgeSequence: Int
  let bridgeObserved: Bool
}


struct FBAXRoutingSnapshot: Encodable, Sendable {
  let schema = 4
  let pointContext: FBAXPointContextSnapshot?
  let receipts: [FBAXRoutingReceipt]
  let attemptedReceipts: Int
  let maximumReceipts = 128
  let truncated: Bool
  let unfinishedReceiptCount: Int
  let requestResolvingBehaviorBefore: String?
  let requestResolvingBehaviorAfter: String?
  let modeChanged: Bool?
  let inputDispatched = false
  let ownershipAccepted = false
}

/// The lock protects the recorder because the synchronous bridge is Sendable.
/// Only immutable values enter it. Late native callbacks never call this owner.
final class FBAXIdentityRoutingRecorder: @unchecked Sendable {
  struct Ticket: Sendable { let sequence: Int; let request: FBAXRoutingRequest; let started: Double }
  private let lock = NSLock()
  private var attempted = 0
  private var pending = Set<Int>()
  private var receipts: [FBAXRoutingReceipt] = []
  private var before: String?
  private var after: String?
  private var pointContext: FBAXPointContextGate?

  func attachPointContext(_ value: FBAXPointContextGate) {
    lock.lock(); defer { lock.unlock() }; pointContext = value
  }

  func setMode(_ value: UInt64, beforeRead: Bool) {
    lock.lock(); defer { lock.unlock() }
    if beforeRead { before = String(value) } else { after = String(value) }
  }

  func begin(_ request: FBAXRoutingRequest, now: Double) -> Ticket? {
    lock.lock(); defer { lock.unlock() }
    attempted += 1
    guard attempted <= 128 else { return nil }
    pending.insert(attempted)
    return .init(sequence: attempted, request: request, started: now)
  }

  func finish(_ ticket: Ticket?, now: Double, outcome: String, dispatched: Bool, reply: FBAXRoutingReply?) {
    guard let ticket else { return }
    lock.lock(); defer { lock.unlock() }
    guard pending.remove(ticket.sequence) != nil else { return }
    receipts.append(.init(sequence: ticket.sequence, request: ticket.request,
      startedUptime: ticket.started, finishedUptime: now, outcome: outcome, nativeRequestDispatched: dispatched, reply: reply))
  }

  func snapshot() -> FBAXRoutingSnapshot {
    lock.lock(); defer { lock.unlock() }
    return .init(pointContext: pointContext?.snapshot(), receipts: receipts.sorted { $0.sequence < $1.sequence }, attemptedReceipts: attempted,
      truncated: attempted > 128, unfinishedReceiptCount: pending.count,
      requestResolvingBehaviorBefore: before, requestResolvingBehaviorAfter: after,
      modeChanged: before.flatMap { first in after.map { first != $0 } })
  }
}

/// This isolated diagnostic mode never authorizes ownership or input.
public enum FBSimulatorAXPointContextMode: String, Codable, Sendable, CaseIterable {
  case absent
  case explicitZero
  case freshRootContext
}

enum FBAXPointContextError: Error { case rejected(String) }

struct FBAXPointContextSnapshot: Encodable, Sendable {
  let mode: FBSimulatorAXPointContextMode
  let freshRootContext: FBAXRawNumber
  let rootResponseValid: Bool
  let selectedContext: String?
  let observedCallbacks: Int
  let attemptedPointRequests: Int
  let enteredNativeSends: Int
  let originalParameterKeys: [String]?
  let effectiveParameterKeys: [String]?
  let original: FBAXRoutingRequest?
  let effective: FBAXRoutingRequest?
  let failure: String?
  let ownershipAccepted = false
  let inputDispatched = false
}

extension FBAXRoutingRequest {
  static func capture(_ request: AXPTranslatorRequest, token: String, source: String) -> Self {
    let parameters = request.parameters
    return .init(token: token, source: source,
      requestType: String(request.requestType), attributeType: String(request.attributeType),
      clientType: String(request.clientType), translationPID: request.translation.map { String($0.pid) },
      translationObjectID: request.translation.map { String($0.objectID) },
      point: .inspect(parameters?["point"]), displayID: .inspect(parameters?["displayId"]),
      contextID: .inspect(parameters?["contextId"]), genericParameter: .inspect(parameters?["parameter"]))
  }
}

/// A request-local gate. It retains immutable metadata only, never an AX wrapper.
/// The synchronous Sendable bridge can enter it; the lock owns its small state.
final class FBAXPointContextGate: @unchecked Sendable {
  private let lock = NSLock()
  private let mode: FBSimulatorAXPointContextMode
  private let rootContext: FBAXRawNumber
  private let rootResponseValid: Bool
  private let selectedContext: UInt32?
  private let token: String
  private let point: CGPoint
  private let displayID: UInt32
  private var callbackCount = 0
  private var firstCallbackAdmitted = false
  private var attempts = 0
  private var sends = 0
  private var original: FBAXRoutingRequest?
  private var effective: FBAXRoutingRequest?
  private var originalKeys: [String]?
  private var effectiveKeys: [String]?
  private var failure: String?

  init(mode: FBSimulatorAXPointContextMode, rootContext: FBAXRawNumber,
       rootResponseValid: Bool, token: String, point: CGPoint, displayID: UInt32) throws {
    self.mode = mode; self.rootContext = rootContext; self.rootResponseValid = rootResponseValid
    self.token = token; self.point = point; self.displayID = displayID
    switch mode {
    case .absent: selectedContext = nil
    case .explicitZero: selectedContext = 0
    case .freshRootContext:
      guard rootResponseValid, rootContext.state == "uint32",
            let text = rootContext.decimalValue, let value = UInt32(text), value > 0,
            String(value) == text else {
        throw FBAXPointContextError.rejected("Fresh root context is not a successful nonzero UInt32 response")
      }
      selectedContext = value
    }
  }

  private func reject(_ reason: String) -> FBAXPointContextError {
    if failure == nil { failure = reason }
    return .rejected(reason)
  }

  /// Every callback for the point token must enter this method. The first is
  /// required to be the point request; ordinary later attribute calls are not
  /// reclassified or changed, but cannot precede a valid point send.
  func admitCallback(_ request: AXPTranslatorRequest?, token actualToken: String,
                     source: String) throws -> AXPTranslatorRequest {
    lock.lock(); defer { lock.unlock() }
    callbackCount += 1
    if let failure { throw FBAXPointContextError.rejected(failure) }
    guard let request else { throw reject("Missing callback request") }
    guard actualToken == token, source == "point" else {
      throw reject("Callback owner changed")
    }
    if !firstCallbackAdmitted {
      original = .capture(request, token: actualToken, source: source)
      originalKeys = request.parameters?.keys.compactMap { $0 as? String }.sorted()
      guard request.requestType == 6 else { throw reject("First callback is not the point request") }
      firstCallbackAdmitted = true
    } else if request.requestType != 6 {
      guard sends == 1 else { throw reject("Attribute callback before point send") }
      return request
    }
    return try preparePoint(request, token: actualToken, source: source)
  }

  private func preparePoint(_ request: AXPTranslatorRequest, token actualToken: String,
                            source: String) throws -> AXPTranslatorRequest {
    attempts += 1
    guard attempts == 1 else { throw reject("Duplicate point request") }
    original = .capture(request, token: actualToken, source: source)
    guard let parameters = request.parameters else { throw reject("Missing point parameters") }
    let keys = parameters.keys.compactMap { $0 as? String }.sorted()
    originalKeys = keys
    guard parameters.count == 2, keys == ["displayId", "point"] else {
      throw reject("Original point parameter keyset changed")
    }
    guard source == "point", actualToken == token, request.requestType == 6,
          request.attributeType == 0, request.actionType == 0,
          let translation = request.translation, translation.pid == 0,
          translation.bridgeDelegateToken == token else {
      throw reject("Original point request identity changed")
    }
    let rawPoint = FBAXRawPoint.inspect(parameters["point"])
    let rawDisplay = FBAXRawNumber.inspect(parameters["displayId"])
    guard rawPoint.state == "point", rawPoint.x == point.x, rawPoint.y == point.y,
          ["uint32", "numericZeroUnknownMeaning"].contains(rawDisplay.state),
          rawDisplay.decimalValue == String(displayID) else {
      throw reject("Original point or display changed")
    }
    // Client type is native point-routing state, not an IDB constant. The copy
    // must retain that exact factory value while this diagnostic adds context.
    guard let copy = request.copy() as? AXPTranslatorRequest, copy !== request,
          copy.translation === translation, copy.requestType == request.requestType,
          copy.attributeType == request.attributeType, copy.actionType == request.actionType,
          copy.clientType == request.clientType, let copied = copy.parameters,
          NSDictionary(dictionary: parameters).isEqual(to: copied) else {
      throw reject("Typed request copy did not preserve the original")
    }
    var replaced = copied
    if let selectedContext { replaced["contextId"] = NSNumber(value: selectedContext) }
    copy.parameters = replaced
    guard let final = copy.parameters else { throw reject("Copied point parameters missing") }
    let finalKeys = final.keys.compactMap { $0 as? String }.sorted()
    let expectedKeys = selectedContext == nil ? ["displayId", "point"] : ["contextId", "displayId", "point"]
    guard final.count == expectedKeys.count, finalKeys == expectedKeys else {
      throw reject("Effective point parameter keyset changed")
    }
    var preserved = final; preserved.removeValue(forKey: "contextId")
    guard NSDictionary(dictionary: parameters).isEqual(to: preserved),
          copy.translation === translation, translation.pid == 0,
          translation.bridgeDelegateToken == token else {
      throw reject("Effective point request did not preserve original fields")
    }
    let finalContext = FBAXRawNumber.inspect(final["contextId"])
    guard selectedContext.map({ finalContext.decimalValue == String($0) }) ?? (finalContext.state == "absent") else {
      throw reject("Effective context differs from the selected mode")
    }
    effectiveKeys = finalKeys
    effective = .capture(copy, token: actualToken, source: source)
    return copy
  }

  /// Called immediately before the native API invocation, after the budget gate.
  /// It proves send entry only, not a guest reply or the branch taken in the guest.
  func willSend() throws {
    lock.lock(); defer { lock.unlock() }
    guard failure == nil, attempts == 1, effective != nil, sends == 0 else {
      throw reject("Point native-send gate is not ready")
    }
    sends += 1
  }

  func requireComplete() throws {
    lock.lock(); defer { lock.unlock() }
    guard failure == nil, attempts == 1, sends == 1, effective != nil else {
      throw reject("Missing or rejected point dispatch")
    }
  }

  func snapshot() -> FBAXPointContextSnapshot {
    lock.lock(); defer { lock.unlock() }
    return .init(mode: mode, freshRootContext: rootContext, rootResponseValid: rootResponseValid,
      selectedContext: selectedContext.map(String.init), observedCallbacks: callbackCount, attemptedPointRequests: attempts,
      enteredNativeSends: sends, originalParameterKeys: originalKeys, effectiveParameterKeys: effectiveKeys,
      original: original, effective: effective, failure: failure)
  }
}

/// Registered host relation evidence only. This never grants element ownership.
struct FBAXRegisteredHostEvidence: Encodable, Sendable {
  let rawPresenter: FBAXIdentityAttribute
  let cachedPresenterPID: String?
  let expectedForegroundPID: Int32
  let usableHostPID: Int32?
  let relation: String
  let reason: String
  let inputDispatched = false
  let ownershipAccepted = false

  static func evaluate(raw: FBAXIdentityAttribute, cached: String?, expectedPID: Int32) -> Self {
    func result(_ pid: Int32? = nil, _ reason: String) -> Self {
      .init(rawPresenter: raw, cachedPresenterPID: cached, expectedForegroundPID: expectedPID,
        usableHostPID: pid, relation: pid.map { $0 == expectedPID ? "matchesExpectedForegroundHost" : "differsFromExpectedForegroundHost" } ?? "unknown",
        reason: reason)
    }
    guard expectedPID > 0 else { return result(nil, "invalidExpectedForegroundPID") }
    guard raw.state == "nativeResponse", raw.bridgeObserved,
          raw.nativeResponsePresent == true, raw.translatorResponsePresent,
          raw.responseError == "0", raw.responseAttribute == "65",
          raw.firstBridgeSequence == raw.lastBridgeSequence else {
      return result(nil, "noSingleSuccessfulNativePresenterReply")
    }
    guard raw.value.state == "uint32", let text = raw.value.decimalValue,
          let value = Int32(text), value > 0, String(value) == text else {
      return result(nil, "presenterIsNotExactPositiveInt32")
    }
    return result(value, "registeredHostRelationOnly")
  }
}
