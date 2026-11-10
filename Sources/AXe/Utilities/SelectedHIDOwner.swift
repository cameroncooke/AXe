import Foundation
import FBControlCore
import FBSimulatorControl

/// Main-actor ownership keeps simulator objects on the same boundary as the existing CLI.
/// The admission guard remains set across suspension, including context reads and cleanup.
@MainActor
final class SelectedHIDOwner {
    let brokerID = UUID()
    private let simulatorUDID: String
    private let logger: AxeLogger
    private let dependencies: SelectedAXDependencies
    private let transportOwner: FBSimulatorHIDTransportOwner
    private let sliderValueOwner = SelectedSliderValueOwner()
    private var admission = SelectedHIDAdmission()
    private var lease: HIDInputLease?
    private var session: FBSimulatorHIDSession?
    private var feed: FBSimulatorHIDNativeFreshnessProvider?
    private var quarantined = false
    private var maintainingRetainedInput = false
    private var batchRunning = false
    private var quarantineReceipt: SelectedHIDQuarantine?
    private var lastRequest: SelectedHIDRequest?
    private var libraryToken: FBSimulatorHIDContactToken?
    private var observation: FBSimulatorHIDSessionObservation?
    private var lastActivity: TimeInterval
    private(set) var shouldStop = false
    var isBusy: Bool { admission.inFlight || maintainingRetainedInput || batchRunning || shouldStop || quarantined }
    var currentTime: TimeInterval { dependencies.now() }

    init(simulatorUDID: String, logger: AxeLogger, dependencies: SelectedAXDependencies? = nil) {
        self.simulatorUDID = simulatorUDID; self.logger = logger
        let transportOwner = FBSimulatorHIDTransportOwner()
        self.transportOwner = transportOwner
        self.dependencies = dependencies ?? .live(transportOwner: transportOwner)
        lastActivity = self.dependencies.now()
    }

