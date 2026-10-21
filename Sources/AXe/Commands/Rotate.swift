import ArgumentParser
import Foundation
import FBSimulatorControl

struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rotate Duo left or right and observe the selected active screen. Sends one request without replay.")
    @Argument(help: "Direction: left or right.") var direction: String
    @Option(name: .customLong("udid"), help: "Simulator UDID.") var simulatorUDID: String
    @Option(name: .customLong("screen-id"), help: "Selected active screen ID.") var screenID: UInt32
    @Option(name: .customLong("screen-uuid"), help: "Selected active screen UUID.") var screenUUID: String
    @Option(name: .customLong("expected-boot"), help: "Fresh PID:SECONDS:MICROSECONDS boot identity.") var expectedBoot: String
    @Option(name: .customLong("timeout"), help: "Observation budget in seconds, 0.5...15. Native reads have separate bounds.") var timeout: Double = 8

    func request() throws -> SelectedHIDRequest {
        guard UUID(uuidString: simulatorUDID) != nil, let uuid = UUID(uuidString: screenUUID),
              let direction = FBSimulatorRotationDirection(rawValue: direction) else {
            throw ValidationError("Use valid simulator and screen UUIDs, and direction left or right")
        }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: uuid, operation: .complete, token: nil, primitives: [],
            rotation: SelectedRotationRequest(direction: direction, expectedBootIdentity: expectedBoot, timeoutSeconds: timeout))
        try request.validate()
        return request
    }
    func validate() throws { _ = try request() }
    func run() async throws {
        try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(try request(), simulatorUDID: simulatorUDID))
    }
}
