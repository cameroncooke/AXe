import ArgumentParser
import Foundation

/// A command that also runs on a physical device. Its `run()` starts with `runOnDeviceIfTargeted()`,
/// and a physical batch runs each step through `validateOnDevice(inBatch: true)` and `runOnDevice(_:)`
/// inside the batch's one session.
protocol PhysicalDeviceCommand: AsyncParsableCommand {
    /// What `runOnDevice(_:)` hands to `reportOnDevice(_:)`.
    associatedtype DeviceResult: Sendable = Void

    var simulatorUDID: String { get }

    /// Refuses the options a physical device does not support. It does no device work, so every
    /// refusal comes before a lease and before any input. `inBatch` applies the batch step rules.
    func validateOnDevice(inBatch: Bool) throws

    @MainActor
    func runOnDevice(_ input: PhysicalDeviceInput) async throws -> DeviceResult

    /// Reports a standalone command's result after its session has closed.
    func reportOnDevice(_ result: DeviceResult) throws
}

extension PhysicalDeviceCommand where DeviceResult == Void {
    func reportOnDevice(_ result: Void) throws {}
}

extension PhysicalDeviceCommand {
    /// Runs the command on the physical device its UDID names. Returns false for a simulator UDID.
    @MainActor
    func runOnDeviceIfTargeted() async throws -> Bool {
        guard let device = try await AutomationTarget.physicalInputDevice(udid: simulatorUDID) else { return false }
        try validateOnDevice(inBatch: false)
        let result = try await PhysicalDeviceInput.withSession(for: device) { input in
            try await runOnDevice(input)
        }
        try reportOnDevice(result)
        return true
    }
}

extension SelectedInputOptions {
    /// Physical input has no agent mode and no simulator display selection.
    func refuseOnDevice(agent: Bool,
                        _ message: String = "Physical input uses coordinates without --agent or simulator display selection.") throws {
        guard mode == .legacy, screenID == nil, screenUUID == nil, !agent else {
            throw AutomationTarget.unsupportedOnDevice(message)
        }
    }
}
