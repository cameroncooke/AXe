import CoreGraphics
import Foundation
import Testing
import XPC
@testable import FBSimulatorControl

@Suite("Complete legacy keyboard transport reuse", .serialized)
struct FBSimulatorHIDCompleteLegacyKeyboardTests {
  @Test func repeatedModifiersAndTargetKeepTheirOrderAndReuse() async throws {
    let fixture = try LegacyKeyboardFixture()
    defer { fixture.close() }
    let owner = FBSimulatorHIDTransportOwner()
    let first = try await fixture.session(owner: owner)
    let modifiers: [UInt32] = [4, 4, 255, 0, 224, 1, 225, 225]
    let events = modifiers.map { FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: $0) }
      + [.keyboard(direction: .down, keyCode: 225), .keyboard(direction: .up, keyCode: 225)]
      + modifiers.reversed().map { .keyboard(direction: .up, keyCode: $0) }
    let receipt = try await first.executeLegacyKeyboard(.composite(events))
    #expect(receipt.enqueuedEventCount == 18 && receipt.cleanup == .notNeeded)
    #expect(fixture.peer.keyboard == modifiers.map { "down:" + String($0) }
      + ["down:225", "up:225"] + modifiers.reversed().map { "up:" + String($0) })
    _ = try await first.close()
    let next = try await owner.reserve(observation: fixture.observation)
    #expect(next.transport === fixture.transport)
    let second = fixture.session(owner: owner, reservation: next)
    _ = try await second.executeLegacyKeyboard(.shortKeyPress(5))
    _ = try await second.close()
    let final = try await owner.reserve(observation: fixture.observation)
    #expect(final.transport === fixture.transport)
    #expect(final.connectionID == next.connectionID)
    #expect(Array(fixture.peer.keyboard.suffix(2)) == ["down:5", "up:5"])
    await owner.discard(final.identifier)
    await owner.close()
  }

  @Test func rawStreamLargerThanAgentLimitsHasNoNewCap() async throws {
    let fixture = try LegacyKeyboardFixture()
    defer { fixture.close() }
    let owner = FBSimulatorHIDTransportOwner()
    let session = try await fixture.session(owner: owner)
    let events = (0..<300).map { _ in FBSimulatorHIDEvent.shortKeyPress(4) }
    let receipt = try await session.executeLegacyKeyboard(.composite(events))
    #expect(receipt.enqueuedEventCount == 600)
    #expect(fixture.peer.keyboard == (0..<300).flatMap { _ in ["down:4", "up:4"] })
    _ = try await session.close()
    let next = try await owner.reserve(observation: fixture.observation)
    #expect(next.transport === fixture.transport)
    await owner.discard(next.identifier)
    await owner.close()
  }

  @Test(arguments: [false, true])
  func legacyBatchAndTouchRemainIneligibleForReuse(touch: Bool) async throws {
    let fixture = try LegacyKeyboardFixture()
    defer { fixture.close() }
    let owner = FBSimulatorHIDTransportOwner()
    let session = try await fixture.session(owner: owner)
    _ = try await session.submitLegacyBatchPart(touch ? .tapAt(x: 10, y: 20) : .shortKeyPress(4))
    _ = try await session.close()
    let next = try await owner.reserve(observation: fixture.observation)
    #expect(next.transport == nil)
    await owner.discard(next.identifier)
    await owner.close()
  }

  @Test(arguments: [false, true])
  func invalidCompleteStreamCannotSendOrCache(mixedTouch: Bool) async throws {
    let fixture = try LegacyKeyboardFixture()
    defer { fixture.close() }
    let owner = FBSimulatorHIDTransportOwner()
    let session = try await fixture.session(owner: owner)
    let event: FBSimulatorHIDEvent = mixedTouch
      ? .composite([.shortKeyPress(4), .tapAt(x: 10, y: 20)])
      : .keyboard(direction: .down, keyCode: 4)
    await #expect(throws: (any Error).self) { _ = try await session.executeLegacyKeyboard(event) }
    #expect(fixture.peer.inputCount == 0)
    _ = try await session.close()
    let next = try await owner.reserve(observation: fixture.observation)
    #expect(next.transport == nil)
    await owner.discard(next.identifier)
    await owner.close()
  }

  @Test func cancellationReleasesHeldKeyAndCannotCache() async throws {
    let fixture = try LegacyKeyboardFixture()
    defer { fixture.close() }
    let owner = FBSimulatorHIDTransportOwner()
    let session = try await fixture.session(owner: owner)
    let operation = Task {
      try await session.executeLegacyKeyboard(.composite([
        .keyboard(direction: .down, keyCode: 225), .delay(5),
        .keyboard(direction: .up, keyCode: 225)
      ]))
    }
    try await fixture.peer.waitForKeyboardCount(1)
    operation.cancel()
    do { _ = try await operation.value; Issue.record("Cancelled input must fail") }
    catch let FBSimulatorHIDSessionError.interrupted(reason, cleanup) {
      #expect(reason == .cancelled && cleanup == .releaseEnqueuedAndDrained)
    }
    #expect(fixture.peer.keyboard == ["down:225", "up:225"])
    _ = try await session.close()
    let next = try await owner.reserve(observation: fixture.observation)
    #expect(next.transport == nil)
    await owner.discard(next.identifier)
    await owner.close()
  }

  @Test func cancellationBeforeInputCannotSendOrCache() async throws {
    let fixture = try LegacyKeyboardFixture()
    defer { fixture.close() }
    let owner = FBSimulatorHIDTransportOwner()
    let session = try await fixture.session(owner: owner)
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await session.executeLegacyKeyboard(.shortKeyPress(4))
    }
    do { _ = try await operation.value; Issue.record("Cancelled input must fail") }
    catch let FBSimulatorHIDSessionError.interrupted(reason, cleanup) {
      #expect(reason == .cancelled && cleanup == .notNeeded)
    }
    #expect(fixture.peer.inputCount == 0)
    _ = try await session.close()
    let next = try await owner.reserve(observation: fixture.observation)
    #expect(next.transport == nil)
    await owner.discard(next.identifier)
    await owner.close()
  }

  @Test func changedRevisionCannotReturnCompletedConnection() async throws {
    let fixture = try LegacyKeyboardFixture()
    defer { fixture.close() }
    let owner = FBSimulatorHIDTransportOwner()
    let session = try await fixture.session(owner: owner)
    _ = try await session.executeLegacyKeyboard(.shortKeyPress(4))
    fixture.provider.invalidate()
    _ = try await session.close()
    let next = try await owner.reserve(observation: fixture.observation)
    #expect(next.transport == nil)
    await owner.discard(next.identifier)
    await owner.close()
  }
}

