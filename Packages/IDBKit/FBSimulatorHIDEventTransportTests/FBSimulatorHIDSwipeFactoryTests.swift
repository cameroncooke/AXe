import CoreGraphics
import Testing
import FBSimulatorControl

struct FBSimulatorHIDSwipeFactoryTests {
  @Test func onePointPathHasFiniteBalancedEndpoints() throws {
    let event = FBSimulatorHIDEvent.swipe(80, yStart: 50, xEnd: 81, yEnd: 50,
      delta: 50, duration: 0.3)
    let events = try #require(event.subEvents)
    #expect(events.count == 7)
    #expect(touches(events) == [
      .touch(direction: .down, x: 80, y: 50),
      .touch(direction: .down, x: 81, y: 50),
      .touch(direction: .down, x: 81, y: 50),
      .touch(direction: .up, x: 81, y: 50)
    ])
    try assertPreflight(event, primitives: 4, duration: 0.3)
  }

  @Test(arguments: [CGPoint(x: 49, y: 50), CGPoint(x: 50, y: 51), CGPoint(x: 51, y: 51)])
  func shortPathsPreserveDirectionAndEndpoints(end: CGPoint) throws {
    let event = FBSimulatorHIDEvent.swipe(50, yStart: 50, xEnd: end.x, yEnd: end.y,
      delta: 50, duration: 0.3)
    let contactEvents = touches(try #require(event.subEvents))
    #expect(contactEvents == [
      .touch(direction: .down, x: 50, y: 50),
      .touch(direction: .down, x: end.x, y: end.y),
      .touch(direction: .down, x: end.x, y: end.y),
      .touch(direction: .up, x: end.x, y: end.y)
    ])
    try assertPreflight(event, primitives: 4, duration: 0.3)
  }

  @Test(arguments: [100.0, 125.0])
  func normalPathsKeepFloorSamplingAndTotalDelay(endX: Double) throws {
    let event = FBSimulatorHIDEvent.swipe(0, yStart: 50, xEnd: endX, yEnd: 50,
      delta: 50, duration: 0.4)
    let events = try #require(event.subEvents)
    // Both historical paths use two steps, including the non-integral 125 / 50 case.
    let midpoint = endX == 100 ? 50.0 : 62.5
    #expect(events == [
      .touch(direction: .down, x: 0, y: 50), .delay(0.1),
      .touch(direction: .down, x: midpoint, y: 50), .delay(0.1),
      .touch(direction: .down, x: endX, y: 50), .delay(0.1),
      .touch(direction: .down, x: endX, y: 50), .delay(0.1),
      .touch(direction: .up, x: endX, y: 50)
    ])
    try assertPreflight(event, primitives: 5, duration: 0.4)
  }

  @Test func exactDeltaKeepsOneStepAndDuplicateFinalDown() throws {
    let event = FBSimulatorHIDEvent.swipe(50, yStart: 50, xEnd: 100, yEnd: 50,
      delta: 50, duration: 0.3)
    #expect(touches(try #require(event.subEvents)) == [
      .touch(direction: .down, x: 50, y: 50),
      .touch(direction: .down, x: 100, y: 50),
      .touch(direction: .down, x: 100, y: 50),
      .touch(direction: .up, x: 100, y: 50)
    ])
    try assertPreflight(event, primitives: 4, duration: 0.3)
  }

  @Test(arguments: [0.0, -1.0])
  func existingNonpositiveDeltaFallbackIsPreserved(delta: Double) throws {
    let normal = FBSimulatorHIDEvent.swipe(20, yStart: 50, xEnd: 40, yEnd: 50,
      delta: delta, duration: 0.4)
    #expect(normal == .swipe(20, yStart: 50, xEnd: 40, yEnd: 50,
      delta: 10, duration: 0.4))
    try assertPreflight(normal, primitives: 5, duration: 0.4)
    let short = FBSimulatorHIDEvent.swipe(20, yStart: 50, xEnd: 21, yEnd: 50,
      delta: delta, duration: 0.3)
    try assertPreflight(short, primitives: 4, duration: 0.3)
  }

  @Test func zeroLengthRemainsRejectedByPublicPreflight() throws {
    let event = FBSimulatorHIDEvent.swipe(50, yStart: 50, xEnd: 50, yEnd: 50,
      delta: 50, duration: 0.3)
    let observation = try observation()
    #expect(throws: FBSimulatorHIDSessionError.self) {
      try FBSimulatorHIDSession.preflight(event, observation: observation)
    }
  }

  @Test(arguments: [-0.1, Double.infinity])
  func invalidDurationRemainsRejectedByPublicPreflight(duration: Double) throws {
    let event = FBSimulatorHIDEvent.swipe(50, yStart: 50, xEnd: 51, yEnd: 50,
      delta: 50, duration: duration)
    let observation = try observation()
    #expect(throws: FBSimulatorHIDSessionError.self) {
      try FBSimulatorHIDSession.preflight(event, observation: observation)
    }
  }

  private func touches(_ events: [FBSimulatorHIDEvent]) -> [FBSimulatorHIDEvent] {
    events.filter { if case .touch = $0 { return true }; return false }
  }

  private func assertPreflight(_ event: FBSimulatorHIDEvent, primitives: Int,
                               duration: Double) throws {
    let events = try #require(event.subEvents)
    for item in events {
      switch item {
      case let .touch(_, x, y):
        #expect(x.isFinite && y.isFinite)
      case let .delay(seconds):
        #expect(seconds.isFinite && seconds >= 0)
      default:
        Issue.record("Swipe factory produced an unexpected event")
      }
    }
    let result = try FBSimulatorHIDSession.preflight(event, observation: observation())
    #expect(result.primitiveCount == primitives)
    #expect(abs(result.requestedDelaySeconds - duration) < 1e-12)
  }

  private func observation() throws -> FBSimulatorHIDSessionObservation {
    let context = try FBSimulatorHIDDisplayContext(hidTarget: 3,
      nativePixelSize: CGSize(width: 600, height: 900), scale: 3, rotation: .rot0)
    return try FBSimulatorHIDSessionObservation(simulatorUDID: "local-swipe-check",
      bootIdentity: "boot", screenID: 3,
      screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58", axDisplayID: 3,
      displayContext: context, poseRevision: "open")
  }
}
