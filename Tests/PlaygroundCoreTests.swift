import Foundation
import Testing

/// Run this suite by itself: all cases use the same foreground simulator app.
@Suite("Playground Core E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundCoreTests {
    @Test("Find a button and tap it by its identifier")
    func findAndTap() async throws {
        let app = try CorePlaygroundSession()
        let initial = try await app.open("slider-value-test", readyID: "slider-value-button")
        let button = try app.element("slider-value-button", in: initial)
        #expect(button.type == "Button")
        _ = try app.frame(of: button)
        #expect(try app.element("slider-value-state", in: initial).value == "Initial")

        try await app.run(["tap", "--id", "slider-value-button"])
        try await app.waitForValue("slider-value-state", equals: "Tapped")
    }

    @Test("Tap a freshly discovered button with legacy coordinates")
    func coordinateTap() async throws {
        let app = try CorePlaygroundSession()
        let initial = try await app.open("slider-value-test", readyID: "slider-value-button")
        let button = try app.element("slider-value-button", in: initial)
        try #require(button.type == "Button" && button.enabled == true)
        let frame = try app.frame(of: button)
        let point = app.point(in: frame, x: 0.5, y: 0.5)
        try #require(try app.element("slider-value-state", in: initial).value == "Initial")
        print("Legacy coordinate tap: raw AX button frame=\(frame), point=(\(point.x), \(point.y))")

        try await app.run(["tap", "-x", String(point.x), "-y", String(point.y)])
        try await app.waitForValue("slider-value-state", equals: "Tapped")
    }

    @Test("Type text into the discovered field and read the app value")
    func typeText() async throws {
        let app = try CorePlaygroundSession()
        let initial = try await app.open("text-input", readyID: "text-input-field")
        #expect(try app.element("text-input-field", in: initial).value == "empty")
        try await app.run(["tap", "--id", "text-input-field", "--element-type", "TextField"])
        _ = try await app.waitFor("active text input") { state in
            UIStateParser.findElement(in: state) { $0.label?.contains("Typing active") == true } != nil
        }

        let text = "AXe core 123"
        try await app.run(["type", text])
        try await app.waitForValue("text-input-field", equals: text)
        try await app.waitForValue("character-count", equals: String(text.count))
        try await app.waitForValue("word-count", equals: "3")
    }

    @Test("Scroll the real list and select a newly visible row")
    func scrollList() async throws {
        let app = try CorePlaygroundSession()
        let initial = try await app.open("long-scroll-test", readyID: "long-scroll-test-scroll-view")
        let applicationFrame = try app.frame(of: initial)
        let listFrame = try app.frame(of: app.element("long-scroll-test-scroll-view", in: initial))
        let initialRows = app.visibleRows(in: initial, listFrame: listFrame)
        let initialLastRow = try #require(initialRows.max(), "The list has no visible rows before scrolling.")
        var revealedRow: Int?

        for _ in 0..<5 {
            try await app.run([
                "gesture", "scroll-up", "--screen-width", String(applicationFrame.width),
                "--screen-height", String(applicationFrame.height), "--duration", "0.5",
                "--post-delay", "0.4",
            ])
            let state = try await app.waitForRest("the list to stop scrolling") { app.rowFrames(in: $0) }
            let rows = app.visibleRows(in: state, listFrame: listFrame)
            if let row = rows.filter({ $0 > initialLastRow }).min() {
                revealedRow = row
                break
            }
        }

        let row = try #require(revealedRow, "Five scroll commands did not reveal a row after row \(initialLastRow).")
        try await app.run(["tap", "--id", "long-scroll-test-row-\(row)"])
        try await app.waitForValue("long-scroll-test-state", equals: "Row \(row)")
    }

    @Test("Swipe records its direction and both requested points")
    func swipe() async throws {
        let app = try CorePlaygroundSession()
        let initial = try await app.open("swipe-test", readyID: "swipe-count")
        #expect(try app.element("swipe-count", in: initial).value == "0")
        let frame = try app.frame(of: initial)
        let start = app.point(in: frame, x: 0.25, y: 0.4)
        let end = app.point(in: frame, x: 0.7, y: 0.4)

        try await app.run([
            "swipe", "--start-x", String(start.x), "--start-y", String(start.y),
            "--end-x", String(end.x), "--end-y", String(end.y), "--duration", "0.4",
        ])
        let result = try await app.waitFor("one completed right swipe at \(start) to \(end)") { state in
            app.value("swipe-count", in: state) == "1"
                && app.label("last-swipe-direction", in: state) == "Direction: Right"
                && app.coordinate("last-swipe-start", in: state, isNear: start)
                && app.coordinate("last-swipe-end", in: state, isNear: end)
        }
        #expect(app.value("swipe-count", in: result) == "1")
    }

    @Test("Drag sends a start, movement and release to the app")
    func drag() async throws {
        let app = try CorePlaygroundSession()
        let initial = try await app.open("touch-control", readyID: "touch-event-count")
        #expect(try app.element("touch-event-count", in: initial).value == "0")
        let frame = try app.frame(of: app.element("touch-control-screen", in: initial))
        let start = app.point(in: frame, x: 0.4, y: 0.55)
        let end = app.point(in: frame, x: 0.4, y: 0.8)

        try await app.run([
            "drag", "--start-x", String(start.x), "--start-y", String(start.y),
            "--end-x", String(end.x), "--end-y", String(end.y),
            "--duration", "0.4", "--steps", "12",
        ])
        _ = try await app.waitFor("drag start \(start), movement and release \(end)") { state in
            let points = app.elements(in: state).compactMap { element -> (x: Int, y: Int)? in
                guard let value = element.value, value.hasPrefix("down:") else { return nil }
                return CoordinateParser.parseNamedCoordinates(from: value)
            }
            let hasStart = points.contains { app.isNear($0, start) }
            let hasMovement = points.contains { abs($0.x - start.x) <= 2 && $0.y > start.y + 5 && $0.y < end.y - 5 }
            return hasStart && hasMovement && app.coordinate("last-touch-up-coordinates", in: state, isNear: end)
        }
    }

    @Test("SwiftUI switch input changes the app state in both directions")
    func swiftUISwitchState() async throws {
        try await switchState(kind: "swiftui")
    }

    @Test("UIKit switch input changes the app state in both directions")
    func uiKitSwitchState() async throws {
        try await switchState(kind: "uikit")
    }

    private func switchState(kind: String) async throws {
        let app = try CorePlaygroundSession()
        let switchID = "\(kind)-weather-alerts-switch"
        let stateID = "\(kind)-weather-alerts-state"
        let initial = try await app.open("switch-test", readyID: switchID)
        let switchType = try app.element(switchID, in: initial).type
        #expect(try app.element(stateID, in: initial).value == "Off")

        for expected in ["On", "Off"] {
            try await app.run(["tap", "--id", switchID, "--element-type", switchType])
            try await app.waitForValue(stateID, equals: expected)
        }
    }

    @Test("Slider reaches two requested values in the actual app")
    func slider() async throws {
        let app = try CorePlaygroundSession()
        let initial = try await app.open("slider-value-test", readyID: "slider-value-slider")
        #expect(try app.element("slider-exact-value-state", in: initial).value == "0.2500")
        // Slider value input follows native feedback; it needs the app's accessibility settled.
        try await TestHelpers.waitForSettledAccessibility(simulatorUDID: app.simulatorUDID,
            description: "screen slider-value-test")

        for percent in [75, 40] {
            try await app.run([
                "slider", "--id", "slider-value-slider", "--value", String(percent), "--element-type", "Slider",
            ])
            _ = try await app.waitFor("slider at \(percent)% in AX and app state") { state in
                guard let exactText = app.value("slider-exact-value-state", in: state),
                      let exact = Double(exactText),
                      let percentText = app.value("slider-percent-state", in: state),
                      let appPercent = Double(percentText),
                      let sliderValue = app.value("slider-value-slider", in: state),
                      let axPercent = app.sliderPercent(sliderValue) else { return false }
                let target = Double(percent)
                return abs(exact * 100 - target) <= 0.07
                    && abs(appPercent - target) <= 0.07 && abs(axPercent - target) <= 0.07
            }
        }
    }
}

