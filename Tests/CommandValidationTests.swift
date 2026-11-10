import ArgumentParser
import Foundation
import Testing
@testable import AXe

/// Option checks that refuse a command before it reads or touches a simulator.
@Suite("Command option validation")
struct CommandValidationTests {
    private static let udid = "4A4D3F14-5E8B-4C5B-9D1E-4F2A5B6C7D8E"

    private func refusal<Command: ParsableCommand>(_ type: Command.Type, _ arguments: [String]) -> String? {
        do {
            _ = try type.parse(arguments + ["--udid", Self.udid])
            return nil
        } catch {
            return type.message(for: error)
        }
    }

    @Test("key-combo refuses empty, out-of-range and too many modifiers and an out-of-range key", arguments: [
        (["--modifiers", "", "--key", "4"], "All modifier keycodes must be valid integers."),
        (["--modifiers", "256", "--key", "4"], "All modifier keycodes must be between 0 and 255. Invalid keycode: 256"),
        (["--modifiers", "227", "--key", "300"], "Key must be between 0 and 255."),
        (["--modifiers", Array(repeating: "227", count: 9).joined(separator: ","), "--key", "4"],
         "At most 8 modifier keycodes may be provided."),
    ])
    func keyCombo(arguments: [String], message: String) {
        #expect(refusal(KeyCombo.self, arguments)?.contains(message) == true)
    }

    @Test("key-sequence refuses empty and out-of-range keycodes, a negative delay and over 100 keys", arguments: [
        (["--keycodes", ""], "All keycodes must be valid integers."),
        (["--keycodes", "11,256,15"], "All keycodes must be between 0 and 255. Invalid keycode: 256"),
        (["--keycodes", "11,8,15", "--delay=-0.5"], "Delay must be non-negative."),
        (["--keycodes", Array(repeating: "4", count: 101).joined(separator: ",")], "Key sequence must not exceed 100 keys."),
    ])
    func keySequence(arguments: [String], message: String) {
        #expect(refusal(KeySequence.self, arguments)?.contains(message) == true)
    }

    @Test("Valid key, key-combo and key-sequence options parse")
    func validKeyOptions() throws {
        _ = try Key.parse(["4", "--duration", "1", "--udid", Self.udid])
        _ = try KeyCombo.parse(["--modifiers", "227,225", "--key", "4", "--udid", Self.udid])
        _ = try KeySequence.parse(["--keycodes", "11,8,15", "--delay", "0.5", "--udid", Self.udid])
    }

    @Test("batch takes exactly one step source")
    func batchSource() {
        #expect(refusal(Batch.self, ["--step", "tap -x 1 -y 2", "--file", "/tmp/steps.txt"])?
            .contains("Specify exactly one step source: --step, --file, or --stdin.") == true)
        #expect(refusal(Batch.self, ["--step", "tap -x 1 -y 2", "--stdin"]) != nil)
        #expect(refusal(Batch.self, []) != nil)
    }

    @Test("stream-video refuses native H.264 on a simulator and out-of-range settings", arguments: [
        (["--format", "h264"], "Native --format h264 requires a physical device UDID."),
        (["--fps", "40"], "FPS must be between 1 and 30"),
        (["--quality", "101"], "Quality must be between 1 and 100"),
        (["--scale", "0.05"], "Scale must be between 0.1 and 1.0"),
    ])
    func streamVideo(arguments: [String], message: String) {
        #expect(refusal(StreamVideo.self, arguments)?.contains(message) == true)
    }

    @Test("record-video refuses an FPS outside 1...30", arguments: ["0", "40"])
    func recordVideo(fps: String) {
        #expect(refusal(RecordVideo.self, ["--fps", fps])?.contains("FPS must be between 1 and 30") == true)
    }
}

/// `list-simulators` against the host's real simulator set. No simulator is booted or changed.
@Suite("List simulators output")
struct ListSimulatorsOutputTests {
    private struct Inventory: Decodable {
        let data: Payload
        struct Payload: Decodable { let result: Result }
        struct Result: Decodable { let simulators: [Simulator] }
        struct Simulator: Decodable { let udid: String; let name: String; let state: String; let osVersion: String }
    }

    private struct SimctlDevices: Decodable {
        let devices: [String: [Device]]
        struct Device: Decodable { let udid: String; let name: String; let isAvailable: Bool? }
    }

    private func simctlDevices() async throws -> [String: String] {
        let result = try await CommandRunner.run("xcrun simctl list devices available -j", timeout: 60)
        let json = result.output.firstIndex(of: "{").map { String(result.output[$0...]) } ?? ""
        let devices = try JSONDecoder().decode(SimctlDevices.self, from: Data(json.utf8)).devices.values.joined()
        return Dictionary(devices.map { ($0.udid, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("Text and JSON list every available simulator with its name, state and runtime")
    func listsHostSimulators() async throws {
        let before = try await simctlDevices()
        let axe = try TestHelpers.getAxePath()
        let json = try await CommandRunner.run(shellQuote(axe) + " list-simulators --output json", timeout: 60)
        let text = try await CommandRunner.run(shellQuote(axe) + " list-simulators", timeout: 60)
        let after = try await simctlDevices()
        let listed = try JSONDecoder().decode(Inventory.self, from: Data(json.output.utf8)).data.result.simulators
        let byUDID = Dictionary(listed.map { ($0.udid, $0) }, uniquingKeysWith: { first, _ in first })
        // Another process can add or remove a simulator meanwhile; check the ones present throughout.
        for (udid, name) in before where after[udid] == name {
            let simulator = try #require(byUDID[udid], "list-simulators omitted \(name) \(udid)")
            #expect(simulator.name == name && !simulator.state.isEmpty && !simulator.osVersion.isEmpty)
            #expect(text.output.contains(udid), "The text listing omitted \(udid)")
        }
        #expect(listed.count == Set(listed.map(\.udid)).count, "list-simulators repeated a UDID")
    }
}
