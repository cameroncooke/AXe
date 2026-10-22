import Foundation
import FBSimulatorControl

enum SelectedAXPreparation: String, Codable, Sendable {
    case automationSession = "automation-session"
    case existingBridge = "existing-bridge"
    var libraryValue: FBSimulatorAXPreparation {
        self == .automationSession ? .automationSession : .existingBridge
    }
}

enum SelectedAXFailure: String, Codable, Sendable {
    case ownershipRejected, acquisitionFailed, targetRejected, pressFailed, sliderFailed, inputFailed, cleanupUncertain, responseTooLarge, setupFailed, waitTimedOut, waitCancelled
}

/// Simulator taps use the library's down/up factory without an inserted hold.
/// Physical taps retain the existing selected 0.1-second hold.
enum SelectedTapStyle: String, Codable, Sendable {
    case physical, simulator, automatic

    /// Coordinates have no AX target. Selector taps pass the selected node only.
    func resolved(for target: FBSimulatorAXNode?) throws -> Self {
        guard self == .automatic else { return self }
        guard let target else { return .simulator }
        let element = try JSONDecoder().decode(AccessibilityElement.self, from: JSONEncoder().encode(target))
        return element.isSwitchLikeControl ? .physical : .simulator
    }

    /// Run after native target validation and before the session can enqueue down.
    func validateAutomaticChoice(verifiedTarget: FBSimulatorAXNode) throws {
        guard self != .automatic, try Self.automatic.resolved(for: verifiedTarget) == self else {
            throw SelectedHIDFailure.invalid("Automatic tap style changed before input")
        }
    }

    func event(x: Double, y: Double) throws -> FBSimulatorHIDEvent {
        switch self {
        case .physical: return .tapAt(x: x, y: y, duration: TapTiming.defaultHoldDuration)
        case .simulator: return .tapAt(x: x, y: y)
        case .automatic: throw SelectedHIDFailure.invalid("Automatic tap requires a resolved style")
        }
    }

    func primitives(x: Double, y: Double) throws -> [SelectedHIDPrimitive] {
        guard case let .composite(events) = try event(x: x, y: y) else {
            throw SelectedHIDFailure.invalid("The selected tap factory did not return a composite")
        }
        return try events.map { event in
            switch event {
            case let .touch(.down, x, y): return .touch(.down, x: x, y: y)
            case let .touch(.up, x, y): return .touch(.up, x: x, y: y)
            case let .delay(seconds): return .delay(seconds)
            default: throw SelectedHIDFailure.invalid("The selected tap factory returned an unsupported primitive")
            }
        }
    }
}

