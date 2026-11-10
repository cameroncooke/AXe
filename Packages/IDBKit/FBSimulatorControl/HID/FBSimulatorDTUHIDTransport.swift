/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@preconcurrency import CoreSimulator
import Darwin
@preconcurrency import FBControlCore
import Foundation
import XPC

/// Tracks the per-contact phase so that a stream of Indigo `.down`/`.up` events maps onto the
/// `dtuhidd` `start` / `position` / `end` model: the first `.down` is a `start`, subsequent `.down`s
/// (a drag/swipe) are `position`s, and `.up` is the `end`.
struct DigitizerContactTracker {
  private var active = false

  mutating func eventType(for direction: FBSimulatorHIDDirection) -> DigitizerEventType {
    switch direction {
    case .down:
      if active {
        return .position
      }
      active = true
      return .start
    case .up:
      active = false
      return .end
    }
  }
}

/**
 The DTUHID transport (Xcode 27 / macOS 26 / iOS 26+).

 Drives the modern `dtuhidd` daemon: events cross the host→guest boundary as plain-XPC dictionaries
 delivered to the `com.apple.coredevice.feature.remote.hid.digitizer` service. Each message is built
 as an `Encodable` model (e.g. `IndigoDigitizerEvent`) wrapped in a `DTUHIDMessage` envelope and
 serialized with `XPCEncoder`, rather than hand-rolled `xpc_dictionary_set_*` calls. The host XPC
 connection is built from the simulator's Mach port via the private `_4sim` endpoint symbols
 (resolved with `dlsym`) and must be marked simulator-to-host with `xpc_connection_enable_sim2host_4sim`
 before messages reach the service handler.

 Capabilities are added one per commit; not-yet-implemented primitives throw
 `notImplementedOnDTUHIDTransport` rather than silently falling back to Indigo.

 An `actor`: the mutable contact state is actor-isolated, so the type needs no `@unchecked Sendable`.
 The XPC connection handle is thread-safe, so `disconnect()` cancels it from a `nonisolated` context.
 */
