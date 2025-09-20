import Testing
import Foundation

@Suite("Stream Video Command Tests")
struct StreamVideoTests {
    @Test("Stream video records an MP4 file with default options")
    func streamVideoDefaultRecording() async throws {
        let result = try await recordVideo(duration: 3.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0, "Command should exit successfully")
        #expect(result.fileSize > 150_000, "Recorded file should be non-trivial in size (got: \(result.fileSize))")
        #expect(result.stderr.contains("Recording simulator"), "Should log recording start")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == result.outputURL.path, "stdout should contain the output path")
    }

    @Test("Stream video honours FPS and scale settings")
    func streamVideoCustomOptions() async throws {
        let result = try await recordVideo(fps: 5, scale: 0.5, duration: 2.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0)
        #expect(result.fileSize > 50_000, "Scaled recording should still produce data")
        #expect(result.stderr.contains("Press Ctrl+C"), "Should log usage guidance")
    }

    @Test("Stream video uses provided directory without deleting its contents")
    func streamVideoOutputDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-output-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sentinel = tempDir.appendingPathComponent("sentinel.txt")
        try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)

        let result = try await recordVideo(duration: 1.0, outputPath: tempDir.path)

        #expect(FileManager.default.fileExists(atPath: sentinel.path), "Sentinel file should remain intact")
        #expect(result.exitCode == 0, "Recording should succeed")
        #expect(result.fileSize > 0, "Recording should produce a non-empty file")
        #expect(result.outputURL.path.hasPrefix(tempDir.path), "Output should be created inside the provided directory")
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path), "Recorded file should exist")

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Stream video validates FPS input")
    func streamVideoInvalidFPS() async throws {
        guard let udid = defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified")
        }
        let axePath = try TestHelpers.getAxePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: axePath)
        process.arguments = [
            "stream-video",
            "--udid", udid,
            "--fps", "40"
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(process.terminationStatus != 0, "Invalid FPS should fail")
        #expect(errorOutput.contains("FPS must be between 1 and 30"), "Should surface validation message")
    }

    // MARK: - Helpers

    private struct RecordingResult {
        let outputURL: URL
        let stdout: String
        let stderr: String
        let fileSize: Int
        let exitCode: Int32
    }

    private func recordVideo(
        fps: Int = 10,
        quality: Int = 80,
        scale: Double = 1.0,
        duration: TimeInterval = 2.0,
        outputPath: String? = nil
    ) async throws -> RecordingResult {
        guard let udid = defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified in SIMULATOR_UDID environment variable")
        }
        let axePath = try TestHelpers.getAxePath()

        let defaultOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-video-test-\(UUID().uuidString).mp4")
        let configuredOutputPath = outputPath ?? defaultOutputURL.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: axePath)
        process.arguments = [
            "stream-video",
            "--udid", udid,
            "--fps", "\(fps)",
            "--quality", "\(quality)",
            "--scale", "\(scale)",
            "--output", configuredOutputPath
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        process.interrupt() // send SIGINT to trigger graceful shutdown
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let resolvedOutputPath = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedURL = resolvedOutputPath.isEmpty ? defaultOutputURL : URL(fileURLWithPath: resolvedOutputPath)

        var fileSize = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
           let sizeNumber = attributes[.size] as? NSNumber {
            fileSize = sizeNumber.intValue
        }

        if outputPath == nil {
            try? FileManager.default.removeItem(at: resolvedURL)
        }

        return RecordingResult(
            outputURL: resolvedURL,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            fileSize: fileSize,
            exitCode: process.terminationStatus
        )
    }
}
