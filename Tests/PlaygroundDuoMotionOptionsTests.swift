import Foundation
import Testing

@Suite("Playground Duo Motion Options", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoMotionOptionsTests {
    @Test("One-point swipe remains finite and releases at its exact endpoint", arguments: [false, true])
    func onePoint(selected: Bool) async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let start = (frame.x + frame.width / 2, frame.y + frame.height / 2)
            let end = (start.0 + 1, start.1)
            let before = try app.documents.read()
            let arguments = ["swipe", "--start-x", String(start.0), "--start-y", String(start.1), "--end-x", String(end.0), "--end-y", String(end.1), "--duration", "0.3", "--delta", "50"]
            if selected { _ = try await app.selected(arguments) } else { _ = try await app.app.run(arguments) }
            let after = try await app.documents.waitFor("one-point physical movement and release") { $0.activeWindowTouches == 0 && $0.count("touchMoved") > before.count("touchMoved") }
            try app.requireContact(after, since: before, start: start, end: end)
        }
    }

    @Test("Explicit movement timing and spacing preserve physical endpoints", arguments: ["swipe", "drag"], [false, true])
    func options(verb: String, selected: Bool) async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let start = (frame.x + frame.width / 2 - 80, frame.y + frame.height / 2)
            let end = (start.0 + 160, start.1)
            let before = try app.documents.read()
            var args = [verb, "--start-x", String(start.0), "--start-y", String(start.1), "--end-x", String(end.0), "--end-y", String(end.1),
                "--duration", "1", "--pre-delay", "0.2", "--post-delay", "0.3"]
            args += verb == "drag" ? ["--steps", "8"] : ["--delta", "20"]
            let started = ProcessInfo.processInfo.systemUptime
            if selected { _ = try await app.selected(args) } else { _ = try await app.app.run(args) }
            try #require(ProcessInfo.processInfo.systemUptime - started >= 1.5)
            let after = try await app.documents.waitFor("one completed timed pan") {
                $0.count("pan") == before.count("pan") + 1 && $0.activeWindowTouches == 0
                    && $0.recognizerTrace.last(where: { $0.name == "pan" })?.state == 3
            }
            try app.requireContact(after, since: before, start: start, end: end)
            let trace = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
            let first = try #require(trace.first)
            let last = try #require(trace.last)
            try #require(last.timestamp - first.timestamp >= 0.9)
            try #require(after.panX > 120 && abs(after.panY) <= 2)
            try controlsRecognizer(after, before: before, name: "pan")
            if verb == "swipe" && selected { try await tabletopSwipe(app) }
        }
    }
    private func tabletopSwipe(_ app: PlaygroundControlsSession) async throws {
        let device = try DuoPlaygroundSession()
        let half = try await device.setPose(.tabletop, boot: app.catalogue.bootIdentity)
        let rotation = try half.activePanel.rotationDegrees()
        try #require(rotation == 90 && half.activePanel.identity == app.catalogue.activePanel.identity)
        let current = PlaygroundControlsSession(copying: app, catalogue: half)
        let frame = try await current.frame("feature.pad")
        let start = (frame.x + frame.width / 2 - 40, frame.y + frame.height / 2)
        let end = (start.0 + 80, start.1)
        let before = try current.documents.read()
        let receipt = try await current.selected(["swipe", "--start-x", String(start.0), "--start-y", String(start.1),
            "--end-x", String(end.0), "--end-y", String(end.1), "--duration", "0.4", "--delta", "10"])
        try #require(receipt.enqueuedEventCount == 10 && receipt.outcome == "enqueuedAndDrained")
        let after = try await current.documents.waitFor("the prior tabletop 80-point swipe and release") {
            $0.count("pan") == before.count("pan") + 1 && $0.activeWindowTouches == 0
                && $0.recognizerTrace.last(where: { $0.name == "pan" })?.state == 3
        }
        try current.requireContact(after, since: before, start: start, end: end)
        try controlsRecognizer(after, before: before, name: "pan")
        try #require(after.panX > 20 && abs(after.panY) <= 0.5)
        try #require(after.text == before.text && after.slider == before.slider && after.switchOn == before.switchOn)
        try #require(after.listOffsetY == before.listOffsetY && after.pageOffsetY == before.pageOffsetY)
        try current.preserveState("tabletop80-point-swipe")
        _ = try await device.setPose(.open, boot: app.catalogue.bootIdentity)
    }

}

@Suite("Playground Duo Edge Navigation", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoNavigationTests {
    @Test("Default outer edge gesture returns from the visible controls page")
    func outerDefault() async throws { try await navigate(position: .outer0, explicitPath: false, inset: nil) }
    @Test("Explicit inner edge inset returns from the visible controls page")
    func innerInset() async throws { try await navigate(position: .inner90, explicitPath: false, inset: 1) }
    @Test("Explicit inner x1 path returns from the visible controls page")
    func innerCoordinates() async throws { try await navigate(position: .inner90, explicitPath: true, inset: nil) }

    private func navigate(position: DuoControlsPosition, explicitPath: Bool, inset: Int?) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            let panel = app.catalogue.activePanel
            let arguments: [String]
            if explicitPath {
                let logicalWidth = panel.nativePixelHeight / Double(panel.pointScale)
                let logicalHeight = panel.nativePixelWidth / Double(panel.pointScale)
                arguments = ["swipe", "--start-x", "1", "--start-y", String(logicalHeight / 2),
                    "--end-x", String(logicalWidth - 20), "--end-y", String(logicalHeight / 2), "--duration", "0.3", "--delta", "50"]
            } else {
                arguments = ["gesture", "swipe-from-left-edge"] + (inset.map { ["--edge-inset", String($0), "--duration", "1"] } ?? [])
            }
            _ = try await app.selected(arguments)
            _ = try await app.app.waitFor("real navigation returned to Playground menu") { state in
                UIStateParser.findElement(in: state, withIdentifier: "feature.screen") == nil
                    && UIStateParser.findElementByLabel(in: state, label: "AXe Playground") != nil
            }
            let final = try app.documents.read()
            try final.requireClear()
        }
    }
}
