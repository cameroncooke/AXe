import Foundation
import Testing

@Suite("Playground Duo Manual Boundary Regression", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoManualBoundaryTests {
    @Test("A raw retained contact releases while idle on fold and turn", arguments: [PlaygroundDuoChange.fold, .rotate])
    func rawIdle(change: PlaygroundDuoChange) async throws {
        let app = try await prepareDuoControls(.inner90)
        let frame = try await app.frame("feature.pad")
        let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
        let before = try app.documents.read()
        _ = try await app.app.run(["touch", "-x", String(point.0), "-y", String(point.1), "--down"])
        _ = try await app.documents.waitFor("one actual retained raw contact") { $0.activeWindowTouches == 1 }
        _ = try await changeDuoControls(app, change: change)
        let released = try await app.documents.waitFor("automatic raw release before another touch command") { $0.activeWindowTouches == 0 }
        try requireReleasedContacts(released, before: before, count: 1)
        // An unmatched raw UP is a no-owned-contact operation. It must not touch the new screen.
        _ = try await app.app.run(["touch", "-x", String(point.0), "-y", String(point.1), "--up"])
        let after = try app.documents.read()
        try #require(after.windowTouchTrace.count == released.windowTouchTrace.count && after.activeWindowTouches == 0)
        try await app.freshTap()
    }

    @Test("A selected request cannot release a raw retained owner")
    func wrongOriginCannotRelease() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
            let before = try app.documents.read()
            _ = try await app.app.run(["touch", "-x", String(point.0), "-y", String(point.1), "--down"])
            let held = try await app.documents.waitFor("one held raw owner") { $0.activeWindowTouches == 1 }
            let wrong = try await app.selected(["touch", "-x", String(point.0), "-y", String(point.1), "--up", "--contact-token", UUID().uuidString], allowFailure: true)
            try #require(wrong.error != nil && wrong.enqueuedEventCount == 0 && wrong.cleanup == "notNeeded" && wrong.quarantine == nil)
            let unchanged = try app.documents.read()
            try #require(unchanged.activeWindowTouches == 1 && unchanged.windowTouchTrace.count == held.windowTouchTrace.count)
            _ = try await app.app.run(["touch", "-x", String(point.0), "-y", String(point.1), "--up"])
            let released = try await app.documents.waitFor("original raw owner released normally") { $0.activeWindowTouches == 0 }
            try app.requireContact(released, since: before, start: point, end: point)
            try await app.freshTap()
        }
    }

    @Test("The public retained single outer0to90 regression releases before old token input")
    func outerRetainedRotation() async throws {
        let app = try await prepareDuoControls(.outer0)
        let frame = try await app.frame("feature.pad")
        let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
        let before = try app.documents.read()
        let begin = try await app.selected(["touch", "-x", String(point.0), "-y", String(point.1), "--down"])
        let token = try #require(begin.token)
        _ = try await app.documents.waitFor("one actual retained outer contact") { $0.activeWindowTouches == 1 }
        let turned = try await changeDuoControls(app, change: .rotate)
        let rotation = try turned.activePanel.rotationDegrees()
        try #require(rotation == 90 && turned.activePanel.identity == app.catalogue.activePanel.identity)
        let released = try await app.documents.waitFor("outer retained contact released while idle") { $0.activeWindowTouches == 0 }
        try requireReleasedContacts(released, before: before, count: 1)
        let old = try await app.selected(["touch", "-x", String(point.0), "-y", String(point.1), "--down", "--contact-token", token.uuidString], allowFailure: true)
        try #require(old.error != nil && old.enqueuedEventCount == 0 && old.quarantine == nil && old.cleanup != "uncertain")
        try #require(try app.documents.read().windowTouchTrace.count == released.windowTouchTrace.count)
        try await app.freshTap()
    }

    @Test("Opening preserves the app, rejects the old display and focuses a freshly found field")
    func openAndRefindField() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {}
        let app = try await prepareDuoControls(.outer90)
        let initial = try app.documents.read()
        let opened = try await changeDuoControls(app, change: .open)
        let rotation = try opened.activePanel.rotationDegrees()
        try #require(rotation == 90)
        let stale = try await app.selected(["tap", "--id", "feature.text", "--element-type", "TextField", "--expected-pid", String(app.pid)], allowFailure: true)
        try #require(stale.error != nil && stale.outcome == "failedBeforeInput" && stale.enqueuedEventCount == 0 && stale.cleanup == "notNeeded")
        try #require(try app.documents.read().windowTouchTrace.count == initial.windowTouchTrace.count)
        let current = PlaygroundControlsSession(copying: app, catalogue: opened)
        try await current.show("feature.showText")
        let before = try current.documents.read()
        let frame = try await current.frame("feature.text")
        let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
        let receipt = try await current.selected(["tap", "--id", "feature.text", "--element-type", "TextField", "--tap-style", "physical", "--expected-pid", String(app.pid)])
        try #require(receipt.enqueuedEventCount == 2 && receipt.cleanup == "notNeeded")
        let focused = try await current.documents.waitFor("the moved field focused in the same app") { $0.textFocused && $0.activeWindowTouches == 0 }
        try #require(focused.pid == initial.pid && focused.generation == initial.generation && focused.text == initial.text)
        try current.requireContact(focused, since: before, start: point, end: point)
    }

    @Test("The stale inner slider selection is rejected at closed outer90")
    func inactiveSlider() async throws {
        try await withDuoPlaygroundScreen(pose: .closed, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let before = try app.documents.read()
            let inner = try #require(app.catalogue.panels.first { $0.identity != app.catalogue.activePanel.identity })
            let output = try await app.app.run(["slider", "--id", "feature.slider", "--endpoint", "maximum", "--element-type", "Slider", "--expected-pid", String(app.pid),
                "--input-mode", "selected", "--screen-id", String(inner.identity.displayID), "--screen-uuid", inner.identity.uniqueID.uuidString], allowFailure: true)
            let receipt = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(output.output.utf8))
            try #require(output.exitCode != 0 && receipt.outcome == "failedBeforeInput" && receipt.enqueuedEventCount == 0 && receipt.cleanup == "notNeeded" && receipt.quarantine == nil)
            try #require(receipt.ax?.failure == .setupFailed)
            let after = try app.documents.read()
            try #require(after.slider == before.slider && after.counts == before.counts && after.windowTouchTrace.count == before.windowTouchTrace.count)
            try await app.freshTap()
        }
    }

    @Test("The original one-point library swipe factory changes a real Button")
    func nativeShortFactory() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.tap")
            let point = ShortFactoryConfiguration.Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            let end = ShortFactoryConfiguration.Point(x: point.x + 1, y: point.y)
            let panel = app.catalogue.activePanel.identity
            let cli = try TestHelpers.getAxePath()
            let config = ShortFactoryConfiguration(simulatorUDID: app.app.udid, bootIdentity: app.catalogue.bootIdentity, screenID: panel.displayID,
                screenUUID: panel.uniqueID, helperPath: URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("cadisplay-context").path,
                first: point, second: end, movedFirst: point, movedSecond: end, staleFirst: point, staleSecond: end,
                coordinationDirectory: app.artifacts.path, mode: "normal", hingeDegrees: 180)
            let file = app.artifacts.appendingPathComponent("short-factory.json")
            try JSONEncoder().encode(config).write(to: file)
            let executable = try #require(ProcessInfo.processInfo.environment["AXE_DUO_RETAINED_PAIR_PATH"])
            let process = try PlaygroundTestProcess(executable: executable, arguments: ["short-factory", file.path], directory: app.artifacts, name: "short-factory")
            let before = try app.documents.read()
            do {
                try process.start()
                try await process.wait(timeout: 15)
                let diagnostics = try process.diagnostics()
                try #require(process.exitCode == 0, "Native factory failed: \(diagnostics)")
                let receipt = try process.receipt(ShortFactoryReceipt.self)
                try #require(receipt.stage == "shortFactoryCompleted" && receipt.operation.outcome == "enqueuedAndDrained" && receipt.operation.normalEventDelta == 4 && !receipt.operation.tokenReturned)
                let after = try await app.documents.waitFor("one real short-factory Button callback") { $0.count("tap") == before.count("tap") + 1 && $0.activeWindowTouches == 0 }
                try app.requireContact(after, since: before, start: (point.x, point.y), end: (end.x, end.y))
            } catch { await process.finish(); throw error }
            await process.finish()
        }
    }
}

private struct ShortFactoryConfiguration: Encodable {
    struct Point: Encodable { let x: Double; let y: Double }
    let simulatorUDID: String; let bootIdentity: String; let screenID: UInt32; let screenUUID: UUID; let helperPath: String
    let first: Point; let second: Point; let movedFirst: Point; let movedSecond: Point; let staleFirst: Point; let staleSecond: Point
    let coordinationDirectory: String; let mode: String; let hingeDegrees: Double
}
private struct ShortFactoryReceipt: Decodable {
    let stage: String; let operation: Operation
    struct Operation: Decodable { let outcome: String; let normalEventDelta: Int; let tokenReturned: Bool }
}