actor FBSimulatorDTUHIDTransport: FBSimulatorHIDTransport, FBSimulatorHIDCleanupTransportDiagnostics, FBSimulatorHIDOwnedCleanupTransport {

  private var latestSendEvidence: FBSimulatorHIDSendEvidence?
  func lastSendEvidence() -> FBSimulatorHIDSendEvidence? { latestSendEvidence }

  static let digitizerServiceName = "com.apple.coredevice.feature.remote.hid.digitizer"

  // Private XPC endpoint functions, resolved at runtime (not in the XPC module headers).
  private typealias EndpointFromMachPortFn = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
  private typealias ConnectionFromEndpointFn = @convention(c) (xpc_object_t) -> xpc_connection_t?
  private typealias EnableSim2HostFn = @convention(c) (xpc_connection_t) -> Void

  /// Bounded connection keepalive after one dispatched gesture, not a guest acknowledgement.
  /// The XPC send barrier confirms host enqueue only. In the Duo timing proof, an extra 300 ms
  /// after the previous 80 ms drain allowed an unchanged default tap to arrive before disconnect;
  /// a 200 ms pre-send wait did not. Keep event spacing unchanged and retain the connection for
  /// that measured total of 380 ms. UI outcome still requires independent readback. This is not
  /// a general delivery guarantee, and cancellation can still interrupt the existing sleep.
  /// Every disconnect also defers the XPC cancel until this long after the last dispatch, so a
  /// caller whose process stays alive need not wait in `flush()`.
  static let drainNanos: UInt64 = 380_000_000 // 380 ms

  private let connection: FBSimulatorDTUHIDConnection
  private let enqueueGate: FBSimulatorDTUHIDEnqueueGate
  private let mainScreenSize: CGSize
  private let mainScreenScale: Float
  private let displayContext: FBSimulatorHIDDisplayContext?
  private let nativeEdge: FBSimulatorHIDNativeEdge
  private var contact = DigitizerContactTracker()
  private var twoFingerContact = DigitizerContactTracker()

  // MARK: Initializers

  /// Builds a DTUHID transport for the provided Simulator, establishing the host XPC connection to
  /// `dtuhidd`. All setup is synchronous, so the returned transport is ready to send.
  static func dtuhid(for simulator: FBSimulator, displayContext: FBSimulatorHIDDisplayContext? = nil, nativeEdge: FBSimulatorHIDNativeEdge = .none, ownedCleanup: Bool = false) throws -> FBSimulatorDTUHIDTransport {
    guard let handle = dlopen(nil, RTLD_NOW) else {
      throw FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable
    }
    guard
      let endpointFromPort = symbol(handle, "xpc_endpoint_create_mach_port_4sim", as: EndpointFromMachPortFn.self),
      let connectionFromEndpoint = symbol(handle, "xpc_connection_create_from_endpoint", as: ConnectionFromEndpointFn.self),
      let enableSim2Host = symbol(handle, "xpc_connection_enable_sim2host_4sim", as: EnableSim2HostFn.self)
    else {
      throw FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable
    }

    var lookupError: NSError?
    let servicePort = simulator.device.lookup(digitizerServiceName, error: &lookupError)
    if servicePort == 0 {
      throw FBSimulatorHIDError.dtuhidDigitizerServiceUnavailable(underlying: lookupError)
    }

    guard
      let endpoint = endpointFromPort(servicePort, 0, 0),
      let connection = connectionFromEndpoint(endpoint)
    else {
      throw FBSimulatorHIDError.dtuhidConnectionFailed
    }

    // The load-bearing step: without this the daemon observes the peer but never the payload.
    enableSim2Host(connection)

    return FBSimulatorDTUHIDTransport(
      connection: connection,
      mainScreenSize: simulator.device.deviceType.mainScreenSize,
      mainScreenScale: simulator.device.deviceType.mainScreenScale,
      displayContext: displayContext, nativeEdge: nativeEdge, ownedCleanup: ownedCleanup)
  }

  init(connection: xpc_connection_t, mainScreenSize: CGSize, mainScreenScale: Float, displayContext: FBSimulatorHIDDisplayContext? = nil, nativeEdge: FBSimulatorHIDNativeEdge = .none, ownedCleanup: Bool = false) {
    let handle = FBSimulatorDTUHIDConnection(connection)
    self.connection = handle
    let gate = FBSimulatorDTUHIDEnqueueGate(retainForOwnedCleanup: ownedCleanup,
      disconnectDrainSeconds: Double(Self.drainNanos) / 1_000_000_000) { handle.disconnect() }
    self.enqueueGate = gate
    handle.start(gate: gate)
    self.mainScreenSize = mainScreenSize
    self.mainScreenScale = mainScreenScale
    self.displayContext = displayContext
    self.nativeEdge = nativeEdge
  }

  private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let sym = dlsym(handle, name) else {
      return nil
    }
    return unsafeBitCast(sym, to: type)
  }

  // MARK: FBSimulatorHIDTransport

  nonisolated func disconnect() {
    enqueueGate.disconnect()
  }

  /// Local eligibility only. A later send still requires its normal host and guest proof.
  func acceptsInput() -> Bool { enqueueGate.acceptsInput }

  /// Connection startup. This confirms guest service progress before the first input; it does
  /// not confirm UIKit readiness or change contact timing. A failure closes the connection.
  func prepareConnection(timeout: TimeInterval = 2) async throws {
    try await enqueueGate.performInitialGuestBarrier(timeout: timeout) {
      connection.sendGuestBarrier(completion: $0)
    }
  }

  func sendTouch(direction: FBSimulatorHIDDirection, x: Double, y: Double) async throws {
    let ratio = try normalizedPoint(CGPoint(x: x, y: y))
    let event = IndigoDigitizerEvent(
      pointOne: DigitizerPoint(x: Double(ratio.x), y: Double(ratio.y)),
      eventType: contact.eventType(for: direction),
      edge: nativeEdge.rawValue, target: displayContext?.hidTarget ?? 0)
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  func sendTwoFingerTouch(direction: FBSimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint) async throws {
    let r1 = try normalizedPoint(finger1)
    let r2 = try normalizedPoint(finger2)
    let event = IndigoDigitizerEvent(
      pointOne: DigitizerPoint(x: Double(r1.x), y: Double(r1.y)),
      pointTwo: DigitizerPoint(x: Double(r2.x), y: Double(r2.y)),
      eventType: twoFingerContact.eventType(for: direction),
      edge: nativeEdge.rawValue, target: displayContext?.hidTarget ?? 0)
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  private func normalizedPoint(_ point: CGPoint) throws -> CGPoint {
    if let displayContext {
      return try displayContext.normalizedPoint(from: point)
    }
    return FBSimulatorIndigoHID.screenRatio(
      from: point, screenSize: mainScreenSize, screenScale: mainScreenScale)
  }

  func sendButton(direction: FBSimulatorHIDDirection, button: FBSimulatorHIDButton) async throws {
    guard let usage = button.dtuhidUsage else {
      throw FBSimulatorHIDError.notImplementedOnDTUHIDTransport(
        operation: "sendButton(.applePay) — Apple Pay is a double side-button press, not a single HID usage; send two .sideButton presses instead")
    }
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoButtonEvent",
      payload: IndigoButtonEvent(usagePage: UInt64(usage.page), usageCode: UInt64(usage.code), state: state))
  }

  func sendKeyboard(direction: FBSimulatorHIDDirection, keyCode: UInt32) async throws {
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoKeyboardButtonEvent",
      payload: IndigoKeyboardButtonEvent(usageCode: UInt64(keyCode), state: state))
  }

  /// Release only input recorded by the owning session, using its original connection.
  /// Normal input remains closed. These requests retain the same host and guest proof.
  func releaseOwnedInput(_ release: FBSimulatorHIDOwnedRelease) async throws {
    switch release {
    case let .touch(point):
      let ratio = try normalizedPoint(point)
      let event = IndigoDigitizerEvent(
        pointOne: DigitizerPoint(x: Double(ratio.x), y: Double(ratio.y)),
        eventType: contact.eventType(for: .up), edge: nativeEdge.rawValue,
        target: displayContext?.hidTarget ?? 0)
      try await send(messageType: "IndigoDigitizerEvent", payload: event, ownedRelease: true)
    case let .pair(first, second):
      let r1 = try normalizedPoint(first)
      let r2 = try normalizedPoint(second)
      let event = IndigoDigitizerEvent(
        pointOne: DigitizerPoint(x: Double(r1.x), y: Double(r1.y)),
        pointTwo: DigitizerPoint(x: Double(r2.x), y: Double(r2.y)),
        eventType: twoFingerContact.eventType(for: .up), edge: nativeEdge.rawValue,
        target: displayContext?.hidTarget ?? 0)
      try await send(messageType: "IndigoDigitizerEvent", payload: event, ownedRelease: true)
    case let .key(code):
      try await send(messageType: "IndigoKeyboardButtonEvent",
        payload: IndigoKeyboardButtonEvent(usageCode: UInt64(code), state: .up), ownedRelease: true)
    case let .button(button):
      guard let usage = button.dtuhidUsage else {
        throw FBSimulatorHIDError.notImplementedOnDTUHIDTransport(operation: "Owned Apple Pay release")
      }
      try await send(messageType: "IndigoButtonEvent",
        payload: IndigoButtonEvent(usagePage: UInt64(usage.page), usageCode: UInt64(usage.code), state: .up),
        ownedRelease: true)
    }
  }

  // MARK: Sending

  /// Wraps `payload` in a `DTUHIDMessage` and serializes it to the `xpc_object_t` `dtuhidd` decodes.
  /// Pure and stateless, so the envelope shape is unit-testable without a live daemon connection.
  nonisolated func encode(messageType: String, payload: some Encodable) throws -> xpc_object_t {
    let message = DTUHIDMessage(
      messageType: messageType, featureIdentifier: Self.digitizerServiceName, payload: payload)
    return try XPCEncoder().encode(message)
  }

  /// Bounds host enqueue and the separate guest service reply. A failed session send closes
  /// normal input admission but preserves the connection for owned UP cleanup only. Other
  /// transports, XPC errors and failed cleanup still cancel the connection. A guest reply
  /// confirms service order; it does not confirm a UIKit event or an application effect.
  func send(messageType: String, payload: some Encodable, ownedRelease: Bool = false) async throws {
    latestSendEvidence = FBSimulatorHIDSendEvidence(messageType: messageType,
      startedUptime: ProcessInfo.processInfo.systemUptime)
    var phase = "encode"
    do {
      let object = try encode(messageType: messageType, payload: payload)
      phase = "hostEnqueue"
      try await enqueueGate.perform(ownedRelease: ownedRelease) { connection.send(object, completion: $0) }
      latestSendEvidence?.hostEnqueueCompletedUptime = ProcessInfo.processInfo.systemUptime
      phase = "guestBarrier"
      latestSendEvidence?.guestBarrierStartedUptime = ProcessInfo.processInfo.systemUptime
      try await enqueueGate.performResult(operation: "DTUHID guest barrier", ownedRelease: ownedRelease) {
        connection.sendGuestBarrier(completion: $0)
      }
      latestSendEvidence?.guestBarrierCompletedUptime = ProcessInfo.processInfo.systemUptime
    } catch {
      latestSendEvidence?.failedUptime = ProcessInfo.processInfo.systemUptime
      latestSendEvidence?.failurePhase = phase
      latestSendEvidence?.errorDescription = String(describing: error)
      throw error
    }
  }

  /// Keeps the connection alive for `drainNanos` after a dispatched gesture. This wait does not
  /// acknowledge guest consumption. It runs once per send, not after every primitive.
  func flush() async throws {
    try? await Task.sleep(nanoseconds: Self.drainNanos)
  }

}

