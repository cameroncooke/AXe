import Foundation
import FBSimulatorControl

/// Internal operation boundaries; the CLI always uses live dependencies.
/// The owner retains one state machine and the same lock for every implementation.
@MainActor
struct SelectedAXDependencies {
    typealias Execute = @MainActor (SelectedHIDRequest, String, UUID, AxeLogger, (any AgentOwnedTapAdmission)?) async -> SelectedHIDResponse
    typealias Persist = @MainActor (String, SelectedHIDResponse, SelectedHIDRequest?) throws -> Void
    let execute: Execute
    let persist: Persist
    let now: @MainActor () -> TimeInterval

    static var live: Self { live(transportOwner: nil) }

    static func live(transportOwner: FBSimulatorHIDTransportOwner?) -> Self {
        Self(execute: { request, udid, brokerID, logger, batchTap in
            if request.keyboard != nil {
                return await SelectedKeyboardOperation.perform(request, simulatorUDID: udid, brokerID: brokerID, logger: logger, transportOwner: transportOwner)
            }
            if request.hinge != nil {
                return await SelectedHingeOperation.perform(request, simulatorUDID: udid, brokerID: brokerID, logger: logger)
            }
            if request.rotation != nil {
                return await SelectedRotationOperation.perform(request, simulatorUDID: udid, brokerID: brokerID, logger: logger)
            }
            return await SelectedAXOperation.perform(request, simulatorUDID: udid, brokerID: brokerID, logger: logger, transportOwner: transportOwner, batchTap: batchTap)
        }, persist: { udid, response, request in
            try HIDInputQuarantine.persist(simulatorUDID: udid, response: response, request: request)
        }, now: { ProcessInfo.processInfo.systemUptime })
    }
}
