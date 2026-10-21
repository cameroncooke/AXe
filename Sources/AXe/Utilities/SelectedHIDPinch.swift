import Foundation
import FBSimulatorControl

/// One complete two-contact gesture. The owner supplies the fresh selected observation.
struct SelectedHIDPinch: Codable, Sendable {
    static let maximumSegments = 500
    static let maximumEventCount = 1024
    let centerX: Double
    let centerY: Double
    let scale: Double
    let radius: Double
    var duration: Double = 0.6
    var spacing: Double = 5
    var preDelay: Double = 0
    var postDelay: Double = 0

    func validate() throws {
        let endRadius = radius * scale
        guard centerX.isFinite, centerY.isFinite, centerX >= 0, centerY >= 0,
              scale.isFinite, scale > 0, scale != 1,
              radius.isFinite, radius > 0, endRadius.isFinite, endRadius > 0 else {
            throw SelectedHIDFailure.invalid("Pinch requires finite non-negative center coordinates, positive radius and scale other than 1")
        }
        guard duration.isFinite, duration > 0, duration <= 10,
              spacing.isFinite, spacing > 0, spacing <= 200,
              preDelay.isFinite, (0...10).contains(preDelay),
              postDelay.isFinite, (0...10).contains(postDelay),
              preDelay + duration + postDelay <= 20 else {
            throw SelectedHIDFailure.invalid("Pinch duration must be in (0,10], delta in (0,200], delays in [0,10], and total delay at most 20 seconds")
        }
        // Bound the donor's work before it allocates its event array. This is a count
        // check only; all interpolation and both contacts come from the library builder.
        let segments = ceil(abs(endRadius - radius) / spacing)
        guard segments.isFinite, segments <= Double(Self.maximumSegments) else {
            throw SelectedHIDFailure.invalid("Pinch exceeds 500 movement segments")
        }
    }

    func event(observation: FBSimulatorHIDSessionObservation) throws -> FBSimulatorHIDEvent {
        try validate()
        let motion = try FBSimulatorHIDGesture(observation: observation).pinch(
            at: CGPoint(x: centerX, y: centerY), scale: scale, radius: radius,
            duration: duration, spacing: spacing)
        guard var events = motion.subEvents else {
            throw SelectedHIDFailure.invalid("Pinch builder did not return a complete event")
        }
        if preDelay > 0 { events.insert(.delay(preDelay), at: 0) }
        if postDelay > 0 { events.append(.delay(postDelay)) }
        guard events.count <= Self.maximumEventCount else {
            throw SelectedHIDFailure.invalid("Expanded pinch event exceeds its work limit")
        }
        let event = FBSimulatorHIDEvent.composite(events)
        _ = try FBSimulatorHIDSession.preflight(event, observation: observation)
        return event
    }
}
