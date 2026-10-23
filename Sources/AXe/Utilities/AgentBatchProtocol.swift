import Foundation

/// Only complete tap/type actions. IDs are resolved again before each step.
struct AgentBatchRequest: Codable, Sendable {
    let expectedPID: Int32
    let steps: [AgentBatchStep]

    func validate() throws {
        guard expectedPID > 0, (1...8).contains(steps.count) else {
            throw AgentModeFailure("invalidBatch", "Agent batch requires a positive PID and 1...8 tap/type steps.")
        }
        for step in steps { try step.validate(expectedPID: expectedPID) }
    }

    // Each existing action keeps its timeout. The single reply must cover all steps
    // and the initial description; this does not retry or extend native operations.
    var responseTimeoutMilliseconds: Int { (steps.count + 1) * 120_000 }
}

struct AgentBatchStep: Codable, Sendable {
    enum Action: String, Codable, Sendable { case tap, type }
    let action: Action
    let id: String
    let text: String?

    init(from decoder: Decoder) throws {
        try AgentBatchJSONKey.requireOnly(["action", "id", "text"], decoder: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Action.self, forKey: .action)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    func validate(expectedPID: Int32) throws {
        guard !id.isEmpty, id.utf8.count <= 4096,
              id == id.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AgentModeFailure("invalidBatchID", "Every agent batch step requires an exact nonempty native ID.")
        }
        switch action {
        case .tap:
            guard text == nil else { throw AgentModeFailure("mixedBatchPayload", "A tap step cannot contain text.") }
        case .type:
            guard let text else { throw AgentModeFailure("missingBatchText", "A type step requires literal text.") }
            let events = try SelectedKeyboardRequest.primitives(from: SelectedKeyboardRequest.textEvent(text))
            try SelectedKeyboardRequest(expectedPID: expectedPID, focusID: id, events: events).validate()
        }
    }
}

struct AgentBatchDocument: Decodable {
    let steps: [AgentBatchStep]
    private enum CodingKeys: String, CodingKey { case steps }
    init(from decoder: Decoder) throws {
        try AgentBatchJSONKey.requireOnly(["steps"], decoder: decoder)
        steps = try decoder.container(keyedBy: CodingKeys.self).decode([AgentBatchStep].self, forKey: .steps)
    }
}

private struct AgentBatchJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func requireOnly(_ allowed: Set<String>, decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Self.self).allKeys.map(\.stringValue)
        guard keys.allSatisfy(allowed.contains) else {
            throw AgentModeFailure("unsupportedBatchField", "Agent batch contains an unsupported field; only steps with action, id and type text are accepted.")
        }
    }
}

struct AgentBatchStepReceipt: Codable, Sendable {
    let index: Int
    let action: AgentBatchStep.Action
    let status: String
    let requestID: UUID
    let receipt: AgentModeActionReceipt?
    let error: AgentModeFailure?
    let cache: AgentModeCacheState
    let context: SelectedHIDContext?
}

struct AgentBatchReceipt: Codable, Sendable {
    let totalSteps: Int
    let completedSteps: Int
    let steps: [AgentBatchStepReceipt]
    let stoppedAt: Int?
    let replayed = false
    let rolledBack = false
}
