import Foundation
import Testing

/// Draws on the Playground Drawing screen and checks the stroke the app recorded from its raw touches.
/// The matrix runs these on the iPhone, the iPad and the Duo.
@Suite("Playground Drawing E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundDrawingTests {
    @Test("A straight line starts, ends and stays on its points")
    func line() async throws {
        let canvas = try await DrawingCanvas.open()
        try await canvas.draw([(0.15, 0.5), (0.85, 0.5)])
    }

    @Test("A closed triangle returns to its first point through every corner")
    func closedTriangle() async throws {
        let canvas = try await DrawingCanvas.open()
        try await canvas.draw([(0.5, 0.2), (0.8, 0.8), (0.2, 0.8)], close: true, duration: 1.5)
    }

    @Test("A zigzag passes every turn in order")
    func zigzag() async throws {
        let canvas = try await DrawingCanvas.open()
        try await canvas.draw([(0.1, 0.7), (0.3, 0.3), (0.5, 0.7), (0.7, 0.3), (0.9, 0.7)])
    }

    @Test("Selected input draws on the active screen")
    func selected() async throws {
        let canvas = try await DrawingCanvas.open()
        try await canvas.draw([(0.2, 0.3), (0.8, 0.3), (0.8, 0.7)], flags: ["--input-mode", "selected"])
    }

    @Test("A batch step draws one stroke")
    func batchStep() async throws {
        let canvas = try await DrawingCanvas.open()
        try await canvas.draw([(0.2, 0.7), (0.5, 0.3), (0.8, 0.7)], close: true, inBatch: true)
    }
}

/// Pinches the Playground Zoom screen's scroll view without selected input.
@Suite("Playground Zoom E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundZoomTests {
    @Test("Pinch at the default centre and radius zooms in, then out")
    func defaultPinch() async throws {
        try await pinchInThenOut(geometry: { _ in [] })
    }

    @Test("Pinch at an explicit point and radius zooms in, then out")
    func explicitPinch() async throws {
        try await pinchInThenOut { surface in
            let radius = Int(min(surface.width, surface.height) / 6)
            return ["-x", String(Int(surface.x + surface.width / 2)), "-y", String(Int(surface.y + surface.height / 2)),
                    "--radius", String(radius)]
        }
    }

    /// The scale lands short of the request (an iPad measured 1.82 for 2), so check direction and range.
    private func pinchInThenOut(geometry: (UIElement.Frame) -> [String]) async throws {
        let app = try CorePlaygroundSession()
        let initial = try await app.open("zoom", readyID: "zoom.surface")
        try #require(app.value("zoom.scale", in: initial) == "1.00" && app.value("zoom.events", in: initial) == "0")
        let surface = try app.frame(of: app.element("zoom.surface", in: initial))
        let options = geometry(surface)

        try await app.run(["gesture", "pinch", "--scale", "2"] + options)
        let zoomedIn = try await app.waitFor("one zoom in") { state in
            app.value("zoom.events", in: state) == "1" && app.value("zoom.last", in: state) == "in"
        }
        let inScale = try #require(app.value("zoom.scale", in: zoomedIn).flatMap(Double.init))
        print("Pinch in \(options): scale \(inScale)")
        #expect(inScale > 1.3 && inScale <= 2.2)

        try await app.run(["gesture", "pinch", "--scale", "0.5"] + options)
        let zoomedOut = try await app.waitFor("one zoom out") { state in
            app.value("zoom.events", in: state) == "2" && app.value("zoom.last", in: state) == "out"
        }
        let outScale = try #require(app.value("zoom.scale", in: zoomedOut).flatMap(Double.init))
        print("Pinch out \(options): scale \(outScale)")
        #expect(outScale < inScale - 0.3 && outScale >= 0.5 && outScale < 1.4)
    }
}

/// One fresh Drawing screen and the canvas frame the points are placed in.
private struct DrawingCanvas {
    let app: CorePlaygroundSession
    let frame: UIElement.Frame

