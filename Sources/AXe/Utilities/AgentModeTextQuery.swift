import ArgumentParser
import AXeCore
import Foundation

/// Read-only chunks use the same immutable snapshot and live context checks as input.
struct AgentModeTextQuery: Codable, Sendable {
    enum Field: String, Codable, Sendable, ExpressibleByArgument {
        case label, value, id
        case customActions = "custom-actions"
    }
    let field: Field
    let offset: Int
    let limit: Int

    func validate() throws {
        guard offset >= 0, (1...4096).contains(limit) else {
            throw AgentModeFailure("invalidTextRange", "Text offset must be non-negative and text limit must be in 1...4096 Unicode scalars.")
        }
    }
}

struct AgentModeTextDetail: Codable, Sendable {
    let ref: String
    let field: AgentModeTextQuery.Field
    let offset: Int
    let nextOffset: Int?
    let totalLength: Int
    let text: String
    let frame: AgentFrame?
    let actions: [RuntimeElementAction]
}
