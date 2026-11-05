import Foundation

/// Names describe provider metadata only. They do not authorize input or named execution.
enum AgentModeCustomActions {
    static let maximumNames = 4
    static let maximumNameScalars = 96

    static func preview(_ names: [String]) -> (names: [String], truncated: Bool) {
        var truncated = names.count > maximumNames
        let preview = names.prefix(maximumNames).map { name in
            let scalars = name.unicodeScalars.prefix(maximumNameScalars + 1)
            guard scalars.count > maximumNameScalars else { return name }
            truncated = true
            return String(String.UnicodeScalarView(scalars.prefix(maximumNameScalars - 1))) + "…"
        }
        return (preview, truncated)
    }

    static func jsonText(_ names: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(names), as: UTF8.self)
    }
}