    func perform(_ incoming: SelectedHIDRequest, batchTap: (any AgentOwnedTapAdmission)? = nil) async -> SelectedHIDResponse {
        var request = incoming
        if incoming.activeDisplay == true {
            do {
                guard !shouldStop, !quarantined, !maintainingRetainedInput, !batchRunning else { throw SelectedHIDFailure.busy }
                request = try await bindActiveDisplay(incoming)
            } catch { return response(incoming, outcome: "rejectedBeforeInput", error: error) }
        }
        do {
            guard !shouldStop, !quarantined, !maintainingRetainedInput, !batchRunning else { throw SelectedHIDFailure.busy }
            if batchTap != nil {
                guard request.ax?.kind == .tap, request.agentAdmission == nil else {
                    throw SelectedHIDFailure.invalid("Owned batch admission requires a reference tap")
                }
            }
            try admission.enter(request)
            lastRequest = request
        }
        catch { return response(request, outcome: "rejectedBeforeInput", error: error) }
        defer { admission.finish(); lastActivity = dependencies.now() }
        if request.legacyTouch != nil { return await performLegacyTouch(request) }
        if request.agentAdmission != nil, request.ax == nil, request.keyboard == nil {
            do {
                try acquireLease()
                let result = await AgentModeNativeOperation.perform(request, simulatorUDID: simulatorUDID,
                    brokerID: brokerID, logger: logger, transportOwner: transportOwner)
                if result.cleanup == "uncertain" {
                    await transportOwner.close()
                    return quarantine(result, request: request)
                }
                if result.error != nil, !Self.sentNothing(result) { await transportOwner.invalidate() }
                clear()
                return result
            } catch {
                let result = response(request, outcome: "rejectedBeforeInput", error: error)
                if lease != nil { await transportOwner.invalidate() }
                clear()
                return result
            }
        }
        if request.ax != nil || request.hinge != nil || request.keyboard != nil || request.rotation != nil {
            do {
                try acquireLease()
                if request.hinge != nil || request.rotation != nil { await transportOwner.invalidate() }
                let result: SelectedHIDResponse
                if request.ax?.kind == .sliderPercentage {
                    result = await SelectedAXOperation.perform(request, simulatorUDID: simulatorUDID,
                        brokerID: brokerID, logger: logger, valueOwner: sliderValueOwner, transportOwner: transportOwner)
                } else {
                    result = await dependencies.execute(request, simulatorUDID, brokerID, logger, batchTap)
                }
                let rotationNeedsInputQuarantine = result.rotation?.failure?.delivery == .uncertain
                    && !isStateOnlyRotationFailure(result, request: request)
                if result.cleanup == "uncertain" || result.ax?.slider?.delivery == "uncertain" || result.ax?.sliderValue?.delivery == "uncertain" || result.hinge?.failure?.delivery == .uncertain || rotationNeedsInputQuarantine {
                    await transportOwner.close()
                    return quarantine(result, request: request)
                }
                if result.error != nil, !Self.sentNothing(result) { await transportOwner.invalidate() }
                let retire = requiresRetirement(after: result, request: request)
                clear()
                if retire {
                    shouldStop = true
                    logger.info().log("Selected broker retiring after terminal AX read failure; request=\(request.requestID), broker=\(brokerID). No input was sent or replayed.")
                }
                return result
            } catch {
                let result = response(request, outcome: "rejectedBeforeInput", error: error)
                if lease != nil { await transportOwner.invalidate() }
                clear()
                return result
            }
        }
        var beforeCount = 0
        var buttonExecution: SelectedButtonExecutionEvidence?
        do {
            if request.expectedContext != nil, session != nil {
                throw SelectedHIDFailure.invalid("Context-bound input requires a fresh complete session")
            }
            let legacyKeyboardEvents = try await request.legacyKeyboard?.consume(
                endpoint: SelectedHIDBroker.endpoint(simulatorUDID: simulatorUDID))
            try Task.checkCancellation()
            if session == nil { try await open(request) }
            guard let session, let observation else { throw SelectedHIDFailure.invalid("Missing owned session") }
            beforeCount = await session.status().enqueuedEventCount
            let receipt: FBSimulatorHIDSessionReceipt
            switch request.operation {
            case .complete:
                if let legacyKeyboardEvents {
                    // Keep the raw keyboard lifecycle, including repeated modifier credits and boundary checks.
                    receipt = try await session.executeLegacyKeyboard(.composite(legacyKeyboardEvents.map(\.event)))
                    try await HIDInteractor.waitForStabilization(logger: logger)
                    try await session.validateLegacyBatchBoundary()
                    break
                }
                let event: FBSimulatorHIDEvent
                if let path = request.legacyPath {
                    event = try path.event(logicalSize: observation.displayContext.logicalSize)
                } else {
                    event = try request.completeEvent(observation: observation)
                }
                _ = try FBSimulatorHIDSession.preflight(event, observation: observation)
                receipt = try await session.execute(event)
            case .begin:
                receipt = try await session.begin(at: request.primitives[0].point)
                guard let token = receipt.token else { throw SelectedHIDFailure.invalid("Library did not return the retained token") }
                libraryToken = token
                admission.retain(request, token: UUID())
            case .move:
                guard let libraryToken else { throw SelectedHIDFailure.invalidToken }
                receipt = try await session.move(libraryToken, to: request.primitives[0].point)
            case .end:
                guard let libraryToken else { throw SelectedHIDFailure.invalidToken }
                // The library validates this point before sending; failure releases owned input.
                _ = try await session.move(libraryToken, to: request.primitives[0].point)
                receipt = try await session.end(libraryToken)
            case .close:
                receipt = try await session.close()
            }
            let count = await session.status().enqueuedEventCount - beforeCount
            let finishes = request.operation == .complete || request.operation == .end || request.operation == .close
            var cleanup = receipt.cleanup.rawValue
            if finishes {
                cleanup = try await session.close().cleanup.rawValue
                guard cleanup != "uncertain" else { throw SelectedHIDFailure.invalid("Cleanup outcome is uncertain") }
            }
            if request.home != nil || request.button != nil, let execution = await session.executionEvidence() {
                buttonExecution = SelectedButtonExecutionEvidence(execution: execution, cleanup: await session.cleanupEvidence())
            }
            let result = response(request, outcome: receipt.outcome.rawValue, count: count, cleanup: cleanup, includeToken: !finishes, buttonExecution: buttonExecution)
            if finishes { await feed?.closeAndWait(); clear() }
            return result
        } catch {
            var cleanup = "notNeeded"
            var count = 0
            if let session {
                let status = await session.status(); count = max(0, status.enqueuedEventCount - beforeCount)
                if let closed = try? await session.close() { cleanup = closed.cleanup.rawValue }
                else { cleanup = "uncertain" }
                if request.home != nil || request.button != nil, let execution = await session.executionEvidence() {
                    buttonExecution = SelectedButtonExecutionEvidence(execution: execution, cleanup: await session.cleanupEvidence())
                }
            }
            let result = response(request, outcome: "failedNoReplay", count: count, cleanup: cleanup, error: error, includeToken: false, buttonExecution: buttonExecution)
            await feed?.closeAndWait()
            if cleanup == "uncertain" {
                await transportOwner.close()
                return quarantine(result, request: request)
            }
            if lease != nil { await transportOwner.invalidate() }
            clear()
            // A retained token cannot be retried through a replacement session.
            return result
        }
    }

