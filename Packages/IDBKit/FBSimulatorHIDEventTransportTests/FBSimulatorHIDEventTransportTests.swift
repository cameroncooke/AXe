/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import XCTest
import Foundation
import Testing

final class FBSimulatorHIDEventTransportTests: XCTestCase {

  func testApplePayBecomesTwoSideButtonPressesOnDTUHID() {
    XCTAssertEqual(
      FBSimulatorHIDEvent.shortButtonPress(.applePay).event(for: .dtuhid),
      .composite([
        .button(direction: .down, button: .sideButton),
        .button(direction: .up, button: .sideButton),
        .delay(0.15),
        .button(direction: .down, button: .sideButton),
        .button(direction: .up, button: .sideButton),
      ]))
  }

  func testApplePaySplitsCommandDurationAcrossSideButtonPresses() {
    let event = FBSimulatorHIDEvent.composite([
      .button(direction: .down, button: .applePay),
      .delay(2),
      .button(direction: .up, button: .applePay),
    ])

    let transportEvent = event.event(for: .dtuhid)
    XCTAssertEqual(
      transportEvent,
      .composite([
        .button(direction: .down, button: .sideButton),
        .delay(1),
        .button(direction: .up, button: .sideButton),
        .delay(0.15),
        .button(direction: .down, button: .sideButton),
        .delay(1),
        .button(direction: .up, button: .sideButton),
      ]))
    XCTAssertEqual(totalDelay(in: transportEvent), 2.15, accuracy: 1e-9)
  }

  func testIndigoPreservesApplePayEvent() {
    let event = FBSimulatorHIDEvent.shortButtonPress(.applePay)
    XCTAssertEqual(event.event(for: .indigo), event)
  }

  func testUnmatchedApplePayPrimitiveRemainsUnsupported() {
    let event = FBSimulatorHIDEvent.button(direction: .down, button: .applePay)
    XCTAssertEqual(event.event(for: .dtuhid), event)
  }

  func testApplePayRewritePreservesNestedDurationBudget() {
    let event = FBSimulatorHIDEvent.composite([
      .button(direction: .down, button: .applePay),
      .composite([.delay(1), .delay(1)]),
      .button(direction: .up, button: .applePay),
    ])

    let transportEvent = event.event(for: .dtuhid)
    XCTAssertEqual(totalDelay(in: transportEvent), 2.15, accuracy: 1e-9)
  }

  func testApplePayRewriteDoesNotDuplicateMixedEvents() {
    let event = FBSimulatorHIDEvent.composite([
      .button(direction: .down, button: .applePay),
      .touch(direction: .down, x: 10, y: 20),
      .button(direction: .up, button: .applePay),
    ])

    XCTAssertEqual(event.event(for: .dtuhid), event)
  }

  func testDTUHIDPacesKeyboardCompositeBeforeFlush() {
    XCTAssertEqual(
      FBSimulatorHIDEvent.shortKeyPress(4).event(for: .dtuhid),
      .composite([
        .composite([
          .keyboard(direction: .down, keyCode: 4),
          .delay(0.01),
          .keyboard(direction: .up, keyCode: 4),
          .delay(0.01),
        ]),
        .delay(0.05),
      ]))
  }

  func testDTUHIDPacesDirectKeyboardEventBeforeFlush() {
    XCTAssertEqual(
      FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: 4).event(for: .dtuhid),
      .composite([
        .composite([
          .keyboard(direction: .down, keyCode: 4),
          .delay(0.01),
        ]),
        .delay(0.05),
      ]))
  }

  func testDTUHIDPreservesNonKeyboardEvent() {
    let event = FBSimulatorHIDEvent.tapAt(x: 10, y: 20)
    XCTAssertEqual(event.event(for: .dtuhid), event)
  }

  private func totalDelay(in event: FBSimulatorHIDEvent) -> TimeInterval {
    switch event {
    case let .delay(duration):
      return duration
    case let .composite(events):
      return events.reduce(0) { $0 + totalDelay(in: $1) }
    default:
      return 0
    }
  }
}