struct CorePlaygroundSession {
    private let udid: String
    var simulatorUDID: String { udid }
    private let axePath: String

    init() throws {
        udid = try TestHelpers.requireSimulatorUDID()
        axePath = try TestHelpers.getAxePath()
    }

    @discardableResult
    func run(_ arguments: [String]) async throws -> String {
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        do {
            return try await CommandRunner.run(command, timeout: 30).output
        } catch {
            throw TestError.commandError("\(command)\n\(error)")
        }
    }

    func open(_ screen: String, readyID: String) async throws -> UIElement {
        let arguments = [
            "xcrun", "simctl", "launch", "--terminate-running-process", udid,
            "com.cameroncooke.AxePlayground", "--launch-arg", "screen=\(screen)",
        ]
        _ = try await CommandRunner.run(arguments.map(Self.quote).joined(separator: " "), timeout: 30)
        let ready = try await waitFor("screen \(screen), identifier \(readyID)") { state in
            UIStateParser.findElement(in: state, withIdentifier: readyID) != nil
        }
        guard try await DuoPlaygroundLaunchTarget.prepareIfNeeded() else { return ready }
        return try await waitFor("screen \(screen), identifier \(readyID) after Duo orientation") { state in
            UIStateParser.findElement(in: state, withIdentifier: readyID) != nil
        }
    }

