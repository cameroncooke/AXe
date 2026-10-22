import Foundation
import FBControlCore
import FBSimulatorControl

/// Keep the legacy CLI surface while using the measured input owner on the verified Duo.
enum LegacyDuoTap {
    @MainActor
    static func captureContext(
        simulatorUDID: String,
        preDelay: Double?,
        logger: AxeLogger
    ) async throws -> SelectedHIDContext? {
        try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
        let set = try await getSimulatorSet(
            deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared
        )
        guard let simulator = set.allSimulators.first(where: {
            UUID(uuidString: $0.udid) == UUID(uuidString: simulatorUDID)
        }), simulator.state == .booted else {
            throw CLIError.simulatorNotFound(udid: simulatorUDID)
        }
        // Do not make older rigid-device profiles depend on the Duo metadata contract.
        guard simulator.device.deviceType?.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo" else {
            return nil
        }
        let capability = try FBSimulatorNativeContextReader.capability(for: simulator)
        guard capability.hinge == .supported else {
            throw SelectedHIDFailure.invalid(capability.reason)
        }
        guard let executable = Bundle.main.executableURL else {
            throw SelectedHIDFailure.invalid("Missing executable")
        }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("cadisplay-context")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw SelectedHIDFailure.invalid("Missing signed cadisplay-context helper beside axe")
        }
        try await wait(preDelay)
        let discovery = try await ActivePanelReader.discoverWithMetadata(for: simulator)
        let panel = discovery.readback.snapshot.activePanel.identity
        let reader = FBSimulatorNativeContextReader(
            simulator: simulator, helperURL: helper, screenID: panel.displayID,
            screenUniqueID: panel.uniqueID
        )
        let observation = try await reader.observation()
        guard observation.bootIdentity == discovery.bootIdentity else {
            throw SelectedHIDFailure.invalid("Simulator boot changed during Duo tap preparation")
        }
        return SelectedHIDContext(observation)
    }

    static func perform(
        at point: (x: Double, y: Double),
        style: TapStyle,
        context: SelectedHIDContext,
        simulatorUDID: String,
        postDelay: Double?,
        logger: AxeLogger
    ) async throws {
        let selectedStyle: SelectedTapStyle
        switch style {
        case .physical: selectedStyle = .physical
        case .simulator: selectedStyle = .simulator
        case .automatic: throw SelectedHIDFailure.invalid("Duo tap requires a resolved legacy style")
        }
        guard let uuid = UUID(uuidString: context.screenUUID) else {
            throw SelectedHIDFailure.invalid("Invalid measured Duo display identity")
        }
        let request = SelectedHIDRequest(
            version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: context.screenID, screenUUID: uuid, operation: .complete, token: nil,
            primitives: try selectedStyle.primitives(x: point.x, y: point.y),
            expectedContext: context
        )
        logger.info().log("Duo tap uses screen \(context.screenID), rotation \(context.rotationDegrees), logical point (\(point.x), \(point.y))")
        let response = try SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID)
        guard response.error == nil, response.cleanup != "uncertain", response.quarantine == nil else {
            throw CLIError(errorDescription: "Duo tap failed: \(response.error ?? response.outcome); events=\(response.enqueuedEventCount); cleanup=\(response.cleanup). Input was not replayed.")
        }
        try await wait(postDelay)
    }

    private static func wait(_ seconds: Double?) async throws {
        guard let seconds, seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
