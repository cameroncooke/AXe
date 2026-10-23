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
        return await performReserved(request)
    }

    private func performReserved(_ request: SelectedHIDRequest) async -> SelectedHIDResponse {
        var action: AgentModeActionReceipt?
        do {
            try request.validate()
            guard let mode = request.agent, let pid = mode.expectedPID else {
                throw AgentModeFailure("missingRequest", "The agent request is missing.")
            }
            let display = try await discover(request)
            let fresh = try await observe(display: display, pid: pid)
            guard let context = fresh.context, let roots = fresh.ax?.roots else {
                throw AgentModeFailure("missingObservation", "The native observation has no selected context or hierarchy.")
            }
            let snapshot = try AgentModeSnapshot(roots: roots)
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
                          previous.snapshot.hash == snapshot.hash,
                          previous.snapshot.nativeFingerprint == snapshot.nativeFingerprint {
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
            let native = try nativeRequest(request, mode: mode, context: context, snapshot: snapshot, cached: cached)
            // Invalidate before input, including partial or uncertain native delivery.
            record = nil
            let result = await owner.perform(native)
            action = AgentModeActionReceipt(kind: mode.kind, outcome: result.outcome,
                enqueuedEventCount: result.enqueuedEventCount, cleanup: result.cleanup, replayed: false,
                quarantine: result.quarantine, slider: result.ax?.slider, sliderValue: result.ax?.sliderValue)
            guard result.error == nil, result.cleanup != "uncertain" else {
                return failure(request, AgentModeFailure("nativeActionFailed", result.error ?? "Native cleanup is uncertain."),
                               native: result, action: action)
            }
            // A fresh replacement is useful, but its failure must not suggest replaying the action.
            do {
                try await Task.sleep(for: .milliseconds(300))
                let afterDisplay = try await discover(request)
                let after = try await observe(display: afterDisplay, pid: pid)
                guard let afterContext = after.context, let afterRoots = after.ax?.roots else {
                    throw AgentModeFailure("refreshFailed", "The action completed, but its replacement snapshot is unavailable.")
                }
                let stored = store(try AgentModeSnapshot(roots: afterRoots), context: afterContext, pid: pid)
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
        } catch {
            record = nil
            let nativeFailure = error as? AgentModeNativeFailure
            let reason = error as? AgentModeFailure
                ?? AgentModeFailure("observationFailed", nativeFailure?.response.error ?? String(describing: error))
            return failure(request, reason, native: nativeFailure?.response, action: action)
        }
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
            var initial = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
            initial.agent = AgentModeRequest(kind: .describe, expectedPID: batch.expectedPID)
            last = await performReserved(initial)
            guard let initialResult = last?.agent, !initialResult.didError, let baseline = record?.context else {
                throw last?.agent?.error ?? AgentModeFailure("batchObservationFailed", "The initial batch observation failed.")
            }
            for (offset, step) in batch.steps.enumerated() {
                currentIndex = offset + 1
                currentRequestID = UUID()
                try Task.checkCancellation()
                guard let current = record, current.context == baseline else {
                    throw AgentModeFailure("batchContextChanged", "The batch boot, display, orientation or hinge context changed. Later steps were stopped.")
                }
                let ref = try current.snapshot.reference(id: step.id,
                    action: step.action == .tap ? .tap : .typeText)
                var action = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: currentRequestID,
                    screenID: baseline.screenID, screenUUID: UUID(uuidString: baseline.screenUUID),
                    operation: .complete, token: nil, primitives: [])
                action.agent = AgentModeRequest(kind: step.action == .tap ? .tap : .typeText,
                    expectedPID: batch.expectedPID, snapshotID: current.id, ref: ref, text: step.text)
                let response = await performReserved(action)
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
                guard didComplete, !result.data.cache.requiresRefresh, record != nil else {
                    throw AgentModeFailure("batchRefreshFailed", "The step ended without a usable replacement snapshot. Later steps were stopped; completed input was not replayed.")
                }
                guard record?.context == baseline else {
                    throw AgentModeFailure("batchContextChanged", "The batch boot, display, orientation or hinge context changed. Later steps were stopped.")
                }
            }
            return finish(nil)
        } catch {
            let failure = error as? AgentModeFailure
                ?? AgentModeFailure("batchStopped", String(describing: error))
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

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func store(_ snapshot: AgentModeSnapshot, context: SelectedHIDContext, pid: Int32) -> Record {
        sequence += 1
        let value = Record(id: UUID(), sequence: sequence, capturedAt: now,
                           expectedPID: pid, context: context, snapshot: snapshot)
        record = value
        return value
    }

    private func requireRecord(_ mode: AgentModeRequest, context: SelectedHIDContext,
                               fresh: AgentModeSnapshot) throws -> Record {
        guard let record, mode.snapshotID == record.id else {
            throw AgentModeFailure("snapshotMissing", "The snapshot ID is absent, replaced, or belongs to another broker. Refresh the snapshot.")
        }
        guard now - record.capturedAt < Self.timeToLive else {
            throw AgentModeFailure("snapshotExpired", "The snapshot expired. Refresh the snapshot.")
        }
        guard record.expectedPID == mode.expectedPID, record.context == context else {
            throw AgentModeFailure("contextChanged", "The native runtime context changed. Refresh the snapshot.")
        }
        guard record.snapshot.nativeFingerprint == fresh.nativeFingerprint else {
            throw AgentModeFailure("screenChanged", "The screen changed outside this reference table. Refresh the snapshot.")
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

    private func observe(display: ActivePanelIdentity, pid: Int32) async throws -> SelectedHIDResponse {
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: display.displayID, screenUUID: display.uniqueID, operation: .complete, token: nil, primitives: [])
        request.ax = SelectedAXRequest(kind: .describe, expectedPID: pid, preparation: .automationSession,
            endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0)
        let result = await owner.perform(request)
        guard result.error == nil, result.cleanup != "uncertain" else {
            throw AgentModeNativeFailure(response: result)
        }
        guard let actualPID = result.ax?.acquisition?.attempts.last?.rootPID, actualPID == pid else {
            throw AgentModeFailure("processEvidenceMissing", "The native observation did not confirm the requested application PID.")
        }
        return result
    }

    private func nativeRequest(_ outer: SelectedHIDRequest, mode: AgentModeRequest, context: SelectedHIDContext,
                               snapshot: AgentModeSnapshot, cached: Record?) throws -> SelectedHIDRequest {
        guard let pid = mode.expectedPID, let uuid = UUID(uuidString: context.screenUUID) else {
            throw AgentModeFailure("missingContext", "The selected runtime context is incomplete.")
        }
        var plannedPrimitives: [SelectedHIDPrimitive] = []
        var plannedPath: SelectedHIDPath?
        var plannedPinch: SelectedHIDPinch?
        var plannedAX: SelectedAXRequest?
        var plannedKeyboard: SelectedKeyboardRequest?
        var node: FBSimulatorAXNode?
        if let ref = mode.ref, let cached {
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
            let freshTarget = try snapshot.resolve(original)
            try AgentModeTarget(original).validate(freshTarget)
            node = freshTarget
        } else if let kind = mode.selectorKind, let value = mode.selectorValue {
            node = try snapshot.match(kind: kind, value: value, type: mode.elementType)
        } else if let selector = mode.tapSelector {
            node = try snapshot.match(selector, type: mode.elementType, context: context)
        }
        var admission = AgentModeAdmission(context: context, expectedPID: pid, screenHash: snapshot.hash,
                                          nativeFingerprint: snapshot.nativeFingerprint, target: try node.map { try AgentModeTarget($0) })
        if let node {
            let selector = try snapshot.uniqueSelector(for: node)
            admission.selectorKind = selector.kind
            admission.selectorValue = selector.value
        }
        switch mode.kind {
        case .describe: throw AgentModeFailure("invalidAction", "A description is not an input action.")
        case .tap:
            if let node {
                let selector = try snapshot.uniqueSelector(for: node)
                plannedAX = SelectedAXRequest(kind: .tap, expectedPID: pid, preparation: .automationSession,
                    endpoint: nil, selectorKind: selector.kind, selectorValue: selector.value,
                    preDelay: mode.preDelay, postDelay: mode.postDelay, elementType: node.type, tapStyle: mode.tapStyle)
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
            let selector = try snapshot.uniqueSelector(for: node)
            plannedAX = SelectedAXRequest(kind: .hold, expectedPID: pid, preparation: .automationSession,
                endpoint: nil, selectorKind: selector.kind, selectorValue: selector.value,
                preDelay: 0, postDelay: 0, elementType: node.type, holdDuration: mode.duration)
        case .doubleTap:
            guard let node, let timing = mode.doubleTapTiming else {
                throw AgentModeFailure("missingDoubleTapTarget", "The fresh double-tap target or timing is unavailable.")
            }
            let selector = try snapshot.uniqueSelector(for: node)
            plannedAX = SelectedAXRequest(kind: .doubleTap, expectedPID: pid, preparation: .automationSession,
                endpoint: nil, selectorKind: selector.kind, selectorValue: selector.value,
                preDelay: mode.preDelay, postDelay: mode.postDelay,
                elementType: node.type, doubleTapTiming: timing)
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
                expectedPID: pid, preparation: .automationSession,
                endpoint: endpoint, selectorKind: selector.kind, selectorValue: selector.value,
                preDelay: 0, postDelay: 0, elementType: node.type, percentage: endpoint == nil ? percentage : nil)
        case .sliderEndpoint:
            guard let node, node.type == "Slider", let endpoint = mode.sliderEndpoint else {
                throw AgentModeFailure("missingSliderTarget", "The fresh slider target or endpoint is unavailable.")
            }
            let selector = try snapshot.uniqueSelector(for: node)
            plannedAX = SelectedAXRequest(kind: .sliderEndpoint, expectedPID: pid, preparation: .automationSession,
                endpoint: endpoint, selectorKind: selector.kind, selectorValue: selector.value,
                preDelay: 0, postDelay: 0, elementType: node.type)
        case .keyPress, .keyCombo, .keySequence:
            guard let node, let identifier = node.identifier, let events = mode.keyEvents else {
                throw AgentModeFailure("unsupportedKeyTarget", "Keyboard input requires an exact native focused field ID.")
            }
            try SelectedKeyboardFocusPolicy.validate(node, expectedPID: pid, focusID: identifier)
            plannedKeyboard = SelectedKeyboardRequest(expectedPID: pid, focusID: identifier, events: events)
        case .typeText:
            guard let node, let identifier = node.identifier, let text = mode.text else {
                throw AgentModeFailure("unsupportedTextTarget", "Typing requires an exact native focused field ID.")
            }
            try SelectedKeyboardFocusPolicy.validate(node, expectedPID: pid, focusID: identifier)
            plannedKeyboard = SelectedKeyboardRequest(expectedPID: pid, focusID: identifier,
                events: try SelectedKeyboardRequest.primitives(from: SelectedKeyboardRequest.textEvent(text)))
        case .swipe:
            guard let node, let ref = mode.ref, let cached, let direction = mode.direction,
                  let original = cached.snapshot.elements.first(where: { $0.ref == ref }),
                  let frame = node.frame else { throw AgentModeFailure("missingSwipeTarget", "The swipe target is unavailable.") }
            let freshArea = RuntimeSnapshotElement(ref: ref, role: original.role,
                frame: AgentFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), actions: [.swipeWithin])
            guard let points = freshArea.swipePoints(direction: direction, distance: mode.distance) else {
                throw AgentModeFailure("invalidSwipeGeometry", "The fresh native swipe area is too small.")
            }
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
                         nextSteps: [String] = []) -> SelectedHIDResponse {
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: owner.brokerID, outcome: native.outcome, token: nil,
            enqueuedEventCount: native.enqueuedEventCount, cleanup: native.cleanup, error: nil, context: native.context)
        response.quarantine = native.quarantine
        response.agent = AgentModeResult(capture: capture, action: action, cache: cache,
            context: native.context, quarantine: native.quarantine, observation: observation, nextSteps: nextSteps)
        return response
    }

    private func failure(_ request: SelectedHIDRequest, _ error: AgentModeFailure,
                         native: SelectedHIDResponse? = nil, action: AgentModeActionReceipt? = nil,
                         cache: AgentModeCacheState? = nil, nextSteps: [String]? = nil) -> SelectedHIDResponse {
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: owner.brokerID, outcome: native?.outcome ?? "rejectedBeforeInput", token: nil,
            enqueuedEventCount: native?.enqueuedEventCount ?? 0, cleanup: native?.cleanup ?? "notNeeded",
            error: error.message, context: native?.context)
        response.quarantine = native?.quarantine
        let observation = AgentModeObservationEvidence(native)
        let recoverySteps: [String]
        if native?.quarantine != nil {
            recoverySteps = ["Inspect the quarantine receipt and complete explicit input recovery before retrying. Input was not replayed."]
        } else if let instruction = observation?.captureInstruction(udid: simulatorUDID) {
            recoverySteps = [instruction]
        } else {
            recoverySteps = ["Run describe-ui --agent with the current expected PID. Input was not replayed."]
        }
        response.agent = AgentModeResult(error: error, action: action,
            batch: request.agentBatch.map { AgentBatchReceipt(totalSteps: $0.steps.count,
                completedSteps: 0, steps: [], stoppedAt: 1) },
            cache: cache ?? AgentModeCacheState(status: "invalidated", reason: error.code, requiresRefresh: true),
            context: native?.context, quarantine: native?.quarantine, observation: observation,
            nextSteps: nextSteps ?? recoverySteps)
        return response
    }
}
