import Testing
import Foundation

@Suite("Button Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct ButtonTests {
    private func simulatorUDID() throws -> String {
        try #require(defaultSimulatorUDID, "AXE_E2E_SIMULATOR_UDID is required for button E2E tests")
    }

    private func springBoardState(_ name: String) async throws -> Int {
        let simulatorUDID = try simulatorUDID()
        let result = try await CommandRunner.run(
            "xcrun simctl spawn \(simulatorUDID) notifyutil -g com.apple.springboard.\(name)"
        )
        return try #require(
            result.output.split(whereSeparator: { $0.isWhitespace }).last.flatMap { Int($0) },
            "SpringBoard \(name) state must be observable"
        )
    }

    private func waitForSpringBoardState(_ name: String, expectedState: Int) async throws -> Int {
        let deadline = Date().addingTimeInterval(5)
        var currentState = try await springBoardState(name)
        while currentState != expectedState && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            currentState = try await springBoardState(name)
        }
        return currentState
    }

    private func isXcode27() async throws -> Bool {
        let version = try await CommandRunner.run("xcodebuild -version")
        let majorVersion = version.output
            .split(whereSeparator: { $0.isWhitespace })
            .dropFirst()
            .first
            .flatMap { Int($0.split(separator: ".").first ?? "") }
        return majorVersion == 27
    }

    private func waitForDeviceHIDServiceIfRequired() async throws {
        guard try await isXcode27() else {
            return
        }

        let simulatorUDID = try simulatorUDID()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let result = try await CommandRunner.run(
                "launchd_sim_pid=$(pgrep -f '^launchd_sim .*/Devices/\(simulatorUDID)/data/var/run/launchd_bootstrap.plist$' | head -1); "
                    + "test -n \"$launchd_sim_pid\" && pgrep -P \"$launchd_sim_pid\" -x dtuhidd",
                allowFailure: true
            )
            if result.exitCode == 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw TestError.unexpectedState("Device Hub simulator DTUHID service did not become ready")
    }

    private func waitForDeviceHIDAttachmentAfterBootIfRequired() async throws {
        try await waitForDeviceHIDServiceIfRequired()
        guard try await isXcode27() else {
            return
        }
        try await Task.sleep(for: .seconds(10))
    }

    private func rebootSimulator() async throws {
        let simulatorUDID = try simulatorUDID()
        _ = try await CommandRunner.run("xcrun simctl shutdown \(simulatorUDID)", allowFailure: true)
        _ = try await CommandRunner.run("xcrun simctl boot \(simulatorUDID)")
        _ = try await CommandRunner.run("xcrun simctl bootstatus \(simulatorUDID) -b", timeout: 120)
        try await waitForDeviceHIDAttachmentAfterBootIfRequired()
        #expect(
            try await waitForSpringBoardState("lockstate", expectedState: 0) == 0,
            "A freshly booted simulator should be unlocked"
        )
    }

    private func prepareUnlockedSimulator() async throws {
        if try await springBoardState("lockstate") != 0 {
            try await rebootSimulator()
        } else {
            try await waitForDeviceHIDServiceIfRequired()
        }
    }

    private func runButtonCommand(_ command: String) async throws -> Duration {
        try await prepareUnlockedSimulator()
        let startTime = ContinuousClock.now
        do {
            try await TestHelpers.runAxeCommand(command, simulatorUDID: defaultSimulatorUDID)
        } catch {
            try? await rebootSimulator()
            throw error
        }
        return ContinuousClock.now - startTime
    }

    private func pressLockingButton(_ command: String) async throws {
        _ = try await runButtonCommand(command)
        #expect(try await waitForSpringBoardState("lockstate", expectedState: 1) == 1)
        try await rebootSimulator()
    }

    @Test("Home button press")
    func homeButtonPress() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runAxeCommand("button home", simulatorUDID: defaultSimulatorUDID)
        
        // Note: Cannot assert UI state as home button takes us out of the app
        // This test verifies the command executes without error
    }
    
    @Test("Lock button press")
    func lockButtonPress() async throws {
        try await pressLockingButton("button lock")
    }
    
    @Test("Side button press")
    func sideButtonPress() async throws {
        _ = try await runButtonCommand("button side-button")
        #expect(
            try await waitForSpringBoardState("hasBlankedScreen", expectedState: 1) == 1,
            "A short side-button press should blank the simulator display"
        )
        try await rebootSimulator()
    }

    @Test("Apple Pay button command executes")
    func applePayButtonPress() async throws {
        try await waitForDeviceHIDServiceIfRequired()
        try await TestHelpers.runAxeCommand("button apple-pay", simulatorUDID: defaultSimulatorUDID)
    }

    @Test("Siri button command executes")
    func siriButtonPress() async throws {
        try await waitForDeviceHIDServiceIfRequired()
        try await TestHelpers.runAxeCommand("button siri", simulatorUDID: defaultSimulatorUDID)
    }
    
    @Test("Button press with duration")
    func buttonPressWithDuration() async throws {
        let duration = try await runButtonCommand("button lock --duration 2")
        #expect(duration >= .seconds(2), "Command should hold the button for at least 2 seconds")
        try await rebootSimulator()
    }
}
