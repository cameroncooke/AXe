import Foundation
import FBSimulatorControl

struct SelectedHIDRequest: Codable, Sendable {
    static let version = 91
    enum Operation: String, Codable, Sendable { case complete, begin, move, end, close }

    /// What a request asks the owner to do. A request carries exactly one, so a mixed request
    /// cannot be built or decoded.
    enum Payload: Codable, Sendable {
        /// Touch primitives for a complete, begin, move or end operation; none for close.
        case contact([SelectedHIDPrimitive])
        case path(SelectedHIDPath)
        case pinch(SelectedHIDPinch)
        case gesture(SelectedHIDCompleteGesture)
        case ax(SelectedAXRequest)
        case hinge(SelectedHingeRequest)
        case keyboard(SelectedKeyboardRequest)
        case button(SelectedButtonRequest)
        case rotation(SelectedRotationRequest)
        /// An agent action. A complete coordinate action also carries its path or its primitives.
        case agent(AgentModeRequest, path: SelectedHIDPath? = nil, primitives: [SelectedHIDPrimitive] = [])
        case agentBatch(AgentBatchRequest)
        case ordinaryTouch(OrdinaryBrokerTouch)
        case ordinaryKeyboard(OrdinaryBrokerKeyboard)
        /// No input: tells an idle broker a client still needs it, so it does not shut down.
        /// `axe serve` sends it while waiting for its next command.
        case keepAlive
    }

    // Header: which protocol, which request, which screen and which contact.
    let version: Int
    let requestID: UUID
    var screenID: UInt32?
    var screenUUID: UUID?
    /// Selected input without an explicit pair: the broker binds the screen that is active when it
    /// admits the request, then clears this flag. Every later check uses the bound pair.
    var activeDisplay: Bool? = nil
    let operation: Operation
    let token: UUID?
    var payload: Payload
    var includeReadingContinuation: Bool? = nil
    var agentAdmission: AgentModeAdmission? = nil
    var expectedContext: SelectedHIDContext? = nil
    /// Diagnostic only. Asks the broker to return its phase timings with the response.
    var timing: Bool? = nil
    /// A plain command whose screen the broker binds, as it does for selected input, instead of the
    /// client measuring it first: that measurement loads the simulator set in every command, about
    /// 80 ms. The broker serves it only on a simulator whose plain input uses the shared owner, and
    /// the payload keeps the plain route's events.
    var plainRoute: Bool? = nil

    // Read-only views of the payload, for code that handles one kind.
    var primitives: [SelectedHIDPrimitive] {
        switch payload {
        case .contact(let primitives), .agent(_, _, let primitives): return primitives
        default: return []
        }
    }
    var path: SelectedHIDPath? {
        switch payload {
        case .path(let path): return path
        case .agent(_, let path, _): return path
        default: return nil
        }
    }
    var pinch: SelectedHIDPinch? { if case .pinch(let value) = payload { return value }; return nil }
    var gesture: SelectedHIDCompleteGesture? { if case .gesture(let value) = payload { return value }; return nil }
    var ax: SelectedAXRequest? { if case .ax(let value) = payload { return value }; return nil }
    var hinge: SelectedHingeRequest? { if case .hinge(let value) = payload { return value }; return nil }
    var keyboard: SelectedKeyboardRequest? { if case .keyboard(let value) = payload { return value }; return nil }
    var button: SelectedButtonRequest? { if case .button(let value) = payload { return value }; return nil }
    var rotation: SelectedRotationRequest? { if case .rotation(let value) = payload { return value }; return nil }
    var agent: AgentModeRequest? { if case .agent(let value, _, _) = payload { return value }; return nil }
    var agentBatch: AgentBatchRequest? { if case .agentBatch(let value) = payload { return value }; return nil }
    var ordinaryTouch: OrdinaryBrokerTouch? { if case .ordinaryTouch(let value) = payload { return value }; return nil }
    var ordinaryKeyboard: OrdinaryBrokerKeyboard? { if case .ordinaryKeyboard(let value) = payload { return value }; return nil }
    var isKeepAlive: Bool { if case .keepAlive = payload { return true }; return false }

