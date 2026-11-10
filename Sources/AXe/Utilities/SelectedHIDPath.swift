import Foundation
import FBSimulatorControl

/// A value-only path request. The owner resolves presets after it owns fresh display geometry.
struct SelectedHIDPath: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case swipe, drag, preset, draw }
    /// `ordinary` keeps the ordinary commands' events and limits on the broker route: a swipe is one
    /// native swipe event, a drag may last longer than a selected path, and the client keeps the delays.
    enum Generator: String, Codable, Sendable { case selected, ordinary }
    let kind: Kind
    var preset: GesturePreset? = nil
    var startX: Double? = nil
    var startY: Double? = nil
    var endX: Double? = nil
    var endY: Double? = nil
    let duration: Double
    var delta: Double? = nil
    var steps: Int? = nil
    var preDelay: Double = 0
    var postDelay: Double = 0
    var expectedWidth: Double? = nil
    var expectedHeight: Double? = nil
    var edgeInset: Double? = nil
    /// Scroll presets only: length as a fraction of the screen. Nil keeps 200 points.
    var distance: Double? = nil
    /// Agent swipes slow to rest before lift-off. A linear swipe releases at full speed and the
    /// content keeps decelerating for about two seconds; at rest it stops with the finger, moves
    /// the path distance, and the replacement read settles at once. Raw swipes stay linear.
    var endsAtRest: Bool? = nil
    /// Drag only: seconds the finger rests on the start point before it moves. Nil is `Drag.initialHold`.
    /// A list starts a reorder, and an icon lifts, only after a rest of about half a second.
    var hold: Double? = nil
    /// Draw only: every point of the stroke, in order. A drag is the two-point stroke of its endpoints.
    var points: [SelectedHIDCompleteGesture.Point]? = nil
    /// Nil is `selected`.
    var generator: Generator? = nil

    /// Bounds allocation before an ordinary swipe expands into native events.
    private static let maximumOrdinaryMoves = 100_000

    var initialHold: Double { hold ?? Drag.initialHold }

    var strokePoints: [CGPoint] {
        if let points { return points.map(\.cgPoint) }
        return [CGPoint(x: startX ?? 0, y: startY ?? 0), CGPoint(x: endX ?? 0, y: endY ?? 0)]
    }

    func validate() throws {
        if let hold {
            guard kind == .drag, hold.isFinite, (0...Drag.maximumHold).contains(hold) else {
                throw SelectedHIDFailure.invalid("Only a drag takes a hold, of 0 to 10 seconds")
            }
        }
        if generator == .ordinary { return try validateOrdinary() }
        guard endsAtRest != true || kind == .swipe || kind == .preset else {
            throw SelectedHIDFailure.invalid("Only a swipe can end at rest")
        }
        guard (points != nil) == (kind == .draw) else {
            throw SelectedHIDFailure.invalid("Only a draw carries a point list")
        }
        if kind == .draw {
            guard preset == nil, edgeInset == nil, distance == nil, expectedWidth == nil, expectedHeight == nil,
                  startX == nil, startY == nil, endX == nil, endY == nil, delta == nil, steps == nil,
                  duration.isFinite, duration > 0, duration <= TouchStroke.maximumDuration,
                  preDelay.isFinite, (0...10).contains(preDelay),
                  postDelay.isFinite, (0...10).contains(postDelay) else {
                throw SelectedHIDFailure.invalid("A draw takes its points, a duration in (0,30] and delays in [0,10] only")
            }
            try TouchStroke.validate(strokePoints)
            return
        }
        guard duration.isFinite, duration > 0, duration <= 10,
              preDelay.isFinite, (0...10).contains(preDelay),
              postDelay.isFinite, (0...10).contains(postDelay) else {
            throw SelectedHIDFailure.invalid("Selected path duration must be in (0,10]; delays must be in [0,10]")
        }
        let holds = kind == .drag ? initialHold + Drag.finalHold : 0
        guard preDelay + duration + holds + postDelay <= 20 else {
            throw SelectedHIDFailure.invalid("Selected path total delay exceeds 20 seconds")
        }
        if kind == .preset {
            guard let preset, startX == nil, startY == nil, endX == nil, endY == nil else {
                throw SelectedHIDFailure.invalid("Preset requires a named pattern and no explicit endpoints")
            }
            try preset.validateEdgeInset(edgeInset)
            do { try preset.validateDistance(distance) }
            catch { throw SelectedHIDFailure.invalid("Distance is a scroll preset's fraction of the screen, 0.05 to 0.95") }
        } else {
            guard preset == nil, edgeInset == nil, distance == nil, expectedWidth == nil, expectedHeight == nil,
                  let startX, let startY, let endX, let endY,
                  [startX, startY, endX, endY].allSatisfy({ $0.isFinite && $0 >= 0 }),
                  startX != endX || startY != endY else {
                throw SelectedHIDFailure.invalid("Selected path requires finite distinct non-negative endpoints")
            }
        }
        for dimension in [expectedWidth, expectedHeight].compactMap({ $0 }) {
            guard dimension.isFinite, dimension > 0 else {
                throw SelectedHIDFailure.invalid("Expected dimensions must be finite and positive")
            }
        }
        if kind == .drag {
            guard delta == nil, let steps, (1...1000).contains(steps) else {
                throw SelectedHIDFailure.invalid("Selected drag requires 1...1000 steps and no delta")
            }
        } else {
            guard steps == nil, let delta, delta.isFinite, delta > 0 else {
                throw SelectedHIDFailure.invalid("Selected swipe requires a finite positive delta and no step override")
            }
        }
    }

    private func validateOrdinary() throws {
        guard (points != nil) == (kind == .draw) else {
            throw SelectedHIDFailure.invalid("Only a draw carries a point list")
        }
        guard kind != .preset, preset == nil, edgeInset == nil, distance == nil, expectedWidth == nil, expectedHeight == nil,
              endsAtRest == nil || kind == .swipe, preDelay == 0, postDelay == 0 else {
            throw SelectedHIDFailure.invalid("An ordinary path takes endpoints or points, a duration and delta or steps only")
        }
        if kind == .draw {
            try TouchStroke.validate(strokePoints)
            guard startX == nil, startY == nil, endX == nil, endY == nil, delta == nil, steps == nil,
                  duration.isFinite, duration > 0, duration <= TouchStroke.maximumDuration else {
                throw SelectedHIDFailure.invalid("Draw requires its points and a duration in (0,30]")
            }
            return
        }
        guard let startX, let startY, let endX, let endY,
              [startX, startY, endX, endY].allSatisfy({ $0.isFinite && $0 >= 0 }),
              startX != endX || startY != endY,
              duration.isFinite, duration > 0,
              duration < Double(UInt64.max) / 1_000_000_000 else {
            throw SelectedHIDFailure.invalid("Path requires finite distinct points and a representable positive duration")
        }
        if kind == .swipe {
            guard steps == nil, let delta, delta.isFinite, delta > 0 else {
                throw SelectedHIDFailure.invalid("Swipe requires a finite positive delta and no steps")
            }
            let moves = sqrt(pow(endY - startY, 2) + pow(endX - startX, 2)) / delta
            guard moves.isFinite, moves < Double(Self.maximumOrdinaryMoves + 1) else {
                throw SelectedHIDFailure.invalid("Swipe exceeds 100000 movement steps")
            }
        } else {
            guard delta == nil, let steps, (1...1000).contains(steps) else {
                throw SelectedHIDFailure.invalid("Drag requires 1...1000 steps and no delta")
            }
        }
    }

    /// The ordinary route's socket read bound: the motion plus two minutes. Selected paths use the default.
    var responseTimeoutMilliseconds: Int? {
        guard generator == .ordinary else { return nil }
        return Int(ceil((duration + (kind == .swipe ? 0 : 0.1) + 120) * 1000))
    }

    /// The one event the owner sends for this path on the current display.
    func event(logicalSize: CGSize) throws -> FBSimulatorHIDEvent {
        guard generator == .ordinary else { return .composite(try primitives(logicalSize: logicalSize).map(\.event)) }
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
        if kind == .swipe, let delta {
            if endsAtRest == true {
                return .composite(Self.restingSwipe(from: stroke[0], to: stroke[1], duration: duration, delta: delta)
                    .map(\.event))
            }
            return .swipe(stroke[0].x, yStart: stroke[0].y, xEnd: stroke[1].x, yEnd: stroke[1].y,
                          delta: delta, duration: duration)
        }
        let moves = steps ?? TouchStroke.moveCount(duration: duration)
        return .composite(TouchStroke.primitives(through: stroke, duration: duration, moves: moves,
            initialHold: initialHold, finalHold: Drag.finalHold).map(\.event))
    }

    /// Down at the start, `count` moves over `duration`, up at the end.
    static func swipe(from start: CGPoint, to end: CGPoint, duration: Double, count: Int,
                      endsAtRest: Bool) -> [SelectedHIDPrimitive] {
        var result: [SelectedHIDPrimitive] = [.touch(.down, x: start.x, y: start.y)]
        for index in 1...count {
            result.append(.delay(duration / Double(count)))
            let linear = Double(index) / Double(count)
            // Cubic ease-out: the last movements are small, so the release velocity is near zero.
            let fraction = endsAtRest ? 1 - pow(1 - linear, 3) : linear
            let point = index == count ? end : CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction)
            result.append(.touch(.down, x: point.x, y: point.y))
        }
        result.append(.touch(.up, x: end.x, y: end.y))
        return result
    }

    /// A swipe that ends at rest, for the routes that send one event: at least eight moves, so the
    /// easing has small last movements even when `delta` is a large part of the path.
    static func restingSwipe(from start: CGPoint, to end: CGPoint, duration: Double, delta: Double) -> [SelectedHIDPrimitive] {
        let moves = ceil(hypot(end.x - start.x, end.y - start.y) / max(delta, 1))
        return swipe(from: start, to: end, duration: duration, count: Int(min(1000, max(8, moves))), endsAtRest: true)
    }

    func primitives(logicalSize: CGSize) throws -> [SelectedHIDPrimitive] {
        guard generator != .ordinary else { throw SelectedHIDFailure.invalid("An ordinary path is one event") }
        try validate()
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else {
            throw SelectedHIDFailure.invalid("Missing current logical display bounds")
        }
        if let expectedWidth, expectedWidth != logicalSize.width {
            throw SelectedHIDFailure.invalid("Supplied screen width does not match the selected display")
        }
        if let expectedHeight, expectedHeight != logicalSize.height {
            throw SelectedHIDFailure.invalid("Supplied screen height does not match the selected display")
        }
        if kind == .drag || kind == .draw {
            let points = strokePoints
            try TouchStroke.requireInside(points, width: logicalSize.width, height: logicalSize.height)
            let moves = steps ?? TouchStroke.moveCount(duration: duration)
            var result: [SelectedHIDPrimitive] = preDelay > 0 ? [.delay(preDelay)] : []
            result += TouchStroke.primitives(through: points, duration: duration, moves: moves,
                initialHold: initialHold, finalHold: Drag.finalHold)
            if postDelay > 0 { result.append(.delay(postDelay)) }
            // Geometry and complete contact lifecycle are preflighted by the owned V12 session.
            return result
        }
        let start: CGPoint
        let end: CGPoint
        if let preset {
            try preset.validateEdgeInset(edgeInset, screenWidth: logicalSize.width, screenHeight: logicalSize.height)
            let points = preset.coordinates(screenWidth: logicalSize.width, screenHeight: logicalSize.height,
                edgeInset: edgeInset, distance: distance)
            start = CGPoint(x: points.startX, y: points.startY)
            end = CGPoint(x: points.endX, y: points.endY)
        } else {
            start = CGPoint(x: startX!, y: startY!)
            end = CGPoint(x: endX!, y: endY!)
        }
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance.isFinite, distance > 0 else {
            throw SelectedHIDFailure.invalid("Selected path distance must be finite and positive")
        }
        let count: Int
        if let steps { count = steps }
        else {
            let countValue = ceil(distance / delta!)
            guard countValue.isFinite, countValue <= 1000 else {
                throw SelectedHIDFailure.invalid("Selected path exceeds 1000 movement steps")
            }
            count = max(1, Int(countValue))
        }
        var result: [SelectedHIDPrimitive] = []
        if preDelay > 0 { result.append(.delay(preDelay)) }
        result += Self.swipe(from: start, to: end, duration: duration, count: count, endsAtRest: endsAtRest == true)
        if postDelay > 0 { result.append(.delay(postDelay)) }
        // Geometry and complete contact lifecycle are preflighted by the owned V12 session.
        return result
    }
}