@Suite("Native live feed renewal")
struct FBSimulatorHIDFeedRenewalTests {
  private func sample(_ timestamp: TimeInterval, degrees: Double = 180) -> FBSimulatorHingeObservation {
    FBSimulatorHingeObservation(channelID: "test-channel", timestampUptime: timestamp,
      receivedUptime: timestamp, mechanicalDegrees: degrees, sensedDegrees: degrees,
      velocityDegreesPerSecond: 0, minimumDegrees: 0, maximumDegrees: 180)
  }

  private func state(_ clock: FeedTestClock, motion: Bool = true) -> FBSimulatorHIDFeedState {
    FBSimulatorHIDFeedState(maximumAge: 0.5, requiresMotion: motion, clock: { clock.read() })
  }

  private func failure(_ state: FBSimulatorHIDFeedState, generation: UInt64) -> String {
    do { try state.validate(generation: generation); return "" }
    catch { return String(describing: error) }
  }

  @Test func identicalFreshAnglesRefreshTimeWithoutChangingRevision() throws {
    let clock = FeedTestClock(100)
    let feed = state(clock)
    feed.observeMotion(sample(100)); feed.observeDisplays([])
    let revision = try feed.checkpoint()
    clock.set(100.4); feed.observeMotion(sample(100.4)); feed.observeDisplays([])
    clock.set(100.8); feed.observeDisplays([])
    try feed.validate(generation: revision)
    #expect(feed.status().generation == revision)
    #expect(feed.status().motionSampleCount == 2)
    #expect((feed.status().motionAgeSeconds ?? 1) < 0.5)
  }

  @Test func listenerChangeAndReversionStillInvalidateTheOriginalRevision() throws {
    let clock = FeedTestClock(100)
    let feed = state(clock)
    feed.observeMotion(sample(100)); feed.observeDisplays([])
    let revision = try feed.checkpoint()
    clock.set(100.2)
    feed.observeMotion(sample(100.1, degrees: 90)); feed.observeMotion(sample(100.2))
    #expect(feed.status().generation == revision + 2)
    #expect(throws: FBSimulatorHIDSessionError.self) { try feed.validate(generation: revision) }
  }

  @Test func anOlderCallbackCannotRefreshTheMotionClock() throws {
    let clock = FeedTestClock(100)
    let feed = state(clock)
    feed.observeMotion(sample(100)); feed.observeDisplays([])
    let revision = try feed.checkpoint()
    clock.set(100.6); feed.observeDisplays([]); feed.observeMotion(sample(99.9))
    let error = failure(feed, generation: revision)
    #expect(error.contains("staleSources=motion;"))
    #expect(error.contains("motionTimestampUptime=100.0"))
    #expect(error.contains("displayAgeSeconds=0.0"))
    #expect(error.contains("motionSampleCount=2"))
  }

  @Test func staleDisplayIsReportedSeparatelyFromFreshMotion() throws {
    let clock = FeedTestClock(100)
    let feed = state(clock)
    feed.observeMotion(sample(100)); feed.observeDisplays([])
    let revision = try feed.checkpoint()
    clock.set(100.6); feed.observeMotion(sample(100.6))
    let error = failure(feed, generation: revision)
    #expect(error.contains("staleSources=display;"))
    #expect(error.contains("motionAgeSeconds=0.0"))
    #expect(error.contains("displayRefreshCount=1"))
  }

  @Test func aDisplayOnlyProfileStillRequiresFreshDisplays() throws {
    let clock = FeedTestClock(100)
    let feed = state(clock, motion: false)
    feed.observeDisplays([])
    let revision = try feed.checkpoint()
    clock.set(100.4); try feed.validate(generation: revision)
    clock.set(100.6)
    let error = failure(feed, generation: revision)
    #expect(error.contains("staleSources=display;"))
    #expect(error.contains("motionAgeSeconds=missing"))
  }