    /// The same agent action on a new snapshot and reference, for a retry after the screen moved on.
    /// Any other request is returned unchanged.
    func retargeted(snapshotID: UUID, ref: String) -> SelectedHIDRequest {
        var request = self
        request.updateAgent { $0.snapshotID = snapshotID; $0.ref = ref }
        return request
    }

    /// Changes the agent action in place, keeping its coordinates. Any other request is left alone.
    mutating func updateAgent(_ change: (inout AgentModeRequest) -> Void) {
        guard case .agent(var agent, let path, let primitives) = payload else { return }
        change(&agent)
        payload = .agent(agent, path: path, primitives: primitives)
    }

    private var isComplete: Bool { operation == .complete && token == nil }
    private var hasScreenPair: Bool { screenID != nil && screenUUID != nil }

    func validate() throws {
        guard version == Self.version else { throw SelectedHIDFailure.invalid("Protocol version mismatch") }
        if isKeepAlive {
            guard isComplete, screenID == nil, screenUUID == nil, activeDisplay == nil, expectedContext == nil,
                  agentAdmission == nil, plainRoute == nil else {
                throw SelectedHIDFailure.invalid("A keep-alive request carries no screen, context or input")
            }
            return
        }
        if activeDisplay != nil {
            let bindsAScreen: Bool
            switch payload {
            case .agent, .agentBatch, .hinge, .ordinaryTouch, .ordinaryKeyboard: bindsAScreen = false
            default: bindsAScreen = true
            }
            guard activeDisplay == true, screenID == nil, screenUUID == nil, expectedContext == nil,
                  agentAdmission == nil, bindsAScreen else {
                throw SelectedHIDFailure.invalid("Active-display binding applies only to selected input without a screen pair")
            }
        }
        if includeReadingContinuation == true, agentBatch == nil, agent?.rowLimit != 64 {
            throw AgentModeFailure("invalidReadingContinuation", "A reading continuation requires a default-size agent capture.")
        }
        if case .agentBatch(let batch) = payload {
            try batch.validate()
            guard isComplete, screenID == nil, screenUUID == nil, agentAdmission == nil, expectedContext == nil else {
                throw AgentModeFailure("mixedBatchPayload", "Agent batch cannot contain other action, display, reference or retained-input payloads.")
            }
            return
        }
        // Ordinary input is measured by the client; the owner checks it against that measurement.
        let ordinary: Bool
        switch payload {
        case .path(let path): ordinary = path.generator == .ordinary
        case .ordinaryTouch, .ordinaryKeyboard: ordinary = true
        default: ordinary = false
        }
        if let plainRoute {
            let plainPayload: Bool
            switch payload {
            case .contact(let primitives): plainPayload = !primitives.isEmpty
            case .path(let path): plainPayload = path.generator == .ordinary
            default: plainPayload = false
            }
            guard plainRoute, isComplete, plainPayload, expectedContext == nil, agentAdmission == nil,
                  activeDisplay == true || (screenID != nil && screenUUID != nil) else {
                throw SelectedHIDFailure.invalid("A broker-bound plain request is one complete tap, touch or ordinary path")
            }
        }
        if ordinary, expectedContext == nil, plainRoute != true {
            throw SelectedHIDFailure.invalid("Legacy Duo input requires a measured expected context")
        }
        if let expectedContext {
            let measured: Bool
            if case .contact(let primitives) = payload { measured = !primitives.isEmpty } else { measured = ordinary }
            guard isComplete, measured, agentAdmission == nil,
                  expectedContext.screenID == screenID,
                  UUID(uuidString: expectedContext.screenUUID) == screenUUID else {
                throw SelectedHIDFailure.invalid("Expected context requires one primitive, ordinary path, legacy touch or legacy keyboard request on its measured display")
            }
            try expectedContext.validate()
        }
        if case .agent(let agent, let path, let primitives) = payload {
            try agent.validate()
            guard agentAdmission == nil, isComplete, (screenID == nil) == (screenUUID == nil) else {
                throw AgentModeFailure("mixedPayload", "Agent input requires one complete request without native action payloads.")
            }
            if agent.kind == .complete {
                guard path != nil || !primitives.isEmpty else {
                    throw AgentModeFailure("missingCompletePayload", "A complete coordinate action requires its existing path or primitives.")
                }
                try path?.validate()
                guard primitives.count <= 1024 else { throw AgentModeFailure("inputTooLarge", "Too many coordinate primitives.") }
                for primitive in primitives { try primitive.validate() }
            } else if path != nil || !primitives.isEmpty {
                throw AgentModeFailure("mixedPayload", "Agent reference actions cannot contain coordinate primitives.")
            }
            return
        }
        if ax?.kind == .hold, agentAdmission?.target == nil {
            throw AgentModeFailure("missingHoldAdmission", "A reference hold requires fresh agent target admission.")
        }
        if ax?.kind == .doubleTap, agentAdmission?.target == nil {
            throw AgentModeFailure("missingDoubleTapAdmission", "A reference double-tap requires fresh agent target admission.")
        }
        if let agentAdmission {
            let admitsNativeInput: Bool
            switch payload {
            case .hinge, .rotation, .button, .gesture: admitsNativeInput = false
            default: admitsNativeInput = true
            }
            guard isComplete, agentAdmission.expectedPID > 0,
                  agentAdmission.context.screenID == screenID,
                  UUID(uuidString: agentAdmission.context.screenUUID) == screenUUID, admitsNativeInput else {
                throw AgentModeFailure("invalidAdmission", "Agent native admission does not match this complete request.")
            }
            if pinch != nil {
                guard agentAdmission.target != nil,
                      agentAdmission.selectorKind == .id || agentAdmission.selectorKind == .label,
                      agentAdmission.selectorValue != nil else {
                    throw AgentModeFailure("missingPinchAdmission", "A reference pinch requires fresh agent area admission.")
                }
            }
        }
        if case .hinge(let hinge) = payload {
            guard isComplete, screenID == nil, screenUUID == nil else {
                throw SelectedHIDFailure.invalid("Hinge requires one device operation without screen, AX, path, pinch or contact fields")
            }
            try hinge.validate()
            return
        }
        guard hasScreenPair || activeDisplay == true else {
            throw SelectedHIDFailure.invalid("Selected screen operations require both screen ID and UUID, or the active screen")
        }
        switch payload {
        case .agent, .agentBatch, .hinge, .keepAlive:
            return      // handled above
        case .ordinaryTouch(let touch):
            try touch.validate()
        case .ordinaryKeyboard(let keyboard):
            try keyboard.validate()
        case .rotation(let rotation):
            guard isComplete else { throw SelectedHIDFailure.invalid("Rotation requires one complete operation without contact fields") }
            try rotation.validate()
        case .button(let button):
            guard isComplete else { throw SelectedHIDFailure.invalid("Button requires one complete operation without a token or primitive payload") }
            try button.validate()
        case .keyboard(let keyboard):
            guard isComplete else { throw SelectedHIDFailure.invalid("Keyboard requires one complete operation without a contact token or touch primitives") }
            try keyboard.validate()
        case .ax(let ax):
            guard isComplete else { throw SelectedHIDFailure.invalid("AX requires one complete operation without a token, primitives, path or pinch") }
            try ax.validate()
        case .path(let path):
            guard isComplete else { throw SelectedHIDFailure.invalid("A path requires one complete event and no primitive payload, pinch or token") }
            try path.validate()
        case .pinch(let pinch):
            guard isComplete else { throw SelectedHIDFailure.invalid("Pinch requires one complete event without primitives or a retained token") }
            try pinch.validate()
        case .gesture(let gesture):
            guard isComplete else { throw SelectedHIDFailure.invalid("A complete gesture cannot contain primitives or a retained token") }
            try gesture.validate()
        case .contact(let primitives):
            try Self.validate(contact: primitives, operation: operation, token: token)
        }
    }

