/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@_implementationOnly @preconcurrency import AccessibilityPlatformTranslation
import CoreSimulator
import FBControlCore
import Foundation

/// Mutable holder so the synchronous bridge can capture the response out of the
/// `@Sendable` CoreSimulator completion handler. The `DispatchGroup` wait below
/// establishes the happens-before needed before the value is read, so unchecked
/// Sendable is safe here.
private final class AXPResponseBox: @unchecked Sendable {
  var response: AXPTranslatorResponse?
}

// Late replies can arrive after a bounded wait. Lock both reads and writes.
private final class AXBoundedResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: AXPTranslatorResponse?
  func complete(_ response: AXPTranslatorResponse?) { lock.lock(); value = response; lock.unlock() }
  func response() -> AXPTranslatorResponse? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Bridges the asynchronous CoreSimulator accessibility API to the synchronous
/// callback model `AXPTranslator` expects. Holds the token→request registry and,
/// per request, performs the translator handshake and converts the lazy AXP
/// attribute callbacks into synchronous CoreSimulator XPC round-trips.
///
/// Created and driven entirely from Swift in this module (see
/// `FBSimulatorAccessibilityCommands`). It remains an `NSObject` class because
/// it conforms to the Objective-C `AXPTranslationTokenDelegateHelper` protocol
/// and is installed as `AXPTranslator`'s bridge-token delegate.
final class FBAXTranslationDispatcher: NSObject, AXPTranslationTokenDelegateHelper {

  private weak var translator: AXPTranslator?
  private let logger: FBControlCoreLogger?
  private let callbackQueue: DispatchQueue
  private let lock = NSLock()
  private var tokenToRequest: [String: FBAXTranslationRequest] = [:]

  init(translator: AXPTranslator, logger: FBControlCoreLogger?) {
    self.translator = translator
    self.logger = logger
    self.callbackQueue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.accessibility_translator.callback")
    super.init()
  }

  // MARK: - Public

  func platformElement(withRequest request: FBAXTranslationRequest, simulator: FBSimulator, isolation: isolated (any Actor)? = #isolation) async throws -> FBAXPlatformElement {
    // Snapshot callers inherit their dedicated worker. Legacy callers use the
    // generic executor. No synchronous AX work is dispatched to the main queue.
    try Task.checkCancellation()
    request.device = simulator.device
    request.translator = self.translator
    self.pushRequest(request)
    var transferred = false
    defer { if !transferred { self.popRequest(request) } }
    let collector = request.collector

    let translationStart = CFAbsoluteTimeGetCurrent()
    guard let translator = self.translator, let translation = request.perform(withTranslator: translator) else {
      throw FBAccessibilityError.noTranslationObject
    }
    collector?.translationDuration = CFAbsoluteTimeGetCurrent() - translationStart
    translation.bridgeDelegateToken = request.token

    let conversionStart = CFAbsoluteTimeGetCurrent()
    let rawElement = translator.macPlatformElement(fromTranslation: translation)
    collector?.elementConversionDuration = CFAbsoluteTimeGetCurrent() - conversionStart

    guard let element = rawElement as? FBAXPlatformElement else {
      throw FBAccessibilityError.noTranslationObject
    }
    try Task.checkCancellation()
    element.axSetBridgeDelegateToken(request.token)
    transferred = true
    return element
  }

  // MARK: - Private

  private func pushRequest(_ request: FBAXTranslationRequest) {
    lock.lock()
    defer { lock.unlock() }
    tokenToRequest[request.token] = request
    logger?.log("Registered request with token \(request.token)")
  }

  func popRequest(_ request: FBAXTranslationRequest) {
    lock.lock()
    let present = tokenToRequest[request.token] != nil
    if present {
      tokenToRequest.removeValue(forKey: request.token)
    }
    lock.unlock()
    if present {
      logger?.log("Removed request with token \(request.token)")
    } else {
      logger?.log("popRequest: token \(request.token) not found (already popped or replaced by remediation), ignoring")
    }
  }

