import Foundation
import Testing

@Suite("Playground Agent Native State E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentNativeStateTests {
    @Test("Duplicate and unnamed controls are unavailable; hidden text is absent")
    func unavailableRows() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        let before = try session.document.read()
        let capture = try await session.capture()
        let targets = try capture.capture.targets.map(AgentPlaygroundRow.init)
        let duplicate = targets.filter { $0.label == "Same" && $0.identifier.isEmpty }
        try #require(duplicate.count == 2 && duplicate.allSatisfy { $0.action == "unavailable" })
        try #require(targets.contains { $0.label.isEmpty && $0.identifier.isEmpty && $0.action == "unavailable" })
        let field = try #require(targets.first { $0.identifier == "agent-examples.text" })
        try #require(field.action == "tap")
        let rows = capture.capture.targets + capture.capture.scroll + capture.capture.text
        try #require(!rows.contains { $0.contains("Hidden note") })
        let after = try session.document.read()
        try #require(after == before)
    }

    @Test("A native trailing space invalidates the old reference even when compact text is equal")
    func exactNativeWhitespace() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        try await session.tap("agent-examples.text")
        _ = try await session.run(["type", "q7", "--agent", "--expected-pid", String(session.pid),
            "--focus-id", "agent-examples.text"])
        _ = try await session.document.waitFor("seeded focused field") { $0.text == "q7" && $0.focused }
        let current = try await session.core.state()
        let space = try session.core.frame(of: session.core.element("agent-examples.space", in: current))
        _ = try await session.run(["tap", "-x", String(space.x + space.width / 2),
            "-y", String(space.y + space.height / 2), "--tap-style", "simulator"])
        let old = try await session.capture()
        let initial = try session.document.read()
        try #require(initial.status == "a")
        let changed = try await session.document.waitFor("normal delayed native trailing space", timeout: 12) { $0.status == "a " }
        try #require(changed.text == "q7" && changed.focused)
        let result = try await session.run(["type", "z"] + (try session.arguments(old, id: "agent-examples.text")), allowFailure: true)
        let refusal = try session.decode(result.output)
        try #require(result.exitCode != 0 && refusal.didError && refusal.error?.code == "screenChanged")
        try #require(refusal.data.action == nil && refusal.data.cache.requiresRefresh)
        let afterRefusal = try session.document.read()
        try #require(afterRefusal == changed)
        let fresh = try await session.capture()
        try #require(fresh.capture.snapshotID != old.capture.snapshotID)
        _ = try await session.run(["type", "z"] + (try session.arguments(fresh, id: "agent-examples.text")))
        _ = try await session.document.waitFor("fresh text after whitespace change") { $0.text == "q7z" }
        try old.requireUnexpired("after whitespace invalidation and fresh input")
    }

    @Test("The parent scroll target cannot move its nested list; the child target can")
    func nestedScrollOwnership() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        let capture = try await session.capture()
        let before = try session.document.read()
        let wrong = try await session.run(["swipe", "--direction", "up", "--distance", "1", "--duration", "0.7"]
            + (try session.arguments(capture, id: "agent-examples.outer")), allowFailure: true)
        let refusal = try session.decode(wrong.output)
        try #require(wrong.exitCode != 0 && refusal.didError)
        let action = try #require(refusal.data.action)
        try #require(action.kind == "swipe" && action.enqueuedEventCount == 0
            && action.outcome == "failedBeforeInput" && !action.replayed && action.cleanup == "notNeeded")
        let afterWrong = try session.document.read()
        try #require(afterWrong == before)
        let child = try await session.capture()
        let moved = try await session.run(["swipe", "--direction", "up", "--distance", "1", "--duration", "0.7"]
            + (try session.arguments(child, id: "agent-examples.list")))
        let movedResult = try session.decode(moved.output)
        try #require(movedResult.data.action?.outcome == "enqueuedAndDrained")
        let after = try await session.document.waitFor("only the nested list moved") {
            $0.listOffset > before.listOffset + 5 && abs($0.outerOffset - before.outerOffset) < 1
        }
        try #require(after.text == before.text && after.taps == before.taps)
        try await session.tap("agent-examples.tap")
        _ = try await session.document.waitFor("fresh button after nested scrolling") { $0.taps == before.taps + 1 }
    }

    @Test("Large native content retains a zero-input failure receipt and permits fresh input")
    func boundedFailureReceipt() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        try await session.tap("agent-examples.long")
        _ = try await session.document.waitFor("visible long content") { $0.longVisible && $0.longLength == 900_000 }
        _ = try await session.capture()
        let before = try session.document.read()
        let result = try await session.run(["tap", "--agent", "--expected-pid", String(session.pid),
            "--id", "agent-examples.covered"], allowFailure: true)
        let envelope = try session.decode(result.output)
        try #require(result.exitCode != 0 && envelope.didError && envelope.error?.code == "responseTooLarge")
        let action = try #require(envelope.data.action)
        try #require(action.kind == "tap" && action.outcome == "failedBeforeInput"
            && action.enqueuedEventCount == 0 && action.cleanup == "notNeeded" && !action.replayed)
        try #require(envelope.data.cache.requiresRefresh && envelope.data.capture == nil)
        let after = try session.document.read()
        try #require(after == before)
        let state = try await session.core.state()
        let reset = try session.core.frame(of: session.core.element("agent-examples.reset", in: state))
        let clear = try await session.capture()
        _ = try await session.run(["tap", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", clear.capture.snapshotID.uuidString, "-x", String(reset.x + reset.width / 2),
            "-y", String(reset.y + reset.height / 2), "--tap-style", "simulator"])
        _ = try await session.document.waitFor("normal Reset cleared long content") { !$0.longVisible && $0.taps == 0 }
        try await session.tap("agent-examples.tap")
        _ = try await session.document.waitFor("fresh real button callback") { $0.taps == 1 }
    }
}