    private static func validate(contact primitives: [SelectedHIDPrimitive], operation: Operation, token: UUID?) throws {
        guard !primitives.isEmpty || operation == .close, primitives.count <= 1024 else {
            throw SelectedHIDFailure.invalid("Invalid primitive count")
        }
        var duration = 0.0
        for primitive in primitives {
            try primitive.validate()
            duration += primitive.duration ?? 0
        }
        guard duration <= 20 else { throw SelectedHIDFailure.invalid("Total delay exceeds 20 seconds") }
        switch operation {
        case .complete:
            guard token == nil else { throw SelectedHIDFailure.invalid("Complete events cannot use a contact token") }
        case .begin:
            guard token == nil, primitives.count == 1, primitives[0].kind == .down else {
                throw SelectedHIDFailure.invalid("Begin requires one down and no token")
            }
        case .move, .end:
            guard token != nil, primitives.count == 1, primitives[0].kind == .down else {
                throw SelectedHIDFailure.invalid("Move/end requires one point and a contact token")
            }
        case .close:
            guard token != nil, primitives.isEmpty else { throw SelectedHIDFailure.invalid("Close requires a token and no points") }
        }
    }

    func selectedDisplay() throws -> (id: UInt32, uuid: UUID) {
        guard hinge == nil, let screenID, let screenUUID else {
            throw SelectedHIDFailure.invalid("Missing selected display")
        }
        return (screenID, screenUUID)
    }

