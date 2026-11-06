@_implementationOnly import AccessibilityPlatformTranslation
import CoreFoundation
import Foundation

public struct FBSimulatorAXPressReply: Codable, Sendable {
  public let nativeResponsePresent: Bool
  public let error: String?
  public let attribute: String?
  public let valueKind: String
  public let value: Bool?

  static func decode(present: Bool, error: UInt64?, attribute: UInt64?, raw: Any?) -> Self {
    var kind = raw == nil ? "absent" : "wrongType"
    var value: Bool?
    if let number = raw as? NSNumber {
      // Accept a real Boolean or exact 0/1; arbitrary numeric truthiness is not evidence.
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        kind = "boolean"; value = number.boolValue
      } else if number.decimalValue == Decimal.zero {
        kind = "numericBoolean"; value = false
      } else if number.decimalValue == Decimal(1) {
        kind = "numericBoolean"; value = true
      } else { kind = "invalidNumber" }
    }
    return .init(nativeResponsePresent: present, error: error.map(String.init),
      attribute: attribute.map(String.init), valueKind: kind, value: value)
  }
  var accepted: Bool { nativeResponsePresent && error == "0" && value == true }
}

public struct FBSimulatorAXPressReceipt: Codable, Sendable {
  public var outcome = "rejectedBeforeAction"
  public var delivery = "notDispatched"
  public var callbackCount = 0
  public var sendCount = 0
  public var translatorCallAttempted = false
  public var reply: FBSimulatorAXPressReply?
  public var failure: String?
  public var target: FBSimulatorAXPressTarget?
  public var stateBefore: Bool?
  public var stateAfter: Bool?
  public var readbackCount: Int?
  public let guestEffectProved = false
  public let hidEventCount = 0
}

/// Decode only the Boolean forms already returned for a native CheckBox.
/// Neither arbitrary numeric truthiness nor localized value labels are accepted.
enum FBAXSwitchBoolean {
  static func decode(_ raw: Any?) throws -> Bool {
    if let text = raw as? String {
      if text == "0" { return false }
      if text == "1" { return true }
    } else if let number = raw as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
      if number.decimalValue == Decimal.zero { return false }
      if number.decimalValue == Decimal(1) { return true }
    }
    throw FBAXPressError.rejected("Semantic CheckBox value is not a strict Boolean or 0/1")
  }
}

struct FBAXPressBinding: Equatable, Sendable {
  let requestIdentity: ObjectIdentifier
  let translationIdentity: ObjectIdentifier
  let token: String
  let pid: Int32
  let objectID: UInt64
  // Native non-Catalyst translations can omit raw bytes. Preserve presence as part of equality.
  let rawData: Data?
  let requestType: UInt64
  let actionType: UInt64
  let attributeType: UInt64
  let clientType: UInt64
  let parametersEmpty: Bool

  static func capture(_ request: AXPTranslatorRequest?, token: String) -> Self? {
    guard let request, let translation = request.translation,
          translation.bridgeDelegateToken == token else { return nil }
    return .init(requestIdentity: ObjectIdentifier(request), translationIdentity: ObjectIdentifier(translation),
      token: token, pid: translation.pid, objectID: translation.objectID, rawData: translation.rawElementData,
      requestType: request.requestType, actionType: request.actionType,
      attributeType: request.attributeType, clientType: request.clientType,
      parametersEmpty: request.parameters?.isEmpty ?? true)
  }
}

enum FBAXPressError: Error { case rejected(String) }

/// Pure one-shot admission state. The callback gate below supplies synchronization.
struct FBAXPressAdmission {
  let expected: FBAXPressBinding
  private(set) var callbacks = 0
  private(set) var sends = 0
  private var admitted = false
  mutating func admit(_ actual: FBAXPressBinding?) throws {
    callbacks += 1
    guard callbacks == 1, sends == 0, actual == expected,
          expected.pid > 0, expected.objectID > 0, expected.rawData?.isEmpty != true,
          expected.requestType == 7, expected.actionType == 5,
          expected.attributeType == 0, expected.clientType == 2, expected.parametersEmpty else {
      throw FBAXPressError.rejected("Semantic press callback binding differs or repeats")
    }
    admitted = true
  }
  mutating func willSend() throws {
    guard admitted, callbacks == 1, sends == 0 else { throw FBAXPressError.rejected("Semantic press send repeats") }
    sends = 1
  }
}

/// Only immutable identity values cross the synchronous callback boundary.
/// The lock owns all mutable state. A late native completion never mutates this gate.
final class FBAXPressGate: @unchecked Sendable {
  private let lock = NSLock()
  private var admission: FBAXPressAdmission
  private var receipt = FBSimulatorAXPressReceipt()
  private let validate: @Sendable () throws -> Void
  init(binding: FBAXPressBinding, validate: @escaping @Sendable () throws -> Void) {
    admission = .init(expected: binding); self.validate = validate
  }
  func beginTranslatorCall() throws {
    lock.lock(); defer { lock.unlock() }
    guard !receipt.translatorCallAttempted else { throw FBAXPressError.rejected("Translator call repeats") }
    receipt.translatorCallAttempted = true
    receipt.delivery = "uncertain"
  }
  func willSend(_ request: AXPTranslatorRequest?, token: String, devicePresent: Bool) throws {
    lock.lock(); defer { lock.unlock() }
    do {
      guard receipt.translatorCallAttempted, receipt.failure == nil else { throw FBAXPressError.rejected("Semantic press already stopped") }
      try admission.admit(.capture(request, token: token))
      guard devicePresent else { throw FBAXPressError.rejected("Semantic press device missing") }
      try validate()
      try admission.willSend()
      receipt.delivery = "uncertain"
    } catch { receipt.failure = String(reflecting: error); throw error }
  }
  func finish(_ response: AXPTranslatorResponse?) {
    lock.lock(); defer { lock.unlock() }
    receipt.reply = .decode(present: response != nil, error: response?.error,
      attribute: response?.attribute, raw: response?.resultData)
    if admission.sends == 1, receipt.failure == nil, receipt.reply?.accepted == true {
      receipt.delivery = "nativeReplyAccepted"; receipt.outcome = "nativeReplyAccepted"
    }
  }
  func stop(_ error: Error) {
    lock.lock(); defer { lock.unlock() }; receipt.failure = String(reflecting: error)
    if receipt.translatorCallAttempted { receipt.delivery = "uncertain"; receipt.outcome = "failedNoReplay" }
  }
  func snapshot() -> FBSimulatorAXPressReceipt {
    lock.lock(); defer { lock.unlock() }
    var result = receipt; result.callbackCount = admission.callbacks; result.sendCount = admission.sends
    if result.translatorCallAttempted, result.delivery != "nativeReplyAccepted" { result.outcome = "failedNoReplay" }
    return result
  }
}
