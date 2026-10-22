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
    private let helperURL: URL
    private let dependencies: SelectedAXDependencies
    private var admission = SelectedHIDAdmission()
    private var lease: HIDInputLease?
    private var session: FBSimulatorHIDSession?
    private var feed: FBSimulatorHIDNativeFreshnessProvider?
    private var quarantined = false
    private var maintainingRetainedInput = false
    private var quarantineReceipt: SelectedHIDQuarantine?
    private var lastRequest: SelectedHIDRequest?
    private var libraryToken: FBSimulatorHIDContactToken?
    private var observation: FBSimulatorHIDSessionObservation?
    private var lastActivity: TimeInterval
    private(set) var shouldStop = false
    var isBusy: Bool { admission.inFlight || maintainingRetainedInput || shouldStop || quarantined }

    convenience init(simulatorUDID: String, logger: AxeLogger, helperURL: URL) {
        self.init(simulatorUDID: simulatorUDID, logger: logger, helperURL: helperURL, dependencies: .live)
    }

    init(simulatorUDID: String, logger: AxeLogger, helperURL: URL, dependencies: SelectedAXDependencies) {
        self.simulatorUDID = simulatorUDID; self.logger = logger; self.helperURL = helperURL
        self.dependencies = dependencies; lastActivity = dependencies.now()
    }

    func perform(_ request: SelectedHIDRequest) async -> SelectedHIDResponse {
        do {
            guard !shouldStop, !quarantined, !maintainingRetainedInput else { throw SelectedHIDFailure.busy }
            try admission.enter(request)
            lastRequest = request
        }
        catch { return response(request, outcome: "rejectedBeforeInput", error: error) }
        defer { admission.finish(); lastActivity = dependencies.now() }
        if request.agentAdmission != nil, request.ax == nil, request.keyboard == nil {
            do {
                try acquireLease()
                let result = await AgentModeNativeOperation.perform(request, simulatorUDID: simulatorUDID,
                    brokerID: brokerID, logger: logger, helperURL: helperURL)
                if result.cleanup == "uncertain" { return quarantine(result, request: request) }
                clear()
                return result
            } catch {
                let result = response(request, outcome: "rejectedBeforeInput", error: error)
                clear()
                return result
            }
        }
        if request.ax != nil || request.hinge != nil || request.keyboard != nil || request.rotation != nil {
            do {
                try acquireLease()
                let result = await dependencies.execute(request, simulatorUDID, brokerID, logger, helperURL)
                if result.cleanup == "uncertain" || result.ax?.slider?.delivery == "uncertain" || result.hinge?.failure?.delivery == .uncertain || result.rotation?.failure?.delivery == .uncertain {
                    return quarantine(result, request: request)
                }
                clear()
                return result
            } catch {
                let result = response(request, outcome: "rejectedBeforeInput", error: error)
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
            if session == nil { try await open(request) }
            guard let session, let observation else { throw SelectedHIDFailure.invalid("Missing owned session") }
            beforeCount = await session.status().enqueuedEventCount
            let receipt: FBSimulatorHIDSessionReceipt
            switch request.operation {
            case .complete:
                let event = try request.completeEvent(observation: observation)
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
            if cleanup == "uncertain" { return quarantine(result, request: request) }
            clear()
            // A retained token cannot be retried through a replacement session.
            return result
        }
    }

    func maintain() async {
        guard !quarantined, !admission.inFlight, !maintainingRetainedInput else { return }
        if admission.token != nil, let feed, let observation {
            do { try feed.validateCurrentRevision(expected: observation) }
            catch {
                maintainingRetainedInput = true
                await releaseInvalidRetainedInput(error)
                return
            }
        }
        guard dependencies.now() - lastActivity >= 30 else { return }
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
            _ = quarantine(result, request: lastRequest)
            return
        }
        clear()
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
            error: quarantined ? SelectedHIDFailure.invalid("Device input is quarantined; explicit recovery is required") : SelectedHIDFailure.busy,
            includeToken: false)
        result.quarantine = quarantineReceipt
        result.ax?.failure = .ownershipRejected
        return result
    }

    private func acquireLease() throws {
        let legacyEndpoint = try HIDBroker.endpointPath(simulatorUDID: simulatorUDID)
        guard try !HIDBroker.isBrokerProcessAlive(endpoint: legacyEndpoint) else { throw SelectedHIDFailure.busy }
        lease = try HIDInputLease.acquire(simulatorUDID: simulatorUDID)
    }

    private func open(_ request: SelectedHIDRequest) async throws {
        try acquireLease()
        try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
        let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let simulator = set.allSimulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: simulatorUDID) }), simulator.state == .booted else {
            throw CLIError.simulatorNotFound(udid: simulatorUDID)
        }
        let display = try request.selectedDisplay()
        let feed = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator, helperURL: helperURL,
            screenID: display.id, screenUniqueID: display.uuid)
        self.feed = feed
        observation = feed.initialObservation
        if let expected = request.expectedContext, expected != SelectedHIDContext(feed.initialObservation) {
            throw SelectedHIDFailure.invalid("Measured Duo tap context changed before input")
        }
        try request.home?.validate(observation: feed.initialObservation)
        try request.button?.validate(observation: feed.initialObservation)
        session = try await FBSimulatorHIDSession.open(for: simulator, observation: feed.initialObservation, liveFreshnessProvider: feed)
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

    private func clear() {
        session = nil; feed = nil; libraryToken = nil; observation = nil; lease = nil; lastRequest = nil; admission.clear()
    }
    private func response(_ request: SelectedHIDRequest, outcome: String, count: Int = 0,
                          cleanup: String = "notNeeded", error: Error? = nil, includeToken: Bool = false,
                          buttonExecution: SelectedButtonExecutionEvidence? = nil) -> SelectedHIDResponse {
        var ax = request.ax.map { SelectedAXResult(kind: $0.kind, expectedPID: $0.expectedPID, preparation: $0.preparation) }
        if error != nil { ax?.failure = .setupFailed }
        var hinge = request.hinge.map(SelectedHingeResult.init)
        if let readinessError = error as? FBSimulatorHingeReadinessError { hinge?.readinessPreflightFailure = readinessError }
        else if let error { hinge?.failure = SelectedHingeFailure(error) }
        return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID, brokerID: brokerID,
            outcome: outcome, token: includeToken ? admission.token : nil, enqueuedEventCount: count, cleanup: cleanup,
            error: error.map { String(describing: $0) }, context: observation.map(SelectedHIDContext.init), ax: ax,
            quarantine: quarantineReceipt, hinge: hinge,
            home: request.home == nil ? nil : buttonExecution,
            button: request.button.flatMap { payload in
                buttonExecution.map { SelectedButtonResult(kind: payload.kind, execution: $0) }
            })
    }
}
