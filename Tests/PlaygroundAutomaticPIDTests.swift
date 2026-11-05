import Foundation
import Testing

/// Run alone. Each command starts a separate CLI process against the normal app.
@Suite("Playground Automatic Agent PID E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAutomaticPIDTests {
    @Test("Omitted PID captures, validates and uses replacement references across CLI calls")
    func automaticCaptureAndReferenceLifecycle() async throws {
        let session = try await open("reference-lifecycle")
        let before = try session.document.read()
        let initial = try await capture(session)
        let validated = try await session.command(["describe-ui", "--agent", "--snapshot-id",
            initial.capture.snapshotID.uuidString])
        let validation = try session.decodeAgent(validated.output)
        try #require(!validation.didError && validation.data.action == nil)
        try #require(validation.data.cache.status == "validated"
            && validation.data.capture?.snapshotID == initial.capture.snapshotID
            && validation.data.capture?.applicationPID == session.pid)
        let reused = try await session.command(["describe-ui", "--agent", "--since-screen-hash",
            initial.capture.screenHash])
        let reuse = try session.decodeAgent(reused.output)
        try #require(!reuse.didError && reuse.data.cache.status == "reused")
        try #require(reuse.data.capture?.snapshotID == initial.capture.snapshotID
            && reuse.data.capture?.applicationPID == session.pid)
        try #require(try session.document.read().inputState == before.inputState)

        let first = try await tap(session, capture: initial.capture, before: before)
        let replacement = try #require(first.data.capture)
        try #require(replacement.snapshotID != initial.capture.snapshotID
            && replacement.applicationPID == session.pid && !first.data.cache.requiresRefresh)
        let afterFirst = try session.document.read()
        let second = try await tap(session, capture: replacement, before: afterFirst)
        let secondReplacement = try #require(second.data.capture)
        try #require(secondReplacement.snapshotID != replacement.snapshotID
            && secondReplacement.applicationPID == session.pid && !second.data.cache.requiresRefresh)
        let afterSecond = try session.document.read()
        let old = try await session.command(tapArguments(session, capture: initial.capture), allowFailure: true)
        try requireNoInput(old, session: session, before: afterSecond, codes: ["snapshotMissing"])
        try initial.requireUnexpired("after omitted-PID replacement refusal")
    }

    @Test("Explicit correct PID works while wrong, zero and negative assertions send no input")
    func explicitPIDAssertionsRemainStrict() async throws {
        let session = try await open("explicit-assertions")
        let before = try session.document.read()
        let correct = try await session.command(["describe-ui", "--agent", "--expected-pid", String(session.pid)])
        let correctResult = try session.decodeAgent(correct.output)
        let current = try #require(correctResult.data.capture)
        try #require(!correctResult.didError && current.applicationPID == session.pid)
        let wrong = try await session.command(tapArguments(session, capture: current)
            + ["--expected-pid", String(Int32.max)], allowFailure: true)
        try requireNoInput(wrong, session: session, before: before, codes: ["contextChanged"])
        for invalid in ["0", "-1"] {
            let output = try await session.command(["describe-ui", "--agent", "--expected-pid", invalid], allowFailure: true)
            try #require(output.exitCode != 0)
            try #require(try session.document.read().inputState == before.inputState)
        }
        let fresh = try await capture(session)
        _ = try await tap(session, capture: fresh.capture, before: before, expectedPID: session.pid)
    }

    @Test("Home discovery and a newly opened app cannot reuse the previous owner references")
    func homeAndAppChangesReplaceOwner() async throws {
        let session = try await open("home-owner")
        let initial = try await capture(session)
        let before = try session.document.read()
        let home = try await session.command(["button", "home"] + session.selectedFlags)
        let homeReceipt = try session.rawReceipt(home.output)
        try #require(homeReceipt.outcome == "enqueuedAndDrained" && homeReceipt.enqueuedEventCount == 2
            && homeReceipt.cleanup == "notNeeded" && homeReceipt.error == nil && homeReceipt.quarantine == nil)
        let stale = try await session.command(tapArguments(session, capture: initial.capture), allowFailure: true)
        try requireNoInput(stale, session: session, before: before,
            codes: ["snapshotMissing", "contextChanged", "observationFailed"])
        try initial.requireUnexpired("after Home refused the old app reference")
        let homeReply = try await session.command(["describe-ui", "--agent"])
        let homeResult = try session.decodeAgent(homeReply.output)
        let homeCapture = try #require(homeResult.data.capture)
        try #require(!homeResult.didError && homeResult.data.action == nil
            && homeCapture.applicationPID > 0 && homeCapture.applicationPID != session.pid)
        try #require(try session.document.read().inputState == before.inputState)

        let reopened = try await open("app-after-home")
        let openedState = try reopened.document.read()
        let fresh = try await capture(reopened)
        try #require(fresh.capture.applicationPID == reopened.pid
            && fresh.capture.applicationPID != homeCapture.applicationPID
            && fresh.capture.snapshotID != homeCapture.snapshotID)
        let oldPage = try await reopened.command(["describe-ui", "--agent", "--snapshot-id",
            homeCapture.snapshotID.uuidString], allowFailure: true)
        try requireNoInput(oldPage, session: reopened, before: openedState, codes: ["snapshotMissing"])
        _ = try await tap(reopened, capture: fresh.capture, before: openedState)
    }

    @Test("Automatic agent PID does not change plain description or raw keyboard behavior")
    func rawCommandsKeepTheirOutputAndInput() async throws {
        let session = try await open("raw-compatibility")
        try await session.focusField()
        let before = try session.document.read()
        let raw = try await session.command(["describe-ui"])
        try #require(raw.exitCode == 0 && !raw.output.contains("axe.output.agent-result"))
        let roots = try UIStateParser.parseDescribeUIRoots(raw.output)
        try #require(roots.contains { $0.type == "Application" && $0.label == "AxePlayground" })
        _ = try await session.rawCommand(["key", "4"])
        let edited = try await session.document.waitFor("one normal raw lowercase edit") { $0.text == before.text + "a" }
        try #require(edited.count("textChanged") == before.count("textChanged") + 1
            && edited.activeWindowTouches == 0 && edited.windowTouchTrace == before.windowTouchTrace)
        let discovered = try await capture(session)
        try #require(discovered.capture.applicationPID == session.pid)
        try #require(try session.document.read().inputState == edited.inputState)
    }

    @Test("Fresh selectors and focused reference typing discover their owner without PID")
    func selectorAndFocusedTypeDiscoverOwner() async throws {
        let session = try await open("selector-and-type")
        let before = try session.document.read()
        let selector = try await session.command(["tap", "--agent", "--id", "feature.tap",
            "--element-type", "Button", "--tap-style", "physical"])
        try session.requireHIDSuccess(selector, kind: "tap", events: 2)
        try await session.requireButtonTap(after: before)
        try #require(try session.decodeAgent(selector.output).data.capture?.applicationPID == session.pid)

        try await session.focusField()
        let focused = try session.document.read()
        let field = try await capture(session)
        let typed = try await session.command(["type", "q7", "--agent", "--snapshot-id",
            field.capture.snapshotID.uuidString, "--ref", try session.reference("feature.text", in: field.capture)])
        try session.requireHIDSuccess(typed, kind: "typeText", events: 4)
        let after = try await session.document.waitFor("two exact automatic-owner edits") {
            $0.text == focused.text + "q7" && $0.activeWindowTouches == 0
        }
        try #require(after.count("textChanged") == focused.count("textChanged") + 2
            && after.pid == focused.pid && after.generation == focused.generation
            && after.windowTouchTrace == focused.windowTouchTrace
            && after.count("tap") == focused.count("tap") && after.slider == focused.slider
            && after.switchOn == focused.switchOn)
        try #require(try session.decodeAgent(typed.output).data.capture?.applicationPID == session.pid)
    }

    @Test("A PID-free batch keeps one app owner across two real Button steps")
    func batchKeepsItsInitiallyDiscoveredOwner() async throws {
        let session = try await open("batch-owner")
        let file = session.artifacts.appendingPathComponent("automatic-pid-steps.json")
        try Data(#"{"steps":[{"action":"tap","id":"feature.tap"},{"action":"tap","id":"feature.tap"}]}"#.utf8)
            .write(to: file, options: .withoutOverwriting)
        let before = try session.document.read()
        let output = try await session.command(["batch", "--agent", "--file", file.path])
        let result = try session.decodeAgent(output.output)
        try #require(!result.didError && result.data.capture?.applicationPID == session.pid
            && !result.data.cache.requiresRefresh)
        let line = try #require(output.output.split(separator: "\n").first { $0.first == "{" })
        let batch = try JSONDecoder().decode(AutomaticPIDBatchEnvelope.self, from: Data(line.utf8)).data.batch
        try #require(batch.totalSteps == 2 && batch.completedSteps == 2 && batch.stoppedAt == nil
            && !batch.replayed && !batch.rolledBack && batch.steps.count == 2)
        try #require(batch.steps.map(\.index) == [1, 2]
            && Set(batch.steps.map(\.requestID)).count == 2)
        for step in batch.steps {
            let action = try #require(step.receipt)
            try #require(step.status == "completed" && step.context == session.initialContext
                && action.kind == "tap" && action.outcome == "enqueuedAndDrained"
                && action.enqueuedEventCount == 2 && action.cleanup == "notNeeded" && !action.replayed)
        }
        let after = try await session.document.waitFor("two ordered Button callbacks and released contacts") {
            $0.count("tap") == before.count("tap") + 2 && $0.activeWindowTouches == 0
        }
        _ = try session.contacts(after: before, in: after, count: 2)
        try #require(after.pid == before.pid && after.generation == before.generation
            && after.text == before.text && after.count("textChanged") == before.count("textChanged")
            && after.slider == before.slider && after.switchOn == before.switchOn)
    }

    private func open(_ name: String) async throws -> PlaygroundAgentFeatureSession {
        try await PlaygroundAgentFeatureSession.open(caseName: "automatic-pid-" + name,
            position: isDuoPlaygroundE2EEnabled ? .inner90 : .outer0)
    }

    private func capture(_ session: PlaygroundAgentFeatureSession) async throws -> AgentPlaygroundTimedCapture {
        let started = ProcessInfo.processInfo.systemUptime
        let output = try await session.command(["describe-ui", "--agent"])
        let result = try session.decodeAgent(output.output)
        let value = try #require(result.data.capture)
        try #require(!result.didError && result.data.action == nil && value.applicationPID == session.pid)
        let timed = try AgentPlaygroundTimedCapture(capture: value, requestStartedUptime: started)
        try timed.requireUnexpired("after automatic app capture")
        return timed
    }

    private func tapArguments(_ session: PlaygroundAgentFeatureSession, capture: AgentPlaygroundCapture) throws -> [String] {
        ["tap", "--agent", "--snapshot-id", capture.snapshotID.uuidString,
            "--ref", try session.reference("feature.tap", in: capture), "--tap-style", "physical"]
    }

    private func tap(_ session: PlaygroundAgentFeatureSession, capture: AgentPlaygroundCapture,
                     before: PlaygroundControlsDocument, expectedPID: Int32? = nil) async throws -> AgentPlaygroundResult {
        var arguments = try tapArguments(session, capture: capture)
        if let expectedPID { arguments += ["--expected-pid", String(expectedPID)] }
        let output = try await session.command(arguments)
        try session.requireHIDSuccess(output, kind: "tap", events: 2)
        try await session.requireButtonTap(after: before)
        let after = try session.document.read()
        try #require(after.pid == before.pid && after.generation == before.generation && after.activeWindowTouches == 0)
        return try session.decodeAgent(output.output)
    }

    private func requireNoInput(_ output: CommandOutput, session: PlaygroundAgentFeatureSession,
                                before: PlaygroundControlsDocument, codes: [String]) throws {
        let result = try session.decodeAgent(output.output)
        try #require(output.exitCode != 0 && result.didError && result.data.action == nil
            && result.data.capture == nil && result.data.cache.requiresRefresh)
        try #require(codes.contains(result.error?.code ?? ""))
        try #require(try session.document.read().inputState == before.inputState)
    }
}

private struct AutomaticPIDBatchEnvelope: Decodable {
    struct Payload: Decodable { let batch: Batch }
    struct Batch: Decodable {
        struct Step: Decodable {
            let index: Int
            let status: String
            let requestID: UUID
            let context: DuoContext?
            let receipt: AgentPlaygroundResult.Action?
        }
        let totalSteps: Int
        let completedSteps: Int
        let stoppedAt: Int?
        let replayed: Bool
        let rolledBack: Bool
        let steps: [Step]
    }
    let data: Payload
}
