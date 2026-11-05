import Foundation

/// Native diagnostic strings and AX trees stay in the private broker response.
/// Public agent errors use typed evidence and fixed text, never reflected errors.
enum AgentModePublicErrorProjection {
    static func project(_ error: AgentModeFailure, native: SelectedHIDResponse?) -> AgentModeFailure {
        switch error.code {
        case "nativeActionFailed", "observationFailed", "batchObservationFailed", "batchStopped":
            return AgentModeFailure(error.code, message(code: error.code, native: native))
        default:
            // Existing host policy failures already use explicit public messages.
            return error
        }
    }

    static func quarantine(_ source: SelectedHIDQuarantine?) -> SelectedHIDQuarantine? {
        source.map { value in
            SelectedHIDQuarantine(recordPath: value.recordPath, persisted: value.persisted,
                error: value.error.map { _ in value.persisted
                    ? "Input quarantine returned a diagnostic. Inspect the recovery record before more input."
                    : "Input quarantine could not be saved. Complete input recovery before more input." })
        }
    }

    static func action(_ source: AgentModeActionReceipt?) -> AgentModeActionReceipt? {
        source.map { value in
            AgentModeActionReceipt(kind: value.kind, outcome: value.outcome,
                enqueuedEventCount: value.enqueuedEventCount, cleanup: value.cleanup,
                replayed: value.replayed, quarantine: quarantine(value.quarantine),
                slider: slider(value.slider), sliderValue: sliderValue(value.sliderValue))
        }
    }

    static func batch(_ source: AgentBatchReceipt?) -> AgentBatchReceipt? {
        source.map { value in
            AgentBatchReceipt(totalSteps: value.totalSteps, completedSteps: value.completedSteps,
                steps: value.steps.map { step in
                    AgentBatchStepReceipt(index: step.index, action: step.action, status: step.status,
                        requestID: step.requestID, receipt: action(step.receipt), error: step.error,
                        cache: step.cache, context: step.context)
                }, stoppedAt: value.stoppedAt)
        }
    }

    private static func slider(_ source: SelectedSliderResult?) -> SelectedSliderResult? {
        source.map { value in
            SelectedSliderResult(agentPublic: value,
                reason: sliderReason(value.reason, delivery: value.delivery))
        }
    }

    private static func sliderValue(_ source: SelectedSliderValueResult?) -> SelectedSliderValueResult? {
        source.map { value in
            SelectedSliderValueResult(outcome: value.outcome,
                reason: sliderReason(value.reason, delivery: value.delivery), delivery: value.delivery,
                requestedPercent: value.requestedPercent, initialValue: value.initialValue,
                finalValue: value.finalValue, nativeTarget: value.nativeTarget,
                domainMinimum: value.domainMinimum, domainMaximum: value.domainMaximum,
                tolerance: value.tolerance, moves: value.moves, pickupReadPhases: value.pickupReadPhases,
                elapsedSeconds: value.elapsedSeconds, nativeReadDiagnostic: value.nativeReadDiagnostic)
        }
    }

    private static func sliderReason(_ source: String?, delivery: String) -> String? {
        source.map { _ in delivery == "uncertain"
            ? "Slider input delivery is uncertain. Inspect the scalar receipt and complete input recovery before more input."
            : "The slider operation returned a diagnostic. Inspect the scalar receipt before more input." }
    }

    private static func message(code: String, native: SelectedHIDResponse?) -> String {
        if native?.quarantine != nil || native?.cleanup == "uncertain" {
            return "Input cleanup is uncertain. Inspect the cleanup receipt and complete input recovery before more input."
        }
        if let failure = native?.ax?.failure {
            switch failure {
            case .ownershipRejected:
                return "The native operation could not acquire input ownership. Wait for current input to finish, then refresh the snapshot."
            case .acquisitionFailed:
                return "The accessibility read failed. Refresh the snapshot before more input."
            case .targetRejected:
                return "The native check rejected the selected control. Refresh the snapshot before more input."
            case .pressFailed, .sliderFailed, .inputFailed:
                return "The native input did not finish successfully. Inspect the input and cleanup receipts before more input."
            case .cleanupUncertain:
                return "Input cleanup is uncertain. Inspect the cleanup receipt and complete input recovery before more input."
            case .responseTooLarge:
                return "The native response exceeded its size limit. Inspect the input receipt before more input."
            case .setupFailed:
                return "The native input setup failed. Refresh the snapshot before more input."
            case .waitTimedOut:
                return "The selected control was not ready before the timeout. Refresh the snapshot before more input."
            case .waitCancelled:
                return "The wait for the selected control was cancelled. Refresh the snapshot before more input."
            }
        }
        switch code {
        case "observationFailed", "batchObservationFailed":
            return "The simulator observation failed. Refresh the snapshot before more input."
        case "batchStopped":
            return "The batch stopped. Inspect the completed-step receipts before more input."
        default:
            return "The native action failed. Inspect the input and cleanup receipts before more input."
        }
    }
}
