import Foundation
import Testing

enum PlaygroundAgentBatchVariant: String, Sendable { case invalidJSON, wrongPID, normal, stopAtMissing, rawCompatibility, selectedCompatibility, focusReferences }

@Suite("Playground Agent Batch E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentBatchTests {
    @Test("Agent batches preserve order and completed work without replay", arguments: [
        PlaygroundAgentBatchVariant.invalidJSON, .wrongPID, .normal, .stopAtMissing, .rawCompatibility, .selectedCompatibility,
        .focusReferences,
    ])
    func batch(_ variant: PlaygroundAgentBatchVariant) async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        let seed: String
        switch variant {
        case .rawCompatibility, .stopAtMissing: seed = "AB"
        case .selectedCompatibility: seed = "ABc"
        default: seed = ""
        }
        if !seed.isEmpty {
            try await session.tap("agent-examples.text")
            let field = try await session.capture()
            let seeded = try await session.run(["type", seed] + (try session.arguments(field, id: "agent-examples.text")))
            let value = try session.decode(seeded.output)
            let action = try #require(value.data.action)
            try #require(!value.didError && action.kind == "typeText" && action.outcome == "enqueuedAndDrained"
                && action.enqueuedEventCount > 0 && action.cleanup == "notNeeded" && !action.replayed)
            _ = try await session.document.waitFor("exact pre-batch text") { $0.text == seed && $0.activeWindowTouches == 0 }
        }
        let old = try await session.capture()
        let file = session.artifacts.appendingPathComponent("steps.json")
        let normal = AgentExampleBatchDocument(steps: [
            .init(action: "tap", id: "agent-examples.text", text: nil),
            .init(action: "type", id: "agent-examples.text", text: "AB"),
            .init(action: "tap", id: "agent-examples.tap", text: nil),
        ])
        let missing = AgentExampleBatchDocument(steps: [
            .init(action: "tap", id: "agent-examples.tap", text: nil),
            .init(action: "tap", id: "agent-examples.absent-7d53", text: nil),
            .init(action: "tap", id: "agent-examples.tap", text: nil),
        ])
        if variant == .invalidJSON { try Data("{".utf8).write(to: file) }
        else if variant == .focusReferences {
            // One reference batch focuses the unfocused field, types, then taps the button.
            let document: [String: Any] = ["snapshotID": old.capture.snapshotID.uuidString, "steps": [
                ["action": "type", "ref": try session.reference("agent-examples.text", in: old), "text": "AB", "focus": true],
                ["action": "tap", "ref": try session.reference("agent-examples.tap", in: old)],
            ]]
            try JSONSerialization.data(withJSONObject: document).write(to: file)
        }
        else { try JSONEncoder().encode(variant == .stopAtMissing ? missing : normal).write(to: file) }
        var arguments = ["batch", "--agent", "--file", file.path,
            "--expected-pid", String(variant == .wrongPID ? session.pid + 1 : session.pid)]
        if variant == .rawCompatibility || variant == .selectedCompatibility {
            let state = try await session.core.state()
            let textFrame = try session.core.frame(of: session.core.element("agent-examples.text", in: state))
            let buttonFrame = try session.core.frame(of: session.core.element("agent-examples.tap", in: state))
            arguments = ["batch", "--step", "tap -x \(textFrame.x + textFrame.width / 2) -y \(textFrame.y + textFrame.height / 2) --tap-style physical",
                "--step", "type c", "--step", "tap -x \(buttonFrame.x + buttonFrame.width / 2) -y \(buttonFrame.y + buttonFrame.height / 2) --tap-style physical"]
            if variant == .selectedCompatibility {
                let measured = try AgentExampleContext.decode(try await session.run(["describe-ui", "--agent", "--expected-pid", String(session.pid)]).output)
                arguments += ["--input-mode", "selected", "--screen-id", String(measured.screenID), "--screen-uuid", measured.screenUUID.uuidString]
                arguments[4] = "type d --expected-pid \(session.pid) --focus-id agent-examples.text"
            }
        }
        let before = try session.document.read()
        let mayFail = [.invalidJSON, .wrongPID, .stopAtMissing].contains(variant)
        let result = try await session.run(arguments, allowFailure: mayFail, timeout: 90)
        if variant == .invalidJSON {
            try #require(result.exitCode != 0 && result.output.contains("JSON"))
            let after = try session.document.read()
            try #require(after == before)
        } else if variant == .wrongPID {
            let envelope = try session.decode(result.output)
            try #require(result.exitCode != 0 && envelope.didError && envelope.error?.code == "observationFailed")
            try #require(result.output.contains("processChanged"))
            let batch = try #require(try AgentExampleBatchResult.decode(result.output).data.batch)
            try #require(batch.completedSteps == 0 && batch.steps.isEmpty)
            let after = try session.document.read()
            try #require(after == before)
        } else {
            let partial = variant == .stopAtMissing
            if variant == .normal || variant == .focusReferences || partial {
                let envelope = try session.decode(result.output)
                try #require(envelope.didError == partial && (result.exitCode != 0) == partial)
                let batch = try #require(try AgentExampleBatchResult.decode(result.output).data.batch)
                let steps = variant == .focusReferences ? 2 : 3
                try #require(batch.totalSteps == steps && batch.completedSteps == (partial ? 1 : steps))
                try #require(!batch.replayed && !batch.rolledBack)
                try #require(batch.stoppedAt == (partial ? 2 : nil))
                try #require(batch.steps.count == (partial ? 2 : steps))
                try #require(Set(batch.steps.map(\.requestID)).count == batch.steps.count)
                if partial {
                    try #require(batch.steps[0].status == "completed" && batch.steps[1].status == "rejectedBeforeInput")
                    try #require(batch.steps[1].error?.code == "batchTargetMissing")
                    // A batch stopped by a step that sent nothing returns the current screen.
                    try #require(!envelope.data.cache.requiresRefresh)
                    let capture = try #require(envelope.data.capture)
                    try #require(capture.snapshotID != old.capture.snapshotID)
                    try requireAgentCaptureValue(capture, identifier: "agent-examples.text", expected: "AB",
                        action: "typeText", pid: session.pid, udid: session.app.udid)
                } else {
                    try #require(batch.steps.allSatisfy { $0.status == "completed" && $0.receipt?.cleanup != "uncertain" })
                    // A focus step counts its focus tap (2) and its typing (8) together.
                    try #require(batch.steps.compactMap { $0.receipt?.enqueuedEventCount }
                        == (variant == .focusReferences ? [10, 2] : [2, 8, 2]))
                    if let capture = envelope.data.capture {
                        try requireAgentCaptureValue(capture, identifier: "agent-examples.text", expected: "AB",
                            action: "typeText", pid: session.pid, udid: session.app.udid)
                    }
                }
            } else { try #require(result.exitCode == 0) }
            let expectedText = partial ? "AB" : variant == .normal || variant == .focusReferences ? "AB"
                : variant == .rawCompatibility ? "ABc" : "ABcd"
            let after = try await session.document.waitFor("ordered batch callbacks and release") {
                $0.taps == before.taps + 1 && $0.text == expectedText && $0.activeWindowTouches == 0
            }
            try #require(after.textChanges == before.textChanges
                + (partial ? 0 : variant == .normal || variant == .focusReferences ? 2 : 1))
            let oldIDs = Set(before.windowTouchTrace.map(\.contactID))
            let groups = Dictionary(grouping: after.windowTouchTrace.filter { !oldIDs.contains($0.contactID) }, by: \.contactID)
            try #require(groups.count == (partial ? 1 : 2) && after.windowTraceDropped == 0)
            for rows in groups.values {
                try #require(rows.first?.phase == "windowTouchBegan" && rows.last?.phase == "windowTouchEnded")
                try #require(rows.filter { $0.phase == "windowTouchBegan" }.count == 1)
                try #require(rows.filter { $0.phase == "windowTouchEnded" || $0.phase == "windowTouchCancelled" }.count == 1)
                try #require(rows.dropFirst().dropLast().allSatisfy { $0.phase == "windowTouchMoved" })
                let ordered = zip(rows, rows.dropFirst()).allSatisfy { $0.0.timestamp <= $0.1.timestamp }
                try #require(ordered)
            }
            if partial {
                let stale = try await session.run(["tap"] + (try session.arguments(old, id: "agent-examples.tap")), allowFailure: true)
                let refusal = try session.decode(stale.output)
                try #require(stale.exitCode != 0 && refusal.error?.code == "snapshotMissing" && refusal.data.action == nil)
                let unchanged = try session.document.read()
                try #require(unchanged == after)
            }
            let fresh = try await session.capture()
            try requireAgentCaptureValue(fresh.capture, identifier: "agent-examples.text", expected: expectedText,
                action: "typeText", pid: session.pid, udid: session.app.udid)
        }
    }
}

private struct AgentExampleBatchDocument: Encodable {
    struct Step: Encodable { let action: String; let id: String; let text: String? }
    let steps: [Step]
}
private struct AgentExampleBatchResult: Decodable {
    struct Payload: Decodable { let batch: Batch? }
    struct Batch: Decodable {
        struct Step: Decodable {
            struct Action: Decodable { let enqueuedEventCount: Int; let cleanup: String }
            struct Failure: Decodable { let code: String }
            let status: String
            let requestID: UUID
            let receipt: Action?
            let error: Failure?
        }
        let totalSteps: Int
        let completedSteps: Int
        let stoppedAt: Int?
        let replayed: Bool
        let rolledBack: Bool
        let steps: [Step]
    }
    let data: Payload
    static func decode(_ output: String) throws -> Self {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No agent batch result: \(output)")
    }
}
private struct AgentExampleContext: Decodable {
    struct Payload: Decodable { let context: DuoContext? }
    let data: Payload
    static func decode(_ output: String) throws -> DuoContext {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), let context = value.data.context { return context }
        }
        throw TestError.invalidJSON("No measured context: \(output)")
    }
}
