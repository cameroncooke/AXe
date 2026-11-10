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
    struct Record {
        let id: UUID
        let sequence: Int
        let capturedAt: Double
        let expectedPID: Int32
        let context: SelectedHIDContext
        let snapshot: AgentModeSnapshot
    }
    /// Measures the active panel. The request's explicit display is checked by the caller.
    typealias DisplayDiscovery = @MainActor (SelectedHIDRequest) async throws -> ActivePanelIdentity
    let simulatorUDID: String
    private let logger: AxeLogger
    let owner: SelectedHIDOwner
    private let discoverDisplay: DisplayDiscovery
    var record: Record?
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

    /// One broker reservation; native input ownership remains per complete action.
    func performBatch(_ request: SelectedHIDRequest) async -> SelectedHIDResponse {
        guard !isBusy, !owner.isBusy else { return reject(request) }
        isBusy = true
        defer { isBusy = false }
        return await performBatchRetrying(request)
    }

    /// The optional page is part of this reply and uses exactly the record already
    /// captured or validated by the command. No second observation authorizes it.
    func withReadingContinuation(_ response: SelectedHIDResponse,
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
    func performReserved(_ request: SelectedHIDRequest,
                                 focusPlan: AgentFocusAndTypePlan? = nil, retryDepth: Int = 0,
                                 preread: Record? = nil) async -> SelectedHIDResponse {
        if request.agent?.kind == .focusAndType {
            return await performFocusAndTypeRetrying(request, retryDepth: retryDepth)
        }
        var action: AgentModeActionReceipt?
        var refusalContext: SelectedHIDContext?
        var refusalPID: Int32?
        var refusalOriginal: AgentModeSnapshot?
        var observedScreen = false
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
            // These native operations read the complete owned tree and require the table's fingerprint,
            // target and context on it before the first event, so the table supplies the plan and no
            // separate pre-description is read: a published reference tap (admitted on the tap's own
            // owned tree), path and AX-size guarded actions, and snapshot-bound coordinate input.
            // Typing reads only its focused field and keeps its pre-description.
            let referenceTap = mode.kind == .tap && mode.ref != nil
            if let referenceRecord, focusPlan == nil, let pid = expectedPID,
               referenceTap || Self.admitsOnOwnedTree(mode.kind) || Self.admitsCoordinatesOnOwnedTree(mode) {
                try requireRequestedDisplay(request, matches: referenceRecord.context)
                let tapAdmission = referenceTap ? try AgentReferenceTapAdmission(published: referenceRecord.snapshot,
                    context: referenceRecord.context, pid: pid, mode: mode) : nil
                let native: SelectedHIDRequest
                if let tapAdmission {
                    native = try tapAdmission.request(requestID: request.requestID)
                } else {
                    native = try nativeRequest(request, mode: mode, pid: pid, context: referenceRecord.context,
                        snapshot: referenceRecord.snapshot, cached: referenceRecord)
                }
                // Invalidate before input, including partial or uncertain native delivery.
                record = nil
                let result = await PhaseTimer.measure("agent.input") { await owner.perform(native, batchTap: tapAdmission) }
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
                observedScreen = true
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
                // From here a failure is evidence about the current screen.
                observedScreen = true
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
            let nativeFailure = error as? AgentModeNativeFailure
            // The shared table is cleared only on evidence that it no longer describes the screen:
            // a native failure, a refusal after a fresh read, or its own expiry. A malformed
            // request, a wrong PID assertion or display, or an old snapshot ID leaves another
            // caller's current table in place. Input paths cleared it before their first event.
            if nativeFailure != nil || observedScreen || (error as? AgentModeFailure)?.code == "snapshotExpired" {
                record = nil
            }
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
    static func unchangedReference(_ ref: String, from original: AgentModeSnapshot,
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
    func reboundReference(_ ref: String, original: AgentModeSnapshot, stored: inout Record) async -> String? {
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
    static func sameControl(_ old: FBSimulatorAXNode, _ new: FBSimulatorAXNode) -> Bool {
        old.type == new.type && old.identifier == new.identifier && old.label == new.label && old.pid == new.pid
            && old.value == new.value
            && (old.nativeIdentity == nil || new.nativeIdentity == nil || old.nativeIdentity == new.nativeIdentity)
            && new.enabled != false && new.hidden != true
    }

    /// One read of the table's display, stored as the new table.
    func refreshTable(context: SelectedHIDContext?, pid: Int32?) async -> Record? {
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

    /// Snapshot-bound coordinate taps. Their admission guard reads the complete owned tree and
    /// requires the table's fingerprint before the first event. Complete coordinate paths are
    /// covered by `admitsOnOwnedTree`.
    static func admitsCoordinatesOnOwnedTree(_ mode: AgentModeRequest) -> Bool {
        mode.kind == .tap && mode.point != nil && mode.snapshotID != nil && mode.ref == nil
            && mode.selectorKind == nil && mode.tapSelector == nil
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
            throw AgentModeFailure.missingContext
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

    private var now: Double { owner.currentTime }

    func store(_ snapshot: AgentModeSnapshot, context: SelectedHIDContext, pid: Int32) -> Record {
        sequence += 1
        let value = Record(id: UUID(), sequence: sequence, capturedAt: now,
                           expectedPID: pid, context: context, snapshot: snapshot)
        record = value
        return value
    }

    func requireRecordIdentity(_ mode: AgentModeRequest) throws -> Record {
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
            throw AgentModeFailure.screenChanged
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
                do {
                    return try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
                } catch let failure as CLIOutputFailure {
                    // Keep notBooted or targetNotFound in the agent reply instead of observationFailed.
                    throw AgentModeFailure(failure.code, failure.message)
                }
            }
            // Display catalogue, boot identity and the devicectl active-panel read.
            let discovery = try await PhaseTimer.measure("activePanel.discover") {
                try await ActivePanelReader.discoverWithMetadata(for: simulator)
            }
            return discovery.readback.snapshot.activePanel.identity
        }
    }

    func observe(display: ActivePanelIdentity, pid: Int32?) async throws -> SelectedHIDResponse {
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

    func success(_ request: SelectedHIDRequest, native: SelectedHIDResponse,
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

    func failure(_ request: SelectedHIDRequest, _ error: AgentModeFailure,
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
