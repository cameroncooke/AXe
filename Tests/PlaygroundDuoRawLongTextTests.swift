import Foundation
import Testing

@Suite("Playground Duo Raw Long Text E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoRawLongTextTests {
    @Test("Raw text above 256 bytes preserves all characters and releases modifiers")
    func exactLongText() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(
            caseName: "duo-raw-long-text", position: .inner270)
        try await session.focusField()
        let before = try session.document.read()
        try #require(before.text.isEmpty && before.textFocused && before.activeWindowTouches == 0)
        let text = String(repeating: "aQ7", count: 100)
        try #require(text.utf8.count == 300)

        // The normal raw command follows the agent focus taps without another AX read.
        _ = try await session.rawCommand(["type", text])
        let typed = try await session.document.waitFor("all 300 raw characters and callbacks") {
            $0.text == text && $0.count("textChanged") == before.count("textChanged") + text.count
        }
        try requireOnlyTextChanges(typed, after: before, text: text)

        // A lowercase key after the uppercase text proves the modifier has no later effect.
        _ = try await session.rawCommand(["key", "6"])
        let finished = try await session.document.waitFor("one lowercase key after long raw text") {
            $0.text == text + "c" && $0.count("textChanged") == typed.count("textChanged") + 1
        }
        try requireOnlyTextChanges(finished, after: typed, text: text + "c")
        try await session.requireNativeFieldValue(text + "c")
    }

    private func requireOnlyTextChanges(_ after: PlaygroundControlsDocument,
                                        after before: PlaygroundControlsDocument, text: String) throws {
        var expectedCounts = before.counts
        expectedCounts["textChanged"] = before.count("textChanged") + text.count - before.text.count
        try #require(after.pid == before.pid && after.generation == before.generation)
        try #require(after.text == text && after.textFocused && after.activeWindowTouches == 0)
        try #require(after.counts == expectedCounts)
        try #require(after.inputState.windowTouchTrace == before.inputState.windowTouchTrace)
        try #require(after.windowTraceDropped == before.windowTraceDropped)
        try #require(after.slider == before.slider && after.switchOn == before.switchOn
            && after.advancedSliders == before.advancedSliders)
    }
}
