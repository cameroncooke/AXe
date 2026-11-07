import Foundation
import Testing

// Kept in its own file: swift test --filter PlaygroundAgentFocusAndTypeTests selects every
// suite in the matching file, and this suite is skipped without a Duo simulator.
@Suite("Playground Duo Agent Focus And Type E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoAgentFocusAndTypeTests {
    @Test("Find, focus and type on the outer screen", arguments: PlaygroundFocusField.allCases)
    private func outerScreen(_ field: PlaygroundFocusField) async throws {
        try await PlaygroundFocusTypeCheck.run(field: field, position: .outer0)
    }

    @Test("Find, focus and type on the inner landscape screen", arguments: PlaygroundFocusField.allCases)
    private func innerLandscape(_ field: PlaygroundFocusField) async throws {
        try await PlaygroundFocusTypeCheck.run(field: field, position: .inner90)
    }
}
