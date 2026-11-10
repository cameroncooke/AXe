import Darwin
import Foundation
import Testing

// MARK: - Command Execution

let defaultSimulatorUDID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
let isE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["AXE_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
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
                userInfo: [NSLocalizedDescriptionKey:
                    "Command failed (\(process.terminationStatus)): \(command)\n\(combinedOutput)"]
            )
        }

        // Every AXe JSON result an e2e test sees must match its published schema.
        try OutputSchemas.validate(output: stdoutText)
        return (combinedOutput, process.terminationStatus)
    }
}

/// One argument quoted for `/bin/bash -c`, as CommandRunner runs it.
func shellQuote(_ argument: String) -> String {
    "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Test Helpers

struct TestHelpers {
    /// Directory containing the loaded test bundle, e.g. `.build/out/Products/Debug`.
    ///
    /// SwiftPM and Xcode place executable products alongside the test bundle, so this
    /// locates `axe` without invoking `swift build` while `swift test` holds the build lock.
    private static func testProductsDirectory() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let imagePath = info.dli_fname else {
            return nil
        }

        var url = URL(fileURLWithPath: String(cString: imagePath)).resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "xctest" {
                return url.deletingLastPathComponent()
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    private static func resolveSwiftBinPath(sourceRoot: String, timeout: TimeInterval = 30) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "--show-bin-path"]
        process.currentDirectoryURL = URL(fileURLWithPath: sourceRoot)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw TestError.commandError(
                "Timed out after \(timeout)s running `swift build --show-bin-path` from \(sourceRoot). "
                    + "This deadlocks when run inside `swift test`; set AXE_BIN_PATH instead."
            )
        }

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

    /// Get the path to the axe binary.
    ///
    /// Resolution order: `AXE_BIN_PATH`, the products directory containing the test bundle,
    /// then `swift build --show-bin-path` from the source root.
    static func getAxePath(testFile: String = #file) throws -> String {
        if let axeBinPath = ProcessInfo.processInfo.environment["AXE_BIN_PATH"], !axeBinPath.isEmpty {
            if FileManager.default.fileExists(atPath: axeBinPath) {
                return axeBinPath
            }

            throw TestError.unexpectedState("AXE_BIN_PATH points to a missing axe binary at \(axeBinPath). Please run 'swift build'.")
        }

        if let productsDirectory = testProductsDirectory() {
            let bundledAxePath = productsDirectory.appendingPathComponent("axe").path
            if FileManager.default.isExecutableFile(atPath: bundledAxePath) {
                return bundledAxePath
            }
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
