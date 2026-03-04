import Testing
import Foundation

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
}
