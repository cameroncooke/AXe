import Testing
import Foundation

@Suite("Gesture Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct GestureTests {
    @Test("Scroll up gesture")
    func scrollUpGesture() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        
        // Act
        try await TestHelpers.runAxeCommand("gesture scroll-up", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let match = UIStateParser.findElementByLabel(in: uiState, label: "Latest Gesture: scroll-up")
        
        #expect(match != nil)
    }
    
    @Test("Scroll down gesture")
    func scrollDownGesture() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        
        // Act
        try await TestHelpers.runAxeCommand("gesture scroll-down", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let match = UIStateParser.findElementByLabel(in: uiState, label: "Latest Gesture: scroll-down")
        
        #expect(match != nil)
    }
    
    @Test("Scroll left gesture")
    func scrollLeftGesture() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        
        // Act
        try await TestHelpers.runAxeCommand("gesture scroll-left", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let match = UIStateParser.findElementByLabel(in: uiState, label: "Latest Gesture: scroll-left")
        
        #expect(match != nil)
    }
    
    @Test("Scroll right gesture")
    func scrollRightGesture() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        
        // Act
        try await TestHelpers.runAxeCommand("gesture scroll-right", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let match = UIStateParser.findElementByLabel(in: uiState, label: "Latest Gesture: scroll-right")
        
        #expect(match != nil)
    }
    
    @Test("Swipe from left edge gesture")
    func swipeFromLeftEdge() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        
        // Act
        try await TestHelpers.runAxeCommand("gesture swipe-from-left-edge", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let match = UIStateParser.findElementByLabel(in: uiState, label: "Latest Gesture: swipe-from-left-edge")
        
        withKnownIssue("Playground doesn't currently detect edge gestures") {
            #expect(match != nil)
        }
    }
    
    @Test("Swipe from right edge gesture")
    func swipeFromRightEdge() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        
        // Act
        try await TestHelpers.runAxeCommand("gesture swipe-from-right-edge", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let match = UIStateParser.findElementByLabel(in: uiState, label: "Latest Gesture: swipe-from-right-edge")
        
        withKnownIssue("Playground doesn't currently detect edge gestures") {
            #expect(match != nil)
        }
    }
    
    @Test("Gesture with custom speed")
    func gestureWithCustomSpeed() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        
        // Act - slower scroll
        let startTime = Date()
        try await TestHelpers.runAxeCommand("gesture scroll-up --duration 2", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 1.0, "Slower gesture should take more time")
        
        let uiState = try await TestHelpers.getUIState()
        let match = UIStateParser.findElementByLabel(in: uiState, label: "Latest Gesture: scroll-up")
        
        #expect(match != nil)
    }
    
    @Test("Gesture with delays")
    func gestureWithDelays() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        
        // Act
        let startTime = Date()
        try await TestHelpers.runAxeCommand("gesture scroll-down --pre-delay 1 --post-delay 1", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Command should take at least 2 seconds with delays")
        
        let uiState = try await TestHelpers.getUIState()
        let match = UIStateParser.findElementByLabel(in: uiState, label: "Latest Gesture: scroll-down")
        
        #expect(match != nil)
    }
}
