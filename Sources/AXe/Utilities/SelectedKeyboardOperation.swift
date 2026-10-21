import Foundation
import FBControlCore
import FBSimulatorControl

/// The common broker lease remains held through every focus read, key release and feed close.
@MainActor
enum SelectedKeyboardOperation {
    static func perform(_ request: SelectedHIDRequest, simulatorUDID: String,
                        brokerID: UUID, logger: AxeLogger, helperURL: URL) async -> SelectedHIDResponse {
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
            _ = try FBSimulatorHIDSession.preflight(keyboard.event, observation: live.initialObservation)
            let focus = SelectedKeyboardFocusGuard(simulator: simulator, feed: live, request: keyboard)
            guardOwner = focus
            try await focus.prepare()
            let hid = try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                liveFreshnessProvider: live)
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
    private let deadline = DispatchTime.now() + 8
    private(set) var result: SelectedKeyboardResult

    init(simulator: FBSimulator, feed: FBSimulatorHIDNativeFreshnessProvider, request: SelectedKeyboardRequest) {
        self.simulator = simulator
        self.feed = feed
        self.request = request
        result = SelectedKeyboardResult(expectedPID: request.expectedPID, focusID: request.focusID)
    }

    func prepare() async throws {
        result.initialTarget = try await readFocusedField()
    }

    func validateKeyDown(observation: FBSimulatorHIDSessionObservation, keyCode: UInt32) async throws {
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
        let remaining = try remainingSeconds()
        let policy = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: remaining, maximumAttempts: 1)
        let acquisition = try await FBSimulatorAXSnapshot.acquire(for: simulator, expectedPID: request.expectedPID,
            observation: feed.initialObservation, freshnessProvider: feed, policy: policy, preparation: .existingBridge)
        _ = try remainingSeconds()
        guard acquisition.outcome == .ready, let snapshot = acquisition.snapshot else {
            throw SelectedHIDFailure.invalid("Keyboard focus read failed: \(acquisition.outcome.rawValue)")
        }
        let reference = try await snapshot.resolve(.identifier(request.focusID), freshnessProvider: feed)
        try SelectedKeyboardFocusPolicy.validate(reference.node, expectedPID: request.expectedPID, focusID: request.focusID)
        try await snapshot.validate(reference, freshnessProvider: feed)
        _ = try remainingSeconds()
        return reference.node
    }

    private func remainingSeconds() throws -> Double {
        try Task.checkCancellation()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else {
            throw SelectedHIDFailure.invalid("Selected keyboard exceeded its eight-second admission budget")
        }
        return Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }
}
