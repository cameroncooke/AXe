import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

struct FBSimulatorHIDRetainedIdleTests {
  @Test(arguments: [false, true])
  func idleChangeReleasesRetainedInput(pair: Bool) async throws {
    let fixture = try IdleFixture()
    let token = try #require(try await fixture.begin(pair: pair).token)
    _ = try await fixture.move(token, pair: pair)
    let observationReads = fixture.provider.observationReads
    fixture.provider.invalidate()
    try await waitUntil { await fixture.session.status().state == .invalidated }
    let status = await fixture.session.status()
    #expect(!status.hasRetainedContact && status.enqueuedEventCount == 2)
    #expect(status.lastCleanup == .releaseEnqueuedAndDrained)
    #expect(fixture.provider.observationReads == observationReads)
    let kind = pair ? "pair" : "touch"
    #expect(fixture.transport.events == [kind + ":down", kind + ":down", kind + ":up"])
    let cleanup = try #require(await fixture.session.cleanupEvidence())
    #expect(cleanup.releases.count == 1 && cleanup.releases[0].returnedSuccessfully)
    do {
      _ = try await fixture.move(token, pair: pair)
      Issue.record("An old token must reject before input")
    } catch FBSimulatorHIDSessionError.invalidated {}
    #expect(await fixture.session.status().enqueuedEventCount == 2)
    let closed = try await fixture.session.close()
    #expect(closed.token == nil && closed.cleanup == .releaseEnqueuedAndDrained)
    #expect(fixture.transport.events.count == 3)
  }

  @Test func closeJoinsOnlyOwnedIdleCleanup() async throws {
    let gate = IdleGate()
    let fixture = try IdleFixture(releaseGate: gate)
    _ = try await fixture.begin(pair: true)
    fixture.provider.invalidate()
    try await waitUntil { fixture.transport.events == ["pair:down", "pair:up"] }
    let closes = IdleCompletions()
    let first = Task {
      let receipt = try await fixture.session.close()
      await closes.add()
      return receipt
    }
    let second = Task {
      let receipt = try await fixture.session.close()
      await closes.add()
      return receipt
    }
    do {
      _ = try await fixture.begin(pair: true)
      Issue.record("Idle cleanup must own admission")
    } catch FBSimulatorHIDSessionError.busy {}
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(await closes.count == 0)
    await gate.open()
    for receipt in [try await first.value, try await second.value] {
      #expect(receipt.cleanup == .releaseEnqueuedAndDrained && receipt.token == nil)
      #expect(receipt.enqueuedEventCount == 0)
    }
    #expect(await closes.count == 2)
    #expect(fixture.transport.events == ["pair:down", "pair:up"])
    #expect(await fixture.session.status().state == .closed)
  }

  @Test func closeDoesNotJoinNormalCallerExecution() async throws {
    let gate = IdleGate()
    let fixture = try IdleFixture(downGate: gate)
    let action = Task {
      try await fixture.session.execute(.tapAt(x: 10, y: 20))
    }
    try await waitUntil { fixture.transport.events == ["touch:down"] }
    do {
      _ = try await fixture.session.close()
      Issue.record("Concurrent caller execution must still reject as busy")
    } catch FBSimulatorHIDSessionError.busy {}
    await gate.open()
    #expect(try await action.value.enqueuedEventCount == 2)
    _ = try await fixture.session.close()
    #expect(fixture.transport.events == ["touch:down", "touch:up"])
  }

  @Test func endStopsIdleObservation() async throws {
    let fixture = try IdleFixture()
    let token = try #require(try await fixture.begin(pair: true).token)
    let ended = try await fixture.session.end(token)
    #expect(ended.token == nil)
    let checks = fixture.provider.localChecks
    fixture.provider.invalidate()
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(fixture.provider.localChecks == checks)
    #expect(fixture.transport.events == ["pair:down", "pair:up"])
    #expect(await fixture.session.status().state == .ready)
    _ = try await fixture.session.close()
  }

