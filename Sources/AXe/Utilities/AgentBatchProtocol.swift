import Foundation

/// Only complete tap/type actions. A batch uses fresh IDs or one published reference table.
struct AgentBatchRequest: Codable, Sendable {
    let expectedPID: Int32?
    var snapshotID: UUID? = nil
    let steps: [AgentBatchStep]

    var usesReferences: Bool { steps.contains { $0.ref != nil } }

    func validate() throws {
        _ = try AgentModePIDPolicy.expectedPID(assertion: expectedPID, snapshot: nil)
        guard (1...8).contains(steps.count) else {
            throw AgentModeFailure("invalidBatch", "Agent batch requires 1...8 tap/type steps.")
        }
        for step in steps { try step.validate(expectedPID: expectedPID) }
        if usesReferences {
            guard snapshotID != nil, steps.allSatisfy({ $0.ref != nil }) else {
                throw AgentModeFailure("mixedBatchTargets", "A reference batch requires one snapshotID and only ref steps. Native ID and reference steps cannot be mixed.")
            }
        } else if snapshotID != nil {
            throw AgentModeFailure("unexpectedBatchSnapshot", "A native ID batch does not use snapshotID. Use ref steps to target a published table.")
        }
    }

    // Each existing action keeps its timeout. The single reply must cover all steps
    // and the initial description; this does not retry or extend native operations.
    var responseTimeoutMilliseconds: Int { (steps.count + 1) * 120_000 }
}

struct AgentBatchStep: Codable, Sendable {
    enum Action: String, Codable, Sendable { case tap, type }
    let action: Action
    let id: String?
    let ref: String?
    let text: String?

    init(from decoder: Decoder) throws {
        try AgentBatchJSONKey.requireOnly(["action", "id", "ref", "text"], decoder: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Action.self, forKey: .action)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    /// The same step addressed on a new table.
    func replacingReference(_ newRef: String) throws -> AgentBatchStep {
        var object: [String: String] = ["action": action.rawValue, "ref": newRef]
        if let text { object["text"] = text }
        return try JSONDecoder().decode(AgentBatchStep.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func validate(expectedPID: Int32?) throws {
        _ = try AgentModePIDPolicy.expectedPID(assertion: expectedPID, snapshot: nil)
        guard (id != nil) != (ref != nil) else {
            throw AgentModeFailure("invalidBatchTarget", "Every agent batch step requires exactly one native id or published ref.")
        }
        if let id {
            guard !id.isEmpty, id.utf8.count <= 4096,
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw AgentModeFailure("invalidBatchID", "Every native ID batch step requires an exact nonempty ID.")
            }
        }
        if let ref {
            let digits = ref.dropFirst()
            guard ref.first == "e", ref.utf8.count <= 32, !digits.isEmpty,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let ordinal = UInt64(digits), ordinal > 0 else {
                throw AgentModeFailure("invalidBatchReference", "Every reference batch step requires a published eN reference.")
            }
        }
        switch action {
        case .tap:
            guard text == nil else { throw AgentModeFailure("mixedBatchPayload", "A tap step cannot contain text.") }
        case .type:
            guard let text else { throw AgentModeFailure("missingBatchText", "A type step requires literal text.") }
            let events = try SelectedKeyboardRequest.primitives(from: SelectedKeyboardRequest.textEvent(text))
            try SelectedKeyboardRequest.validateEvents(events)
        }
    }
}

struct AgentBatchDocument: Decodable {
    let snapshotID: UUID?
    let steps: [AgentBatchStep]
    private enum CodingKeys: String, CodingKey { case snapshotID, steps }
    init(from decoder: Decoder) throws {
        try AgentBatchJSONKey.requireOnly(["snapshotID", "steps"], decoder: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshotID = try container.decodeIfPresent(UUID.self, forKey: .snapshotID)
        steps = try container.decode([AgentBatchStep].self, forKey: .steps)
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
            throw AgentModeFailure("unsupportedBatchField", "Agent batch contains an unsupported field. Use snapshotID with ref steps, or native id steps, and literal text for type actions.")
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
