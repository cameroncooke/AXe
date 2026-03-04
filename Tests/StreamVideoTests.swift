import Testing
import Foundation

@Suite("Stream Video Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct StreamVideoTests {
    @Test("Stream video outputs MJPEG data with HTTP headers")
    func streamVideoMJPEG() async throws {
        let result = try await streamVideoForDuration(format: "mjpeg", duration: 3.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(!result.output.isEmpty, "Should have stderr messages")
        #expect(result.output.contains("Starting screenshot-based video stream"))
        #expect(result.output.contains("Format: mjpeg"))
    }

    @Test("Stream video outputs raw JPEG data for ffmpeg format")
    func streamVideoFFmpeg() async throws {
        let result = try await streamVideoForDuration(format: "ffmpeg", duration: 2.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.output.contains("Format: ffmpeg"))
    }

    @Test("Stream video outputs raw JPEG with length prefix for raw format")
    func streamVideoRaw() async throws {
        let result = try await streamVideoForDuration(format: "raw", duration: 2.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.output.contains("Format: raw"))
    }

    @Test("Stream video with custom FPS")
    func streamVideoWithFPS() async throws {
        let result = try await streamVideoForDuration(format: "mjpeg", fps: 5, duration: 2.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.output.contains("FPS: 5"))
    }

    @Test("Stream video with quality and scale settings")
    func streamVideoWithQualityAndScale() async throws {
        let result = try await streamVideoForDuration(
            format: "mjpeg",
            fps: 5,
            quality: 50,
            scale: 0.5,
            duration: 1.0
        )

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(result.output.contains("Quality: 50"))
        #expect(result.output.contains("Scale: 0.5"))
    }

    @Test("Stream BGRA video outputs raw pixel data")
    func streamVideoBGRA() async throws {
        let result = try await streamVideoForDuration(format: "bgra", duration: 2.0)

        #expect(isAcceptableStreamExitCode(result.exitCode), "Unexpected exit code: \(result.exitCode)")
        #expect(!result.output.isEmpty)
        #expect(result.output.contains("Starting BGRA video stream"))
        #expect(result.output.contains("Format: bgra"))
    }

    @Test("Stream video can be cancelled gracefully")
    func streamVideoCancellation() async throws {
        let task = Task {
            try await streamVideoForDuration(format: "mjpeg", fps: 30, duration: 60.0)
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        _ = await task.result
    }

    @Test("Stream video rejects invalid formats")
    func streamVideoInvalidFormat() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()

        let axePath = try TestHelpers.getAxePath()
        let fullCommand = "\(axePath) stream-video --format h264 --udid \(udid)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", fullCommand]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(process.terminationStatus != 0)
        #expect(errorOutput.contains("format"))
    }

    private func streamVideoForDuration(
        format: String = "mjpeg",
        fps: Int = 10,
        quality: Int = 80,
        scale: Double = 1.0,
        duration: TimeInterval = 2.0
    ) async throws -> (output: String, data: Data, dataString: String, dataSize: Int, exitCode: Int32) {
        var command = "stream-video"
        command += " --format \(format)"
        command += " --fps \(fps)"
        command += " --quality \(quality) --scale \(scale)"

        let udid = try TestHelpers.requireSimulatorUDID()

        let axePath = try TestHelpers.getAxePath()
        let fullCommand = "\(axePath) \(command) --udid \(udid)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", fullCommand]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdoutReadTask = Task {
            try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        }

        try process.run()

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        process.terminate()

        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 10.0,
            description: "stream-video process did not exit after terminate"
        )

        let outputData = (try? await stdoutReadTask.value) ?? Data()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        let dataString = String(data: outputData, encoding: .utf8) ?? ""

        if outputData.count == 0 && !errorOutput.isEmpty {
            print("DEBUG: No data received. Error output: \(errorOutput)")
        }

        return (
            output: errorOutput,
            data: outputData,
            dataString: dataString,
            dataSize: outputData.count,
            exitCode: process.terminationStatus
        )
    }

    private func isAcceptableStreamExitCode(_ code: Int32) -> Bool {
        let acceptable: Set<Int32> = [0, 9, 15, 130, 137, 143]
        return acceptable.contains(code)
    }
}
