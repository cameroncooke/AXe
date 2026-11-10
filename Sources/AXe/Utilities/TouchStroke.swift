import Foundation

/// One finger along straight segments: down at the first point, through every point in order, up at
/// the last. Time is spread by arc length, so the finger moves at one speed. Drag is the two-point case.
enum TouchStroke {
    /// 1,000 given points plus the return to the first for `draw --close`.
    static let maximumPoints = 1_001
    static let maximumMoves = 1_000
    static let maximumDuration: TimeInterval = 30
    /// Draw moves every 20 ms. The simulator merges touch moves that arrive within one 60 Hz display
    /// frame and keeps the last, so at a default drag's 10 ms about half the moves, corners
    /// included, never reach the app; measured on iOS 27.2, a triangle lost up to 5 points at a corner.
    static let movesPerSecond = 50.0

    /// Two to 1,000 finite, non-negative points, with no point repeating the one before it.
    static func validate(_ points: [CGPoint]) throws {
        guard (2...maximumPoints).contains(points.count) else {
            throw SelectedHIDFailure.invalid("A stroke needs 2 to \(maximumPoints) points")
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }) else {
            throw SelectedHIDFailure.invalid("Stroke points must be finite and non-negative")
        }
        for index in 1..<points.count where points[index] == points[index - 1] {
            throw SelectedHIDFailure.invalid("Stroke point \(index + 1) repeats the point before it")
        }
    }

    /// The moves a draw makes: one per 20 ms, at most 1,000.
    static func moveCount(duration: TimeInterval) -> Int {
        max(1, Int(min(Double(maximumMoves), ceil(duration * movesPerSecond))))
    }

    /// The first point outside a `width` x `height` screen, numbered from 1, or nil.
    static func outsidePoint(_ points: [CGPoint], width: Double, height: Double) -> String? {
        guard let index = points.firstIndex(where: { $0.x > width || $0.y > height || $0.x < 0 || $0.y < 0 }) else {
            return nil
        }
        return "Point \(index + 1) (\(text(points[index].x)),\(text(points[index].y))) is outside the "
            + "\(text(width))x\(text(height)) screen"
    }

    /// Fails with `invalidArguments` before any input when a point is off the screen.
    static func requireInside(_ points: [CGPoint], width: Double, height: Double) throws {
        if let outside = outsidePoint(points, width: width, height: height) {
            throw SelectedHIDFailure.coded(code: CLIError.Code.invalidArguments.rawValue, message: outside)
        }
    }

    /// Down, hold, about `moves` moves, hold, up. Each segment gets its share of the moves and of the
    /// duration by its length, at least one move, and ends exactly on its point, so corners are never
    /// cut. A drag is one segment with exactly `moves` moves; it may repeat its point.
    static func primitives(through points: [CGPoint], duration: TimeInterval, moves: Int,
                           initialHold: TimeInterval, finalHold: TimeInterval) -> [SelectedHIDPrimitive] {
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        var result: [SelectedHIDPrimitive] = [.touch(.down, x: points[0].x, y: points[0].y), .delay(initialHold)]
        for (index, length) in lengths.enumerated() {
            let share = total > 0 ? length / total : 1 / Double(lengths.count)
            let count = max(1, Int((Double(moves) * share).rounded()))
            let interval = duration * share / Double(count)
            let start = points[index], end = points[index + 1]
            for step in 1...count {
                let fraction = Double(step) / Double(count)
                let point = step == count ? end : CGPoint(x: start.x + (end.x - start.x) * fraction,
                                                          y: start.y + (end.y - start.y) * fraction)
                result.append(.delay(interval))
                result.append(.touch(.down, x: point.x, y: point.y))
            }
        }
        let last = points[points.count - 1]
        result.append(.delay(finalHold))
        result.append(.touch(.up, x: last.x, y: last.y))
        return result
    }

    private static func text(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
