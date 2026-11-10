import Foundation
import Testing

let isOrdinaryPlaygroundE2EEnabled = isE2EEnabled && !isDuoPlaygroundE2EEnabled

/// Plain AXe commands, without selected or agent options, on an ordinary iPhone or iPad. Every
/// check reads the effect back from the Playground's own accessibility state.
@Suite("Playground Ordinary Input E2E", .serialized, .enabled(if: isOrdinaryPlaygroundE2EEnabled))
struct PlaygroundOrdinaryInputTests {
    @Test("A label tap and a generated back button tap return to the menu", arguments: ["label", "generated"])
    func backNavigation(kind: String) async throws {
        let app = try OrdinaryPlaygroundSession()
        if kind == "label" {
            _ = try await app.open("tap-test", readyID: "tap-test-screen")
            try await app.run(["tap", "--label", "AXe Playground"])
        } else {
            let state = try await app.open("toolbar-picker-test", readyID: "toolbar-picker-test-body")
            try #require(UIStateParser.findElement(in: state, withIdentifier: "BackButton")?.type == "Button")
            try await app.run(["tap", "--id", "BackButton"])
        }
        try await app.waitForMenu()
    }

    @Test("Coordinate taps land at their points, including one with pre and post delays")
    func coordinateTaps() async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("tap-test", readyID: "tap-test-screen")
        let area = try app.frame("tap-test-screen", in: state)
        let points = [(0.3, 0.5), (0.5, 0.6), (0.7, 0.7)].map { app.core.point(in: area, x: $0.0, y: $0.1) }
        for (index, point) in points.enumerated() {
            try await app.run(["tap", "-x", String(point.x), "-y", String(point.y)])
            try await app.waitForTap(count: index + 1, at: point)
        }
        let delayed = app.core.point(in: area, x: 0.5, y: 0.8)
        let elapsed = try await app.timed(["tap", "-x", String(delayed.x), "-y", String(delayed.y),
            "--pre-delay", "0.5", "--post-delay", "0.5"])
        try #require(elapsed >= 1, "The pre and post delays took \(elapsed) seconds.")
        try await app.waitForTap(count: 4, at: delayed)
    }

    @Test("Taps four points inside the app's edges land at their points")
    func edgeTaps() async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("tap-test", readyID: "tap-test-screen")
        let area = try app.frame("tap-test-screen", in: state)
        let inset = 8.0
        let points = [
            (area.x + inset, area.y + area.height * 0.6), (area.x + area.width - inset, area.y + area.height * 0.6),
            (area.x + area.width * 0.3, area.y + area.height - inset),
            (area.x + area.width - inset, area.y + area.height - inset),
        ].map { (x: Int($0.0.rounded()), y: Int($0.1.rounded())) }
        for (index, point) in points.enumerated() {
            try await app.run(["tap", "-x", String(point.x), "-y", String(point.y)])
            try await app.waitForTap(count: index + 1, at: point)
        }
    }

    @Test("A SwiftUI TabView exposes radio-button tabs and a label tap selects one")
    func tabView() async throws {
        let app = try OrdinaryPlaygroundSession()
        // The screen's identifier covers its text elements, so read the state from labels.
        let state = try await app.open("tab-view-test", readyID: "tab-view-test-screen")
        try #require(UIStateParser.findElementByLabel(in: state, label: "Current Tab: Home") != nil)
        for label in ["Home", "Settings"] {
            let tab = try #require(UIStateParser.findElementByLabel(in: state, label: label), "No \(label) tab.")
            try #require(tab.type == "RadioButton" && tab.frame != nil)
        }
        try await app.run(["tap", "--label", "Settings", "--element-type", "RadioButton"])
        try await app.waitForLabel("Current Tab: Settings")
    }

    @Test("A toolbar segmented picker exposes its segments and a label tap selects one")
    func toolbarPicker() async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("toolbar-picker-test", readyID: "toolbar-picker-test-body")
        try #require(app.core.value("toolbar-picker-test-state", in: state) == "All")
        for label in ["All", "Unread", "Read"] {
            try #require(UIStateParser.findElementByLabel(in: state, label: label)?.type == "RadioButton")
        }
        try await app.run(["tap", "--label", "Unread", "--element-type", "RadioButton"])
        try await app.core.waitForValue("toolbar-picker-test-state", equals: "Unread")
    }

    @Test("Label taps toggle SwiftUI and UIKit switches")
    func switchesByLabel() async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("switch-test", readyID: "uikit-weather-alerts-switch")
        for kind in ["SwiftUI", "UIKit"] {
            try await app.run(["tap", "--label", "\(kind) Weather Alerts"])
            try await app.core.waitForValue("\(kind.lowercased())-weather-alerts-state", equals: "On")
        }
    }

    @Test("A physical coordinate tap at a UIKit switch's centre toggles it")
    func physicalSwitchTap() async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("switch-test", readyID: "uikit-weather-alerts-switch")
        let frame = try app.frame("uikit-weather-alerts-switch", in: state)
        let center = app.core.point(in: frame, x: 0.5, y: 0.5)
        try await app.run(["tap", "-x", String(center.x), "-y", String(center.y), "--tap-style", "physical"])
        try await app.core.waitForValue("uikit-weather-alerts-state", equals: "On")
    }

    @Test("A slider found by its label reaches both ends and two interior values")
    func sliderByLabel() async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("slider-value-test", readyID: "slider-value-slider")
        for percent in [0.0, 1.5, 100.0, 78.25] {
            try await app.run(["slider", "--label", "Slider Value Slider", "--value", String(percent), "--element-type", "Slider"])
            _ = try await app.core.waitFor("slider at \(percent)% in AX and app state") { state in
                guard let exact = app.core.value("slider-exact-value-state", in: state).flatMap(Double.init),
                      let shown = app.core.value("slider-percent-state", in: state).flatMap(Double.init),
                      let axText = app.core.value("slider-value-slider", in: state),
                      let ax = app.core.sliderPercent(axText) else { return false }
                return abs(exact * 100 - percent) <= 0.07 && abs(shown - percent) <= 0.07 && abs(ax - percent) <= 0.07
            }
        }
    }

    @Test("describe-ui --point returns the element at that point with its tree frame")
    func describePoint() async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("tap-test", readyID: "tap-test-screen")
        let button = try #require(UIStateParser.findElement(in: state, withIdentifier: "BackButton"))
        let frame = try app.core.frame(of: button)
        let output = try await app.run(["describe-ui", "--point", "\(frame.x + frame.width / 2),\(frame.y + frame.height / 2)"])
        let roots = try UIStateParser.parseDescribeUIRoots(output)
        let element = try #require(roots.first)
        try #require(roots.count == 1 && element.identifier == "BackButton" && element.type == "Button")
        try #require(element.label == "AXe Playground" && element.roleDescription == "back button" && element.enabled == true)
        let pointFrame = try #require(element.frame)
        try #require(pointFrame.x == frame.x && pointFrame.y == frame.y
            && pointFrame.width == frame.width && pointFrame.height == frame.height)
        try #require(element.children?.isEmpty == true)
    }

    @Test("Swipes report their direction, both points and their duration", arguments: ["Right", "Left", "Down", "Up"])
    func swipe(direction: String) async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("swipe-test", readyID: "swipe-count")
        let frame = try app.core.frame(of: state)
        let (from, to): ((Double, Double), (Double, Double)) = switch direction {
        case "Right": ((0.25, 0.55), (0.75, 0.55))
        case "Left": ((0.75, 0.55), (0.25, 0.55))
        case "Down": ((0.5, 0.4), (0.5, 0.7))
        default: ((0.5, 0.7), (0.5, 0.4))
        }
        let start = app.core.point(in: frame, x: from.0, y: from.1), end = app.core.point(in: frame, x: to.0, y: to.1)
        let elapsed = try await app.timed(["swipe", "--start-x", String(start.x), "--start-y", String(start.y),
            "--end-x", String(end.x), "--end-y", String(end.y), "--duration", "0.8"])
        try #require(elapsed >= 0.8, "The 0.8-second swipe took \(elapsed) seconds.")
        _ = try await app.core.waitFor("one \(direction) swipe from \(start) to \(end)") { state in
            app.core.value("swipe-count", in: state) == "1"
                && app.core.label("last-swipe-direction", in: state) == "Direction: \(direction)"
                && app.core.coordinate("last-swipe-start", in: state, isNear: start)
                && app.core.coordinate("last-swipe-end", in: state, isNear: end)
        }
    }

    @Test("Scroll presets are recognised in their direction, with duration and delays",
          arguments: ["scroll-up", "scroll-down", "scroll-left", "scroll-right"])
    func scrollPreset(name: String) async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("gesture-presets", readyID: "gesture-presets-screen")
        var arguments = ["gesture", name]
        var minimum = 0.0
        if name == "scroll-up" { arguments += ["--duration", "1.5"]; minimum = 1.5 }
        if name == "scroll-down" { arguments += ["--pre-delay", "0.5", "--post-delay", "0.5"]; minimum = 1 }
        let elapsed = try await app.timed(arguments)
        try #require(elapsed >= minimum, "\(arguments) took \(elapsed) seconds.")
        // The screen's identifier covers its text elements, so read the gesture from labels.
        _ = try await app.core.waitFor("one \(name) gesture") { state in
            UIStateParser.findElementByLabel(in: state, label: "Latest Gesture: \(name)") != nil
                && UIStateParser.findElementByLabel(in: state, label: "Detected: 1") != nil
        }
    }

    @Test("Touch down, a moved down and an up report the final point")
    func touchMove() async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("touch-control", readyID: "touch-event-count")
        let frame = try app.frame("touch-control-screen", in: state)
        let start = app.core.point(in: frame, x: 0.3, y: 0.55), end = app.core.point(in: frame, x: 0.7, y: 0.75)
        try await app.run(["touch", "-x", String(start.x), "-y", String(start.y), "--down"])
        try await app.waitForCoordinate("last-touch-down-coordinates", near: start)
        try await app.run(["touch", "-x", String(end.x), "-y", String(end.y), "--down"])
        try await app.waitForCoordinate("last-touch-down-coordinates", near: end)
        try await app.run(["touch", "-x", String(end.x), "-y", String(end.y), "--up"])
        try await app.waitForCoordinate("last-touch-up-coordinates", near: end)
    }

    @Test("A held touch with --delay is a long press at its point")
    func touchLongPress() async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("touch-control", readyID: "touch-event-count")
        let frame = try app.frame("touch-control-screen", in: state)
        let point = app.core.point(in: frame, x: 0.55, y: 0.6)
        let elapsed = try await app.timed(["touch", "-x", String(point.x), "-y", String(point.y), "--down", "--up", "--delay", "1"])
        try #require(elapsed >= 1, "The 1-second hold took \(elapsed) seconds.")
        try await app.core.waitForValue("long-press-count", equals: "1")
        try await app.waitForCoordinate("last-long-press-coordinates", near: point)
        try await app.waitForCoordinate("last-touch-down-coordinates", near: point)
        try await app.waitForCoordinate("last-touch-up-coordinates", near: point)
    }

    @Test("An alert's destructive button is found and tapped by its label")
    func alert() async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("alert-test", readyID: "alert-test-show-alert")
        try await app.run(["tap", "--id", "alert-test-show-alert"])
        let state = try await app.waitForPresented { UIStateParser.findElementByLabel(in: $0, label: "Delete Draft?") != nil }
        try #require(UIStateParser.findElementByLabel(in: state, label: "Delete")?.type == "Button")
        try await app.run(["tap", "--label", "Delete", "--element-type", "Button"])
        try await app.core.waitForValue("alert-test-state", equals: "Deleted")
    }

    @Test("A sheet's buttons run its action and close it")
    func sheet() async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("sheet-test", readyID: "sheet-test-open-sheet")
        try await app.run(["tap", "--id", "sheet-test-open-sheet"])
        _ = try await app.waitForPresented { UIStateParser.findElementByLabel(in: $0, label: "Run Sheet Action") != nil }
        try await app.run(["tap", "--label", "Run Sheet Action", "--element-type", "Button"])
        try await app.core.waitForValue("sheet-test-state", equals: "Sheet action tapped")
        try await app.run(["tap", "--label", "Close Sheet", "--element-type", "Button"])
        _ = try await app.core.waitFor("the sheet to close") { UIStateParser.findElementByLabel(in: $0, label: "Run Sheet Action") == nil }
    }

    @Test("A long press opens a context menu and its action is tapped by label")
    func contextMenu() async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("context-menu-test", readyID: "context-menu-test-target")
        let point = app.core.point(in: try app.frame("context-menu-test-target", in: state), x: 0.5, y: 0.5)
        try await app.run(["touch", "-x", String(point.x), "-y", String(point.y), "--down", "--up", "--delay", "1"])
        _ = try await app.waitForPresented { UIStateParser.findElementByLabel(in: $0, label: "Favorite") != nil }
        try await app.run(["tap", "--label", "Favorite"])
        try await app.core.waitForValue("context-menu-test-state", equals: "Favorited")
    }

    @Test("A modal flow's navigation link and nested button are tapped by identifier")
    func modalNavigation() async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("modal-navigation-test", readyID: "modal-navigation-test-open")
        try await app.run(["tap", "--id", "modal-navigation-test-open"])
        _ = try await app.waitForPresented { UIStateParser.findElement(in: $0, withIdentifier: "modal-navigation-test-detail-link") != nil }
        try await app.run(["tap", "--id", "modal-navigation-test-detail-link"])
        _ = try await app.waitForPresented { UIStateParser.findElement(in: $0, withIdentifier: "modal-navigation-test-complete") != nil }
        try await app.run(["tap", "--id", "modal-navigation-test-complete"])
        try await app.core.waitForValue("modal-navigation-test-state", equals: "Completed")
    }
}