    var event: FBSimulatorHIDEvent { .composite(primitives.map(\.event)) }
    func completeEvent(observation: FBSimulatorHIDSessionObservation) throws -> FBSimulatorHIDEvent {
        try validate()
        guard keyboard == nil, rotation == nil, ordinaryTouch == nil, ordinaryKeyboard == nil else { throw SelectedHIDFailure.invalid("Keyboard, rotation and legacy input require separate admission") }
        if let button { return try button.event(observation: observation) }
        if let pinch { return try pinch.event(observation: observation) }
        if let gesture { return try gesture.event(observation: observation) }
        return try completeEvent(logicalSize: observation.displayContext.logicalSize)
    }

    func completeEvent(logicalSize: CGSize) throws -> FBSimulatorHIDEvent {
        guard pinch == nil, gesture == nil, keyboard == nil, button == nil, rotation == nil, ordinaryTouch == nil, ordinaryKeyboard == nil else { throw SelectedHIDFailure.invalid("Complete gestures require a fresh selected observation") }
        guard let path else { return event }
        return try path.event(logicalSize: logicalSize)
    }
}

struct SelectedHIDPrimitive: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case down, up, delay }
    let kind: Kind
    let x: Double?
    let y: Double?
    let duration: Double?
    static func touch(_ kind: Kind, x: Double, y: Double) -> Self { Self(kind: kind, x: x, y: y, duration: nil) }
    static func delay(_ seconds: Double) -> Self { Self(kind: .delay, x: nil, y: nil, duration: seconds) }
    func validate() throws {
        switch kind {
        case .down, .up:
            guard let x, let y, x.isFinite, y.isFinite, x >= 0, y >= 0, duration == nil else {
                throw SelectedHIDFailure.invalid("Touch requires finite non-negative coordinates only")
            }
        case .delay:
            guard let duration, duration.isFinite, duration >= 0, duration <= 10, x == nil, y == nil else {
                throw SelectedHIDFailure.invalid("Delay must be finite and in 0...10 seconds")
            }
        }
    }
    var point: CGPoint { CGPoint(x: x ?? 0, y: y ?? 0) }
    var event: FBSimulatorHIDEvent {
        switch kind {
        case .down: return .touch(direction: .down, x: x!, y: y!)
        case .up: return .touch(direction: .up, x: x!, y: y!)
        case .delay: return .delay(duration!)
        }
    }
}

struct SelectedHIDQuarantine: Codable, Sendable {
    let recordPath: String?
    let persisted: Bool
    let error: String?
}

struct SelectedHIDResponse: Codable, Sendable {
    let version: Int
    let requestID: UUID
    let brokerID: UUID
    let outcome: String
    let token: UUID?
    let enqueuedEventCount: Int
    let cleanup: String
    var error: String?
    let context: SelectedHIDContext?
    /// The documented code of a coded refusal; `error` then holds its readable message.
    var errorCode: String? = nil
    var ax: SelectedAXResult? = nil
    var quarantine: SelectedHIDQuarantine? = nil
    var hinge: SelectedHingeResult? = nil
    var keyboard: SelectedKeyboardResult? = nil
    var button: SelectedButtonResult? = nil
    var rotation: SelectedRotationResult? = nil
    var agent: AgentModeResult? = nil
    var readingContinuation: AgentModeCapture? = nil
    /// Present only when the request set `timing`. Dropped first when a response is too large.
    var timing: PhaseTimingPayload? = nil
}

