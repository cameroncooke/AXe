import CryptoKit
import Darwin
import Foundation
import Testing

enum PlaygroundClipboardVariant: String, Sendable {
    case empty, invalidUTF8, oversized, invalidUDID, unsupportedAgent, stagedOnly, unicodePaste, interrupt, terminate
}

@Suite("Playground Clipboard E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundClipboardTests {
    @Test("Clipboard copy validates bytes and only a separate native Paste inserts them", arguments: [
        PlaygroundClipboardVariant.empty, .invalidUTF8, .oversized, .invalidUDID, .unsupportedAgent,
        .stagedOnly, .unicodePaste, .interrupt, .terminate,
    ])
    func copy(_ variant: PlaygroundClipboardVariant) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "clipboard-" + variant.rawValue)
        let cli = try TestHelpers.getAxePath()
        let unicode = "AXe 日本語 😀 e\u{0301}"
        let payload: Data
        switch variant {
        case .empty: payload = Data()
        case .invalidUTF8: payload = Data([0xff, 0xfe])
        case .oversized: payload = Data(repeating: 65, count: 65_537)
        default: payload = Data(unicode.utf8)
        }
        var args = ["clipboard", "copy", "--stdin", "--udid", variant == .invalidUDID ? "not-a-uuid" : session.agent.udid]
        if variant == .unsupportedAgent { args += ["--agent"] }
        let cancelled = variant == .interrupt || variant == .terminate
        let input = try PlaygroundStdinProcess(executable: cli, arguments: args, data: cancelled ? nil : payload,
            directory: session.artifacts, name: "clipboard")
        let before = try session.document.read()
        do {
            try input.start()
            if cancelled {
                try await Task.sleep(nanoseconds: 300_000_000)
                try #require(input.isRunning && !input.inputClosed)
                try input.signal(variant == .interrupt ? SIGINT : SIGTERM)
            }
            let result = try await input.wait(timeout: cancelled ? 5 : 40)
            if cancelled {
                try #require(result.exitCode != 0 && !input.inputClosed)
                let output = try input.stdoutBytes()
                try #require(output.isEmpty)
                let after = try session.document.read()
                try #require(after.inputState == before.inputState)
            } else if [.empty, .invalidUTF8, .oversized, .invalidUDID, .unsupportedAgent].contains(variant) {
                try #require(result.exitCode != 0)
                let expected = variant == .oversized ? "exceeds 64 KiB" : variant == .invalidUDID ? "valid simulator UUID"
                    : variant == .unsupportedAgent ? "Unknown option" : "valid UTF-8 bytes"
                try #require(result.output.contains(expected))
                let after = try session.document.read()
                try #require(after.inputState == before.inputState)
            } else {
                try #require(result.exitCode == 0)
                let receipt = try JSONDecoder().decode(ClipboardAcceptanceReceipt.self, from: input.stdoutBytes())
                try #require(receipt.source == "appleCoreDevicePasteboard" && receipt.operation == "copy"
                    && receipt.outcome == "stagedAndVerified" && receipt.verified && !receipt.inserted
                    && receipt.clipboardReplaced && receipt.sharedClipboardMayChange)
                try #require(receipt.simulatorUDID == UUID(uuidString: session.agent.udid))
                try #require(receipt.utf8Length == payload.count && receipt.sha256 == Self.digest(payload))
                let staged = try session.document.read()
                try #require(staged.inputState == before.inputState)
                if variant == .unicodePaste {
                    try await session.focusField()
                    let capture = try await session.capture()
                    let menu = try await session.command(["key", "101"] + (try session.contextArguments(capture, identifier: "feature.text")))
                    try session.requireHIDSuccess(menu, kind: "keyPress", events: 2)
                    _ = try await session.core.waitFor("native Paste control") { state in
                        session.core.elements(in: state).contains { $0.type == "Button" && $0.label == "Paste" }
                    }
                    let beforePaste = try session.document.read()
                    let pasted = try await session.command(["tap", "--agent", "--expected-pid", String(session.pid),
                        "--label", "Paste", "--element-type", "Button"])
                    try session.requireHIDSuccess(pasted, kind: "tap", events: 2)
                    let after = try await session.document.waitFor("exact Unicode after a native Paste") {
                        Array($0.text.utf8) == Array(payload) && $0.activeWindowTouches == 0
                    }
                    try #require(after.count("textChanged") == beforePaste.count("textChanged") + 1)
                    _ = try session.contacts(after: beforePaste, in: after, count: 1)
                    let fresh = try await session.capture()
                    try requireAgentCaptureValue(fresh.capture, identifier: "feature.text", expected: unicode,
                        action: "typeText", pid: session.pid, udid: session.agent.udid)
                    let rows = fresh.capture.targets.map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
                    let field = try #require(rows.first { $0.count == 6 && $0[5] == "feature.text" })
                    try #require(Self.digest(Data(field[4].utf8)) == Self.digest(payload))
                }
            }
            await input.finish()
        } catch { await input.finish(); throw error }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
private struct ClipboardAcceptanceReceipt: Decodable {
    let source: String
    let operation: String
    let outcome: String
    let simulatorUDID: UUID
    let utf8Length: Int
    let sha256: String
    let verified: Bool
    let inserted: Bool
    let clipboardReplaced: Bool
    let sharedClipboardMayChange: Bool
}