    private func performLegacyTouch(_ request: SelectedHIDRequest) async -> SelectedHIDResponse {
        var beforeCount = 0
        do {
            guard let touch = request.legacyTouch, let expected = request.expectedContext else {
                throw SelectedHIDFailure.invalid("Missing measured Duo touch payload")
            }
            let hadContact = admission.origin == .legacyTouch
            if session == nil { try await open(request) }
            guard let session, let observation else { throw SelectedHIDFailure.invalid("Missing owned Duo touch session") }
            beforeCount = await session.status().enqueuedEventCount
            guard expected == SelectedHIDContext(observation) else {
                throw SelectedHIDFailure.invalid("Duo touch context changed while input was retained")
            }
            // An unpaired up cannot release input owned by another selected route.
            // Do not send it on a replacement display after idle invalidation.
            let receipt: FBSimulatorHIDSessionReceipt
            if touch.up && !touch.down && !hadContact {
                receipt = try await session.close()
            } else {
                receipt = try await session.submitOwnedPart(touch.event())
            }
            let count = await session.status().enqueuedEventCount - beforeCount
            if touch.up {
                let cleanup = try await session.close().cleanup.rawValue
                guard cleanup != "uncertain" else { throw SelectedHIDFailure.invalid("Duo touch cleanup is uncertain") }
                let result = response(request, outcome: hadContact || touch.down ? receipt.outcome.rawValue : "noOwnedContact",
                    count: count, cleanup: cleanup)
                await feed?.closeAndWait()
                clear()
                return result
            }
            admission.retain(request, token: admission.token ?? UUID(), origin: .legacyTouch)
            return response(request, outcome: receipt.outcome.rawValue, count: count)
        } catch {
            var cleanup = "notNeeded"
            var count = 0
            if let session {
                let status = await session.status()
                count = max(0, status.enqueuedEventCount - beforeCount)
                if let closed = try? await session.close() { cleanup = closed.cleanup.rawValue }
                else { cleanup = "uncertain" }
            }
            let result = response(request, outcome: "failedNoReplay", count: count, cleanup: cleanup, error: error)
            await feed?.closeAndWait()
            if cleanup == "uncertain" {
                await transportOwner.close()
                return quarantine(result, request: request)
            }
            if lease != nil { await transportOwner.invalidate() }
            clear()
            return result
        }
    }

