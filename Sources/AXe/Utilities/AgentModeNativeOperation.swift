import Foundation
import FBControlCore
import FBSimulatorControl

/// Called only while SelectedHIDOwner holds its normal admission and device lease.
@MainActor
enum AgentModeNativeOperation {
    static func perform(_ request: SelectedHIDRequest, simulatorUDID: String,
                        brokerID: UUID, logger: AxeLogger, helperURL: URL) async -> SelectedHIDResponse {
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
            try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
            let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
            guard let simulator = set.allSimulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: simulatorUDID) }),
                  simulator.state == .booted else { throw CLIError.simulatorNotFound(udid: simulatorUDID) }
            let display = try request.selectedDisplay()
            let live = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator, helperURL: helperURL,
                screenID: display.id, screenUniqueID: display.uuid)
            feed = live; observation = live.initialObservation
            try admission.validateContext(live.initialObservation)
            let event = try request.completeEvent(observation: live.initialObservation)
            let guardOwner: any FBSimulatorHIDInputAdmissionGuard
            if admission.target != nil {
                guard let path = request.path else {
                    throw AgentModeFailure("unsupportedTargetPath", "A target admission requires a complete explicit path.")
                }
                let guardValue = try AgentModePathAdmissionGuard(simulator: simulator, feed: live,
                    admission: admission, path: path)
                pathGuard = guardValue
                guardOwner = guardValue
            } else {
                guardOwner = AgentModeFreshScreenGuard(simulator: simulator, feed: live, admission: admission)
            }
            let hid = try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                liveFreshnessProvider: live)
            session = hid
            let receipt = try await hid.execute(event, admissionGuard: guardOwner)
            count = await hid.status().enqueuedEventCount
            cleanup = try await hid.close().cleanup.rawValue
            guard cleanup != "uncertain" else { throw AgentModeFailure("cleanupUncertain", "Native input cleanup is uncertain.") }
            await live.closeAndWait()
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
            return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: brokerID, outcome: released.0 == 0 && released.1 == "notNeeded" ? "failedBeforeInput" : "failedNoReplay",
                token: nil, enqueuedEventCount: released.0, cleanup: released.1,
                error: message, context: observation.map(SelectedHIDContext.init))
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
        let policy = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: 8, maximumAttempts: 1)
        let acquisition = try await FBSimulatorAXSnapshot.acquire(for: simulator, expectedPID: admission.expectedPID,
            observation: observation, freshnessProvider: feed, policy: policy, preparation: .automationSession)
        guard acquisition.outcome == .ready, let snapshot = acquisition.snapshot else {
            throw AgentModeFailure("admissionReadFailed", "The native screen could not be confirmed before input.")
        }
        try admission.validateScreen(snapshot.roots)
        try feed.validateCurrentRevision(expected: observation)
    }
}
