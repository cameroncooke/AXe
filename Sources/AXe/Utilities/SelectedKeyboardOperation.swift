import Foundation
import FBControlCore
import FBSimulatorControl

/// The common broker lease remains held through every focus read, key release and feed close.
@MainActor
enum SelectedKeyboardOperation {
    static func perform(_ request: SelectedHIDRequest, simulatorUDID: String,
                        brokerID: UUID, logger: AxeLogger,
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
            guard var keyboard = request.keyboard else { throw SelectedHIDFailure.invalid("Missing keyboard payload") }
            try Task.checkCancellation()
            let simulator = try await PhaseTimer.measure("keyboard.simulatorSet") {
                try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
            }
            let display = try request.selectedDisplay()
            let live = try await PhaseTimer.measure("keyboard.liveContextStart") {
                try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator,
                    screenID: display.id, screenUniqueID: display.uuid)
            }
            feed = live
            observation = live.initialObservation
            try request.agentAdmission?.validateContext(live.initialObservation)
            if keyboard.expectedPID == nil {
                // Without --expected-pid, bind the app that is frontmost now; every focus read requires it.
                let pid = try await PhaseTimer.measure("keyboard.frontmostPID") {
                    try await FBSimulatorAXSnapshot.frontmostApplicationPID(for: simulator,
                        observation: live.initialObservation, freshnessProvider: live)
                }
                keyboard = keyboard.bound(to: pid)
                result = SelectedKeyboardResult(expectedPID: pid, focusID: keyboard.focusID)
            }
            _ = try FBSimulatorHIDSession.preflight(keyboard.event, observation: live.initialObservation)
            let focus = try SelectedKeyboardFocusGuard(simulator: simulator, feed: live, request: keyboard, agentAdmission: request.agentAdmission)
            guardOwner = focus
            try await focus.prepare()
            let hid = try await PhaseTimer.measure("keyboard.hidOpen") { () async throws -> FBSimulatorHIDSession in
                if let transportOwner {
                    return try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                        liveFreshnessProvider: live, transportOwner: transportOwner)
                }
                return try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                    liveFreshnessProvider: live)
            }
            session = hid
            // Includes one focused-field read before every key down.
            let receipt = try await PhaseTimer.measure("keyboard.hidExecute") {
                try await hid.execute(keyboard.event, keyboardAdmissionGuard: focus)
            }
            result = focus.result
            count = await hid.status().enqueuedEventCount
            cleanup = try await PhaseTimer.measure("keyboard.hidClose") { try await hid.close().cleanup.rawValue }
            guard cleanup != "uncertain" else { throw SelectedHIDFailure.invalid("Keyboard release is uncertain") }
            await PhaseTimer.measure("keyboard.liveContextClose") { await live.closeAndWait() }
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

/// Read again before the first key down, after a key that can move focus or a delay, and every focus
/// check interval otherwise (16 by default).
/// Key up and cleanup bypass focus admission so owned keys release.
/// AX focus and HID delivery are separate OS operations; this is not an atomic recipient guarantee.
@MainActor
final class SelectedKeyboardFocusGuard: FBSimulatorHIDKeyboardAdmissionGuard {
    private let simulator: FBSimulator
    private let feed: FBSimulatorHIDNativeFreshnessProvider
    private let request: SelectedKeyboardRequest
    private let expectedPID: Int32
    private let agentAdmission: AgentModeAdmission?
    private let deadline: DispatchTime
    private(set) var result: SelectedKeyboardResult
    private let checkedKeyDowns: Set<Int>

    init(simulator: FBSimulator, feed: FBSimulatorHIDNativeFreshnessProvider, request: SelectedKeyboardRequest, agentAdmission: AgentModeAdmission? = nil) throws {
        guard let expectedPID = request.expectedPID, expectedPID > 0 else {
            throw SelectedHIDFailure.invalid("Selected keyboard focus checks require a bound PID")
        }
        self.simulator = simulator
        self.feed = feed
        self.request = request
        self.expectedPID = expectedPID
        self.agentAdmission = agentAdmission
        let requestedDelay = request.events.reduce(0.0) { total, event in
            if case .delay(let seconds) = event { return total + seconds }
            return total
        }
        // Keep the input work allowance, plus time for the focus read before each key down: about
        // 100 ms each on an iOS 27.3 iPhone simulator, so 8 s alone stopped a 256-byte agent type after
        // about 100 characters. Validated explicit waits have their own bound.
        deadline = DispatchTime.now() + (8 + requestedDelay + Self.focusReadAllowance * Double(Self.keyDowns(in: request.events)))
        result = SelectedKeyboardResult(expectedPID: request.expectedPID, focusID: request.focusID)
        checkedKeyDowns = Self.checkedKeyDowns(in: request.events, interval: request.effectiveFocusCheckInterval)
    }

    /// Letters, digits, space, punctuation and Shift only add text; any other key (Return, Tab,
    /// Escape, arrows, Command, Control, Option) can move focus, as can whatever a delay waits for.
    static func onlyAddsText(_ keyCode: UInt32) -> Bool {
        (4...39).contains(keyCode) || (44...56).contains(keyCode) || keyCode == 225 || keyCode == 229
    }

