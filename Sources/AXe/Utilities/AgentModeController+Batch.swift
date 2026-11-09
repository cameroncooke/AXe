import AXeCore
import Foundation
import FBSimulatorControl

extension AgentModeController {
    /// A reference batch stopped before any input repeats on a new table when every
    /// step's target is unchanged.
    func performBatchRetrying(_ request: SelectedHIDRequest, retryDepth: Int = 0) async -> SelectedHIDResponse {
        let original = record.flatMap { $0.id == request.agentBatch?.snapshotID ? $0 : nil }
        let response = await performBatchReserved(request, retryDepth: retryDepth)
        guard let error = response.agent?.error, let batch = request.agentBatch, response.quarantine == nil else {
            return response
        }
        let sentNothing = Self.batchStoppedBeforeInput(response)
        guard sentNothing || Self.batchStoppedCleanly(response) else { return response }
        if sentNothing, retryDepth < Self.maximumRetries, let original, batch.usesReferences, response.enqueuedEventCount == 0,
           response.agent?.data.batch?.completedSteps == 0,
           ["screenChanged", "targetChanged", "batchLayoutChanged"].contains(error.code),
           var stored = await refreshTable(context: original.context, pid: original.expectedPID) {
            let steps = await reboundSteps(batch.steps, original: original.snapshot, stored: &stored) ?? []
            if !steps.isEmpty {
                var retry = request
                retry.agentBatch = AgentBatchRequest(expectedPID: batch.expectedPID, snapshotID: stored.id, steps: steps)
                return await performBatchRetrying(retry, retryDepth: retryDepth + 1)
            }
        }
        // The stopping step sent nothing, or its delivered input finished with clean release. Return
        // the current screen with the stopped batch, so the agent decides its remaining steps from a
        // fresh table instead of reading one first. Nothing is repeated.
        guard let stored = await refreshTable(context: original?.context ?? response.context,
                                              pid: original?.expectedPID ?? batch.expectedPID) else { return response }
        let capture = stored.snapshot.capture(id: stored.id, sequence: stored.sequence, udid: simulatorUDID,
            request: AgentModeRequest(kind: .describe), applicationPID: stored.expectedPID, context: stored.context,
            unchanged: false, expiresIn: Self.timeToLive)
        var withScreen = response
        withScreen.agent = AgentModeResult(error: error, capture: capture, batch: response.agent?.data.batch,
            cache: AgentModeCacheState(status: "refreshed", reason: error.code, requiresRefresh: false),
            context: stored.context, quarantine: nil, observation: response.agent?.data.observation,
            nextSteps: [sentNothing
                            ? "Inspect each step receipt. Completed steps were not undone; the stopping step sent no input."
                            : "Inspect each step receipt. The stopping step's delivered input was not undone or repeated.",
                        "The capture is the current screen; choose the remaining steps from its snapshot ID. Do not resubmit the batch."])
        return withScreen
    }

    /// The stopping step delivered input that finished with clean release and no quarantine, so a
    /// read of the current screen is safe. It is never a reason to repeat that input.
    private static func batchStoppedCleanly(_ response: SelectedHIDResponse) -> Bool {
        guard let steps = response.agent?.data.batch?.steps,
              let stopping = steps.last(where: { $0.status != "completed" }),
              let receipt = stopping.receipt else { return false }
        return receipt.cleanup != "uncertain" && receipt.quarantine == nil
    }

