import Foundation
import FBControlCore
import FBSimulatorControl

/// The shared owner holds admission and the per-device input lease throughout this operation.
@MainActor
enum SelectedRotationOperation {
    static func perform(_ request: SelectedHIDRequest, simulatorUDID: String,
                        brokerID: UUID, logger: AxeLogger, helperURL: URL) async -> SelectedHIDResponse {
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
            try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
            let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
            guard let simulator = set.allSimulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: simulatorUDID) }),
                  simulator.state == .booted else { throw CLIError.simulatorNotFound(udid: simulatorUDID) }
            result.receipt = try await FBSimulatorRotationNative.rotate(for: simulator, helperURL: helperURL,
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
