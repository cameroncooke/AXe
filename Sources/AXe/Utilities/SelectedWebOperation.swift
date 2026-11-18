import Foundation
import FBControlCore
import FBSimulatorControl

/// A tap on, or typing into, one control of a hosted web page. The page runs in its own
/// WebContent process, so the app-process target checks do not apply; instead the element at
/// the control's tap point is read again before the first touch and before every key down, and
/// must be that control, with the same app in front. Web elements report `AXFocused` as true
/// whether or not they hold focus, so focus is not read here: the caller taps the field first.
@MainActor
enum SelectedWebOperation {
    static func perform(_ request: SelectedHIDRequest, ax: SelectedAXRequest, simulator: FBSimulator,
                        display: (id: UInt32, uuid: UUID), brokerID: UUID,
                        transportOwner: FBSimulatorHIDTransportOwner?) async -> SelectedHIDResponse {
        var result = SelectedAXResult(kind: ax.kind, expectedPID: ax.expectedPID)
        var observation: FBSimulatorHIDSessionObservation?
        var feed: FBSimulatorHIDNativeFreshnessProvider?
        var session: FBSimulatorHIDSession?
        var inputGuard: SelectedWebInputGuard?
        var count = 0
        var cleanup = "notNeeded"
        do {
            try ax.validate()
            guard let pid = ax.expectedPID, let target = ax.webTarget, let point = ax.point else {
                throw SelectedHIDFailure.invalid("Web input requires the app's PID, a web control and a point")
            }
            let live = try await PhaseTimer.measure("web.liveContextStart") {
                try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator,
                    screenID: display.id, screenUniqueID: display.uuid)
            }
            feed = live
            observation = live.initialObservation
            try SelectedAXBounds.validateContext(SelectedHIDContext(live.initialObservation))
            try request.agentAdmission?.validateContext(live.initialObservation)
            let location = CGPoint(x: point.x, y: point.y)
            let event: FBSimulatorHIDEvent
            if ax.kind == .webType {
                guard let keyEvents = ax.keyEvents else { throw SelectedHIDFailure.invalid("Missing web key events") }
                event = .composite(keyEvents.map(\.event))
            } else {
                event = .tapAt(x: location.x, y: location.y)
            }
            _ = try FBSimulatorHIDSession.preflight(event, observation: live.initialObservation)
            let owner = SelectedWebInputGuard(simulator: simulator, feed: live, expectedPID: pid,
                target: target, point: location, exact: ax.kind == .webType, covered: ax.webFieldCovered == true,
                allowance: SelectedWebInputGuard.allowance(ax.keyEvents ?? []))
            inputGuard = owner
            if ax.kind == .webType {
                // Typing checks the focused field before opening input, as native typing does.
                try await owner.prepare()
            }
            let hid = try await PhaseTimer.measure("web.hidOpen") { () async throws -> FBSimulatorHIDSession in
                if let transportOwner {
                    return try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                        liveFreshnessProvider: live, transportOwner: transportOwner)
                }
                return try await FBSimulatorHIDSession.open(for: simulator, observation: live.initialObservation,
                    liveFreshnessProvider: live)
            }
            session = hid
            let receipt = try await PhaseTimer.measure("web.hidExecute") { () async throws -> FBSimulatorHIDSessionReceipt in
                if ax.kind == .webType { return try await hid.execute(event, keyboardAdmissionGuard: owner) }
                return try await hid.execute(event, admissionGuard: owner)
            }
            result.webElement = owner.verified
            count = await hid.status().enqueuedEventCount
            cleanup = try await PhaseTimer.measure("web.hidClose") { try await hid.close().cleanup.rawValue }
            session = nil
            guard cleanup != "uncertain" else { throw SelectedHIDFailure.invalid("Web input cleanup is uncertain") }
            await PhaseTimer.measure("web.liveContextClose") { await live.closeAndWait() }
            feed = nil
            return response(request, brokerID: brokerID, result: result, observation: observation,
                outcome: receipt.outcome.rawValue, count: count, cleanup: cleanup, error: nil)
        } catch {
            result.webElement = inputGuard?.verified
            if let session {
                count = await session.status().enqueuedEventCount
                do { cleanup = try await session.close().cleanup.rawValue }
                catch { cleanup = "uncertain" }
            }
            await feed?.closeAndWait()
            if cleanup == "uncertain" { result.failure = .cleanupUncertain }
            else if count > 0 { result.failure = .inputFailed }
            else { result.failure = .targetRejected }
            let outcome = count == 0 && cleanup == "notNeeded" ? "failedBeforeInput" : "failedNoReplay"
            var failed = response(request, brokerID: brokerID, result: result, observation: observation,
                outcome: outcome, count: count, cleanup: cleanup,
                error: (error as? AgentModeFailure)?.message ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription)
            // A refusal before input keeps its typed code for the agent reply.
            let policy = error as? AgentModeFailure ?? inputGuard?.refusal
            if outcome == "failedBeforeInput", let policy {
                failed.agent = AgentModeResult(error: policy,
                    cache: AgentModeCacheState(status: "invalidated", reason: policy.code, requiresRefresh: true),
                    context: failed.context)
            }
            return failed
        }
    }

    private static func response(_ request: SelectedHIDRequest, brokerID: UUID, result: SelectedAXResult,
                                 observation: FBSimulatorHIDSessionObservation?, outcome: String, count: Int,
                                 cleanup: String, error: String?) -> SelectedHIDResponse {
        SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID, brokerID: brokerID,
            outcome: outcome, token: nil, enqueuedEventCount: count, cleanup: cleanup, error: error,
            context: observation.map(SelectedHIDContext.init), ax: result)
    }
}

