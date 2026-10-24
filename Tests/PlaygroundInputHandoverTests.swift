import Foundation
import Testing

@Suite("Playground Input Handover E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundInputHandoverTests {
    @Test("A complete raw touch hands input to selected, raw and agent commands")
    func completeRawSelectedAgentHandover() async throws {
        let session = try await Self.open("complete")
        do {
            let point = try await Self.point("feature.tap", in: session)
            let touch = ["touch", "--down", "--up"] + Self.coordinates(point)
            var before = try session.document.read()
            _ = try await session.rawCommand(touch)
            try await session.requireButtonTap(after: before)

            before = try session.document.read()
            let selected = try await session.command(touch + session.selectedFlags)
            try session.requireSelectedSuccess(selected, events: 2)
            try await session.requireButtonTap(after: before)

            before = try session.document.read()
            _ = try await session.rawCommand(touch)
            try await session.requireButtonTap(after: before)

            before = try session.document.read()
            let agent = try await session.command(["tap", "--agent", "--expected-pid", String(session.pid),
                "--id", "feature.tap", "--element-type", "Button"])
            try session.requireHIDSuccess(agent, kind: "tap", events: 2)
            try await session.requireButtonTap(after: before)
        } catch {
            // Complete commands already attempted UP. Await readback without replaying input.
            await Self.requireReleasedAfterAttempt(session)
            throw error
        }
    }

    @Test("Raw DOWN and MOVE keep one contact and refuse selected input until UP")
    func rawRetainedContactBlocksSelected() async throws {
        let session = try await Self.open("raw-retained")
        let start = try await Self.point("feature.pad", in: session)
        let end = (x: start.x + 20, y: start.y)
        let initial = try session.document.read()
        var downAttempted = false
        var upAttempted = false
        var releasePoint = start
        do {
            downAttempted = true
            _ = try await session.rawCommand(["touch", "--down"] + Self.coordinates(start))
            let held = try await Self.heldContact(session, after: initial, at: start)
            let refused = try await session.command(["touch", "--down", "--up"]
                + Self.coordinates(start) + session.selectedFlags, allowFailure: true)
            let receipt = try session.rawReceipt(refused.output)
            let expectedOutcome = isDuoPlaygroundE2EEnabled ? "rejectedBeforeInput" : "failedNoReplay"
            try #require(refused.exitCode != 0 && receipt.outcome == expectedOutcome
                && receipt.enqueuedEventCount == 0 && receipt.cleanup == "notNeeded"
                && receipt.error == "busy" && receipt.quarantine == nil)
            try Self.requireSameHeldContact(try session.document.read(), as: held)

            releasePoint = end
            _ = try await session.rawCommand(["touch", "--down"] + Self.coordinates(end))
            let moved = try await session.document.waitFor("the same raw contact moves") {
                $0.activeWindowTouches == 1 && $0.windowTouchTrace.last?.phase == "windowTouchMoved"
                    && abs(($0.windowTouchTrace.last?.x ?? 0) - end.x) <= 2
                    && abs(($0.windowTouchTrace.last?.y ?? 0) - end.y) <= 2
            }
            try #require(moved.windowTouchTrace.last?.contactID == held.windowTouchTrace.last?.contactID)
            try #require(moved.count("windowTouchBegan") == initial.count("windowTouchBegan") + 1)

            upAttempted = true
            _ = try await session.rawCommand(["touch", "--up"] + Self.coordinates(end))
            let released = try await session.document.waitFor("raw UP releases its contact") { $0.activeWindowTouches == 0 }
            try Self.requireMovedPair(released, after: initial, start: start, end: end)
            _ = try await session.capture()
            let beforeTap = try session.document.read()
            let tapped = try await session.command(["tap", "--agent", "--expected-pid", String(session.pid),
                "--id", "feature.tap", "--element-type", "Button"])
            try session.requireHIDSuccess(tapped, kind: "tap", events: 2)
            try await session.requireButtonTap(after: beforeTap)
        } catch {
            if downAttempted && !upAttempted {
                // Release only this possible contact. Do not repeat DOWN or a failed UP.
                await Self.cleanupRawContact(session, point: releasePoint)
            } else if upAttempted {
                await Self.requireReleasedAfterAttempt(session)
            }
            throw error
        }
    }

    @Test("A selected retained contact refuses raw input until its matching token UP")
    func selectedRetainedContactBlocksRaw() async throws {
        let session = try await Self.open("selected-retained")
        // This case must not depend on a raw broker left by another test.
        let warmButton = try await Self.point("feature.tap", in: session)
        let beforeWarm = try session.document.read()
        _ = try await session.rawCommand(["touch", "--down", "--up"] + Self.coordinates(warmButton))
        try await session.requireButtonTap(after: beforeWarm)
        let point = try await Self.point("feature.pad", in: session)
        let initial = try session.document.read()
        var token: UUID?
        var upAttempted = false
        do {
            let down = try await session.command(["touch", "--down"]
                + Self.coordinates(point) + session.selectedFlags, allowFailure: true)
            let receipt = try session.rawReceipt(down.output)
            token = receipt.token
            try #require(down.exitCode == 0 && receipt.outcome == "retained"
                && receipt.enqueuedEventCount == 1 && receipt.cleanup == "notNeeded"
                && receipt.error == nil && receipt.quarantine == nil)
            let owned = try #require(token)
            let held = try await Self.heldContact(session, after: initial, at: point)
            try await Self.requireRawRefusal(["touch", "--down", "--up"] + Self.coordinates(point), in: session)
            try Self.requireSameHeldContact(try session.document.read(), as: held)

            upAttempted = true
            let up = try await session.command(["touch", "--up", "--contact-token", owned.uuidString]
                + Self.coordinates(point) + session.selectedFlags)
            let ended = try session.rawReceipt(up.output)
            try #require(up.exitCode == 0 && ended.outcome == "endedAndDrained"
                && ended.enqueuedEventCount == 2 && ended.cleanup == "notNeeded"
                && ended.error == nil && ended.quarantine == nil)
            let released = try await session.document.waitFor("selected token UP releases its contact") { $0.activeWindowTouches == 0 }
            let groups = try controlsContactGroups(released, before: initial, expected: 1)
            let rows = try #require(groups.first)
            let first = try #require(rows.first)
            let last = try #require(rows.last)
            try #require(first.contactID == held.windowTouchTrace.last?.contactID && last.contactID == first.contactID)
            try #require(hypot(first.x - point.x, first.y - point.y) <= 2
                && hypot(last.x - point.x, last.y - point.y) <= 2)
            // UIKit can omit a MOVE callback when the native MOVE keeps the same point.
            // The native receipt must still prove both MOVE and UP were drained.

            let button = try await Self.point("feature.tap", in: session)
            let beforeTap = try session.document.read()
            _ = try await session.rawCommand(["touch", "--down", "--up"] + Self.coordinates(button))
            try await session.requireButtonTap(after: beforeTap)
        } catch {
            if let token, !upAttempted {
                await Self.cleanupSelectedContact(session, token: token, point: point)
            } else if upAttempted {
                await Self.requireReleasedAfterAttempt(session)
            } else {
                Issue.record("Selected DOWN returned no usable token. Matching UP cannot be sent; input recovery remains unverified.")
            }
            throw error
        }
    }

    private static func open(_ name: String) async throws -> PlaygroundAgentFeatureSession {
        let position: DuoControlsPosition = isDuoPlaygroundE2EEnabled ? .inner90 : .outer0
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "handover-" + name, position: position)
        try await session.show("feature.showPad")
        try session.document.read().requireClear()
        return session
    }

    private static func point(_ identifier: String, in session: PlaygroundAgentFeatureSession) async throws -> (x: Double, y: Double) {
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element(identifier, in: state))
        try #require(frame.width > 40 && frame.height > 0)
        return (frame.x + frame.width / 2, frame.y + frame.height / 2)
    }

    private static func coordinates(_ point: (x: Double, y: Double)) -> [String] {
        ["-x", String(point.x), "-y", String(point.y)]
    }

    private static func heldContact(_ session: PlaygroundAgentFeatureSession, after before: PlaygroundControlsDocument,
                                    at point: (x: Double, y: Double)) async throws -> PlaygroundControlsDocument {
        let held = try await session.document.waitFor("one actual retained contact") {
            $0.activeWindowTouches == 1 && $0.windowTouchTrace.count > before.windowTouchTrace.count
        }
        try #require(held.pid == before.pid && held.generation == before.generation)
        try #require(held.windowTraceDropped == 0 && held.recognizerTraceDropped == 0)
        let added = Array(held.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
        try #require(added.count == 1 && added[0].phase == "windowTouchBegan" && added[0].hitView == "feature.pad")
        try #require(hypot(added[0].x - point.x, added[0].y - point.y) <= 2)
        return held
    }

    private static func requireSameHeldContact(_ after: PlaygroundControlsDocument, as held: PlaygroundControlsDocument) throws {
        try #require(after.pid == held.pid && after.generation == held.generation && after.activeWindowTouches == 1)
        try #require(after.windowTouchTrace == held.windowTouchTrace && after.windowTraceDropped == 0)
        try #require(after.count("tap") == held.count("tap"))
    }

    private static func requireMovedPair(_ after: PlaygroundControlsDocument, after before: PlaygroundControlsDocument,
                                         start: (x: Double, y: Double), end: (x: Double, y: Double)) throws {
        let groups = try controlsContactGroups(after, before: before, expected: 1)
        let rows = try #require(groups.first)
        let first = try #require(rows.first)
        let last = try #require(rows.last)
        try #require(hypot(first.x - start.x, first.y - start.y) <= 2)
        try #require(hypot(last.x - end.x, last.y - end.y) <= 2)
        try #require(rows.contains { $0.phase == "windowTouchMoved" } && rows.allSatisfy { $0.hitView == "feature.pad" })
    }

    private static func requireRawRefusal(_ arguments: [String], in session: PlaygroundAgentFeatureSession) async throws {
        let name = "raw-refusal-" + UUID().uuidString
        let argv = arguments + ["--udid", session.agent.udid]
        try JSONEncoder().encode(argv).write(to: session.artifacts.appendingPathComponent(name + "-argv.json"))
        try Data(contentsOf: session.document.url).write(to: session.artifacts.appendingPathComponent(name + "-before.json"))
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: argv,
            directory: session.artifacts, name: name)
        do {
            try process.start()
            try await process.wait(timeout: 8)
            let elapsed = ProcessInfo.processInfo.systemUptime - process.startedUptime
            try #require(elapsed < 10, "Raw refusal exceeded its 10-second bound.")
            try JSONEncoder().encode(InputHandoverRawRefusalRecord(exitCode: process.exitCode, elapsedSeconds: elapsed))
                .write(to: session.artifacts.appendingPathComponent(name + "-result.json"))
            let stdout = try process.output()
            let diagnostics = try process.diagnostics()
            try #require(process.exitCode != 0 && stdout.isEmpty && !diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Raw input was not refused with its empty stdout contract: \(diagnostics)")
            try Data(contentsOf: session.document.url).write(to: session.artifacts.appendingPathComponent(name + "-after.json"))
            await process.finish()
        } catch { await process.finish(); throw error }
    }

    private static func cleanupRawContact(_ session: PlaygroundAgentFeatureSession, point: (x: Double, y: Double)) async {
        do {
            _ = try await session.rawCommand(["touch", "--up"] + coordinates(point))
            _ = try await session.document.waitFor("normal raw UP cleanup") { $0.activeWindowTouches == 0 }
        } catch { Issue.record("Raw contact cleanup failed: \(error)") }
    }

    private static func cleanupSelectedContact(_ session: PlaygroundAgentFeatureSession, token: UUID,
                                                point: (x: Double, y: Double)) async {
        do {
            _ = try await session.command(["touch", "--up", "--contact-token", token.uuidString]
                + coordinates(point) + session.selectedFlags)
            _ = try await session.document.waitFor("normal selected UP cleanup") { $0.activeWindowTouches == 0 }
        } catch { Issue.record("Selected contact cleanup failed: \(error)") }
    }

    private static func requireReleasedAfterAttempt(_ session: PlaygroundAgentFeatureSession) async {
        do {
            _ = try await session.document.waitFor("release after the one UP attempt") { $0.activeWindowTouches == 0 }
        } catch { Issue.record("The one UP attempt did not prove release; input was not replayed: \(error)") }
    }
}

private struct InputHandoverRawRefusalRecord: Encodable {
    let exitCode: Int32
    let elapsedSeconds: Double
}
