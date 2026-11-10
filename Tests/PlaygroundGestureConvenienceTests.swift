import Foundation
import Testing

/// Long press, double tap and two-finger tap on `tap`; the drag hold; scroll distance; scrolling until an
/// element is on screen; and the Control Centre preset. The Drawing screen records every contact as a
/// stroke with its duration, length and number of fingers, so each gesture is read back from the app.
/// The matrix runs these on the iPhone, the iPad and the Duo.
@Suite("Playground Gesture Conveniences E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundGestureConvenienceTests {
    @Test("tap --hold at a point is one long contact")
    func longPressAtAPoint() async throws {
        let pad = try await StrokePad.open()
        let centre = pad.app.point(in: pad.canvas, x: 0.5, y: 0.5)
        try await pad.app.run(["tap", "-x", String(centre.x), "-y", String(centre.y), "--hold", "1.2"])
        let stroke = try await pad.stroke(1)
        #expect(stroke.touches == 1 && stroke.length == 0 && (1.0...1.8).contains(stroke.duration), "\(stroke)")
    }

    @Test("tap --hold on an element chosen by --id presses its centre")
    func longPressOnAnElement() async throws {
        let pad = try await StrokePad.open()
        try await pad.app.run(["tap", "--id", "drawing.canvas", "--hold", "0.8"])
        let stroke = try await pad.stroke(1)
        #expect(stroke.touches == 1 && (0.6...1.4).contains(stroke.duration), "\(stroke)")
        #expect(abs(stroke.start.x - (pad.canvas.x + pad.canvas.width / 2)) <= 2
            && abs(stroke.start.y - (pad.canvas.y + pad.canvas.height / 2)) <= 2, "\(stroke) in \(pad.canvas)")
    }

    @Test("tap --count 2 is two short contacts")
    func doubleTap() async throws {
        let pad = try await StrokePad.open()
        try await pad.app.run(["tap", "--id", "drawing.canvas", "--count", "2"])
        let stroke = try await pad.stroke(2)
        #expect(stroke.touches == 1 && stroke.duration < 0.5, "\(stroke)")
    }

    @Test("tap --touches 2 puts two fingers down, and --hold keeps them there")
    func twoFingerTap() async throws {
        let pad = try await StrokePad.open()
        try await pad.app.run(["tap", "--id", "drawing.canvas", "--touches", "2"])
        #expect(try await pad.stroke(1).touches == 2)
        try await pad.app.run(["tap", "--id", "drawing.canvas", "--touches", "2", "--hold", "0.7"])
        let held = try await pad.stroke(2)
        #expect(held.touches == 2 && held.duration >= 0.5, "\(held)")
    }

    @Test("drag --hold rests on the start before it moves")
    func dragHold() async throws {
        let pad = try await StrokePad.open()
        let start = pad.app.point(in: pad.canvas, x: 0.5, y: 0.3), end = pad.app.point(in: pad.canvas, x: 0.5, y: 0.6)
        let line = ["--start-x", String(start.x), "--start-y", String(start.y), "--end-x", String(end.x), "--end-y", String(end.y),
                    "--duration", "0.5"]
        try await pad.app.run(["drag"] + line)
        let plain = try await pad.stroke(1)
        try await pad.app.run(["drag"] + line + ["--hold", "0.7"])
        let held = try await pad.stroke(2)
        print("Drag \(plain.duration) s, with --hold 0.7 \(held.duration) s")
        #expect(abs(held.length - Double(end.y - start.y)) <= 6 && held.touches == 1, "\(held)")
        // The default rest is 0.05 s, so the hold adds about 0.65 s.
        #expect((0.45...1.1).contains(held.duration - plain.duration), "plain \(plain.duration), held \(held.duration)")
    }

    @Test("A scroll preset's --distance is a fraction of the screen")
    func scrollDistance() async throws {
        let pad = try await StrokePad.open()
        try await pad.app.run(["gesture", "scroll-down", "--distance", "0.4"])
        let long = try await pad.stroke(1)
        #expect(abs(long.length - pad.screen.height * 0.4) <= 12, "\(long) on \(pad.screen)")
        try await pad.app.run(["gesture", "scroll-down"])
        #expect(abs(try await pad.stroke(2).length - 200) <= 8)
    }

    @Test("A scroll preset repeats until the element is on screen")
    func scrollUntil() async throws {
        let app = try CorePlaygroundSession()
        let initial = try await app.open("long-scroll-test", readyID: "long-scroll-test-scroll-view")
        let screen = try app.frame(of: initial)
        let list = try app.frame(of: app.element("long-scroll-test-scroll-view", in: initial))
        let last = try #require(app.visibleRows(in: initial, listFrame: list).max())
        let target = "long-scroll-test-row-\(last + 12)"
        let found = try await app.run(["gesture", "scroll-up", "--distance", "0.4", "--until-id", target, "--max-swipes", "20"])
        #expect(found.contains("is on screen after") && !found.contains("after 0 scrolls"), "\(found)")
        let state = try await app.waitForRest("the list to stop scrolling") { app.rowFrames(in: $0) }
        let frame = try app.frame(of: app.element(target, in: state))
        #expect(frame.y + frame.height / 2 >= 0 && frame.y + frame.height / 2 <= screen.height, "\(frame) on \(screen)")
        // Already there: it reads once and sends nothing.
        #expect(try await app.run(["gesture", "scroll-up", "--until-id", target]).contains("after 0 scrolls"))
        do {
            try await app.run(["gesture", "scroll-down", "--until-id", "no-such-element", "--max-swipes", "2"])
            Issue.record("A missing element was reported as found")
        } catch {
            #expect("\(error)".contains("not on screen after 2 scrolls"), "\(error)")
        }
    }

    @Test("swipe-from-top-right-corner opens Control Centre")
    func controlCentre() async throws {
        let app = try CorePlaygroundSession()
        _ = try await app.open("tap-test", readyID: "tap-test-title")
        try await app.run(["gesture", "swipe-from-top-right-corner"])
        // Control Centre replaces the app in the tree. Its header has a Power button.
        var tree = ""
        for _ in 0..<10 {
            tree = (try? await app.run(["describe-ui"])) ?? ""
            if tree.contains("\"Power\"") { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await app.run(["button", "home"])
        #expect(tree.contains("\"Power\"") && !tree.contains("tap-test-title"), "Control Centre did not open")
    }
}

/// The Drawing screen as a recorder of contacts.
struct StrokePad {
    struct Stroke: CustomStringConvertible {
        let duration: Double, length: Double, touches: Int
        let start: (x: Double, y: Double)
        var description: String { "duration \(duration), length \(length), touches \(touches), start \(start)" }
    }

    let app: CorePlaygroundSession
    let canvas: UIElement.Frame
    let screen: UIElement.Frame

    static func open() async throws -> StrokePad {
        let app = try CorePlaygroundSession()
        let state = try await app.open("drawing", readyID: "drawing.canvas")
        try #require(app.value("drawing.strokeCount", in: state) == "0")
        return StrokePad(app: app, canvas: try app.frame(of: app.element("drawing.canvas", in: state)),
                         screen: try app.frame(of: state))
    }

    /// Waits until the app has recorded `count` completed strokes and returns the last.
    func stroke(_ count: Int) async throws -> Stroke {
        let state = try await app.waitFor("\(count) completed strokes") { state in
            app.value("drawing.strokeCount", in: state) == String(count) && app.value("drawing.active", in: state) == "false"
        }
        let number = { (id: String) in app.value("drawing.last." + id, in: state).flatMap(Double.init) }
        let start = (app.value("drawing.last.start", in: state) ?? "").split(separator: ",").compactMap { Double($0) }
        try #require(start.count == 2)
        return Stroke(duration: try #require(number("duration")), length: try #require(number("length")),
                      touches: Int(try #require(number("maxTouches"))), start: (start[0], start[1]))
    }
}
