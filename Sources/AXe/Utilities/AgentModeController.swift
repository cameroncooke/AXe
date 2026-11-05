import AXeCore
import Foundation
import FBControlCore
import FBSimulatorControl

/// The broker owns one table. Its reservation spans every read, action and replacement.
@MainActor
final class AgentModeController {
    static let timeToLive = 60.0
    private struct Record {
        let id: UUID
        let sequence: Int
        let capturedAt: Double
        let expectedPID: Int32
        let context: SelectedHIDContext
        let snapshot: AgentModeSnapshot
    }
    private let simulatorUDID: String
    private let logger: AxeLogger
    private let owner: SelectedHIDOwner
    private var record: Record?
    private var sequence = 0
    private(set) var isBusy = false

    init(simulatorUDID: String, logger: AxeLogger, owner: SelectedHIDOwner) {
        self.simulatorUDID = simulatorUDID; self.logger = logger; self.owner = owner
    }

    func invalidate() { record = nil }

    static func canReuseSnapshot(_ previous: AgentModeSnapshot, with fresh: AgentModeSnapshot) -> Bool {
        previous.hash == fresh.hash && previous.nativeFingerprint == fresh.nativeFingerprint
            && previous.protectedTargetsMatch(fresh)
    }

    func maintain() async {
        guard !isBusy, !owner.isBusy else { return }
        if let record, now - record.capturedAt >= Self.timeToLive { invalidate() }
        await owner.maintain(retainingAgentSnapshot: record != nil)
    }

    func reject(_ request: SelectedHIDRequest, code: String = "busy") -> SelectedHIDResponse {
        let native = owner.rejectBusy(request)
        let quarantined = native.quarantine != nil
        return failure(request,
            AgentModeFailure(quarantined ? "quarantined" : code,
                native.error ?? "The runtime is busy. Retry after the current action finishes."), native: native,
            cache: AgentModeCacheState(status: quarantined ? "quarantined" : "busy", reason: code, requiresRefresh: true),
            nextSteps: quarantined
                ? ["Inspect the quarantine receipt and complete explicit input recovery before retrying."]
                : ["Wait for the current action to finish, then request a fresh agent snapshot."])
    }

    func perform(_ request: SelectedHIDRequest) async -> SelectedHIDResponse {
        guard !isBusy, !owner.isBusy else { return reject(request) }
        isBusy = true
        defer { isBusy = false }
        return withReadingContinuation(await performReserved(request), request: request)
    }

