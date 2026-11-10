import Foundation
import Testing

/// Paints on the Playground Sketch screen, a PencilKit canvas with the system tool picker. A finger
/// draws there, so `draw` leaves real ink; tools and line weights are chosen in the picker by their
/// accessibility labels. The app reports the stroke count, the selected tool and the last stroke's ink.
/// The matrix runs these on the iPhone, the iPad and the Duo.
@Suite("Playground Sketch E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundSketchTests {
    @Test("A drawn triangle becomes one ink stroke with the selected tool's ink")
    func strokeLeavesInk() async throws {
        let sketch = try await SketchCanvas.open()
        let ink = try await sketch.selectedInk()
        let bounds = try await sketch.draw([(0.5, 0.15), (0.8, 0.55), (0.2, 0.55)], close: true, expectedStrokes: 1)
        let state = try await sketch.app.state()
        #expect(sketch.app.value("sketch.last.ink", in: state) == ink)
        // PencilKit smooths a stroke and adds half the line width on each side.
        let expected = sketch.bounds(of: [(0.5, 0.15), (0.8, 0.55), (0.2, 0.55)])
        #expect(zip(bounds, expected).allSatisfy { abs($0 - $1) <= 20 }, "bounds \(bounds) vs \(expected)")
    }

    @Test("A tool chosen in the tool picker is the ink of the next stroke")
    func toolPickerChoosesTheInk() async throws {
        let sketch = try await SketchCanvas.open()
        let current = try await sketch.selectedTool()
        // A tap on the selected tool opens its options, so the selected tool goes last.
        let tools = ["Marker", "Monoline", "Pen"].filter { $0 != current.label } + [current.label]
        for (index, tool) in tools.prefix(3).enumerated() {
            if tool != (try await sketch.selectedTool()).label { try await sketch.select(tool) }
            let row = 0.15 + 0.15 * Double(index)
            _ = try await sketch.draw([(0.2, row), (0.8, row)], expectedStrokes: index + 1)
            let state = try await sketch.app.state()
            let ink = try #require(sketch.app.value("sketch.last.ink", in: state))
            #expect(ink.hasPrefix(SketchCanvas.ink(for: tool) + " "), "\(tool) drew \(ink)")
        }
    }

    @Test("A heavier line weight chosen in the tool's options draws a wider line")
    func weightChangesTheLine() async throws {
        let sketch = try await SketchCanvas.open()
        // Monoline keeps one width at any speed, so the drawn height depends on the weight alone.
        if (try await sketch.selectedTool()).label != "Monoline" { try await sketch.select("Monoline") }
        var heights: [Double] = [], widths: [Double] = []
        for (index, weight) in ["Very Light", "Very Heavy"].enumerated() {
            widths.append(try await sketch.setWeight(weight, of: "Monoline"))
            let row = 0.2 + 0.2 * Double(index)
            let bounds = try await sketch.draw([(0.2, row), (0.8, row)], expectedStrokes: index + 1)
            heights.append(bounds[3] - bounds[1])
        }
        print("Monoline widths \(widths), drawn heights \(heights)")
        #expect(widths[1] > widths[0] && heights[1] > heights[0])
    }

    /// The one case that looks like a drawing: a blue sky and green grass in marker washes, a sun with
    /// rays, a house, a tree and two birds. It uses three tools, three line weights and nine colours.
    @Test("A picture is painted with three tools, three weights and nine colours")
    func paintsAPicture() async throws {
        let sketch = try await SketchCanvas.open()
        var strokes = 0
        func paint(_ points: [(Double, Double)], seconds: Double? = nil) async throws {
            try await sketch.stroke(points.map(sketch.point), seconds: seconds)
            strokes += 1
        }

        // Sky and grass: washes with the heaviest marker, whose band is about 52 points tall.
        _ = try await sketch.use("Marker", weight: "Very Heavy")
        let band = 52 / sketch.frame.height
        var row = band / 2
        try await sketch.colour("sky")
        while row + band / 2 <= 0.62 { try await paint([(0.01, row), (0.99, row)], seconds: 0.4); row += band }
        let horizon = row - band / 2
        try await sketch.colour("grass")
        while row - band / 2 < 0.97 { try await paint([(0.01, min(row, 1 - band / 2)), (0.99, min(row, 1 - band / 2))], seconds: 0.4); row += band }
        try await sketch.wait(for: strokes)

        // Everything solid uses Monoline: opaque, and one width at any speed.
        _ = try await sketch.use("Monoline", weight: "Very Heavy")
        let sun = (0.80, 0.16), radius = 0.07 * sketch.frame.width
        try await sketch.colour("sun")
        try await sketch.stroke(sketch.disc(at: sun, radius: radius)); strokes += 1
        try await sketch.colour("orange")
        for ray in 0..<6 {
            let angle = Double(ray) / 6 * 2 * Double.pi + 0.3
            let centre = sketch.point(sun)
            try await sketch.stroke([1.5, 2.3].map { CGPoint(x: centre.x + radius * $0 * cos(angle), y: centre.y + radius * $0 * sin(angle)) },
                                    seconds: 0.3)
            strokes += 1
        }
        try await sketch.colour("red")      // the house
        try await sketch.stroke(sketch.fill(from: 0.14, to: 0.42, top: { _ in horizon - 0.10 }, bottom: { _ in horizon + 0.14 })); strokes += 1
        try await sketch.colour("wood")     // its roof, then the tree's trunk
        try await sketch.stroke(sketch.fill(from: 0.10, to: 0.46, top: { horizon - 0.22 + abs($0 - 0.28) / 0.18 * 0.12 }, bottom: { _ in horizon - 0.10 })); strokes += 1
        try await sketch.stroke(sketch.fill(from: 0.70, to: 0.74, top: { _ in horizon - 0.12 }, bottom: { _ in horizon + 0.12 })); strokes += 1
        try await sketch.colour("white")    // the door
        try await sketch.stroke(sketch.fill(from: 0.25, to: 0.31, top: { _ in horizon + 0.02 }, bottom: { _ in horizon + 0.14 })); strokes += 1
        try await sketch.colour("leaf")     // the tree's crown
        try await sketch.stroke(sketch.disc(at: (0.72, horizon - 0.20), radius: 0.10 * sketch.frame.width)); strokes += 1

        // Two birds with the pen.
        _ = try await sketch.use("Pen", weight: "Medium")
        try await sketch.colour("black")
        for (u, v) in [(0.30, 0.12), (0.47, 0.22)] {
            try await paint([(u - 0.04, v), (u - 0.02, v - 0.015), (u, v), (u + 0.02, v - 0.015), (u + 0.04, v)], seconds: 0.3)
        }

        let state = try await sketch.wait(for: strokes)
        let inks = sketch.app.value("sketch.inks", in: state) ?? ""
        print("Painted \(strokes) strokes with inks: \(inks)")
        #expect(inks == "marker #6EC6FF, marker #34C759, monoline #FFD60A, monoline #FF9500, monoline #D62828, "
            + "monoline #8B5A2B, monoline #FFFFFF, monoline #1E7D32, pen #000000")
        let extent = (sketch.app.value("sketch.bounds", in: state) ?? "").split(separator: ",").compactMap { Double($0) }
        try #require(extent.count == 4)
        #expect(extent[2] - extent[0] >= sketch.frame.width * 0.9 && extent[3] - extent[1] >= sketch.frame.height * 0.85,
                "The picture covers \(extent) of \(sketch.frame)")
        // Keep the picture with the run's artifacts.
        if let directory = ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"] {
            try await sketch.app.run(["screenshot", "--output", directory + "/sketch-picture-\(UUID().uuidString.prefix(8)).png"])
        }
    }

    @Test("Clear removes every stroke")
    func clear() async throws {
        let sketch = try await SketchCanvas.open()
        _ = try await sketch.draw([(0.2, 0.2), (0.8, 0.2)], expectedStrokes: 1)
        _ = try await sketch.draw([(0.2, 0.4), (0.8, 0.4), (0.5, 0.55)], expectedStrokes: 2)
        try await sketch.app.run(["tap", "--id", "sketch.clear"])
        try await sketch.app.waitForValue("sketch.strokeCount", equals: "0")
    }
}

