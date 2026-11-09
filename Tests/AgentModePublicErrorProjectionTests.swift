import Foundation
import Testing
@testable import AXe

@Suite("Public agent native failures")
struct AgentModePublicErrorProjectionTests {
    private let objectID = "12001969888172651012"
    private var diagnostic: String {
        "FBSimulatorAXTargetHitFailure(nativeIdentity: objectID:" + objectID + ") " +
            String(repeating: "private-tree-label ", count: 5000)
    }

    @Test("Typed rejected-hit failures do not publish reflected trees in any output view")
    func nativeTreesStayPrivate() throws {
        let native = response(failure: .targetRejected)
        let original = AgentModeFailure("nativeActionFailed", diagnostic)
        let projected = AgentModePublicErrorProjection.project(original, native: native)
        #expect(projected.code == original.code)
        #expect(projected.message == "Another control is at the tap point (yours is covered or has moved), so nothing was sent. Check the capture in this reply, then scroll it into view, close what covers it, or choose it again.")
        #expect(projected.message.utf8.count < 256)
        #expect(native.error == diagnostic && original.message == diagnostic)
        let action = AgentModeActionReceipt(kind: .tap, outcome: native.outcome,
            enqueuedEventCount: native.enqueuedEventCount, cleanup: native.cleanup, replayed: false,
            quarantine: native.quarantine)
        let value = AgentModeResult(error: projected, action: action,
            cache: .init(status: "invalidated", reason: projected.code, requiresRefresh: true),
            nextSteps: ["Input was not replayed."])
        for view in [AgentOutputView.full, .reading, .navigation] {
            let output = try render(value, view: view)
            let text = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            let rendered = CLIOutputText.render(output)
            #expect(!rendered.contains(objectID) && !rendered.contains("private-tree-label"))
            #expect(!text.contains(objectID) && !text.contains("nativeIdentity"))
            #expect(!text.contains("private-tree-label") && !text.contains("FBSimulatorAXTargetHitFailure"))
            #expect(output["error"]?["code"]?.stringValue == "nativeActionFailed")
            #expect(output["data"]?["action"]?["outcome"]?.stringValue == "failedBeforeInput")
            #expect(output["data"]?["action"]?["enqueuedEventCount"]?.scalarText == "0")
            #expect(output["data"]?["action"]?["cleanup"]?.stringValue == "notNeeded")
            #expect(output["data"]?["action"]?["replayed"]?.boolValue == false)
        }
    }

    @Test("Unknown native failures use fixed messages across action, observation and batch boundaries")
    func unknownNativeFailureHasNoStringFallback() {
        for code in ["nativeActionFailed", "observationFailed", "batchObservationFailed", "batchStopped"] {
            let projected = AgentModePublicErrorProjection.project(.init(code, diagnostic), native: response())
            #expect(projected.code == code)
            #expect(projected.message.utf8.count < 256)
            #expect(!projected.message.contains(objectID) && !projected.message.contains("private-tree-label"))
        }
        let unknown = AgentModePublicErrorProjection.project(.init("nativeActionFailed", diagnostic), native: nil)
        #expect(unknown.message == "The input did not finish cleanly. Check the action receipt: do not repeat input that reports sent events, and read the screen to see what happened.")
        let stopped = AgentModePublicErrorProjection.project(.init("batchStopped", diagnostic), native: nil)
        #expect(stopped.message == "The batch stopped. The receipt lists the completed steps, which were not undone. Read the screen before planning the remaining steps; do not resend the batch.")
    }

    @Test(arguments: [SelectedAXFailure.ownershipRejected, .acquisitionFailed, .targetRejected,
        .pressFailed, .sliderFailed, .inputFailed, .cleanupUncertain, .responseTooLarge,
        .setupFailed, .waitTimedOut, .waitCancelled])
    func everyTypedAXFailureHasBoundedPublicText(_ kind: SelectedAXFailure) {
        let projected = AgentModePublicErrorProjection.project(.init("nativeActionFailed", diagnostic),
            native: response(failure: kind))
        #expect(projected.code == "nativeActionFailed")
        #expect(projected.message.utf8.count < 256)
        #expect(!projected.message.contains(objectID) && !projected.message.contains("private-tree-label"))
    }

