import Foundation
import FBSimulatorControl

/// Retain legacy event construction without selected-path timing or wire-array limits.
struct LegacyDuoPath: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case swipe, drag, draw }
    let kind: Kind
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
    let duration: Double
    var delta: Double? = nil
    var steps: Int? = nil
    /// Draw only: every point of the stroke, in order; the endpoints repeat its first and last.
    var points: [SelectedHIDCompleteGesture.Point]? = nil

    // Bound allocation before expanding an untrusted compact request into native events.
    private static let maximumMoves = 100_000

    init(kind: Kind, startX: Double, startY: Double, endX: Double, endY: Double, duration: Double,
         delta: Double? = nil, steps: Int? = nil) {
        self.kind = kind; self.startX = startX; self.startY = startY; self.endX = endX; self.endY = endY
        self.duration = duration; self.delta = delta; self.steps = steps
    }

    /// One stroke through `points`, which `validate` checks.
    init(drawing points: [CGPoint], duration: Double) {
        let first = points.first ?? .zero, last = points.last ?? .zero
        self.init(kind: .draw, startX: first.x, startY: first.y, endX: last.x, endY: last.y, duration: duration)
        self.points = points.map { SelectedHIDCompleteGesture.Point(x: $0.x, y: $0.y) }
    }

    private var strokePoints: [CGPoint] {
        points?.map(\.cgPoint) ?? [CGPoint(x: startX, y: startY), CGPoint(x: endX, y: endY)]
    }

    func validate() throws {
        guard (points != nil) == (kind == .draw) else {
            throw SelectedHIDFailure.invalid("Only a draw carries a point list")
        }
        if kind == .draw {
            let stroke = strokePoints
            try TouchStroke.validate(stroke)
            guard delta == nil, steps == nil, duration.isFinite, duration > 0, duration <= TouchStroke.maximumDuration,
                  stroke.first == CGPoint(x: startX, y: startY), stroke.last == CGPoint(x: endX, y: endY) else {
                throw SelectedHIDFailure.invalid("Draw requires its points, matching endpoints and a duration in (0,30]")
            }
            return
        }
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
        case .draw:
            break
        }
    }

    /// Called only after validate(), so conversion to the socket's integer interval is safe.
    var responseTimeoutMilliseconds: Int {
        Int(ceil((duration + (kind == .swipe ? 0 : 0.1) + 120) * 1000))
    }

    @MainActor
    func event(logicalSize: CGSize) throws -> FBSimulatorHIDEvent {
        try validate()
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else {
            throw SelectedHIDFailure.invalid("Missing measured logical display bounds")
        }
        let stroke = strokePoints
        if kind == .draw {
            try TouchStroke.requireInside(stroke, width: logicalSize.width, height: logicalSize.height)
        }
        guard stroke.allSatisfy({ $0.x <= logicalSize.width && $0.y <= logicalSize.height }) else {
            throw SelectedHIDFailure.invalid("Path endpoints exceed the measured logical display")
        }
        switch kind {
        case .swipe:
            return .swipe(startX, yStart: startY, xEnd: endX, yEnd: endY,
                          delta: delta!, duration: duration)
        case .drag, .draw:
            let moves = steps ?? TouchStroke.moveCount(duration: duration)
            return .composite(TouchStroke.primitives(through: stroke, duration: duration, moves: moves,
                initialHold: Drag.initialHold, finalHold: Drag.finalHold).map(\.event))
        }
    }
}
