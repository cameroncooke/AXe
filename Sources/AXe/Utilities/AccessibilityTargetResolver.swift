import Foundation

enum AccessibilityQuery {
    case id(String)
    case label(String)
    case value(String)

    var allowsSiblingRedirection: Bool {
        switch self {
        case .label:
            return true
        case .id, .value:
            return false
        }
    }
}

enum ElementResolutionError: LocalizedError {
    case notFound(kind: String, value: String)
    case multipleMatches(count: Int, kind: String, value: String, hasUniqueIDs: Bool)
    case invalidFrame(reason: String)
    case multipleSwitchDescendants(count: Int, selectorDescription: String)

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
        case .multipleSwitchDescendants(let count, let selectorDescription):
            return "Matched element for \(selectorDescription) contains multiple (\(count)) switch/toggle controls. Target the switch more specifically with --id when available, or use coordinates. Use --element-type only when describe-ui reports a specific target type like Switch or Toggle. \(tip)"
        }
    }

    var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }
}

struct AccessibilityMatch {
    let element: AccessibilityElement
    let selectorDescription: String
}

struct AccessibilityTargetResolver {
    static let describeUITip = "Make sure the app is on the expected screen, then run `axe describe-ui --udid <SIMULATOR_UDID>` and prefer --id when available."

    private static let wideSwitchActivationWidthThreshold = 100.0
    private static let switchTrailingActivationInset = 31.0

    static func resolveTapPoint(
        roots: [AccessibilityElement],
        query: AccessibilityQuery,
        elementType: String? = nil
    ) throws -> (x: Double, y: Double) {
        try resolveTap(roots: roots, query: query, elementType: elementType).point
    }

    static func resolveElement(
        roots: [AccessibilityElement],
        query: AccessibilityQuery,
        elementType: String? = nil
    ) throws -> AccessibilityMatch {
        var allElements = roots.flatMap { $0.flattened() }

        if let elementType {
            allElements = allElements.filter { $0.type == elementType }
        }

        let matchedElement: AccessibilityElement
        let selectorDescription: String

        switch query {
        case .id(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedUniqueId == value }
            matchedElement = try selectUniqueMatch(matches, kind: "--id", value: rawValue)
            selectorDescription = "--id '\(rawValue)'"
        case .label(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedLabel == value }
            matchedElement = try selectBestLabelMatch(matches, value: rawValue)
            selectorDescription = "--label '\(rawValue)'"
        case .value(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedValue == value }
            matchedElement = try selectBestLabelMatch(matches, kind: "--value", value: rawValue)
            selectorDescription = "--value '\(rawValue)'"
        }

        return AccessibilityMatch(element: matchedElement, selectorDescription: selectorDescription)
    }

    static func resolveTap(
        roots: [AccessibilityElement],
        query: AccessibilityQuery,
        elementType: String? = nil
    ) throws -> TapResolution {
        let match = try resolveElement(roots: roots, query: query, elementType: elementType)

        let activationElement = try selectActivationElement(
            from: match.element,
            roots: roots,
            selectorDescription: match.selectorDescription,
            allowSiblingRedirection: query.allowsSiblingRedirection
        )

        guard let frame = activationElement.frame else {
            throw ElementResolutionError.invalidFrame(reason: "Matched element has no frame.")
        }
        guard frame.width > 0, frame.height > 0 else {
            throw ElementResolutionError.invalidFrame(reason: "Matched element has an invalid frame size (\(frame.width)x\(frame.height)).")
        }

        return TapResolution(
            point: activationPoint(for: activationElement, frame: frame),
            isSwitchLikeControl: activationElement.isSwitchLikeControl
        )
    }

