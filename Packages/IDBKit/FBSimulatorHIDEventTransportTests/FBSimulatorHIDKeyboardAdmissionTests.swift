import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

struct FBSimulatorHIDKeyboardAdmissionTests {
  @Test func checksEveryDownButNeverUp() async throws {
    let fixture = try KeyboardFixture()
    let gate = KeyboardGate()
    let receipt = try await fixture.session.execute(.composite([
      .shortKeyPress(4), .shortKeyPress(40), .shortKeyPress(5)
    ]), keyboardAdmissionGuard: gate)
    #expect(await gate.codes == [4, 40, 5])
    #expect(fixture.transport.events == ["down:4", "up:4", "down:40", "up:40", "down:5", "up:5"])
    #expect(receipt.enqueuedEventCount == 6)
    #expect(receipt.cleanup == .notNeeded)
    _ = try await fixture.session.close()
  }

  @Test func laterRejectionStopsNextKeyWithoutReplay() async throws {
    let fixture = try KeyboardFixture()
    let gate = KeyboardGate(rejectCall: 3)
    do {
      _ = try await fixture.session.execute(.composite([
        .shortKeyPress(4), .shortKeyPress(40), .shortKeyPress(5)
      ]), keyboardAdmissionGuard: gate)
      Issue.record("The third key down must be rejected")
    } catch let FBSimulatorHIDSessionError.interrupted(reason, cleanup) {
      guard case .inputAdmissionRejected = reason else { Issue.record("Wrong interruption"); return }
      #expect(cleanup == .notNeeded)
    }
    #expect(await gate.codes == [4, 40, 5])
    #expect(fixture.transport.events == ["down:4", "up:4", "down:40", "up:40"])
    let evidence = try #require(await fixture.session.executionEvidence())
    #expect(evidence.phase == .admission)
    #expect(evidence.sentPrimitiveCount == 4)
    #expect(evidence.allInputsReleasedBeforeCleanup)
    #expect(await fixture.session.status().state == .invalidated)
    _ = try await fixture.session.close()
  }

