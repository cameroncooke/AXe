import ArgumentParser
import Foundation
import Testing
@testable import AXe

/// Routing for physical devices: one detector, and every option refusal before a lease or input.
@Suite("Physical device command routing")
@MainActor
struct PhysicalDeviceCommandTests {
    static let device = "00000001-0000000000000001"
    static let simulator = "8775B9A0-A491-4182-88CD-43600178780F"

    /// The failure code a refusal throws, or the error type when it is not a coded failure.
    private func refusal(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let failure as CLIOutputFailure {
            return failure.code
        } catch {
            return String(describing: Swift.type(of: error))
        }
    }

    @Test func simulatorUDIDKeepsTheSimulatorRoute() async throws {
        let key = try Key.parse(["40", "--udid", Self.simulator])
        #expect(try await key.runOnDeviceIfTargeted() == false)
        let tap = try Tap.parse(["-x", "1", "-y", "2", "--udid", Self.simulator])
        #expect(try await tap.runOnDeviceIfTargeted() == false)
    }

    /// Refusals throw before `PhysicalDeviceInput.withSession`, which would start the broker lease.
    @Test func refusalsComeBeforeTheLease() async throws {
        let commands: [any PhysicalDeviceCommand] = [
            try Key.parse(["40", "--udid", Self.device, "--input-mode", "selected", "--focus-id", "field"]),
            try KeySequence.parse(["--keycodes", "4,5", "--udid", Self.device, "--input-mode", "selected",
                                   "--focus-id", "field"]),
            try KeyCombo.parse(["--modifiers", "227", "--key", "4", "--udid", Self.device, "--input-mode",
                                "selected", "--focus-id", "field"]),
            try Type.parse(["hello", "--udid", Self.device, "--input-mode", "selected", "--focus-id", "field"]),
            try Swipe.parse(["--start-x", "1", "--start-y", "1", "--end-x", "9", "--end-y", "9",
                             "--udid", Self.device, "--input-mode", "selected"]),
            try Drag.parse(["--start-x", "1", "--start-y", "1", "--end-x", "9", "--end-y", "9",
                            "--udid", Self.device, "--input-mode", "selected"]),
            try Draw.parse(["1,1", "9,9", "--udid", Self.device, "--input-mode", "selected"]),
            try Touch.parse(["-x", "1", "-y", "1", "--down", "--udid", Self.device]),
            try Gesture.parse(["swipe-from-right-edge", "--udid", Self.device]),
            try Button.parse(["side-button", "--udid", Self.device]),
            try Rotate.parse(["left", "--udid", Self.device, "--verbose"]),
            try DescribeUI.parse(["--udid", Self.device, "--input-mode", "selected"]),
            try Tap.parse(["-x", "1", "-y", "1", "--udid", Self.device, "--tap-style", "simulator"]),
        ]
        for command in commands {
            do {
                _ = try await command.runOnDeviceIfTargeted()
                Issue.record("\(Swift.type(of: command)) reached the device")
            } catch let failure as CLIOutputFailure {
                #expect(failure.code == "unsupportedOnDevice", "\(Swift.type(of: command)): \(failure.message)")
            }
        }
    }

    @Test func keyAndTextChecksComeBeforeTheLease() async throws {
        let combo = try KeyCombo.parse(["--modifiers", "4", "--key", "5", "--udid", Self.device])
        #expect(refusal { try combo.validateOnDevice(inBatch: false) } == "ValidationError")
        let text = try Type.parse(["caf\u{E9}", "--udid", Self.device])
        #expect(refusal { try text.validateOnDevice(inBatch: false) } == "TextConversionError")
        let long = try Type.parse([String(repeating: "a", count: 257), "--udid", Self.device])
        #expect(refusal { try long.validateOnDevice(inBatch: false) } == "ValidationError")
        #expect(refusal { try Type.parse(["hello", "--udid", Self.device]).validateOnDevice(inBatch: false) } == nil)
    }

    @Test func batchStepsApplyTheBatchRules() throws {
        let partial = try Touch.parse(["-x", "1", "-y", "1", "--down", "--udid", Self.device])
        #expect(refusal { try partial.validateOnDevice(inBatch: false) } == "unsupportedOnDevice")
        #expect(refusal { try partial.validateOnDevice(inBatch: true) } == nil)

        let press = try Tap.parse(["--semantic-press", "--id", "switch", "--udid", Self.device])
        #expect(refusal { try press.validateOnDevice(inBatch: false) } == nil)
        #expect(refusal { try press.validateOnDevice(inBatch: true) } == "unsupportedOnDevice")

        let pinch = try Gesture.parse(["pinch", "--scale", "2", "--udid", Self.device])
        #expect(refusal { try pinch.validateOnDevice(inBatch: false) } == nil)
        #expect(refusal { try pinch.validateOnDevice(inBatch: true) } == "unsupportedOnDevice")
        let preset = try Gesture.parse(["scroll-up", "--udid", Self.device])
        #expect(refusal { try preset.validateOnDevice(inBatch: true) } == nil)
    }

    @Test func everyBatchInputStepMapsToItsCommand() {
        let expected: [BatchStepKind: String] = [
            .tap: "Tap", .swipe: "Swipe", .gesture: "Gesture", .draw: "Draw", .touch: "Touch", .type: "Type",
            .button: "Button", .key: "Key", .keySequence: "KeySequence", .keyCombo: "KeyCombo",
        ]
        for (kind, name) in expected {
            #expect(PhysicalDeviceBatch.commandType(for: kind).map { String(describing: $0) } == name)
        }
        #expect(PhysicalDeviceBatch.commandType(for: .sleep) == nil)
    }
}