/// A normal host XPC peer exercises the real enqueue/reply gate without a simulator.
private final class LegacyKeyboardFixture {
  let peer: LegacyKeyboardPeer
  let listener: xpc_connection_t
  let transport: FBSimulatorDTUHIDTransport
  let observation: FBSimulatorHIDSessionObservation
  let provider: LegacyKeyboardProvider

  init() throws {
    let context = try FBSimulatorHIDDisplayContext(hidTarget: 1,
      nativePixelSize: CGSize(width: 600, height: 900), scale: 3, rotation: .rot0)
    let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "legacy-keyboard-host",
      bootIdentity: "boot", screenID: 1,
      screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58", axDisplayID: 1,
      displayContext: context, poseRevision: "rigid")
    self.observation = observation
    provider = LegacyKeyboardProvider(observation)
    let peer = LegacyKeyboardPeer()
    self.peer = peer
    let listener = xpc_connection_create(nil, nil)
    self.listener = listener
    xpc_connection_set_event_handler(listener) { connection in
      guard xpc_get_type(connection) == XPC_TYPE_CONNECTION else { return }
      peer.accept(connection)
    }
    xpc_connection_resume(listener)
    let endpoint = xpc_endpoint_create(listener)
    let connection = xpc_connection_create_from_endpoint(endpoint)
    transport = FBSimulatorDTUHIDTransport(connection: connection,
      mainScreenSize: context.nativePixelSize, mainScreenScale: 3,
      displayContext: context, ownedCleanup: true)
  }

  func session(owner: FBSimulatorHIDTransportOwner) async throws -> FBSimulatorHIDSession {
    session(owner: owner, reservation: try await owner.reserve(observation: observation))
  }

  func session(owner: FBSimulatorHIDTransportOwner,
               reservation: FBSimulatorHIDTransportReservation) -> FBSimulatorHIDSession {
    let lease = FBSimulatorHIDTransportLease(owner: owner,
      reservationID: reservation.identifier, connectionID: reservation.connectionID,
      observation: observation, transport: reservation.transport ?? transport)
    return FBSimulatorHIDSession(transport: lease.transport, observation: observation,
      freshnessProvider: provider, liveProvider: provider, transportLease: lease)
  }

  func close() {
    transport.disconnect()
    xpc_connection_cancel(listener)
    peer.close()
  }
}