struct SelectedHIDContext: Codable, Sendable, Equatable {
    let bootIdentity: String
    let screenID: UInt32
    let screenUUID: String
    let logicalWidth: Double
    let logicalHeight: Double
    let rotationDegrees: Int
    let nativePixelWidth: Double
    let nativePixelHeight: Double
    let scale: Double
    let poseRevision: String
    init(_ value: FBSimulatorHIDSessionObservation) {
        bootIdentity = value.bootIdentity; screenID = value.screenID; screenUUID = value.screenUniqueID
        logicalWidth = value.displayContext.logicalSize.width; logicalHeight = value.displayContext.logicalSize.height
        rotationDegrees = value.displayContext.rotation.rawValue
        nativePixelWidth = value.displayContext.nativePixelSize.width
        nativePixelHeight = value.displayContext.nativePixelSize.height
        scale = value.displayContext.scale
        poseRevision = value.poseRevision
    }

    func validate() throws {
        guard !bootIdentity.isEmpty, bootIdentity.utf8.count <= 256,
              !poseRevision.isEmpty, poseRevision.utf8.count <= 4096,
              UUID(uuidString: screenUUID) != nil,
              let rotation = FBSimulatorHIDDisplayRotation(rawValue: rotationDegrees) else {
            throw SelectedHIDFailure.invalid("Invalid expected input context identity or rotation")
        }
        let display = try FBSimulatorHIDDisplayContext(
            hidTarget: UInt64(screenID),
            nativePixelSize: CGSize(width: nativePixelWidth, height: nativePixelHeight),
            scale: scale, rotation: rotation
        )
        guard display.logicalSize == CGSize(width: logicalWidth, height: logicalHeight) else {
            throw SelectedHIDFailure.invalid("Expected input context has inconsistent logical geometry")
        }
    }
}

enum SelectedHIDFailure: Error, LocalizedError {
    case invalid(String)
    case busy
    case invalidToken
    case selectionChanged
    /// A refusal before input with its own documented error code, such as `invalidArguments`.
    /// The broker sends the code and message as separate reply fields.
    case coded(code: String, message: String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .coded(_, let message): return message
        case .busy: return "Simulator input is owned by another action or retained contact"
        case .invalidToken: return "Retained contact token is absent, expired or belongs to another broker"
        case .selectionChanged: return "Retained contact cannot change its selected display"
        }
    }
}

/// Value-state admission is checked before any asynchronous work.
struct SelectedHIDAdmission {
    enum Origin { case selected, ordinaryTouch }
    private(set) var inFlight = false
    private(set) var token: UUID?
    private(set) var screenID: UInt32?
    private(set) var screenUUID: UUID?
    private(set) var origin: Origin?
    mutating func enter(_ request: SelectedHIDRequest) throws {
        try request.validate()
        guard !inFlight else { throw SelectedHIDFailure.busy }
        if let token {
            if origin == .ordinaryTouch {
                guard request.ordinaryTouch != nil, request.token == nil else { throw SelectedHIDFailure.busy }
            } else {
                guard request.ordinaryTouch == nil, request.token == token else { throw SelectedHIDFailure.busy }
            }
            guard request.screenID == screenID, request.screenUUID == screenUUID else { throw SelectedHIDFailure.selectionChanged }
        } else if request.token != nil { throw SelectedHIDFailure.invalidToken }
        inFlight = true
    }
    mutating func retain(_ request: SelectedHIDRequest, token: UUID, origin: Origin = .selected) {
        self.token = token; screenID = request.screenID; screenUUID = request.screenUUID
        self.origin = origin
    }
    mutating func finish() { inFlight = false }
    mutating func clear() { token = nil; screenID = nil; screenUUID = nil; origin = nil }
}
