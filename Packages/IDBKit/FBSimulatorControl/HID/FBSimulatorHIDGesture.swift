import CoreGraphics
import Foundation

/// Validated gesture construction in the selected display's upright point space.
/// No transport is opened until the complete event has passed preflight.
public struct FBSimulatorHIDGesture {
    public enum ConstructionError: Error, Equatable {
        case invalidDuration
        case invalidSpacing
        case invalidGeometry
        case excessiveSegments
        case coincidentContacts
    }

    public static let maximumSegments = 4096
    public let observation: FBSimulatorHIDSessionObservation

    public init(observation: FBSimulatorHIDSessionObservation) {
        self.observation = observation
    }

    public func tap(at point: CGPoint, hold: TimeInterval = 0.1) throws -> FBSimulatorHIDEvent {
        try duration(hold)
        return try checked(.tapAt(x: point.x, y: point.y, duration: hold))
    }

    public func doubleTap(at point: CGPoint, hold: TimeInterval = 0.06,
                          interval: TimeInterval = 0.1) throws -> FBSimulatorHIDEvent {
        try duration(interval)
        let single = try tap(at: point, hold: hold)
        return try checked(.composite([single, .delay(interval), single]))
    }

    public func twoFingerTap(first: CGPoint, second: CGPoint,
                             hold: TimeInterval = 0.1) throws -> FBSimulatorHIDEvent {
        try duration(hold)
        return try checked(.composite([
            .twoFingerTouch(direction: .down, finger1: first, finger2: second),
            .delay(hold),
            .twoFingerTouch(direction: .up, finger1: first, finger2: second),
        ]))
    }

    /// Includes exact start and end points. Short and zero-distance paths are valid.
    /// The final stationary sample retains the existing arm-simulator scroll policy.
    public func swipe(from start: CGPoint, to end: CGPoint, duration seconds: TimeInterval = 0.5,
                      spacing: Double = 10) throws -> FBSimulatorHIDEvent {
        try duration(seconds)
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else {
            throw ConstructionError.invalidGeometry
        }
        let count = try segments(distance: hypot(end.x - start.x, end.y - start.y), spacing: spacing)
        let points = (0...count).map { index in
            let fraction = Double(index) / Double(count)
            return CGPoint(x: start.x + (end.x - start.x) * fraction,
                           y: start.y + (end.y - start.y) * fraction)
        }
        let delay = seconds / Double(points.count + 1)
        var events: [FBSimulatorHIDEvent] = []
        for point in points {
            events.append(.touch(direction: .down, x: point.x, y: point.y))
            events.append(.delay(delay))
        }
        events.append(.touch(direction: .down, x: end.x, y: end.y))
        events.append(.delay(delay))
        events.append(.touch(direction: .up, x: end.x, y: end.y))
        return try checked(.composite(events))
    }

    public func drag(from start: CGPoint, to end: CGPoint, hold: TimeInterval = 0.5,
                     duration seconds: TimeInterval = 0.5, spacing: Double = 10) throws -> FBSimulatorHIDEvent {
        try duration(hold)
        let motion = try swipe(from: start, to: end, duration: seconds, spacing: spacing)
        return try checked(.composite([
            .touch(direction: .down, x: start.x, y: start.y), .delay(hold), motion,
        ]))
    }

