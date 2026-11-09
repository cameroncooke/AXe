import Foundation
import FBControlCore
import FBSimulatorControl

/// One accepted broker call owns this transaction until its local cleanup ends.
/// MainActor alone does not exclude reentrancy; SelectedHIDAdmission is the owner.
@MainActor
enum SelectedAXOperation {
    static func perform(_ request: SelectedHIDRequest, simulatorUDID: String,
                        brokerID: UUID, logger: AxeLogger,
                        valueOwner: SelectedSliderValueOwner? = nil,
                        transportOwner: FBSimulatorHIDTransportOwner? = nil,
                        batchTap: (any AgentOwnedTapAdmission)? = nil) async -> SelectedHIDResponse {
        guard let ax = request.ax else {
            return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: brokerID, outcome: "rejectedBeforeInput", token: nil, enqueuedEventCount: 0,
                cleanup: "notNeeded", error: "Missing AX payload", context: nil)
        }
        var result = SelectedAXResult(kind: ax.kind, expectedPID: ax.expectedPID)
        var observation: FBSimulatorHIDSessionObservation?
        var feed: FBSimulatorHIDNativeFreshnessProvider?
        var target: FBSimulatorAXTargetOperation?
        var session: FBSimulatorHIDSession?
        var sizeGuard: SelectedAXSizeGuard?
        var count = 0
        var cleanup = "notNeeded"
        do {
            try Task.checkCancellation()
            let simulator = try await PhaseTimer.measure("ax.simulatorSet") {
                try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
            }
            if ax.preDelay > 0 { try await PhaseTimer.measure("ax.preDelay") { try await Task.sleep(for: .seconds(ax.preDelay)) } }
            let display = try request.selectedDisplay()
            if ax.kind == .describe || ax.kind == .describePoint {
                // A snapshot is a bounded read. Live subscriptions belong to actual input.
                let reader = PhaseTimedFreshnessProvider(FBSimulatorNativeContextReader(simulator: simulator,
                    screenID: display.id, screenUniqueID: display.uuid))
                let initial = try await PhaseTimer.measure("ax.contextRead") { try await reader.observation() }
                observation = initial
                try SelectedAXBounds.validateContext(SelectedHIDContext(initial))
                try request.agentAdmission?.validateContext(initial)
                let policy: FBSimulatorAXAcquisitionPolicy
                if ax.kind == .describe {
                    policy = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: 8, maximumAttempts: 8,
                        retryDelaySeconds: 0.5)
                } else {
                    policy = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: 8, maximumAttempts: 4)
                }
                let acquisition = try await PhaseTimer.measure("ax.acquire") { () async throws -> FBSimulatorAXAcquisition in
                    if ax.kind == .describePoint {
                        guard let point = ax.point else {
                            throw SelectedHIDFailure.invalid("Selected point description requires a point")
                        }
                        let expectedPID: Int32
                        if let bound = ax.expectedPID {
                            expectedPID = bound
                        } else {
                            // Bind the frontmost app once; the point read still requires it before and after.
                            expectedPID = try await FBSimulatorAXSnapshot.frontmostApplicationPID(for: simulator,
                                observation: initial, freshnessProvider: reader)
                            result.expectedPID = expectedPID
                        }
                        result.point = point
                        return try await FBSimulatorAXSnapshot.acquire(at: CGPoint(x: point.x, y: point.y),
                            for: simulator, expectedPID: expectedPID, observation: initial,
                            freshnessProvider: reader, policy: policy, includeNativeIdentity: ax.includeNativeIdentity == true)
                    } else if let expectedPID = ax.expectedPID {
                        return try await FBSimulatorAXSnapshot.acquire(for: simulator, expectedPID: expectedPID,
                            observation: initial, freshnessProvider: reader, policy: policy, includeNativeIdentity: ax.includeNativeIdentity == true)
                    } else {
                        return try await FBSimulatorAXSnapshot.acquireFrontmost(for: simulator,
                            observation: initial, freshnessProvider: reader, policy: policy, includeNativeIdentity: ax.includeNativeIdentity == true)
                    }
                }
                result.acquisition = try SelectedAXAcquisition(acquisition)
                result.roots = acquisition.snapshot?.roots
                result.nativeIdentityMetadata = acquisition.snapshot?.nativeIdentityMetadata
                // A point read bound its PID before reading; only a whole-tree read discovers it here.
                if ax.kind == .describe, ax.expectedPID == nil, acquisition.outcome == .ready {
                    guard let observedPID = acquisition.attempts.last?.rootPID, observedPID > 0,
                          result.roots?.contains(where: { $0.type == "Application" && $0.pid == observedPID }) == true else {
                        throw SelectedHIDFailure.invalid("Frontmost acquisition did not confirm one positive application PID")
                    }
                    result.expectedPID = observedPID
                }
                try SelectedAXBounds.validateContent(result)
                guard acquisition.outcome == .ready else {
                    result.failure = .acquisitionFailed
                    throw SelectedHIDFailure.invalid("Selected AX acquisition ended with \(acquisition.outcome.rawValue): \(acquisition.failureDescription ?? "No further detail")")
                }
                return response(request, brokerID: brokerID, result: result, observation: observation,
                    outcome: "ready", count: 0, cleanup: "notNeeded", error: nil)
            }
            if let bound = ax.expectedPID, bound <= 0 {
                throw SelectedHIDFailure.invalid("Selected AX input requires a positive expected PID")
            }
            let live = try await PhaseTimer.measure("ax.liveContextStart") {
                try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator,
                    screenID: display.id, screenUniqueID: display.uuid)
            }
            feed = live; observation = live.initialObservation
            let expectedPID: Int32
            if let bound = ax.expectedPID {
                expectedPID = bound
            } else {
                // Without --expected-pid, bind the app that is frontmost now. Every later target,
                // hit and frontmost check requires this PID, so an app change fails before input.
                expectedPID = try await PhaseTimer.measure("ax.frontmostPID") {
                    try await FBSimulatorAXSnapshot.frontmostApplicationPID(for: simulator,
                        observation: live.initialObservation, freshnessProvider: live)
                }
                result.expectedPID = expectedPID
            }
            try SelectedAXBounds.validateContext(SelectedHIDContext(live.initialObservation))
            try request.agentAdmission?.validateContext(live.initialObservation)
            try batchTap?.validateContext(SelectedHIDContext(live.initialObservation), pid: expectedPID)
            if ax.kind == .semanticPress {
                guard let identifier = ax.selectorValue else { throw SelectedHIDFailure.invalid("Missing semantic press ID") }
                let receipt = try await FBSimulatorAXSemanticPress.perform(for: simulator,
                    expectedPID: expectedPID, identifier: identifier, observation: live.initialObservation,
                    freshnessProvider: live)
                result.press = receipt
                let valueChanged = receipt.outcome == "switchValueChangedObserved"
                if !valueChanged { result.failure = .pressFailed }
                // AXe sends no HID here. The native action can still cause guest touch events.
                // An uncertain semantic send keeps the common lease.
                let semanticCleanup = receipt.delivery == "uncertain" ? "uncertain" : "notNeeded"
                await live.closeAndWait()
                return response(request, brokerID: brokerID, result: result, observation: observation,
                    outcome: receipt.outcome, count: 0, cleanup: semanticCleanup,
                    error: valueChanged ? nil : receipt.failure ?? "Semantic switch value change not observed; no replay")
            }
            if ax.kind == .sliderEndpoint {
                guard let selectorValue = ax.selectorValue, let endpoint = ax.endpoint else {
                    throw SelectedHIDFailure.invalid("Missing selected slider endpoint or selector")
                }
                try SelectedSliderResult.validateCapacity(result: result, context: SelectedHIDContext(live.initialObservation))
                let sliderAdmission = try request.agentAdmission.map(AgentModeSliderAdmission.init)
                let backend: FBSimulatorSliderBackend
                switch ax.selectorKind {
                case .id:
                    backend = FBSimulatorSliderBackend(simulator: simulator, observation: live.initialObservation,
                        freshnessProvider: live, identifier: selectorValue, expectedPID: expectedPID,
                        elementType: ax.elementType, admissionGuard: sliderAdmission)
                case .label:
                    backend = FBSimulatorSliderBackend(simulator: simulator, observation: live.initialObservation,
                        freshnessProvider: live, label: selectorValue, expectedPID: expectedPID,
                        elementType: ax.elementType, admissionGuard: sliderAdmission)
                default:
                    throw SelectedHIDFailure.invalid("Selected slider requires an ID or label")
                }
                let receipt = await FBSimulatorSliderEndpointController().run(endpoint: endpoint,
                    backend: backend, budgetSeconds: 15, maximumActions: 20)
                result.slider = SelectedSliderResult(receipt)
                if receipt.outcome == "failed" { result.failure = .sliderFailed }
                await live.closeAndWait()
                return response(request, brokerID: brokerID, result: result, observation: observation,
                    outcome: receipt.outcome, count: 0, cleanup: "notNeeded",
                    error: receipt.outcome == "failed" ? "Selected slider failed: " + (result.slider?.reason ?? "unknown") : nil)
            }
            if ax.kind == .sliderPercentage {
                guard let valueOwner, let percentage = ax.percentage,
                      let selectorKind = ax.selectorKind, let selectorValue = ax.selectorValue else {
                    throw SelectedHIDFailure.invalid("Missing owned slider percentage operation or selector")
                }
                let sliderAdmission = try request.agentAdmission.map(AgentModeSliderAdmission.init)
                let operation = SelectedSliderValueOperation(simulator: simulator,
                    observation: live.initialObservation, live: live,
                    selectorKind: selectorKind, selectorValue: selectorValue, expectedPID: expectedPID,
                    elementType: ax.elementType,
                    admissionGuard: sliderAdmission, transportOwner: transportOwner)
                let execution = await valueOwner.run(operation, percent: percentage)
                result.sliderValue = execution.receipt
                if execution.error != nil { result.failure = .sliderFailed }
                if execution.cleanup == "uncertain" { result.failure = .cleanupUncertain }
                await live.closeAndWait()
                return response(request, brokerID: brokerID, result: result, observation: observation,
                    outcome: execution.outcome, count: execution.enqueuedEventCount,
                    cleanup: execution.cleanup, error: execution.error)
            }
            let policy = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: 8, maximumAttempts: 4)
            guard let selector = ax.selector else { throw SelectedHIDFailure.invalid("Missing selected selector") }
            if let waitPolicy = ax.waitPolicy {
                result.wait = try await PhaseTimer.measure("ax.wait") { try await SelectedAXWait.run(policy: waitPolicy) { timeout in
                    try live.validateCurrentRevision(expected: live.initialObservation)
                    let probePolicy = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: timeout, maximumAttempts: 4)
                    let acquisition = try await FBSimulatorAXSnapshot.acquire(for: simulator, expectedPID: expectedPID,
                        observation: live.initialObservation, freshnessProvider: live, policy: probePolicy,
                        includeNativeIdentity: ax.nativeTarget?.nativeIdentity != nil)
                    try Task.checkCancellation()
                    guard acquisition.outcome == .ready, let snapshot = acquisition.snapshot else {
                        throw SelectedAXWaitAcquisitionFailure(acquisition: acquisition)
                    }
                    // Only this typed resolution can report a retryable missing target.
                    _ = try await snapshot.resolve(selector, freshnessProvider: live)
                } }
            }
            try Task.checkCancellation()
            // Starts before the library budget. It can reject earlier, never extend it.
            let deadline = DispatchTime.now() + policy.timeoutSeconds
            let opaqueFrameTapAdmission = try SelectedOpaqueFrameTapAdmission.make(for: ax)
            // Includes the target's own hierarchy read.
            let operation = try await PhaseTimer.measure("ax.targetOpen") { () async throws -> FBSimulatorAXTargetOperation in
                if ax.kind == .tap, ax.nativeTarget?.nativeIdentity != nil {
                    return try await FBSimulatorAXTargetOperation.openForNativeObjectTap(for: simulator,
                        expectedPID: expectedPID, selector: selector, observation: live.initialObservation,
                        freshnessProvider: live, policy: policy, opaqueFrameTapAdmission: opaqueFrameTapAdmission)
                }
                return try await FBSimulatorAXTargetOperation.open(for: simulator, expectedPID: expectedPID,
                    selector: selector, observation: live.initialObservation, freshnessProvider: live, policy: policy,
                    includeNativeIdentity: ax.nativeTarget?.nativeIdentity != nil || batchTap?.requiresNativeIdentity == true,
                    opaqueFrameTapAdmission: opaqueFrameTapAdmission)
            }
            target = operation
            let inputAdmission = try await PhaseTimer.measure("ax.admission") { () async throws -> AgentModeAdmission? in
                if let batchTap {
                    return try batchTap.validateOwnedSnapshot(roots: await operation.snapshot.roots,
                        nativeIdentityMetadata: await operation.snapshot.nativeIdentityMetadata, context: SelectedHIDContext(live.initialObservation), pid: expectedPID,
                        nativeTarget: await operation.reference.node)
                } else if let agentAdmission = request.agentAdmission {
                    try agentAdmission.validateScreen(await operation.snapshot.roots,
                        nativeIdentityMetadata: await operation.snapshot.nativeIdentityMetadata)
                    try agentAdmission.target?.validate(await operation.reference.node)
                    return agentAdmission
                }
                return nil
            }
            result.acquisition = try SelectedAXAcquisition(await operation.acquisition)
            result.roots = await operation.snapshot.roots
            result.nativeIdentityMetadata = await operation.snapshot.nativeIdentityMetadata
            result.target = await operation.reference.node
            let point = await operation.point
            result.point = SelectedAXPoint(x: point.x, y: point.y)
            try SelectedAXBounds.validateContent(result)
            let style: SelectedTapStyle?
            if ax.kind == .doubleTap {
                style = nil
            } else {
                style = try ax.resolvedTapStyle(target: result.target)
            }
            let guardOwner = SelectedAXSizeGuard(operation: operation, result: result, deadline: deadline,
                automaticStyle: ax.tapStyle == .automatic ? style : nil, agentAdmission: inputAdmission)
            sizeGuard = guardOwner
            let hid = try await PhaseTimer.measure("ax.hidOpen") { () async throws -> FBSimulatorHIDSession in
                if let transportOwner {
                    return try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                        liveFreshnessProvider: live, transportOwner: transportOwner)
                }
                return try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                    liveFreshnessProvider: live)
            }
            session = hid
            let event: FBSimulatorHIDEvent
            if ax.kind == .doubleTap {
                guard let timing = ax.doubleTapTiming else {
                    throw SelectedHIDFailure.invalid("Missing reference double-tap timing")
                }
                // AX pre/post delays stay outside input, as for the existing target actions.
                event = try SelectedHIDCompleteGesture.doubleTap(.init(
                    point: .init(x: point.x, y: point.y), hold: timing.hold, interval: timing.interval))
                    .event(observation: live.initialObservation)
            } else {
                event = try ax.tapEvent(at: point, target: result.target)
            }
            // Includes the guard's pre-input target validation and event drain.
            let receipt = try await PhaseTimer.measure("ax.hidExecute") { try await hid.execute(event, admissionGuard: guardOwner) }
            result = await guardOwner.result
            count = await hid.status().enqueuedEventCount
            cleanup = try await PhaseTimer.measure("ax.hidClose") { try await hid.close().cleanup.rawValue }
            guard cleanup != "uncertain" else { throw SelectedHIDFailure.invalid("Selected AX input cleanup is uncertain") }
            try await PhaseTimer.measure("ax.targetClose") { try await operation.close() }
            target = nil
            await PhaseTimer.measure("ax.liveContextClose") { await live.closeAndWait() }
            if ax.postDelay > 0 { try await PhaseTimer.measure("ax.postDelay") { try await Task.sleep(for: .seconds(ax.postDelay)) } }
            return response(request, brokerID: brokerID, result: result, observation: observation,
                outcome: receipt.outcome.rawValue, count: count, cleanup: cleanup, error: nil)
        } catch {
            result.failure = result.failure ?? (count > 0 ? .inputFailed : .setupFailed)
            if let failure = error as? SelectedAXWaitFailure {
                result.wait = failure.receipt
                switch failure.receipt.outcome {
                case .timedOut: result.failure = .waitTimedOut
                case .cancelled: result.failure = .waitCancelled
                case .failed, .matched: result.failure = .targetRejected
                }
                if let acquisition = failure.cause as? SelectedAXWaitAcquisitionFailure {
                    result.acquisition = try? SelectedAXAcquisition(acquisition.acquisition)
                    if failure.receipt.outcome == .failed { result.failure = .acquisitionFailed }
                }
            }
            if error is SelectedAXContentError { result.failure = .responseTooLarge }
            if let failure = error as? FBSimulatorAXTargetOpenFailure {
                result.failure = .targetRejected
                result.acquisition = try? SelectedAXAcquisition(failure.acquisition)
            }
            if let sizeGuard {
                let failure = result.failure
                result = await sizeGuard.result
                result.failure = failure
            }
            if let target {
                if let validation = await target.validationReceipt() { result.validation = SelectedAXValidation(validation) }
                if let rejected = await target.rejectedHitReceipt() {
                    result.rejectedHit = SelectedAXRejectedHit(rejected)
                    // HID may wrap the thrown error as text; the owned receipt retains its type.
                    result.failure = .targetRejected
                }
            }
            if let session {
                count = await session.status().enqueuedEventCount
                if let closed = try? await session.close() { cleanup = closed.cleanup.rawValue }
                else { cleanup = "uncertain" }
            }
            if let target {
                do { try await target.close() }
                catch { cleanup = "uncertain" }
            }
            await feed?.closeAndWait()
            if cleanup == "uncertain" { result.failure = .cleanupUncertain }
            else if count > 0 { result.failure = .inputFailed }
            let outcome = count == 0 && cleanup == "notNeeded" ? "failedBeforeInput" : "failedNoReplay"
            var failed = response(request, brokerID: brokerID, result: result, observation: observation,
                outcome: outcome, count: count, cleanup: cleanup, error: Self.publicText(error))
            // Owned admission rejections before input keep their typed code for the agent reply.
            if batchTap != nil || (request.agentAdmission != nil && outcome == "failedBeforeInput"),
               let policyFailure = error as? AgentModeFailure {
                failed.agent = AgentModeResult(error: policyFailure,
                    cache: AgentModeCacheState(status: "invalidated", reason: policyFailure.code, requiresRefresh: true),
                    context: failed.context)
            }
            return failed
        }
    }

    /// Error text an agent can act on: a typed AXe failure's own message, otherwise the error's
    /// localized description. Never a Swift debug rendering of the error value.
    private static func publicText(_ error: Error) -> String {
        if let failure = error as? AgentModeFailure { return failure.message }
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        return error.localizedDescription
    }

    private static func response(_ request: SelectedHIDRequest, brokerID: UUID, result: SelectedAXResult,
                                 observation: FBSimulatorHIDSessionObservation?, outcome: String, count: Int,
                                 cleanup: String, error: String?) -> SelectedHIDResponse {
        SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID, brokerID: brokerID,
            outcome: outcome, token: nil, enqueuedEventCount: count, cleanup: cleanup, error: error,
            context: observation.map(SelectedHIDContext.init), ax: result)
    }
}

