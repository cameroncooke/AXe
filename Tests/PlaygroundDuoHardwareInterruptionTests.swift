import Foundation
import Testing

@Suite("Playground Duo Hardware Interruption E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoHardwareInterruptionTests {
    @Test("Library Home and side-button holds release on fold or turn",
          arguments: ["home", "side-button"], ["fold", "rotate"])
    func libraryHardware(button: String, mode: String) async throws {
        try await verify(button: button, mode: mode, publicCLI: false)
    }

    @Test("Public Home hold releases on folding")
    func publicHomeDuringFold() async throws { try await verify(button: "home", mode: "fold", publicCLI: true) }

    @Test("Public side-button hold releases on inner rotation")
    func publicSideButtonDuringRotation() async throws { try await verify(button: "side-button", mode: "rotate", publicCLI: true) }

    private func verify(button: String, mode: String, publicCLI: Bool) async throws {
        try await preparePlaygroundChangingScreen(pose: .open, rotation: 90) {
            let controls = try await PlaygroundControlsSession()
            let environment = ProcessInfo.processInfo.environment
            let driver = try #require(environment["AXE_VERIFY_DUO_HELD_HARDWARE_PATH"])
            let probe = try #require(environment["AXE_DUO_HELD_HARDWARE_PROBE_PATH"])
            let stateOperator = try #require(environment["AXE_DUO_STATE_CHANGE_PATH"])
            try #require(FileManager.default.isReadableFile(atPath: driver))
            try #require(FileManager.default.isExecutableFile(atPath: probe))
            try #require(FileManager.default.isExecutableFile(atPath: stateOperator))
            let out = controls.artifacts.appendingPathComponent("hardware-proof")
            var arguments = ["/usr/bin/python3", driver, "--button", button, "--mode", mode, "--fold-angle", "0",
                "--cli", try TestHelpers.getAxePath(), "--device", controls.app.udid, "--pid", String(controls.pid),
                "--probe", probe, "--operator", stateOperator, "--out", out.path]
            if publicCLI { arguments.append("--public") }
            try JSONEncoder().encode(arguments).write(to: controls.artifacts.appendingPathComponent("hardware-driver-argv.json"))
            let output = try await CommandRunner.run(arguments.map(playgroundShellQuote).joined(separator: " "),
                allowFailure: true, timeout: 65)
            try Data(output.output.utf8).write(to: controls.artifacts.appendingPathComponent("hardware-driver-output.txt"))
            try #require(output.exitCode == 0, "Held hardware proof failed: \(output.output)")
            let resultURL = out.appendingPathComponent("result.json")
            let result = try JSONDecoder().decode(HeldHardwareDriverResult.self, from: Data(contentsOf: resultURL))
            try #require(result.status == "PASSED_BOUNDED" && result.cleanup == "releaseEnqueuedAndDrained")
            try #require(result.normalEventCount == 1 && result.button == button && result.mode == mode)
            if publicCLI { try #require(result.proof == "publicCLIWithRetrospectiveTiming") }
            else {
                try #require(result.proof == "realLibrarySessionNotPublicCLI")
                let raw = try JSONDecoder().decode(PlaygroundNativeHoldReceipt.self,
                    from: Data(contentsOf: out.appendingPathComponent("hardware-probe-stdout")))
                let runtimeDirectory = URL(fileURLWithPath: try TestHelpers.getAxePath()).deletingLastPathComponent().standardizedFileURL.path + "/"
                try #require(raw.frameworkPath.hasPrefix(runtimeDirectory))
            }
            try await HardwareAcceptanceSession(controls: controls).returnToSameApp()
            try await runPlaygroundRefindProof(controls)
            let after = try controls.documents.read()
            try #require(after.count("tap") == 1)
            try after.requireClear()
            try controls.preserveState("held-hardware-fresh-physical-tap")
        }
    }
}

/// Reuse the exact prior physical Button proof on the current normal Playground process.
func runPlaygroundRefindProof(_ controls: PlaygroundControlsSession) async throws {
    let driver = try #require(ProcessInfo.processInfo.environment["AXE_VERIFY_DUO_CONTROLS_PATH"])
    try #require(FileManager.default.isReadableFile(atPath: driver))
    let arguments = ["/usr/bin/python3", driver, "--case", "refind", "--cli", try TestHelpers.getAxePath(),
        "--device", controls.app.udid, "--pid", String(controls.pid),
        "--out", controls.artifacts.appendingPathComponent("fresh-physical-" + UUID().uuidString).path]
    let output = try await CommandRunner.run(arguments.map(playgroundShellQuote).joined(separator: " "),
        allowFailure: true, timeout: 45)
    try Data(output.output.utf8).write(to: controls.artifacts.appendingPathComponent("fresh-physical-driver-" + UUID().uuidString + ".txt"))
    try #require(output.exitCode == 0, "Fresh physical Button proof failed: \(output.output)")
}

private struct HeldHardwareDriverResult: Decodable {
    let status: String
    let cleanup: String
    let normalEventCount: Int
    let button: String
    let mode: String
    let proof: String
}