    /// Two independent straight paths with one shared clock and stable finger order.
    /// Either path may be stationary. Coordinates stay in the selected logical space.
    public func twoFingerSwipe(firstStart: CGPoint, firstEnd: CGPoint,
                               secondStart: CGPoint, secondEnd: CGPoint,
                               duration seconds: TimeInterval = 0.6, spacing: Double = 5) throws -> FBSimulatorHIDEvent {
        let points = [firstStart, firstEnd, secondStart, secondEnd]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ConstructionError.invalidGeometry
        }
        // The relative segment reaches the origin only when both contacts share a point at the same time.
        let startDX = firstStart.x - secondStart.x
        let startDY = firstStart.y - secondStart.y
        let endDX = firstEnd.x - secondEnd.x
        let endDY = firstEnd.y - secondEnd.y
        let firstProduct = startDX * endDY
        let secondProduct = startDY * endDX
        let determinant = firstProduct - secondProduct
        guard [startDX, startDY, endDX, endDY, firstProduct, secondProduct, determinant].allSatisfy(\.isFinite) else {
            throw ConstructionError.invalidGeometry
        }
        let spansOriginX = min(startDX, endDX) <= 0 && max(startDX, endDX) >= 0
        let spansOriginY = min(startDY, endDY) <= 0 && max(startDY, endDY) >= 0
        guard determinant != 0 || !spansOriginX || !spansOriginY else {
            throw ConstructionError.coincidentContacts
        }
        let distance = max(hypot(firstEnd.x - firstStart.x, firstEnd.y - firstStart.y),
                           hypot(secondEnd.x - secondStart.x, secondEnd.y - secondStart.y))
        let count = try segments(distance: distance, spacing: spacing)
        func interpolate(_ start: CGPoint, _ end: CGPoint, _ fraction: Double) -> CGPoint {
            if fraction == 0 { return start }
            if fraction == 1 { return end }
            return CGPoint(x: start.x + (end.x - start.x) * fraction,
                           y: start.y + (end.y - start.y) * fraction)
        }
        return try pairMotion(duration: seconds, segments: count) { fraction in
            (interpolate(firstStart, firstEnd, fraction), interpolate(secondStart, secondEnd, fraction))
        }
    }

    public func pinch(at center: CGPoint, scale: Double, radius: Double = 30,
                      duration seconds: TimeInterval = 0.6, spacing: Double = 5) throws -> FBSimulatorHIDEvent {
        guard scale.isFinite, scale > 0, radius.isFinite, radius > 0,
              (radius * scale).isFinite else { throw ConstructionError.invalidGeometry }
        let endRadius = radius * scale
        let count = try segments(distance: abs(endRadius - radius), spacing: spacing)
        return try pairMotion(center: center, duration: seconds, segments: count) { fraction in
            (radius + (endRadius - radius) * fraction, 0)
        }
    }

    /// Positive angles rotate clockwise in UIKit's top-left-origin coordinate space.
    public func rotate(at center: CGPoint, degrees: Double, radius: Double = 30,
                       duration seconds: TimeInterval = 0.6, spacing: Double = 5) throws -> FBSimulatorHIDEvent {
        guard degrees.isFinite, radius.isFinite, radius > 0 else { throw ConstructionError.invalidGeometry }
        let radians = degrees * .pi / 180
        let count = try segments(distance: abs(radians) * radius, spacing: spacing)
        return try pairMotion(center: center, duration: seconds, segments: count) { fraction in
            (radius, radians * fraction)
        }
    }

    private func pairMotion(center: CGPoint, duration seconds: TimeInterval, segments count: Int,
                            geometry: (Double) -> (radius: Double, angle: Double)) throws -> FBSimulatorHIDEvent {
        try duration(seconds)
        guard center.x.isFinite, center.y.isFinite else { throw ConstructionError.invalidGeometry }
        return try pairMotion(duration: seconds, segments: count) { fraction in
            let position = geometry(fraction)
            let dx = position.radius * cos(position.angle)
            let dy = position.radius * sin(position.angle)
            return (CGPoint(x: center.x - dx, y: center.y - dy),
                    CGPoint(x: center.x + dx, y: center.y + dy))
        }
    }

    private func pairMotion(duration seconds: TimeInterval, segments count: Int,
                            geometry: (Double) -> (first: CGPoint, second: CGPoint)) throws -> FBSimulatorHIDEvent {
        try duration(seconds)
        let delay = seconds / Double(count + 2)
        var events: [FBSimulatorHIDEvent] = []
        var finalFirst = CGPoint.zero
        var finalSecond = CGPoint.zero
        for index in 0...count {
            let position = geometry(Double(index) / Double(count))
            finalFirst = position.first
            finalSecond = position.second
            events.append(.twoFingerTouch(direction: .down, finger1: finalFirst, finger2: finalSecond))
            events.append(.delay(delay))
        }
        events.append(.twoFingerTouch(direction: .down, finger1: finalFirst, finger2: finalSecond))
        events.append(.delay(delay))
        events.append(.twoFingerTouch(direction: .up, finger1: finalFirst, finger2: finalSecond))
        return try checked(.composite(events))
    }

    private func segments(distance: Double, spacing: Double) throws -> Int {
        guard spacing.isFinite, spacing > 0 else { throw ConstructionError.invalidSpacing }
        guard distance.isFinite, distance >= 0 else { throw ConstructionError.invalidGeometry }
        let count = ceil(distance / spacing)
        guard count.isFinite, count <= Double(Self.maximumSegments) else { throw ConstructionError.excessiveSegments }
        return max(1, Int(count))
    }

    private func duration(_ seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds >= 0,
              seconds < Double(UInt64.max) / 1_000_000_000 else { throw ConstructionError.invalidDuration }
    }

    private func checked(_ event: FBSimulatorHIDEvent) throws -> FBSimulatorHIDEvent {
        _ = try FBSimulatorHIDSession.preflight(event, observation: observation)
        return event
    }
}