    static func open() async throws -> DrawingCanvas {
        let app = try CorePlaygroundSession()
        let state = try await app.open("drawing", readyID: "drawing.canvas")
        try #require(app.value("drawing.strokeCount", in: state) == "0")
        return DrawingCanvas(app: app, frame: try app.frame(of: app.element("drawing.canvas", in: state)))
    }

    /// Draws through canvas-relative points and checks start, end, bounds, contacts, duration and path.
    func draw(_ relative: [(Double, Double)], close: Bool = false, duration: Double = 1,
              flags: [String] = [], inBatch: Bool = false) async throws {
        let points = relative.map { CGPoint(x: (frame.x + frame.width * $0.0).rounded(),
                                            y: (frame.y + frame.height * $0.1).rounded()) }
        let arguments = points.map { "\(Int($0.x)),\(Int($0.y))" } + (close ? ["--close"] : [])
            + ["--duration", String(duration)]
        let started = Date()
        if inBatch {
            try await app.run(["batch", "--step", (["draw"] + arguments).joined(separator: " ")])
        } else {
            try await app.run(["draw"] + arguments + flags)
        }
        let elapsed = Date().timeIntervalSince(started)
        let state = try await app.waitFor("one completed stroke") { state in
            app.value("drawing.strokeCount", in: state) == "1" && app.value("drawing.active", in: state) == "false"
        }
        let stroke = close ? points + [points[0]] : points
        let value = { (id: String) in app.value("drawing.last." + id, in: state) ?? "" }
        print("Drew \(arguments) in \(String(format: "%.2f", elapsed)) s. App: start \(value("start")), end \(value("end")), "
            + "bounds \(value("bounds")), points \(value("points")), duration \(value("duration")), "
            + "maxTouches \(value("maxTouches")), cancelled \(value("cancelled")), path \(value("path"))")

        let start = try Self.point(value("start")), end = try Self.point(value("end"))
        #expect(Self.distance(start, stroke[0]) <= 2 && Self.distance(end, stroke[stroke.count - 1]) <= 2)
        let bounds = value("bounds").split(separator: ",").compactMap { Double($0) }
        try #require(bounds.count == 4)
        let xs = stroke.map(\.x), ys = stroke.map(\.y)
        let expectedBounds = [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
        #expect(zip(bounds, expectedBounds).allSatisfy { abs($0 - $1) <= 2 }, "bounds \(bounds) vs \(expectedBounds)")
        #expect(value("maxTouches") == "1" && value("cancelled") == "false")
        // Both drag holds add 0.1 s. Each route also spends a few milliseconds sending every move.
        let recorded = try #require(Double(value("duration")))
        #expect(recorded >= duration * 0.9 && recorded <= duration * 1.6 + 0.3, "duration \(recorded) for \(duration)")
        let path = try value("path").split(separator: ";").map { try Self.point(String($0)) }
        let expected = Self.resampled(stroke, count: 16)
        try #require(path.count == 16)
        #expect(zip(path, expected).allSatisfy { Self.distance($0, $1) <= 4 }, "path \(path) vs \(expected)")
    }

    private static func point(_ text: String) throws -> CGPoint {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { throw TestError.unexpectedState("Not a point: \(text)") }
        return CGPoint(x: parts[0], y: parts[1])
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    /// The app's resampling: `count` points evenly spaced by arc length, including both ends.
    private static func resampled(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let lengths = zip(points, points.dropFirst()).map { distance($0, $1) }
        let total = lengths.reduce(0, +)
        return (0..<count).map { index in
            var target = total * Double(index) / Double(count - 1)
            for (segment, length) in lengths.enumerated() {
                if target <= length || segment == lengths.count - 1 {
                    let t = length > 0 ? min(1, target / length) : 0
                    let a = points[segment], b = points[segment + 1]
                    return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                }
                target -= length
            }
            return points[points.count - 1]
        }
    }
}
