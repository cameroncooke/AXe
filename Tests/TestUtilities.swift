import Darwin
import Foundation
import Testing

// MARK: - Command Execution

let defaultSimulatorUDID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
let isE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["AXE_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()
let isLandscapeE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["AXE_LANDSCAPE_E2E"]?.lowercased() ?? ""
    return isE2EEnabled && (raw == "1" || raw == "true" || raw == "yes")
}()

struct CommandOutput {
    let output: String
    let exitCode: Int32
}

struct CommandRunner {
    static func run(
        _ command: String,
        environment: [String: String]? = nil,
        allowFailure: Bool = false,
        timeout: TimeInterval = 30
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdoutReadTask = Task {
            try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        }
        let stderrReadTask = Task {
            try errorPipe.fileHandleForReading.readToEnd() ?? Data()
        }

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        var didTimeout = false
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        if process.isRunning {
            didTimeout = true
            process.terminate()
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let outputData = (try? await stdoutReadTask.value) ?? Data()
        let errorData = (try? await stderrReadTask.value) ?? Data()

        let stdoutText = String(data: outputData, encoding: .utf8) ?? ""
        let stderrText = String(data: errorData, encoding: .utf8) ?? ""

        let combinedOutput = stdoutText + (stderrText.isEmpty ? "" : "\n\(stderrText)")

        if didTimeout {
            throw NSError(
                domain: "CommandRunner",
                code: 124,
                userInfo: [
                    NSLocalizedDescriptionKey: "Command timed out after \(timeout)s: \(command)\n\(combinedOutput)"
                ]
            )
        }

        if process.terminationStatus != 0, !allowFailure {
            throw NSError(
                domain: "CommandRunner",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: combinedOutput]
            )
        }

        return (combinedOutput, process.terminationStatus)
    }
}

// MARK: - Test Helpers

struct TestHelpers {
    private static func resolveSwiftBinPath(sourceRoot: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "--show-bin-path"]
        process.currentDirectoryURL = URL(fileURLWithPath: sourceRoot)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 || output.isEmpty {
            throw TestError.commandError(
                "Unable to resolve AXe binary path via `swift build --show-bin-path` from \(sourceRoot). \(errorOutput)"
            )
        }