/// XPC permits send and cancellation from different threads. The handle never changes.
private final class FBSimulatorDTUHIDConnection: @unchecked Sendable {
  private let value: xpc_connection_t
  init(_ value: xpc_connection_t) { self.value = value }
  deinit { xpc_connection_cancel(value) }
  func start(gate: FBSimulatorDTUHIDEnqueueGate) {
    xpc_connection_set_event_handler(value) { [weak gate] event in
      if xpc_get_type(event) == XPC_TYPE_ERROR { gate?.disconnect() }
    }
    xpc_connection_resume(value)
  }
  func send(_ object: xpc_object_t, completion: @escaping @Sendable () -> Void) {
    xpc_connection_send_message(value, object)
    xpc_connection_send_barrier(value, completion)
  }
  func sendGuestBarrier(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    let request = FBSimulatorDTUHIDGuestBarrier.request()
    xpc_connection_send_message_with_reply(value, request, DispatchQueue.global(qos: .userInitiated)) { reply in
      completion(Result { try FBSimulatorDTUHIDGuestBarrier.validate(reply: reply) })
    }
  }
  func disconnect() { xpc_connection_cancel(value) }
}

enum FBSimulatorDTUHIDEnqueueError: Error { case connectionClosed, invalidBarrierReply }

/// FlowDeck sends this one-field request after each touch. The installed dtuhidd handler
/// creates and sends a reply before returning from the barrier branch. No UI result is encoded.
enum FBSimulatorDTUHIDGuestBarrier {
  static func request() -> xpc_object_t {
    let request = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_bool(request, "isBarrier", true)
    return request
  }

