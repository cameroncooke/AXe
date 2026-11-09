import Foundation
import FBSimulatorControl

/// Retain legacy event construction without selected-path timing or wire-array limits.
struct LegacyDuoPath: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case swipe, drag }
    let kind: Kind
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
    let duration: Double
    var delta: Double? = nil
    var steps: Int? = nil

    // Bound allocation before expanding an untrusted compact request into native events.
    private static let maximumMoves = 100_000

    func validate() throws {
        guard [startX, startY, endX, endY].allSatisfy({ $0.isFinite && $0 >= 0 }),
              startX != endX || startY != endY,
              duration.isFinite, duration > 0,
              duration < Double(UInt64.max) / 1_000_000_000 else {
            throw SelectedHIDFailure.invalid("Path requires finite distinct points and a representable positive duration")
        }
        switch kind {
        case .swipe:
            guard steps == nil, let delta, delta.isFinite, delta > 0 else {
                throw SelectedHIDFailure.invalid("Swipe requires a finite positive delta and no steps")
            }
            let distance = sqrt(pow(endY - startY, 2) + pow(endX - startX, 2))
            let moves = distance / delta
            guard moves.isFinite, moves < Double(Self.maximumMoves + 1) else {
                throw SelectedHIDFailure.invalid("Swipe exceeds 100000 movement steps")
            }
        case .drag:
            guard delta == nil, let steps, (1...1000).contains(steps) else {
                throw SelectedHIDFailure.invalid("Drag requires 1...1000 steps and no delta")
            }
        }
    }

    /// Called only after validate(), so conversion to the socket's integer interval is safe.
    var responseTimeoutMilliseconds: Int {
        Int(ceil((duration + (kind == .drag ? 0.1 : 0) + 120) * 1000))
    }

    @MainActor
    func event(logicalSize: CGSize) throws -> FBSimulatorHIDEvent {
        try validate()
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0,
              startX <= logicalSize.width, endX <= logicalSize.width,
              startY <= logicalSize.height, endY <= logicalSize.height else {
            throw SelectedHIDFailure.invalid("Path endpoints exceed the measured logical display")
        }
        switch kind {
        case .swipe:
            return .swipe(startX, yStart: startY, xEnd: endX, yEnd: endY,
                          delta: delta!, duration: duration)
        case .drag:
            return try HIDInteractor.makeCompositeDragEvent(
                from: (x: startX, y: startY), to: (x: endX, y: endY),
                duration: duration, steps: steps!, initialHold: 0.05, finalHold: 0.05
            )
        }
    }
}
