import Darwin
import Foundation
import Testing

@Suite("Playground Duo Retained Single Input", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoRetainedInputTests {
    @Test("Raw down, move and up keep one real finger", arguments: [DuoControlsPosition.outer0, .inner90])
    func rawRetained(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let start = (frame.x + frame.width / 2 - 30, frame.y + frame.height / 2)
            let end = (start.0 + 60, start.1)
            let before = try app.documents.read()
            _ = try await app.app.run(["touch", "-x", String(start.0), "-y", String(start.1), "--down"])
            _ = try await app.documents.waitFor("one retained raw contact") { $0.activeWindowTouches == 1 }
            _ = try await app.app.run(["touch", "-x", String(end.0), "-y", String(end.1), "--down"])
            _ = try await app.documents.waitFor("same raw finger moved") {
                $0.activeWindowTouches == 1 && $0.windowTouchTrace.last?.phase == "windowTouchMoved"
                    && abs(($0.windowTouchTrace.last?.x ?? 0) - end.0) <= 2
            }
            _ = try await app.app.run(["touch", "-x", String(end.0), "-y", String(end.1), "--up"])
            let after = try await app.documents.waitFor("raw retained finger released") { $0.activeWindowTouches == 0 }
            try app.requireContact(after, since: before, start: start, end: end)
            try await app.freshTap()
        }
    }

    @Test("Selected owner rejects a wrong token while preserving the original contact")
    func selectedToken() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
            let before = try app.documents.read()
            let begin = try await app.selected(["touch", "-x", String(point.0), "-y", String(point.1), "--down"])
            let token = try #require(begin.token)
            try #require(begin.outcome == "retained" && begin.enqueuedEventCount == 1)
            let held = try await app.documents.waitFor("original selected contact held") { $0.activeWindowTouches == 1 }
            let refusal = try await app.selected(["touch", "-x", String(point.0 + 20), "-y", String(point.1), "--down", "--contact-token", UUID().uuidString], allowFailure: true)
            try #require(refusal.error != nil && refusal.enqueuedEventCount == 0 && refusal.cleanup == "notNeeded" && refusal.quarantine == nil)
            let unchanged = try app.documents.read()
            try #require(unchanged.activeWindowTouches == 1 && unchanged.windowTouchTrace.count == held.windowTouchTrace.count)
            let ended = try await app.selected(["touch", "-x", String(point.0), "-y", String(point.1), "--up", "--contact-token", token.uuidString])
            try #require(ended.outcome == "endedAndDrained" && ended.token == nil)
            let after = try await app.documents.waitFor("original contact released") { $0.activeWindowTouches == 0 }
            try app.requireContact(after, since: before, start: point, end: point)
            try await app.freshTap()
        }
    }

    @Test("Idle retained input releases when the phone closes, opens or turns", arguments: PlaygroundDuoChange.allCases)
    func idleLayoutChange(change: PlaygroundDuoChange) async throws {
        let app = try await prepareDuoControls(change == .open ? .outer0 : .inner90)
        let frame = try await app.frame("feature.pad")
        let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
        let before = try app.documents.read()
        let began = try await app.selected(["touch", "-x", String(point.0), "-y", String(point.1), "--down"])
        let token = try #require(began.token)
        _ = try await app.documents.waitFor("one live original contact") { $0.activeWindowTouches == 1 }
        _ = try await changeDuoControls(app, change: change)
        let released = try await app.documents.waitFor("automatic release before any old move or end") { $0.activeWindowTouches == 0 }
        try requireReleasedContacts(released, before: before, count: 1)
        for flag in ["--down", "--up"] {
            let old = try await app.selected(["touch", "-x", String(point.0 + 20), "-y", String(point.1), flag, "--contact-token", token.uuidString], allowFailure: true)
            try #require(old.error != nil && old.enqueuedEventCount == 0 && old.quarantine == nil && old.cleanup != "uncertain")
        }
        let afterRefusals = try app.documents.read()
        try #require(afterRefusals.windowTouchTrace.count == released.windowTouchTrace.count)
        try await app.freshTap()
    }

    @Test("A retained raw contact is held at30seconds and released by the existing idle deadline")
    func idleDeadline() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
            let before = try app.documents.read()
            _ = try await app.app.run(["touch", "-x", String(point.0), "-y", String(point.1), "--down"])
            _ = try await app.documents.waitFor("retained raw contact began") { $0.activeWindowTouches == 1 }
            let started = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(nanoseconds: 30_000_000_000)
            let held = try app.documents.read()
            try #require(held.activeWindowTouches == 1)
            let released = try await app.documents.waitFor("existing60-second idle release", timeout: 40) { $0.activeWindowTouches == 0 }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            try #require(elapsed >= 55 && elapsed <= 70)
            try requireReleasedContacts(released, before: before, count: 1)
            try await app.freshTap()
        }
    }

    @Test("Stopped client releases its actual held touch")
    func stoppedClient() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
            let before = try app.documents.read()
            let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(),
                arguments: ["touch", "-x", String(point.0), "-y", String(point.1), "--down", "--up", "--delay", "8", "--udid", app.app.udid],
                directory: app.artifacts, name: "stopped-client")
            do {
                try process.start()
                _ = try await app.documents.waitFor("real touch DOWN before stopping its client") { $0.activeWindowTouches == 1 }
                try #require(process.isRunning)
                try process.signal(SIGTERM)
                try await process.wait(timeout: 15)
                try #require(process.exitCode != 0)
                let released = try await app.documents.waitFor("owned release after client exit") { $0.activeWindowTouches == 0 }
                try requireReleasedContacts(released, before: before, count: 1)
                try await Task.sleep(nanoseconds: 500_000_000)
                try #require(try app.documents.read().windowTouchTrace.count == released.windowTouchTrace.count)
                try await app.freshTap()
            } catch { await process.finish(); throw error }
            await process.finish()
        }
    }
}
