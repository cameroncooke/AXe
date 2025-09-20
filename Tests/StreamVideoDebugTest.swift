import Testing
import Foundation

@Suite("Stream Video Cancellation Tests")
struct StreamVideoDebugTests {
    @Test("Stream video command can be cancelled without hanging")
    func streamVideoBasicExecution() async throws {
        guard let udid = defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified")
        }

        let axePath = try TestHelpers.getAxePath()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-video-debug-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: axePath)
        process.arguments = [
            "stream-video",
            "--udid", udid,
            "--fps", "5",
            "--output", tempURL.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

        process.interrupt()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "Command should exit cleanly after cancellation")
    }
}