/// The Sketch screen with its tool picker expanded. Points are fractions of the canvas above the picker.
struct SketchCanvas {
    let app: CorePlaygroundSession
    let frame: UIElement.Frame

    static func open() async throws -> SketchCanvas {
        let app = try CorePlaygroundSession()
        var state = try await app.open("sketch", readyID: "sketch.canvas")
        try #require(app.value("sketch.strokeCount", in: state) == "0")
        var palette = try app.frame(of: app.element("Drawing-Palette", in: state))
        if palette.width < 200 {
            // A narrow screen shows the picker as one round button until it is tapped.
            try await app.run(["tap", "-x", String(Int(palette.x + palette.width / 2)), "-y", String(Int(palette.y + palette.height / 2))])
            state = try await app.waitFor("the tool picker to expand") { state in
                ((try? app.frame(of: app.element("Drawing-Palette", in: state)))?.width ?? 0) >= 200
            }
            palette = try app.frame(of: app.element("Drawing-Palette", in: state))
        }
        let canvas = try app.frame(of: app.element("sketch.canvas", in: state))
        let visible = UIElement.Frame(x: canvas.x, y: canvas.y, width: canvas.width,
            height: min(canvas.height, palette.y - 8 - canvas.y))
        try #require(visible.height > 120, "The tool picker leaves too little canvas: \(visible)")
        return SketchCanvas(app: app, frame: visible)
    }

