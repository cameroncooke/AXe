import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

/// Pins the events and limits of the ordinary broker route's swipe, drag and draw, and keeps them
/// distinct from the selected route's paths.
@Suite("Ordinary broker path events")
@MainActor
struct OrdinaryPathEventTests {
    private let size = CGSize(width: 400, height: 800)

    @Test func swipeIsOneNativeSwipeEvent() throws {
        let path = SelectedHIDPath(kind: .swipe, startX: 10, startY: 20, endX: 200, endY: 400, duration: 1, delta: 50, generator: .ordinary)
        #expect(try path.event(logicalSize: size) == .swipe(10, yStart: 20, xEnd: 200, yEnd: 400, delta: 50, duration: 1))
        #expect(path.responseTimeoutMilliseconds == 121_000)
        #expect(SelectedHIDPath(kind: .swipe, startX: 10, startY: 20, endX: 200, endY: 400, duration: 1, delta: 50)
            .responseTimeoutMilliseconds == nil)
        // The owner sends the request's complete event, which is the same single swipe.
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: UUID(), operation: .complete, token: nil, primitives: [], path: path)
        #expect(try request.completeEvent(logicalSize: size) == .swipe(10, yStart: 20, xEnd: 200, yEnd: 400,
            delta: 50, duration: 1))
    }

    @Test func dragHoldsMovesEvenlyAndReleases() throws {
        let path = SelectedHIDPath(kind: .drag, startX: 100, startY: 200, endX: 300, endY: 600, duration: 0.4, steps: 4, generator: .ordinary)
        let expected: [FBSimulatorHIDEvent] = [
            .touch(direction: .down, x: 100, y: 200), .delay(0.05),
            .delay(0.1), .touch(direction: .down, x: 150, y: 300),
            .delay(0.1), .touch(direction: .down, x: 200, y: 400),
            .delay(0.1), .touch(direction: .down, x: 250, y: 500),
            .delay(0.1), .touch(direction: .down, x: 300, y: 600),
            .delay(0.05), .touch(direction: .up, x: 300, y: 600),
        ]
        #expect(try path.event(logicalSize: size).subEvents == expected)
        #expect(path.responseTimeoutMilliseconds == 120_500)
    }

    @Test func drawFollowsItsPointsWithDrawTiming() throws {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 30, y: 40)]
        let path = SelectedHIDPath(kind: .draw, duration: 1, points: points.map { .init(x: $0.x, y: $0.y) }, generator: .ordinary)
        let events = try #require(try path.event(logicalSize: size).subEvents)
        let expected = TouchStroke.primitives(through: points, duration: 1, moves: 50,
            initialHold: 0.05, finalHold: 0.05).map(\.event)
        #expect(events == expected)
        #expect(events.first == .touch(direction: .down, x: 10, y: 10))
        #expect(events.last == .touch(direction: .up, x: 30, y: 40))
    }

    /// The ordinary route keeps its own limits: a long drag or swipe that the selected route refuses.
    @Test func ordinaryLimitsDifferFromSelectedOnes() throws {
        let longDrag = SelectedHIDPath(kind: .drag, startX: 1, startY: 1, endX: 9, endY: 9, duration: 15, steps: 10, generator: .ordinary)
        try longDrag.validate()
        #expect(throws: (any Error).self) {
            try SelectedHIDPath(kind: .drag, startX: 1, startY: 1, endX: 9, endY: 9, duration: 15, steps: 10).validate()
        }
        let fineSwipe = SelectedHIDPath(kind: .swipe, startX: 0, startY: 0, endX: 300, endY: 0, duration: 1, delta: 0.01, generator: .ordinary)
        try fineSwipe.validate()
        #expect(throws: (any Error).self) {
            try SelectedHIDPath(kind: .swipe, startX: 0, startY: 0, endX: 2000, endY: 0, duration: 1, delta: 0.01, generator: .ordinary).validate()
        }
        #expect(throws: (any Error).self) {
            try SelectedHIDPath(kind: .drag, startX: 1, startY: 1, endX: 9, endY: 9, duration: 1, steps: 1001, generator: .ordinary).validate()
        }
        #expect(throws: (any Error).self) {
            _ = try SelectedHIDPath(kind: .swipe, startX: 10, startY: 10, endX: 401, endY: 10, duration: 1, delta: 5, generator: .ordinary)
                .event(logicalSize: size)
        }
    }
}