/// Serialization remains inside admission. The session's fast revision check follows.
actor SelectedAXSizeGuard: FBSimulatorHIDInputAdmissionGuard {
    private let operation: FBSimulatorAXTargetOperation
    private let deadline: DispatchTime
    private let automaticStyle: SelectedTapStyle?
    private let agentAdmission: AgentModeAdmission?
    private(set) var result: SelectedAXResult
    init(operation: FBSimulatorAXTargetOperation, result: SelectedAXResult, deadline: DispatchTime,
         automaticStyle: SelectedTapStyle? = nil, agentAdmission: AgentModeAdmission? = nil) {
        self.operation = operation; self.result = result; self.deadline = deadline
        self.automaticStyle = automaticStyle
        self.agentAdmission = agentAdmission
    }
    func validate(observation: FBSimulatorHIDSessionObservation, firstEvent: FBSimulatorHIDEvent) async throws {
        try checkDeadline()
        try agentAdmission?.validateContext(observation)
        try await operation.validate(observation: observation, firstEvent: firstEvent)
        guard let receipt = await operation.validationReceipt() else {
            throw SelectedHIDFailure.invalid("Missing selected target validation receipt")
        }
        result.validation = SelectedAXValidation(receipt)
        try agentAdmission?.target?.validate(receipt.verifiedTarget)
        if let automaticStyle {
            try automaticStyle.validateAutomaticChoice(verifiedTarget: receipt.verifiedTarget)
        }
        try checkDeadline()
        try SelectedAXBounds.validateContent(result)
        try checkDeadline()
    }
    private func checkDeadline() throws {
        try Task.checkCancellation()
        guard DispatchTime.now() < deadline else {
            throw SelectedHIDFailure.invalid("Selected AX admission deadline exceeded; no input")
        }
    }
}
