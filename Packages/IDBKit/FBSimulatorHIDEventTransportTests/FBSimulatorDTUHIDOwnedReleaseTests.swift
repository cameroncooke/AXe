import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

struct FBSimulatorDTUHIDOwnedReleaseTests {
  @Test func timeoutStopsInputButAllowsOnlyOwnedRelease() async throws {
    let witness = GateWitness()
    let gate = FBSimulatorDTUHIDEnqueueGate(retainForOwnedCleanup: true) { witness.disconnect() }
    do {
      try await gate.performResult(timeout: 0.02, operation: "Lost normal guest reply") { witness.capture($0) }
      Issue.record("The lost reply must fail")
    } catch { #expect(String(describing: error).contains("timed out")) }
    #expect(!witness.disconnected)
    await expectNormalClosed(gate, witness)
    try await gate.perform(ownedRelease: true) { finish in witness.record("owned-UP-host"); finish() }
    try await gate.performResult(operation: "Owned UP guest reply", ownedRelease: true) { finish in
      witness.record("owned-UP-guest"); finish(.success(()))
    }
    #expect(witness.events == ["owned-UP-host", "owned-UP-guest"])
    #expect(!witness.disconnected)
    gate.disconnect()
    #expect(witness.disconnected)
  }

  @Test func cancellationStopsInputAndAllowsOwnedRelease() async throws {
    let witness = GateWitness()
    let gate = FBSimulatorDTUHIDEnqueueGate(retainForOwnedCleanup: true) { witness.disconnect() }
    let input = Task {
      try await gate.performResult(operation: "Cancelled normal send") { witness.capture($0) }
    }
    try await witness.waitForStart()
    input.cancel()
    do { try await input.value; Issue.record("Cancelled input must fail") }
    catch { #expect(error is CancellationError) }
    #expect(!witness.disconnected)
    await expectNormalClosed(gate, witness)
    try await gate.perform(ownedRelease: true) { finish in witness.record("owned-UP"); finish() }
    #expect(witness.events == ["owned-UP"])
    gate.disconnect()
  }

  @Test func lateNormalReplyCannotReopenInput() async throws {
    let witness = GateWitness()
    let gate = FBSimulatorDTUHIDEnqueueGate(retainForOwnedCleanup: true) { witness.disconnect() }
    do {
      try await gate.performResult(timeout: 0.02, operation: "Lost normal reply") { witness.capture($0) }
      Issue.record("Lost reply must fail")
    } catch {}
    witness.complete(.success(()))
    await expectNormalClosed(gate, witness)
    try await gate.perform(ownedRelease: true) { finish in witness.record("owned-UP"); finish() }
    witness.complete(.success(()))
    await expectNormalClosed(gate, witness)
    #expect(witness.events == ["owned-UP"])
    gate.disconnect()
  }

  @Test func failedOwnedReleaseCancelsAndCannotBeRetried() async throws {
    let witness = GateWitness()
    let gate = FBSimulatorDTUHIDEnqueueGate(retainForOwnedCleanup: true) { witness.disconnect() }
    do {
      try await gate.performResult(operation: "Failed owned UP", ownedRelease: true) { finish in
        witness.record("owned-UP"); finish(.failure(FBSimulatorDTUHIDEnqueueError.invalidBarrierReply))
      }
      Issue.record("Failed cleanup must fail")
    } catch {}
    #expect(witness.disconnected)
    do {
      try await gate.perform(ownedRelease: true) { finish in witness.record("unexpected-retry"); finish() }
      Issue.record("Closed cleanup must fail")
    } catch {}
    #expect(witness.events == ["owned-UP"])
  }

  @Test func explicitConnectionLossRejectsOwnedRelease() async throws {
    let witness = GateWitness()
    let gate = FBSimulatorDTUHIDEnqueueGate(retainForOwnedCleanup: true) { witness.disconnect() }
    gate.disconnect()
    do {
      try await gate.perform(ownedRelease: true) { finish in witness.record("unexpected-UP"); finish() }
      Issue.record("Disconnected cleanup must fail")
    } catch {}
    #expect(witness.disconnected)
    #expect(witness.events.isEmpty)
  }

  @Test func rawTransportTimeoutStillCancels() async throws {
    let witness = GateWitness()
    let gate = FBSimulatorDTUHIDEnqueueGate { witness.disconnect() }
    do {
      try await gate.performResult(timeout: 0.02, operation: "Lost raw reply") { witness.capture($0) }
      Issue.record("Raw timeout must fail")
    } catch {}
    #expect(witness.disconnected)
    do {
      try await gate.perform(ownedRelease: true) { finish in witness.record("unexpected-UP"); finish() }
      Issue.record("Raw transport has no owned cleanup admission")
    } catch {}
    #expect(witness.events.isEmpty)
  }

  @Test func initialBarrierFailureStillCancels() async throws {
    let witness = GateWitness()
    let gate = FBSimulatorDTUHIDEnqueueGate(retainForOwnedCleanup: true) { witness.disconnect() }
    do {
      try await gate.performInitialGuestBarrier(timeout: 0.02) { witness.capture($0) }
      Issue.record("Initial barrier timeout must fail")
    } catch {}
    #expect(witness.disconnected)
  }

  @Test func sessionUsesOwnedUPAfterNormalSendTimeout() async throws {
    let transport = TimedOutKeyboardTransport()
    let context = try FBSimulatorHIDDisplayContext(hidTarget: 3,
      nativePixelSize: CGSize(width: 600, height: 900), scale: 3, rotation: .rot0)
    let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "owned-release-test",
      bootIdentity: "boot", screenID: 3, screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58",
      axDisplayID: 3, displayContext: context, poseRevision: "open")
    let provider = ReleaseIdentityProvider(value: observation)
    let session = FBSimulatorHIDSession(transport: transport, observation: observation,
      freshnessProvider: provider, liveProvider: provider)
    do {
      _ = try await session.execute(.shortKeyPress(4))
      Issue.record("The failed DOWN acknowledgement must stop the action")
    } catch let FBSimulatorHIDSessionError.interrupted(reason, cleanup) {
      guard case .transportFailure = reason else { Issue.record("Wrong interruption"); return }
      #expect(cleanup == .releaseEnqueuedAndDrained)
    }
    #expect(transport.witness.events == ["normal-DOWN:4", "owned-UP:4", "drain"])
    #expect(transport.witness.disconnected)
    let evidence = try #require(await session.cleanupEvidence())
    #expect(evidence.releases.count == 1)
    #expect(evidence.releases[0].returnedSuccessfully)
    #expect(!evidence.timedOut)
    #expect(await session.status().state == .invalidated)
    _ = try await session.close()
  }

  private func expectNormalClosed(_ gate: FBSimulatorDTUHIDEnqueueGate, _ witness: GateWitness) async {
    do {
      try await gate.perform { finish in witness.record("unexpected-normal-input"); finish() }
      Issue.record("Normal input must remain closed")
    } catch {}
    #expect(!witness.events.contains("unexpected-normal-input"))
  }
}

private final class GateWitness: @unchecked Sendable {
  private let lock = NSLock()
  private let started = FBSimulatorBoundedResult<Bool>()
  private var callback: (@Sendable (Result<Void, Error>) -> Void)?
  private var storedEvents: [String] = []
  private var storedDisconnected = false
  var events: [String] { lock.lock(); defer { lock.unlock() }; return storedEvents }
  var disconnected: Bool { lock.lock(); defer { lock.unlock() }; return storedDisconnected }
  func record(_ value: String) { lock.lock(); storedEvents.append(value); lock.unlock() }
  func disconnect() { lock.lock(); storedDisconnected = true; lock.unlock() }
  func capture(_ value: @escaping @Sendable (Result<Void, Error>) -> Void) {
    lock.lock(); callback = value; lock.unlock()
    started.finish(.success(true))
  }
  func complete(_ result: Result<Void, Error>) {
    lock.lock(); let finish = callback; lock.unlock()
    finish?(result)
  }
  func waitForStart() async throws {
    _ = try await started.value(timeout: 1, operation: "Local send start") { _ in }
  }
}

private final class TimedOutKeyboardTransport: FBSimulatorHIDTransport,
    FBSimulatorHIDOwnedCleanupTransport, @unchecked Sendable {
  let witness: GateWitness
  private let gate: FBSimulatorDTUHIDEnqueueGate
  init() {
    let witness = GateWitness()
    self.witness = witness
    gate = FBSimulatorDTUHIDEnqueueGate(retainForOwnedCleanup: true) { witness.disconnect() }
  }
  func disconnect() { gate.disconnect() }
  func sendTouch(direction: FBSimulatorHIDDirection, x: Double, y: Double) async throws {
    throw FBSimulatorHIDSessionError.invalidEvent("Keyboard-only local proof")
  }
  func sendTwoFingerTouch(direction: FBSimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint) async throws {
    throw FBSimulatorHIDSessionError.invalidEvent("Keyboard-only local proof")
  }
  func sendButton(direction: FBSimulatorHIDDirection, button: FBSimulatorHIDButton) async throws {
    throw FBSimulatorHIDSessionError.invalidEvent("Keyboard-only local proof")
  }
  func sendKeyboard(direction: FBSimulatorHIDDirection, keyCode: UInt32) async throws {
    witness.record("normal-" + (direction == .down ? "DOWN:" : "UP:") + String(keyCode))
    try await gate.performResult(timeout: 0.02, operation: "Missing keyboard guest reply") { _ in }
  }
  func releaseOwnedInput(_ release: FBSimulatorHIDOwnedRelease) async throws {
    guard case let .key(code) = release else {
      throw FBSimulatorHIDSessionError.invalidEvent("Keyboard-only local proof")
    }
    try await gate.perform(ownedRelease: true) { finish in
      witness.record("owned-UP:" + String(code)); finish()
    }
    try await gate.performResult(operation: "Owned UP guest reply", ownedRelease: true) { $0(.success(())) }
  }
  func flush() async throws { witness.record("drain") }
}

private struct ReleaseIdentityProvider: FBSimulatorHIDLiveFreshnessProvider, FBSimulatorHIDCleanupIdentityProvider {
  let value: FBSimulatorHIDSessionObservation
  func observation() async throws -> FBSimulatorHIDSessionObservation { value }
  func validateCurrentRevision(expected: FBSimulatorHIDSessionObservation) throws {
    guard expected == value else { throw FBSimulatorHIDSessionError.invalidObservation("Changed local context") }
  }
  func cleanupIdentity() async throws -> FBSimulatorHIDCleanupIdentity {
    let now = ProcessInfo.processInfo.systemUptime
    return FBSimulatorHIDCleanupIdentity(simulatorUDID: value.simulatorUDID, bootIdentity: value.bootIdentity,
      screenID: value.screenID, screenUUID: value.screenUniqueID,
      nativePixelWidth: value.displayContext.nativePixelSize.width,
      nativePixelHeight: value.displayContext.nativePixelSize.height, scale: value.displayContext.scale,
      startedUptime: now, finishedUptime: now)
  }
  func close() {}
}