  @Test(arguments: [false, true])
  func failureReleasesHeldModifierWithoutAnotherGuard(cancel: Bool) async throws {
    let fixture = try KeyboardFixture()
    let gate = KeyboardGate(rejectCall: 2, cancel: cancel)
    do {
      _ = try await fixture.session.execute(.composite([
        .keyboard(direction: .down, keyCode: 225),
        .shortKeyPress(4),
        .keyboard(direction: .up, keyCode: 225)
      ]), keyboardAdmissionGuard: gate)
      Issue.record("The second key down must stop")
    } catch let FBSimulatorHIDSessionError.interrupted(reason, cleanup) {
      if cancel { #expect(reason == .cancelled) }
      else if case .inputAdmissionRejected = reason {} else { Issue.record("Wrong interruption") }
      #expect(cleanup == .releaseEnqueuedAndDrained)
    }
    #expect(await gate.codes == [225, 4])
    #expect(fixture.transport.events == ["down:225", "up:225"])
    let cleanup = try #require(await fixture.session.cleanupEvidence())
    #expect(cleanup.releases.count == 1)
    #expect(cleanup.releases.first?.returnedSuccessfully == true)
    #expect(fixture.transport.disconnected)
    _ = try await fixture.session.close()
  }

  @Test func requiresLiveProviderBeforeAnySend() async throws {
    let fixture = try KeyboardFixture(live: false)
    let gate = KeyboardGate()
    do {
      _ = try await fixture.session.execute(.shortKeyPress(4), keyboardAdmissionGuard: gate)
      Issue.record("A live provider is required")
    } catch FBSimulatorHIDSessionError.invalidEvent {}
    #expect(await gate.codes.isEmpty)
    #expect(fixture.transport.events.isEmpty)
    _ = try await fixture.session.close()
  }

  @Test func rejectsMixedTouchBeforeAnySend() async throws {
    let fixture = try KeyboardFixture()
    let gate = KeyboardGate()
    do {
      _ = try await fixture.session.execute(.composite([
        .shortKeyPress(4), .tapAt(x: 10, y: 20)
      ]), keyboardAdmissionGuard: gate)
      Issue.record("Keyboard admission cannot admit touch input")
    } catch FBSimulatorHIDSessionError.invalidEvent {}
    #expect(await gate.codes.isEmpty)
    #expect(fixture.transport.events.isEmpty)
    _ = try await fixture.session.close()
  }

  @Test func rejectsDelayOnlyBeforeAnySend() async throws {
    let fixture = try KeyboardFixture()
    let gate = KeyboardGate()
    do {
      _ = try await fixture.session.execute(.delay(0), keyboardAdmissionGuard: gate)
      Issue.record("A keyboard down is required")
    } catch FBSimulatorHIDSessionError.invalidEvent {}
    #expect(await gate.codes.isEmpty)
    #expect(fixture.transport.events.isEmpty)
    _ = try await fixture.session.close()
  }

  @Test func existingTouchGuardStillRunsOnce() async throws {
    let fixture = try KeyboardFixture()
    let gate = FirstEventGate()
    _ = try await fixture.session.execute(.tapAt(x: 10, y: 20), admissionGuard: gate)
    #expect(await gate.calls == 1)
    #expect(fixture.transport.events == ["touch:down", "touch:up"])
    _ = try await fixture.session.close()
  }

  @Test func existingUnguardedKeyboardOverloadStillWorks() async throws {
    let fixture = try KeyboardFixture(live: false)
    let receipt = try await fixture.session.execute(.shortKeyPress(4))
    #expect(receipt.enqueuedEventCount == 2)
    #expect(fixture.transport.events == ["down:4", "up:4"])
    _ = try await fixture.session.close()
  }

  @Test(arguments: ["touch", "pair", "key"])
  func changedContextDuringLongDelayReleasesBeforeDelayEnds(kind: String) async throws {
    let context = try FBSimulatorHIDDisplayContext(hidTarget: 3,
      nativePixelSize: CGSize(width: 600, height: 900), scale: 3, rotation: .rot0)
    let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "delay-check", bootIdentity: "boot",
      screenID: 3, screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58", axDisplayID: 3,
      displayContext: context, poseRevision: "open")
    let transport = KeyboardTransport()
    let start = ProcessInfo.processInfo.systemUptime
    let provider = ExpiringInputProvider(value: observation, validUntil: start + 0.15)
    let session = FBSimulatorHIDSession(transport: transport, observation: observation,
      freshnessProvider: provider, liveProvider: provider)
    let down: FBSimulatorHIDEvent
    let up: FBSimulatorHIDEvent
    switch kind {
    case "touch": down = .touch(direction: .down, x: 10, y: 20); up = .touch(direction: .up, x: 10, y: 20)
    case "pair":
      down = .twoFingerTouch(direction: .down, finger1: CGPoint(x: 10, y: 20), finger2: CGPoint(x: 30, y: 20))
      up = .twoFingerTouch(direction: .up, finger1: CGPoint(x: 10, y: 20), finger2: CGPoint(x: 30, y: 20))
    default: down = .keyboard(direction: .down, keyCode: 225); up = .keyboard(direction: .up, keyCode: 225)
    }
    do {
      _ = try await session.execute(.composite([down, .delay(2), up]))
      Issue.record("A changed context must stop the held input")
    } catch let FBSimulatorHIDSessionError.interrupted(reason, cleanup) {
      #expect(reason == .staleContext && cleanup == .releaseEnqueuedAndDrained)
    }
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    let execution = try #require(await session.executionEvidence())
    #expect(execution.phase == .delay && execution.sentPrimitiveCount == 1)
    let cleanup = try #require(await session.cleanupEvidence())
    #expect(cleanup.releases.count == 1 && cleanup.releases[0].returnedSuccessfully)
    #expect(transport.events.count == 2 && transport.disconnected)
    _ = try await session.close()
  }
}