    func state() async throws -> UIElement {
        let output = try await run(["describe-ui"])
        let roots = try UIStateParser.parseDescribeUIRoots(output)
        guard let application = roots.first(where: { $0.type == "Application" && $0.label == "AxePlayground" }) else {
            throw TestError.unexpectedState("No AxePlayground application in describe-ui.\n\(output)")
        }
        return application
    }

    @discardableResult
    func waitFor(_ description: String, matches: (UIElement) -> Bool) async throws -> UIElement {
        let deadline = Date().addingTimeInterval(10)
        var lastObserved = "No app state was read."
        repeat {
            do {
                let current = try await state()
                if matches(current) { return current }
                lastObserved = elements(in: current).map {
                    "\($0.type) id=\($0.identifier ?? "none") label=\($0.label ?? "none") value=\($0.value ?? "none")"
                }.joined(separator: "\n")
            } catch {
                lastObserved = String(describing: error)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw TestError.unexpectedState("Timed out waiting for \(description).\n\(lastObserved)")
    }

    func waitForValue(_ identifier: String, equals expected: String) async throws {
        _ = try await waitFor("\(identifier)=\(expected)") { value(identifier, in: $0) == expected }
    }

    /// Reads until two consecutive reads, 300 ms apart, give the same signature. A scroll view can
    /// decelerate for seconds after a gesture, and a tap on a moving list stops it instead of
    /// selecting a row, so no fixed pause is enough.
    func waitForRest<Signature: Equatable>(_ description: String,
                                           signature: (UIElement) -> Signature) async throws -> UIElement {
        let deadline = Date().addingTimeInterval(10)
        var previous: Signature?
        var lastObserved = "No app state was read."
        repeat {
            do {
                let current = try await state()
                let value = signature(current)
                if let previous, previous == value { return current }
                previous = value
                lastObserved = String(describing: value)
            } catch {
                previous = nil
                lastObserved = String(describing: error)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < deadline
        throw TestError.unexpectedState("Timed out waiting for \(description).\n\(lastObserved)")
    }

    func rowFrames(in state: UIElement) -> [String] {
        elements(in: state).compactMap { element in
            guard let identifier = element.identifier, identifier.hasPrefix("long-scroll-test-row-"),
                  let frame = element.frame else { return nil }
            return "\(identifier)@\(frame.y)"
        }
    }

    func element(_ identifier: String, in state: UIElement) throws -> UIElement {
        guard let element = UIStateParser.findElement(in: state, withIdentifier: identifier) else {
            throw TestError.elementNotFound(identifier)
        }
        return element
    }

    func value(_ identifier: String, in state: UIElement) -> String? {
        UIStateParser.findElement(in: state, withIdentifier: identifier)?.value
    }

    func label(_ identifier: String, in state: UIElement) -> String? {
        UIStateParser.findElement(in: state, withIdentifier: identifier)?.label
    }

    func frame(of element: UIElement) throws -> UIElement.Frame {
        guard let frame = element.frame,
              [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else {
            throw TestError.unexpectedState("No valid frame for \(element.identifier ?? element.type).")
        }
        return frame
    }

    func point(in frame: UIElement.Frame, x: Double, y: Double) -> (x: Int, y: Int) {
        (Int((frame.x + frame.width * x).rounded()), Int((frame.y + frame.height * y).rounded()))
    }

    func elements(in root: UIElement) -> [UIElement] {
        [root] + (root.children ?? []).flatMap { elements(in: $0) }
    }

    func visibleRows(in state: UIElement, listFrame: UIElement.Frame) -> [Int] {
        elements(in: state).compactMap { element in
            guard let identifier = element.identifier, identifier.hasPrefix("long-scroll-test-row-"),
                  let row = Int(identifier.dropFirst("long-scroll-test-row-".count)), let frame = element.frame,
                  frame.height > 0, frame.width > 0,
                  frame.y >= listFrame.y + 4, frame.y + frame.height <= listFrame.y + listFrame.height - 4 else { return nil }
            return row
        }
    }

    func coordinate(_ identifier: String, in state: UIElement, isNear expected: (x: Int, y: Int)) -> Bool {
        guard let element = UIStateParser.findElement(in: state, withIdentifier: identifier),
              let coordinates = CoordinateParser.parseNamedCoordinates(from: element.value ?? "")
                ?? CoordinateParser.parseCoordinates(from: element.label ?? "") else { return false }
        return isNear(coordinates, expected)
    }

    func isNear(_ actual: (x: Int, y: Int), _ expected: (x: Int, y: Int)) -> Bool {
        abs(actual.x - expected.x) <= 2 && abs(actual.y - expected.y) <= 2
    }

    func sliderPercent(_ raw: String) -> Double? {
        guard let number = Double(raw.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return raw.contains("%") || number > 1 ? number : number * 100
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
