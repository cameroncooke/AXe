import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Rotate: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rotate a physical device or the iPhone Duo left or right.",
        discussion: "Sends one request and never repeats it. On a physical device, AXe waits until the display reaches the orientation the device reports. On the iPhone Duo, it shows the active screen afterwards. Without --screen-id and --screen-uuid, AXe uses the screen that is active when the command starts. With them, the command refuses if that screen is no longer active.")
    @Argument(help: "Direction: left or right.") var direction: String
    @Option(name: .customLong("udid"), help: "Simulator or physical device UDID.") var simulatorUDID: String
    @Option(name: .customLong("screen-id"), help: "Duo only, optional: refuse unless this screen is active. Requires --screen-uuid.") var screenID: UInt32?
    @Option(name: .customLong("screen-uuid"), help: "Duo only, optional: refuse unless this screen is active. Requires --screen-id.") var screenUUID: String?
    @Option(name: .customLong("expected-boot"),
        help: ArgumentHelp("Refuse unless the simulator boot identity is PID:SECONDS:MICROSECONDS.", visibility: .hidden))
    var expectedBoot: String?
    @Option(name: .customLong("timeout"), help: "Seconds to wait for the rotation, 0.5...15.") var timeout: Double = 8
    @Flag(name: .customLong("verbose"), help: "Duo only: print the full broker reply as JSON: context before and after, receipts and boot identity.")
    var verbose = false

    func validate() throws {
        guard FBSimulatorRotationDirection(rawValue: direction) != nil else {
            throw ValidationError("Direction must be left or right")
        }
        guard timeout.isFinite, (0.5...15).contains(timeout) else {
            throw ValidationError("--timeout must be in 0.5...15 seconds")
        }
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID) { return }
        guard UUID(uuidString: simulatorUDID) != nil else { throw ValidationError("Invalid simulator UDID") }
        guard (screenID == nil) == (screenUUID == nil) else {
            throw ValidationError("Pass both --screen-id and --screen-uuid, or neither")
        }
        if let screenUUID, UUID(uuidString: screenUUID) == nil { throw ValidationError("Invalid --screen-uuid") }
        if let expectedBoot {
            try SelectedHingeRequest(kind: .read, expectedBootIdentity: expectedBoot,
                degrees: nil, toleranceDegrees: nil, timeoutSeconds: nil).validate()
        }
    }

    func request(screenID: UInt32, screenUUID: UUID, bootIdentity: String) throws -> SelectedHIDRequest {
        guard let direction = FBSimulatorRotationDirection(rawValue: direction) else {
            throw ValidationError("Direction must be left or right")
        }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: screenUUID, operation: .complete, token: nil, primitives: [],
            rotation: SelectedRotationRequest(direction: direction, expectedBootIdentity: bootIdentity, timeoutSeconds: timeout))
        try request.validate()
        return request
    }

    func validateOnDevice(inBatch: Bool) throws {
        guard screenID == nil, screenUUID == nil, expectedBoot == nil, !verbose else {
            throw AutomationTarget.unsupportedOnDevice("Physical rotation does not accept simulator display, boot or verbose options.")
        }
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        try await input.rotate(direction == "left" ? .left : .right, timeout: timeout)
    }

    func reportOnDevice(_ result: Void) throws {
        let output = RotateOutput(udid: simulatorUDID, direction: direction, previousRotation: nil, activeScreen: nil)
        try DeviceState.emit(output, text: output.textLines)
    }

    func run() async throws {
        if try await runOnDeviceIfTargeted() { return }
        let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: AxeLogger())
        let display: (id: UInt32, uuid: UUID)
        let boot: String
        if let screenID, let screenUUID, let uuid = UUID(uuidString: screenUUID) {
            display = (screenID, uuid)
            boot = try expectedBoot ?? DeviceState.currentBootIdentity(udid: simulatorUDID)
        } else {
            let discovery = try await DeviceState.settledDiscovery(for: simulator)
            let active = discovery.readback.snapshot.activePanel.identity
            display = (active.displayID, active.uniqueID)
            boot = expectedBoot ?? discovery.bootIdentity
        }
        let response = try SelectedHIDBroker.send(
            try request(screenID: display.id, screenUUID: display.uuid, bootIdentity: boot),
            simulatorUDID: simulatorUDID)
        let receipt = try Self.receipt(from: response, verbose: verbose)
        let (discovery, displays) = try await DeviceState.displays(for: simulator)
        guard discovery.bootIdentity == boot else {
            throw CLIOutputFailure(code: "bootChanged",
                message: "The simulator restarted after the rotation. Read its state again.")
        }
        guard !verbose else { return }
        let output = RotateOutput(udid: simulatorUDID, direction: receipt.direction.rawValue,
            previousRotation: receipt.before.rotation, activeScreen: displays.activeScreen)
        try DeviceState.emit(output, text: output.textLines)
    }

    /// `verbose` prints the receipt; the checks and codes are the same with or without it.
    static func receipt(from response: SelectedHIDResponse, verbose: Bool) throws -> FBSimulatorRotationReceipt {
        if verbose { try SelectedHIDBroker.writeReceipt(response) }
        guard response.error == nil, let receipt = response.rotation?.receipt else {
            throw DeviceStateFailure.rotation(response)
        }
        return receipt
    }
}

/// A physical device reports only the direction; the iPhone Duo adds its rotation before and the
/// active screen after.
struct RotateOutput: Encodable {
    let udid: String
    let direction: String
    let previousRotation: Int?
    let activeScreen: ScreenStateOutput?

    var textLines: [String] {
        ["Rotated \(direction)"] + (activeScreen.map { DeviceStateText.screenLines($0, active: true) } ?? [])
    }
}
