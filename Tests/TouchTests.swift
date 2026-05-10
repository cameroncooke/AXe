import Testing
import Foundation

@Suite("Touch Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct TouchTests {
    @Test("Basic touch down and up")
    func basicTouchDownUp() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "touch-control")
        
        // Act - Touch down
        try await TestHelpers.runAxeCommand("touch -x 200 -y 400 --down", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Assert touch down
        var uiState = try await TestHelpers.getUIState()
        let touchDownElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch down:")
        #expect(touchDownElement?.label == "Last touch down: (200, 400)", "Touch down coordinates should be recorded")
        
        // Act - Touch up
        try await TestHelpers.runAxeCommand("touch -x 200 -y 400 --up", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Assert touch up
        uiState = try await TestHelpers.getUIState()
        let touchUpElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch up:")
        #expect(touchUpElement?.label == "Last touch up: (200, 400)", "Touch up coordinates should be recorded")
    }
    
    @Test("Landscape coordinate touch preserves translated point", .enabled(if: isLandscapeE2EEnabled))
    func landscapeCoordinateTouchPreservesTranslatedPoint() async throws {
        try await runLandscapeTouchPrecisionTest(orientation: .left)
    }

    @Test("Landscape-right coordinate touch preserves translated point", .enabled(if: isLandscapeE2EEnabled))
    func landscapeRightCoordinateTouchPreservesTranslatedPoint() async throws {
        try await runLandscapeTouchPrecisionTest(orientation: .right)
    }

    @Test("Touch move")
    func touchMove() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "touch-control")
        
        // Act - Touch down, move, then up
        try await TestHelpers.runAxeCommand("touch -x 100 -y 300 --down", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 300_000_000)
        
        try await TestHelpers.runAxeCommand("touch -x 200 -y 400 --down", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 300_000_000)
        
        try await TestHelpers.runAxeCommand("touch -x 300 -y 500 --down", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // Touch up at final position
        try await TestHelpers.runAxeCommand("touch -x 300 -y 500 --up", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // Assert touch down and up were registered with correct coordinates
        let uiState = try await TestHelpers.getUIState()
        let touchDownElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch down:")
        let touchUpElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch up:")
        
        #expect(touchDownElement?.label == "Last touch down: (300, 500)", "Touch down should be at final position")
        #expect(touchUpElement?.label == "Last touch up: (300, 500)", "Touch up should be at final position")
    }
    
    @Test("Multiple touch sequences")
    func multipleTouchSequences() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "touch-control")
        
        // Perform 3 touch sequences
        for i in 1...3 {
            let x = 100 + i * 50
            let y = 300 + i * 30
            
            // Touch down
            try await TestHelpers.runAxeCommand("touch -x \(x) -y \(y) --down", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 200_000_000)
            
            // Touch up
            try await TestHelpers.runAxeCommand("touch -x \(x) -y \(y) --up", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        
        // Assert - Check the event count increased and last coordinates are from final sequence
        let uiState = try await TestHelpers.getUIState()
        let eventCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Events:")
        let touchDownElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch down:")
        let touchUpElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch up:")
        
        #expect(eventCountElement?.label == "Events: 6", "Should register 6 total events (3 down + 3 up)")
        #expect(touchDownElement?.label == "Last touch down: (250, 390)", "Last touch down should be from final sequence")
        #expect(touchUpElement?.label == "Last touch up: (250, 390)", "Last touch up should be from final sequence")
    }
    
    @Test("Touch with drag simulation")
    func touchDragSimulation() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "touch-control")
        
        // Act - Simulate drag from left to right
        try await TestHelpers.runAxeCommand("touch -x 100 -y 400 --down", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Move in steps to simulate smooth drag (using touch down at each position)
        for x in stride(from: 150, through: 300, by: 50) {
            try await TestHelpers.runAxeCommand("touch -x \(x) -y 400 --down", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        try await TestHelpers.runAxeCommand("touch -x 300 -y 400 --up", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let touchDownElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch down:")
        let touchUpElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch up:")
        
        #expect(touchDownElement?.label == "Last touch down: (300, 400)", "Touch down should be at final position")
        #expect(touchUpElement?.label == "Last touch up: (300, 400)", "Touch up should be at end position")
    }
    
    @Test("Touch with delays")
    func touchWithDelays() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "touch-control")
        
        // Act - Use the delay feature for touch down then up
        let startTime = Date()
        try await TestHelpers.runAxeCommand("touch -x 200 -y 300 --down --up --delay 1.0", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 1.0, "Command should take at least 1 second with delay")
        
        let uiState = try await TestHelpers.getUIState()
        let touchDownElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch down:")
        let touchUpElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch up:")
        
        #expect(touchDownElement?.label == "Last touch down: (200, 300)", "Touch down should register with delays")
        #expect(touchUpElement?.label == "Last touch up: (200, 300)", "Touch up should register with delays")
    }

    private enum LandscapeTestOrientation {
        case left
        case right
    }

    private func runLandscapeTouchPrecisionTest(orientation: LandscapeTestOrientation) async throws {
        try await TestHelpers.launchPlaygroundApp(to: "landscape-coordinate-test")
        do {
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            switch orientation {
            case .left:
                try await TestHelpers.setSimulatorOrientationLandscapeLeft()
            case .right:
                try await TestHelpers.setSimulatorOrientationLandscapeRight()
            }

            let initialState = try await TestHelpers.waitForLandscapeCoordinateFixtureLayout(timeout: 6)

            guard let target = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Target"),
                  let frame = target.frame else {
                throw TestError.elementNotFound("landscape-coordinate-target")
            }

            let logicalX = Int(frame.x + frame.width / 2)
            let logicalY = Int(frame.y + frame.height / 2)

            try await TestHelpers.runAxeCommand(
                "touch -x \(logicalX) -y \(logicalY) --down --up",
                simulatorUDID: defaultSimulatorUDID
            )

            let hitCount = try await waitForLandscapeHitCount(expected: "Landscape Hit Count: 1", timeout: 3)
            #expect(hitCount == "Landscape Hit Count: 1")
            try await assertLastNamedCoordinate(containing: "Last Tap Hit:", expectedX: logicalX, expectedY: logicalY, timeout: 3)
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
        } catch {
            try? await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            throw error
        }
    }

    private func waitForLandscapeHitCount(expected: String, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            if let element = UIStateParser.findElementContainingLabel(in: uiState, containing: "Landscape Hit Count:"),
               let label = element.label {
                lastValue = label
                if label == expected {
                    return label
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState("Timed out waiting for \(expected). Last value: \(lastValue ?? "none")")
    }

    private func assertLastNamedCoordinate(
        containing text: String,
        expectedX: Int,
        expectedY: Int,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            if let label = UIStateParser.findElementContainingLabel(in: uiState, containing: text)?.label {
                lastValue = label
                if let point = CoordinateParser.parseNamedCoordinates(from: label),
                   abs(point.x - expectedX) <= 1,
                   abs(point.y - expectedY) <= 1 {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState(
            "Timed out waiting for \(text) near x:\(expectedX),y:\(expectedY). Last value: \(lastValue ?? "none")"
        )
    }

    @Test("Touch delay triggers long press recognition")
    func touchDelayTriggersLongPressRecognition() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "touch-control")

        // Act
        try await TestHelpers.runAxeCommand("touch -x 220 -y 340 --down --up --delay 1.0", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Assert
        let uiState = try await TestHelpers.getUIState()
        let longPressCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Long presses:")
        let longPressElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last long press:")
        let touchDownElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch down:")
        let touchUpElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last touch up:")

        #expect(longPressCountElement?.label == "Long presses: 1", "Long press should be recognized once")
        #expect(longPressElement?.label == "Last long press: (220, 340)", "Long press coordinates should match")
        #expect(touchDownElement?.label == "Last touch down: (220, 340)", "Touch down coordinates should still match")
        #expect(touchUpElement?.label == "Last touch up: (220, 340)", "Touch up coordinates should still match")
    }
} 
