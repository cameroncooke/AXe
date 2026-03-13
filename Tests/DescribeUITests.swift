import Testing
import Foundation

@Suite("Describe UI Command Surface Tests")
struct DescribeUICommandSurfaceTests {
    @Test("--point appears in describe-ui --help")
    func describeUIHelpIncludesPoint() async throws {
        let result = try await TestHelpers.runAxeCommand("describe-ui --help")
        #expect(result.output.contains("--point <x,y>"))
    }

    @Test("--point appears in help describe-ui")
    func helpDescribeUIIncludesPoint() async throws {
        let result = try await TestHelpers.runAxeCommand("help describe-ui")
        #expect(result.output.contains("--point <x,y>"))
    }

    @Test("Invalid --point format fails with guidance")
    func invalidPointFormatFails() async throws {
        let result = try await TestHelpers.runAxeCommandAllowFailure("describe-ui --udid invalid --point nope")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("--point must be in the form x,y using non-negative numbers."))
    }
}

@Suite("Describe UI Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct DescribeUITests {
    @Test("Basic describe-ui returns valid JSON")
    func basicDescribeUI() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        let uiState = try await TestHelpers.getUIState()
        
        // Assert - Should have basic structure (which means JSON was parsed successfully)
        #expect(uiState.type != "", "Root element should have a type")
    }
    
    @Test("Describe-ui captures UI hierarchy")
    func describeUIHierarchy() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        let uiState = try await TestHelpers.getUIState()
        
        // Assert - Should have basic structure
        #expect(uiState.type != "", "Root element should have a type")
        #expect(uiState.children != nil, "Root element should have children")
        #expect(uiState.children?.count ?? 0 > 0, "Should have at least one child element")
    }

    @Test("Describe-ui --point returns the targeted element")
    func describeUIAtPoint() async throws {
        let simulatorUDID = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test", simulatorUDID: simulatorUDID)

        let uiState = try await TestHelpers.getUIState(simulatorUDID: simulatorUDID)
        guard let backButton = UIStateParser.findElement(in: uiState, withIdentifier: "BackButton"),
              let frame = backButton.frame
        else {
            throw TestError.elementNotFound("BackButton with frame was not found in describe-ui output")
        }

        let centerX = frame.x + (frame.width / 2)
        let centerY = frame.y + (frame.height / 2)
        let point = "\(centerX),\(centerY)"

        let result = try await TestHelpers.runAxeCommand(
            "describe-ui --point \(point)",
            simulatorUDID: simulatorUDID
        )

        let roots = try UIStateParser.parseDescribeUIRoots(result.output)
        #expect(roots.count == 1, "Point-based describe-ui should return a single top-level element")

        let targetedElement = try #require(roots.first)
        let targetedFrame = try #require(targetedElement.frame)

        #expect(targetedElement.identifier == "BackButton")
        #expect(targetedElement.label == "AXe Playground")
        #expect(targetedElement.type == "Button")
        #expect(targetedElement.role == "AXButton")
        #expect(targetedElement.roleDescription == "back button")
        #expect(targetedElement.enabled == true)
        #expect(targetedElement.contentRequired == false)
        #expect(targetedElement.title == nil)
        #expect(targetedElement.helpText == nil)
        #expect(targetedElement.subrole == nil)
        #expect(targetedElement.AXFrame == "{{16, 62}, {44, 44}}")
        #expect(targetedElement.children?.isEmpty == true)
        #expect(targetedElement.customActions?.isEmpty == true)
        #expect(targetedFrame.x == 16)
        #expect(targetedFrame.y == 62)
        #expect(targetedFrame.width == 44)
        #expect(targetedFrame.height == 44)
    }
}
