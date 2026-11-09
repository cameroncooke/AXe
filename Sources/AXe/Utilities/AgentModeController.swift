import AXeCore
import Foundation
import FBControlCore
import FBSimulatorControl

/// The broker owns one table. Its reservation spans every read, action and replacement.
@MainActor
final class AgentModeController {
    static let timeToLive = 60.0
    /// A refusal before input caused by a changing screen re-reads and retries while the target is
    /// the same control. An unchanged target binds on that one read; a moved one binds once two
    /// reads about 150 ms apart agree. Five retries cover a transition of a few seconds; beyond
    /// that, or for a refusal that would repeat on the same screen, the current screen is returned.
    static let maximumRetries = 5
    private struct Record {
        let id: UUID
        let sequence: Int
        let capturedAt: Double
        let expectedPID: Int32
        let context: SelectedHIDContext
        let snapshot: AgentModeSnapshot
    }
    /// Measures the active panel. The request's explicit display is checked by the caller.
    typealias DisplayDiscovery = @MainActor (SelectedHIDRequest) async throws -> ActivePanelIdentity
    private let simulatorUDID: String
    private let logger: AxeLogger
    private let owner: SelectedHIDOwner
    private let discoverDisplay: DisplayDiscovery
    private var record: Record?
    private var sequence = 0
    private(set) var isBusy = false