    /// The key downs, numbered from 0, that read the focused field first: the first, every `interval`
    /// after it, and each one after a key that can move focus or after a delay. With a read only every
    /// 16 keys, Return then a 0.3 s wait then "a" sent the "a" after focus had left the field.
    static func checkedKeyDowns(in events: [SelectedKeyboardPrimitive], interval: Int) -> Set<Int> {
        var checked: Set<Int> = []
        let shortcutModifiers: Set<UInt32> = [224, 226, 227, 228, 230, 231]
        var index = 0
        var mayHaveMoved = true
        var heldShortcutModifiers: Set<UInt32> = []
        for event in events {
            switch event {
            case .delay: mayHaveMoved = true
            case .up(let code): heldShortcutModifiers.remove(code)
            case .down(let code):
                if mayHaveMoved || index % interval == 0 { checked.insert(index) }
                // A key pressed with Command, Control or Option held is a shortcut.
                mayHaveMoved = !onlyAddsText(code) || !heldShortcutModifiers.isEmpty
                if shortcutModifiers.contains(code) { heldShortcutModifiers.insert(code) }
                index += 1
            }
        }
        return checked
    }

    /// About three times the measured focus read, for a loaded Mac.
    static let focusReadAllowance = 0.3

    static func keyDowns(in events: [SelectedKeyboardPrimitive]) -> Int {
        events.reduce(0) { count, event in
            if case .down = event { return count + 1 }
            return count
        }
    }

    func prepare() async throws {
        result.initialTarget = try await readFocusedField()
    }

    func validateKeyDown(observation: FBSimulatorHIDSessionObservation, keyCode: UInt32) async throws {
        try agentAdmission?.validateContext(observation)
        guard observation == feed.initialObservation, keyCode <= 255, result.initialTarget != nil else {
            throw SelectedHIDFailure.invalid("Keyboard context or initial field is missing or changed")
        }
        if checkedKeyDowns.contains(result.validatedKeyDownCount) {
            result.lastValidatedTarget = try await readFocusedField()
            result.focusCheckedKeyDownCount = (result.focusCheckedKeyDownCount ?? 0) + 1
        }
        result.validatedKeyDownCount += 1
        guard try JSONEncoder().encode(result).count <= SelectedAXBounds.contentBytes else {
            throw SelectedAXContentError.tooLarge
        }
        _ = try remainingSeconds()
    }

    private func readFocusedField() async throws -> FBSimulatorAXNode {
        try await PhaseTimer.measure("keyboard.focusRead") { try await readFocusedFieldUntimed() }
    }

    private func readFocusedFieldUntimed() async throws -> FBSimulatorAXNode {
        // While a keyboard settles, a walk can meet an element without a native identity yet, or
        // miss the field for one read. That is not a changed field: read again, at most three
        // times 100 ms apart. No key is sent between the reads.
        var attempt = 0
        while true {
            do { return try await readFocusedFieldOnce() }
            catch let error as FBSimulatorAXSnapshotError {
                switch error {
                case .invalidSelection, .notFound:
                    guard attempt < 3 else { throw error }
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(100))
                    _ = try remainingSeconds()
                default: throw error
                }
            }
        }
    }

    private func readFocusedFieldOnce() async throws -> FBSimulatorAXNode {
        // Read a new root and exact field before every down; do not serialize the whole tree.
        let field = try await SelectedKeyboardFocusRead.perform(remainingSeconds: remainingSeconds) { remaining in
            if let identifier = request.fieldTarget.semanticID {
                return try await FBSimulatorAXSnapshot.readFocusedTextField(for: simulator,
                    expectedPID: expectedPID, identifier: identifier,
                    observation: feed.initialObservation, liveFreshnessProvider: feed, timeoutSeconds: remaining)
            }
            guard let identity = request.fieldTarget.nativeIdentity else {
                throw SelectedHIDFailure.invalid("Selected keyboard field identity is unavailable")
            }
            return try await FBSimulatorAXSnapshot.readFocusedTextField(for: simulator,
                expectedPID: expectedPID, identity: identity,
                observation: feed.initialObservation, liveFreshnessProvider: feed, timeoutSeconds: remaining)
        }
        _ = try remainingSeconds()
        let logicalSize = feed.initialObservation.displayContext.logicalSize
        let target: AgentModeTarget?
        if let admitted = agentAdmission?.target { target = admitted }
        else if let initial = result.initialTarget { target = try AgentModeTarget(initial, nativeTarget: request.fieldTarget) }
        else { target = nil }
        if let target {
            try SelectedKeyboardEditingTargetPolicy.validate(field, against: target,
                expectedPID: expectedPID, fieldTarget: request.fieldTarget, logicalSize: logicalSize,
                editingStarted: result.validatedKeyDownCount > 0, allowingMove: agentAdmission?.fieldMayMove == true)
        } else {
            try SelectedKeyboardEditingTargetPolicy.validateCurrentField(field,
                expectedPID: expectedPID, fieldTarget: request.fieldTarget, logicalSize: logicalSize)
        }
        _ = try remainingSeconds()
        return field
    }

    private func remainingSeconds() throws -> Double {
        try Task.checkCancellation()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else {
            throw SelectedHIDFailure.invalid("Selected keyboard exceeded its input allowance (8 s plus 0.3 s a key) and requested delays")
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