    @Test("Each typed native failure has its own public code and fixed message", arguments: [
        (SelectedAXFailure.ownershipRejected, "busy"), (.acquisitionFailed, "observationFailed"),
        (.targetRejected, "targetCovered"), (.pressFailed, "inputIncomplete"), (.sliderFailed, "inputIncomplete"),
        (.inputFailed, "inputIncomplete"), (.cleanupUncertain, "cleanupUncertain"),
        (.responseTooLarge, "responseTooLarge"), (.setupFailed, "displayChanged"),
        (.waitTimedOut, "waitTimedOut"), (.waitCancelled, "waitCancelled"),
    ])
    func everyTypedAXFailureHasItsOwnCode(_ kind: SelectedAXFailure, code: String) {
        let native = response(failure: kind)
        let failure = AgentModePublicErrorProjection.nativeFailure(native)
        #expect(failure.code == code)
        #expect(failure.message == AgentModePublicErrorProjection.project(.init("nativeActionFailed", diagnostic),
            native: native).message)
        #expect(!failure.message.contains(objectID) && !failure.message.contains("private-tree-label"))
        // Projecting the typed failure again keeps its code and text.
        let projected = AgentModePublicErrorProjection.project(failure, native: native)
        #expect(projected.code == code && projected.message == failure.message)
    }

    @Test("An untyped native failure stays nativeActionFailed; uncertain cleanup is cleanupUncertain")
    func untypedAndUncertainNativeFailures() {
        #expect(AgentModePublicErrorProjection.nativeFailure(response()).code == "nativeActionFailed")
        #expect(AgentModePublicErrorProjection.nativeFailure(
            response(failure: .targetRejected, cleanup: "uncertain")).code == "cleanupUncertain")
        #expect(AgentModePublicErrorProjection.nativeFailure(
            response(failure: .inputFailed, count: 2, quarantined: true)).code == "cleanupUncertain")
    }

    @Test("Public batch failure retains partial delivery, cleanup, quarantine and no-replay evidence")
    func failedBatchEvidenceIsNotCompactedAway() throws {
        let native = response(failure: .inputFailed, count: 2, cleanup: "uncertain", quarantined: true)
        let projected = AgentModePublicErrorProjection.project(.init("nativeActionFailed", diagnostic), native: native)
        #expect(projected.message == "AXe could not confirm that the touch or key was released, so the simulator may still be holding input. Send no more input until you have followed the recovery steps in the cleanup receipt.")
        let action = AgentModeActionReceipt(kind: .tap, outcome: native.outcome,
            enqueuedEventCount: 2, cleanup: "uncertain", replayed: false, quarantine: native.quarantine)
        let cache = AgentModeCacheState(status: "quarantined", reason: projected.code, requiresRefresh: true)
        let step = AgentBatchStepReceipt(index: 1, action: .tap, status: "failed", requestID: UUID(),
            receipt: action, error: projected, cache: cache, context: nil)
        let value = AgentModeResult(error: projected, action: action,
            batch: .init(totalSteps: 2, completedSteps: 0, steps: [step], stoppedAt: 1),
            cache: cache, quarantine: native.quarantine,
            nextSteps: ["Completed steps were not undone; no step was replayed."])
        for view in [AgentOutputView.full, .reading, .navigation] {
            let output = try render(value, view: view)
            let text = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            let rendered = CLIOutputText.render(output)
            #expect(!rendered.contains(objectID) && !rendered.contains("private-tree-label"))
            #expect(!text.contains(objectID) && !text.contains("private-tree-label"))
            #expect(output["data"]?["action"]?["enqueuedEventCount"]?.scalarText == "2")
            #expect(output["data"]?["action"]?["cleanup"]?.stringValue == "uncertain")
            #expect(output["data"]?["action"]?["replayed"]?.boolValue == false)
            #expect(output["data"]?["quarantine"]?["persisted"]?.boolValue == true)
            #expect(output["data"]?["batch"]?["completedSteps"]?.scalarText == "0")
            #expect(output["data"]?["batch"]?["stoppedAt"]?.scalarText == "1")
            let receipt = try #require(output["data"]?["batch"]?["steps"]?.arrayValue?.first)
            #expect(receipt["status"]?.stringValue == "failed")
            #expect(receipt["receipt"]?["enqueuedEventCount"]?.scalarText == "2")
            #expect(receipt["error"]?["code"]?.stringValue == "nativeActionFailed")
        }
    }

    @Test("Existing host policy errors retain their exact public code and message")
    func hostPolicyMessageIsUnchanged() {
        let original = AgentModeFailure("targetChanged", "The selected control changed. Refresh the snapshot.")
        let projected = AgentModePublicErrorProjection.project(original, native: nil)
        #expect(projected.code == original.code && projected.message == original.message)
    }

    @Test("Public nested receipt copies remove arbitrary diagnostic text and retain scalar evidence")
    func contaminatedNestedReceiptsStayPrivateInJSONAndText() throws {
        let reasonJSON = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        let endpoint = try JSONDecoder().decode(SelectedSliderResult.self, from: Data("""
        {"outcome":"failed","reason":\(reasonJSON),"reasonTruncated":true,"delivery":"uncertain",
         "endpoint":"maximum","actionAttempts":2,"actionsReturned":1,"startedUptime":10,
         "deadlineUptime":18,"elapsedSeconds":1.5,
         "samples":[{"phase":"initial","elapsedSeconds":0.2,
           "snapshotID":"00000000-0000-0000-0000-000000000001","elementType":"Slider",
           "minimum":0,"maximum":100,"tolerance":0.01,"value":40}],
         "actions":[{"action":"increment","valueBeforeAction":40,"elementType":"Slider",
           "callStartedUptime":10.2,"callReturnedUptime":10.3,"guestAcknowledged":false}]}
        """.utf8))
        let timing = SliderValueNativeReadTiming(readOrdinal: 1, readName: "pickup", startedUptime: 10,
            finishedUptime: 10.2, deadlineUptime: 18, remainingSecondsAtStart: 8,
            outcome: "readFailed", lastStage: "targetValidation")
        let feedback = SliderValueFeedbackPath(iteration: 1, moves: 2, startX: 1, startY: 2,
            currentX: 3, currentY: 4, previousX: 0, previousValue: 0.2, coherentSampleValue: 0.4,
            requestedValue: 0.75, direction: 1, nativeTrackSpan: 100, pickupHitWidth: 44,
            sampleSnapshotID: "00000000-0000-0000-0000-000000000002", fullAdmissionRead: timing,
            decision: "bounded", slope: 0.1, gain: 0.2, proposedDistance: 0.3,
            proposedNextX: 5, proposedNextY: 6)
        let reads = SliderValueNativeReadDiagnostic(readOrdinal: 1, readName: "pickup", readError: "readFailed",
            targetCallbacks: 2, overwrittenRecords: 0, latest: [["nodeValueNumber": "40.0"]],
            recentReads: [timing], feedbackPaths: [feedback])
        let physical = SelectedSliderValueResult(outcome: "failed", reason: diagnostic, delivery: "uncertain",
            requestedPercent: 75, initialValue: 0.2, finalValue: 0.4, nativeTarget: 0.75,
            domainMinimum: 0, domainMaximum: 1, tolerance: 0.01, moves: 3, pickupReadPhases: 2,
            elapsedSeconds: 1.5, nativeReadDiagnostic: reads)
        let quarantine = SelectedHIDQuarantine(recordPath: "/private-fixture", persisted: false, error: diagnostic)
        let error = AgentModePublicErrorProjection.project(.init("nativeActionFailed", diagnostic),
            native: response(failure: .inputFailed, count: 2, cleanup: "uncertain", quarantined: true))
        let action = AgentModeActionReceipt(kind: .sliderPercentage, outcome: "failedNoReplay",
            enqueuedEventCount: 2, cleanup: "uncertain", replayed: false, quarantine: quarantine,
            slider: endpoint, sliderValue: physical)
        let cache = AgentModeCacheState(status: "quarantined", reason: error.code, requiresRefresh: true)
        let step = AgentBatchStepReceipt(index: 1, action: .tap, status: "failed", requestID: UUID(),
            receipt: action, error: error, cache: cache, context: nil)
        let result = AgentModeResult(error: error, action: action,
            batch: .init(totalSteps: 2, completedSteps: 0, steps: [step], stoppedAt: 1),
            cache: cache, quarantine: quarantine, nextSteps: ["Input was not replayed."])
        let publicAction = try #require(result.data.action)
        #expect(try withoutReason(#require(publicAction.slider)) == withoutReason(endpoint))
        #expect(try withoutReason(#require(publicAction.sliderValue)) == withoutReason(physical))
        #expect(publicAction.quarantine?.recordPath == quarantine.recordPath)
        #expect(publicAction.quarantine?.persisted == false)
        #expect(quarantine.error == diagnostic && endpoint.reason == diagnostic && physical.reason == diagnostic)
        for view in [AgentOutputView.full, .reading, .navigation] {
            let output = try render(result, view: view)
            let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            let text = CLIOutputText.render(output)
            for exposed in [json, text] {
                #expect(!exposed.contains(objectID) && !exposed.contains("private-tree-label"))
                #expect(!exposed.contains("FBSimulatorAXTargetHitFailure") && !exposed.contains("nativeIdentity"))
            }
            #expect(output["data"]?["quarantine"]?["recordPath"]?.stringValue == "/private-fixture")
            #expect(output["data"]?["quarantine"]?["persisted"]?.boolValue == false)
            #expect(output["data"]?["action"]?["enqueuedEventCount"]?.scalarText == "2")
            #expect(output["data"]?["action"]?["slider"]?["reasonTruncated"]?.boolValue == true)
            let stored = try #require(output["data"]?["batch"]?["steps"]?.arrayValue?.first)
            #expect(stored["receipt"]?["cleanup"]?.stringValue == "uncertain")
            #expect(stored["receipt"]?["replayed"]?.boolValue == false)
            #expect(stored["receipt"]?["quarantine"]?["recordPath"]?.stringValue == "/private-fixture")
        }
    }

    private func withoutReason<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        let parsed = try JSONDecoder().decode(CLIOutputValue.self, from: encoded)
        guard case var .object(fields) = parsed else {
            throw AgentModeFailure("invalidFixture", "Expected a scalar receipt object.")
        }
        fields.removeValue(forKey: "reason")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(CLIOutputValue.object(fields))
    }

    private func response(failure: SelectedAXFailure? = nil, count: Int = 0,
                          cleanup: String = "notNeeded", quarantined: Bool = false) -> SelectedHIDResponse {
        var ax = SelectedAXResult(kind: .tap)
        ax.failure = failure
        return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: UUID(),
            outcome: count == 0 ? "failedBeforeInput" : "failedNoReplay", token: nil,
            enqueuedEventCount: count, cleanup: cleanup, error: diagnostic, context: nil, ax: ax,
            quarantine: quarantined ? .init(recordPath: "/private-fixture", persisted: true, error: nil) : nil)
    }

    private func render(_ result: AgentModeResult, view: AgentOutputView) throws -> CLIOutputValue {
        let value = try JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(result))
        return try AgentOutputProjection.project(value, view: view)
    }
}