    /// The optional page is part of this reply and uses exactly the record already
    /// captured or validated by the command. No second observation authorizes it.
    private func withReadingContinuation(_ response: SelectedHIDResponse,
                                         request: SelectedHIDRequest) -> SelectedHIDResponse {
        guard request.includeReadingContinuation == true, !Task.isCancelled,
              let result = response.agent, !result.didError, !result.data.cache.requiresRefresh,
              let capture = result.data.capture, capture.nextRowOffset != nil,
              let stored = record, capture.snapshotID == stored.id, capture.seq == stored.sequence,
              capture.applicationPID == stored.expectedPID, capture.context == stored.context else {
            return response
        }
        guard let offset = try? AgentPageEnrichment.continuationOffset(
            JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(result))),
            now - stored.capturedAt < Self.timeToLive else { return response }
        var page = AgentModeRequest(kind: .describe)
        page.rowOffset = offset
        var enriched = response
        enriched.readingContinuation = stored.snapshot.capture(id: stored.id, sequence: stored.sequence,
            udid: simulatorUDID, request: page, applicationPID: stored.expectedPID, context: stored.context,
            unchanged: false, expiresIn: max(0, Self.timeToLive - (now - stored.capturedAt)))
        return enriched
    }

    private func performReserved(_ request: SelectedHIDRequest,
                                 focusPlan: AgentFocusAndTypePlan? = nil) async -> SelectedHIDResponse {
        if request.agent?.kind == .focusAndType { return await performFocusAndTypeReserved(request) }
        var action: AgentModeActionReceipt?
        do {
            try request.validate()
            guard let mode = request.agent else {
                throw AgentModeFailure("missingRequest", "The agent request is missing.")
            }
            let referenceRecord: Record?
            if mode.snapshotID != nil || mode.ref != nil {
                referenceRecord = try requireRecordIdentity(mode)
            } else { referenceRecord = nil }
            let expectedPID = try AgentModePIDPolicy.expectedPID(
                assertion: mode.expectedPID, snapshot: referenceRecord?.expectedPID)
            let display = try await discover(request)
            // A stale display can be refused before a disconnected AX channel hides it.
            if let referenceRecord {
                guard referenceRecord.context.screenID == display.displayID,
                      UUID(uuidString: referenceRecord.context.screenUUID) == display.uniqueID else {
                    throw AgentModeFailure("contextChanged", "The native runtime context changed. Refresh the snapshot.")
                }
            }
            let fresh = try await observe(display: display, pid: expectedPID)
            guard let context = fresh.context, let roots = fresh.ax?.roots,
                  let pid = fresh.ax?.expectedPID else {
                throw AgentModeFailure("missingObservation", "The native observation has no selected context or hierarchy.")
            }
            let snapshot = try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: fresh.ax?.nativeIdentityMetadata, context: context)
            if let focusPlan {
                if mode.kind == .tap {
                    try focusPlan.validateBeforeTap(snapshot: snapshot, context: context, pid: pid)
                } else {
                    _ = try focusPlan.focusedReference(snapshot: snapshot, context: context, pid: pid)
                }
            }
            if mode.kind == .read {
                let stored = try requireRecord(mode, context: context, fresh: snapshot)
                guard let reference = mode.readReference, let query = mode.textQuery else {
                    throw AgentModeFailure("invalidReadReference", "The reference read has no field query.")
                }
                let detail = try stored.snapshot.detail(ref: reference, query: query)
                return success(request, native: fresh,
                    cache: AgentModeCacheState(status: "validated", reason: nil, requiresRefresh: false),
                    detail: detail)
            }
            if mode.kind == .describe {
                let stored: Record
                let unchanged: Bool
                let cacheStatus: String
                if mode.snapshotID != nil {
                    stored = try requireRecord(mode, context: context, fresh: snapshot)
                    unchanged = false
                    cacheStatus = "validated"
                } else if let previous = record,
                          mode.sinceScreenHash == previous.snapshot.hash,
                          now - previous.capturedAt < Self.timeToLive,
                          previous.expectedPID == pid, previous.context == context,
                          Self.canReuseSnapshot(previous.snapshot, with: snapshot) {
                    // Hash equality does not prove ordinal refs stayed in the same order.
                    // Retain the old table and UUID; only the observation sequence advances.
                    sequence += 1
                    stored = Record(id: previous.id, sequence: sequence, capturedAt: previous.capturedAt,
                        expectedPID: previous.expectedPID, context: previous.context, snapshot: previous.snapshot)
                    record = stored
                    unchanged = true
                    cacheStatus = "reused"
                } else {
                    stored = store(snapshot, context: context, pid: pid)
                    unchanged = false
                    cacheStatus = "refreshed"
                }
                let capture = stored.snapshot.capture(id: stored.id, sequence: stored.sequence,
                    udid: simulatorUDID, request: mode, applicationPID: stored.expectedPID, context: stored.context,
                    unchanged: unchanged,
                    expiresIn: max(0, Self.timeToLive - (now - stored.capturedAt)))
                return success(request, native: fresh, capture: capture,
                    cache: AgentModeCacheState(status: cacheStatus, reason: nil, requiresRefresh: false))
            }

            let cached: Record?
            if mode.snapshotID != nil || mode.ref != nil {
                cached = try requireRecord(mode, context: context, fresh: snapshot)
            } else { cached = nil }
            let native = try nativeRequest(request, mode: mode, pid: pid,
                context: context, snapshot: snapshot, cached: cached)
            // Invalidate before input, including partial or uncertain native delivery.
            record = nil
            let result = await owner.perform(native)
            action = AgentModeActionReceipt(kind: mode.kind, outcome: result.outcome,
                enqueuedEventCount: result.enqueuedEventCount, cleanup: result.cleanup, replayed: false,
                quarantine: result.quarantine, slider: result.ax?.slider, sliderValue: result.ax?.sliderValue)
            guard result.error == nil, result.cleanup != "uncertain" else {
                return failure(request, AgentModeFailure("nativeActionFailed", "The native action failed."),
                               native: result, action: action)
            }
            // A fresh replacement is useful, but its failure must not suggest replaying the action.
            do {
                let afterContext: SelectedHIDContext
                let afterSnapshot: AgentModeSnapshot
                if native.path?.kind == .swipe {
                    guard let inputContext = result.context, inputContext == context,
                          result.brokerID == owner.brokerID else {
                        throw AgentModeFailure("postSwipeContextChanged", "The completed swipe has no matching native owner and context.")
                    }
                    let settled = try await AgentPostSwipePublication.capture(
                        context: inputContext, pid: pid, brokerID: owner.brokerID,
                        startedAt: now, now: { self.now },
                        pause: { try await Task.sleep(for: .milliseconds(300)) },
                        sample: { deadline in
                            try AgentPostSwipePublication.requireMayStart(now: self.now, deadline: deadline)
                            if self.owner.isBusy { throw AgentModeNativeFailure(response: self.owner.rejectBusy(request)) }
                            let display = try await self.discover(request)
                            try AgentPostSwipePublication.requireMayStart(now: self.now, deadline: deadline)
                            if self.owner.isBusy { throw AgentModeNativeFailure(response: self.owner.rejectBusy(request)) }
                            let observed = try await self.observe(display: display, pid: pid)
                            guard let observedContext = observed.context, let roots = observed.ax?.roots,
                                  let observedPID = observed.ax?.expectedPID else {
                                throw AgentModeFailure("refreshFailed", "The action completed, but its replacement snapshot is unavailable.")
                            }
                            return AgentPostSwipePublication.Sample(
                                snapshot: try AgentModeSnapshot(roots: roots,
                                    nativeIdentityMetadata: observed.ax?.nativeIdentityMetadata, context: observedContext),
                                context: observedContext, pid: observedPID, brokerID: observed.brokerID)
                        })
                    afterContext = settled.context
                    afterSnapshot = settled.snapshot
                } else {
                    try await Task.sleep(for: .milliseconds(300))
                    let afterDisplay = try await discover(request)
                    let after = try await observe(display: afterDisplay, pid: pid)
                    guard let observedContext = after.context, let afterRoots = after.ax?.roots else {
                        throw AgentModeFailure("refreshFailed", "The action completed, but its replacement snapshot is unavailable.")
                    }
                    afterContext = observedContext
                    afterSnapshot = try AgentModeSnapshot(roots: afterRoots,
                        nativeIdentityMetadata: after.ax?.nativeIdentityMetadata, context: afterContext)
                }
                let stored = store(afterSnapshot, context: afterContext, pid: pid)
                let capture = stored.snapshot.capture(id: stored.id, sequence: stored.sequence,
                    udid: simulatorUDID, request: mode, applicationPID: stored.expectedPID, context: stored.context,
                    unchanged: false, expiresIn: Self.timeToLive)
                return success(request, native: result, capture: capture, action: action,
                    cache: AgentModeCacheState(status: "refreshed", reason: "inputCompleted", requiresRefresh: false))
            } catch {
                let nativeFailure = error as? AgentModeNativeFailure
                if let nativeFailure, nativeFailure.response.quarantine != nil {
                    return failure(request,
                        AgentModeFailure("postActionRefreshQuarantined", "The action completed, but input recovery is required after its refresh failed."),
                        native: nativeFailure.response, action: action)
                }
                let observation = AgentModeObservationEvidence(nativeFailure?.response)
                let nextSteps: [String]
                if let instruction = observation?.captureInstruction(udid: simulatorUDID) {
                    nextSteps = ["The action completed. Do not replay this action.", instruction]
                } else {
                    nextSteps = ["The action completed. Run describe-ui --agent before another reference action. Do not replay this action."]
                }
                return success(request, native: result, action: action,
                    cache: AgentModeCacheState(status: "invalidated", reason: "postActionRefreshFailed", requiresRefresh: true),
                    observation: observation, nextSteps: nextSteps)
            }
        } catch let error as AgentModeFailure where error.code == "snapshotMissing"
            && request.agent?.snapshotID != nil && record != nil
            && request.agent?.snapshotID != record?.id {
            // A stale caller cannot erase another caller's newer reference table.
            return failure(request, error, action: action)
        } catch {
            record = nil
            let nativeFailure = error as? AgentModeNativeFailure
            let reason = error as? AgentModeFailure
                ?? AgentModeFailure("observationFailed", "The simulator observation failed.")
            return failure(request, reason, native: nativeFailure?.response, action: action)
        }
    }

    /// Explicit focus changes the field layout once. Each phase reuses ordinary native guards.
    /// The controller reservation spans both phases; common input leases remain per phase.
    private func performFocusAndTypeReserved(_ request: SelectedHIDRequest) async -> SelectedHIDResponse {
        var progress = AgentFocusAndTypeProgress()
        var last: SelectedHIDResponse?
        var failure: AgentModeFailure?
        do {
            try request.validate()
            guard let mode = request.agent, let ref = mode.ref else {
                throw AgentModeFailure("invalidFocusAndType", "Focus and type requires a published field reference.")
            }
            let initial = try requireRecordIdentity(mode)
            let plan = try AgentFocusAndTypePlan(snapshot: initial.snapshot, ref: ref,
                context: initial.context, pid: initial.expectedPID)
            var tap = request
            tap.agent = AgentModeRequest(kind: .tap, expectedPID: initial.expectedPID,
                snapshotID: initial.id, ref: ref, tapStyle: .physical)
            let tapResult = await performReserved(tap, focusPlan: plan)
            last = tapResult
            try progress.append(tapResult, action: .tap)
            try Task.checkCancellation()
            guard let focused = record, last?.agent?.data.cache.requiresRefresh == false else {
                throw AgentModeFailure("focusObservationFailed", "The focus input completed without a usable field observation. Typing was stopped; do not repeat the focus input.")
            }
            let baseline = try plan.focusedBaseline(snapshot: focused.snapshot,
                context: focused.context, pid: focused.expectedPID)
            let focusedRef = try baseline.focusedReference(snapshot: focused.snapshot,
                context: focused.context, pid: focused.expectedPID)
            var type = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                screenID: request.screenID, screenUUID: request.screenUUID,
                operation: .complete, token: nil, primitives: [])
            type.agent = AgentModeRequest(kind: .typeText, expectedPID: initial.expectedPID,
                snapshotID: focused.id, ref: focusedRef, text: mode.text)
            let typeResult = await performReserved(type, focusPlan: baseline)
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
                    : "Complete explicit input recovery. Do not resubmit the focus-and-type command.",
            ])
        return response
    }

    /// One broker reservation; native input ownership remains per complete action.
    func performBatch(_ request: SelectedHIDRequest) async -> SelectedHIDResponse {
        guard !isBusy, !owner.isBusy else { return reject(request) }
        isBusy = true
        defer { isBusy = false }
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
                        : "Complete explicit input recovery before another action. Do not resubmit the batch.",
                ])
            return response
        }

        do {
            try request.validate()
            guard let batch = request.agentBatch else {
                throw AgentModeFailure("missingBatch", "The agent batch request is missing.")
            }
            let initialRecord: Record
            let referencePlan: AgentBatchReferencePlan?
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
                last = await performReserved(initial)
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
                let response: SelectedHIDResponse
                if let referencePlan {
                    response = await performReferenceBatchStep(action, step: step, index: offset,
                        plan: referencePlan, pid: batchPID)
                } else {
                    guard let current = record, current.context == baseline else {
                        throw AgentModeFailure("batchContextChanged", "The batch boot, display, orientation or hinge context changed. Later steps were stopped.")
                    }
                    guard let id = step.id else {
                        throw AgentModeFailure("invalidBatchID", "A native ID batch step has no ID.")
                    }
                    let ref = try current.snapshot.reference(id: id,
                        action: step.action == .tap ? .tap : .typeText)
                    action.agent = AgentModeRequest(kind: step.action == .tap ? .tap : .typeText,
                        expectedPID: batchPID, snapshotID: current.id, ref: ref, text: step.text)
                    response = await performReserved(action)
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
                if referencePlan != nil { continue }
                guard !result.data.cache.requiresRefresh, record != nil else {
                    throw AgentModeFailure("batchRefreshFailed", "The step ended without a usable replacement snapshot. Later steps were stopped; completed input was not replayed.")
                }
                guard record?.context == baseline else {
                    throw AgentModeFailure("batchContextChanged", "The batch boot, display, orientation or hinge context changed. Later steps were stopped.")
                }
            }
            if referencePlan != nil {
                // Reference batches validate each step against fresh native input evidence,
                // then publish one replacement table after all completed input.
                var final = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                    screenID: baseline.screenID, screenUUID: UUID(uuidString: baseline.screenUUID),
                    operation: .complete, token: nil, primitives: [])
                final.agent = AgentModeRequest(kind: .describe, expectedPID: batchPID)
                last = await performReserved(final)
                guard let finalResult = last?.agent, !finalResult.didError, record != nil else {
                    throw last?.agent?.error ?? AgentModeFailure("batchRefreshFailed", "Completed input has no usable replacement snapshot. Do not replay the batch.")
                }
                guard record?.context == baseline else {
                    throw AgentModeFailure("batchContextChanged", "The batch boot, display, orientation or hinge context changed. Completed input was not replayed.")
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

    /// A published-reference batch owns its original plan. Each step uses fresh native evidence,
    /// and does not publish an intermediate table that another step or caller could reuse.
    private func performReferenceBatchStep(_ request: SelectedHIDRequest, step: AgentBatchStep,
                                          index: Int, plan: AgentBatchReferencePlan,
                                          pid: Int32) async -> SelectedHIDResponse {
        do {
            let result: SelectedHIDResponse
            let kind: AgentModeRequest.Kind
            if step.action == .tap {
                let admission = AgentBatchTapAdmission(plan: plan, index: index)
                let native = try admission.request(requestID: request.requestID)
                record = nil
                result = await owner.perform(native, batchTap: admission)
                kind = .tap
            } else {
                // Typing retains its existing independent description and focused-field path.
                let display = try await discover(request)
                let fresh = try await observe(display: display, pid: pid)
                guard let context = fresh.context, let roots = fresh.ax?.roots else {
                    throw AgentModeFailure("missingObservation", "The batch step has no fresh native context or hierarchy.")
                }
                let snapshot = try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: fresh.ax?.nativeIdentityMetadata, context: context)
                let target = try plan.resolve(index: index, snapshot: snapshot, context: context, pid: pid)
                // The complete batch document and target plan were validated before step one.
                // Carry that chosen authority directly; no opaque ID becomes selector text.
                let mode = AgentModeRequest(kind: .typeText, expectedPID: pid, text: step.text)
                let native = try nativeRequest(request, mode: mode, pid: pid,
                    context: context, snapshot: snapshot, cached: nil, binding: target)
                record = nil
                result = await owner.perform(native)
                kind = mode.kind
            }
            let action = AgentModeActionReceipt(kind: kind, outcome: result.outcome,
                enqueuedEventCount: result.enqueuedEventCount, cleanup: result.cleanup, replayed: false,
                quarantine: result.quarantine, slider: result.ax?.slider, sliderValue: result.ax?.sliderValue)
            guard result.error == nil, result.cleanup != "uncertain" else {
                return failure(request, result.agent?.error
                    ?? AgentModeFailure("nativeActionFailed", "The native action failed."),
                    native: result, action: action)
            }
            return success(request, native: result, action: action,
                cache: AgentModeCacheState(status: "invalidated", reason: "batchInProgress", requiresRefresh: true))
        } catch {
            record = nil
            let nativeFailure = error as? AgentModeNativeFailure
            let failure = error as? AgentModeFailure
                ?? AgentModeFailure("batchObservationFailed", "The batch observation failed.")
            return self.failure(request, failure, native: nativeFailure?.response)
        }
    }

    private var now: Double { owner.currentTime }

    private func store(_ snapshot: AgentModeSnapshot, context: SelectedHIDContext, pid: Int32) -> Record {
        sequence += 1
        let value = Record(id: UUID(), sequence: sequence, capturedAt: now,
                           expectedPID: pid, context: context, snapshot: snapshot)
        record = value
        return value
    }

    private func requireRecordIdentity(_ mode: AgentModeRequest) throws -> Record {
        guard let record, mode.snapshotID == record.id else {
            throw AgentModeFailure("snapshotMissing", "The snapshot ID is absent, replaced, or belongs to another broker. Refresh the snapshot.")
        }
        guard now - record.capturedAt < Self.timeToLive else {
            throw AgentModeFailure("snapshotExpired", "The snapshot expired. Refresh the snapshot.")
        }
        _ = try AgentModePIDPolicy.expectedPID(assertion: mode.expectedPID, snapshot: record.expectedPID)
        return record
    }

    private func requireRecord(_ mode: AgentModeRequest, context: SelectedHIDContext,
                               fresh: AgentModeSnapshot) throws -> Record {
        let record = try requireRecordIdentity(mode)
        guard record.context == context else {
            throw AgentModeFailure("contextChanged", "The native runtime context changed. Refresh the snapshot.")
        }
        guard record.snapshot.nativeFingerprint == fresh.nativeFingerprint else {
            logger.info().log("Agent snapshot fingerprint mismatch: \(AgentModeSnapshotDifference.summary(previous: record.snapshot.nodes, current: fresh.nodes))")
            throw AgentModeFailure("screenChanged", "The screen changed outside this reference table. Refresh the snapshot.")
        }
        if let ref = mode.ref ?? mode.readReference {
            try record.snapshot.validateProtectedReference(ref, in: fresh)
        } else if mode.kind == .describe {
            try record.snapshot.validateProtectedTargets(in: fresh)
        }
        return record
    }

    private func discover(_ request: SelectedHIDRequest) async throws -> ActivePanelIdentity {
        try Task.checkCancellation()
        try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
        let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let simulator = set.allSimulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: simulatorUDID) }),
              simulator.state == .booted else { throw CLIError.simulatorNotFound(udid: simulatorUDID) }
        let discovery = try await ActivePanelReader.discoverWithMetadata(for: simulator)
        let panel = discovery.readback.snapshot.activePanel.identity
        if let requestedID = request.screenID, let requestedUUID = request.screenUUID {
            guard requestedID == panel.displayID, requestedUUID == panel.uniqueID else {
                throw AgentModeFailure("inactiveDisplay", "The selected display is not the measured active panel. Refresh display selection.")
            }
        }
        return panel
    }

    private func observe(display: ActivePanelIdentity, pid: Int32?) async throws -> SelectedHIDResponse {
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: display.displayID, screenUUID: display.uniqueID, operation: .complete, token: nil, primitives: [])
        request.ax = SelectedAXRequest(kind: .describe, expectedPID: pid,
            endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0, includeNativeIdentity: true)
        let result = await owner.perform(request)
        guard result.error == nil, result.cleanup != "uncertain" else {
            throw AgentModeNativeFailure(response: result)
        }
        guard result.ax?.acquisition?.outcome == .ready, let actualPID = result.ax?.expectedPID,
              result.ax?.acquisition?.attempts.last?.rootPID == actualPID else {
            throw AgentModeFailure("processEvidenceMissing", "The native observation did not confirm its application PID.")
        }
        _ = try AgentModePIDPolicy.verifiedPID(actualPID, expected: pid)
        return result
    }

    private func nativeRequest(_ outer: SelectedHIDRequest, mode: AgentModeRequest, pid: Int32, context: SelectedHIDContext,
                               snapshot: AgentModeSnapshot, cached: Record?,
                               binding: AgentBatchReferencePlan.ResolvedTarget? = nil) throws -> SelectedHIDRequest {
        guard pid > 0, let uuid = UUID(uuidString: context.screenUUID) else {
            throw AgentModeFailure("missingContext", "The selected runtime context is incomplete.")
        }
        var plannedPrimitives: [SelectedHIDPrimitive] = []
        var plannedPath: SelectedHIDPath?
        var plannedPinch: SelectedHIDPinch?
        var plannedAX: SelectedAXRequest?
        var plannedKeyboard: SelectedKeyboardRequest?
        var node: FBSimulatorAXNode?
        var chosenTarget: SelectedNativeTarget?
        if let binding {
            let current = try snapshot.match(target: binding.nativeTarget)
            try AgentModeTarget(binding.node, nativeTarget: binding.nativeTarget).validate(current)
            node = current
            chosenTarget = binding.nativeTarget
        } else if let ref = mode.ref, let cached {
            let original: FBSimulatorAXNode
            if mode.kind == .drag {
                original = try cached.snapshot.dragNode(ref: ref)
            } else if mode.kind == .pinch {
                original = try cached.snapshot.pinchNode(ref: ref)
            } else if mode.kind == .sliderEndpoint || mode.kind == .sliderPercentage {
                original = try cached.snapshot.sliderNode(ref: ref)
            } else {
                let action: RuntimeElementAction
                switch mode.kind {
                case .typeText, .keyPress, .keyCombo, .keySequence: action = .typeText
                case .swipe: action = .swipeWithin
                case .hold: action = .longPress
                default: action = .tap
                }
                original = try cached.snapshot.node(ref: ref, requiredAction: action)
            }
            let chosen = try cached.snapshot.target(ref: ref)
            let freshTarget = try snapshot.match(target: chosen)
            try AgentModeTarget(original, nativeTarget: chosen).validate(freshTarget)
            node = freshTarget
            if mode.kind == .tap, mode.tapStyle == nil || mode.tapStyle == .physical,
               freshTarget.type == "Button" {
                chosenTarget = try snapshot.physicalButtonExecutionTarget(reference: chosen,
                    node: freshTarget, context: context)
            } else { chosenTarget = chosen }
        } else if let kind = mode.selectorKind, let value = mode.selectorValue {
            switch mode.kind {
            case .typeText, .keyPress, .keyCombo, .keySequence:
                let ref = try snapshot.reference(id: value, action: .typeText)
                node = try snapshot.node(ref: ref, requiredAction: .typeText)
            default:
                node = try snapshot.match(kind: kind, value: value, type: mode.elementType)
            }
        } else if let selector = mode.tapSelector {
            node = try snapshot.match(selector, type: mode.elementType, context: context)
        }
        if let node, chosenTarget == nil {
            let selector = try snapshot.uniqueSelector(for: node)
            chosenTarget = .semantic(kind: selector.kind, value: selector.value, elementType: node.type)
        }
        var admission = AgentModeAdmission(context: context, expectedPID: pid, screenHash: snapshot.hash,
            nativeFingerprint: snapshot.nativeFingerprint,
            target: try node.map { try AgentModeTarget($0, nativeTarget: chosenTarget) }, nativeTarget: chosenTarget)
        if case let .semantic(kind, value, _)? = chosenTarget {
            admission.selectorKind = kind
            admission.selectorValue = value
        }
        switch mode.kind {
        case .describe, .read, .focusAndType: throw AgentModeFailure("invalidAction", "A description or reference read is not an input action.")
        case .tap:
            if let node {
                guard let chosenTarget else { throw AgentModeFailure("unsupportedIdentity", "The tap has no chosen native target.") }
                plannedAX = SelectedAXRequest(kind: .tap, expectedPID: pid,
                    endpoint: nil, selectorKind: nil, selectorValue: nil,
                    preDelay: mode.preDelay, postDelay: mode.postDelay, elementType: node.type, tapStyle: mode.tapStyle,
                    nativeTarget: chosenTarget)
            } else if let point = mode.point {
                let style = try (mode.tapStyle ?? .physical).resolved(for: nil)
                if mode.preDelay > 0 { plannedPrimitives.append(.delay(mode.preDelay)) }
                plannedPrimitives += try style.primitives(x: point.x, y: point.y)
                if mode.postDelay > 0 { plannedPrimitives.append(.delay(mode.postDelay)) }
            } else { throw AgentModeFailure("missingTarget", "The tap target is unavailable.") }
        case .hold:
            guard let node else {
                throw AgentModeFailure("missingHoldTarget", "The fresh hold target is unavailable.")
            }
            guard let chosenTarget else { throw AgentModeFailure("unsupportedIdentity", "The hold has no chosen native target.") }
            plannedAX = SelectedAXRequest(kind: .hold, expectedPID: pid,
                endpoint: nil, selectorKind: nil, selectorValue: nil,
                preDelay: 0, postDelay: 0, elementType: node.type, holdDuration: mode.duration, nativeTarget: chosenTarget)
        case .doubleTap:
            guard let node, let timing = mode.doubleTapTiming else {
                throw AgentModeFailure("missingDoubleTapTarget", "The fresh double-tap target or timing is unavailable.")
            }
            guard let chosenTarget else { throw AgentModeFailure("unsupportedIdentity", "The double-tap has no chosen native target.") }
            plannedAX = SelectedAXRequest(kind: .doubleTap, expectedPID: pid,
                endpoint: nil, selectorKind: nil, selectorValue: nil,
                preDelay: mode.preDelay, postDelay: mode.postDelay,
                elementType: node.type, doubleTapTiming: timing, nativeTarget: chosenTarget)
        case .pinch:
            guard let node, let geometry = mode.pinch, let frame = node.frame else {
                throw AgentModeFailure("missingPinchTarget", "The fresh pinch area or geometry is unavailable.")
            }
            let selector = try snapshot.uniqueSelector(for: node)
            _ = try snapshot.pinchNode(kind: selector.kind, value: selector.value, type: node.type)
            plannedPinch = geometry.selected(at: CGPoint(x: frame.midX, y: frame.midY),
                duration: mode.duration, preDelay: mode.preDelay, postDelay: mode.postDelay)
        case .sliderPercentage:
            guard let node, node.type == "Slider", let percentage = mode.sliderPercentage else {
                throw AgentModeFailure("missingSliderTarget", "The fresh slider target or percentage is unavailable.")
            }
            let selector = try snapshot.uniqueSelector(for: node)
            let endpoint = SelectedAXRequest.endpoint(forPercentage: percentage)
            plannedAX = SelectedAXRequest(kind: endpoint == nil ? .sliderPercentage : .sliderEndpoint,
                expectedPID: pid,
                endpoint: endpoint, selectorKind: selector.kind, selectorValue: selector.value,
                preDelay: 0, postDelay: 0, elementType: node.type, percentage: endpoint == nil ? percentage : nil)
        case .sliderEndpoint:
            guard let node, node.type == "Slider", let endpoint = mode.sliderEndpoint else {
                throw AgentModeFailure("missingSliderTarget", "The fresh slider target or endpoint is unavailable.")
            }
            let selector = try snapshot.uniqueSelector(for: node)
            plannedAX = SelectedAXRequest(kind: .sliderEndpoint, expectedPID: pid,
                endpoint: endpoint, selectorKind: selector.kind, selectorValue: selector.value,
                preDelay: 0, postDelay: 0, elementType: node.type)
        case .keyPress, .keyCombo, .keySequence:
            guard let node, let chosenTarget, let events = mode.keyEvents else {
                throw AgentModeFailure("unsupportedKeyTarget", "Keyboard input requires a chosen focused native field.")
            }
            try SelectedKeyboardFocusPolicy.validate(node, expectedPID: pid, fieldTarget: chosenTarget)
            plannedKeyboard = SelectedKeyboardRequest(expectedPID: pid, fieldTarget: chosenTarget, events: events)
        case .typeText:
            guard let node, let chosenTarget, let text = mode.text, !text.isEmpty,
                  text.utf8.count <= SelectedKeyboardRequest.maximumTextBytes else {
                throw AgentModeFailure("unsupportedTextTarget", "Typing requires a chosen focused native field and bounded text.")
            }
            try SelectedKeyboardFocusPolicy.validate(node, expectedPID: pid, fieldTarget: chosenTarget)
            plannedKeyboard = SelectedKeyboardRequest(expectedPID: pid, fieldTarget: chosenTarget,
                events: try SelectedKeyboardRequest.primitives(from: SelectedKeyboardRequest.textEvent(text)))
        case .swipe:
            guard let node, let ref = mode.ref, let cached, let direction = mode.direction,
                  let original = cached.snapshot.elements.first(where: { $0.ref == ref }) else {
                throw AgentModeFailure("missingSwipeTarget", "The swipe target is unavailable.")
            }
            let plan = try AgentModeSwipePlanner.plan(target: node, snapshot: snapshot,
                logicalSize: CGSize(width: context.logicalWidth, height: context.logicalHeight),
                role: original.role, direction: direction, distance: mode.distance, nativeTarget: chosenTarget)
            let points = plan.points
            plannedPath = SelectedHIDPath(kind: .swipe, startX: points.from.x, startY: points.from.y,
                endX: points.to.x, endY: points.to.y, duration: mode.duration, delta: 50,
                preDelay: mode.preDelay, postDelay: mode.postDelay)
        case .drag:
            guard let node, let frame = node.frame, let destination = mode.destination,
                  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                  frame.width > 0, frame.height > 0 else {
                throw AgentModeFailure("missingDragTarget", "The fresh native drag target has no valid frame.")
            }
            let bounds = CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight)
            let start = CGPoint(x: frame.midX, y: frame.midY)
            let end = CGPoint(x: destination.x, y: destination.y)
            guard bounds.contains(start), bounds.contains(end) else {
                throw AgentModeFailure("invalidDragGeometry", "The drag start and destination must be inside the current selected display.")
            }
            plannedPath = SelectedHIDPath(kind: .drag, startX: start.x, startY: start.y,
                endX: end.x, endY: end.y, duration: mode.duration, steps: mode.steps,
                preDelay: mode.preDelay, postDelay: mode.postDelay)
        case .complete:
            guard mode.snapshotID != nil, outer.hinge == nil, outer.rotation == nil,
                  outer.keyboard == nil, outer.ax == nil, outer.home == nil, outer.button == nil,
                  outer.pinch == nil, outer.gesture == nil, outer.path != nil || !outer.primitives.isEmpty else {
                throw AgentModeFailure("unsupportedCompleteAction", "This agent slice supports complete coordinate paths and taps only.")
            }
            plannedPath = outer.path
            plannedPrimitives = outer.primitives
        }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: outer.requestID,
            screenID: context.screenID, screenUUID: uuid, operation: .complete, token: nil,
            primitives: plannedPrimitives, path: plannedPath, pinch: plannedPinch, ax: plannedAX,
            keyboard: plannedKeyboard, agentAdmission: admission)
        try request.validate()
        return request
    }

    private func success(_ request: SelectedHIDRequest, native: SelectedHIDResponse,
                         capture: AgentModeCapture? = nil, action: AgentModeActionReceipt? = nil,
                         cache: AgentModeCacheState, observation: AgentModeObservationEvidence? = nil,
                         detail: AgentModeTextDetail? = nil,
                         nextSteps: [String] = []) -> SelectedHIDResponse {
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: owner.brokerID, outcome: native.outcome, token: nil,
            enqueuedEventCount: native.enqueuedEventCount, cleanup: native.cleanup, error: nil, context: native.context)
        response.quarantine = native.quarantine
        response.agent = AgentModeResult(capture: capture, action: action, cache: cache,
            context: native.context, quarantine: native.quarantine, observation: observation,
            detail: detail, nextSteps: nextSteps)
        return response
    }

    private func failure(_ request: SelectedHIDRequest, _ error: AgentModeFailure,
                         native: SelectedHIDResponse? = nil, action: AgentModeActionReceipt? = nil,
                         cache: AgentModeCacheState? = nil, nextSteps: [String]? = nil) -> SelectedHIDResponse {
        let publicError = AgentModePublicErrorProjection.project(error, native: native)
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: owner.brokerID, outcome: native?.outcome ?? "rejectedBeforeInput", token: nil,
            enqueuedEventCount: native?.enqueuedEventCount ?? 0, cleanup: native?.cleanup ?? "notNeeded",
            error: publicError.message, context: native?.context)
        response.quarantine = native?.quarantine
        let observation = AgentModeObservationEvidence(native)
        let recoverySteps: [String]
        if native?.quarantine != nil {
            recoverySteps = ["Inspect the quarantine receipt and complete explicit input recovery before retrying. Input was not replayed."]
        } else if let instruction = observation?.captureInstruction(udid: simulatorUDID) {
            recoverySteps = [instruction]
        } else {
            recoverySteps = ["Run describe-ui --agent for a fresh snapshot of the frontmost application. Input was not replayed."]
        }
        response.agent = AgentModeResult(error: publicError, action: action,
            batch: request.agentBatch.map { AgentBatchReceipt(totalSteps: $0.steps.count,
                completedSteps: 0, steps: [], stoppedAt: 1) },
            cache: cache ?? AgentModeCacheState(status: "invalidated", reason: publicError.code, requiresRefresh: true),
            context: native?.context, quarantine: native?.quarantine, observation: observation,
            nextSteps: nextSteps ?? recoverySteps)
        return response
    }
}
