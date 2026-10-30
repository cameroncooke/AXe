import Foundation
import FBControlCore
import FBSimulatorControl

/// The common broker lease remains held through every focus read, key release and feed close.
@MainActor
enum SelectedKeyboardOperation {
    static func perform(_ request: SelectedHIDRequest, simulatorUDID: String,
                        brokerID: UUID, logger: AxeLogger, helperURL: URL,
                        transportOwner: FBSimulatorHIDTransportOwner? = nil) async -> SelectedHIDResponse {
        var observation: FBSimulatorHIDSessionObservation?
        var feed: FBSimulatorHIDNativeFreshnessProvider?
        var session: FBSimulatorHIDSession?
        var guardOwner: SelectedKeyboardFocusGuard?
        var result = request.keyboard.map { SelectedKeyboardResult(expectedPID: $0.expectedPID, focusID: $0.focusID) }
        var count = 0
        var cleanup = "notNeeded"
        do {
            try request.validate()
            guard let keyboard = request.keyboard else { throw SelectedHIDFailure.invalid("Missing keyboard payload") }
            try Task.checkCancellation()
            try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
            let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
            guard let simulator = set.allSimulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: simulatorUDID) }),
                  simulator.state == .booted else { throw CLIError.simulatorNotFound(udid: simulatorUDID) }
            let display = try request.selectedDisplay()
            let live = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator, helperURL: helperURL,
                screenID: display.id, screenUniqueID: display.uuid)
            feed = live
            observation = live.initialObservation
            try request.agentAdmission?.validateContext(live.initialObservation)
            _ = try FBSimulatorHIDSession.preflight(keyboard.event, observation: live.initialObservation)
            let focus = SelectedKeyboardFocusGuard(simulator: simulator, feed: live, request: keyboard, agentAdmission: request.agentAdmission)
            guardOwner = focus
            try await focus.prepare()
            let hid: FBSimulatorHIDSession
            if let transportOwner {
                hid = try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                    liveFreshnessProvider: live, transportOwner: transportOwner)
            } else {
                hid = try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                    liveFreshnessProvider: live)
            }
            session = hid
            let receipt = try await hid.execute(keyboard.event, keyboardAdmissionGuard: focus)
            result = focus.result
            count = await hid.status().enqueuedEventCount
            cleanup = try await hid.close().cleanup.rawValue
            guard cleanup != "uncertain" else { throw SelectedHIDFailure.invalid("Keyboard release is uncertain") }
            await live.closeAndWait()
            return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: brokerID, outcome: receipt.outcome.rawValue, token: nil,
                enqueuedEventCount: count, cleanup: cleanup, error: nil,
                context: observation.map(SelectedHIDContext.init), keyboard: result)
        } catch {
            result = guardOwner?.result ?? result
            if let session {
                count = await session.status().enqueuedEventCount
                do { cleanup = try await session.close().cleanup.rawValue }
                catch { cleanup = "uncertain" }
            }
            await feed?.closeAndWait()
            return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: brokerID, outcome: count == 0 && cleanup == "notNeeded" ? "failedBeforeInput" : "failedNoReplay",
                token: nil, enqueuedEventCount: count, cleanup: cleanup, error: String(reflecting: error),
                context: observation.map(SelectedHIDContext.init), keyboard: result)
        }
    }
}

/// Read again before every key down. Key up and cleanup bypass focus admission so owned keys release.
/// AX focus and HID delivery are separate OS operations; this is not an atomic recipient guarantee.
@MainActor
final class SelectedKeyboardFocusGuard: FBSimulatorHIDKeyboardAdmissionGuard {
    private let simulator: FBSimulator
    private let feed: FBSimulatorHIDNativeFreshnessProvider
    private let request: SelectedKeyboardRequest
    private let agentAdmission: AgentModeAdmission?
    private let deadline: DispatchTime
    private(set) var result: SelectedKeyboardResult

    init(simulator: FBSimulator, feed: FBSimulatorHIDNativeFreshnessProvider, request: SelectedKeyboardRequest, agentAdmission: AgentModeAdmission? = nil) {
        self.simulator = simulator
        self.feed = feed
        self.request = request
        self.agentAdmission = agentAdmission
        let requestedDelay = request.events.reduce(0.0) { total, event in
            if case .delay(let seconds) = event { return total + seconds }
            return total
        }
        // Keep the input work allowance. Validated explicit waits have their own bound.
        deadline = DispatchTime.now() + (8 + requestedDelay)
        result = SelectedKeyboardResult(expectedPID: request.expectedPID, focusID: request.focusID)
    }

    func prepare() async throws {
        result.initialTarget = try await readFocusedField()
    }

    func validateKeyDown(observation: FBSimulatorHIDSessionObservation, keyCode: UInt32) async throws {
        try agentAdmission?.validateContext(observation)
        guard observation == feed.initialObservation, keyCode <= 255, let initial = result.initialTarget else {
            throw SelectedHIDFailure.invalid("Keyboard context or initial field is missing or changed")
        }
        let field = try await readFocusedField()
        guard field.frame == initial.frame else {
            throw SelectedHIDFailure.invalid("Focused field geometry changed before key down")
        }
        result.lastValidatedTarget = field
        result.validatedKeyDownCount += 1
        guard try JSONEncoder().encode(result).count <= SelectedAXBounds.contentBytes else {
            throw SelectedAXContentError.tooLarge
        }
        _ = try remainingSeconds()
    }

    private func readFocusedField() async throws -> FBSimulatorAXNode {
        // Read a new root and exact field before every down; do not serialize the whole tree.
        let field = try await SelectedKeyboardFocusRead.perform(remainingSeconds: remainingSeconds) { remaining in
            try await FBSimulatorAXSnapshot.readFocusedTextField(for: simulator,
                expectedPID: request.expectedPID, identifier: request.focusID,
                observation: feed.initialObservation, liveFreshnessProvider: feed, timeoutSeconds: remaining)
        }
        _ = try remainingSeconds()
        try SelectedKeyboardFocusPolicy.validate(field, expectedPID: request.expectedPID, focusID: request.focusID)
        try agentAdmission?.target?.validate(field, allowingValueChange: result.validatedKeyDownCount > 0)
        _ = try remainingSeconds()
        return field
    }

    private func remainingSeconds() throws -> Double {
        try Task.checkCancellation()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else {
            throw SelectedHIDFailure.invalid("Selected keyboard exceeded its eight-second input allowance and requested delays")
        }
        return Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }
}

/// Reacquire only the native AX read. The input transaction and its deadline stay with the caller.
@MainActor
enum SelectedKeyboardFocusRead {
    static func perform(remainingSeconds: () throws -> Double,
                        read: (Double) async throws -> FBSimulatorAXNode) async throws -> FBSimulatorAXNode {
        let timeout = min(8, try remainingSeconds())
        do {
            return try await read(timeout)
        } catch {
            let nativeError = error as NSError
            guard nativeError.domain == "DTXProxyChannel", nativeError.code == 1,
                  nativeError.userInfo[NSLocalizedDescriptionKey] as? String == "Channel disconnected" else {
                throw error
            }
            try Task.checkCancellation()
            // The first read already closed its AX handle/session. Do not reuse its result or budget.
            return try await read(min(8, try remainingSeconds()))
        }
    }
}