  static func validate(reply: xpc_object_t) throws {
    if xpc_get_type(reply) == XPC_TYPE_ERROR {
      throw FBSimulatorDTUHIDEnqueueError.connectionClosed
    }
    guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
      throw FBSimulatorDTUHIDEnqueueError.invalidBarrierReply
    }
  }
}

/// One connection owner for pending barriers, caller cancellation, timeout, and disconnect.
/// All mutable fields use the lock. The start closure only enqueues; it must not wait for completion.
/// Callback completion uses a separate one-shot result, so synchronous and late callbacks are safe.
final class FBSimulatorDTUHIDEnqueueGate: @unchecked Sendable {
  private let lock = NSLock()
  private let cancelConnection: @Sendable () -> Void
  private enum Admission { case open, ownedReleaseOnly, closed }
  private var admission = Admission.open
  private let retainForOwnedCleanup: Bool
  private let disconnectDrainSeconds: TimeInterval
  private var lastDispatchUptime: TimeInterval?
  private var pending: [UUID: FBSimulatorBoundedResult<Void>] = [:]

  /// `disconnectDrainSeconds` keeps the XPC connection alive after the last dispatched message
  /// before it is cancelled. Admission still closes at once; only the cancel waits.
  init(retainForOwnedCleanup: Bool = false, disconnectDrainSeconds: TimeInterval = 0,
       disconnect: @escaping @Sendable () -> Void) {
    self.retainForOwnedCleanup = retainForOwnedCleanup
    self.disconnectDrainSeconds = disconnectDrainSeconds
    cancelConnection = disconnect
  }