    /// Every step of a batch that sent nothing, on one new table. Unchanged targets bind at once.
    /// Moved targets (the same control at a new position, as `sameControl` defines) bind once all
    /// of them hold still across two reads about 150 ms apart, within four reads, as a single
    /// refused action does. All refs come from the same table.
    private func reboundSteps(_ steps: [AgentBatchStep], original: AgentModeSnapshot,
                              stored: inout Record) async -> [AgentBatchStep]? {
        let unchanged = steps.map { step -> AgentBatchStep? in
            guard let ref = step.ref, let newRef = Self.unchangedReference(ref, from: original, to: stored.snapshot) else { return nil }
            return try? step.replacingReference(newRef)
        }
        if unchanged.allSatisfy({ $0 != nil }) { return unchanged.compactMap { $0 } }
        var previousFrames: [CGRect]?
        for _ in 0..<4 {
            var frames: [CGRect] = []
            var moved: [AgentBatchStep] = []
            for step in steps {
                guard let ref = step.ref, let chosen = try? original.target(ref: ref),
                      let old = try? original.match(target: chosen),
                      let new = try? stored.snapshot.match(target: chosen), Self.sameControl(old, new),
                      let frame = new.frame, let newRef = try? stored.snapshot.reference(target: chosen),
                      let rebound = try? step.replacingReference(newRef) else { return nil }
                frames.append(frame)
                moved.append(rebound)
            }
            if previousFrames == frames { return moved }
            previousFrames = frames
            guard (try? await PhaseTimer.measure("agent.reboundPause") { try await Task.sleep(for: .milliseconds(150)) }) != nil,
                  let next = await refreshTable(context: stored.context, pid: stored.expectedPID) else { return nil }
            stored = next
        }
        return nil
    }

    /// The step that stopped the batch was refused before any of its input was sent.
    private static func batchStoppedBeforeInput(_ response: SelectedHIDResponse) -> Bool {
        guard let steps = response.agent?.data.batch?.steps, let stopping = steps.last(where: { $0.status != "completed" }) else {
            return false
        }
        guard let receipt = stopping.receipt else { return stopping.status == "rejectedBeforeInput" }
        return receipt.enqueuedEventCount == 0 && receipt.outcome == "failedBeforeInput" && receipt.cleanup != "uncertain"
    }

    private func performBatchReserved(_ request: SelectedHIDRequest, retryDepth: Int = 0) async -> SelectedHIDResponse {
        var receipts: [AgentBatchStepReceipt] = []
        var completed = 0
        var currentIndex: Int?
        var currentRequestID = UUID()
        var last: SelectedHIDResponse?

        func finish(_ error: AgentModeFailure?) -> SelectedHIDResponse {
            if error != nil { record = nil }
            let prior = last?.agent?.data
            let quarantine = prior?.quarantine ?? last?.quarantine
            let cache = error == nil ? (prior?.cache ?? AgentModeCacheState(
                status: "invalidated", reason: "missingCapture", requiresRefresh: true)) : AgentModeCacheState(
                status: quarantine == nil ? "invalidated" : "quarantined", reason: error?.code, requiresRefresh: true)
            let batch = AgentBatchReceipt(totalSteps: request.agentBatch?.steps.count ?? 0,
                completedSteps: completed, steps: receipts, stoppedAt: error == nil ? nil : currentIndex ?? 1)
            var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: owner.brokerID, outcome: error == nil ? "completed" : "stopped", token: nil,
                enqueuedEventCount: receipts.reduce(0) { $0 + ($1.receipt?.enqueuedEventCount ?? 0) },
                cleanup: last?.cleanup ?? "notNeeded", error: error?.message,
                context: last?.context, quarantine: quarantine)
            response.agent = AgentModeResult(error: error, capture: error == nil ? prior?.capture : nil,
                batch: batch, cache: cache, context: last?.context, quarantine: quarantine,
                observation: prior?.observation, nextSteps: error == nil ? [] : [
                    "Inspect each step receipt. Completed steps were not undone; no step was replayed.",
                    quarantine == nil ? "Read a fresh snapshot before deciding the next action. Do not resubmit the batch."
                        : HIDInputQuarantine.recoveryStep + " Do not resubmit the batch.",
                ])
            return response
        }

