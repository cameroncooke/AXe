import Testing
import Foundation

@Suite("Record Video Command Tests")
struct RecordVideoTests {
    @Test("Record video writes an MP4 file with default options")
    func recordVideoDefault() async throws {
        let result = try await invokeRecordVideo(duration: 3.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0)
        #expect(result.fileSize > 150_000, "Recorded file should be non-trivial in size (got: \(result.fileSize))")
        #expect(result.stderr.contains("Recording simulator"))
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == result.outputURL.path)
    }

    @Test("Record video honours FPS, scale, and quality settings")
    func recordVideoCustomOptions() async throws {
        let result = try await invokeRecordVideo(fps: 5, scale: 0.5, quality: 60, duration: 2.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0)
        #expect(result.fileSize > 50_000)
        #expect(result.stderr.contains("Press Ctrl+C"))
    }

    @Test("Record video uses provided directory without deleting its contents")
    func recordVideoOutputDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-record-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sentinel = tempDir.appendingPathComponent("sentinel.txt")
        try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)

        let result = try await invokeRecordVideo(duration: 1.0, outputPath: tempDir.path)

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(result.exitCode == 0)
        #expect(result.fileSize > 0)
        #expect(result.outputURL.path.hasPrefix(tempDir.path))
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Record video validates FPS input")
    func recordVideoInvalidFPS() async throws {
        guard let udid = defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified")
        }
        let axePath = try TestHelpers.getAxePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: axePath)
        process.arguments = [
            "record-video",
            "--udid", udid,
            "--fps", "40"
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(process.terminationStatus != 0)
        #expect(errorOutput.contains("FPS must be between 1 and 30"))
    }

    // MARK: - Helpers

    private struct RecordingResult {
        let outputURL: URL
        let stdout: String
        let stderr: String
        let fileSize: Int
        let exitCode: Int32
    }

    private func invokeRecordVideo(
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
            .appendingPathComponent("axe-record-test-\(UUID().uuidString).mp4")
        let configuredOutputPath = outputPath ?? defaultOutputURL.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: axePath)
        process.arguments = [
            "record-video",
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

        process.interrupt()
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