  private func request(forToken token: String) -> FBAXTranslationRequest? {
    lock.lock()
    defer { lock.unlock() }
    return tokenToRequest[token]
  }

  private static func emptyResponse() -> AXPTranslatorResponse? {
    AXPTranslatorResponse.empty() as? AXPTranslatorResponse
  }

  // MARK: - AXPTranslationTokenDelegateHelper

  // Since the CoreSimulator accessibility API is asynchronous but AXPTranslator's
  // delegation is synchronous, a DispatchGroup acts as a mutex to wait on the
  // result. The wait must never run on the main queue.
  func accessibilityTranslationDelegateBridgeCallback(withToken token: String) -> AXPTranslationCallback {
    guard let request = request(forToken: token) else {
      return { [weak self] _ in
        self?.logger?.log("Request with token \(token) is gone. Returning empty response")
        return Self.emptyResponse()
      }
    }
    let device = request.device
    let collector = request.collector
    let logger = request.logger
    let timeoutSeconds = request.requestTimeoutSeconds
    let callbackQueue = self.callbackQueue
    let budget = request.acquisitionBudget
    let routing = request.identityRoutingRecorder
    let routingSource = request.identityRoutingSource
    let pointGate = request.identityPointContextGate
    let opaquePointRead = request.opaquePointReadSuccess
    let pressGate = request.semanticPressGate
    let pressReads = request.semanticPressRequiresSuccessfulReads
    return { axRequest in
      logger?.log("Sending Accessibility Request \(String(describing: axRequest))")
      if let budget {
        let phaseLogger = FBControlCoreGlobalConfiguration.defaultLogger
        let signal = DispatchSemaphore(value: 0)
        let response = AXBoundedResponseBox()
        let start = ProcessInfo.processInfo.systemUptime
        // Copy diagnostic metadata on this owned synchronous path, not in the
        // asynchronous completion. This does not change the request or response.
        var ticket: FBAXIdentityRoutingRecorder.Ticket?
        var dispatched = false
        var enteredSend = false
        do {
          if pointGate != nil { try budget.check() }
          var effectiveRequest = axRequest
          if let pointGate {
            FBAXClientTypeRouting.apply(to: axRequest)
            effectiveRequest = try pointGate.admitCallback(axRequest, token: token, source: routingSource)
          }
          let isPoint = effectiveRequest?.requestType == 6
          var sendGateError: Error?
          try budget.wait(signal, requestTimeout: timeoutSeconds) {
            enteredSend = true
            FBAXClientTypeRouting.apply(to: effectiveRequest)
            ticket = Self.routingTicket(effectiveRequest, token: token, source: routingSource,
              recorder: routing, now: start)
            if let pointGate, isPoint {
              do {
                guard device != nil else { throw FBAXPointContextError.rejected("Point device missing") }
                try pointGate.willSend()
              } catch { sendGateError = error; signal.signal(); return }
            }
            if let opaquePointRead {
              do { try opaquePointRead.willSend(effectiveRequest, token: token, devicePresent: device != nil) }
              catch { sendGateError = error; signal.signal(); return }
            }
            if let pressGate {
              do { try pressGate.willSend(effectiveRequest, token: token, devicePresent: device != nil) }
              catch { sendGateError = error; signal.signal(); return }
            }
            dispatched = device != nil
            device?.sendAccessibilityRequestAsync(effectiveRequest, completionQueue: callbackQueue) { reply in
              response.complete(reply)
              signal.signal()
            }
          }
          if let sendGateError { throw sendGateError }
          let value = response.response()
          opaquePointRead?.didReply(effectiveRequest, token: token, response: value)
          pressGate?.finish(value)
          if pressReads, pressGate == nil, value == nil || value?.error != 0 {
            budget.stop(.failed)
            throw FBAXPressError.rejected("Semantic target read returned nil or native error")
          }
          routing?.finish(ticket, now: ProcessInfo.processInfo.systemUptime,
            outcome: value == nil ? "nativeNilResponse" : value?.error != 0 ? "nativeError" : "nativeResponse",
            dispatched: dispatched, reply: Self.routingReply(value))
          phaseLogger.log("AX acquisition response=completed token=\(token) nil=\(value == nil) elapsed=\(ProcessInfo.processInfo.systemUptime - start)")
          return value
        } catch {
          opaquePointRead?.stop()
          pressGate?.stop(error)
          if !enteredSend {
            ticket = Self.routingTicket(axRequest, token: token, source: routingSource,
              recorder: routing, now: start)
          }
          let stop = (error as? FBAXAcquisitionStop)?.outcome.rawValue ?? "stopped"
          let outcome = error is FBAXPointContextError ? "syntheticPointContextStop:" + String(reflecting: error) : "syntheticBudgetStop:" + stop
          routing?.finish(ticket, now: ProcessInfo.processInfo.systemUptime,
            outcome: outcome, dispatched: dispatched, reply: nil)
          phaseLogger.log("AX acquisition response=stopped token=\(token) reason=\(error) elapsed=\(ProcessInfo.processInfo.systemUptime - start)")
          return Self.emptyResponse()
        }
      }
      if let opaquePointRead {
        opaquePointRead.stop()
        return Self.emptyResponse()
      }
      // Semantic action must never enter the unbounded legacy callback path.
      if let pressGate {
        pressGate.stop(FBAXPressError.rejected("Semantic action budget missing"))
        return Self.emptyResponse()
      }
      let group = DispatchGroup()
      group.enter()
      let box = AXPResponseBox()

      let xpcStart = CFAbsoluteTimeGetCurrent()
      FBAXClientTypeRouting.apply(to: axRequest)
      device?.sendAccessibilityRequestAsync(axRequest, completionQueue: callbackQueue) { innerResponse in
        box.response = innerResponse
        group.leave()
      }
      let waitResult = group.wait(timeout: .now() + timeoutSeconds)
      collector?.addXPCCallDuration(CFAbsoluteTimeGetCurrent() - xpcStart)

      if waitResult == .timedOut {
        logger?.log("Accessibility request \(String(describing: axRequest)) timed out after \(timeoutSeconds)s — returning empty response")
        return Self.emptyResponse()
      }
      logger?.log("Got Accessibility Response \(String(describing: box.response))")
      return box.response
    }
  }