private final class LegacyKeyboardPeer: @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [xpc_connection_t] = []
  private var events: [String] = []
  private var inputs = 0
  var keyboard: [String] { lock.lock(); defer { lock.unlock() }; return events }
  var inputCount: Int { lock.lock(); defer { lock.unlock() }; return inputs }

  func accept(_ connection: xpc_connection_t) {
    lock.lock(); connections.append(connection); lock.unlock()
    xpc_connection_set_event_handler(connection) { [weak self] message in
      guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
      if xpc_dictionary_get_bool(message, "isBarrier") {
        if let reply = xpc_dictionary_create_reply(message) { xpc_connection_send_message(connection, reply) }
        return
      }
      self?.record(message)
    }
    xpc_connection_resume(connection)
  }

  private func record(_ message: xpc_object_t) {
    let type = xpc_dictionary_get_string(message, "messageType").map { String(cString: $0) }
    let payload = xpc_dictionary_get_value(message, "payload")
    lock.lock()
    defer { lock.unlock() }
    inputs += 1
    guard type == "IndigoKeyboardButtonEvent", let payload else { return }
    let state = xpc_dictionary_get_uint64(payload, "state")
    let code = xpc_dictionary_get_uint64(payload, "usageCode")
    events.append((state == 1 ? "down:" : "up:") + String(code))
  }

  func waitForKeyboardCount(_ count: Int) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while keyboard.count < count {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw FBSimulatorHIDSessionError.invalidEvent("Host peer did not receive the key")
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  func close() {
    lock.lock(); let peers = connections; connections.removeAll(); lock.unlock()
    for peer in peers { xpc_connection_cancel(peer) }
  }
}

private final class LegacyKeyboardProvider: FBSimulatorHIDLiveFreshnessProvider,
    FBSimulatorHIDCleanupIdentityProvider, @unchecked Sendable {
  let value: FBSimulatorHIDSessionObservation
  private let lock = NSLock()
  private var valid = true
  init(_ value: FBSimulatorHIDSessionObservation) { self.value = value }
  func observation() async throws -> FBSimulatorHIDSessionObservation { value }
  func validateCurrentRevision(expected: FBSimulatorHIDSessionObservation) throws {
    lock.lock(); let current = valid; lock.unlock()
    guard current && expected == value else {
      throw FBSimulatorHIDSessionError.interrupted(reason: .staleContext, cleanup: .notNeeded)
    }
  }
  func cleanupIdentity() async throws -> FBSimulatorHIDCleanupIdentity {
    let now = ProcessInfo.processInfo.systemUptime
    return FBSimulatorHIDCleanupIdentity(simulatorUDID: value.simulatorUDID,
      bootIdentity: value.bootIdentity, screenID: value.screenID,
      screenUUID: value.screenUniqueID, nativePixelWidth: value.displayContext.nativePixelSize.width,
      nativePixelHeight: value.displayContext.nativePixelSize.height,
      scale: value.displayContext.scale, startedUptime: now, finishedUptime: now)
  }
  func invalidate() { lock.lock(); valid = false; lock.unlock() }
  func close() {}
}