    private static func activationPoint(
        for element: AccessibilityElement,
        frame: AccessibilityElement.Frame
    ) -> (x: Double, y: Double) {
        let centerY = frame.y + (frame.height / 2.0)

        if element.isSwitchLikeControl, frame.width > wideSwitchActivationWidthThreshold {
            return (x: frame.x + frame.width - switchTrailingActivationInset, y: centerY)
        }

        return (x: frame.x + (frame.width / 2.0), y: centerY)
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
        kind: String = "--label",
        value: String
    ) throws -> AccessibilityElement {
        let switchLikeMatches = matches.filter(\.isSwitchLikeControl)
        if switchLikeMatches.count == 1 {
            return switchLikeMatches[0]
        }
        if switchLikeMatches.count > 1 {
            return try selectUniqueMatch(switchLikeMatches, kind: kind, value: value)
        }

        let actionableMatches = matches.filter(\.isActionable)
        if actionableMatches.count == 1 {
            return actionableMatches[0]
        }

        if actionableMatches.count > 1 {
            return try selectUniqueMatch(actionableMatches, kind: kind, value: value)
        }

        return try selectUniqueMatch(matches, kind: kind, value: value)
    }

    private static func selectActivationElement(
        from matchedElement: AccessibilityElement,
        roots: [AccessibilityElement],
        selectorDescription: String,
        allowSiblingRedirection: Bool
    ) throws -> AccessibilityElement {
        if matchedElement.isSwitchLikeControl {
            return matchedElement
        }

        let switchDescendants = matchedElement.switchLikeDescendantsIncludingSelf()
        if !switchDescendants.isEmpty {
            guard switchDescendants.count == 1 else {
                throw ElementResolutionError.multipleSwitchDescendants(
                    count: switchDescendants.count,
                    selectorDescription: selectorDescription
                )
            }
            return switchDescendants[0]
        }

        if matchedElement.isActionable {
            return matchedElement
        }

        if allowSiblingRedirection, let ancestor = nearestAncestor(of: matchedElement, in: roots) {
            let siblingSwitches = directSwitchLikeChildren(of: ancestor)
            if siblingSwitches.count == 1 {
                return siblingSwitches[0]
            }
        }

        return matchedElement
    }

    private static func directSwitchLikeChildren(of element: AccessibilityElement) -> [AccessibilityElement] {
        element.children?.filter(\.isSwitchLikeControl) ?? []
    }

    private static func nearestAncestor(
        of matchedElement: AccessibilityElement,
        in roots: [AccessibilityElement]
    ) -> AccessibilityElement? {
        for root in roots {
            if let ancestor = nearestAncestor(of: matchedElement, in: root, parent: nil) {
                return ancestor
            }
        }
        return nil
    }

    private static func nearestAncestor(
        of matchedElement: AccessibilityElement,
        in currentElement: AccessibilityElement,
        parent: AccessibilityElement?
    ) -> AccessibilityElement? {
        if sameElement(currentElement, matchedElement) {
            return parent
        }

        for child in currentElement.children ?? [] {
            if let ancestor = nearestAncestor(of: matchedElement, in: child, parent: currentElement) {
                return ancestor
            }
        }
        return nil
    }

    private static func sameElement(_ lhs: AccessibilityElement, _ rhs: AccessibilityElement) -> Bool {
        if let lhsID = lhs.normalizedStableUniqueId, let rhsID = rhs.normalizedStableUniqueId {
            return lhsID == rhsID
        }

        guard lhs.type == rhs.type,
              lhs.normalizedLabel == rhs.normalizedLabel,
              lhs.normalizedValue == rhs.normalizedValue,
              sameFrame(lhs.frame, rhs.frame) else {
            return false
        }

        if lhs.normalizedLabel == nil && lhs.normalizedValue == nil {
            return lhs.role == rhs.role
                && lhs.roleDescription == rhs.roleDescription
                && lhs.subrole == rhs.subrole
        }

        return true
    }

    private static func sameFrame(_ lhs: AccessibilityElement.Frame?, _ rhs: AccessibilityElement.Frame?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.x == rhs.x
            && lhs.y == rhs.y
            && lhs.width == rhs.width
            && lhs.height == rhs.height
    }
}