/// Reads the element at the web control's point before the first touch and before every key
/// down. AX state and HID delivery are separate OS operations; this is not an atomic guarantee.
@MainActor
final class SelectedWebInputGuard: FBSimulatorHIDInputAdmissionGuard, FBSimulatorHIDKeyboardAdmissionGuard {
    private let simulator: FBSimulator
    private let feed: FBSimulatorHIDNativeFreshnessProvider
    private let expectedPID: Int32
    private let target: FBSimulatorAXNode
    private let point: CGPoint
    /// Typing needs the field itself at the point, not text inside it.
    private let exact: Bool
    /// The keyboard covers the field: only the app in front is checked.
    private let covered: Bool
    private let deadline: DispatchTime
    private(set) var verified: FBSimulatorAXNode?
    private(set) var validatedKeyDownCount = 0
    /// The typed refusal behind the last failed check, kept for the agent reply.
    private(set) var refusal: AgentModeFailure?

    init(simulator: FBSimulator, feed: FBSimulatorHIDNativeFreshnessProvider, expectedPID: Int32,
         target: FBSimulatorAXNode, point: CGPoint, exact: Bool, covered: Bool = false,
         allowance: Double = SelectedWebInputGuard.baseAllowance) {
        self.simulator = simulator; self.feed = feed; self.expectedPID = expectedPID
        self.target = target; self.point = point; self.exact = exact; self.covered = covered
        deadline = DispatchTime.now() + allowance
    }

    /// The input work allowance of a tap, as native input has.
    nonisolated static let baseAllowance: Double = 8
    /// Each key down reads the element at the field's point first (about 70 ms on an iPhone 18
    /// Pro simulator); this leaves twice that.
    nonisolated static let perKeyAllowance: Double = 0.15

    /// The base allowance, the waits the request asked for, and time for each key's point read.
    nonisolated static func allowance(_ events: [SelectedKeyboardPrimitive]) -> Double {
        events.reduce(baseAllowance) { total, event in
            switch event {
            case .delay(let seconds): return total + max(0, seconds)
            case .down: return total + perKeyAllowance
            case .up: return total
            }
        }
    }

    func prepare() async throws { verified = try await read() }

    /// Keys are checked at the centre of the field's visible part: typing can bring up a control
    /// at the field's right end, where the focus tap landed (a search field's Clear button).
    private var keyCheckPoint: CGPoint {
        let size = feed.initialObservation.displayContext.logicalSize
        guard let frame = target.frame, let centre = FBAXWebControlPolicy.tapPoint(frame: frame,
                screen: CGRect(origin: .zero, size: size)) else { return point }
        return centre
    }

    func validate(observation: FBSimulatorHIDSessionObservation, firstEvent: FBSimulatorHIDEvent) async throws {
        guard observation == feed.initialObservation else { throw AgentModeFailure.contextChangedBeforeInput }
        guard case let .touch(.down, x, y) = firstEvent, x == point.x, y == point.y else {
            throw SelectedHIDFailure.invalid("A web tap must start with its own touch down")
        }
        verified = try await read()
    }

    func validateKeyDown(observation: FBSimulatorHIDSessionObservation, keyCode: UInt32) async throws {
        guard observation == feed.initialObservation, keyCode <= 255, verified != nil else {
            throw AgentModeFailure.contextChangedBeforeInput
        }
        verified = try await read()
        validatedKeyDownCount += 1
    }