private struct ExpiringInputProvider: FBSimulatorHIDLiveFreshnessProvider, FBSimulatorHIDCleanupIdentityProvider {
  let value: FBSimulatorHIDSessionObservation
  let validUntil: TimeInterval
  func observation() async throws -> FBSimulatorHIDSessionObservation { value }
  func validateCurrentRevision(expected: FBSimulatorHIDSessionObservation) throws {
    guard expected == value, ProcessInfo.processInfo.systemUptime < validUntil else {
      throw FBSimulatorHIDSessionError.interrupted(reason: .staleContext, cleanup: .notNeeded)
    }
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

private struct KeyboardFixture {
  let transport: KeyboardTransport
  let session: FBSimulatorHIDSession

  init(live: Bool = true) throws {
    let transport = KeyboardTransport()
    self.transport = transport
    let context = try FBSimulatorHIDDisplayContext(hidTarget: 3,
      nativePixelSize: CGSize(width: 600, height: 900), scale: 3, rotation: .rot0)
    let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "local-unit-check",
      bootIdentity: "boot", screenID: 3, screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58",
      axDisplayID: 3, displayContext: context, poseRevision: "open")
    let provider = KeyboardProvider(value: observation)
    session = FBSimulatorHIDSession(transport: transport, observation: observation,
      freshnessProvider: provider, liveProvider: live ? provider : nil)
  }
}

// This is the existing internal dependency boundary; no production test route is added.
private struct KeyboardProvider: FBSimulatorHIDLiveFreshnessProvider {
  let value: FBSimulatorHIDSessionObservation
  func observation() async throws -> FBSimulatorHIDSessionObservation { value }
  func validateCurrentRevision(expected: FBSimulatorHIDSessionObservation) throws {
    guard expected == value else {
      throw FBSimulatorHIDSessionError.interrupted(reason: .staleContext, cleanup: .notNeeded)
    }
  }
  func close() {}
}

private actor KeyboardGate: FBSimulatorHIDKeyboardAdmissionGuard {
  private(set) var codes: [UInt32] = []
  let rejectCall: Int?
  let cancel: Bool
  init(rejectCall: Int? = nil, cancel: Bool = false) {
    self.rejectCall = rejectCall; self.cancel = cancel
  }
  func validateKeyDown(observation: FBSimulatorHIDSessionObservation, keyCode: UInt32) async throws {
    codes.append(keyCode)
    if codes.count == rejectCall {
      if cancel { throw CancellationError() }
      throw FBSimulatorHIDSessionError.invalidEvent("Focus was lost")
    }
  }
}

private actor FirstEventGate: FBSimulatorHIDInputAdmissionGuard {
  private(set) var calls = 0
  func validate(observation: FBSimulatorHIDSessionObservation, firstEvent: FBSimulatorHIDEvent) async throws {
    calls += 1
  }
}

private final class KeyboardTransport: FBSimulatorHIDTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private var didDisconnect = false
  var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
  var disconnected: Bool { lock.lock(); defer { lock.unlock() }; return didDisconnect }
  private func append(_ value: String) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
  func disconnect() { lock.lock(); defer { lock.unlock() }; didDisconnect = true }
  func sendTouch(direction: FBSimulatorHIDDirection, x: Double, y: Double) async throws {
    append("touch:" + direction.name)
  }
  func sendTwoFingerTouch(direction: FBSimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint) async throws {
    append("pair:" + direction.name)
  }
  func sendButton(direction: FBSimulatorHIDDirection, button: FBSimulatorHIDButton) async throws {
    append("button:" + direction.name)
  }
  func sendKeyboard(direction: FBSimulatorHIDDirection, keyCode: UInt32) async throws {
    append(direction.name + ":" + String(keyCode))
  }
  func flush() async throws {}
}