    init(simulatorUDID: String, logger: AxeLogger, owner: SelectedHIDOwner,
         discoverDisplay: DisplayDiscovery? = nil) {
        self.simulatorUDID = simulatorUDID; self.logger = logger; self.owner = owner
        self.discoverDisplay = discoverDisplay ?? Self.liveDiscovery(simulatorUDID: simulatorUDID, logger: logger)
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
                ? ["Inspect the quarantine receipt. " + HIDInputQuarantine.recoveryStep]
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

    /// `preread` supplies the typing phase of focus-and-type with the focus tap's own replacement
    /// read instead of a new one; the keyboard guard still reads the field before every key.
    private func performReserved(_ request: SelectedHIDRequest,
                                 focusPlan: AgentFocusAndTypePlan? = nil, retryDepth: Int = 0,
                                 preread: Record? = nil) async -> SelectedHIDResponse {
        if request.agent?.kind == .focusAndType {
            return await performFocusAndTypeRetrying(request, retryDepth: retryDepth)
        }
        var action: AgentModeActionReceipt?
        var refusalContext: SelectedHIDContext?
        var refusalPID: Int32?
        var refusalOriginal: AgentModeSnapshot?
        do {
            try request.validate()
            guard let mode = request.agent else {
                throw AgentModeFailure("missingRequest", "The agent request is missing.")
            }
            let referenceRecord: Record?
            if mode.snapshotID != nil || mode.ref != nil {
                referenceRecord = try requireRecordIdentity(mode)
            } else { referenceRecord = nil }
            refusalOriginal = referenceRecord?.snapshot
            let expectedPID = try AgentModePIDPolicy.expectedPID(
                assertion: mode.expectedPID, snapshot: referenceRecord?.expectedPID)
            // A refusal before the owned paths below read anything still reads the table's display.
            refusalContext = referenceRecord?.context
            refusalPID = expectedPID
            // A published reference tap is admitted on the operation's own owned tree. The table
            // supplies the target, display and context; the owned full context read and tree
            // replace the separate pre-description and its two-tree equality.
            if mode.kind == .tap, mode.ref != nil, focusPlan == nil, let referenceRecord, let pid = expectedPID {
                try requireRequestedDisplay(request, matches: referenceRecord.context)
                let admission = try AgentReferenceTapAdmission(published: referenceRecord.snapshot,
                    context: referenceRecord.context, pid: pid, mode: mode)
                let native = try admission.request(requestID: request.requestID)
                // Invalidate before input, including partial or uncertain native delivery.
                record = nil
                let result = await PhaseTimer.measure("agent.input") { await owner.perform(native, batchTap: admission) }
                let actionReceipt = receipt(mode.kind, result, retried: retryDepth > 0)
                action = actionReceipt
                guard result.error == nil, result.cleanup != "uncertain" else {
                    return await refusal(request, result.agent?.error
                        ?? AgentModePublicErrorProjection.nativeFailure(result),
                        native: result, action: actionReceipt,
                        context: referenceRecord.context, pid: pid,
                        original: referenceRecord.snapshot, retryDepth: retryDepth)
                }
                return await publishReplacement(request, mode: mode, result: result, action: actionReceipt,
                    context: referenceRecord.context, pid: pid)
            }
            // These native operations read the complete owned tree and require the admission's
            // fingerprint, target and context on it before the first event, so the table can
            // supply the plan. Typing reads only its focused field and keeps its pre-description.
            if let referenceRecord, focusPlan == nil, let pid = expectedPID, Self.admitsOnOwnedTree(mode.kind) {
                try requireRequestedDisplay(request, matches: referenceRecord.context)
                let native = try nativeRequest(request, mode: mode, pid: pid, context: referenceRecord.context,
                    snapshot: referenceRecord.snapshot, cached: referenceRecord)
                // Invalidate before input, including partial or uncertain native delivery.
                record = nil
                let result = await PhaseTimer.measure("agent.input") { await owner.perform(native) }
                let actionReceipt = receipt(mode.kind, result, retried: retryDepth > 0)
                action = actionReceipt
                guard result.error == nil, result.cleanup != "uncertain" else {
                    return await refusal(request, result.agent?.error
                        ?? AgentModePublicErrorProjection.nativeFailure(result),
                        native: result, action: actionReceipt,
                        context: referenceRecord.context, pid: pid,
                        original: referenceRecord.snapshot, retryDepth: retryDepth)
                }
                return await publishReplacement(request, mode: mode, result: result, action: actionReceipt,
                    context: referenceRecord.context, pid: pid)
            }
            // Coordinate input names no target. The native operation's own complete read before
            // the first event must have the table's fingerprint and context, as the separate
            // pre-description had to, so that description is not repeated here.
            if let referenceRecord, focusPlan == nil, let pid = expectedPID, Self.admitsCoordinatesOnOwnedTree(mode) {
                try requireRequestedDisplay(request, matches: referenceRecord.context)
                let native = try nativeRequest(request, mode: mode, pid: pid, context: referenceRecord.context,
                    snapshot: referenceRecord.snapshot, cached: referenceRecord)
                record = nil
                let result = await PhaseTimer.measure("agent.input") { await owner.perform(native) }
                let actionReceipt = receipt(mode.kind, result, retried: retryDepth > 0)
                action = actionReceipt
                guard result.error == nil, result.cleanup != "uncertain" else {
                    return await refusal(request, result.agent?.error
                        ?? AgentModePublicErrorProjection.nativeFailure(result),
                        native: result, action: actionReceipt,
                        context: referenceRecord.context, pid: pid,
                        original: referenceRecord.snapshot, retryDepth: retryDepth)
                }
                return await publishReplacement(request, mode: mode, result: result, action: actionReceipt,
                    context: referenceRecord.context, pid: pid)
            }
            // A table names its display; the full context read admits that panel again.
            // Without a table the active panel must be measured first.
            let context: SelectedHIDContext
            let pid: Int32
            let snapshot: AgentModeSnapshot
            var fresh: SelectedHIDResponse?
            if let preread, focusPlan != nil, mode.kind == .typeText {
                context = preread.context
                pid = preread.expectedPID
                snapshot = preread.snapshot
            } else {
                let display: ActivePanelIdentity
                if let referenceRecord {
                    try requireRequestedDisplay(request, matches: referenceRecord.context)
                    display = try Self.display(of: referenceRecord.context)
                } else {
                    display = try await discover(request)
                }
                let observed = try await observe(display: display, pid: expectedPID)
                guard let observedContext = observed.context, let roots = observed.ax?.roots,
                      let observedPID = observed.ax?.expectedPID else {
                    throw AgentModeFailure("missingObservation", "The native observation has no selected context or hierarchy.")
                }
                context = observedContext
                pid = observedPID
                snapshot = try PhaseTimer.measureSync("agent.snapshotBuild") {
                    try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: observed.ax?.nativeIdentityMetadata, context: observedContext)
                }
                fresh = observed
            }
            refusalContext = context
            refusalPID = pid
            if let focusPlan {
                if mode.kind == .tap {
                    try focusPlan.validateBeforeTap(snapshot: snapshot, context: context, pid: pid)
                } else {
                    _ = try focusPlan.focusedReference(snapshot: snapshot, context: context, pid: pid)
                }
            }
            if mode.kind == .read {
                guard let reference = mode.readReference, let query = mode.textQuery else {
                    throw AgentModeFailure("invalidReadReference", "The reference read has no field query.")
                }
                guard let fresh else { throw AgentModeFailure("missingObservation", "The reference read has no native observation.") }
                do {
                    let stored = try requireRecord(mode, context: context, fresh: snapshot)
                    return success(request, native: fresh,
                        cache: AgentModeCacheState(status: "validated", reason: nil, requiresRefresh: false),
                        detail: try stored.snapshot.detail(ref: reference, query: query))
                } catch let changed as AgentModeFailure where ["screenChanged", "targetChanged"].contains(changed.code) {
                    // Something else on the screen changed. When the control read is itself unchanged,
                    // read it from this table, as the agent would after capturing again. The snapshot
                    // stays stale for input, which the cache state reports.
                    guard let original = try? requireRecordIdentity(mode).snapshot,
                          let current = Self.unchangedReference(reference, from: original, to: snapshot) else { throw changed }
                    let read = try snapshot.detail(ref: current, query: query)
                    return success(request, native: fresh,
                        cache: AgentModeCacheState(status: "invalidated", reason: changed.code, requiresRefresh: true),
                        detail: AgentModeTextDetail(ref: reference, field: read.field, offset: read.offset,
                            nextOffset: read.nextOffset, totalLength: read.totalLength, text: read.text,
                            frame: read.frame, actions: read.actions))
                }
            }
            if mode.kind == .describe {
                let stored: Record
                let unchanged: Bool
                let cacheStatus: String
                if mode.snapshotID != nil {
                    do {
                        stored = try requireRecord(mode, context: context, fresh: snapshot)
                        cacheStatus = "validated"
                    } catch let changed as AgentModeFailure where ["screenChanged", "targetChanged"].contains(changed.code) {
                        // The agent would read the screen again; this read is that read. It is a new
                        // table, so it is a refusal of the requested page: its refs must not be
                        // merged with pages of the old snapshot. It restarts at its first row.
                        let replacement = store(snapshot, context: context, pid: pid)
                        var first = mode
                        first.rowOffset = 0
                        let capture = replacement.snapshot.capture(id: replacement.id, sequence: replacement.sequence,
                            udid: simulatorUDID, request: first, applicationPID: replacement.expectedPID,
                            context: replacement.context, unchanged: false, expiresIn: Self.timeToLive)
                        return failure(request, changed,
                            cache: AgentModeCacheState(status: "refreshed", reason: changed.code, requiresRefresh: false),
                            nextSteps: ["The capture is a new snapshot of the current screen. Discard rows from the old snapshot and page this one from its first row."],
                            capture: capture)
                    }
                    unchanged = false
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
                guard let fresh else { throw AgentModeFailure("missingObservation", "The description has no native observation.") }
                return success(request, native: fresh, capture: capture,
                    cache: AgentModeCacheState(status: cacheStatus, reason: nil, requiresRefresh: false))
            }

            let cached: Record?
            var admittedMode = mode
            if let focusPlan, mode.kind == .typeText {
                // The typing phase of focus-and-type. Keys route by native focus, not by position,
                // and this table is AXe's own read after the focus tap, which the agent never chose
                // from. Admit on the focus plan's field checks against this fresh read; the focus
                // guard still reads the focused field before every key down.
                _ = try requireRecordIdentity(mode)
                admittedMode.ref = try focusPlan.focusedReference(snapshot: snapshot, context: context, pid: pid)
                cached = Record(id: UUID(), sequence: sequence, capturedAt: now, expectedPID: pid,
                    context: context, snapshot: snapshot)
            } else if mode.snapshotID != nil || mode.ref != nil {
                cached = try requireRecord(mode, context: context, fresh: snapshot)
            } else { cached = nil }
            let native = try nativeRequest(request, mode: admittedMode, pid: pid,
                context: context, snapshot: snapshot, cached: cached)
            // Invalidate before input, including partial or uncertain native delivery.
            record = nil
            let result = await PhaseTimer.measure("agent.input") { await owner.perform(native) }
            let actionReceipt = receipt(mode.kind, result, retried: retryDepth > 0)
            action = actionReceipt
            guard result.error == nil, result.cleanup != "uncertain" else {
                return await refusal(request, result.agent?.error
                    ?? AgentModePublicErrorProjection.nativeFailure(result),
                    native: result, action: actionReceipt, context: context, pid: pid,
                    original: referenceRecord?.snapshot, retryDepth: retryDepth,
                    // Focus-and-type owns the single retry loop for both of its phases.
                    allowsRetry: focusPlan == nil)
            }
            return await publishReplacement(request, mode: mode, result: result, action: actionReceipt,
                context: context, pid: pid)
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
            if nativeFailure == nil, focusPlan == nil, request.agent?.kind != .describe {
                return await refusal(request, reason, native: nil, action: action,
                    context: refusalContext, pid: refusalPID, original: refusalOriginal, retryDepth: retryDepth)
            }
            return failure(request, reason, native: nativeFailure?.response, action: action)
        }
    }

    /// A refusal before any input returns the current screen as a new table, so recovery needs
    /// no separate description. Nothing is replayed.
    private func refusal(_ request: SelectedHIDRequest, _ error: AgentModeFailure,
                         native: SelectedHIDResponse?, action: AgentModeActionReceipt?,
                         context: SelectedHIDContext?, pid: Int32?,
                         original: AgentModeSnapshot? = nil, retryDepth: Int = 0,
                         allowsRetry: Bool = true) async -> SelectedHIDResponse {
        guard Self.refusalRefreshes(error, native: native), let mode = request.agent,
              var stored = await refreshTable(context: context, pid: pid) else {
            return failure(request, error, native: native, action: action)
        }
        // A tap the native hit check refused because the keyboard covers its target fails again on
        // every attempt: the keyboard does not move by itself. Say so at once, with the fix and the
        // fresh screen, instead of retrying. The hit check stays the authority; the keyboard frame
        // only explains its refusal.
        if error.code == "targetCovered", native?.outcome == "failedBeforeInput", mode.kind == .tap,
           let original, let ref = mode.ref,
           let fresh = Self.unchangedReference(ref, from: original, to: stored.snapshot),
           let cover = AgentKeyboardCover.find(ref: fresh, in: stored.snapshot, pid: stored.expectedPID,
                                               context: stored.context) {
            let capture = stored.snapshot.capture(id: stored.id, sequence: stored.sequence, udid: simulatorUDID,
                request: mode, applicationPID: stored.expectedPID, context: stored.context,
                unchanged: false, expiresIn: Self.timeToLive)
            return failure(request, cover.failure, native: native, action: action,
                cache: AgentModeCacheState(status: "refreshed", reason: "keyboardCovered", requiresRefresh: false),
                nextSteps: ["Input was not sent. The capture is the current screen; choose the next action from its snapshot ID."],
                capture: capture)
        }
        // The agent's own recovery, inside the call. A refusal caused by a changing screen, or any
        // refusal after which the screen has moved on, is retried when the refused action's target
        // is still the same control. A refusal on an unchanged screen (a covered target, another
        // input running) would only repeat, so it returns the new table to the agent at once.
        let screenMovedOn = original.map { stored.snapshot.visibleFingerprint != $0.visibleFingerprint } ?? false
        if allowsRetry, Self.retriesOnNewTable(mode.kind), retryDepth < Self.maximumRetries,
           !Self.targetRefusals.contains(error.code),
           Self.screenChangeRefusals.contains(error.code) || screenMovedOn {
            if let original, let ref = mode.ref,
               let newRef = await reboundReference(ref, original: original, stored: &stored) {
                var retry = request
                retry.agent?.snapshotID = stored.id
                retry.agent?.ref = newRef
                return await performReserved(retry, retryDepth: retryDepth + 1)
            }
            // A selector action (an ID, label or value) names no snapshot position: it resolves its
            // target on the fresh read every time, so the same request runs again.
            if mode.ref == nil, mode.snapshotID == nil, mode.selectorKind != nil || mode.tapSelector != nil {
                return await performReserved(request, retryDepth: retryDepth + 1)
            }
        }
        let capture = stored.snapshot.capture(id: stored.id, sequence: stored.sequence, udid: simulatorUDID,
            request: mode, applicationPID: stored.expectedPID, context: stored.context,
            unchanged: false, expiresIn: Self.timeToLive)
        return failure(request, error, native: native, action: action,
            cache: AgentModeCacheState(status: "refreshed", reason: error.code, requiresRefresh: false),
            nextSteps: ["Input was not sent. The capture is the current screen; choose the next action from its snapshot ID."],
            capture: capture)
    }

    /// A refusal that proves no input was sent: a host refusal of a changed screen or an
    /// unusable target, or any native operation, whatever its code, that failed before input
    /// with clean release and no quarantine.
    private static func refusalRefreshes(_ error: AgentModeFailure, native: SelectedHIDResponse?) -> Bool {
        guard (native?.enqueuedEventCount ?? 0) == 0, native?.quarantine == nil,
              native?.cleanup != "uncertain" else { return false }
        return screenChangeRefusals.contains(error.code) || targetRefusals.contains(error.code)
            || native?.outcome == "failedBeforeInput"
    }

    /// Refusals that a changing screen causes. Retried while the target is the same control.
    private static let screenChangeRefusals: Set<String> = [
        "screenChanged", "targetChanged", "batchLayoutChanged", "nativeIdentityIncomplete",
    ]

    /// A ref or selector that names no current control offering the action. The agent chose it,
    /// often from a capture taken while the screen was still changing, so the same request is not
    /// retried; the refusal returns the current screen so the next choice needs no separate read.
    private static let targetRefusals: Set<String> = ["unsupportedReference", "targetMissing"]

    private static func retriesOnNewTable(_ kind: AgentModeRequest.Kind) -> Bool {
        switch kind {
        case .tap, .typeText, .keyPress, .keyCombo, .keySequence, .swipe, .hold, .doubleTap: return true
        default: return false
        }
    }

    /// The same target on a new table: the same control as `sameControl` defines (including the
    /// native object whenever both reads report one) at the same frame.
    private static func unchangedReference(_ ref: String, from original: AgentModeSnapshot,
                                           to fresh: AgentModeSnapshot) -> String? {
        guard let chosen = try? original.target(ref: ref), let old = try? original.match(target: chosen),
              let new = try? fresh.match(target: chosen), sameControl(old, new),
              (try? AgentModeTarget(old).validate(new)) != nil else { return nil }
        return try? fresh.reference(target: chosen)
    }

    /// The refused target on the new table. An unchanged target binds at once. The same control
    /// at a new position binds once its frame holds still across two reads about 150 ms apart,
    /// within four reads. A changed value is a changed state, not a moved control. Anything else
    /// does not bind.
    private func reboundReference(_ ref: String, original: AgentModeSnapshot, stored: inout Record) async -> String? {
        if let same = Self.unchangedReference(ref, from: original, to: stored.snapshot) { return same }
        guard let chosen = try? original.target(ref: ref), let old = try? original.match(target: chosen) else { return nil }
        var previousFrame: CGRect?
        for _ in 0..<4 {
            guard let new = try? stored.snapshot.match(target: chosen), Self.sameControl(old, new),
                  let frame = new.frame else { return nil }
            if previousFrame == frame { return try? stored.snapshot.reference(target: chosen) }
            previousFrame = frame
            guard (try? await PhaseTimer.measure("agent.reboundPause") { try await Task.sleep(for: .milliseconds(150)) }) != nil,
                  let next = await refreshTable(context: stored.context, pid: stored.expectedPID) else { return nil }
            stored = next
        }
        return nil
    }

    /// Same type, identifier, label, value and process, the same native object whenever both reads
    /// report one, and still enabled and shown.
    private static func sameControl(_ old: FBSimulatorAXNode, _ new: FBSimulatorAXNode) -> Bool {
        old.type == new.type && old.identifier == new.identifier && old.label == new.label && old.pid == new.pid
            && old.value == new.value
            && (old.nativeIdentity == nil || new.nativeIdentity == nil || old.nativeIdentity == new.nativeIdentity)
            && new.enabled != false && new.hidden != true
    }

    /// One read of the table's display, stored as the new table.
    private func refreshTable(context: SelectedHIDContext?, pid: Int32?) async -> Record? {
        guard let context, !Task.isCancelled, let display = try? Self.display(of: context),
              let fresh = try? await observe(display: display, pid: pid),
              let freshContext = fresh.context, let roots = fresh.ax?.roots, let freshPID = fresh.ax?.expectedPID,
              let snapshot = try? AgentModeSnapshot(roots: roots,
                  nativeIdentityMetadata: fresh.ax?.nativeIdentityMetadata, context: freshContext) else { return nil }
        return store(snapshot, context: freshContext, pid: freshPID)
    }

    /// Path guards and the AX size guard compare the complete owned tree with the admission
    /// fingerprint and target before input. Keyboard and slider guards read only their field.
    static func admitsOnOwnedTree(_ kind: AgentModeRequest.Kind) -> Bool {
        switch kind {
        case .swipe, .drag, .pinch, .hold, .doubleTap, .complete: return true
        case .describe, .read, .tap, .typeText, .focusAndType, .keyPress, .keyCombo, .keySequence,
             .sliderEndpoint, .sliderPercentage: return false
        }
    }

    /// Snapshot-bound coordinate taps and complete coordinate paths. Their admission guard reads
    /// the complete owned tree and requires the table's fingerprint before the first event.
    static func admitsCoordinatesOnOwnedTree(_ mode: AgentModeRequest) -> Bool {
        guard mode.snapshotID != nil, mode.ref == nil, mode.selectorKind == nil, mode.tapSelector == nil else { return false }
        switch mode.kind {
        case .tap: return mode.point != nil
        case .complete: return true
        default: return false
        }
    }

    private func receipt(_ kind: AgentModeRequest.Kind, _ result: SelectedHIDResponse,
                         retried: Bool) -> AgentModeActionReceipt {
        AgentModeActionReceipt(kind: kind, outcome: result.outcome,
            enqueuedEventCount: result.enqueuedEventCount, cleanup: result.cleanup, replayed: false,
            quarantine: result.quarantine, slider: result.ax?.slider, sliderValue: result.ax?.sliderValue,
            retried: retried ? true : nil)
    }

    /// A fresh replacement is useful, but its failure must not suggest replaying the action.
    private func publishReplacement(_ request: SelectedHIDRequest, mode: AgentModeRequest,
                                    result: SelectedHIDResponse, action: AgentModeActionReceipt,
                                    context: SelectedHIDContext, pid: Int32) async -> SelectedHIDResponse {
        do {
            let afterContext: SelectedHIDContext
            let afterSnapshot: AgentModeSnapshot
            do {
                let refreshed = try await PhaseTimer.measure("agent.refresh") {
                    () async throws -> (SelectedHIDContext, AgentModeSnapshot) in
                    func read() async throws -> (SelectedHIDContext, AgentModeSnapshot) {
                        let after = try await observeReplacement(request, context: context, pid: pid)
                        guard let observedContext = after.context, let afterRoots = after.ax?.roots else {
                            throw AgentModeFailure("refreshFailed", "The action completed, but its replacement snapshot is unavailable.")
                        }
                        let snapshot = try PhaseTimer.measureSync("agent.snapshotBuild") {
                            try AgentModeSnapshot(roots: afterRoots,
                                nativeIdentityMetadata: after.ax?.nativeIdentityMetadata, context: observedContext)
                        }
                        return (observedContext, snapshot)
                    }
                    // One read, published at once, after every action including a swipe. A screen
                    // still in transition, or content still decelerating, is caught by the next
                    // action's admission, which re-reads and retries inside its own call.
                    let first = try await read()
                    return (first.0, first.1)
                }
                afterContext = refreshed.0
                afterSnapshot = refreshed.1
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
    }

    /// The admitted panel is read first; its full context read admits it again. Only a
    /// replaced active panel justifies a second discovery and read. The same panel repeats
    /// the first failure, and a quarantine is never followed by another read.
    private func observeReplacement(_ request: SelectedHIDRequest, context: SelectedHIDContext,
                                    pid: Int32) async throws -> SelectedHIDResponse {
        let known = try Self.display(of: context)
        do { return try await observe(display: known, pid: pid) }
        catch {
            if let native = error as? AgentModeNativeFailure, native.response.quarantine != nil { throw error }
            try Task.checkCancellation()
            let panel = try await discover(request)
            guard panel != known else { throw error }
            return try await observe(display: panel, pid: pid)
        }
    }

    private static func display(of context: SelectedHIDContext) throws -> ActivePanelIdentity {
        guard let uuid = UUID(uuidString: context.screenUUID) else {
            throw AgentModeFailure("missingContext", "AXe could not read the simulator display, so nothing was sent. Run describe-ui --agent again; if it keeps failing, check that the simulator is booted and on screen.")
        }
        return ActivePanelIdentity(displayID: context.screenID, uniqueID: uuid)
    }

    /// An explicit display option must name the table's display. No display is measured here;
    /// the table's panel is admitted by the full context read that follows.
    private func requireRequestedDisplay(_ request: SelectedHIDRequest, matches context: SelectedHIDContext) throws {
        guard let requestedID = request.screenID, let requestedUUID = request.screenUUID else { return }
        guard requestedID == context.screenID, requestedUUID == UUID(uuidString: context.screenUUID) else {
            throw AgentModeFailure("inactiveDisplay", "The display you selected is not this snapshot's display, so nothing was sent. Use the display of the capture, or capture again on the display you want.")
        }
    }

    /// A focus-and-type refused before any input returns the current screen. A refusal caused by
    /// a changing screen is repeated on that new table when its field is unchanged, as the agent
    /// would do after reading the screen again. This is the only retry loop for both phases.
    private func performFocusAndTypeRetrying(_ request: SelectedHIDRequest, retryDepth: Int = 0) async -> SelectedHIDResponse {
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

    /// One broker reservation; native input ownership remains per complete action.
    func performBatch(_ request: SelectedHIDRequest) async -> SelectedHIDResponse {
        guard !isBusy, !owner.isBusy else { return reject(request) }
        isBusy = true
        defer { isBusy = false }
        return await performBatchRetrying(request)
    }

    /// A reference batch stopped before any input repeats on a new table when every
    /// step's target is unchanged.
    private func performBatchRetrying(_ request: SelectedHIDRequest, retryDepth: Int = 0) async -> SelectedHIDResponse {
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
                        let ref = try current.snapshot.reference(id: id, action: .tap)
                        action.agent = AgentModeRequest(kind: .focusAndType, expectedPID: batchPID,
                            snapshotID: current.id, ref: ref, text: step.text)
                        return Self.focusStep(await performFocusAndTypeRetrying(action, retryDepth: retryDepth),
                            retried: retryDepth > 0)
                    }
                    let ref = try current.snapshot.reference(id: id,
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
                    throw AgentModeFailure("missingContext", "AXe could not read the simulator display, so nothing was sent. Run describe-ui --agent again; if it keeps failing, check that the simulator is booted and on screen.")
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
                throw AgentModeFailure("missingContext", "AXe could not read the simulator display, so nothing was sent. Run describe-ui --agent again; if it keeps failing, check that the simulator is booted and on screen.")
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
            throw AgentModeFailure("snapshotMissing", "That snapshot ID is no longer current: a newer capture replaced it, it expired after 60 seconds, or AXe restarted. Nothing was sent. Use the snapshot ID and refs from your latest capture, or run describe-ui.")
        }
        guard now - record.capturedAt < Self.timeToLive else {
            throw AgentModeFailure("snapshotExpired", "This snapshot is more than 60 seconds old, so its refs have expired and nothing was sent. Run describe-ui --agent and act from that capture.")
        }
        _ = try AgentModePIDPolicy.expectedPID(assertion: mode.expectedPID, snapshot: record.expectedPID)
        return record
    }

    private func requireRecord(_ mode: AgentModeRequest, context: SelectedHIDContext,
                               fresh: AgentModeSnapshot) throws -> Record {
        let record = try requireRecordIdentity(mode)
        guard record.context == context else {
            throw AgentModeFailure("contextChanged", "The app or display changed after this snapshot was taken, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        // Admission ignores the text of ordinary labels; a field read also needs that field unchanged.
        guard record.snapshot.visibleFingerprint == fresh.visibleFingerprint,
              mode.readReference.map({ record.snapshot.hasSameFields($0, in: fresh) }) != false else {
            logger.info().log("Agent snapshot fingerprint mismatch: \(AgentModeSnapshotDifference.summary(previous: record.snapshot.nodes, current: fresh.nodes))")
            throw AgentModeFailure("screenChanged", "The screen changed after this snapshot was taken, so nothing was sent. Use the snapshot ID and refs from the capture in this reply, or run describe-ui if there is none, then act again.")
        }
        if let ref = mode.ref ?? mode.readReference {
            try record.snapshot.validateProtectedReference(ref, in: fresh)
        } else if mode.kind == .describe {
            try record.snapshot.validateProtectedTargets(in: fresh)
        }
        return record
    }

    private func discover(_ request: SelectedHIDRequest) async throws -> ActivePanelIdentity {
        try await PhaseTimer.measure("agent.discover") {
            try Task.checkCancellation()
            let panel = try await discoverDisplay(request)
            if let requestedID = request.screenID, let requestedUUID = request.screenUUID {
                guard requestedID == panel.displayID, requestedUUID == panel.uniqueID else {
                    throw AgentModeFailure("inactiveDisplay", "The display you selected is not the one the simulator is showing, so nothing was sent. Capture again without a display option, or select the active display.")
                }
            }
            return panel
        }
    }

    private static func liveDiscovery(simulatorUDID: String, logger: AxeLogger) -> DisplayDiscovery {
        { _ in
            let simulator = try await PhaseTimer.measure("simulatorSet") { () async throws -> FBSimulator in
                try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
                let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
                guard let simulator = set.allSimulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: simulatorUDID) }),
                      simulator.state == .booted else { throw CLIError.simulatorNotFound(udid: simulatorUDID) }
                return simulator
            }
            // Display catalogue, boot identity and the devicectl active-panel read.
            let discovery = try await PhaseTimer.measure("activePanel.discover") {
                try await ActivePanelReader.discoverWithMetadata(for: simulator)
            }
            return discovery.readback.snapshot.activePanel.identity
        }
    }

    private func observe(display: ActivePanelIdentity, pid: Int32?) async throws -> SelectedHIDResponse {
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: display.displayID, screenUUID: display.uniqueID, operation: .complete, token: nil, primitives: [])
        request.ax = SelectedAXRequest(kind: .describe, expectedPID: pid,
            endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0, includeNativeIdentity: true)
        let result = await PhaseTimer.measure("agent.observe") { await owner.perform(request) }
        guard result.error == nil, result.cleanup != "uncertain" else {
            throw AgentModeNativeFailure(response: result)
        }
        guard result.ax?.acquisition?.outcome == .ready, let actualPID = result.ax?.expectedPID,
              result.ax?.acquisition?.attempts.last?.rootPID == actualPID else {
            throw AgentModeFailure("processEvidenceMissing", "AXe could not confirm which app owns the screen, so nothing was sent. The app may still be launching: run describe-ui --agent again.")
        }
        _ = try AgentModePIDPolicy.verifiedPID(actualPID, expected: pid)
        return result
    }

    private func nativeRequest(_ outer: SelectedHIDRequest, mode: AgentModeRequest, pid: Int32, context: SelectedHIDContext,
                               snapshot: AgentModeSnapshot, cached: Record?,
                               binding: AgentBatchReferencePlan.ResolvedTarget? = nil) throws -> SelectedHIDRequest {
        guard pid > 0, let uuid = UUID(uuidString: context.screenUUID) else {
            throw AgentModeFailure("missingContext", "AXe could not read the simulator display, so nothing was sent. Run describe-ui --agent again; if it keeps failing, check that the simulator is booted and on screen.")
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
            nativeFingerprint: snapshot.nativeFingerprint, visibleFingerprint: snapshot.visibleFingerprint,
            target: try node.map { try AgentModeTarget($0, nativeTarget: chosenTarget) }, nativeTarget: chosenTarget)
        if case let .semantic(kind, value, _)? = chosenTarget {
            admission.selectorKind = kind
            admission.selectorValue = value
        }
        switch mode.kind {
        case .describe, .read, .focusAndType: throw AgentModeFailure("invalidAction", "A description or reference read is not an input action.")
        case .tap:
            if let node {
                guard let chosenTarget else { throw AgentModeFailure("unsupportedIdentity", "AXe could not resolve the tap target to one control, so nothing was sent. \(AgentModeFailure.actFromCapture)") }
                plannedAX = SelectedAXRequest(kind: .tap, expectedPID: pid,
                    endpoint: nil, selectorKind: nil, selectorValue: nil,
                    preDelay: mode.preDelay, postDelay: mode.postDelay, elementType: node.type, tapStyle: mode.tapStyle,
                    nativeTarget: chosenTarget)
            } else if let point = mode.point {
                let style = try (mode.tapStyle ?? .physical).resolved(for: nil)
                if mode.preDelay > 0 { plannedPrimitives.append(.delay(mode.preDelay)) }
                plannedPrimitives += try style.primitives(x: point.x, y: point.y)
                if mode.postDelay > 0 { plannedPrimitives.append(.delay(mode.postDelay)) }
            } else { throw AgentModeFailure("missingTarget", "The tap target is no longer on screen, so nothing was sent. \(AgentModeFailure.actFromCapture)") }
        case .hold:
            guard let node else {
                throw AgentModeFailure("missingHoldTarget", "The fresh hold target is unavailable.")
            }
            guard let chosenTarget else { throw AgentModeFailure("unsupportedIdentity", "AXe could not resolve the press target to one control, so nothing was sent. \(AgentModeFailure.actFromCapture)") }
            plannedAX = SelectedAXRequest(kind: .hold, expectedPID: pid,
                endpoint: nil, selectorKind: nil, selectorValue: nil,
                preDelay: 0, postDelay: 0, elementType: node.type, holdDuration: mode.duration, nativeTarget: chosenTarget)
        case .doubleTap:
            guard let node, let timing = mode.doubleTapTiming else {
                throw AgentModeFailure("missingDoubleTapTarget", "The fresh double-tap target or timing is unavailable.")
            }
            guard let chosenTarget else { throw AgentModeFailure("unsupportedIdentity", "AXe could not resolve the double-tap target to one control, so nothing was sent. \(AgentModeFailure.actFromCapture)") }
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
                preDelay: mode.preDelay, postDelay: mode.postDelay, endsAtRest: true)
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
                         cache: AgentModeCacheState? = nil, nextSteps: [String]? = nil,
                         capture: AgentModeCapture? = nil) -> SelectedHIDResponse {
        let publicError = AgentModePublicErrorProjection.project(error, native: native)
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: owner.brokerID, outcome: native?.outcome ?? "rejectedBeforeInput", token: nil,
            enqueuedEventCount: native?.enqueuedEventCount ?? 0, cleanup: native?.cleanup ?? "notNeeded",
            error: publicError.message, context: native?.context)
        response.quarantine = native?.quarantine
        let observation = AgentModeObservationEvidence(native)
        let recoverySteps: [String]
        if native?.quarantine != nil {
            recoverySteps = ["Inspect the quarantine receipt. " + HIDInputQuarantine.recoveryStep + " Input was not replayed."]
        } else if let instruction = observation?.captureInstruction(udid: simulatorUDID) {
            recoverySteps = [instruction]
        } else {
            recoverySteps = ["Run describe-ui --agent for a fresh snapshot of the frontmost application. Input was not replayed."]
        }
        response.agent = AgentModeResult(error: publicError, capture: capture, action: action,
            batch: request.agentBatch.map { AgentBatchReceipt(totalSteps: $0.steps.count,
                completedSteps: 0, steps: [], stoppedAt: 1) },
            cache: cache ?? AgentModeCacheState(status: "invalidated", reason: publicError.code, requiresRefresh: true),
            context: native?.context, quarantine: native?.quarantine, observation: observation,
            nextSteps: nextSteps ?? recoverySteps)
        return response
    }
}