/// Batches of plain steps: sources, failure handling, the accessibility cache and waits.
@Suite("Playground Ordinary Batch E2E", .serialized, .enabled(if: isOrdinaryPlaygroundE2EEnabled))
struct PlaygroundOrdinaryBatchTests {
    @Test("Steps from --step, --file and --stdin run in order", arguments: ["step", "file", "stdin"])
    func sources(source: String) async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("tap-test", readyID: "tap-test-screen")
        let area = try app.frame("tap-test-screen", in: state)
        let first = app.core.point(in: area, x: 0.35, y: 0.55), second = app.core.point(in: area, x: 0.65, y: 0.7)
        let steps = ["tap -x \(first.x) -y \(first.y)", "sleep 0.2", "tap -x \(second.x) -y \(second.y)"]
        switch source {
        case "step":
            try await app.run(["batch"] + steps.flatMap { ["--step", $0] })
        case "file":
            let file = try app.artifact("batch-steps.txt")
            try steps.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            try await app.run(["batch", "--file", file.path])
        default:
            let result = try await app.attempt(["batch", "--stdin"], input: steps.joined(separator: "\n") + "\n")
            try #require(result.exitCode == 0, "batch --stdin failed: \(result.output)")
        }
        try await app.waitForTap(count: 2, at: second)
    }

    @Test("--continue-on-error runs the later steps and reports the failed one")
    func continueOnError() async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("batch-test", readyID: "batch-test-screen")
        let result = try await app.attempt(["batch", "--continue-on-error", "--wait-timeout", "2", "--poll-interval", "0.1",
            "--ax-cache", "perStep", "--step", "unknown-command", "--step", "tap --label 'Trigger State Change'",
            "--step", "tap --label 'State Target'"])
        try #require(result.exitCode != 0 && result.output.contains("Batch completed with 1 failure(s):")
            && result.output.contains("unknown-command"), "Unexpected batch result: \(result.output)")
        try await app.waitForLabel("Current State: State target tapped")
    }

    @Test("A per-batch cache misses an element that appears mid-batch; a per-step cache finds it",
          arguments: ["perBatch", "perStep"])
    func cache(mode: String) async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("batch-test", readyID: "batch-test-screen")
        let result = try await app.attempt(["batch", "--ax-cache", mode, "--step", "tap --label 'Trigger State Change'",
            "--step", "tap --label 'State Target'"])
        if mode == "perBatch" {
            try #require(result.exitCode != 0 && result.output.contains("Step 2 failed:"), "Unexpected batch result: \(result.output)")
            let state = try await app.core.state()
            try #require(UIStateParser.findElementByLabel(in: state, label: "Current State: State target tapped") == nil)
        } else {
            try #require(result.exitCode == 0, "batch failed: \(result.output)")
            try await app.waitForLabel("Current State: State target tapped")
        }
    }

    @Test("--wait-timeout waits for a delayed element; without it the step fails", arguments: [5, 0])
    func waitTimeout(seconds: Int) async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("batch-test", readyID: "batch-test-screen")
        let result = try await app.attempt(["batch", "--wait-timeout", String(seconds), "--poll-interval", "0.1",
            "--step", "tap --label 'Trigger Delayed Element'", "--step", "tap --label 'Delayed Target'"])
        if seconds == 0 {
            try #require(result.exitCode != 0 && result.output.contains("Step 2 failed:"), "Unexpected batch result: \(result.output)")
        } else {
            try #require(result.exitCode == 0, "batch failed: \(result.output)")
            try await app.waitForLabel("Current State: Delayed target tapped")
        }
    }

    @Test("A login flow with a loading transition completes only with a wait", arguments: [true, false])
    func loginFlow(wait: Bool) async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("batch-login-flow", readyID: "batch-login-screen")
        let steps = ["type 'cam@example.com'", "tap --label Continue", "type 'supersecret'", "tap --label 'Sign In'",
                     "tap --label 'Open Settings'"] + (wait ? ["tap --label 'Toggle Preference'"] : [])
        let result = try await app.attempt(["batch", "--ax-cache", "perStep", "--wait-timeout", wait ? "6" : "0",
            "--poll-interval", "0.1"] + steps.flatMap { ["--step", $0] })
        if wait {
            try #require(result.exitCode == 0, "batch failed: \(result.output)")
            try await app.waitForLabel("Current Screen: Settings")
            try await app.waitForLabel("Settings Opened")
        } else {
            try #require(result.exitCode != 0 && result.output.contains("Step 5 failed:"), "Unexpected batch result: \(result.output)")
        }
    }

    @Test("Label steps toggle both switches; a step's tap style overrides the batch's")
    func switchesAndTapStyle() async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("switch-test", readyID: "uikit-weather-alerts-switch")
        try await app.run(["batch", "--ax-cache", "perStep", "--step", "tap --label 'SwiftUI Weather Alerts'",
            "--step", "tap --label 'UIKit Weather Alerts'"])
        try await app.core.waitForValue("swiftui-weather-alerts-state", equals: "On")
        try await app.core.waitForValue("uikit-weather-alerts-state", equals: "On")
        try await app.run(["batch", "--tap-style", "simulator", "--step", "tap --label 'SwiftUI Weather Alerts' --tap-style automatic"])
        try await app.core.waitForValue("swiftui-weather-alerts-state", equals: "Off")
    }
}

