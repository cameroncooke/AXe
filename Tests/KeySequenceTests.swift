import Testing
import Foundation

@Suite("KeySequence Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct KeySequenceTests {
    @Test("Basic key sequence execution")
    func basicKeySequence() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "key-sequence")

        // Act
        try await TestHelpers.runAxeCommand("key-sequence --keycodes 11,8,15,15,18", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textField = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField"
        }
        #expect(textField != nil, "Should find text field element")
    }

    @Test("Key sequence with delay")
    func keySequenceWithDelay() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "key-sequence")

        // Act
        let startTime = Date()
        try await TestHelpers.runAxeCommand("key-sequence --keycodes 4,5 --delay 0.5", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 0.5, "Command should take at least the specified delay time")

        let uiState = try await TestHelpers.getUIState()
        let textField = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField"
        }
        #expect(textField != nil, "Should find text field element for key sequence input")
    }

    @Test("Empty keycode sequence fails validation")
    func emptyKeycodeSequence() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "key-sequence")
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runAxeCommand("key-sequence --keycodes \"\"", simulatorUDID: defaultSimulatorUDID)
        }
    }

    @Test("Invalid keycode fails validation")
    func invalidKeycode() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "key-sequence")
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runAxeCommand("key-sequence --keycodes 11,256,15", simulatorUDID: defaultSimulatorUDID)
        }
    }

    @Test("Negative delay fails validation")
    func negativeDelay() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "key-sequence")
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runAxeCommand("key-sequence --keycodes 11,8,15,15,18 --delay -0.5", simulatorUDID: defaultSimulatorUDID)
        }
    }

    @Test("Too many keycodes fails validation")
    func tooManyKeycodes() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "key-sequence")
        let keycodes = Array(repeating: "4", count: 101).joined(separator: ",")
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runAxeCommand("key-sequence --keycodes \(keycodes)", simulatorUDID: defaultSimulatorUDID)
        }
    }
}