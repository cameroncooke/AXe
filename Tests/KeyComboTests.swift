import Testing
import Foundation

@Suite("Key Combo Command Tests")
struct KeyComboTests {
    @Test("Cmd+A selects all text")
    func cmdA() async throws {
        // Arrange - navigate to text input and type some text
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        try await TestHelpers.runAxeCommand("type \"hello world\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Act - Cmd+A to select all, then Backspace to delete
        try await TestHelpers.runAxeCommand("key-combo --modifiers 227 --key 4", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await TestHelpers.runAxeCommand("key 42", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Assert - text field should be empty after select all + delete
        let uiState = try await TestHelpers.getUIState()
        let textField = UIStateParser.findElement(in: uiState) { $0.type == "TextField" }
        #expect(textField?.value == nil || textField?.value == "")
    }

    @Test("Single modifier key combo")
    func singleModifier() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "key-press")

        // Act - press Cmd+A (modifier 227, key 4)
        try await TestHelpers.runAxeCommand("key-combo --modifiers 227 --key 4", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Assert - the key press should have been registered
        let uiState = try await TestHelpers.getUIState()
        let keyPressElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last Key:")
        #expect(keyPressElement != nil, "A key press should have been registered")
    }

    @Test("Multiple modifier key combo")
    func multipleModifiers() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "key-press")

        // Act - press Cmd+Shift+A (modifiers 227,225, key 4)
        try await TestHelpers.runAxeCommand("key-combo --modifiers 227,225 --key 4", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Assert - the key press should have been registered
        let uiState = try await TestHelpers.getUIState()
        let keyPressElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last Key:")
        #expect(keyPressElement != nil, "A key press should have been registered")
    }

    @Test("Empty modifiers fails validation")
    func emptyModifiers() async throws {
        // Act & Assert - Should fail with validation error
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runAxeCommand("key-combo --modifiers \"\" --key 4", simulatorUDID: defaultSimulatorUDID)
        }
    }

    @Test("Out-of-range modifier fails validation")
    func outOfRangeModifier() async throws {
        // Act & Assert - Modifier keycode 256 is out of valid range (0-255)
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runAxeCommand("key-combo --modifiers 256 --key 4", simulatorUDID: defaultSimulatorUDID)
        }
    }

    @Test("Out-of-range key fails validation")
    func outOfRangeKey() async throws {
        // Act & Assert - Key 300 is out of valid range (0-255)
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runAxeCommand("key-combo --modifiers 227 --key 300", simulatorUDID: defaultSimulatorUDID)
        }
    }

    @Test("Too many modifiers fails validation")
    func tooManyModifiers() async throws {
        // Act & Assert - 9 modifiers exceeds the limit of 8
        let modifiers = Array(repeating: "227", count: 9).joined(separator: ",")
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runAxeCommand("key-combo --modifiers \(modifiers) --key 4", simulatorUDID: defaultSimulatorUDID)
        }
    }
}