struct OrdinaryPlaygroundSession {
    let core: CorePlaygroundSession
    let udid: String
    let axe: String

    init() throws {
        core = try CorePlaygroundSession()
        udid = core.simulatorUDID
        axe = try TestHelpers.getAxePath()
    }

    /// Opens a fresh screen and waits until its accessibility tree stops changing: on iOS 27.2 a new
    /// app handles touches late for a few seconds after the first read.
    func open(_ screen: String, readyID: String) async throws -> UIElement {
        _ = try await core.open(screen, readyID: readyID)
        try await TestHelpers.waitForSettledAccessibility(simulatorUDID: udid, description: "screen \(screen)")
        return try await core.state()
    }

    @discardableResult
    func run(_ arguments: [String]) async throws -> String { try await core.run(arguments) }

    /// Runs a command that may fail, optionally with text on standard input.
    func attempt(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 60) async throws -> CommandOutput {
        var command = ([axe] + arguments + ["--udid", udid]).map(shellQuote).joined(separator: " ")
        if let input { command = "printf '%s' " + shellQuote(input) + " | " + command }
        let result = try await CommandRunner.run(command, allowFailure: true, timeout: timeout)
        return CommandOutput(output: result.output, exitCode: result.exitCode)
    }

    func timed(_ arguments: [String]) async throws -> TimeInterval {
        let started = Date()
        try await run(arguments)
        return Date().timeIntervalSince(started)
    }

