import Testing
import Foundation

@Suite("List Simulators Command Tests", .enabled(if: isE2EEnabled))
struct ListSimulatorsTests {
    @Test("Basic list-simulators returns output")
    func basicListSimulators() async throws {
        // Act
        let result = try await TestHelpers.runAxeCommand("list-simulators")
        
        // Assert
        #expect(result.exitCode == 0, "Exit code should be 0")
        #expect(!result.output.isEmpty, "Output should not be empty")
        #expect(
            result.output.contains("iOS") ||
            result.output.contains("Shutdown") ||
            result.output.contains("Booted")
        )
    }
    
    @Test("List simulators includes UDID")
    func listSimulatorsIncludesUDID() async throws {
        // Act
        let result = try await TestHelpers.runAxeCommand("list-simulators")
        
        // Assert - Should contain UUID pattern
        let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        let regex = try NSRegularExpression(pattern: uuidPattern, options: .caseInsensitive)
        let matches = regex.matches(in: result.output, range: NSRange(result.output.startIndex..., in: result.output))
        
        #expect(matches.count > 0, "Should find at least one simulator UDID")
    }
    
    @Test("List simulators includes device names")
    func listSimulatorsIncludesDeviceNames() async throws {
        // Act
        let result = try await TestHelpers.runAxeCommand("list-simulators")
        
        // Assert - Should contain common device names
        let commonDevicePatterns = ["iPhone", "iPad", "Apple Watch", "Apple TV"]
        var foundAnyDevice = false
        
        for pattern in commonDevicePatterns {
            if result.output.contains(pattern) {
                foundAnyDevice = true
                break
            }
        }
        
        #expect(foundAnyDevice, "Should find at least one device name")
    }
    
    @Test("List simulators includes OS versions")
    func listSimulatorsIncludesOSVersions() async throws {
        // Act
        let result = try await TestHelpers.runAxeCommand("list-simulators")
        
        // Assert - Should contain OS version patterns
        let osPatterns = ["iOS [0-9]+\\.[0-9]+", "watchOS [0-9]+\\.[0-9]+", "tvOS [0-9]+\\.[0-9]+"]
        var foundOSVersion = false
        
        for pattern in osPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: result.output, range: NSRange(result.output.startIndex..., in: result.output)) != nil {
                foundOSVersion = true
                break
            }
        }
        
        #expect(foundOSVersion, "Should find at least one OS version")
    }
    
    @Test("List simulators shows device status")
    func listSimulatorsShowsStatus() async throws {
        // Act
        let result = try await TestHelpers.runAxeCommand("list-simulators")
        
        // Assert - Should show status (Booted or Shutdown)
        let hasStatus = result.output.contains("Booted") || result.output.contains("Shutdown")
        #expect(hasStatus, "Should show simulator status")
    }
    
    @Test("List simulators groups by runtime")
    func listSimulatorsGroupsByRuntime() async throws {
        // Act
        let result = try await TestHelpers.runAxeCommand("list-simulators")
        
        // Assert - Should have runtime grouping headers
        let hasRuntimeHeaders = result.output.contains("iOS") || 
                              result.output.contains("watchOS") || 
                              result.output.contains("tvOS") ||
                              result.output.contains("visionOS")
        #expect(hasRuntimeHeaders, "Should group simulators by runtime")
    }
    
    @Test("List simulators formatted output")
    func listSimulatorsFormattedOutput() async throws {
        // Act
        let result = try await TestHelpers.runAxeCommand("list-simulators")
        
        // Assert - Check for consistent formatting
        let lines = result.output.components(separatedBy: .newlines)
        let simulatorLines = lines.filter { line in
            // Look for lines that contain UDID pattern
            let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
            if let regex = try? NSRegularExpression(pattern: uuidPattern, options: .caseInsensitive),
               regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                return true
            }
            return false
        }
        
        #expect(simulatorLines.count > 0, "Should have properly formatted simulator entries")
        
    }
}