struct SelectedAXRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case describe, describePoint, tap, hold, sliderEndpoint, semanticPress }
    enum SelectorKind: String, Codable, Sendable { case id, label, value }
    let kind: Kind
    let expectedPID: Int32
    let preparation: SelectedAXPreparation
    let endpoint: FBSimulatorSliderEndpoint?
    let selectorKind: SelectorKind?
    let selectorValue: String?
    let preDelay: Double
    let postDelay: Double
    var point: SelectedAXPoint? = nil
    var elementType: String? = nil
    var tapStyle: SelectedTapStyle? = nil
    var waitPolicy: SelectedAXWaitPolicy? = nil
    var holdDuration: Double? = nil

    func validate() throws {
        guard expectedPID > 0 else { throw SelectedHIDFailure.invalid("Selected AX requires a positive expected PID") }
        guard preDelay.isFinite, postDelay.isFinite, (0...10).contains(preDelay), (0...10).contains(postDelay) else {
            throw SelectedHIDFailure.invalid("Selected AX delays must be finite and in 0...10 seconds")
        }
        if kind != .describePoint, point != nil {
            throw SelectedHIDFailure.invalid("Only a selected point description accepts a point payload")
        }
        if kind != .hold, holdDuration != nil {
            throw SelectedHIDFailure.invalid("Only an agent reference hold accepts a hold duration")
        }
        if tapStyle != nil, kind != .tap {
            throw SelectedHIDFailure.invalid("Only an ordinary selected tap accepts a tap style")
        }
        if let waitPolicy {
            guard kind == .tap else {
                throw SelectedHIDFailure.invalid("Only an ordinary selected tap accepts a wait policy")
            }
            try waitPolicy.validate()
        }
        if let elementType {
            guard kind == .tap || kind == .hold || kind == .sliderEndpoint, !elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SelectedHIDFailure.invalid("Only a selected tap, reference hold or slider endpoint accepts a nonempty element type")
            }
        }
        switch kind {
        case .describe:
            guard endpoint == nil, selectorKind == nil, selectorValue == nil, preDelay == 0, postDelay == 0 else {
                throw SelectedHIDFailure.invalid("Describe does not accept selectors or delays")
            }
        case .describePoint:
            guard endpoint == nil, selectorKind == nil, selectorValue == nil,
                  preDelay == 0, postDelay == 0, let point,
                  point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0 else {
                throw SelectedHIDFailure.invalid("Point description requires one finite non-negative point and no selectors or delays")
            }
        case .tap:
            guard endpoint == nil, selectorKind != nil, let selectorValue,
                  !selectorValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SelectedHIDFailure.invalid("Selected tap requires exactly one nonempty ID, label or value")
            }
        case .hold:
            guard endpoint == nil, selectorKind == .id || selectorKind == .label,
                  let selectorValue, !selectorValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let holdDuration, holdDuration.isFinite, holdDuration > 0, holdDuration <= 10,
                  preDelay == 0, postDelay == 0 else {
                throw SelectedHIDFailure.invalid("A reference hold requires an exact ID or label, a duration in (0,10] and no other delays")
            }
        case .semanticPress:
            guard endpoint == nil, selectorKind == .id, let selectorValue,
                  !selectorValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  selectorValue.utf8.count <= 4096, preDelay == 0, postDelay == 0 else {
                throw SelectedHIDFailure.invalid("Semantic press requires an exact ID and no delays")
            }
        case .sliderEndpoint:
            guard endpoint != nil, selectorKind == .id || selectorKind == .label, let selectorValue,
                  !selectorValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  selectorValue.utf8.count <= 4096, preDelay == 0, postDelay == 0 else {
                throw SelectedHIDFailure.invalid("Selected slider requires an ID or label, native endpoint and no delays")
            }
        }
    }
    func resolvedTapStyle(target: FBSimulatorAXNode?) throws -> SelectedTapStyle {
        try validate()
        if kind == .hold { return .physical }
        guard kind == .tap else { throw SelectedHIDFailure.invalid("A tap event requires an ordinary selected tap") }
        if tapStyle == .automatic, target == nil {
            throw SelectedHIDFailure.invalid("An automatic AX tap requires its selected target")
        }
        return try (tapStyle ?? .physical).resolved(for: target)
    }

    func tapEvent(at point: CGPoint, target: FBSimulatorAXNode? = nil) throws -> FBSimulatorHIDEvent {
        let style = try resolvedTapStyle(target: target)
        if kind == .hold, let holdDuration {
            return .tapAt(x: point.x, y: point.y, duration: holdDuration)
        }
        return try style.event(x: point.x, y: point.y)
    }

    var selector: FBSimulatorAXSelector? {
        guard let selectorKind, let selectorValue else { return nil }
        switch selectorKind {
        case .id:
            if let elementType { return .identifierWithType(selectorValue, elementType: elementType) }
            return .identifier(selectorValue)
        case .label:
            if let elementType { return .labelWithType(selectorValue, elementType: elementType) }
            return .label(selectorValue)
        case .value:
            if let elementType { return .valueWithType(selectorValue, elementType: elementType) }
            return .value(selectorValue)
        }
    }
}

