import Testing
import Foundation

@Suite("Stream Video Cancellation Tests", .serialized, .enabled(if: isE2EEnabled))
struct StreamVideoDebugTests {
    @Test("Stream video command can be cancelled without hanging")
    func streamVideoBasicExecution() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()

        let axePath = try TestHelpers.getAxePath()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-video-debug-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: axePath)
        process.arguments = [
            "record-video",
            "--udid", udid,
            "--fps", "5",
            "--output", tempURL.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

        process.interrupt()
        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 10.0,
            description: "record-video debug process did not exit after interrupt"
        )

        #expect(process.terminationStatus == 0, "Command should exit cleanly after cancellation")
    }
}
