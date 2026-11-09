import Foundation
import FBControlCore
import FBSimulatorControl

/// Called only while SelectedHIDOwner holds admission and the per-device input lease.
@MainActor
enum SelectedHingeOperation {
    static func perform(_ request: SelectedHIDRequest, simulatorUDID: String,
                        brokerID: UUID, logger: AxeLogger) async -> SelectedHIDResponse {
        guard let hinge = request.hinge else {
            return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: brokerID, outcome: "rejectedBeforeInput", token: nil, enqueuedEventCount: 0,
                cleanup: "notNeeded", error: "Missing hinge payload", context: nil)
        }
        var result = SelectedHingeResult(hinge)
        do {
            try hinge.validate()
            try Task.checkCancellation()
            let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
            result.readback = try await FBSimulatorHingeNative.read(for: simulator,
                expectedBootIdentity: hinge.expectedBootIdentity)
            if hinge.kind == .read {
                return response(request, brokerID: brokerID, result: result, outcome: "observedHinge")
            }
            let observer: FBSimulatorHingeDisplayReadiness?
            if let readiness = hinge.readiness, let expectedBoot = hinge.expectedBootIdentity {
                do {
                    observer = try await FBSimulatorHingeDisplayReadiness.prepare(for: simulator,
                        expectedBootIdentity: expectedBoot, expected: readiness)
                } catch {
                    result.readinessPreflightFailure = error as? FBSimulatorHingeReadinessError ??
                        FBSimulatorHingeReadinessError(.unavailable, String(describing: error))
                    return response(request, brokerID: brokerID, result: result, outcome: "failedBeforeInput",
                        error: result.readinessPreflightFailure?.detail)
                }
            } else { observer = nil }
            // Complete response capacity and request checks precede the one vendor write.
            try SelectedHingeBounds.reserveBeforeWrite(response(request, brokerID: brokerID,
                result: result, outcome: "observedMechanicalTarget"), includesReadiness: observer != nil)
            let nativeRequest = try hinge.nativeRequest()
            let operation = FBSimulatorHingeNative.operation(for: simulator)
            let mechanical = try await operation.set(nativeRequest)
            result.receipt = mechanical
            // observe() returns a separate typed result, including cancellation and child cleanup.
            // It cannot throw into the write failure path or send another write.
            if let observer {
                let readiness = await observer.observe(after: mechanical)
                result.readiness = readiness
                result.activeDisplayCompletion = readiness.outcome == .coherent ? .coherentObserved : .incomplete
                if readiness.outcome == .incomplete {
                    return response(request, brokerID: brokerID, result: result,
                        outcome: "mechanicalTargetObservedDisplayIncomplete",
                        error: "Mechanical target was observed; display readiness incomplete: " + (readiness.failure?.code.rawValue ?? "unknown"))
                }
                return response(request, brokerID: brokerID, result: result, outcome: "observedMechanicalTargetAndDisplayCoherence")
            }
            return response(request, brokerID: brokerID, result: result, outcome: "observedMechanicalTarget")
        } catch let error as FBSimulatorHingeReadinessError {
            result.readinessPreflightFailure = error
            return response(request, brokerID: brokerID, result: result, outcome: "failedBeforeInput", error: error.detail)
        } catch {
            result.failure = SelectedHingeFailure(error)
            let outcome = result.failure?.delivery == .uncertain ? "failedNoReplay" : "failedBeforeInput"
            return response(request, brokerID: brokerID, result: result, outcome: outcome,
                error: result.failure?.detail)
        }
    }

    private static func response(_ request: SelectedHIDRequest, brokerID: UUID,
                                 result: SelectedHingeResult, outcome: String, error: String? = nil) -> SelectedHIDResponse {
        // HID event count is zero. Hinge delivery has its own typed receipt and uncertainty.
        SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: brokerID, outcome: outcome, token: nil, enqueuedEventCount: 0,
            cleanup: result.readiness?.cleanup == .unconfirmed ? "uncertain" : "notNeeded",
            error: error, context: nil, hinge: result)
    }
}
