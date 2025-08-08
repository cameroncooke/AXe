import Foundation
import Testing

// MARK: - Command Execution

let defaultSimulatorUDID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]

struct CommandOutput {
    let output: String
    let exitCode: Int32
}

struct CommandRunner {
    static func run(_ command: String) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        
        let combinedOutput = output + (error.isEmpty ? "" : "\n\(error)")
        
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "CommandRunner",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: combinedOutput]
            )
        }
        
        return (combinedOutput, process.terminationStatus)
    }
}

// MARK: - UI State Parsing

struct UIElement: Codable {
    let type: String
    let frame: Frame?
    let children: [UIElement]?
    
    // The actual JSON uses AX prefixed fields
    let AXLabel: String?
    let AXValue: String?
    let AXIdentifier: String?
    
    struct Frame: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    
    // Provide convenient accessors
    var label: String? {
        return AXLabel
    }
    
    var value: String? {
        return AXValue
    }
    
    var identifier: String? {
        return AXIdentifier
    }
}

struct UIStateParser {
    static func parseDescribeUIOutput(_ jsonString: String) throws -> UIElement {
        // The describe-ui command outputs a header "Accessibility Information (JSON):" 
        // followed by the JSON array. We need to extract just the JSON part.
        var jsonContent = jsonString
        
        // Find the first '[' which marks the start of the JSON array
        if let jsonStart = jsonString.firstIndex(of: "[") {
            jsonContent = String(jsonString[jsonStart...])
        }
        
        guard let data = jsonContent.data(using: .utf8) else {
            throw TestError.invalidJSON("Could not convert string to data")
        }
        
        let decoder = JSONDecoder()
        // The output is an array, so decode it and return the first element
        let elements = try decoder.decode([UIElement].self, from: data)
        guard let firstElement = elements.first else {
            throw TestError.invalidJSON("No UI elements found")
        }
        return firstElement
    }
    
    static func findElement(in root: UIElement, matching predicate: (UIElement) -> Bool) -> UIElement? {
        if predicate(root) {
            return root
        }
        
        if let children = root.children {
            for child in children {
                if let found = findElement(in: child, matching: predicate) {
                    return found
                }
            }
        }
        
        return nil
    }

    static func findElement(in root: UIElement, withIdentifier identifier: String) -> UIElement? {
        return findElement(in: root) { element in
            element.identifier == identifier
        }
    }
    
    static func findElementByLabel(in root: UIElement, label: String) -> UIElement? {
        return findElement(in: root) { element in
            element.label == label
        }
    }
    
    static func findElementContainingLabel(in root: UIElement, containing: String) -> UIElement? {
        return findElement(in: root) { element in
            element.label?.contains(containing) == true
        }
    }
}

// MARK: - Test Helpers

struct TestHelpers {
    /// Get the path to the axe binary using #file to find source root
    static func getAxePath(testFile: String = #file) throws -> String {
        // First try SRC_ROOT environment variable
        if let srcRoot = ProcessInfo.processInfo.environment["SRC_ROOT"] {
            let axePath = "\(srcRoot)/.build/arm64-apple-macosx/debug/axe"
            if FileManager.default.fileExists(atPath: axePath) {
                return axePath
            }
        }
        
        // Use #file to find source root - test files are in Tests/ directory,
        // so source root is exactly one level up from the Tests directory
        let testFileURL = URL(fileURLWithPath: testFile)
        let testsDirectory = testFileURL.deletingLastPathComponent()  // Gets Tests/
        let sourceRoot = testsDirectory.deletingLastPathComponent()   // Gets source root
        
        let axePath = sourceRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/axe").path
        if FileManager.default.fileExists(atPath: axePath) {
            return axePath
        }
        
        throw TestError.unexpectedState("axe binary not found at \(axePath). Please run 'swift build'.")
    }
    
    static func launchPlaygroundApp(to screen: String, simulatorUDID: String? = nil) async throws {        
        guard let udid = simulatorUDID ?? defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified")
        }
        
        // Terminate existing instance
        let _ = try? await CommandRunner.run("xcrun simctl terminate \(udid) com.cameroncooke.AxePlayground")
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Launch to specific screen
        _ = try await CommandRunner.run("xcrun simctl launch \(udid) com.cameroncooke.AxePlayground --launch-arg \"screen=\(screen)\"")
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }
    
    static func getUIState(simulatorUDID: String? = nil) async throws -> UIElement {
        guard let udid = simulatorUDID ?? defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified")
        }
        let result = try await runAxeCommand("describe-ui", simulatorUDID: udid)
        
        // Check if the command failed
        if result.exitCode != 0 {
            throw TestError.unexpectedState("axe describe-ui command failed with exit code \(result.exitCode). Output: \(result.output)")
        }
                
        return try UIStateParser.parseDescribeUIOutput(result.output)
    }
    
    @discardableResult
    static func runAxeCommand(_ command: String, simulatorUDID: String? = nil) async throws -> CommandOutput {
        var fullCommand = command
        if let udid = simulatorUDID {
            fullCommand.append(" --udid \(udid)")
        }
        
        // Use the built executable directly for faster test execution
        let axePath = try getAxePath()
        let (output, exitCode) = try await CommandRunner.run("\(axePath) \(fullCommand)")
        
        // Check if the command failed
        if exitCode != 0 {
            throw TestError.unexpectedState("axe command '\(fullCommand)' failed with exit code \(exitCode). Output: \(output)")
        }
        
        return CommandOutput(output: output, exitCode: exitCode)
    }
}

// MARK: - Errors

enum TestError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case elementNotFound(String)
    case unexpectedState(String)
    case commandError(String)
    
    var description: String {
        switch self {
        case .invalidJSON(let message):
            return "Invalid JSON: \(message)"
        case .elementNotFound(let message):
            return "Element not found: \(message)"
        case .unexpectedState(let message):
            return "Unexpected state: \(message)"
        case .commandError(let message):
            return "Command error: \(message)"
        }
    }
}

// MARK: - Coordinate Parsing

struct CoordinateParser {
    static func parseCoordinates(from string: String) -> (x: Int, y: Int)? {
        // Pattern: "Tap Location: (150, 350)" or "(150, 350)"
        let pattern = #"\((\d+),\s*(\d+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else {
            return nil
        }
        
        guard let xRange = Range(match.range(at: 1), in: string),
              let yRange = Range(match.range(at: 2), in: string),
              let x = Int(string[xRange]),
              let y = Int(string[yRange]) else {
            return nil
        }
        
        return (x, y)
    }
}
