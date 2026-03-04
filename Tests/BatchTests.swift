import Testing
import Foundation

@Suite("Batch Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct BatchTests {
    @Test("Batch executes ordered tap steps")
    func orderedTapSteps() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        try await TestHelpers.runAxeCommand(
            "batch --step \"tap -x 180 -y 360\" --step \"tap -x 220 -y 420\"",
            simulatorUDID: defaultSimulatorUDID
        )

        _ = try await waitForLabel(containing: "Tap Count:", timeout: 3) {
            (extractInt(from: $0) ?? 0) >= 2
        }

        let uiState = try await TestHelpers.getUIState()
        let tapLocationElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Location:")
        #expect(tapLocationElement?.label == "Tap Location: (220, 420)")
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

        _ = try await waitForLabel(containing: "Tap Count:", timeout: 3) {
            (extractInt(from: $0) ?? 0) >= 2
        }
    }

    @Test("Batch reads steps from stdin")
    func stdinInputSource() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        let udid = try TestHelpers.requireSimulatorUDID()
        let axePath = try TestHelpers.getAxePath()

        let command = "printf 'tap -x 160 -y 350\\ntap -x 200 -y 410\\n' | \(axePath) batch --stdin --udid \(udid)"
        let result = try await CommandRunner.run(command)
        #expect(result.exitCode == 0)

        _ = try await waitForLabel(containing: "Tap Count:", timeout: 3) {
            (extractInt(from: $0) ?? 0) >= 2
        }
    }

    @Test("Batch continue-on-error runs later steps and reports failures")
    func continueOnError() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        let result = try await TestHelpers.runAxeCommandAllowFailure(
            "batch --continue-on-error --wait-timeout 2 --poll-interval 0.1 --ax-cache perStep --step \"unknown-command\" --step \"tap --label 'Trigger State Change'\" --step \"tap --label 'State Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Batch completed with 1 failure(s):"))
        #expect(result.output.contains("unknown-command"))

        let currentState = try await waitForBatchState(expected: "State target tapped", timeout: 3)
        #expect(currentState == "State target tapped")
    }

    @Test("Batch with perBatch cache fails after state change")
    func perBatchCacheCanFailOnStateChange() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        let result = try await TestHelpers.runAxeCommandAllowFailure(
            "batch --ax-cache perBatch --step \"tap --label 'Trigger State Change'\" --step \"tap --label 'State Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Step 2 failed:"))
    }

    @Test("Batch with perStep cache handles state change")
    func perStepCacheHandlesStateChange() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        try await TestHelpers.runAxeCommand(
            "batch --ax-cache perStep --step \"tap --label 'Trigger State Change'\" --step \"tap --label 'State Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        let currentState = try await waitForBatchState(expected: "State target tapped", timeout: 3)
        #expect(currentState == "State target tapped")
    }

    @Test("Batch wait-timeout can wait for delayed element")
    func waitTimeoutFindsDelayedElement() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        try await TestHelpers.runAxeCommand(
            "batch --wait-timeout 5 --poll-interval 0.1 --step \"tap --label 'Trigger Delayed Element'\" --step \"tap --label 'Delayed Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        let currentState = try await waitForBatchState(expected: "Delayed target tapped", timeout: 6)
        #expect(currentState == "Delayed target tapped")
    }

    @Test("Batch without wait-timeout fails when delayed element is missing")
    func noWaitTimeoutFailsForDelayedElement() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-test")

        let result = try await TestHelpers.runAxeCommandAllowFailure(
            "batch --wait-timeout 0 --step \"tap --label 'Trigger Delayed Element'\" --step \"tap --label 'Delayed Target'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Step 2 failed:"))
    }

    @Test("Batch drives realistic login flow with loading transition")
    func loginFlowWithLoadingTransition() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-login-flow")

        try await TestHelpers.runAxeCommand(
            "batch --ax-cache perStep --wait-timeout 6 --poll-interval 0.1 --step \"type 'cam@example.com'\" --step \"tap --label Continue\" --step \"type 'supersecret'\" --step \"tap --label 'Sign In'\" --step \"tap --label 'Open Settings'\" --step \"tap --label 'Toggle Preference'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        let currentScreen = try await waitForLabel(containing: "Current Screen:", timeout: 2) {
            $0 == "Current Screen: Settings"
        }
        #expect(currentScreen == "Current Screen: Settings")

        let uiState = try await TestHelpers.getUIState()
        let settingsOpened = UIStateParser.findElementContainingLabel(in: uiState, containing: "Settings Opened")
        #expect(settingsOpened != nil)
    }

    @Test("Batch login flow fails without waiting for post-sign-in screen")
    func loginFlowFailsWithoutWait() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "batch-login-flow")

        let result = try await TestHelpers.runAxeCommandAllowFailure(
            "batch --ax-cache perStep --wait-timeout 0 --step \"type 'cam@example.com'\" --step \"tap --label Continue\" --step \"type 'supersecret'\" --step \"tap --label 'Sign In'\" --step \"tap --label 'Open Settings'\"",
            simulatorUDID: defaultSimulatorUDID
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Step 5 failed:"))
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

    private func waitForBatchState(expected: String, timeout: TimeInterval) async throws -> String {
        let label = try await waitForLabel(containing: "Current State:", timeout: timeout) {
            $0 == "Current State: \(expected)"
        }
        return label.replacingOccurrences(of: "Current State: ", with: "")
    }

    private func waitForLabel(
        containing text: String,
        timeout: TimeInterval,
        satisfies predicate: (String) -> Bool
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
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

    private func extractInt(from label: String) -> Int? {
        let digits = label.filter { $0.isNumber }
        return Int(digits)
    }
}
