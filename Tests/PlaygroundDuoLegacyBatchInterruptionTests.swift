import Foundation
import Testing

@Suite("Playground Duo Legacy Batch Interruption", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoLegacyBatchInterruptionTests {
    @Test("Raw batch stops later steps after fold or rotation", arguments: [PlaygroundDuoChange.fold, .rotate])
    func stopsLaterInput(change: PlaygroundDuoChange) async throws {
        let app = try await prepareDuoControls(.inner90)
        let frame = try await app.frame("feature.pad")
        let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
        let before = try app.documents.read()
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: batchArguments([
            "touch -x \(point.0) -y \(point.1) --down --up --delay 8", "tap --id feature.tap"])
            + ["--verbose", "--udid", app.app.udid], directory: app.artifacts, name: "legacy-batch")
        do {
            try process.start()
            _ = try await app.documents.waitFor("real held batch contact before layout change") { $0.activeWindowTouches == 1 }
            try #require(process.isRunning)
            _ = try await changeDuoControls(app, change: change)
            try await process.wait(timeout: 15)
            try #require(process.exitCode != 0)
            let output = try process.diagnostics()
            // The error names the step and the change, without Swift type names.
            try #require(output.contains("Error: Step 1 failed: [touch]")
                && output.contains("The batch stopped:")
                && output.contains("Input was not repeated.") && !output.contains("FBSimulatorControl"))
            // The operation can release first; the enclosing session then has no input left to release.
            // --verbose writes the owner's cleanup log line to stderr.
            try #require(output.contains("Duo batch closed; cleanup=notNeeded")
                || output.contains("Duo batch closed; cleanup=releaseEnqueuedAndDrained"))
            try #require(!output.contains("cleanup=uncertain"))
            let released = try await app.documents.waitFor("old batch contact released") { $0.activeWindowTouches == 0 }
            try requireReleasedContacts(released, before: before, count: 1)
            try #require(released.count("tap") == before.count("tap"))
            try await Task.sleep(nanoseconds: 500_000_000)
            let settled = try app.documents.read()
            try #require(settled.windowTouchTrace.count == released.windowTouchTrace.count && settled.count("tap") == before.count("tap"))
            try await app.freshTap()
        } catch { await process.finish(); throw error }
        await process.finish()
    }
}

@Suite("Playground Duo Same App Fold", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoSameAppFoldTests {
    @Test("The same app opens from closed, stops a hold on fold, then accepts a fresh physical outer tap")
    func sameProcess() async throws {
        let closed = try await prepareDuoControls(.outer0)
        let initial = try closed.documents.read()
        let opened = try await changeDuoControls(closed, change: .open)
        let app = PlaygroundControlsSession(copying: closed, catalogue: opened)
        let sameApp = try app.documents.read()
        try #require(sameApp.pid == initial.pid && sameApp.generation == initial.generation)
        let frame = try await app.frame("feature.pad")
        let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(),
            arguments: ["touch", "-x", String(point.0), "-y", String(point.1), "--down", "--up", "--delay", "8"]
                + app.selection() + ["--udid", app.app.udid], directory: app.artifacts, name: "same-app-hold")
        do {
            try process.start()
            _ = try await app.documents.waitFor("real inner long-press callback in the same app") {
                $0.activeWindowTouches == 1 && $0.count("longPress") == sameApp.count("longPress") + 1
            }
            let folded = try await changeDuoControls(app, change: .fold)
            try await process.wait(timeout: 15)
            try #require(process.exitCode != 0)
            let response = try process.receipt(PlaygroundControlsReceipt.self)
            try #require(response.outcome == "failedNoReplay" && response.error?.contains("staleContext") == true
                && response.enqueuedEventCount == 1 && response.cleanup == "releaseEnqueuedAndDrained" && response.quarantine == nil)
            let released = try await app.documents.waitFor("the original inner contact released") { $0.activeWindowTouches == 0 }
            try requireReleasedContacts(released, before: sameApp, count: 1)
            let outer = PlaygroundControlsSession(copying: app, catalogue: folded)
            _ = try await outer.frame("feature.tap")
            let tapped = try await outer.selected(["tap", "--id", "feature.tap", "--element-type", "Button", "--tap-style", "physical", "--expected-pid", String(app.pid)])
            try #require(tapped.enqueuedEventCount == 2 && tapped.cleanup == "notNeeded")
            let final = try await outer.documents.waitFor("one fresh physical outer Button callback") { $0.count("tap") == released.count("tap") + 1 && $0.activeWindowTouches == 0 }
            try #require(final.pid == initial.pid && final.generation == initial.generation)
            try final.requireClear()
        } catch { await process.finish(); throw error }
        await process.finish()
    }
}

extension PlaygroundControlsSession {
    /// Keep the live app/document identity while binding a fresh measured display.
    init(copying original: PlaygroundControlsSession, catalogue: DuoCatalogue) {
        app = original.app
        pid = original.pid
        documents = original.documents
        self.catalogue = catalogue
        artifacts = original.artifacts
    }
}

@Suite("Playground Duo Default Horizontal Presets", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoHorizontalPresetTests {
    @Test("Default horizontal presets traverse200points in each direction")
    func defaultHorizontal() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let x = app.catalogue.activePanel.nativePixelHeight / Double(app.catalogue.activePanel.pointScale) / 2
            let y = app.catalogue.activePanel.nativePixelWidth / Double(app.catalogue.activePanel.pointScale) / 2
            try #require(x - 100 > frame.x && x + 100 < frame.x + frame.width && y > frame.y && y < frame.y + frame.height,
                "The normal visible pad does not contain the default preset path.")
            for (name, direction) in [("scroll-left", -1.0), ("scroll-right", 1.0)] {
                let before = try app.documents.read()
                let start = (x - direction * 100, y)
                let end = (x + direction * 100, y)
                _ = try await app.selected(["gesture", name])
                let after = try await app.documents.waitFor("one real default horizontal pan and release") { $0.count("pan") == before.count("pan") + 1 && $0.activeWindowTouches == 0 }
                try app.requireContact(after, since: before, start: start, end: end)
                try #require(after.panX * direction > 160 && abs(after.panY) <= 2)
            }
        }
    }
}