        return output
    }

    static func requireE2EEnabled() throws {
        if !isE2EEnabled {
            throw TestError.commandError("E2E simulator tests are disabled. Run via ./test-runner.sh or set AXE_E2E=1.")
        }
    }

    static func requireSimulatorUDID() throws -> String {
        try requireE2EEnabled()
        guard let udid = defaultSimulatorUDID, !udid.isEmpty else {
            throw TestError.commandError("SIMULATOR_UDID is required for E2E simulator tests.")
        }
        return udid
    }

    /// Get the path to the axe binary using #file to find source root
    static func getAxePath(testFile: String = #file) throws -> String {
        if let axeBinPath = ProcessInfo.processInfo.environment["AXE_BIN_PATH"], !axeBinPath.isEmpty {
            if FileManager.default.fileExists(atPath: axeBinPath) {
                return axeBinPath
            }

            throw TestError.unexpectedState("AXE_BIN_PATH points to a missing axe binary at \(axeBinPath). Please run 'swift build'.")
        }

        let sourceRoot: String
        if let srcRoot = ProcessInfo.processInfo.environment["SRC_ROOT"] {
            sourceRoot = srcRoot
        } else {
        let testFileURL = URL(fileURLWithPath: testFile)
        let testsDirectory = testFileURL.deletingLastPathComponent()  // Gets Tests/
            sourceRoot = testsDirectory.deletingLastPathComponent().path
        }

        let axePath = URL(fileURLWithPath: try resolveSwiftBinPath(sourceRoot: sourceRoot))
            .appendingPathComponent("axe")
            .path
        if FileManager.default.fileExists(atPath: axePath) {
            return axePath
        }
        
        throw TestError.unexpectedState("axe binary not found at \(axePath). Please run 'swift build'.")
    }
    
    static func setSimulatorOrientationPortrait() async throws {
        try await setSimulatorOrientation(menuItem: "Portrait")
    }

    static func setSimulatorOrientationLandscapeLeft() async throws {
        try await setSimulatorOrientation(menuItem: "Landscape Left")
    }

    static func setSimulatorOrientationLandscapeRight() async throws {
        try await setSimulatorOrientation(menuItem: "Landscape Right")
    }

    static func rotateSimulatorLeft() async throws {
        try await selectSimulatorDeviceMenuItem("Rotate Left")
    }

    private static func setSimulatorOrientation(menuItem: String) async throws {
        let script = """
        tell application "Simulator" to activate
        delay 0.5
        tell application "System Events"
            tell process "Simulator"
                click menu item "\(menuItem)" of menu "Orientation" of menu item "Orientation" of menu "Device" of menu bar 1
            end tell
        end tell
        """
        let escapedScript = script.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await CommandRunner.run("osascript -e '\(escapedScript)'", timeout: 10)
        try await Task.sleep(nanoseconds: 1_500_000_000)
    }

    private static func selectSimulatorDeviceMenuItem(_ menuItem: String) async throws {
        let script = """
        tell application "Simulator" to activate
        delay 0.5
        tell application "System Events"
            tell process "Simulator"
                click menu item "\(menuItem)" of menu "Device" of menu bar 1
            end tell
        end tell
        """
        let escapedScript = script.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await CommandRunner.run("osascript -e '\(escapedScript)'", timeout: 10)
        try await Task.sleep(nanoseconds: 1_500_000_000)
    }

    static func launchPlaygroundApp(to screen: String, simulatorUDID: String? = nil) async throws {
        let udid: String
        if let simulatorUDID {
            udid = simulatorUDID
        } else {
            udid = try requireSimulatorUDID()
        }
        
        // Terminate existing instance
        let _ = try? await CommandRunner.run("xcrun simctl terminate \(udid) com.cameroncooke.AxePlayground")
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Launch to specific screen
        _ = try await CommandRunner.run("xcrun simctl launch \(udid) com.cameroncooke.AxePlayground --launch-arg \"screen=\(screen)\"")
        if screen == "text-input" {
            let deadline = Date().addingTimeInterval(10)
            var lastFocusRequest: Date?
            while Date() < deadline {
                if let state = try? await getUIState(simulatorUDID: udid) {
                    let focusIndicator = UIStateParser.findElement(in: state) { element in
                        element.identifier == "text-input-screen" && element.label == "✏️ Typing active"
                    }
                    if focusIndicator != nil {
                        return
                    }

                    let shouldRequestFocus = lastFocusRequest.map {
                        Date().timeIntervalSince($0) >= 1
                    } ?? true
                    if shouldRequestFocus,
                       let textFieldFrame = UIStateParser.findElement(in: state, matching: { $0.type == "TextField" })?.frame {
                        lastFocusRequest = Date()
                        let centerX = textFieldFrame.x + (textFieldFrame.width / 2)
                        let centerY = textFieldFrame.y + (textFieldFrame.height / 2)
                        _ = try? await runAxeCommand(
                            "tap -x \(centerX) -y \(centerY)",
                            simulatorUDID: udid
                        )
                    }
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw TestError.unexpectedState("Text input fixture did not become focused and ready")
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }
    
    static func getUIState(simulatorUDID: String? = nil) async throws -> UIElement {
        let udid: String
        if let simulatorUDID {
            udid = simulatorUDID
        } else {
            udid = try requireSimulatorUDID()
        }
        let result = try await runAxeCommand("describe-ui", simulatorUDID: udid)
        
        // Check if the command failed
        if result.exitCode != 0 {
            throw TestError.unexpectedState("axe describe-ui command failed with exit code \(result.exitCode). Output: \(result.output)")
        }
                
        let roots = try UIStateParser.parseDescribeUIRoots(result.output)
        if let playgroundRoot = roots.first(where: { root in
            root.type == "Application" && root.label == "AxePlayground"
        }) {
            return playgroundRoot
        }
        guard let firstRoot = roots.first else {
            throw TestError.invalidJSON("No UI elements found")
        }
        return firstRoot
    }

    static func waitForLandscapeCoordinateFixtureLayout(timeout: TimeInterval) async throws -> UIElement {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let uiState = try await getUIState()
            if UIStateParser.findElement(in: uiState, matching: { element in
                element.label == "Layout: landscape" && element.value == "landscape"
            }) != nil {
                return uiState
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState("Timed out waiting for landscape fixture layout")
    }

    static func resetLandscapeCoordinateFixtureToPortrait() async throws {
        try await setSimulatorOrientationPortrait()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let uiState = try await getUIState()
            if UIStateParser.findElement(in: uiState, matching: { element in
                element.label == "Layout: portrait" && element.value == "portrait"
            }) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState("Unable to reset simulator to portrait fixture layout")
    }

    static func waitForLabel(
        containing text: String,
        timeout: TimeInterval,
        simulatorUDID: String? = nil,
        satisfies predicate: (String) -> Bool
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await getUIState(simulatorUDID: simulatorUDID)
            if let element = UIStateParser.findElementContainingLabel(in: uiState, containing: text),
               let label = element.label {
                lastValue = label
                if predicate(label) {
                    return label
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState("Timed out waiting for label containing '\(text)'. Last value: \(lastValue ?? "none")")
    }
    
    @discardableResult
    static func runAxeCommand(
        _ command: String,
        simulatorUDID: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandOutput {
        var fullCommand = command
        if let udid = simulatorUDID {
            fullCommand.append(" --udid \(udid)")
        }
        
        // Use the built executable directly for faster test execution
        let axePath = try getAxePath()
        let (output, exitCode) = try await CommandRunner.run(
            "\(axePath) \(fullCommand)",
            environment: environment
        )
        
        // Check if the command failed
        if exitCode != 0 {
            throw TestError.unexpectedState("axe command '\(fullCommand)' failed with exit code \(exitCode). Output: \(output)")
        }
        
        return CommandOutput(output: output, exitCode: exitCode)
    }

    static func runAxeCommandAllowFailure(
        _ command: String,
        simulatorUDID: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandOutput {
        var fullCommand = command
        if let udid = simulatorUDID {
            fullCommand.append(" --udid \(udid)")
        }

        let axePath = try getAxePath()
        let (output, exitCode) = try await CommandRunner.run(
            "\(axePath) \(fullCommand)",
            environment: environment,
            allowFailure: true
        )

        return CommandOutput(output: output, exitCode: exitCode)
    }

    static func waitForProcessExit(
        _ process: Process,
        timeout: TimeInterval,
        description: String
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        if process.isRunning {
            process.terminate()
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if process.isRunning {
            throw TestError.unexpectedState(description)
        }
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

    static func parseNamedCoordinates(from string: String) -> (x: Int, y: Int)? {
        let pattern = #"x:(\d+),y:(\d+)"#
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
