import Testing
import Foundation

@Suite("Tap Command Tests")
struct TapTests {
    @Test("Basic tap registers on screen")
    func basicTap() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runAxeCommand("tap -x 200 -y 400", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        let tapLocationElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Location:")
        #expect(tapCountElement?.label == "Tap Count: 1", "Tap count should be 1")
        #expect(tapLocationElement?.label == "Tap Location: (200, 400)", "Tap location should be (200, 400)")
    }

    @Test("Tap by AXUniqueId navigates back to home")
    func tapByIDNavigatesBack() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runAxeCommand("tap --id BackButton", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        let tapTestMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(homeMarker != nil)
        #expect(tapTestMarker == nil)
    }
    
    @Test("Tap by AXLabel navigates back to home")
    func tapByLabelNavigatesBack() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runAxeCommand("tap --label 'AXe Playground'", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        let tapTestMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(homeMarker != nil)
        #expect(tapTestMarker == nil)
    }
    
    @Test("Multiple taps register correct count")
    func multipleTaps() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        let tapCount = 3
        
        // Act
        for i in 1...tapCount {
            try await TestHelpers.runAxeCommand("tap -x \(100 + i * 50) -y \(300 + i * 20)", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(tapCountElement?.label == "Tap Count: \(tapCount)", "Tap count should be \(tapCount)")
    }
    
    @Test("Tap with pre and post delays")
    func tapWithDelays() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        let startTime = Date()
        try await TestHelpers.runAxeCommand("tap -x 200 -y 300 --pre-delay 1.0 --post-delay 1.0", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Command should take at least 2 seconds with delays")
        
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(tapCountElement?.label == "Tap Count: 1", "Tap should still register with delays")
    }
    
    @Test("Tap at screen edges")
    func tapAtEdges() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Test corners
        let corners = [
            (x: 10, y: 100),      // Top-left
            (x: 380, y: 100),     // Top-right
            (x: 10, y: 800),      // Bottom-left
            (x: 380, y: 800)      // Bottom-right
        ]
        
        // Act & Assert
        for (index, corner) in corners.enumerated() {
            try await TestHelpers.runAxeCommand("tap -x \(corner.x) -y \(corner.y)", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 500_000_000)
            
            let uiState = try await TestHelpers.getUIState()
            let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
            #expect(tapCountElement?.label == "Tap Count: \(index + 1)", "Tap at edge should register")
        }
    }
}
