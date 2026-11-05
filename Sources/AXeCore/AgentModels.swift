import Foundation

public enum AgentOperation: String, CaseIterable, Codable, Sendable {
    case openApp = "OPEN_APP"
    case tap = "TAP"
    case typeText = "TYPE_TEXT"
    case clearText = "CLEAR_TEXT"
    case scrollDown = "SCROLL_DOWN"
    case scrollUp = "SCROLL_UP"
    case pressReturn = "PRESS_RETURN"
    case wait = "WAIT"
    case done = "DONE"
    case blocked = "BLOCKED"
}

public struct AgentFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }

    public var centre: AgentPoint {
        AgentPoint(x: x + (width / 2), y: y + (height / 2))
    }
}

public struct AgentPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// An rs/1 runtime snapshot of the frontmost application.
public struct AgentScreenSnapshot: Codable, Equatable, Sendable {
    public let fingerprint: String
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let viewport: AgentFrame?
    public let elements: [RuntimeSnapshotElement]

    public init(
        applicationName: String?,
        bundleIdentifier: String?,
        elements: [RuntimeSnapshotElement]
    ) {
        self.fingerprint = RuntimeSnapshotBuilder.screenHash(of: elements)
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.viewport = RuntimeSnapshotBuilder.viewportFrame(in: elements)
        self.elements = elements
    }
}

public struct AgentApplication: Codable, Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String

    public init(name: String, bundleIdentifier: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct AgentHistoryEntry: Codable, Equatable, Sendable {
    public let step: Int
    public let operation: AgentOperation
    public let target: String?
    public let text: String?
    public let beforeFingerprint: String
    public let afterFingerprint: String?
    public let pageChanged: Bool?

    public init(
        step: Int,
        operation: AgentOperation,
        target: String?,
        text: String?,
        beforeFingerprint: String,
        afterFingerprint: String?,
        pageChanged: Bool?
    ) {
        self.step = step
        self.operation = operation
        self.target = target
        self.text = text
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
        self.pageChanged = pageChanged
    }
}

public struct AgentPreparedRequest: Sendable {
    public let payload: TypeSafeSystemOneRequest
    public let availableOperations: Set<AgentOperation>
    /// Offered element choices keyed by rs/1 ref.
    public let elementChoicesByOperation: [AgentOperation: [String: RuntimeSnapshotElement]]
    public let applicationsByChoice: [String: AgentApplication]
    public let soleElementByOperation: [AgentOperation: RuntimeSnapshotElement]
    public let soleApplication: AgentApplication?
    public let textCandidatesByChoice: [String: String]
    public let textQuestionByElementRef: [String: String]

    public init(
        payload: TypeSafeSystemOneRequest,
        availableOperations: Set<AgentOperation>,
        elementChoicesByOperation: [AgentOperation: [String: RuntimeSnapshotElement]],
        applicationsByChoice: [String: AgentApplication],
        soleElementByOperation: [AgentOperation: RuntimeSnapshotElement],
        soleApplication: AgentApplication?,
        textCandidatesByChoice: [String: String],
        textQuestionByElementRef: [String: String]
    ) {
        self.payload = payload
        self.availableOperations = availableOperations
        self.elementChoicesByOperation = elementChoicesByOperation
        self.applicationsByChoice = applicationsByChoice
        self.soleElementByOperation = soleElementByOperation
        self.soleApplication = soleApplication
        self.textCandidatesByChoice = textCandidatesByChoice
        self.textQuestionByElementRef = textQuestionByElementRef
    }
}

public struct AgentDecision: Codable, Equatable, Sendable {
    public let operation: AgentOperation
    /// Target for TAP, TYPE_TEXT and CLEAR_TEXT, or the scroll area for SCROLL_* (nil scrolls the viewport).
    public let element: RuntimeSnapshotElement?
    public let application: AgentApplication?
    public let text: String?
    public let operationConfidence: Double
    public let operationProbability: Double
    public let targetConfidence: Double?
    public let targetProbability: Double?

    public init(
        operation: AgentOperation,
        element: RuntimeSnapshotElement?,
        application: AgentApplication?,
        text: String?,
        operationConfidence: Double,
        operationProbability: Double,
        targetConfidence: Double?,
        targetProbability: Double?
    ) {
        self.operation = operation
        self.element = element
        self.application = application
        self.text = text
        self.operationConfidence = operationConfidence
        self.operationProbability = operationProbability
        self.targetConfidence = targetConfidence
        self.targetProbability = targetProbability
    }
}

public enum AgentPolicyError: LocalizedError, Sendable {
    case emptyGoal
    case missingAnswer(String)
    case invalidChoice(question: String, reason: String)
    case unsupportedOperation(String)
    case missingTarget(AgentOperation)
    case actionProbabilityTooLow(operation: AgentOperation, probability: Double, minimum: Double)

    public var errorDescription: String? {
        switch self {
        case .emptyGoal:
            return "The agent goal must not be empty."
        case .missingAnswer(let question):
            return "TypeSafe did not answer the required question '\(question)'."
        case .invalidChoice(let question, let reason):
            return "TypeSafe returned an invalid answer for '\(question)': \(reason)"
        case .unsupportedOperation(let operation):
            return "TypeSafe selected an unsupported operation: \(operation)"
        case .missingTarget(let operation):
            return "TypeSafe selected \(operation.rawValue) without a valid target."
        case .actionProbabilityTooLow(let operation, let probability, let minimum):
            return "TypeSafe selected \(operation.rawValue) with probability \(probability), below the required minimum of \(minimum)."
        }
    }
}