    /// PencilKit's ink name for a tool picker label.
    static func ink(for tool: String) -> String { tool.lowercased().replacingOccurrences(of: " ", with: "") }

    func point(_ relative: (Double, Double)) -> CGPoint {
        CGPoint(x: (frame.x + frame.width * relative.0).rounded(), y: (frame.y + frame.height * relative.1).rounded())
    }

    func bounds(of relative: [(Double, Double)]) -> [Double] {
        let xs = relative.map { Double(point($0).x) }, ys = relative.map { Double(point($0).y) }
        return [xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0]
    }

    /// The selected tool as the app reports it: "pen #000000 width 2.7".
    func selectedTool() async throws -> (label: String, ink: String, width: Double) {
        let text = try #require(app.value("sketch.tool", in: try await app.state()))
        let parts = text.split(separator: " ").map(String.init)
        try #require(parts.count == 4 && parts[2] == "width", "Unexpected tool report: \(text)")
        let labels = ["pen": "Pen", "monoline": "Monoline", "marker": "Marker", "pencil": "Pencil", "crayon": "Crayon",
                      "fountainpen": "Fountain Pen", "watercolor": "Watercolor", "reed": "Reed"]
        return (labels[parts[0].lowercased()] ?? parts[0], parts[0] + " " + parts[1], try #require(Double(parts[3])))
    }

    func selectedInk() async throws -> String { try await selectedTool().ink }

    /// Taps a tool that is not selected and waits until the canvas uses it.
    func select(_ tool: String) async throws {
        try await app.run(["tap", "--label", tool, "--element-type", "Button"])
        _ = try await app.waitFor("\(tool) to be selected") { state in
            app.value("sketch.tool", in: state)?.hasPrefix(Self.ink(for: tool) + " ") == true
        }
    }

    /// Opens the selected tool's options with a second tap, picks a weight and closes the options.
    /// Returns the tool's new width.
    func setWeight(_ weight: String, of tool: String) async throws -> Double {
        let isWeight = { (element: UIElement) in element.type == "Button" && element.AXLabel == "Weight" }
        try await app.run(["tap", "--label", tool, "--element-type", "Button"])
        _ = try await app.waitFor("\(tool) options") { app.elements(in: $0).contains(where: isWeight) }
        try await app.run(["tap", "--value", weight, "--element-type", "Button"])
        // A tap on the status line above the canvas is outside the options and closes them.
        let state = try await app.state()
        let line = try app.frame(of: app.element("sketch.drawable", in: state))
        try await app.run(["tap", "-x", String(Int(line.x + line.width / 2)), "-y", String(Int(line.y + line.height / 2))])
        _ = try await app.waitFor("\(tool) options to close") { !app.elements(in: $0).contains(where: isWeight) }
        return try await selectedTool().width
    }

    /// Selects a tool if another is selected, then gives it a line weight. Returns its width.
    func use(_ tool: String, weight: String) async throws -> Double {
        if try await selectedTool().label != tool { try await select(tool) }
        return try await setWeight(weight, of: tool)
    }

    /// Gives the selected tool one of the screen's named colours.
    func colour(_ name: String) async throws {
        try await app.run(["tap", "--id", "sketch.colour." + name])
    }

    /// One stroke through screen points, without waiting for the app to report it.
    func stroke(_ points: [CGPoint], seconds: Double? = nil) async throws {
        let duration = seconds ?? max(0.3, min(10, 0.022 * Double(points.count)))
        try await app.run(["draw"] + points.map { String(format: "%.1f,%.1f", $0.x, $0.y) } + ["--duration", String(format: "%.2f", duration)])
    }

    @discardableResult
    func wait(for strokes: Int) async throws -> UIElement {
        try await app.waitFor("\(strokes) ink strokes") { app.value("sketch.strokeCount", in: $0) == String(strokes) }
    }

    /// A spiral from the centre outwards that leaves no gaps at the heaviest Monoline weight.
    func disc(at centre: (Double, Double), radius: Double, spacing: Double = 4.2) -> [CGPoint] {
        let middle = point(centre), turns = max(1, radius / spacing), count = Int(28 * turns)
        return (1...count).map { index in
            let fraction = Double(index) / Double(count), angle = fraction * turns * 2 * Double.pi
            return CGPoint(x: middle.x + radius * fraction * cos(angle), y: middle.y + radius * fraction * sin(angle))
        }
    }

    /// One zigzag stroke that fills the area between two functions of the horizontal fraction.
    func fill(from left: Double, to right: Double, top: (Double) -> Double, bottom: (Double) -> Double,
              spacing: Double = 4.2) -> [CGPoint] {
        let columns = max(2, Int((right - left) * frame.width / spacing))
        return (0...columns).flatMap { column -> [CGPoint] in
            let u = left + (right - left) * Double(column) / Double(columns)
            let ends = [point((u, top(u))), point((u, bottom(u)))]
            return column.isMultiple(of: 2) ? ends : ends.reversed()
        }
    }

    /// Draws through canvas-relative points, waits for the stroke and returns its bounds in screen points.
    func draw(_ relative: [(Double, Double)], close: Bool = false, expectedStrokes: Int) async throws -> [Double] {
        let arguments = relative.map(point).map { "\(Int($0.x)),\(Int($0.y))" } + (close ? ["--close"] : [])
        try await app.run(["draw"] + arguments + ["--duration", "0.8"])
        let state = try await app.waitFor("\(expectedStrokes) ink strokes") { state in
            app.value("sketch.strokeCount", in: state) == String(expectedStrokes)
        }
        let bounds = (app.value("sketch.last.bounds", in: state) ?? "").split(separator: ",").compactMap { Double($0) }
        try #require(bounds.count == 4, "No stroke bounds: \(app.value("sketch.last.bounds", in: state) ?? "nil")")
        return bounds
    }
}
