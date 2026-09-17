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

public struct AgentObservedElement: Codable, Equatable, Sendable {
    public let stableKey: String
    public let type: String?
    public let role: String?
    public let roleDescription: String?
    public let label: String?
    public let identifier: String?
    public let value: String?
    public let frame: AgentFrame
    public let isSwitchLike: Bool
    public let supportsTap: Bool
    public let supportsTextEntry: Bool

    public init(
        stableKey: String,
        type: String?,
        role: String?,
        roleDescription: String?,
        label: String?,
        identifier: String?,
        value: String?,
        frame: AgentFrame,
        isSwitchLike: Bool,
        supportsTap: Bool,
        supportsTextEntry: Bool
    ) {
        self.stableKey = stableKey
        self.type = type
        self.role = role
        self.roleDescription = roleDescription
        self.label = label
        self.identifier = identifier
        self.value = value
        self.frame = frame
        self.isSwitchLike = isSwitchLike
        self.supportsTap = supportsTap
        self.supportsTextEntry = supportsTextEntry
    }

    public var displayName: String {
        label ?? identifier ?? value ?? type ?? role ?? stableKey
    }

    public var activationPoint: AgentPoint {
        if isSwitchLike, frame.width > 100 {
            return AgentPoint(x: frame.x + frame.width - 31, y: frame.y + (frame.height / 2))
        }
        return frame.centre
    }
}

public struct AgentScreenSnapshot: Codable, Equatable, Sendable {
    public let fingerprint: String
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let text: String
    public let applicationFrame: AgentFrame?
    public let elements: [AgentObservedElement]

    public init(
        fingerprint: String,
        applicationName: String?,
        bundleIdentifier: String?,
        text: String,
        applicationFrame: AgentFrame?,
        elements: [AgentObservedElement]
    ) {
        self.fingerprint = fingerprint
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.text = text
        self.applicationFrame = applicationFrame
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
    public let elementChoicesByOperation: [AgentOperation: [String: AgentObservedElement]]
    public let applicationsByChoice: [String: AgentApplication]
    public let soleElementByOperation: [AgentOperation: AgentObservedElement]
    public let soleApplication: AgentApplication?
    public let textCandidatesByChoice: [String: String]
    public let textQuestionByElementKey: [String: String]

    public init(
        payload: TypeSafeSystemOneRequest,
        availableOperations: Set<AgentOperation>,
        elementChoicesByOperation: [AgentOperation: [String: AgentObservedElement]],
        applicationsByChoice: [String: AgentApplication],
        soleElementByOperation: [AgentOperation: AgentObservedElement],
        soleApplication: AgentApplication?,
        textCandidatesByChoice: [String: String],
        textQuestionByElementKey: [String: String]
    ) {
        self.payload = payload
        self.availableOperations = availableOperations
        self.elementChoicesByOperation = elementChoicesByOperation
        self.applicationsByChoice = applicationsByChoice
        self.soleElementByOperation = soleElementByOperation
        self.soleApplication = soleApplication
        self.textCandidatesByChoice = textCandidatesByChoice
        self.textQuestionByElementKey = textQuestionByElementKey
    }
}

public struct AgentDecision: Codable, Equatable, Sendable {
    public let operation: AgentOperation
    public let element: AgentObservedElement?
    public let application: AgentApplication?
    public let text: String?
    public let operationConfidence: Double
    public let operationProbability: Double
    public let targetConfidence: Double?
    public let targetProbability: Double?

    public init(
        operation: AgentOperation,
        element: AgentObservedElement?,
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
