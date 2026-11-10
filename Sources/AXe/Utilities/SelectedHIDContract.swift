import Foundation

/// What the owner requires of its own result before it reports success. A result that misses its
/// contract leaves the owner as a failure, so clients check only the error, the outcome and the
/// bound screen. Agent admissions keep their own verification.
enum SelectedHIDContract {
    /// `response` unchanged when it already failed or meets its contract; otherwise the same receipt
    /// with the contract's error.
    static func checked(_ response: SelectedHIDResponse, for request: SelectedHIDRequest) -> SelectedHIDResponse {
        guard request.agentAdmission == nil, !SelectedInputOutput.failed(response),
              let failure = failure(response, for: request) else { return response }
        var result = response
        result.error = failure.message
        result.errorCode = failure.code
        return result
    }

    static func failure(_ response: SelectedHIDResponse, for request: SelectedHIDRequest) -> (code: String, message: String)? {
        if let button = request.button {
            guard let result = response.button, result.kind == button.kind,
                  response.outcome == "enqueuedAndDrained", response.cleanup == "notNeeded",
                  response.enqueuedEventCount == button.expectedPrimitiveCount,
                  response.ax == nil, response.hinge == nil, response.keyboard == nil,
                  result.execution.completed(primitiveCount: button.expectedPrimitiveCount) else {
                return (CLIError.Code.inputFailed.rawValue, "The button press did not finish with every input released")
            }
        }
        guard let ax = request.ax else { return nil }
        switch ax.kind {
        case .sliderEndpoint where !sliderCompleted(response, for: ax):
            return ("sliderFailed", "The slider did not report a complete endpoint result")
        case .semanticPress where !semanticPressConfirmed(response, for: ax):
            return ("semanticPressUnconfirmed",
                "The switch value change was not confirmed. Check the switch before another action; the press was not repeated")
        default:
            return nil
        }
    }

    /// The controller owns target, domain, value and settled-read verification. Success is one of its
    /// two complete semantic outcomes, with no HID event and an action count that matches it.
    private static func sliderCompleted(_ response: SelectedHIDResponse, for ax: SelectedAXRequest) -> Bool {
        guard let actual = response.ax, let slider = actual.slider, let pid = actual.expectedPID, pid > 0,
              actual.failure == nil, actual.press == nil,
              response.enqueuedEventCount == 0, response.cleanup == "notNeeded",
              slider.outcome == response.outcome, slider.reason == nil, !slider.reasonTruncated,
              slider.actionAttempts == slider.actionsReturned,
              slider.actionsReturned == slider.actions.count else { return false }
        if let elementType = ax.elementType {
            guard !slider.samples.isEmpty,
                  slider.samples.allSatisfy({ $0.elementType?.rawValue == elementType }),
                  slider.actions.allSatisfy({ $0.elementType?.rawValue == elementType }) else { return false }
        }
        switch slider.outcome {
        case "endpointObserved":
            return slider.delivery == "valueObserved" && (1...20).contains(slider.actionsReturned)
        case "alreadyAtEndpoint":
            return slider.delivery == "notDispatched" && slider.actionsReturned == 0
        default:
            return false
        }
    }

    /// One accepted native press on the requested switch in the bound app, read back with a changed value.
    private static func semanticPressConfirmed(_ response: SelectedHIDResponse, for ax: SelectedAXRequest) -> Bool {
        guard response.outcome == "switchValueChangedObserved", response.enqueuedEventCount == 0,
              response.cleanup == "notNeeded", let actual = response.ax, actual.failure == nil,
              let pid = actual.expectedPID, pid > 0, ax.expectedPID == nil || ax.expectedPID == pid,
              let press = actual.press, press.outcome == "switchValueChangedObserved",
              press.delivery == "nativeReplyAccepted", press.failure == nil,
              press.translatorCallAttempted, press.callbackCount == 1, press.sendCount == 1,
              press.reply?.nativeResponsePresent == true, press.reply?.error == "0", press.reply?.value == true,
              let before = press.stateBefore, let after = press.stateAfter, before != after,
              let reads = press.readbackCount, (1...4).contains(reads),
              let target = press.target, target.identifier == ax.selectorValue, target.pid == pid else {
            return false
        }
        return true
    }
}

extension SelectedButtonExecutionEvidence {
    /// Every planned primitive sent and released, the queue drained, and nothing left to clean up.
    func completed(primitiveCount: Int) -> Bool {
        guard phase == "completed", plannedPrimitiveCount == primitiveCount, sentPrimitiveCount == primitiveCount,
              allInputsReleasedBeforeCleanup, drainCompleted, interruption == nil,
              executionCleanup == "notNeeded", startedUptime.isFinite, finishedUptime.isFinite,
              finishedUptime >= startedUptime, let cleanup = cleanupEvidence,
              cleanup.outcome == "notNeeded", cleanup.contextValidation == "noOwnedInput",
              cleanup.releases.isEmpty, !cleanup.timedOut, cleanup.errorDescription == nil else { return false }
        return true
    }
}
