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

    /// A native operation that failed without a typed AXe policy code. The code names the
    /// failure's cause so an agent can branch on it; the message is fixed text.
    static func nativeFailure(_ native: SelectedHIDResponse) -> AgentModeFailure {
        let code = nativeCode(native)
        return AgentModeFailure(code, message(code: code, native: native))
    }

    private static func nativeCode(_ native: SelectedHIDResponse) -> String {
        if native.quarantine != nil || native.cleanup == "uncertain" { return "cleanupUncertain" }
        switch native.ax?.failure {
        case .ownershipRejected: return "busy"
        case .acquisitionFailed: return "observationFailed"
        case .targetRejected: return "targetCovered"
        case .pressFailed, .sliderFailed, .inputFailed: return "inputIncomplete"
        case .cleanupUncertain: return "cleanupUncertain"
        case .responseTooLarge: return "responseTooLarge"
        case .setupFailed: return "displayChanged"
        case .waitTimedOut: return "waitTimedOut"
        case .waitCancelled: return "waitCancelled"
        case nil: return "nativeActionFailed"
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
                slider: slider(value.slider), sliderValue: sliderValue(value.sliderValue),
                retried: value.retried)
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
            return "AXe could not confirm that the touch or key was released, so the simulator may still be holding input. Send no more input until you have followed the recovery steps in the cleanup receipt."
        }
        if let failure = native?.ax?.failure {
            switch failure {
            case .ownershipRejected:
                return "Another input on this simulator was still running, so nothing was sent. Wait for it to finish, then act again from a current capture."
            case .acquisitionFailed:
                return "AXe could not read the app's accessibility tree, so nothing was sent. The app may still be launching or busy: run describe-ui again and act from that capture."
            case .targetRejected:
                return "Another control is at the tap point (yours is covered or has moved), so nothing was sent. Check the capture in this reply, then scroll it into view, close what covers it, or choose it again."
            case .pressFailed, .sliderFailed, .inputFailed:
                return "The input started but did not finish. Do not repeat it: read the screen to see what happened, and check the event count in the action receipt."
            case .cleanupUncertain:
                return "AXe could not confirm that the touch or key was released, so the simulator may still be holding input. Send no more input until you have followed the recovery steps in the cleanup receipt."
            case .responseTooLarge:
                return "The reply was too large to return, and input may have been sent. Read the screen before acting again; do not repeat the input."
            case .setupFailed:
                return "AXe could not start the input because the screen or display changed as it began, so nothing was sent. Act again from a current capture."
            case .waitTimedOut:
                return "The control did not become ready before the wait ended, so nothing was sent. Check a current capture to see whether it exists, then try again."
            case .waitCancelled:
                return "The wait for the control was cancelled, so nothing was sent. Act again from a current capture."
            }
        }
        switch code {
        case "observationFailed", "batchObservationFailed":
            return "AXe could not read the simulator screen, so nothing was sent. Run describe-ui again; if it keeps failing, check that the app is in the foreground."
        case "batchStopped":
            return "The batch stopped. The receipt lists the completed steps, which were not undone. Read the screen before planning the remaining steps; do not resend the batch."
        default:
            return "The input did not finish cleanly. Check the action receipt: do not repeat input that reports sent events, and read the screen to see what happened."
        }
    }
}
