import Foundation
import Testing

@Suite("Playground Agent Keyboard Observation E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentObservationTests {
    @Test("An unfocused normal field reports unknown keyboard visibility")
    func keyboardUnfocused() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: #function)
        let raw = try await session.command(["describe-ui"])
        try #require(!raw.output.contains("axe.output.agent-result"))
        _ = try UIStateParser.parseDescribeUIRoots(raw.output)
        let observation = try await capture(session)
        try #require(observation.keyboard.state == "unknown")
    }

    @Test("A focused normal field reports real keyboard key evidence")
    func keyboardFocusedFresh() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: #function)
        try await session.focusField()
        let observation = try await capture(session)
        try requireVisible(observation.keyboard)
    }

    @Test("Focused keyboard metadata survives paging and cache reuse")
    func keyboardFocusedPageAndReuse() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: #function)
        try await session.focusField()
        let observation = try await capture(session)
        try requireVisible(observation.keyboard)
        try await requirePageAndReuse(session, original: observation)
    }

    @Test("Normal dismissal changes keyboard visibility back to unknown")
    func keyboardDismissedFresh() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: #function)
        try await session.focusField()
        try await session.dismissKeyboard()
        let observation = try await capture(session)
        try #require(observation.keyboard.state == "unknown")
    }

    @Test("Dismissed keyboard metadata survives paging and cache reuse")
    func keyboardDismissedPageAndReuse() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: #function)
        try await session.focusField()
        try await session.dismissKeyboard()
        let observation = try await capture(session)
        try #require(observation.keyboard.state == "unknown")
        try await requirePageAndReuse(session, original: observation)
    }

    @Test("Focus and dismissal change the actual field and release both taps")
    func realFieldFocusAndDismiss() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: #function)
        let before = try session.document.read()
        try #require(!before.textFocused && before.activeWindowTouches == 0)
        try await session.focusField()
        let focused = try session.document.read()
        try #require(focused.textFocused && focused.activeWindowTouches == 0)
        try await session.dismissKeyboard()
        let dismissed = try session.document.read()
        try #require(!dismissed.textFocused && dismissed.activeWindowTouches == 0)
        try #require(dismissed.text == before.text && dismissed.count("tap") == before.count("tap"))
        _ = try session.contacts(after: before, in: focused, count: 2)
        _ = try session.contacts(after: focused, in: dismissed, count: 1)
    }

    private func capture(_ session: PlaygroundAgentFeatureSession,
                         options: [String] = [], expectedCache: String? = nil) async throws -> KeyboardCapture {
        let result = try await session.command(["describe-ui", "--agent", "--expected-pid", String(session.pid)] + options)
        let envelope = try decode(result.output)
        try #require(result.exitCode == 0 && !envelope.didError)
        if let expectedCache { try #require(envelope.data.cache.status == expectedCache) }
        let value = try #require(envelope.data.capture)
        try #require(value.keyboard.source == "accessibility-key-signals"
            && value.keyboard.scope == "selected-application")
        try requireConsistentEvidence(value.keyboard)
        return value
    }

    private func requirePageAndReuse(_ session: PlaygroundAgentFeatureSession,
                                     original: KeyboardCapture) async throws {
        let before = try session.document.read()
        let page = try await capture(session, options: ["--snapshot-id", original.snapshotID.uuidString,
            "--row-offset", "1", "--row-limit", "1"], expectedCache: "validated")
        try #require(page.snapshotID == original.snapshotID && page.keyboard == original.keyboard
            && page.rowOffset == 1 && page.rowLimit == 1)
        let result = try await session.command(["describe-ui", "--agent", "--expected-pid", String(session.pid),
            "--since-screen-hash", original.screenHash, "--row-limit", "1"])
        let reused = try decode(result.output)
        let value = try #require(reused.data.capture)
        try #require(!reused.didError && reused.data.cache.status == "reused")
        try #require(value.snapshotID == original.snapshotID && value.keyboard == original.keyboard
            && value.type == "runtime-snapshot-unchanged")
        try requireConsistentEvidence(value.keyboard)
        let after = try session.document.read()
        try #require(after.inputState == before.inputState)
    }

    private func requireConsistentEvidence(_ keyboard: KeyboardObservation) throws {
        let signals = keyboard.signals
        try #require(signals.idChromeCount >= 0 && signals.letterKeyCount >= 0 && signals.chromeKeyCount >= 0)
        let visible = signals.idChromeCount >= 2 || signals.globeSeen
            || signals.letterKeyCount >= 10 || signals.chromeKeyCount >= 3 || signals.numericKeyCount == 10
        try #require(keyboard.state == (visible ? "likelyVisible" : "unknown"))
    }

    private func requireVisible(_ keyboard: KeyboardObservation) throws {
        try #require(keyboard.state == "likelyVisible")
        try #require(keyboard.signals.idChromeCount >= 2 || keyboard.signals.globeSeen
            || keyboard.signals.letterKeyCount >= 10 || keyboard.signals.chromeKeyCount >= 3 || keyboard.signals.numericKeyCount == 10)
    }

    private func decode(_ output: String) throws -> KeyboardEnvelope {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(KeyboardEnvelope.self, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No keyboard observation envelope: \(output)")
    }
}

private struct KeyboardEnvelope: Decodable {
    struct Payload: Decodable {
        let capture: KeyboardCapture?
        let cache: Cache
    }
    struct Cache: Decodable { let status: String }
    let didError: Bool
    let data: Payload
}

private struct KeyboardCapture: Decodable {
    let type: String
    let rowOffset: Int
    let rowLimit: Int
    let snapshotID: UUID
    let screenHash: String
    let keyboard: KeyboardObservation
}

private struct KeyboardObservation: Decodable, Equatable {
    struct Signals: Decodable, Equatable {
        let idChromeCount: Int
        let globeSeen: Bool
        let letterKeyCount: Int
        let chromeKeyCount: Int
        let numericKeyCount: Int?
    }
    let state: String
    let source: String
    let scope: String
    let signals: Signals
}
