import Foundation
import FBSimulatorControl

/// One complete two-contact gesture. The owner supplies the fresh selected observation.
/// Without a centre the pinch is at the centre of the screen; without a radius it starts a quarter of
/// the screen's shorter side from the centre. The owner fills both from the display it binds.
struct SelectedHIDPinch: Codable, Sendable {
    static let maximumSegments = 500
    static let maximumEventCount = 1024
    var centerX: Double?
    var centerY: Double?
    let scale: Double
    var radius: Double?
    var duration: Double = 0.6
    var spacing: Double = 5
    var preDelay: Double = 0
    var postDelay: Double = 0

    func validate() throws {
        guard (centerX == nil) == (centerY == nil),
              [centerX, centerY].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }),
              scale.isFinite, scale > 0, scale != 1,
              radius.map({ $0.isFinite && $0 > 0 && ($0 * scale).isFinite && $0 * scale > 0 }) ?? true else {
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
        if let radius {
            let segments = ceil(abs(radius * scale - radius) / spacing)
            guard segments.isFinite, segments <= Double(Self.maximumSegments) else {
                throw SelectedHIDFailure.invalid("Pinch exceeds 500 movement segments")
            }
        }
    }

    /// The pinch with its omitted centre and radius taken from a `logicalSize` screen.
    func resolved(logicalSize: CGSize) throws -> SelectedHIDPinch {
        var value = self
        value.centerX = centerX ?? logicalSize.width / 2
        value.centerY = centerY ?? logicalSize.height / 2
        value.radius = radius ?? min(logicalSize.width, logicalSize.height) / 4
        try value.validate()
        return value
    }

    func event(observation: FBSimulatorHIDSessionObservation) throws -> FBSimulatorHIDEvent {
        let pinch = try resolved(logicalSize: observation.displayContext.logicalSize)
        guard let centerX = pinch.centerX, let centerY = pinch.centerY, let radius = pinch.radius else {
            throw SelectedHIDFailure.invalid("Pinch geometry is incomplete")
        }
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
