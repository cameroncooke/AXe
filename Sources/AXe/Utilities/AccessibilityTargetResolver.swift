import Foundation

enum AccessibilityQuery {
    case id(String)
    case label(String)
}

struct AccessibilityTargetResolver {
    static let describeUITip = "Make sure the app is on the expected screen, then run `axe describe-ui --udid <SIMULATOR_UDID>` and prefer --id when available."

    static func resolveCenterPoint(
        roots: [AccessibilityElement],
        query: AccessibilityQuery
    ) throws -> (x: Double, y: Double) {
        let allElements = roots.flatMap { $0.flattened() }
        let matchedElement: AccessibilityElement

        switch query {
        case .id(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedUniqueId == value }
            matchedElement = try selectUniqueMatch(matches, kind: "--id", value: rawValue)
        case .label(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedLabel == value }
            matchedElement = try selectUniqueMatch(matches, kind: "--label", value: rawValue)
        }

        guard let frame = matchedElement.frame else {
            throw CLIError(errorDescription: "Matched element has no frame. \(describeUITip)")
        }
        guard frame.width > 0, frame.height > 0 else {
            throw CLIError(errorDescription: "Matched element has an invalid frame size (\(frame.width)x\(frame.height)). \(describeUITip)")
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
            throw CLIError(errorDescription: "No accessibility element matched \(kind) '\(value)'. \(describeUITip)")
        }
        guard matches.count == 1 else {
            throw CLIError(errorDescription: "Multiple (\(matches.count)) accessibility elements matched \(kind) '\(value)'. Use --id when labels are not unique. \(describeUITip)")
        }
        return matches[0]
    }
}

