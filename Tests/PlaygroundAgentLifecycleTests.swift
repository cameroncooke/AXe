import Foundation
import Testing

/// Run alone. Every call starts a new CLI process against the same warm simulator.
@Suite("Playground Agent Reference Lifecycle E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentLifecycleTests {
    @Test("References survive 35 idle seconds and expire at their original deadline")
    func idleContinuityAndAbsoluteExpiry() async throws {
        let session = try await open("idle-expiry")
        let initial = try await session.capture()
        let receivedAt = ProcessInfo.processInfo.systemUptime
        let button = try session.reference("feature.tap", in: initial.capture)
        let before = try session.document.read()
        try #require(initial.capture.expiresInSeconds > 50)

        // No CLI request keeps the broker active during this interval.
        try await wait(until: receivedAt + 35)
        let validated = try await session.command(["describe-ui", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", initial.capture.snapshotID.uuidString])
        let result = try session.decodeAgent(validated.output)
        let current = try #require(result.data.capture)
        try #require(!result.didError && result.data.action == nil && result.data.cache.status == "validated")
        try #require(current.snapshotID == initial.capture.snapshotID && current.screenHash == initial.capture.screenHash)
        try #require(current.seq == initial.capture.seq && current.expiresInSeconds > 0)
        try #require(current.expiresInSeconds < initial.capture.expiresInSeconds - 30,
            "A validation read must not renew the reference lifetime.")
        try #require(try session.reference("feature.tap", in: current) == button)
        try #require(try session.document.read().inputState == before.inputState)

        let reused = try await session.command(["describe-ui", "--agent", "--expected-pid", String(session.pid),
            "--since-screen-hash", initial.capture.screenHash])
        let reusedResult = try session.decodeAgent(reused.output)
        let reusedCapture = try #require(reusedResult.data.capture)
        try #require(!reusedResult.didError && reusedResult.data.action == nil)
        try #require(reusedResult.data.cache.status == "reused" && !reusedResult.data.cache.requiresRefresh)
        try #require(reusedCapture.type == "runtime-snapshot-unchanged" && reusedCapture.rs == current.rs)
        try #require(reusedCapture.snapshotID == current.snapshotID && reusedCapture.screenHash == current.screenHash)
        try #require(reusedCapture.seq > current.seq && reusedCapture.expiresInSeconds > 0)
        try #require(reusedCapture.expiresInSeconds < current.expiresInSeconds,
            "An unchanged hash read must not renew the reference lifetime.")
        try #require(reusedCapture.targets.isEmpty && reusedCapture.scroll.isEmpty && reusedCapture.text.isEmpty)
        try #require(try session.document.read().inputState == before.inputState)

        // Waiting from receipt gives a later deadline than the server's capture time.
        try await wait(until: receivedAt + initial.capture.expiresInSeconds + 1)
        let expired = try await session.command(tapArguments(session, snapshot: initial.capture, ref: button), allowFailure: true)
        let refusal = try session.decodeAgent(expired.output)
        try #require(refusal.error?.code == "snapshotExpired" || refusal.error?.code == "snapshotMissing")
        try requireNoInput(refusal, output: expired, session: session, before: before)

        let fresh = try await session.capture()
        try #require(fresh.capture.snapshotID != initial.capture.snapshotID)
        try await tapButton(session, capture: fresh.capture, after: before)
    }

    @Test("An old caller cannot remove the newer caller's reference table")
    func plainCaptureReplacesSharedTable() async throws {
        let session = try await open("shared-table")
        let firstCaller = try AgentPlaygroundSession()
        let secondCaller = try AgentPlaygroundSession()
        let before = try session.document.read()
        let firstStarted = ProcessInfo.processInfo.systemUptime
        let first = try #require(try await firstCaller.capture(pid: session.pid).data.capture)
        let firstLifetime = try AgentPlaygroundTimedCapture(capture: first, requestStartedUptime: firstStarted)
        let second = try #require(try await secondCaller.capture(pid: session.pid).data.capture)
        try #require(first.snapshotID != second.snapshotID && first.screenHash == second.screenHash)
        try #require(second.seq > first.seq)

        let validated = try await session.command(["describe-ui", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", second.snapshotID.uuidString])
        let sameTable = try #require(try session.decodeAgent(validated.output).data.capture)
        try #require(sameTable.snapshotID == second.snapshotID)
        try #require(try session.document.read().inputState == before.inputState)

        let ref = try session.reference("feature.tap", in: first)
        let stale = try await session.command(tapArguments(session, snapshot: first, ref: ref), allowFailure: true)
        let refusal = try session.decodeAgent(stale.output)
        try #require(refusal.error?.code == "snapshotMissing")
        try firstLifetime.requireUnexpired("after shared-table replacement refusal")
        try requireNoInput(refusal, output: stale, session: session, before: before)
        let afterRefusal = try await session.command(["describe-ui", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", second.snapshotID.uuidString])
        let preserved = try session.decodeAgent(afterRefusal.output)
        try #require(!preserved.didError && preserved.data.capture?.snapshotID == second.snapshotID)
        let secondRef = try session.reference("feature.tap", in: second)
        let unknown = try await session.command(["tap", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", UUID().uuidString, "--ref", secondRef, "--tap-style", "physical"], allowFailure: true)
        let unknownRefusal = try session.decodeAgent(unknown.output)
        try #require(unknownRefusal.error?.code == "snapshotMissing")
        try requireNoInput(unknownRefusal, output: unknown, session: session, before: before)
        // The refused caller must not force the newer caller to capture again.
        try await tapButton(session, capture: second, after: before)
    }

    @Test("An action returns replacement references that the next CLI call can use")
    func actionReplacementWorksAcrossCalls() async throws {
        let session = try await open("action-replacement")
        let initial = try await session.capture()
        let before = try session.document.read()
        let first = try await tapButton(session, capture: initial.capture, after: before)
        let replacement = try #require(first.data.capture,
            "The stable playground Button must return a usable replacement capture.")
        try #require(replacement.snapshotID != initial.capture.snapshotID)
        try #require(!first.data.cache.requiresRefresh)
        let afterFirst = try session.document.read()
        let second = try await tapButton(session, capture: replacement, after: afterFirst)
        let secondReplacement = try #require(second.data.capture)
        try #require(secondReplacement.snapshotID != replacement.snapshotID && !second.data.cache.requiresRefresh)

        let afterSecond = try session.document.read()
        let oldRef = try session.reference("feature.tap", in: initial.capture)
        let stale = try await session.command(tapArguments(session, snapshot: initial.capture, ref: oldRef), allowFailure: true)
        let refusal = try session.decodeAgent(stale.output)
        try #require(refusal.error?.code == "snapshotMissing")
        try initial.requireUnexpired("after action-replacement refusal")
        try requireNoInput(refusal, output: stale, session: session, before: afterSecond)
        try await tapButton(session, capture: secondReplacement, after: afterSecond)
    }

    @Test("A selected raw read invalidates agent references and fresh references recover")
    func selectedReadInvalidatesReferences() async throws {
        let session = try await open("selected-invalidation")
        let initial = try await session.capture()
        let before = try session.document.read()
        let selected = try await session.command(["describe-ui", "--expected-pid", String(session.pid)] + session.selectedFlags)
        let read = try session.rawReceipt(selected.output)
        try #require(read.outcome == "ready" && read.enqueuedEventCount == 0 && read.cleanup == "notNeeded" && read.error == nil)
        try #require(try session.document.read().inputState == before.inputState)
        let ref = try session.reference("feature.tap", in: initial.capture)
        let stale = try await session.command(tapArguments(session, snapshot: initial.capture, ref: ref), allowFailure: true)
        let refusal = try session.decodeAgent(stale.output)
        try #require(refusal.error?.code == "snapshotMissing")
        try initial.requireUnexpired("after selected-read invalidation refusal")
        try requireNoInput(refusal, output: stale, session: session, before: before)
        let fresh = try await session.capture()
        try await tapButton(session, capture: fresh.capture, after: before)
    }

    @Test("A raw edit rejects saved input before any new capture")
    func rawMutationRejectsReferenceWithoutRecapture() async throws {
        let session = try await open("raw-mutation")
        try await session.focusField()
        let initial = try await session.capture()
        let button = try session.reference("feature.tap", in: initial.capture)
        let before = try session.document.read()
        try #require(before.text.isEmpty && before.textFocused && before.activeWindowTouches == 0)

        _ = try await session.rawCommand(["key", "4"])
        let changed = try await session.document.waitFor("one real raw lowercase edit") { $0.text == "a" }
        try #require(changed.count("textChanged") == before.count("textChanged") + 1)
        try #require(changed.textFocused && changed.activeWindowTouches == 0)
        try #require(changed.windowTouchTrace == before.windowTouchTrace)
        try #require(changed.count("tap") == before.count("tap")
            && changed.slider == before.slider && changed.switchOn == before.switchOn)

        // No capture or AX read occurs between the raw edit and this saved action.
        try initial.requireUnexpired("before saved input after a raw edit")
        let stale = try await session.command(tapArguments(session, snapshot: initial.capture, ref: button), allowFailure: true)
        let refusal = try session.decodeAgent(stale.output)
        try #require(refusal.error?.code == "snapshotMissing" || refusal.error?.code == "screenChanged")
        try requireNoInput(refusal, output: stale, session: session, before: changed)
        try initial.requireUnexpired("after saved input refusal after a raw edit")

        // Keyboard focus can scroll the counter above its visible viewport.
        // Use the normal toolbar before capturing the recovery target.
        try await session.show("feature.showPad")
        let recoveryBefore = try session.document.read()
        try #require(recoveryBefore.text == "a"
            && recoveryBefore.count("textChanged") == changed.count("textChanged")
            && recoveryBefore.textFocused && recoveryBefore.activeWindowTouches == 0)
        let fresh = try await session.capture()
        try #require(fresh.capture.snapshotID != initial.capture.snapshotID)
        try await tapButton(session, capture: fresh.capture, after: recoveryBefore)
        let after = try session.document.read()
        try #require(after.text == "a" && after.count("textChanged") == changed.count("textChanged"))
    }

    @Test("Concurrent capture and input are refused while an agent touch is held")
    func concurrentCallsDoNotInterruptOwnedInput() async throws {
        let session = try await open("concurrent-busy")
        let initial = try await session.capture()
        let before = try session.document.read()
        // The canonical view: the receipt check reads its kind, cleanup and cache state.
        let arguments = canonicalAgentArguments(["touch", "--down", "--up", "--delay", "4"]
            + (try session.contextArguments(initial, identifier: "feature.tap")))
            + ["--udid", session.agent.udid]
        try JSONEncoder().encode(arguments).write(to: session.artifacts.appendingPathComponent("owned-hold-argv.json"))
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: arguments,
            directory: session.artifacts, name: "owned-hold")
        do {
            try process.start()
            let held = try await session.document.waitFor("the agent owns one actual touch") {
                $0.activeWindowTouches == 1 && $0.windowTouchTrace.count > before.windowTouchTrace.count
            }
            let added = Array(held.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
            try #require(added.count == 1 && added[0].phase == "windowTouchBegan" && added[0].hitView == "feature.tap")
            try #require(held.count("tap") == before.count("tap") && process.isRunning)

            let ref = try session.reference("feature.tap", in: initial.capture)
            let competingCalls = [
                ["describe-ui", "--agent", "--expected-pid", String(session.pid)],
                tapArguments(session, snapshot: initial.capture, ref: ref),
            ]
            for arguments in competingCalls {
                let current = try session.document.read()
                try #require(process.isRunning && current.activeWindowTouches == 1,
                    "The owned touch ended before the competing request.")
                let output = try await session.command(arguments, allowFailure: true)
                let result = try session.decodeAgent(output.output)
                try #require(result.error?.code == "busy")
                try requireNoInput(result, output: output, session: session, before: held)
                try #require(process.isRunning, "The owned touch ended before its busy refusal returned.")
            }

            try await process.wait(timeout: 30)
            let completed = CommandOutput(output: try process.output(), exitCode: process.exitCode)
            try session.requireHIDSuccess(completed, kind: "hold", events: 2)
            try await session.requireButtonTap(after: before)
            let afterHold = try session.document.read()
            _ = try session.contacts(after: before, in: afterHold, count: 1, minimumHold: 3.8)
            let fresh = try await session.capture()
            try await tapButton(session, capture: fresh.capture, after: afterHold)
        } catch {
            await process.finish()
            throw error
        }
        await process.finish()
    }

    private func open(_ name: String) async throws -> PlaygroundAgentFeatureSession {
        try await PlaygroundAgentFeatureSession.open(caseName: "lifecycle-" + name,
            position: isDuoPlaygroundE2EEnabled ? .inner90 : .outer0)
    }

    private func tapArguments(_ session: PlaygroundAgentFeatureSession, snapshot: AgentPlaygroundCapture, ref: String) -> [String] {
        ["tap", "--agent", "--expected-pid", String(session.pid), "--snapshot-id", snapshot.snapshotID.uuidString,
         "--ref", ref, "--tap-style", "physical"]
    }

    @discardableResult
    private func tapButton(_ session: PlaygroundAgentFeatureSession, capture: AgentPlaygroundCapture,
                           after before: PlaygroundControlsDocument) async throws -> AgentPlaygroundResult {
        let ref = try session.reference("feature.tap", in: capture)
        let output = try await session.command(tapArguments(session, snapshot: capture, ref: ref))
        try session.requireHIDSuccess(output, kind: "tap", events: 2)
        try await session.requireButtonTap(after: before)
        return try session.decodeAgent(output.output)
    }

    private func requireNoInput(_ result: AgentPlaygroundResult, output: CommandOutput,
                                session: PlaygroundAgentFeatureSession, before: PlaygroundControlsDocument) throws {
        try #require(output.exitCode != 0 && result.didError && result.data.action == nil)
        try #require(result.data.capture == nil && result.data.cache.requiresRefresh)
        try #require(try session.document.read().inputState == before.inputState,
            "A refused reference changed real app state or touch history.")
    }

    private func wait(until deadline: TimeInterval) async throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            try await Task.sleep(for: .seconds(min(remaining, 20)))
        }
    }
}