        do {
            try request.validate()
            guard let batch = request.agentBatch else {
                throw AgentModeFailure("missingBatch", "The agent batch request is missing.")
            }
            let initialRecord: Record
            var referencePlan: AgentBatchReferencePlan?
            if batch.usesReferences {
                let identity = AgentModeRequest(kind: .describe, expectedPID: batch.expectedPID, snapshotID: batch.snapshotID)
                initialRecord = try requireRecordIdentity(identity)
                // All references and capabilities are checked before the first input.
                referencePlan = try AgentBatchReferencePlan(request: batch, snapshotID: initialRecord.id,
                    snapshot: initialRecord.snapshot, context: initialRecord.context, pid: initialRecord.expectedPID)
            } else {
                var initial = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                    screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
                initial.agent = AgentModeRequest(kind: .describe, expectedPID: batch.expectedPID)
                last = await PhaseTimer.measure("batch.initialDescribe") { await performReserved(initial) }
                guard let initialResult = last?.agent, !initialResult.didError, let current = record else {
                    throw last?.agent?.error ?? AgentModeFailure("batchObservationFailed", "The initial batch observation failed.")
                }
                initialRecord = current
                referencePlan = nil
            }
            let baseline = initialRecord.context
            let batchPID = initialRecord.expectedPID
            for (offset, step) in batch.steps.enumerated() {
                currentIndex = offset + 1
                currentRequestID = UUID()
                try Task.checkCancellation()
                var action = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: currentRequestID,
                    screenID: baseline.screenID, screenUUID: UUID(uuidString: baseline.screenUUID),
                    operation: .complete, token: nil, primitives: [])
                let response = try await PhaseTimer.measure("batch.step \(offset + 1) \(step.action)") {
                    () async throws -> SelectedHIDResponse in
                    if let referencePlan {
                        if referencePlan.isFocusStep(offset) {
                            return await performReferenceFocusStep(action, step: step, retryDepth: retryDepth,
                                index: offset, plan: referencePlan, pid: batchPID)
                        }
                        return await performReferenceBatchStep(action, step: step, retryDepth: retryDepth, index: offset,
                            plan: referencePlan, pid: batchPID)
                    }
                    guard let current = record, current.context == baseline else {
                        throw AgentModeFailure("batchContextChanged", "The simulator restarted, rotated or changed its display during the batch, so the remaining steps were not sent. \(AgentModeFailure.batchRest)")
                    }
                    guard let id = step.id else {
                        throw AgentModeFailure("invalidBatchID", "A native ID batch step has no ID.")
                    }
                    if step.action == .type && step.focuses {
                        let ref = try Self.batchReference(current.snapshot, id: id, action: .tap)
                        action.agent = AgentModeRequest(kind: .focusAndType, expectedPID: batchPID,
                            snapshotID: current.id, ref: ref, text: step.text)
                        return Self.focusStep(await performFocusAndTypeRetrying(action, retryDepth: retryDepth),
                            retried: retryDepth > 0)
                    }
                    let ref = try Self.batchReference(current.snapshot, id: id,
                        action: step.action == .tap ? .tap : .typeText)
                    action.agent = AgentModeRequest(kind: step.action == .tap ? .tap : .typeText,
                        expectedPID: batchPID, snapshotID: current.id, ref: ref, text: step.text)
                    return await performReserved(action, retryDepth: retryDepth)
                }
                last = response
                guard let result = response.agent else {
                    throw AgentModeFailure("missingBatchResult", "A batch step returned no agent result. Its outcome must be inspected.")
                }
                let didComplete = result.data.action?.outcome == "enqueuedAndDrained"
                    && result.data.action?.cleanup != "uncertain"
                if didComplete { completed += 1 }
                receipts.append(AgentBatchStepReceipt(index: offset + 1, action: step.action,
                    status: didComplete ? "completed" : "failed", requestID: currentRequestID,
                    receipt: result.data.action, error: result.error, cache: result.data.cache,
                    context: result.data.context))
                if let error = result.error { throw error }
                guard didComplete else {
                    throw AgentModeFailure("batchInputFailed", "The step did not complete. Later steps were stopped; input was not replayed.")
                }
                if let plan = referencePlan {
                    if plan.isFocusStep(offset), batch.steps.indices.contains(offset + 1) {
                        // The focus step's keyboard is a declared layout change. Bind the remaining
                        // steps to the screen after typing; a refusal belongs to the next step.
                        currentIndex = offset + 2
                        currentRequestID = UUID()
                        guard let typed = record, !result.data.cache.requiresRefresh else {
                            throw AgentModeFailure("batchRefreshFailed", "AXe could not read the screen after a focus step, so the remaining steps were not sent. Completed steps are in the receipt and were not undone. Run describe-ui --agent and plan the rest from it; do not resend the batch.")
                        }
                        let current = await settledTable(after: typed, pid: batchPID)
                        referencePlan = try plan.rebased(afterFocusStep: offset, snapshot: current.snapshot,
                            context: current.context, pid: batchPID)
                    }
                    continue
                }
                guard !result.data.cache.requiresRefresh, record != nil else {
                    throw AgentModeFailure("batchRefreshFailed", "AXe could not read the screen after a step, so the remaining steps were not sent. Completed steps are in the receipt and were not undone. Run describe-ui --agent and plan the rest from it; do not resend the batch.")
                }
                guard record?.context == baseline else {
                    throw AgentModeFailure("batchContextChanged", "The simulator restarted, rotated or changed its display during the batch, so the remaining steps were not sent. \(AgentModeFailure.batchRest)")
                }
            }
            if referencePlan != nil {
                // Reference batches validate each step against fresh native input evidence,
                // then publish one replacement table after all completed input.
                var final = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                    screenID: baseline.screenID, screenUUID: UUID(uuidString: baseline.screenUUID),
                    operation: .complete, token: nil, primitives: [])
                final.agent = AgentModeRequest(kind: .describe, expectedPID: batchPID)
                last = await PhaseTimer.measure("batch.finalDescribe") { await performReserved(final) }
                guard let finalResult = last?.agent, !finalResult.didError, record != nil else {
                    throw last?.agent?.error ?? AgentModeFailure("batchRefreshFailed", "The batch input was sent, but AXe could not read the screen afterwards. Do not resend the batch: run describe-ui --agent to see what happened, then plan from that capture.")
                }
                guard record?.context == baseline else {
                    throw AgentModeFailure("batchContextChanged", "The simulator restarted, rotated or changed its display during the batch, so the remaining steps were not sent. \(AgentModeFailure.batchRest)")
                }
            }
            return withReadingContinuation(finish(nil), request: request)
        } catch let error as AgentModeFailure where error.code == "snapshotMissing"
            && request.agentBatch?.snapshotID != nil && record != nil
            && request.agentBatch?.snapshotID != record?.id {
            // An old batch cannot erase another caller's newer published table.
            return failure(request, error)
        } catch {
            let failure: AgentModeFailure
            if let known = error as? AgentModeFailure {
                // Step errors already passed the public failure boundary.
                failure = known
            } else {
                failure = AgentModePublicErrorProjection.project(
                    AgentModeFailure("batchStopped", "The batch stopped."),
                    native: (error as? AgentModeNativeFailure)?.response)
            }
            if let currentIndex, receipts.last?.index != currentIndex,
               let batch = request.agentBatch, batch.steps.indices.contains(currentIndex - 1) {
                receipts.append(AgentBatchStepReceipt(index: currentIndex, action: batch.steps[currentIndex - 1].action,
                    status: "rejectedBeforeInput", requestID: currentRequestID, receipt: nil, error: failure,
                    cache: AgentModeCacheState(status: "invalidated", reason: failure.code, requiresRefresh: true),
                    context: last?.context))
            }
            return finish(failure)
        }
    }

    /// An ID step's ref on the current table. A missing or duplicated ID is a batch refusal.
    private static func batchReference(_ snapshot: AgentModeSnapshot, id: String,
                                       action: RuntimeElementAction) throws -> String {
        do { return try snapshot.reference(id: id, action: action) }
        catch let failure as AgentModeFailure where ["targetMissing", "targetAmbiguous"].contains(failure.code) {
            throw AgentModeFailure("batchTargetMissing", "The batch ID does not identify one exact current native target, so this step and later steps were not sent. \(AgentModeFailure.batchRest)")
        }
    }

    /// A published-reference batch owns its original plan. Each step uses fresh native evidence,
    /// and does not publish an intermediate table that another step or caller could reuse.
    private func performReferenceBatchStep(_ request: SelectedHIDRequest, step: AgentBatchStep, retryDepth: Int,
                                          index: Int, plan: AgentBatchReferencePlan,
                                          pid: Int32) async -> SelectedHIDResponse {
        do {
            let result: SelectedHIDResponse
            let kind: AgentModeRequest.Kind
            if step.action == .tap {
                let admission = AgentBatchTapAdmission(plan: plan, index: index)
                let native = try admission.request(requestID: request.requestID)
                record = nil
                result = await PhaseTimer.measure("agent.input") { await owner.perform(native, batchTap: admission) }
                kind = .tap
            } else {
                // Typing retains its existing independent description and focused-field path.
                // The step request carries the plan's display; its full context read admits it.
                guard let screenID = request.screenID, let screenUUID = request.screenUUID else {
                    throw AgentModeFailure.missingContext
                }
                let fresh = try await observe(display: ActivePanelIdentity(displayID: screenID, uniqueID: screenUUID), pid: pid)
                guard let context = fresh.context, let roots = fresh.ax?.roots else {
                    throw AgentModeFailure("missingObservation", "The batch step has no fresh native context or hierarchy.")
                }
                let snapshot = try PhaseTimer.measureSync("agent.snapshotBuild") {
                    try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: fresh.ax?.nativeIdentityMetadata, context: context)
                }
                let target = try plan.resolve(index: index, snapshot: snapshot, context: context, pid: pid)
                // The complete batch document and target plan were validated before step one.
                // Carry that chosen authority directly; no opaque ID becomes selector text.
                let mode = AgentModeRequest(kind: .typeText, expectedPID: pid, text: step.text)
                let native = try nativeRequest(request, mode: mode, pid: pid,
                    context: context, snapshot: snapshot, cached: nil, binding: target)
                record = nil
                result = await PhaseTimer.measure("agent.input") { await owner.perform(native) }
                kind = mode.kind
            }
            let action = AgentModeActionReceipt(kind: kind, outcome: result.outcome,
                enqueuedEventCount: result.enqueuedEventCount, cleanup: result.cleanup, replayed: false,
                quarantine: result.quarantine, slider: result.ax?.slider, sliderValue: result.ax?.sliderValue,
                retried: retryDepth > 0 ? true : nil)
            guard result.error == nil, result.cleanup != "uncertain" else {
                return failure(request, result.agent?.error
                    ?? AgentModePublicErrorProjection.nativeFailure(result),
                    native: result, action: action)
            }
            return success(request, native: result, action: action,
                cache: AgentModeCacheState(status: "invalidated", reason: "batchInProgress", requiresRefresh: true))
        } catch {
            record = nil
            let nativeFailure = error as? AgentModeNativeFailure
            let failure = error as? AgentModeFailure
                ?? AgentModeFailure("batchObservationFailed", "The batch observation failed.")
            // Every error caught here comes before the step's input is sent. Report that, so a
            // batch that sent nothing retries on a new table and returns the current screen.
            let action = AgentModeActionReceipt(kind: step.action == .tap ? .tap : .typeText,
                outcome: "failedBeforeInput", enqueuedEventCount: 0, cleanup: "notNeeded", replayed: false,
                quarantine: nil, slider: nil, sliderValue: nil, retried: retryDepth > 0 ? true : nil)
            return self.failure(request, failure, native: nativeFailure?.response, action: action)
        }
    }

    /// A focus step makes the same guarded focus tap and typing as `type --focus`, on the field the
    /// plan bound, found on a fresh read. The table it reads stays internal: the batch holds the
    /// controller reservation, and later steps resolve their own fresh evidence.
    private func performReferenceFocusStep(_ request: SelectedHIDRequest, step: AgentBatchStep, retryDepth: Int,
                                          index: Int, plan: AgentBatchReferencePlan,
                                          pid: Int32) async -> SelectedHIDResponse {
        do {
            guard let screenID = request.screenID, let screenUUID = request.screenUUID else {
                throw AgentModeFailure.missingContext
            }
            let fresh = try await observe(display: ActivePanelIdentity(displayID: screenID, uniqueID: screenUUID), pid: pid)
            guard let context = fresh.context, let roots = fresh.ax?.roots else {
                throw AgentModeFailure("missingObservation", "The batch step has no fresh native context or hierarchy.")
            }
            let snapshot = try PhaseTimer.measureSync("agent.snapshotBuild") {
                try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: fresh.ax?.nativeIdentityMetadata, context: context)
            }
            let target = try plan.resolve(index: index, snapshot: snapshot, context: context, pid: pid)
            let ref = try snapshot.reference(target: target.nativeTarget)
            let table = store(snapshot, context: context, pid: pid)
            var focus = request
            focus.agent = AgentModeRequest(kind: .focusAndType, expectedPID: pid, snapshotID: table.id,
                ref: ref, text: step.text)
            return Self.focusStep(await performFocusAndTypeRetrying(focus, retryDepth: retryDepth),
                retried: retryDepth > 0)
        } catch {
            record = nil
            let nativeFailure = error as? AgentModeNativeFailure
            let failure = error as? AgentModeFailure
                ?? AgentModeFailure("batchObservationFailed", "The batch observation failed.")
            // Nothing was sent: the step was refused before its focus tap.
            let action = AgentModeActionReceipt(kind: .focusAndType, outcome: "failedBeforeInput",
                enqueuedEventCount: 0, cleanup: "notNeeded", replayed: false, quarantine: nil,
                slider: nil, sliderValue: nil, retried: retryDepth > 0 ? true : nil)
            return self.failure(request, failure, native: nativeFailure?.response, action: action)
        }
    }

    /// The screen after a focus step, once two reads in a row show the same batch layout. The
    /// keyboard's suggestion bar can change after the last key, so a baseline taken from the read
    /// straight after typing could stop the next step. One read when the screen is already still,
    /// at most four; there is no fixed wait.
    private func settledTable(after typed: Record, pid: Int32) async -> Record {
        var current = typed
        guard var previous = try? AgentBatchReferencePlan.layoutKey(current.snapshot, context: current.context) else {
            return current
        }
        for _ in 0..<4 {
            guard let next = await PhaseTimer.measure("batch.focusSettleRead", {
                      await refreshTable(context: current.context, pid: pid) }),
                  let key = try? AgentBatchReferencePlan.layoutKey(next.snapshot, context: next.context) else {
                return current
            }
            current = next
            if key == previous { return current }
            previous = key
        }
        return current
    }

    /// One focus step's two phases as one batch step. Events from either phase are input, so a
    /// completed focus tap followed by failed typing is never reported as stopped before input.
    private static func focusStep(_ response: SelectedHIDResponse, retried: Bool) -> SelectedHIDResponse {
        guard let result = response.agent else { return response }
        let action = AgentFocusAndTypeProgress.stepAction(result.data.batch, failed: result.error != nil,
            cleanup: response.cleanup, quarantine: response.quarantine, retried: retried)
        var converted = response
        converted.agent = AgentModeResult(error: result.error, capture: result.data.capture, action: action,
            cache: result.data.cache, context: result.data.context, quarantine: result.data.quarantine,
            observation: result.data.observation, nextSteps: result.nextSteps)
        return converted
    }
}
