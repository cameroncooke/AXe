import Foundation

/// Reference geometry has no caller-supplied centre. The owner supplies its fresh area centre.
struct AgentModePinch: Codable, Sendable {
    let radius: Double
    let scale: Double
    let spacing: Double

    func selected(at centre: CGPoint, duration: Double, preDelay: Double, postDelay: Double) -> SelectedHIDPinch {
        SelectedHIDPinch(centerX: centre.x, centerY: centre.y, scale: scale, radius: radius,
            duration: duration, spacing: spacing, preDelay: preDelay, postDelay: postDelay)
    }
}
