import Testing
import Foundation

@Suite("Swipe Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct SwipeTests {
    @Test("Basic swipe registers on screen")
    func basicSwipe() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        try await Task.sleep(nanoseconds: 1_000_000_000) // Extra wait for app to be ready
        
        // Act
        try await TestHelpers.runAxeCommand("swipe --start-x 100 --start-y 400 --end-x 300 --end-y 400", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let swipeCount = UIStateParser.findElementContainingLabel(in: uiState, containing: "Count:")
        let startElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Start:")
        let endElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "End:")

        #expect(swipeCount?.label == "Count: 1")
        #expect(startElement?.label == "Start: (100, 400)")
        #expect(endElement?.label == "End: (300, 400)")
    }
    
    @Test("Swipe direction detection", arguments: [
        (start: (100, 400), end: (300, 400), direction: "Right"),
        (start: (300, 400), end: (100, 400), direction: "Left"),
        (start: (200, 300), end: (200, 500), direction: "Down"),
        (start: (200, 500), end: (200, 300), direction: "Up")
    ])
    func swipeDirectionDetection(
        _ swipeTest: (start: (Int, Int), end: (Int, Int), direction: String)
    ) async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        try await Task.sleep(nanoseconds: 1_000_000_000) // Extra wait for app to be ready
        
        // Act
        try await TestHelpers.runAxeCommand(
            "swipe --start-x \(swipeTest.start.0) --start-y \(swipeTest.start.1) --end-x \(swipeTest.end.0) --end-y \(swipeTest.end.1)",
            simulatorUDID: defaultSimulatorUDID
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let directionElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Direction:")
        #expect(directionElement != nil, "Should find direction element")
        #expect(directionElement?.label == "Direction: \(swipeTest.direction)", 
                "Direction should be \(swipeTest.direction)")
    }
    
    @Test("Swipe with custom duration")
    func swipeWithDuration() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        
        // Act - slower swipe (2 seconds)
        let startTime = Date()
        try await TestHelpers.runAxeCommand("swipe --start-x 100 --start-y 400 --end-x 300 --end-y 400 --duration 2", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Swipe should take at least 2 seconds")
        
        let uiState = try await TestHelpers.getUIState()
        let swipeCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Count:")
        #expect(swipeCountElement?.label == "Count: 1", "Swipe should still register with custom duration")
    }
    
    @Test("Multiple swipes register correctly")
    func multipleSwipes() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        let swipeCount = 3
        
        // Act
        for i in 1...swipeCount {
            try await TestHelpers.runAxeCommand("swipe --start-x \(100 + i * 30) --start-y \(400 + i * 20) --end-x \(200 + i * 30) --end-y \(400 + i * 20)", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let swipeCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Count:")
        #expect(swipeCountElement?.label == "Count: \(swipeCount)", "Swipe count should be \(swipeCount)")
    }
    
    @Test("Draw complex shapes")
    func swipeSegmentedStarTenPaths() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        try await Task.sleep(nanoseconds: 1_000_000_000) // Extra wait for app to be ready
        
        // Act - Draw a proper 5-pointed star broken into 10 segments
        // Star centered at (200, 300) with appropriate radius
        
        // Calculate the 10 vertices of a 5-pointed star
        // We alternate between outer points (tips) and inner vertices
        let centerX = 200.0
        let centerY = 400.0  // Move down to have more space
        let outerRadius = 150.0  // Much larger star
        let innerRadius = 60.0   // Proportionally larger inner radius
        
        var vertices: [(x: Int, y: Int)] = []
        
        // Generate 10 vertices - alternating between outer and inner points
        for i in 0..<10 {
            let angle = Double(i) * .pi / 5.0 - .pi / 2.0  // Start from top
            let radius = i % 2 == 0 ? outerRadius : innerRadius
            
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            
            vertices.append((x: Int(x), y: Int(y)))
        }
        
        // Draw the star as 10 segments with gaps between them
        // Each segment connects adjacent vertices
        for i in 0..<10 {
            let startVertex = vertices[i]
            let endVertex = vertices[(i + 1) % 10]
            
            // Calculate midpoints for creating gaps
            let gapSize = 0.10  // 10% gap at each end (smaller gap for larger star)
            let midStartX = Int(Double(startVertex.x) + (Double(endVertex.x - startVertex.x) * gapSize))
            let midStartY = Int(Double(startVertex.y) + (Double(endVertex.y - startVertex.y) * gapSize))
            let midEndX = Int(Double(endVertex.x) - (Double(endVertex.x - startVertex.x) * gapSize))
            let midEndY = Int(Double(endVertex.y) - (Double(endVertex.y - startVertex.y) * gapSize))
            
            // Draw segment with gap - use smaller delta for better detection
            try await TestHelpers.runAxeCommand(
                "swipe --start-x \(midStartX) --start-y \(midStartY) --end-x \(midEndX) --end-y \(midEndY) --duration 0.3 --delta 10",
                simulatorUDID: defaultSimulatorUDID
            )
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert - Verify all 10 swipes were registered for proper star
        let uiState = try await TestHelpers.getUIState()
        let swipeCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Count:")
        
        // The swipe count element should always exist
        #expect(swipeCountElement != nil, "Should find swipe count element")
        
        // Verify exactly 10 swipes were registered
        #expect(swipeCountElement?.label == "Count: 10", "Should have registered 10 swipes for segmented star art, but got: \(swipeCountElement?.label ?? "nil")")
    }
}
