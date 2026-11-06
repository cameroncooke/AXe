import Foundation

/// A value-only path request. The owner resolves presets after it owns fresh display geometry.
struct SelectedHIDPath: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case swipe, drag, preset }
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
    /// Agent swipes slow to rest before lift-off. A linear swipe releases at full speed and the
    /// content keeps decelerating for about two seconds; at rest it stops with the finger, moves
    /// the path distance, and the replacement read settles at once. Raw swipes stay linear.
    var endsAtRest: Bool? = nil

    func validate() throws {
        guard endsAtRest != true || kind == .swipe else {
            throw SelectedHIDFailure.invalid("Only a swipe can end at rest")
        }
        guard duration.isFinite, duration > 0, duration <= 10,
              preDelay.isFinite, (0...10).contains(preDelay),
              postDelay.isFinite, (0...10).contains(postDelay) else {
            throw SelectedHIDFailure.invalid("Selected path duration must be in (0,10]; delays must be in [0,10]")
        }
        let holds = kind == .drag ? 0.1 : 0
        guard preDelay + duration + holds + postDelay <= 20 else {
            throw SelectedHIDFailure.invalid("Selected path total delay exceeds 20 seconds")
        }
        if kind == .preset {
            guard let preset, startX == nil, startY == nil, endX == nil, endY == nil else {
                throw SelectedHIDFailure.invalid("Preset requires a named pattern and no explicit endpoints")
            }
            try preset.validateEdgeInset(edgeInset)
        } else {
            guard preset == nil, edgeInset == nil, expectedWidth == nil, expectedHeight == nil,
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

    func primitives(logicalSize: CGSize) throws -> [SelectedHIDPrimitive] {
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
        let start: CGPoint
        let end: CGPoint
        if let preset {
            try preset.validateEdgeInset(edgeInset, screenWidth: logicalSize.width, screenHeight: logicalSize.height)
            let points = preset.coordinates(screenWidth: logicalSize.width, screenHeight: logicalSize.height, edgeInset: edgeInset)
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
        result.append(.touch(.down, x: start.x, y: start.y))
        if kind == .drag { result.append(.delay(0.05)) }
        for index in 1...count {
            result.append(.delay(duration / Double(count)))
            let linear = Double(index) / Double(count)
            // Cubic ease-out: the last movements are small, so the release velocity is near zero.
            let fraction = endsAtRest == true ? 1 - pow(1 - linear, 3) : linear
            let point = index == count ? end : CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction)
            result.append(.touch(.down, x: point.x, y: point.y))
        }
        if kind == .drag { result.append(.delay(0.05)) }
        result.append(.touch(.up, x: end.x, y: end.y))
        if postDelay > 0 { result.append(.delay(postDelay)) }
        // Geometry and complete contact lifecycle are preflighted by the owned V12 session.
        return result
    }
}