    private func read() async throws -> FBSimulatorAXNode {
        try Task.checkCancellation()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else {
            throw SelectedHIDFailure.invalid("Web input exceeded its time allowance")
        }
        let remaining = Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
        if covered {
            let pid = try await PhaseTimer.measure("web.frontmostRead") {
                try await FBSimulatorAXSnapshot.frontmostApplicationPID(for: simulator,
                    observation: feed.initialObservation, freshnessProvider: feed)
            }
            guard pid == expectedPID else {
                let failure = AgentModeFailure("contextChanged", "Another app is now in front, so nothing more was typed. \(AgentModeFailure.actFromCapture)")
                refusal = failure
                throw failure
            }
            return target
        }
        do {
            let at = exact ? keyCheckPoint : point
            let node = try await PhaseTimer.measure("web.pointRead") {
                try await FBSimulatorAXSnapshot.webElement(at: at, for: simulator, expectedPID: expectedPID,
                    observation: feed.initialObservation, freshnessProvider: feed, timeoutSeconds: min(4, remaining))
            }
            // While typing, the field proved before the first key is followed by its identity:
            // a label taken from a placeholder changes once text goes in.
            if exact, let anchor = verified, SelectedWebTargetPolicy.sameElement(node, anchor) { return node }
            try SelectedWebTargetPolicy.validate(node, target: target, exact: exact)
            return node
        } catch let failure as AgentModeFailure {
            refusal = failure
            throw failure
        } catch FBSimulatorAXWebError.notWebContent {
            let failure = AgentModeFailure("targetCovered", "Something else now covers that web control, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            refusal = failure
            throw failure
        }
    }
}

/// Whether the element read at a web control's tap point is still that control.
enum SelectedWebTargetPolicy {
    static func validate(_ hit: FBSimulatorAXNode, target: FBSimulatorAXNode, exact: Bool) throws {
        guard let identity = target.nativeIdentity, hit.pid == identity.pid else {
            throw AgentModeFailure("targetCovered", "Something else now covers that web control, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        // A point read and a tree read can name the same web element with different object IDs,
        // so the same role, label and frame in the same process is the same control too.
        if hit.nativeIdentity == identity || sameControl(hit, target) {
            // Typing changes a field's value, so the value is not compared.
            guard sameRole(hit, target), hit.label == target.label,
                  hit.enabled != false, hit.hidden != true else {
                throw AgentModeFailure("targetChanged", "That web control changed after this snapshot was taken, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            }
            return
        }
        // The container the web read found answering at this control's point (a heading around
        // a link) is still the control, for a tap.
        if !exact, let answer = target.webTapAnswer, hit.nativeIdentity == answer,
           hit.enabled != false, hit.hidden != true {
            return
        }
        // Text or an image inside the control answers a hit inside it; anything else covers it.
        guard !exact, let hitFrame = hit.frame, let frame = target.frame,
              hitFrame.width > 0, hitFrame.height > 0,
              frame.insetBy(dx: -1, dy: -1).contains(hitFrame),
              !AgentWebControls.isControl(hit) else {
            throw AgentModeFailure("targetCovered", "Something else now covers that web control, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
    }

    /// WebKit can answer a point read on a link with a button for the same element (same
    /// label and frame, another object ID); either is tapped the same way.
    static func sameRole(_ hit: FBSimulatorAXNode, _ target: FBSimulatorAXNode) -> Bool {
        if hit.role == target.role { return hit.type == target.type }
        let pressable: Set<String> = ["AXLink", "AXButton"]
        return hit.role.map(pressable.contains) == true && target.role.map(pressable.contains) == true
    }

    /// The same native element, with the same role, still enabled and shown; its label may differ.
    static func sameElement(_ hit: FBSimulatorAXNode, _ anchor: FBSimulatorAXNode) -> Bool {
        guard let identity = anchor.nativeIdentity, hit.nativeIdentity == identity else { return false }
        return sameRole(hit, anchor) && hit.enabled != false && hit.hidden != true
    }

    static func sameControl(_ hit: FBSimulatorAXNode, _ target: FBSimulatorAXNode) -> Bool {
        guard hit.pid == target.pid, sameRole(hit, target), hit.label == target.label,
              let left = hit.frame, let right = target.frame else { return false }
        return abs(left.minX - right.minX) <= 1 && abs(left.minY - right.minY) <= 1
            && abs(left.width - right.width) <= 1 && abs(left.height - right.height) <= 1
    }
}

extension AgentModeFailure {
    static let contextChangedBeforeInput = AgentModeFailure("contextChanged", "The simulator display changed before input, so nothing was sent. \(AgentModeFailure.actFromCapture)")
}