    func frame(_ identifier: String, in state: UIElement) throws -> UIElement.Frame {
        try core.frame(of: core.element(identifier, in: state))
    }

    func artifact(_ name: String) throws -> URL {
        let root = ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("ordinary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    func waitForLabel(_ label: String) async throws {
        _ = try await core.waitFor("label '\(label)'") { UIStateParser.findElementByLabel(in: $0, label: label) != nil }
    }

    func waitForMenu() async throws {
        _ = try await core.waitFor("the Playground menu") { state in
            UIStateParser.findElementContainingLabel(in: state, containing: "Touch & Gestures") != nil
                && UIStateParser.findElement(in: state, withIdentifier: "tap-test-screen") == nil
                && UIStateParser.findElement(in: state, withIdentifier: "toolbar-picker-test-body") == nil
        }
    }

    func waitForTap(count: Int, at point: (x: Int, y: Int)) async throws {
        // The Tap Test screen's identifier covers its text elements, so read its labels.
        _ = try await core.waitFor("tap \(count) at \(point)") { state in
            guard UIStateParser.findElementByLabel(in: state, label: "Tap Count: \(count)") != nil,
                  let location = UIStateParser.findElementContainingLabel(in: state, containing: "Tap Location: ")?.label,
                  let tapped = CoordinateParser.parseCoordinates(from: location) else { return false }
            return core.isNear(tapped, point)
        }
    }

    func waitForCoordinate(_ identifier: String, near point: (x: Int, y: Int)) async throws {
        _ = try await core.waitFor("\(identifier) near \(point)") { core.coordinate(identifier, in: $0, isNear: point) }
    }

    /// A presented alert, sheet or menu is in the tree at its final frame while it still animates
    /// in, and a tap then is ignored. Wait for the element, then for two identical screenshots.
    func waitForPresented(_ matches: (UIElement) -> Bool) async throws -> UIElement {
        let state = try await core.waitFor("the presented content", matches: matches)
        let first = try artifact("still-a.png"), second = try artifact("still-b.png")
        var previous: Data?
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let url = previous == nil ? first : second
            try? FileManager.default.removeItem(at: url)
            try await run(["screenshot", "--output", url.path])
            let current = try Data(contentsOf: url)
            if let previous, previous == current { return try await core.state() }
            previous = current
            try await Task.sleep(nanoseconds: 150_000_000)
        } while Date() < deadline
        throw TestError.unexpectedState("The screen did not stop changing after presenting: \(state.type)")
    }
}
