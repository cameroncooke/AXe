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

    /// The one case that looks like a drawing: a shaded 3D car. A small model is lit and projected into
    /// flat faces, each filled in one of five tones of red, with watercolour washes for the wall and the
    /// cast shadow, crayon for the road, fountain-pen lines and pencil hatching. The picture is
    /// scripts/fixtures/sketch-car.json and scripts/sketch_picture.py plays it through the axe CLI: it
    /// picks every tool and line weight in the tool picker, scrolling its strip to the tools that start
    /// out of view, and every colour from the screen's swatches.
    @Test("A shaded 3D car is painted with five tools")
    func paintsAPicture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let player = try #require(environment["AXE_SKETCH_PLAYER_PATH"], "Set the picture player through the Playground matrix.")
        let picture = try #require(environment["AXE_SKETCH_PICTURE_PATH"], "Set the picture through the Playground matrix.")
        let sketch = try await SketchCanvas.open()
        let folder = environment["AXE_E2E_ARTIFACT_DIR"] ?? NSTemporaryDirectory()
        let output = folder + "/sketch-car-\(UUID().uuidString.prefix(8)).png"
        // "current" paints on the screen that is already open, so the Duo keeps the layout this suite set up.
        let command = ["python3", player, try TestHelpers.getAxePath(), sketch.app.simulatorUDID, "current", picture, output]
            .map(shellQuote).joined(separator: " ")
        let result = try await CommandRunner.run(command, timeout: 900)
        let summary = try #require(result.output.split(separator: "\n").last { $0.hasPrefix("PAINTED ") },
                                   "The player printed no result: \(result.output.suffix(600))")
        print(summary)
        var fields: [String: String] = [:]
        for part in summary.split(separator: " ").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        // The player checked every stroke and ink against the app as it finished. Read the app again here.
        let state = try await sketch.app.state()
        let strokes = try #require(fields["strokes"].flatMap { Int($0) })
        #expect(strokes >= 120 && sketch.app.value("sketch.strokeCount", in: state) == String(strokes))
        #expect(fields["tools"] == "crayon,fountainpen,monoline,pencil,watercolor")
        let inks = (sketch.app.value("sketch.inks", in: state) ?? "").components(separatedBy: ", ")
        #expect(inks.count >= 20 && inks.contains("monoline #B01717") && inks.contains("watercolor #1B1D20")
            && inks.contains("crayon #555B62"), "inks: \(inks)")
        #expect(FileManager.default.fileExists(atPath: output))
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
