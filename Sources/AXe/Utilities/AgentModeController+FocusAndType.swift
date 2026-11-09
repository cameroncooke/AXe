import AXeCore
import Foundation
import FBSimulatorControl

extension AgentModeController {
    /// A focus-and-type refused before any input returns the current screen. A refusal caused by
    /// a changing screen is repeated on that new table when its field is unchanged, as the agent
    /// would do after reading the screen again. This is the only retry loop for both phases.
    func performFocusAndTypeRetrying(_ request: SelectedHIDRequest, retryDepth: Int = 0) async -> SelectedHIDResponse {
        let original = record.flatMap { $0.id == request.agent?.snapshotID ? $0 : nil }
        let response = await performFocusAndTypeReserved(request, retryDepth: retryDepth)
        guard let original, let error = response.agent?.error, let ref = request.agent?.ref, let mode = request.agent,
              response.enqueuedEventCount == 0, response.quarantine == nil, response.cleanup != "uncertain",
              var stored = await refreshTable(context: original.context, pid: original.expectedPID) else { return response }
        guard ["screenChanged", "targetChanged"].contains(error.code), retryDepth < Self.maximumRetries,
              let newRef = await reboundReference(ref, original: original.snapshot, stored: &stored) else {
            let capture = stored.snapshot.capture(id: stored.id, sequence: stored.sequence, udid: simulatorUDID,
                request: mode, applicationPID: stored.expectedPID, context: stored.context,
                unchanged: false, expiresIn: Self.timeToLive)
            return failure(request, error, native: nil, action: nil,
                cache: AgentModeCacheState(status: "refreshed", reason: error.code, requiresRefresh: false),
                nextSteps: ["Input was not sent. The capture is the current screen; choose the next action from its snapshot ID."],
                capture: capture)
        }
        var retry = request
        retry.agent?.snapshotID = stored.id
        retry.agent?.ref = newRef
        return await performFocusAndTypeRetrying(retry, retryDepth: retryDepth + 1)
    }

    /// Explicit focus changes the field layout once. Each phase reuses ordinary native guards.
    /// The controller reservation spans both phases; common input leases remain per phase.
    private func performFocusAndTypeReserved(_ request: SelectedHIDRequest, retryDepth: Int = 0) async -> SelectedHIDResponse {
        var progress = AgentFocusAndTypeProgress()
        var last: SelectedHIDResponse?
        var failure: AgentModeFailure?
        do {
            try request.validate()
            guard let mode = request.agent, let ref = mode.ref else {
                throw AgentModeFailure("invalidFocusAndType", "Focus and type requires a published field reference.")
            }
            let initial = try requireRecordIdentity(mode)
            let fieldRef = ref
            let plan = try AgentFocusAndTypePlan(snapshot: initial.snapshot, ref: fieldRef,
                context: initial.context, pid: initial.expectedPID)
            var tap = request
            tap.agent = AgentModeRequest(kind: .tap, expectedPID: initial.expectedPID,
                snapshotID: initial.id, ref: fieldRef, tapStyle: .physical)
            let tapResult = await PhaseTimer.measure("agent.focusTap") {
                await performReserved(tap, focusPlan: plan, retryDepth: retryDepth)
            }
            last = tapResult
            try progress.append(tapResult, action: .tap)
            try Task.checkCancellation()
            guard var focused = record, last?.agent?.data.cache.requiresRefresh == false else {
                throw AgentModeFailure("focusObservationFailed", "The focus input completed without a usable field observation. Typing was stopped; do not repeat the focus input.")
            }
            var baselineResult = Result { try plan.focusedBaseline(snapshot: focused.snapshot,
                context: focused.context, pid: focused.expectedPID) }
            for _ in 0..<5 {
                guard case .failure = baselineResult else { break }
                try await PhaseTimer.measure("agent.focusWait") { try await Task.sleep(for: .milliseconds(100)) }
                guard let next = await refreshTable(context: focused.context, pid: focused.expectedPID) else { break }
                focused = next
                baselineResult = Result { try plan.focusedBaseline(snapshot: focused.snapshot,
                    context: focused.context, pid: focused.expectedPID) }
            }
            let baseline = try baselineResult.get()
            let focusedRef = try baseline.focusedReference(snapshot: focused.snapshot,
                context: focused.context, pid: focused.expectedPID)
            func typing(_ snapshotID: UUID, _ fieldRef: String) -> SelectedHIDRequest {
                var type = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                    screenID: request.screenID, screenUUID: request.screenUUID,
                    operation: .complete, token: nil, primitives: [])
                type.agent = AgentModeRequest(kind: .typeText, expectedPID: initial.expectedPID,
                    snapshotID: snapshotID, ref: fieldRef, text: mode.text)
                return type
            }
            let typeResult = await PhaseTimer.measure("agent.typeText") {
                await performReserved(typing(focused.id, focusedRef), focusPlan: baseline, retryDepth: retryDepth,
                    preread: focused)
            }
            last = typeResult
            try progress.append(typeResult, action: .type)
            guard record != nil, last?.agent?.data.cache.requiresRefresh == false else {
                throw AgentModeFailure("focusTypeRefreshFailed", "Focus and typing completed without a usable replacement snapshot. Do not replay either phase.")
            }
        } catch {
            failure = error as? AgentModeFailure
                ?? AgentModeFailure("focusTypeStopped", "Focus and type stopped. Inspect both phase receipts before more input.")
            // A stale caller must not erase another caller's newer table.
            let newerTable = failure?.code == "snapshotMissing" && record != nil
                && request.agent?.snapshotID != record?.id
            if !newerTable { record = nil }
            if let failure { progress.reject(failure, context: last?.context) }
        }
        let prior = last?.agent?.data
        let quarantine = prior?.quarantine ?? last?.quarantine
        let cache = failure == nil ? (prior?.cache ?? AgentModeCacheState(
            status: "invalidated", reason: "missingCapture", requiresRefresh: true)) : AgentModeCacheState(
                status: quarantine == nil ? "invalidated" : "quarantined", reason: failure?.code, requiresRefresh: true)
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: owner.brokerID, outcome: failure == nil ? "completed" : "stopped", token: nil,
            enqueuedEventCount: progress.steps.reduce(0) { $0 + ($1.receipt?.enqueuedEventCount ?? 0) },
            cleanup: last?.cleanup ?? "notNeeded", error: failure?.message, context: last?.context, quarantine: quarantine)
        response.agent = AgentModeResult(error: failure, capture: failure == nil ? prior?.capture : nil,
            batch: progress.receipt(stopped: failure != nil), cache: cache, context: last?.context,
            quarantine: quarantine, observation: prior?.observation,
            nextSteps: failure == nil ? [] : [
                "Inspect both phase receipts. Completed input was not undone or replayed.",
                quarantine == nil ? "Read a fresh snapshot. Do not resubmit the focus-and-type command."
                    : HIDInputQuarantine.recoveryStep + " Do not resubmit the focus-and-type command.",
            ])
        return response
    }
}
