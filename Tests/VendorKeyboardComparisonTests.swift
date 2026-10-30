import CryptoKit
import Foundation
import Testing

enum VendorKeyboardVariant: String, CaseIterable, Sendable {
    case axeShiftThenSimuseKey
    case simuseShiftThenSimuseKey
}

/// Artifact-only comparison. It must not enter the primary suite without explicit opt-in.
@Suite("Vendor keyboard comparison", .serialized,
       .enabled(if: isE2EEnabled && ProcessInfo.processInfo.environment["AXE_VENDOR_KEYBOARD_E2E"] == "1"))
struct VendorKeyboardComparisonTests {
    private let udid = "419D3218-79E5-46DE-80C0-E58126A88252"
    private let simuse = "/Volumes/Developer/AXe/build_products/verification/duo-vendor-failures-20261026/simuse-research-v1/candidate/sim-use"
    private let simuseSHA256 = "2c58fc06dbc8615aaf5869e2fa5054915210a8bff4fe82b12d64807229b11d02"

    @Test("Compare Shift+C followed by the ordinary lowercase D key", arguments: VendorKeyboardVariant.allCases)
    func keyboardPaths(_ variant: VendorKeyboardVariant) async throws {
        let simulatorUDID = try TestHelpers.requireSimulatorUDID()
        try #require(UUID(uuidString: simulatorUDID) == UUID(uuidString: udid),
            "This comparison is restricted to the dedicated audit simulator.")
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: simuse)))
            .map { String(format: "%02x", $0) }.joined()
        try #require(digest == simuseSHA256, "The comparison requires the pinned sim-use binary.")

        // Keep the original AXe case prefix, including the fresh app and capture.
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "vendor-keyboard-" + variant.rawValue)
        try await session.focusField()
        let initial = try session.document.read()
        try #require(initial.text.isEmpty && initial.count("textChanged") == 0)
        _ = try await axeRaw(["type", "AbA"], session: session, generation: initial.generation, step: "seed")
        let seeded = try await session.document.waitFor("the original exact AbA seed") {
            $0.text == "AbA" && $0.count("textChanged") == 3
        }
        try requireState(seeded, text: "AbA", changes: 3, baseline: initial)
        _ = try await session.capture()

        if variant == .axeShiftThenSimuseKey {
            _ = try await axeRaw(["key-combo", "--modifiers", "225", "--key", "6"],
                session: session, generation: initial.generation, step: "shift-c")
        } else {
            try await vendor(["ios", "key-combo", "--modifiers", "225", "--key", "6",
                "--device", udid, "--json"], session: session, generation: initial.generation, step: "shift-c")
        }
        let upper = try await session.document.waitFor("one uppercase C callback") {
            $0.text == "AbAC" && $0.count("textChanged") == 4
        }
        try requireState(upper, text: "AbAC", changes: 4, baseline: seeded)
        try saveState(session, generation: initial.generation, name: "shift-c-settled")

        // Use the normal sim-use daemon path. Do not warm it or add duration flags.
        try await vendor(["ios", "key", "7", "--device", udid, "--json"],
            session: session, generation: initial.generation, step: "lowercase-d")
        let lower = try await session.document.waitFor("one lowercase D callback and released input") {
            $0.text == "AbACd" && $0.count("textChanged") == 5 && $0.activeWindowTouches == 0
        }
        try requireState(lower, text: "AbACd", changes: 5, baseline: upper)
        try saveState(session, generation: initial.generation, name: "lowercase-d-settled")
    }

    private func requireState(_ state: PlaygroundControlsDocument, text: String, changes: Int,
                              baseline: PlaygroundControlsDocument) throws {
        try #require(state.pid == baseline.pid && state.generation == baseline.generation)
        try #require(state.text == text && state.count("textChanged") == changes && state.textFocused)
        try #require(state.activeWindowTouches == 0 && state.windowTouchTrace == baseline.windowTouchTrace)
        try #require(state.windowTraceDropped == baseline.windowTraceDropped && state.recognizerTraceDropped == baseline.recognizerTraceDropped)
        try #require(state.slider == baseline.slider && state.switchOn == baseline.switchOn
            && state.count("tap") == baseline.count("tap"))
    }

    private func axeRaw(_ arguments: [String], session: PlaygroundAgentFeatureSession,
                        generation: UUID, step: String) async throws -> CommandOutput {
        let name = "comparison-axe-" + step + "-" + UUID().uuidString
        let argv = arguments + ["--udid", session.agent.udid]
        try saveState(session, generation: generation, name: name + "-before")
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let result = try await session.rawCommand(arguments)
            try saveReceipt(VendorKeyboardCommand(executable: TestHelpers.getAxePath(), arguments: argv,
                started: started, finished: ProcessInfo.processInfo.systemUptime,
                exitCode: result.exitCode, error: nil), session: session, name: name)
            try saveState(session, generation: generation, name: name + "-after")
            return result
        } catch {
            try? saveReceipt(VendorKeyboardCommand(executable: TestHelpers.getAxePath(), arguments: argv,
                started: started, finished: ProcessInfo.processInfo.systemUptime,
                exitCode: nil, error: String(describing: error)), session: session, name: name + "-failure")
            saveFailureState(session, generation: generation, name: name)
            throw error
        }
    }

    private func vendor(_ arguments: [String], session: PlaygroundAgentFeatureSession,
                        generation: UUID, step: String) async throws {
        let name = "comparison-simuse-" + step + "-" + UUID().uuidString
        let removedEnvironment = ["DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES",
            "SIM_USE_NO_DAEMON", "HID_TRANSPORT", "HID_SEND_TIMEOUT_MS", "HID_STABILIZATION_MS"]
        let launcherArguments = removedEnvironment.flatMap { ["-u", $0] } + [simuse] + arguments
        try JSONEncoder().encode(launcherArguments).write(to: session.artifacts.appendingPathComponent(name + "-argv.json"), options: .withoutOverwriting)
        try saveState(session, generation: generation, name: name + "-before")
        let process = try PlaygroundTestProcess(executable: "/usr/bin/env", arguments: launcherArguments,
            directory: session.artifacts, name: name)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try process.start()
            try await process.wait(timeout: 30)
            try saveReceipt(VendorKeyboardCommand(executable: "/usr/bin/env", arguments: launcherArguments,
                started: started, finished: ProcessInfo.processInfo.systemUptime,
                exitCode: process.exitCode, error: nil), session: session, name: name)
            try saveState(session, generation: generation, name: name + "-after")
            let diagnostics = try process.diagnostics()
            try #require(process.exitCode == 0, "sim-use command failed: \(diagnostics)")
            await process.finish()
        } catch {
            try? saveReceipt(VendorKeyboardCommand(executable: "/usr/bin/env", arguments: launcherArguments,
                started: started, finished: ProcessInfo.processInfo.systemUptime,
                exitCode: process.isRunning ? nil : process.exitCode, error: String(describing: error)),
                session: session, name: name + "-failure")
            saveFailureState(session, generation: generation, name: name)
            await process.finish()
            throw error
        }
    }

    private func saveState(_ session: PlaygroundAgentFeatureSession, generation: UUID, name: String) throws {
        let bytes = try Data(contentsOf: session.document.url)
        let state = try JSONDecoder().decode(PlaygroundControlsDocument.self, from: bytes)
        guard state.pid == session.pid, state.generation == generation else {
            throw TestError.unexpectedState("The vendor comparison document changed PID or page generation.")
        }
        try bytes.write(to: session.artifacts.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
    }

    private func saveFailureState(_ session: PlaygroundAgentFeatureSession, generation: UUID, name: String) {
        do { try saveState(session, generation: generation, name: name + "-after-failure") }
        catch {
            try? Data(String(describing: error).utf8).write(
                to: session.artifacts.appendingPathComponent(name + "-after-failure-error.txt"), options: .withoutOverwriting)
        }
    }

    private func saveReceipt(_ value: VendorKeyboardCommand, session: PlaygroundAgentFeatureSession, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: session.artifacts.appendingPathComponent(name + "-command.json"), options: .withoutOverwriting)
    }
}

private struct VendorKeyboardCommand: Encodable {
    let executable: String
    let arguments: [String]
    let started: TimeInterval
    let finished: TimeInterval
    let exitCode: Int32?
    let error: String?
    var elapsedSeconds: TimeInterval { finished - started }

    private enum CodingKeys: String, CodingKey { case executable, arguments, started, finished, elapsedSeconds, exitCode, error }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(executable, forKey: .executable)
        try values.encode(arguments, forKey: .arguments)
        try values.encode(started, forKey: .started)
        try values.encode(finished, forKey: .finished)
        try values.encode(elapsedSeconds, forKey: .elapsedSeconds)
        try values.encodeIfPresent(exitCode, forKey: .exitCode)
        try values.encodeIfPresent(error, forKey: .error)
    }
}
