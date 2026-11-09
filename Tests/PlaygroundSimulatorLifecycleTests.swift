import Foundation
import Testing

/// Run last. This suite shuts down only the explicit Duo target and does not boot it again.
@Suite("Playground Simulator Lifecycle E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundSimulatorLifecycleTests {
    @Test("Shutdown affects only the target, confirms completion and rejects broad targets")
    func shutdownOneSimulator() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let target = try #require(UUID(uuidString: udid))
        let cli = try TestHelpers.getAxePath()
        let base = try #require(ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"])
        let directory = URL(fileURLWithPath: base).appendingPathComponent("shutdown-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = try await inventory(directory: directory, name: "before")
        try #require(before[target] == "Booted", "The last lifecycle check needs the existing booted Duo.")
        try #require(before.contains { $0.key != target && $0.value == "Booted" },
            "A second warm simulator is required to prove it is preserved.")
        let first = try await command([cli, "--output", "json", "shutdown", "--udid", udid], directory: directory, name: "shutdown")
        try #require(first.exitCode == 0, "Shutdown failed: \(first.output)")
        try OutputSchemas.validate(output: first.output)
        let completed = try JSONDecoder().decode(ShutdownAcceptanceEnvelope.self, from: Data(first.output.utf8)).data.result
        try #require(UUID(uuidString: completed.udid) == target)
        try #require(completed.initialState == "Booted" && completed.outcome == "shutDown")
        let after = try await inventory(directory: directory, name: "after")
        try #require(after[target] == "Shutdown")
        try requireOtherDevicesPreserved(before, after, target: target)
        let again = try await command([cli, "shutdown", "--udid", udid], directory: directory, name: "already-shutdown")
        try #require(again.exitCode == 0)
        try #require(again.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "\(udid) was already shut down".lowercased())
        for invalid in ["all", "booted", "not-a-uuid"] {
            let rejected = try await command([cli, "shutdown", "--udid", invalid], directory: directory, name: invalid)
            try #require(rejected.exitCode != 0)
        }
        let final = try await inventory(directory: directory, name: "final")
        try #require(final == after, "A rejected target changed a simulator state.")
    }

    private func inventory(directory: URL, name: String) async throws -> [UUID: String] {
        let output = try await command(["/usr/bin/xcrun", "simctl", "list", "devices", "--json"], directory: directory, name: name)
        try #require(output.exitCode == 0)
        let value = try JSONDecoder().decode(ShutdownDeviceInventory.self, from: Data(output.output.utf8))
        let devices = value.devices.values.flatMap { $0 }
        let identifiers = Set(devices.map(\.udid))
        try #require(identifiers.count == devices.count)
        return Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, $0.state) })
    }

    private func command(_ argv: [String], directory: URL, name: String) async throws -> CommandOutput {
        try JSONEncoder().encode(argv).write(to: directory.appendingPathComponent(name + "-argv.json"))
        let output = try await CommandRunner.run(argv.map(playgroundShellQuote).joined(separator: " "),
            allowFailure: true, timeout: 65)
        try Data(output.output.utf8).write(to: directory.appendingPathComponent(name + "-output.txt"))
        return CommandOutput(output: output.output, exitCode: output.exitCode)
    }

    private func requireOtherDevicesPreserved(_ before: [UUID: String], _ after: [UUID: String], target: UUID) throws {
        try #require(Set(before.keys) == Set(after.keys))
        for (device, state) in before where device != target { try #require(after[device] == state) }
    }
}

private struct ShutdownAcceptanceEnvelope: Decodable {
    struct Payload: Decodable { let result: Receipt }
    struct Receipt: Decodable {
        let udid: String
        let initialState: String
        let outcome: String
    }
    let data: Payload
}

private struct ShutdownDeviceInventory: Decodable {
    let devices: [String: [Device]]
    struct Device: Decodable { let udid: UUID; let state: String }
}
