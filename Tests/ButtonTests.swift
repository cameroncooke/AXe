import Testing
import Foundation

@Suite("Button Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct ButtonTests {
    @Test("Home button press")
    func homeButtonPress() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runAxeCommand("button home", simulatorUDID: defaultSimulatorUDID)
        
        // Note: Cannot assert UI state as home button takes us out of the app
        // This test verifies the command executes without error
    }
    
    @Test("Lock button press")
    func lockButtonPress() async throws {
        // Act
        try await TestHelpers.runAxeCommand("button lock", simulatorUDID: defaultSimulatorUDID)
        
        // Note: Cannot assert UI state as lock button locks the device
        // This test verifies the command executes without error
    }
    
    @Test("Side button press")
    func sideButtonPress() async throws {
        // Act
        try await TestHelpers.runAxeCommand("button side-button", simulatorUDID: defaultSimulatorUDID)
        
        // Note: Side button behavior varies by device
        // This test verifies the command executes without error
    }
    
    @Test("Button press with duration")
    func buttonPressWithDuration() async throws {
        // Act
        let startTime = Date()
        try await TestHelpers.runAxeCommand("button lock --duration 2", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        
        // Assert timing
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Command should take at least 2 seconds with delays")
    }
}