  /// The initial service request carries no input. Own cancellation before, during and after
  /// the reply so an unsuccessful open cannot leave a live connection behind.
  func performInitialGuestBarrier(timeout: TimeInterval = 2,
      start: (@escaping @Sendable (Result<Void, Error>) -> Void) -> Void) async throws {
    do {
      try Task.checkCancellation()
      try await performResult(timeout: timeout, operation: "DTUHID initial guest barrier", start: start)
      try Task.checkCancellation()
    } catch {
      disconnect()
      throw error
    }
  }

  func perform(timeout: TimeInterval = 2, ownedRelease: Bool = false,
               start: (@escaping @Sendable () -> Void) -> Void) async throws {
    try await performResult(timeout: timeout, operation: "DTUHID host enqueue", ownedRelease: ownedRelease) { finish in
      start { finish(.success(())) }
    }
  }

  func performResult(timeout: TimeInterval = 2, operation: String, ownedRelease: Bool = false,
                     start: (@escaping @Sendable (Result<Void, Error>) -> Void) -> Void) async throws {
    if ownedRelease { stopInput() }
    let identifier = UUID()
    let result = FBSimulatorBoundedResult<Void>()
    defer { remove(identifier) }
    do {
      try await result.value(timeout: timeout, operation: operation) { finish in
        lock.lock()
        guard admission == .open || (ownedRelease && retainForOwnedCleanup && admission == .ownedReleaseOnly) else {
          lock.unlock()
          finish(.failure(FBSimulatorDTUHIDEnqueueError.connectionClosed))
          return
        }
        pending[identifier] = result
        lastDispatchUptime = ProcessInfo.processInfo.systemUptime
        start(finish)
        lock.unlock()
      }
    } catch {
      // Stop the failed operation before returning. Only the owning session may then send
      // UP cleanup, on this same connection. A failed cleanup cannot reopen the connection.
      if retainForOwnedCleanup && !ownedRelease { stopInput() }
      else { disconnect() }
      throw error
    }
  }

  var acceptsInput: Bool {
    lock.lock()
    defer { lock.unlock() }
    return admission == .open
  }

  private func remove(_ identifier: UUID) {
    lock.lock(); pending.removeValue(forKey: identifier); lock.unlock()
  }

  private func stopInput() {
    lock.lock()
    guard admission == .open else { lock.unlock(); return }
    admission = .ownedReleaseOnly
    let waiting = Array(pending.values)
    pending.removeAll()
    lock.unlock()
    for result in waiting { result.finish(.failure(FBSimulatorDTUHIDEnqueueError.connectionClosed)) }
  }

  /// Admission closes now. The connection is cancelled once `disconnectDrainSeconds` have passed
  /// since the last dispatch, so the guest can consume input that has already been sent. The
  /// scheduled cancel retains the connection until then.
  func disconnect() {
    lock.lock()
    guard admission != .closed else { lock.unlock(); return }
    admission = .closed
    let waiting = Array(pending.values)
    pending.removeAll()
    let remaining = lastDispatchUptime.map { $0 + disconnectDrainSeconds - ProcessInfo.processInfo.systemUptime } ?? 0
    lock.unlock()
    if remaining > 0 {
      let cancel = cancelConnection
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + remaining) { cancel() }
    } else {
      cancelConnection()
    }
    for result in waiting { result.finish(.failure(FBSimulatorDTUHIDEnqueueError.connectionClosed)) }
  }
}

// MARK: - Button usage mapping

extension FBSimulatorHIDButton {

  /// The HID usage (page, code) that drives this hardware button via `dtuhidd`'s `mainScreenButtons`
  /// service. All live-confirmed against a booted Xcode 27 / iOS 26 simulator (Consumer page 0x0C).
  /// Apple Pay has no single usage — it is a double-press of the side button — so it is nil.
  var dtuhidUsage: (page: UInt16, code: UInt16)? {
    switch self {
    case .homeButton:
      return (0x0C, 0x40) // Consumer: Menu
    case .lock:
      return (0x0C, 0x30) // Consumer: Power
    case .sideButton:
      return (0x0C, 0x30) // the side button is the power/lock button
    case .siri:
      return (0x0C, 0xCF) // Consumer: Voice Command
    case .applePay:
      return nil // double-press of the side button; not a single HID usage
    }
  }
}
