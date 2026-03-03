import Testing
import Foundation

@Suite("Batch Command Tests", .serialized)
struct BatchTests {
    @Test("Batch executes ordered tap steps")
    func orderedTapSteps() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        try await TestHelpers.runAxeCommand(
            "batch --step \"tap -x 180 -y 360\" --step \"tap -x 220 -y 420\"",
            simulatorUDID: defaultSimulatorUDID
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        let tapLocationElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Location:")
        let tapCount = extractTapCount(from: tapCountElement?.label)
        #expect((tapCount ?? 0) >= 2)
        #expect(tapLocationElement?.label == "Tap Location: (220, 420)")
    }

    @Test("Batch sleep step inserts delay")
    func sleepStep() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        let startTime = Date()
        try await TestHelpers.runAxeCommand(
            "batch --step \"tap -x 180 -y 360\" --step \"sleep 1.0\" --step \"tap -x 220 -y 420\"",
            simulatorUDID: defaultSimulatorUDID
        )
        let endTime = Date()

        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 1.0, "Batch should take at least 1 second with sleep step")

        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        let tapCount = extractTapCount(from: tapCountElement?.label)
        #expect((tapCount ?? 0) >= 2)
    }

    @Test("Batch enforces one input source")
    func oneSourceValidation() async throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("batch-steps-\(UUID().uuidString).txt")
        try "tap -x 100 -y 200\n".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        await #expect(throws: (any Error).self) {
            try await TestHelpers.runAxeCommand(
                "batch --step \"tap -x 100 -y 200\" --file \"\(tempFile.path)\"",
                simulatorUDID: defaultSimulatorUDID
            )
        }
    }

    @Test("Batch step errors are reported as step failures")
    func stepFailureMessage() async throws {
        guard let udid = defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified in SIMULATOR_UDID environment variable")
        }

        do {
            _ = try await TestHelpers.runAxeCommand(
                "batch --step \"unknown-command\"",
                simulatorUDID: udid
            )
            #expect(Bool(false), "Expected batch to fail for unknown step command")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("Step 1 failed:"))
            #expect(!message.contains("Failed to parse step"))
        }
    }

    @Test("Batch reads steps from file")
    func fileInputSource() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("batch-file-steps-\(UUID().uuidString).txt")
        let steps = [
            "tap -x 180 -y 360",
            "sleep 0.2",
            "tap -x 220 -y 420"
        ].joined(separator: "\n")
        try steps.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try await TestHelpers.runAxeCommand(
            "batch --file \"\(tempFile.path)\"",
            simulatorUDID: defaultSimulatorUDID
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        let tapLocationElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Location:")
        let tapCount = extractTapCount(from: tapCountElement?.label)
        #expect((tapCount ?? 0) >= 2)
        #expect(tapLocationElement?.label == "Tap Location: (220, 420)")
    }

    private func extractTapCount(from label: String?) -> Int? {
        guard let label else { return nil }
        return Int(label.replacingOccurrences(of: "Tap Count: ", with: ""))
    }
}

