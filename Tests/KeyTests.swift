import Testing
import Foundation

@Suite("Key Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct KeyTests {
    @Test("Basic key press updates key label")
    func basicKeyPress() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "key-press")

        // Act
        try await TestHelpers.runAxeCommand("key 4", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)    

        // Assert
        let uiState = try await TestHelpers.getUIState()
        let keyPressElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last Key:")
        #expect(keyPressElement?.label == "Last Key: a (4)")
    }

    @Test("Special key press updates key label")
    func specialKeyPress() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "key-press")

        // Act
        try await TestHelpers.runAxeCommand("key 40", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Assert
        let uiState = try await TestHelpers.getUIState()
        let keyPressElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last Key:")
        #expect(keyPressElement?.label == "Last Key: Return (40)")
    }

    @Test("Key press with duration")
    func keyPressWithDuration() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "key-press")

        // Act
        let startTime = Date()
        try await TestHelpers.runAxeCommand("key 4 --duration 2", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()

        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Command should take at least 2 seconds with duration")

        let uiState = try await TestHelpers.getUIState()
        let keyPressElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last Key:")
        #expect(keyPressElement?.label == "Last Key: a (4)")
    }
}
