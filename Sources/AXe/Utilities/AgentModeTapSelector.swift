import Foundation

/// Agent-only predicates. Older brokers see no legacy target and reject the request.
struct AgentModeTapSelector: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case id, label, value, labelContains, labelRegex }
    static let maximumQueryBytes = 512
    static let maximumPatternBytes = 128
    let kind: Kind
    let query: String
    let frame: AgentModeFrameFilter?

    func validate() throws {
        _ = try validatedExpression()
    }

    func validatedExpression() throws -> NSRegularExpression? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= Self.maximumQueryBytes else {
            throw AgentModeFailure("invalidSelector", "Agent tap queries require 1...512 UTF-8 bytes and must not be blank.")
        }
        try frame?.validate()
        guard kind == .labelRegex else { return nil }
        guard query.utf8.count <= Self.maximumPatternBytes else {
            throw AgentModeFailure("regexTooLarge", "Agent label regex patterns are limited to 128 UTF-8 bytes.")
        }
        do { return try NSRegularExpression(pattern: query) }
        catch { throw AgentModeFailure("invalidRegex", "The agent label regex is invalid.") }
    }
}

/// One logical rectangle; omitted edges use the current selected screen bounds.
struct AgentModeFrameFilter: Codable, Sendable {
    let minX: Double?
    let maxX: Double?
    let minY: Double?
    let maxY: Double?

    init(specification: String) throws {
        guard specification.utf8.count <= 256 else {
            throw AgentModeFailure("invalidFrameFilter", "The agent frame filter is limited to 256 UTF-8 bytes.")
        }
        let parts = specification.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else {
            throw AgentModeFailure("invalidFrameFilter", "Use one to four minX, maxX, minY or maxY bounds.")
        }
        var values: [String: Double] = [:]
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                throw AgentModeFailure("invalidFrameFilter", "Use --frame key=value[,key=value] in logical UI points.")
            }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["minX", "maxX", "minY", "maxY"].contains(key), values[key] == nil,
                  let value = Double(raw), value.isFinite, value >= 0 else {
                throw AgentModeFailure("invalidFrameFilter", "Frame keys must be unique; values must be finite non-negative logical UI points.")
            }
            values[key] = value
        }
        minX = values["minX"]; maxX = values["maxX"]
        minY = values["minY"]; maxY = values["maxY"]
        try validate()
    }

    func validate() throws {
        let bounds = [minX, maxX, minY, maxY].compactMap { $0 }
        guard !bounds.isEmpty, bounds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              maxX.map({ (minX ?? 0) < $0 }) ?? true,
              maxY.map({ (minY ?? 0) < $0 }) ?? true else {
            throw AgentModeFailure("invalidFrameFilter", "The agent frame filter must define a finite positive rectangle.")
        }
    }

    func rectangle(in context: SelectedHIDContext) throws -> CGRect {
        try validate()
        let left = minX ?? 0
        let right = maxX ?? context.logicalWidth
        let top = minY ?? 0
        let bottom = maxY ?? context.logicalHeight
        guard left < right, top < bottom,
              right <= context.logicalWidth, bottom <= context.logicalHeight else {
            throw AgentModeFailure("frameFilterOutsideScreen", "The agent frame filter must fit the current logical screen. Read the UI again after a pose change.")
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// One shared budget across the fresh query, not a separate timeout for each label.
struct AgentModeTapMatcher {
    static let maximumCandidateBytes = 4096
    static let maximumTotalBytes = 262_144
    static let budgetSeconds = 0.1
    private let selector: AgentModeTapSelector
    private let expression: NSRegularExpression?
    private let deadline: Double
    private var totalBytes = 0

    init(selector: AgentModeTapSelector) throws {
        deadline = ProcessInfo.processInfo.systemUptime + Self.budgetSeconds
        self.selector = selector
        expression = try selector.validatedExpression()
        try checkBudget()
    }

    mutating func matches(_ raw: String) throws -> Bool {
        try checkBudget()
        let bytes = raw.utf8.count
        guard bytes <= Self.maximumCandidateBytes, bytes <= Self.maximumTotalBytes - totalBytes else {
            throw AgentModeFailure("selectorQueryTooLarge", "The agent query exceeds its native text bound. Use a narrower type or frame filter.")
        }
        totalBytes += bytes
        if let expression {
            var matched = false
            var expired = false
            var failed = false
            let matchDeadline = deadline
            expression.enumerateMatches(in: raw, options: [.reportProgress, .reportCompletion],
                range: NSRange(raw.startIndex..<raw.endIndex, in: raw)) { result, flags, stop in
                if ProcessInfo.processInfo.systemUptime >= matchDeadline {
                    expired = true
                    stop.pointee = true
                } else if flags.contains(.internalError) {
                    failed = true
                    stop.pointee = true
                } else if result != nil {
                    matched = true
                    stop.pointee = true
                }
            }
            guard !expired else { throw budgetFailure() }
            guard !failed else { throw AgentModeFailure("regexMatchFailed", "The agent label regex could not complete safely.") }
            try checkBudget()
            return matched
        }
        let matched: Bool
        if selector.kind == .labelContains {
            matched = raw.range(of: selector.query, options: .literal) != nil
        } else {
            matched = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                == selector.query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try checkBudget()
        return matched
    }

    func checkBudget() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw budgetFailure() }
    }

    private func budgetFailure() -> AgentModeFailure {
        AgentModeFailure("selectorQueryTimedOut", "The agent selector exceeded its 100 ms query budget. No input was sent; narrow the query.")
    }
}
