import Foundation
import FBSimulatorControl

struct SelectedHIDRequest: Codable, Sendable {
    static let version = 33
    enum Operation: String, Codable, Sendable { case complete, begin, move, end, close }
    let version: Int
    let requestID: UUID
    let screenID: UInt32?
    let screenUUID: UUID?
    let operation: Operation
    let token: UUID?
    let primitives: [SelectedHIDPrimitive]
    var path: SelectedHIDPath? = nil
    var pinch: SelectedHIDPinch? = nil
    var gesture: SelectedHIDCompleteGesture? = nil
    var ax: SelectedAXRequest? = nil
    var hinge: SelectedHingeRequest? = nil
    var keyboard: SelectedKeyboardRequest? = nil
    var home: SelectedHomeRequest? = nil
    var button: SelectedButtonRequest? = nil
    var rotation: SelectedRotationRequest? = nil
    var agent: AgentModeRequest? = nil
    var agentBatch: AgentBatchRequest? = nil
    var agentAdmission: AgentModeAdmission? = nil
    var expectedContext: SelectedHIDContext? = nil
    var legacyPath: LegacyDuoPath? = nil
    var legacyTouch: LegacyDuoTouch? = nil

    func validate() throws {
        guard version == Self.version else { throw SelectedHIDFailure.invalid("Protocol version mismatch") }
        if let agentBatch {
            try agentBatch.validate()
            guard operation == .complete, token == nil, screenID == nil, screenUUID == nil,
                  primitives.isEmpty, path == nil, pinch == nil, gesture == nil, ax == nil,
                  hinge == nil, keyboard == nil, home == nil, button == nil, rotation == nil,
                  agent == nil, agentAdmission == nil, expectedContext == nil,
                  legacyPath == nil, legacyTouch == nil else {
                throw AgentModeFailure("mixedBatchPayload", "Agent batch cannot contain other action, display, reference or retained-input payloads.")
            }
            return
        }
        if legacyPath != nil || legacyTouch != nil, expectedContext == nil {
            throw SelectedHIDFailure.invalid("Legacy Duo input requires a measured expected context")
        }
        if let expectedContext {
            guard operation == .complete, token == nil,
                  [!primitives.isEmpty, legacyPath != nil, legacyTouch != nil].filter({ $0 }).count == 1,
                  path == nil, pinch == nil, gesture == nil, ax == nil, hinge == nil,
                  keyboard == nil, home == nil, button == nil, rotation == nil,
                  agent == nil, agentAdmission == nil,
                  expectedContext.screenID == screenID,
                  UUID(uuidString: expectedContext.screenUUID) == screenUUID else {
                throw SelectedHIDFailure.invalid("Expected context requires one primitive, legacy path or legacy touch request on its measured display")
            }
            try expectedContext.validate()
        }
        if let agent {
            try agent.validate()
            guard agentAdmission == nil, operation == .complete, token == nil,
                  (screenID == nil) == (screenUUID == nil), ax == nil, keyboard == nil,
                  hinge == nil, rotation == nil, home == nil, button == nil, pinch == nil, gesture == nil else {
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
            guard operation == .complete, token == nil, agentAdmission.expectedPID > 0,
                  agentAdmission.context.screenID == screenID,
                  UUID(uuidString: agentAdmission.context.screenUUID) == screenUUID,
                  agentAdmission.screenHash.utf8.count <= 64, hinge == nil, rotation == nil,
                  home == nil, button == nil, gesture == nil else {
                throw AgentModeFailure("invalidAdmission", "Agent native admission does not match this complete request.")
            }
        }
        if pinch != nil, let agentAdmission {
            guard agentAdmission.target != nil,
                  agentAdmission.selectorKind == .id || agentAdmission.selectorKind == .label,
                  agentAdmission.selectorValue != nil else {
                throw AgentModeFailure("missingPinchAdmission", "A reference pinch requires fresh agent area admission.")
            }
        }
        guard [path != nil, legacyPath != nil, legacyTouch != nil, pinch != nil, gesture != nil, ax != nil, hinge != nil, keyboard != nil, home != nil, button != nil, rotation != nil].filter({ $0 }).count <= 1 else {
            throw SelectedHIDFailure.invalid("Selected input payloads cannot be mixed")
        }
        if let hinge {
            guard operation == .complete, token == nil, primitives.isEmpty, path == nil, pinch == nil, gesture == nil, ax == nil,
                  screenID == nil, screenUUID == nil else {
                throw SelectedHIDFailure.invalid("Hinge requires one device operation without screen, AX, path, pinch or contact fields")
            }
            try hinge.validate()
            return
        }
        guard screenID != nil, screenUUID != nil else {
            throw SelectedHIDFailure.invalid("Selected screen operations require both screen ID and UUID")
        }
        if let legacyPath {
            try legacyPath.validate()
            return
        }
        if let legacyTouch {
            try legacyTouch.validate()
            return
        }
        if let rotation {
            guard operation == .complete, token == nil, primitives.isEmpty else {
                throw SelectedHIDFailure.invalid("Rotation requires one complete operation without contact fields")
            }
            try rotation.validate()
            return
        }
        if let home {
            guard operation == .complete, token == nil, primitives.isEmpty else {
                throw SelectedHIDFailure.invalid("Home requires one complete operation without a token or primitive payload")
            }
            try home.validate()
            return
        }
        if let button {
            guard operation == .complete, token == nil, primitives.isEmpty else {
                throw SelectedHIDFailure.invalid("Button requires one complete operation without a token or primitive payload")
            }
            try button.validate()
            return
        }
        if let keyboard {
            guard operation == .complete, token == nil, primitives.isEmpty else {
                throw SelectedHIDFailure.invalid("Keyboard requires one complete operation without a contact token or touch primitives")
            }
            try keyboard.validate()
            return
        }
        if let ax {
            guard operation == .complete, token == nil, primitives.isEmpty, path == nil, pinch == nil, gesture == nil else {
                throw SelectedHIDFailure.invalid("AX requires one complete operation without a token, primitives, path or pinch")
            }
            try ax.validate()
            return
        }
        if let path {
            guard operation == .complete, token == nil, primitives.isEmpty, pinch == nil, gesture == nil else {
                throw SelectedHIDFailure.invalid("A path requires one complete event and no primitive payload, pinch or token")
            }
            try path.validate()
            return
        }
        if let pinch {
            guard operation == .complete, token == nil, primitives.isEmpty, gesture == nil else {
                throw SelectedHIDFailure.invalid("Pinch requires one complete event without primitives or a retained token")
            }
            try pinch.validate()
            return
        }
        if let gesture {
            guard operation == .complete, token == nil, primitives.isEmpty else {
                throw SelectedHIDFailure.invalid("A complete gesture cannot contain primitives or a retained token")
            }
            try gesture.validate()
            return
        }
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
        guard keyboard == nil, rotation == nil, legacyPath == nil, legacyTouch == nil else { throw SelectedHIDFailure.invalid("Keyboard, rotation and legacy input require separate admission") }
        if let home { return try home.event(observation: observation) }
        if let button { return try button.event(observation: observation) }
        if let pinch { return try pinch.event(observation: observation) }
        if let gesture { return try gesture.event(observation: observation) }
        return try completeEvent(logicalSize: observation.displayContext.logicalSize)
    }

    func completeEvent(logicalSize: CGSize) throws -> FBSimulatorHIDEvent {
        guard pinch == nil, gesture == nil, keyboard == nil, home == nil, button == nil, rotation == nil, legacyPath == nil, legacyTouch == nil else { throw SelectedHIDFailure.invalid("Complete gestures require a fresh selected observation") }
        guard let path else { return event }
        return .composite(try path.primitives(logicalSize: logicalSize).map(\.event))
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
    let error: String?
    let context: SelectedHIDContext?
    var ax: SelectedAXResult? = nil
    var quarantine: SelectedHIDQuarantine? = nil
    var hinge: SelectedHingeResult? = nil
    var keyboard: SelectedKeyboardResult? = nil
    var home: SelectedHomeResult? = nil
    var button: SelectedButtonResult? = nil
    var rotation: SelectedRotationResult? = nil
    var agent: AgentModeResult? = nil
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
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .busy: return "Simulator input is owned by another action or retained contact"
        case .invalidToken: return "Retained contact token is absent, expired or belongs to another broker"
        case .selectionChanged: return "Retained contact cannot change its selected display"
        }
    }
}

/// Value-state admission is checked before any asynchronous work.
struct SelectedHIDAdmission {
    enum Origin { case selected, legacyTouch }
    private(set) var inFlight = false
    private(set) var token: UUID?
    private(set) var screenID: UInt32?
    private(set) var screenUUID: UUID?
    private(set) var origin: Origin?
    mutating func enter(_ request: SelectedHIDRequest) throws {
        try request.validate()
        guard !inFlight else { throw SelectedHIDFailure.busy }
        if let token {
            if origin == .legacyTouch {
                guard request.legacyTouch != nil, request.token == nil else { throw SelectedHIDFailure.busy }
            } else {
                guard request.legacyTouch == nil, request.token == token else { throw SelectedHIDFailure.busy }
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
