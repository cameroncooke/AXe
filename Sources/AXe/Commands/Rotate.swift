import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rotate the iPhone Duo left or right and show the active screen afterwards.",
        discussion: "Sends one request and never repeats it. Without --screen-id and --screen-uuid, AXe uses the screen that is active when the command starts. With them, the command refuses if that screen is no longer active.")
    @Argument(help: "Direction: left or right.") var direction: String
    @Option(name: .customLong("udid"), help: "Simulator UDID.") var simulatorUDID: String
    @Option(name: .customLong("screen-id"), help: "Optional: refuse unless this screen is active. Requires --screen-uuid.") var screenID: UInt32?
    @Option(name: .customLong("screen-uuid"), help: "Optional: refuse unless this screen is active. Requires --screen-id.") var screenUUID: String?
    @Option(name: .customLong("expected-boot"),
        help: ArgumentHelp("Refuse unless the simulator boot identity is PID:SECONDS:MICROSECONDS.", visibility: .hidden))
    var expectedBoot: String?
    @Option(name: .customLong("timeout"), help: "Seconds to wait for the rotation, 0.5...15.") var timeout: Double = 8
    @Flag(name: .customLong("verbose"), help: "Print the full broker reply as JSON: context before and after, receipts and boot identity.")
    var verbose = false

    func validate() throws {
        guard UUID(uuidString: simulatorUDID) != nil else { throw ValidationError("Invalid simulator UDID") }
        guard FBSimulatorRotationDirection(rawValue: direction) != nil else {
            throw ValidationError("Direction must be left or right")
        }
        guard (screenID == nil) == (screenUUID == nil) else {
            throw ValidationError("Pass both --screen-id and --screen-uuid, or neither")
        }
        if let screenUUID, UUID(uuidString: screenUUID) == nil { throw ValidationError("Invalid --screen-uuid") }
        guard timeout.isFinite, (0.5...15).contains(timeout) else {
            throw ValidationError("--timeout must be in 0.5...15 seconds")
        }
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

    func run() async throws {
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
        if verbose { try SelectedHIDBroker.printResponse(response, verbose: true); return }
        guard response.error == nil, let receipt = response.rotation?.receipt else {
            throw DeviceStateFailure.rotation(response)
        }
        let (discovery, displays) = try await DeviceState.displays(for: simulator)
        guard discovery.bootIdentity == boot else {
            throw CLIOutputFailure(code: "bootChanged",
                message: "The simulator restarted after the rotation. Read its state again.")
        }
        let output = RotateOutput(udid: simulatorUDID, direction: receipt.direction.rawValue,
            previousRotation: receipt.before.rotation, activeScreen: displays.activeScreen)
        try DeviceState.emit(output, text: output.textLines)
    }
}

struct RotateOutput: Encodable {
    let udid: String
    let direction: String
    let previousRotation: Int
    let activeScreen: ScreenStateOutput

    var textLines: [String] {
        ["Rotated \(direction)"] + DeviceStateText.screenLines(activeScreen, active: true)
    }
}
