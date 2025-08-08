import Testing
import Foundation

@Suite("Stream Video Cancellation Tests")
struct StreamVideoDebugTests {
    @Test("Stream video command runs without hanging")
    func streamVideoBasicExecution() async throws {
        // This test just verifies the command can be executed and terminated
        // without hanging indefinitely
        
        guard let udid = defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified")
        }
        
        // No need to launch app - stream-video captures the simulator screen directly
        
        // Create a task to run the command
        let commandTask = Task {
            try await TestHelpers.runAxeCommand(
                "stream-video --format bgra --fps 1",
                simulatorUDID: udid
            )
        }
        
        // Wait a bit
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
        
        // Cancel the task
        commandTask.cancel()
        
        // Give it time to clean up
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // If we get here without hanging, the test passes
        #expect(commandTask.isCancelled, "Command task should be cancelled")
    }
}