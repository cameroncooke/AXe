import Foundation

enum AccessibilityQuery {
    case id(String)
    case label(String)
    case value(String)
}

enum ElementResolutionError: LocalizedError {
    case notFound(kind: String, value: String)
    case multipleMatches(count: Int, kind: String, value: String, hasUniqueIDs: Bool)
    case invalidFrame(reason: String)

    var errorDescription: String? {
        let tip = AccessibilityTargetResolver.describeUITip
        switch self {
        case .notFound(let kind, let value):
            return "No accessibility element matched \(kind) '\(value)'. \(tip)"
        case .multipleMatches(let count, let kind, let value, let hasUniqueIDs):
            if hasUniqueIDs {
                return "Multiple (\(count)) accessibility elements matched \(kind) '\(value)'. Use --id when labels are not unique. \(tip)"
            }
            return "Multiple (\(count)) accessibility elements matched \(kind) '\(value)', and none of the matches expose AXUniqueId on this screen. Use coordinates for this step (tap -x/-y) or target a more specific screen/state. \(tip)"
        case .invalidFrame(let reason):
            return "\(reason) \(tip)"
        }
    }

    var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }
}

struct AccessibilityTargetResolver {
    static let describeUITip = "Make sure the app is on the expected screen, then run `axe describe-ui --udid <SIMULATOR_UDID>` and prefer --id when available."

    static func resolveCenterPoint(
        roots: [AccessibilityElement],
        query: AccessibilityQuery,
        elementType: String? = nil
    ) throws -> (x: Double, y: Double) {
        var allElements = roots.flatMap { $0.flattened() }

        if let elementType {
            allElements = allElements.filter { $0.type == elementType }
        }

        let matchedElement: AccessibilityElement

        switch query {
        case .id(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedUniqueId == value }
            matchedElement = try selectUniqueMatch(matches, kind: "--id", value: rawValue)
        case .label(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedLabel == value }
            matchedElement = try selectBestLabelMatch(matches, value: rawValue)
        case .value(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedValue == value }
            matchedElement = try selectBestLabelMatch(matches, value: rawValue)
        }

        guard let frame = matchedElement.frame else {
            throw ElementResolutionError.invalidFrame(reason: "Matched element has no frame.")
        }
        guard frame.width > 0, frame.height > 0 else {
            throw ElementResolutionError.invalidFrame(reason: "Matched element has an invalid frame size (\(frame.width)x\(frame.height)).")
        }

        let centerX = frame.x + (frame.width / 2.0)
        let centerY = frame.y + (frame.height / 2.0)
        return (x: centerX, y: centerY)
    }

    private static func selectUniqueMatch(
        _ matches: [AccessibilityElement],
        kind: String,
        value: String
    ) throws -> AccessibilityElement {
        guard !matches.isEmpty else {
            throw ElementResolutionError.notFound(kind: kind, value: value)
        }
        guard matches.count == 1 else {
            let hasUniqueIDs = matches.contains {
                guard let id = $0.normalizedUniqueId else { return false }
                return !id.isEmpty
            }
            throw ElementResolutionError.multipleMatches(count: matches.count, kind: kind, value: value, hasUniqueIDs: hasUniqueIDs)
        }
        return matches[0]
    }

    private static func selectBestLabelMatch(
        _ matches: [AccessibilityElement],
        value: String
    ) throws -> AccessibilityElement {
        let actionableMatches = matches.filter(\.isActionable)
        if actionableMatches.count == 1 {
            return actionableMatches[0]
        }

        if actionableMatches.count > 1 {
            return try selectUniqueMatch(actionableMatches, kind: "--label", value: value)
        }

        return try selectUniqueMatch(matches, kind: "--label", value: value)
    }
}