    func maintain(retainingAgentSnapshot: Bool = false) async {
        guard !quarantined, !admission.inFlight, !maintainingRetainedInput, !batchRunning else { return }
        if admission.token != nil, let feed, let observation {
            do { try feed.validateCurrentRevision(expected: observation) }
            catch {
                maintainingRetainedInput = true
                await releaseInvalidRetainedInput(error)
                return
            }
        }
        let idleTimeout: TimeInterval = admission.origin == .legacyTouch ? 60 : 30
        guard dependencies.now() - lastActivity >= idleTimeout else { return }
        // A live reference table retains the process, never an idle touch.
        if retainingAgentSnapshot, admission.token == nil { return }
        await shutdown()
    }

    private func releaseInvalidRetainedInput(_ error: Error) async {
        defer { maintainingRetainedInput = false; lastActivity = dependencies.now() }
        var cleanup = "uncertain"
        if let session, let receipt = try? await session.close() { cleanup = receipt.cleanup.rawValue }
        await feed?.closeAndWait()
        logger.info().log("Retained input invalidated; cleanup=\(cleanup); reason=\(error)")
        if cleanup == "uncertain" {
            let result = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: brokerID,
                outcome: "retainedContextCleanupUncertain", token: nil, enqueuedEventCount: 0,
                cleanup: cleanup, error: String(describing: error), context: observation.map(SelectedHIDContext.init))
            await transportOwner.close()
            _ = quarantine(result, request: lastRequest)
            return
        }
        clear()
    }

    /// A quarantined broker keeps its lease until the user deletes the persisted record after checking
    /// the device. It then retires without sending input, so the next command starts a fresh broker.
    /// A record that was never persisted keeps the lease, because nothing else would block input.
    func retireIfQuarantineCleared() {
        guard quarantined, quarantineReceipt?.persisted == true, !admission.inFlight, !batchRunning,
              !maintainingRetainedInput, dependencies.quarantineCleared(simulatorUDID) else { return }
        logger.info().log("Quarantine record removed; selected broker \(brokerID) retiring without input.")
        shouldStop = true
    }

    /// Call only after outstanding actions have completed; no new action is admitted.
    func shutdown() async {
        guard !quarantined else { return }
        shouldStop = true
        var cleanup = "notNeeded"
        if let session {
            do {
                let receipt = try await session.close()
                cleanup = receipt.cleanup.rawValue
                logger.info().log("Selected lease closed; cleanup=\(receipt.cleanup.rawValue)")
            } catch { cleanup = "uncertain"; logger.error().log("Selected lease close failed: \(error)") }
        }
        await feed?.closeAndWait()
        await transportOwner.close()
        if cleanup == "uncertain" {
            let result = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: brokerID,
                outcome: "expiryCleanupUncertain", token: nil, enqueuedEventCount: 0, cleanup: cleanup,
                error: "Retained session expiry cleanup is uncertain", context: observation.map(SelectedHIDContext.init))
            _ = quarantine(result, request: lastRequest)
            shouldStop = false
        } else { clear() }
    }

    func rejectBusy(_ request: SelectedHIDRequest) -> SelectedHIDResponse {
        var result = response(request, outcome: "rejectedBeforeInput",
            error: quarantined ? SelectedHIDFailure.invalid("Device input is quarantined; no input was sent. " + HIDInputQuarantine.recoveryStep(recordPath: quarantineReceipt?.recordPath)) : SelectedHIDFailure.busy,
            includeToken: false)
        result.quarantine = quarantineReceipt
        result.ax?.failure = .ownershipRejected
        return result
    }

    /// Selected input without a screen pair binds the screen that is active now. A retained contact
    /// keeps its original pair, so a fold or rotation since it began fails admission instead.
    private func bindActiveDisplay(_ request: SelectedHIDRequest) async throws -> SelectedHIDRequest {
        let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
        let active = try await PhaseTimer.measure("owner.activeDisplay") {
            try await DisplayTransition.settledDiscovery(for: simulator).readback.snapshot.activePanel.identity
        }
        var bound = request
        bound.screenID = active.displayID
        bound.screenUUID = active.uniqueID
        bound.activeDisplay = nil
        try bound.validate()
        return bound
    }

    private func acquireLease() throws {
        // Every current input route, including the raw broker, takes this common lease.
        try PhaseTimer.measureSync("owner.lease") {
            lease = try HIDInputLease.acquire(simulatorUDID: simulatorUDID)
        }
    }

    private func open(_ request: SelectedHIDRequest) async throws {
        let display = try request.selectedDisplay()
        // Ordinary paths, touches and keys use the retained connection on the Duo and on verified
        // DTUHID rigid devices; the shared-owner check refuses any other profile before input.
        try await open(displayID: display.id, displayUUID: display.uuid,
            expectedContext: request.expectedContext, requiresDuo: false,
            requiresSharedOwner: request.legacyPath != nil || request.legacyTouch != nil
                || request.legacyKeyboard != nil) { observation in
                try request.home?.validate(observation: observation)
                try request.button?.validate(observation: observation)
            }
    }

    private func open(displayID: UInt32, displayUUID: UUID, expectedContext: SelectedHIDContext?,
                      requiresDuo: Bool, requiresSharedOwner: Bool = false,
                      validate: (FBSimulatorHIDSessionObservation) throws -> Void = { _ in }) async throws {
        try acquireLease()
        let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
        if requiresDuo {
            guard LegacyDuoInput.isDuo(simulator) else {
                throw SelectedHIDFailure.invalid("Legacy Duo input requires the verified Duo device profile")
            }
            try LegacyDuoInput.requireVerifiedDuo(simulator)
        }
        if requiresSharedOwner, try !LegacyDuoInput.usesSharedKeyboardOwner(for: simulator) {
            throw SelectedHIDFailure.invalid("Raw input transport or verified profile changed before input")
        }
        let feed = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator,
            screenID: displayID, screenUniqueID: displayUUID)
        self.feed = feed
        observation = feed.initialObservation
        if let expected = expectedContext, expected != SelectedHIDContext(feed.initialObservation) {
            throw SelectedHIDFailure.invalid("Measured Duo input context changed before input")
        }
        try validate(feed.initialObservation)
        session = try await FBSimulatorHIDSession.open(for: simulator, observation: feed.initialObservation,
            liveFreshnessProvider: feed, transportOwner: transportOwner)
    }

    /// One in-process owner for the complete ordinary batch. It never rebinds after failure.
    func withLegacyBatch(context: SelectedHIDContext,
                         body: @MainActor () async throws -> Void) async throws {
        guard !isBusy, session == nil, admission.token == nil else { throw SelectedHIDFailure.busy }
        try context.validate()
        guard let uuid = UUID(uuidString: context.screenUUID) else {
            throw SelectedHIDFailure.invalid("Invalid measured Duo display identity")
        }
        batchRunning = true
        defer { batchRunning = false; lastActivity = dependencies.now() }
        var actionError: Error?
        do {
            try await open(displayID: context.screenID, displayUUID: uuid,
                expectedContext: context, requiresDuo: true)
            try await body()
            try await validateLegacyBatchBoundary()
        } catch { actionError = error }

        var cleanup = "notNeeded"
        if let session {
            do { cleanup = try await session.close().cleanup.rawValue }
            catch { cleanup = "uncertain" }
        }
        await feed?.closeAndWait()
        logger.info().log("Duo batch closed; cleanup=\(cleanup)")
        if cleanup == "uncertain" {
            let diagnostic = actionError.map { String(describing: $0) } ?? "Batch completion"
            let result = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(),
                brokerID: brokerID, outcome: "batchCleanupUncertain", token: nil,
                enqueuedEventCount: 0, cleanup: cleanup, error: diagnostic,
                context: observation.map(SelectedHIDContext.init))
            await transportOwner.close()
            let blocked = quarantine(result, request: nil)
            let persistence = blocked.quarantine?.persisted == true
                ? "Input quarantine saved. " + HIDInputQuarantine.recoveryStep(recordPath: blocked.quarantine?.recordPath)
                : "Input quarantine could not be saved; manual recovery is required. \(blocked.quarantine?.error ?? "")"
            throw CLIError(errorDescription: "AXe could not confirm that every touch or key of the batch was released. \(persistence)",
                code: .cleanupUncertain)
        }
        if actionError != nil { await transportOwner.invalidate() }
        clear()
        if let actionError {
            let failure = CLIErrorMapping.failure(for: actionError)
            throw CLIOutputFailure(code: failure.code, message: failure.message + " Input was not repeated.")
        }
    }

    func validateLegacyBatchContext() async throws {
        try Task.checkCancellation()
        guard batchRunning, !quarantined, let session, let feed, let observation else {
            throw SelectedHIDFailure.invalid("Missing fixed Duo batch owner")
        }
        try feed.validateCurrentRevision(expected: observation)
        let state = await session.status().state
        guard state == .ready || state == .retainedInputs else {
            throw SelectedHIDFailure.invalid("Duo batch session is no longer usable; input was not replayed")
        }
        try Task.checkCancellation()
    }

    func validateLegacyBatchBoundary() async throws {
        try await validateLegacyBatchContext()
        guard let session else { throw SelectedHIDFailure.invalid("Missing Duo batch session") }
        try await session.validateLegacyBatchBoundary()
    }

    func submitLegacyBatchPart(_ event: FBSimulatorHIDEvent) async throws {
        try await validateLegacyBatchContext()
        guard let session else { throw SelectedHIDFailure.invalid("Missing Duo batch session") }
        let receipt = try await session.submitLegacyBatchPart(event)
        logger.info().log("Duo batch part completed; events=\(receipt.enqueuedEventCount); outcome=\(receipt.outcome.rawValue)")
        try await HIDInteractor.waitForStabilization(logger: logger)
    }

    /// Only the typed ordinary UP-only step has the legacy no-contact no-op policy.
    /// Generic parts, including composites, retain strict native release validation.
    func releaseLegacyBatchTouch(at point: (x: Double, y: Double)) async throws {
        try await validateLegacyBatchContext()
        guard let session, let observation else { throw SelectedHIDFailure.invalid("Missing Duo batch session") }
        _ = try observation.displayContext.normalizedPoint(from: CGPoint(x: point.x, y: point.y))
        guard await session.status().hasRetainedContact else {
            logger.info().log("Duo batch touch up has no owned contact; no input sent")
            return
        }
        try await submitLegacyBatchPart(.touch(direction: .up, x: point.x, y: point.y))
    }

    func waitForLegacyBatch(seconds: Double) async throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw SelectedHIDFailure.invalid("Duo batch wait must be finite and non-negative")
        }
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            try await validateLegacyBatchContext()
            let components = start.duration(to: clock.now).components
            let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
            guard elapsed < seconds else { return }
            try await Task.sleep(for: .seconds(min(0.05, seconds - elapsed)))
        }
    }

    /// A failed orientation write can change layout later, but cannot retain a key or contact.
    /// Keep its error and require fresh context instead of persisting input-cleanup quarantine.
    private func isStateOnlyRotationFailure(_ result: SelectedHIDResponse, request: SelectedHIDRequest) -> Bool {
        guard request.rotation != nil, (try? request.validate()) != nil,
              request.operation == .complete, request.token == nil, request.primitives.isEmpty,
              admission.inFlight, admission.token == nil, lease != nil,
              session == nil, feed == nil, libraryToken == nil, observation == nil,
              result.version == SelectedHIDRequest.version, result.requestID == request.requestID,
              result.brokerID == brokerID, result.outcome == "failedNoReplay", result.error != nil,
              result.enqueuedEventCount == 0, result.cleanup == "notNeeded", result.token == nil,
              result.quarantine == nil, result.rotation?.receipt == nil,
              result.rotation?.failure?.delivery == .uncertain else { return false }
        return true
    }

    private func quarantine(_ response: SelectedHIDResponse, request: SelectedHIDRequest?) -> SelectedHIDResponse {
        quarantined = true
        var result = response
        let recordPath = try? HIDInputQuarantine.fileURL(simulatorUDID: simulatorUDID).path
        do {
            try dependencies.persist(simulatorUDID, result, request)
            result.quarantine = SelectedHIDQuarantine(recordPath: recordPath, persisted: true, error: nil)
        } catch {
            let message = "Quarantine persistence failed; device lease remains held: \(error)"
            logger.error().log(message)
            result.quarantine = SelectedHIDQuarantine(recordPath: recordPath, persisted: false, error: message)
        }
        quarantineReceipt = result.quarantine
        // Keep the common lease and original context. Recovery is explicit.
        return result
    }

    /// Retire process-owned AX state only after a complete read failed without input or retained ownership.
    private func requiresRetirement(after result: SelectedHIDResponse, request: SelectedHIDRequest) -> Bool {
        guard !quarantined, !maintainingRetainedInput, !batchRunning, admission.inFlight, lease != nil,
              admission.token == nil, libraryToken == nil, session == nil, feed == nil, observation == nil,
              let requestedAX = request.ax, requestedAX.kind == .describe,
              result.version == SelectedHIDRequest.version, result.requestID == request.requestID,
              result.brokerID == brokerID, result.outcome == "failedBeforeInput", result.error != nil,
              result.enqueuedEventCount == 0, result.cleanup == "notNeeded", result.token == nil,
              result.quarantine == nil, result.context != nil, let ax = result.ax,
              ax.kind == requestedAX.kind, ax.expectedPID == requestedAX.expectedPID,
              ax.failure == .acquisitionFailed, ax.acquisition?.outcome == .failed else { return false }
        return true
    }

    /// A refusal before any event, with no cleanup, leaves the borrowed connection untouched. The
    /// session already returned or closed it; the owner reuses it only for an identical context.
    private static func sentNothing(_ result: SelectedHIDResponse) -> Bool {
        result.outcome == "failedBeforeInput" && result.enqueuedEventCount == 0 && result.cleanup == "notNeeded"
            && result.quarantine == nil
    }

    private func clear() {
        sliderValueOwner.clear()
        session = nil; feed = nil; libraryToken = nil; observation = nil; lease = nil; lastRequest = nil; admission.clear()
    }
    private func response(_ request: SelectedHIDRequest, outcome: String, count: Int = 0,
                          cleanup: String = "notNeeded", error: Error? = nil, includeToken: Bool = false,
                          buttonExecution: SelectedButtonExecutionEvidence? = nil) -> SelectedHIDResponse {
        var ax = request.ax.map { SelectedAXResult(kind: $0.kind, expectedPID: $0.expectedPID) }
        if error != nil { ax?.failure = .setupFailed }
        var hinge = request.hinge.map(SelectedHingeResult.init)
        if let readinessError = error as? FBSimulatorHingeReadinessError { hinge?.readinessPreflightFailure = readinessError }
        else if let error { hinge?.failure = SelectedHingeFailure(error) }
        var result = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID, brokerID: brokerID,
            outcome: outcome, token: includeToken ? admission.token : nil, enqueuedEventCount: count, cleanup: cleanup,
            error: error.map { String(describing: $0) }, context: observation.map(SelectedHIDContext.init), ax: ax,
            quarantine: quarantineReceipt, hinge: hinge,
            home: request.home == nil ? nil : buttonExecution,
            button: request.button.flatMap { payload in
                buttonExecution.map { SelectedButtonResult(kind: payload.kind, execution: $0) }
            })
        if case let .coded(code, message)? = error as? SelectedHIDFailure {
            result.errorCode = code
            result.error = message
        }
        return result
    }
}