  @Test func closeStopsIdleObservation() async throws {
    let fixture = try IdleFixture()
    _ = try await fixture.begin(pair: false)
    _ = try await fixture.session.close()
    let checks = fixture.provider.localChecks
    fixture.provider.invalidate()
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(fixture.provider.localChecks == checks)
    #expect(fixture.transport.events == ["touch:down", "touch:up"])
    #expect(await fixture.session.status().state == .closed)
  }

  @Test func monitorDoesNotRetainItsSessionAcrossSleep() async throws {
    let fixture = try IdleFixture()
    let provider = fixture.provider
    let transport = IdleTransport()
    var session: FBSimulatorHIDSession? = FBSimulatorHIDSession(transport: transport,
      observation: provider.value, freshnessProvider: provider, liveProvider: provider)
    weak var weakSession = session
    _ = try await session?.beginTwoFinger(first: CGPoint(x: 10, y: 20), second: CGPoint(x: 30, y: 20))
    session = nil
    try await waitUntil { weakSession == nil }
    let checks = provider.localChecks
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(provider.localChecks == checks)
    _ = try await fixture.session.close()
  }

  @Test(arguments: [false, true])
  func uncertainIdleReleaseStaysUncertainAfterClose(failRelease: Bool) async throws {
    let fixture = try IdleFixture(failRelease: failRelease, matchIdentity: false)
    _ = try await fixture.begin(pair: true)
    fixture.provider.invalidate()
    try await waitUntil { await fixture.session.status().state == .invalidated }
    let evidence = try #require(await fixture.session.cleanupEvidence())
    #expect(await fixture.session.status().lastCleanup == .uncertain)
    #expect(!evidence.timedOut && evidence.releases.count == 1)
    #expect(evidence.releases[0].returnedSuccessfully == !failRelease)
    let closed = try await fixture.session.close()
    #expect(closed.cleanup == .uncertain && closed.token == nil)
    #expect(await fixture.session.cleanupEvidence() == evidence)
    #expect(fixture.transport.events == ["pair:down", "pair:up"])
  }

  @Test func nonLiveRetainedInputKeepsExplicitActionContract() async throws {
    let fixture = try IdleFixture(live: false)
    _ = try await fixture.begin(pair: true)
    fixture.provider.invalidate()
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(await fixture.session.status().hasRetainedContact)
    #expect(fixture.provider.localChecks == 0)
    _ = try await fixture.session.close()
    #expect(fixture.transport.events == ["pair:down", "pair:up"])
  }
}

private func waitUntil(_ predicate: () async -> Bool) async throws {
  let deadline = ProcessInfo.processInfo.systemUptime + 1.5
  while !(await predicate()) {
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      throw FBSimulatorHIDSessionError.invalidEvent("Bounded idle verification timed out")
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
}

private struct IdleFixture {
  let provider: IdleProvider
  let transport: IdleTransport
  let session: FBSimulatorHIDSession

  init(releaseGate: IdleGate? = nil, downGate: IdleGate? = nil,
       failRelease: Bool = false, matchIdentity: Bool = true, live: Bool = true) throws {
    let context = try FBSimulatorHIDDisplayContext(hidTarget: 3,
      nativePixelSize: CGSize(width: 600, height: 900), scale: 3, rotation: .rot0)
    let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "retained-idle-check",
      bootIdentity: "boot", screenID: 3, screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58",
      axDisplayID: 3, displayContext: context, poseRevision: "open")
    provider = IdleProvider(value: observation, matchIdentity: matchIdentity)
    transport = IdleTransport(releaseGate: releaseGate, downGate: downGate, failRelease: failRelease)
    session = FBSimulatorHIDSession(transport: transport, observation: observation,
      freshnessProvider: provider, liveProvider: live ? provider : nil)
  }

  func begin(pair: Bool) async throws -> FBSimulatorHIDSessionReceipt {
    if pair { return try await session.beginTwoFinger(first: CGPoint(x: 10, y: 20), second: CGPoint(x: 30, y: 20)) }
    return try await session.begin(at: CGPoint(x: 10, y: 20))
  }

  func move(_ token: FBSimulatorHIDContactToken, pair: Bool) async throws -> FBSimulatorHIDSessionReceipt {
    if pair { return try await session.moveTwoFinger(token, first: CGPoint(x: 15, y: 20), second: CGPoint(x: 35, y: 20)) }
    return try await session.move(token, to: CGPoint(x: 15, y: 20))
  }
}

