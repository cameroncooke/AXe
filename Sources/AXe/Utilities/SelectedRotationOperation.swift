import Foundation
import FBControlCore
import FBSimulatorControl

/// The shared owner holds admission and the per-device input lease throughout this operation.
@MainActor
enum SelectedRotationOperation {
    static func perform(_ request: SelectedHIDRequest, simulatorUDID: String,
                        brokerID: UUID, logger: AxeLogger) async -> SelectedHIDResponse {
        guard let rotation = request.rotation else {
            return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: brokerID, outcome: "rejectedBeforeInput", token: nil, enqueuedEventCount: 0,
                cleanup: "notNeeded", error: "Missing rotation payload", context: nil)
        }
        var result = SelectedRotationResult(direction: rotation.direction)
        do {
            try rotation.validate()
            try Task.checkCancellation()
            let display = try request.selectedDisplay()
            let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
            result.receipt = try await FBSimulatorRotationNative.rotate(for: simulator,
                screenID: display.id, screenUUID: display.uuid, expectedBootIdentity: rotation.expectedBootIdentity,
                direction: rotation.direction, timeoutSeconds: rotation.timeoutSeconds)
        } catch {
            result.failure = error as? FBSimulatorRotationFailure ?? FBSimulatorRotationFailure(
                detail: String(describing: error), delivery: .notDispatched, before: nil)
        }
        let context = result.receipt?.after ?? result.failure?.before
        return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: brokerID, outcome: result.failure == nil ? "observedRotation" :
                (result.failure?.delivery == .uncertain ? "failedNoReplay" : "failedBeforeInput"),
            token: nil, enqueuedEventCount: 0, cleanup: "notNeeded", error: result.failure?.detail,
            context: context.flatMap { try? $0.sessionObservation() }.map(SelectedHIDContext.init), rotation: result)
    }
}
