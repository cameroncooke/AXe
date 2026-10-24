import Foundation
import Testing

enum PlaygroundAgentTypeVariant: String, Sendable { case reference, exactFocusID, stale, wrongPID, unfocused, file, stdin }

@Suite("Playground Agent Type E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentTypeTests {
    @Test("Agent typing uses a fresh focused field and preserves exact file/stdin text", arguments: [
        PlaygroundAgentTypeVariant.reference, .exactFocusID, .stale, .wrongPID, .unfocused, .file, .stdin,
    ])
    func type(_ variant: PlaygroundAgentTypeVariant) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "agent-type-" + variant.rawValue)
        if variant != .unfocused { try await session.focusField() }
        let capture = try await session.capture()
        var arguments = ["type", "q7"] + (try session.contextArguments(capture, identifier: "feature.text"))
        var code: String?
        var message: String?
        switch variant {
        case .reference: break
        case .exactFocusID:
            arguments = ["type", "q7", "--agent", "--expected-pid", String(session.pid), "--focus-id", "feature.text"]
        case .stale:
            _ = try await session.command(["type", "a"])
            _ = try await session.document.waitFor("real edit before stale type") { $0.text == "a" }
            _ = try await session.capture()
            code = "snapshotMissing"
        case .wrongPID:
            let index = try #require(arguments.firstIndex(of: "--expected-pid"))
            arguments[index + 1] = String(session.pid + 1)
            code = "observationFailed"
            message = "processChanged"
        case .unfocused: code = "unsupportedReference"
        case .file:
            let source = session.artifacts.appendingPathComponent("agent-text.txt")
            try Data("q7".utf8).write(to: source)
            arguments = ["type", "--file", source.path] + (try session.contextArguments(capture, identifier: "feature.text"))
        case .stdin:
            arguments = ["type", "--stdin"] + (try session.contextArguments(capture, identifier: "feature.text"))
        }
        let before = try session.document.read()
        let result: CommandOutput
        if variant == .stdin {
            let input = try PlaygroundStdinProcess(executable: TestHelpers.getAxePath(), arguments: arguments + ["--udid", session.agent.udid],
                data: Data("q7".utf8), directory: session.artifacts, name: "agent-type-stdin")
            do { try input.start(); result = try await input.wait(); await input.finish() }
            catch { await input.finish(); throw error }
        } else { result = try await session.command(arguments, allowFailure: code != nil) }
        if let code { try session.requireRefusal(result, before: before, code: code, message: message) }
        else {
            try session.requireHIDSuccess(result, kind: "typeText", events: 4)
            let after = try await session.document.waitFor("exact agent text") { $0.text == "q7" }
            try #require(after.count("textChanged") == before.count("textChanged") + 2 && after.textFocused)
            try #require(after.inputState.windowTouchTrace == before.inputState.windowTouchTrace && after.activeWindowTouches == 0)
        }
        try capture.requireUnexpired("after agent type check")
    }

    @Test("Agent coordinate tap uses the current snapshot and a fresh real Button frame")
    func coordinateTap() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "agent-coordinate-tap")
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element("feature.tap", in: state))
        let capture = try await session.capture()
        let before = try session.document.read()
        let result = try await session.command(["tap", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", capture.capture.snapshotID.uuidString, "-x", String(frame.x + frame.width / 2),
            "-y", String(frame.y + frame.height / 2), "--tap-style", "physical"])
        try session.requireHIDSuccess(result, kind: "tap", events: 2)
        try await session.requireButtonTap(after: before)
        try capture.requireUnexpired("after agent point tap")
    }
}