  private static func routingTicket(_ request: AXPTranslatorRequest?, token: String,
    source: String, recorder: FBAXIdentityRoutingRecorder?, now: Double
  ) -> FBAXIdentityRoutingRecorder.Ticket? {
    guard let recorder, let request,
          request.requestType == 6 || (request.requestType == 2 &&
            (request.attributeType == 12 || request.attributeType == 63 || request.attributeType == 65)) else { return nil }
    let metadata = FBAXRoutingRequest.capture(request, token: token, source: source)
    return recorder.begin(metadata, now: now)
  }

  private static func routingReply(_ response: AXPTranslatorResponse?) -> FBAXRoutingReply {
    .init(nativeResponsePresent: response != nil, error: response.map { String($0.error) },
      attribute: response.map { String($0.attribute) }, rawValue: .inspect(response?.resultData))
  }

  func accessibilityTranslationConvertPlatformFrame(toSystem rect: CGRect, withToken token: String) -> CGRect {
    rect
  }

  func accessibilityTranslationRootParent(withToken token: String) -> Any? {
    logger?.log("Delegate method 'accessibilityTranslationRootParentWithToken:', with unknown implementation called with token \(token). Returning nil.")
    return nil
  }
}

/// Point hit testing must keep the client type selected by AXPTranslator.
/// Overriding it with IDB's attribute client changes the guest's hit-test mode.
/// Type 6 is the point request emitted by objectAtPoint:displayId:bridgeDelegateToken:.
enum FBAXClientTypeRouting {
  static func apply(to request: AXPTranslatorRequest?) {
    guard let request, request.requestType != 6 else { return }
    request.clientType = 2
  }
}