private final class IdleProvider: FBSimulatorHIDLiveFreshnessProvider, FBSimulatorHIDCleanupIdentityProvider, @unchecked Sendable {
  let value: FBSimulatorHIDSessionObservation
  private let matchIdentity: Bool
  private let lock = NSLock()
  private var invalid = false
  private var reads = 0
  private var checks = 0
  var observationReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
  var localChecks: Int { lock.lock(); defer { lock.unlock() }; return checks }

  init(value: FBSimulatorHIDSessionObservation, matchIdentity: Bool) {
    self.value = value; self.matchIdentity = matchIdentity
  }
  func invalidate() { lock.lock(); defer { lock.unlock() }; invalid = true }
  private func read() -> FBSimulatorHIDSessionObservation {
    lock.lock(); defer { lock.unlock() }; reads += 1; return value
  }
  func observation() async throws -> FBSimulatorHIDSessionObservation { read() }
  func validateCurrentRevision(expected: FBSimulatorHIDSessionObservation) throws {
    lock.lock(); defer { lock.unlock() }; checks += 1
    if invalid || expected != value {
      throw FBSimulatorHIDSessionError.interrupted(reason: .staleContext, cleanup: .notNeeded)
    }
  }
  func cleanupIdentity() async throws -> FBSimulatorHIDCleanupIdentity {
    let now = ProcessInfo.processInfo.systemUptime
    return FBSimulatorHIDCleanupIdentity(simulatorUDID: value.simulatorUDID,
      bootIdentity: matchIdentity ? value.bootIdentity : "different-boot", screenID: value.screenID,
      screenUUID: value.screenUniqueID, nativePixelWidth: value.displayContext.nativePixelSize.width,
      nativePixelHeight: value.displayContext.nativePixelSize.height, scale: value.displayContext.scale,
      startedUptime: now, finishedUptime: now)
  }
  func close() {}
}

private actor IdleGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    let pending = waiters; waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private actor IdleCompletions {
  private(set) var count = 0
  func add() { count += 1 }
}

private final class IdleTransport: FBSimulatorHIDTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private let releaseGate: IdleGate?
  private let downGate: IdleGate?
  private let failRelease: Bool
  var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
  init(releaseGate: IdleGate? = nil, downGate: IdleGate? = nil, failRelease: Bool = false) {
    self.releaseGate = releaseGate; self.downGate = downGate; self.failRelease = failRelease
  }
  private func append(_ event: String) { lock.lock(); defer { lock.unlock() }; recorded.append(event) }
  private func send(_ kind: String, _ direction: FBSimulatorHIDDirection) async throws {
    append(kind + ":" + direction.name)
    if direction == .up {
      await releaseGate?.wait()
      if failRelease { throw FBSimulatorHIDSessionError.invalidEvent("Controlled release failure") }
    } else { await downGate?.wait() }
  }
  func disconnect() {}
  func sendTouch(direction: FBSimulatorHIDDirection, x: Double, y: Double) async throws { try await send("touch", direction) }
  func sendTwoFingerTouch(direction: FBSimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint) async throws { try await send("pair", direction) }
  func sendButton(direction: FBSimulatorHIDDirection, button: FBSimulatorHIDButton) async throws { try await send("button", direction) }
  func sendKeyboard(direction: FBSimulatorHIDDirection, keyCode: UInt32) async throws { try await send("key", direction) }
  func flush() async throws {}
}
