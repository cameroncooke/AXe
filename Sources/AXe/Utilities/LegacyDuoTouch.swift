import Foundation
import FBSimulatorControl

/// The existing no-flag touch surface, bound to one measured Duo context.
struct LegacyDuoTouch: Codable, Sendable {
    let x: Double
    let y: Double
    let down: Bool
    let up: Bool
    let delay: Double?

    func validate() throws {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, down || up else {
            throw SelectedHIDFailure.invalid("Touch requires finite non-negative coordinates and a down or up")
        }
        if let delay {
            guard down, up, delay.isFinite, (0...10).contains(delay) else {
                throw SelectedHIDFailure.invalid("Touch delay requires down/up and must be in 0...10 seconds")
            }
        }
    }

    func event() throws -> FBSimulatorHIDEvent {
        try validate()
        var events: [FBSimulatorHIDEvent] = []
        if down { events.append(.touch(direction: .down, x: x, y: y)) }
        if down && up {
            let hold = delay ?? TapTiming.defaultHoldDuration
            if hold > 0 { events.append(.delay(hold)) }
        }
        if up { events.append(.touch(direction: .up, x: x, y: y)) }
        return .composite(events)
    }
}