  @Test func aCompletedChangeStreamCannotBeRestoredByFreshSamples() throws {
    let clock = FeedTestClock(100)
    let feed = state(clock)
    feed.observeMotion(sample(100)); feed.observeDisplays([])
    let revision = try feed.checkpoint()
    feed.motionSubscriptionCompleted()
    clock.set(100.1); feed.observeMotion(sample(100.1)); feed.observeDisplays([])
    #expect(failure(feed, generation: revision).contains("Motion subscription completed before close"))
    #expect(feed.status().motionSampleCount == 1)
    #expect(feed.status().displayRefreshCount == 1)
  }

  @Test func displayRefreshContinuesWhileTheMotionReadWaits() async throws {
    let clock = FeedTestClock(100)
    let feed = state(clock)
    feed.observeMotion(sample(100)); feed.observeDisplays([])
    let blockedMotion = FBSimulatorBoundedResult<FBSimulatorHingeObservation>()
    let displays = FeedTestDisplayReads()
    let task = Task {
      await FBSimulatorHIDFeedRenewal.run(state: feed, interval: 0.001,
        motionRead: {
          try await blockedMotion.value(timeout: 3, operation: "Blocked test motion") { _ in }
        }, displayRead: { displays.record(); return [] })
    }
    // The third call proves the first two completed independently of the blocked motion read.
    let refreshed = try? await displays.three.value(timeout: 1, operation: "Independent display refresh") { _ in }
    task.cancel(); await task.value
    try #require(refreshed == true)
    #expect(feed.status().displayRefreshCount >= 3)
    #expect(feed.status().motionSampleCount == 1)
    #expect(feed.status().failure == "Feed closed")
  }

  @Test func motionFailureCancelsAndJoinsTheDisplayRead() async throws {
    let clock = FeedTestClock(100)
    let feed = state(clock)
    let displayStarted = FBSimulatorBoundedResult<Bool>()
    let blockedDisplay = FBSimulatorBoundedResult<Bool>()
    let displayFinished = FBSimulatorBoundedResult<Bool>()
    let completed = FBSimulatorBoundedResult<Bool>()
    let task = Task {
      await FBSimulatorHIDFeedRenewal.run(state: feed, interval: 0.001,
        motionRead: {
          _ = try await displayStarted.value(timeout: 1, operation: "Display test start") { _ in }
          throw FeedTestFailure.motion
        }, displayRead: {
          defer { displayFinished.finish(.success(true)) }
          _ = try await blockedDisplay.value(timeout: 3, operation: "Blocked test display") { _ in
            displayStarted.finish(.success(true))
          }
          return []
        })
      completed.finish(.success(true))
    }
    let joined = try? await completed.value(timeout: 1, operation: "Joined failed feed") { _ in }
    task.cancel(); await task.value
    let displayDidFinish = try? await displayFinished.value(timeout: 1, operation: "Display test finish") { _ in }
    try #require(joined == true && displayDidFinish == true)
    #expect(feed.status().failure?.hasPrefix("Motion refresh:") == true)
  }

  @Test func displayOnlyRenewalDoesNotRequireAMotionRead() async throws {
    let clock = FeedTestClock(100)
    let feed = state(clock, motion: false)
    let displays = FeedTestDisplayReads()
    let task = Task {
      await FBSimulatorHIDFeedRenewal.run(state: feed, interval: 0.001,
        motionRead: nil, displayRead: { displays.record(); return [] })
    }
    let refreshed = try? await displays.three.value(timeout: 1, operation: "Display-only refresh") { _ in }
    task.cancel(); await task.value
    try #require(refreshed == true)
    #expect(feed.status().displayRefreshCount >= 2)
    #expect(feed.status().motionSampleCount == 0)
  }
}

private enum FeedTestFailure: Error { case motion }

private final class FeedTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TimeInterval
  init(_ value: TimeInterval) { self.value = value }
  func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
  func set(_ value: TimeInterval) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private final class FeedTestDisplayReads: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let three = FBSimulatorBoundedResult<Bool>()
  func record() {
    lock.lock(); count += 1; let ready = count >= 3; lock.unlock()
    if ready { three.finish(.success(true)) }
  }
}
