import Foundation
import FBSimulatorControl

struct SelectedRotationRequest: Codable, Sendable {
    let direction: FBSimulatorRotationDirection
    let expectedBootIdentity: String
    let timeoutSeconds: Double

    func validate() throws {
        try SelectedHingeRequest(kind: .read, expectedBootIdentity: expectedBootIdentity,
            degrees: nil, toleranceDegrees: nil, timeoutSeconds: nil).validate()
        guard timeoutSeconds.isFinite, (0.5...15).contains(timeoutSeconds) else {
            throw SelectedHIDFailure.invalid("Rotation timeout must be in 0.5...15 seconds")
        }
    }
}

struct SelectedRotationResult: Codable, Sendable {
    let direction: FBSimulatorRotationDirection
    var receipt: FBSimulatorRotationReceipt? = nil
    var failure: FBSimulatorRotationFailure? = nil
}
