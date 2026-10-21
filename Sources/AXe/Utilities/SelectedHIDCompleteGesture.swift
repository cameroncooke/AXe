import Foundation
import FBSimulatorControl

/// One complete gesture. Associated payloads prevent mixed gesture geometry.
enum SelectedHIDCompleteGesture: Codable, Sendable {
    case doubleTap(DoubleTap)
    case rotate(Rotation)
    case twoFingerTap(PairContact)
    case twoFingerHold(PairContact)

    static let maximumSegments = 500
    static let maximumEventCount = 1024

    struct Point: Codable, Sendable {
        let x: Double
        let y: Double
        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
        func validate() throws {
            guard x.isFinite, y.isFinite, x >= 0, y >= 0 else {
                throw SelectedHIDFailure.invalid("Gesture points must be finite and non-negative")
            }
        }
    }

    struct Timing: Codable, Sendable {
        var preDelay: Double = 0
        var postDelay: Double = 0
        func validate(activeDuration: Double) throws {
            guard preDelay.isFinite, postDelay.isFinite,
                  (0...10).contains(preDelay), (0...10).contains(postDelay),
                  activeDuration.isFinite, activeDuration + preDelay + postDelay <= 20 else {
                throw SelectedHIDFailure.invalid("Gesture delays must be in 0...10 seconds and total delay at most 20 seconds")
            }
        }
    }

    struct DoubleTap: Codable, Sendable {
        let point: Point
        var hold: Double = 0.06
        var interval: Double = 0.1
        var timing = Timing()
    }

    struct Rotation: Codable, Sendable {
        let center: Point
        let radius: Double
        let degrees: Double
        var duration: Double = 0.6
        var spacing: Double = 5
        var timing = Timing()
    }

    struct PairContact: Codable, Sendable {
        let first: Point
        let second: Point
        let hold: Double
        var timing = Timing()
    }

    func validate() throws {
        switch self {
        case .doubleTap(let value):
            try value.point.validate()
            try Self.duration(value.hold)
            try Self.duration(value.interval)
            try value.timing.validate(activeDuration: value.hold * 2 + value.interval)
        case .rotate(let value):
            try value.center.validate()
            try Self.duration(value.duration)
            guard value.radius.isFinite, value.radius > 0, value.degrees.isFinite,
                  value.degrees != 0, abs(value.degrees) <= 360,
                  value.spacing.isFinite, value.spacing > 0, value.spacing <= 200 else {
                throw SelectedHIDFailure.invalid("Rotation requires a positive radius, nonzero angle in -360...360 degrees and spacing in (0, 200]")
            }
            let segments = ceil(abs(value.degrees * .pi / 180) * value.radius / value.spacing)
            guard segments.isFinite, segments <= Double(Self.maximumSegments) else {
                throw SelectedHIDFailure.invalid("Rotation exceeds the 500-segment limit")
            }
            try value.timing.validate(activeDuration: value.duration)
        case .twoFingerTap(let value), .twoFingerHold(let value):
            try value.first.validate()
            try value.second.validate()
            guard value.first.x != value.second.x || value.first.y != value.second.y else {
                throw SelectedHIDFailure.invalid("Two-finger contacts require two distinct points")
            }
            try Self.duration(value.hold)
            try value.timing.validate(activeDuration: value.hold)
        }
    }

    func event(observation: FBSimulatorHIDSessionObservation) throws -> FBSimulatorHIDEvent {
        try validate()
        let builder = FBSimulatorHIDGesture(observation: observation)
        let motion: FBSimulatorHIDEvent
        let timing: Timing
        switch self {
        case .doubleTap(let value):
            motion = try builder.doubleTap(at: value.point.cgPoint, hold: value.hold, interval: value.interval)
            timing = value.timing
        case .rotate(let value):
            motion = try builder.rotate(at: value.center.cgPoint, degrees: value.degrees,
                radius: value.radius, duration: value.duration, spacing: value.spacing)
            timing = value.timing
        case .twoFingerTap(let value), .twoFingerHold(let value):
            motion = try builder.twoFingerTap(first: value.first.cgPoint, second: value.second.cgPoint, hold: value.hold)
            timing = value.timing
        }
        var events: [FBSimulatorHIDEvent] = []
        if timing.preDelay > 0 { events.append(.delay(timing.preDelay)) }
        events.append(motion)
        if timing.postDelay > 0 { events.append(.delay(timing.postDelay)) }
        let event = FBSimulatorHIDEvent.composite(events)
        guard Self.leafCount(event) <= Self.maximumEventCount else {
            throw SelectedHIDFailure.invalid("Complete gesture exceeds the 1024-event limit")
        }
        _ = try FBSimulatorHIDSession.preflight(event, observation: observation)
        return event
    }

    private static func duration(_ seconds: Double) throws {
        guard seconds.isFinite, seconds > 0, seconds <= 10 else {
            throw SelectedHIDFailure.invalid("Gesture timing must be finite and in (0, 10] seconds")
        }
    }

    private static func leafCount(_ event: FBSimulatorHIDEvent) -> Int {
        guard let children = event.subEvents else { return 1 }
        return children.reduce(0) { $0 + leafCount($1) }
    }
}