struct SelectedAXAttempt: Codable, Sendable {
    let index: Int
    let startUptime: Double
    let endUptime: Double
    let rootPID: Int32
    let outcome: FBSimulatorAXAcquisitionOutcome
    let roots: [FBSimulatorAXNode]?
    init(_ value: FBSimulatorAXAcquisitionAttempt) throws {
        index = value.index; startUptime = value.startUptime; endUptime = value.endUptime
        rootPID = value.rootPID; outcome = value.outcome
        if let bytes = value.jsonData {
            let decoder = JSONDecoder()
            if let array = try? decoder.decode([FBSimulatorAXNode].self, from: bytes) { roots = array }
            else { roots = [try decoder.decode(FBSimulatorAXNode.self, from: bytes)] }
        } else { roots = nil }
    }
}
struct SelectedAXPhase: Codable, Sendable { let name: String; let uptime: Double }
struct SelectedAXAcquisition: Codable, Sendable {
    let outcome: FBSimulatorAXAcquisitionOutcome
    let attempts: [SelectedAXAttempt]
    let phases: [SelectedAXPhase]
    let failureDescription: String?
    init(_ value: FBSimulatorAXAcquisition) throws {
        outcome = value.outcome; attempts = try value.attempts.map(SelectedAXAttempt.init)
        phases = value.phases.map { SelectedAXPhase(name: $0.name, uptime: $0.uptime) }
        failureDescription = value.failureDescription
    }
}
struct SelectedAXPoint: Codable, Sendable { let x: Double; let y: Double }
struct SelectedAXValidation: Codable, Sendable {
    let startedUptime: Double
    let finishedUptime: Double
    let expectedPID: Int32
    let hitPID: Int32
    let frontmostPID: Int32
    let pointX: Double
    let pointY: Double
    let hit: FBSimulatorAXNode
    let confirmedHit: FBSimulatorAXNode?
    let confirmedHitPID: Int32?
    let matchKind: String
    let verifiedTarget: FBSimulatorAXNode
    let relationshipTree: [FBSimulatorAXNode]?
    init(_ value: FBSimulatorAXTargetValidation) {
        startedUptime = value.startedUptime; finishedUptime = value.finishedUptime
        expectedPID = value.expectedPID; hitPID = value.hitPID; frontmostPID = value.frontmostPID
        pointX = value.pointX; pointY = value.pointY; hit = value.hit; confirmedHit = value.confirmedHit
        confirmedHitPID = value.confirmedHitPID; matchKind = value.matchKind
        verifiedTarget = value.verifiedTarget; relationshipTree = value.relationshipTree
    }
}
struct SelectedAXRejectedHit: Codable, Sendable {
    let expectedPID: Int32
    let hitPID: Int32
    let roots: [FBSimulatorAXNode]
    let freshRoots: [FBSimulatorAXNode]?
    let confirmedRoots: [FBSimulatorAXNode]?
    let confirmedHitPID: Int32?
    let reason: String
    init(_ value: FBSimulatorAXTargetHitFailure) {
        expectedPID = value.expectedPID; hitPID = value.hitPID; roots = value.roots
        freshRoots = value.freshRoots; confirmedRoots = value.confirmedRoots
        confirmedHitPID = value.confirmedHitPID; reason = value.reason
    }
}
struct SelectedAXResult: Codable, Sendable {
    let schemaVersion = 1
    let kind: SelectedAXRequest.Kind
    let expectedPID: Int32
    let preparation: SelectedAXPreparation
    var failure: SelectedAXFailure?
    var slider: SelectedSliderResult?
    var press: FBSimulatorAXPressReceipt?
    var acquisition: SelectedAXAcquisition?
    var roots: [FBSimulatorAXNode]?
    var target: FBSimulatorAXNode?
    var point: SelectedAXPoint?
    var validation: SelectedAXValidation?
    var rejectedHit: SelectedAXRejectedHit?
    var wait: SelectedAXWaitReceipt?
}

enum SelectedAXContentError: Error { case tooLarge }

enum SelectedAXBounds {
    static let responseBytes = 4 * 1024 * 1024
    // Keep control metadata outside the AX content allowance. Neither is truncated.
    static let contentBytes = responseBytes - 64 * 1024
    static func validateContext(_ context: SelectedHIDContext) throws {
        guard try JSONEncoder().encode(context).count <= 32 * 1024 else { throw SelectedAXContentError.tooLarge }
    }
    static func validateContent(_ result: SelectedAXResult) throws {
        guard try JSONEncoder().encode(result).count <= contentBytes else {
            throw SelectedAXContentError.tooLarge
        }
    }
}
