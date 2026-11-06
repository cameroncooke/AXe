import Foundation
import FBControlCore
import FBSimulatorControl

/// Called only while SelectedHIDOwner holds its normal admission and device lease.
@MainActor
enum AgentModeNativeOperation {
    static func perform(_ request: SelectedHIDRequest, simulatorUDID: String,
                        brokerID: UUID, logger: AxeLogger,
                        transportOwner: FBSimulatorHIDTransportOwner? = nil) async -> SelectedHIDResponse {
        var observation: FBSimulatorHIDSessionObservation?
        var feed: FBSimulatorHIDNativeFreshnessProvider?
        var session: FBSimulatorHIDSession?
        var pathGuard: AgentModePathAdmissionGuard?
        var count = 0
        var cleanup = "notNeeded"
        do {
            try request.validate()
            guard let admission = request.agentAdmission else {
                throw AgentModeFailure("missingAdmission", "The agent input admission is missing.")
            }
            let simulator = try await PhaseTimer.measure("native.simulatorSet") { () async throws -> FBSimulator in
                try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
                let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
                guard let simulator = set.allSimulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: simulatorUDID) }),
                      simulator.state == .booted else { throw CLIError.simulatorNotFound(udid: simulatorUDID) }
                return simulator
            }
            let display = try request.selectedDisplay()
            let live = try await PhaseTimer.measure("native.liveContextStart") {
                try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator,
                    screenID: display.id, screenUniqueID: display.uuid)
            }
            feed = live; observation = live.initialObservation
            try admission.validateContext(live.initialObservation)
            let event = try request.completeEvent(observation: live.initialObservation)
            let guardOwner: any FBSimulatorHIDInputAdmissionGuard
            if admission.target != nil {
                let guardValue: AgentModePathAdmissionGuard
                if let pinch = request.pinch {
                    guardValue = try AgentModePathAdmissionGuard(simulator: simulator, feed: live,
                        admission: admission, pinch: pinch)
                } else if let path = request.path {
                    guardValue = try AgentModePathAdmissionGuard(simulator: simulator, feed: live,
                        admission: admission, path: path)
                } else {
                    throw AgentModeFailure("unsupportedTargetPath", "A target admission requires a complete path or pinch.")
                }
                pathGuard = guardValue
                guardOwner = guardValue
            } else {
                guardOwner = AgentModeFreshScreenGuard(simulator: simulator, feed: live, admission: admission)
            }
            let hid = try await PhaseTimer.measure("native.hidOpen") { () async throws -> FBSimulatorHIDSession in
                if let transportOwner {
                    return try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                        liveFreshnessProvider: live, transportOwner: transportOwner)
                }
                return try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                    liveFreshnessProvider: live)
            }
            session = hid
            // Includes the admission guard's screen read before the first event and the event drain.
            let receipt = try await PhaseTimer.measure("native.hidExecute") { try await hid.execute(event, admissionGuard: guardOwner) }
            count = await hid.status().enqueuedEventCount
            cleanup = try await PhaseTimer.measure("native.hidClose") { try await hid.close().cleanup.rawValue }
            guard cleanup != "uncertain" else { throw AgentModeFailure("cleanupUncertain", "Native input cleanup is uncertain.") }
            await PhaseTimer.measure("native.liveContextClose") { await live.closeAndWait() }
            return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: brokerID, outcome: receipt.outcome.rawValue, token: nil,
                enqueuedEventCount: count, cleanup: cleanup, error: nil,
                context: observation.map(SelectedHIDContext.init))
        } catch {
            // This unstructured task does not inherit the action's cancellation state.
            let ownedSession = session
            let ownedFeed = feed
            let released = await Task { @MainActor in
                var count = 0
                var cleanup = "notNeeded"
                if let ownedSession {
                    count = await ownedSession.status().enqueuedEventCount
                    do { cleanup = try await ownedSession.close().cleanup.rawValue }
                    catch { cleanup = "uncertain" }
                }
                await ownedFeed?.closeAndWait()
                return (count, cleanup)
            }.value
            let message: String
            if released.1 == "uncertain" {
                message = "Native input cleanup is uncertain. Do not repeat input."
            } else if let failure = pathGuard?.failure ?? (error as? AgentModeFailure) {
                message = failure.message
            } else if error is CancellationError {
                message = "The agent input was cancelled. Refresh the snapshot before another action."
            } else if released.0 == 0 {
                message = "The native input check failed. Refresh the snapshot."
            } else {
                message = "Native input did not complete. It was not repeated. Refresh the snapshot."
            }
            var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: brokerID, outcome: released.0 == 0 && released.1 == "notNeeded" ? "failedBeforeInput" : "failedNoReplay",
                token: nil, enqueuedEventCount: released.0, cleanup: released.1,
                error: message, context: observation.map(SelectedHIDContext.init))
            // A policy rejection before input keeps its typed code for the agent reply.
            if response.outcome == "failedBeforeInput", let policyFailure = pathGuard?.failure ?? (error as? AgentModeFailure) {
                response.agent = AgentModeResult(error: policyFailure,
                    cache: AgentModeCacheState(status: "invalidated", reason: policyFailure.code, requiresRefresh: true),
                    context: response.context)
            }
            return response
        }
    }
}

@MainActor
private final class AgentModeFreshScreenGuard: FBSimulatorHIDInputAdmissionGuard {
    private let simulator: FBSimulator
    private let feed: FBSimulatorHIDNativeFreshnessProvider
    private let admission: AgentModeAdmission

    init(simulator: FBSimulator, feed: FBSimulatorHIDNativeFreshnessProvider, admission: AgentModeAdmission) {
        self.simulator = simulator; self.feed = feed; self.admission = admission
    }

    func validate(observation: FBSimulatorHIDSessionObservation, firstEvent: FBSimulatorHIDEvent) async throws {
        try Task.checkCancellation()
        try admission.validateContext(observation)
        // Direct first read, as the snapshot's own description used. Runtime preparation runs
        // only after a verified empty tree; an empty or failed result still sends no input.
        let policy = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: 8, maximumAttempts: 2)
        let acquisition = try await PhaseTimer.measure("native.admissionRead") {
            try await FBSimulatorAXSnapshot.acquire(for: simulator, expectedPID: admission.expectedPID,
                observation: observation, freshnessProvider: feed, policy: policy)
        }
        guard acquisition.outcome == .ready, let snapshot = acquisition.snapshot else {
            throw AgentModeFailure("admissionReadFailed", "The native screen could not be confirmed before input.")
        }
        try admission.validateScreen(snapshot.roots)
        try feed.validateCurrentRevision(expected: observation)
    }
}
