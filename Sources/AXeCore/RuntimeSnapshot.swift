import Foundation

// Swift port of XcodeBuildMCP's rs/1 runtime snapshot
// (src/mcp/tools/ui-automation/shared/runtime-snapshot.ts and the compact projection in
// src/utils/structured-output-envelope.ts). The raw accessibility hierarchy is normalised into
// ref-addressed elements with derived roles and actions, then projected into compact
// `ref|action|role|label|value|id` rows for the model.

public enum RuntimeSnapshotProtocol {
    public static let version = "rs/1"
    public static let compactColumns = "ref|action|role|label|value|id"
    public static let targetLimit = 64
    public static let scrollLimit = 32
    public static let textLimit = 64
}

public enum RuntimeElementRole: String, Codable, Sendable {
    case application
    case button
    case cell
    case image
    case keyboardKey = "keyboard-key"
    case list
    case menu
    case other
    case scrollView = "scroll-view"
    case slider
    case `switch`
    case tab
    case text
    case textField = "text-field"
    case window
}

public enum RuntimeElementAction: String, Codable, Sendable {
    case tap
    case typeText
    case longPress
    case touch
    case swipeWithin
}

public enum RuntimeSwipeDirection: String, Codable, Sendable {
    case up
    case down
    case left
    case right
}

public struct RuntimeElementState: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var visible: Bool

    public init(enabled: Bool, visible: Bool) {
        self.enabled = enabled
        self.visible = visible
    }
}

/// Accessibility node input for the snapshot builder, decoupled from AXe's describe-ui decoding.
public struct RuntimeSnapshotNode: Sendable {
    public let type: String?
    public let role: String?
    public let subrole: String?
    public let roleDescription: String?
    public let label: String?
    public let value: String?
    public let identifier: String?
    public let frame: AgentFrame?
    public let enabled: Bool?
    public let customActions: [String]
    /// Exact names for observation only; these do not grant input actions.
    public let customActionNames: [String]
    public let children: [RuntimeSnapshotNode]

    public init(
        type: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        roleDescription: String? = nil,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        frame: AgentFrame? = nil,
        enabled: Bool? = nil,
        customActions: [String] = [],
        customActionNames: [String] = [],
        children: [RuntimeSnapshotNode] = []
    ) {
        self.type = type
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.enabled = enabled
        self.customActions = customActions
        self.customActionNames = customActionNames
        self.children = children
    }
}

public struct RuntimeSnapshotElement: Codable, Equatable, Sendable {
    public let ref: String
    public let role: RuntimeElementRole?
    public let label: String?
    public let value: String?
    public let identifier: String?
    public let frame: AgentFrame
    public internal(set) var state: RuntimeElementState
    public internal(set) var actions: [RuntimeElementAction]
    /// Dot-separated child indices from the hierarchy root, used to find ancestors.
    public let path: String
    /// Read-only names from the accessibility provider, without input authority.
    public let customActionNames: [String]
    public internal(set) var activationPointOverride: AgentPoint?
    public internal(set) var swipeFrame: AgentFrame?

    public init(
        ref: String,
        role: RuntimeElementRole?,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        frame: AgentFrame,
        state: RuntimeElementState? = nil,
        actions: [RuntimeElementAction],
        path: String? = nil,
        activationPointOverride: AgentPoint? = nil,
        swipeFrame: AgentFrame? = nil,
        customActionNames: [String] = []
    ) {
        self.ref = ref
        self.role = role
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.state = state ?? RuntimeElementState(enabled: true, visible: RuntimeSnapshotBuilder.isVisible(frame))
        self.actions = actions
        self.path = path ?? ref
        self.activationPointOverride = activationPointOverride
        self.swipeFrame = swipeFrame
        self.customActionNames = customActionNames
    }

    private enum CodingKeys: String, CodingKey {
        case ref, role, label, value, identifier, frame, state, actions, path
        case activationPointOverride, swipeFrame, customActionNames
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ref: try values.decode(String.self, forKey: .ref),
            role: try values.decodeIfPresent(RuntimeElementRole.self, forKey: .role),
            label: try values.decodeIfPresent(String.self, forKey: .label),
            value: try values.decodeIfPresent(String.self, forKey: .value),
            identifier: try values.decodeIfPresent(String.self, forKey: .identifier),
            frame: try values.decode(AgentFrame.self, forKey: .frame),
            state: try values.decode(RuntimeElementState.self, forKey: .state),
            actions: try values.decode([RuntimeElementAction].self, forKey: .actions),
            path: try values.decode(String.self, forKey: .path),
            activationPointOverride: try values.decodeIfPresent(AgentPoint.self, forKey: .activationPointOverride),
            swipeFrame: try values.decodeIfPresent(AgentFrame.self, forKey: .swipeFrame),
            customActionNames: try values.decodeIfPresent([String].self, forKey: .customActionNames) ?? [])
    }

    public var displayName: String {
        label ?? identifier ?? value ?? role?.rawValue ?? ref
    }

    public var activationPoint: AgentPoint {
        activationPointOverride ?? defaultActivationPoint
    }

    var defaultActivationPoint: AgentPoint {
        if role == .switch, frame.width > 120 {
            return AgentPoint(
                x: RuntimeSnapshotBuilder.jsRound(frame.x + frame.width - 52),
                y: RuntimeSnapshotBuilder.jsRound(frame.y + frame.height / 2)
            )
        }
        return RuntimeSnapshotBuilder.roundedCentre(of: frame)
    }

    /// Logical swipe points inside this element, matching rs/1 `swipe --within-element-ref`.
    public func swipePoints(
        direction: RuntimeSwipeDirection,
        distance: Double = 1
    ) -> (from: AgentPoint, to: AgentPoint)? {
        RuntimeSnapshotBuilder.swipePoints(
            in: swipeFrame ?? frame,
            role: role,
            direction: direction,
            distance: distance
        )
    }
}

public enum RuntimeSnapshotBuilder {
    /// Preserve the original raw snapshot entry point and inferred native viewport.
    public static func elements(from roots: [RuntimeSnapshotNode]) -> [RuntimeSnapshotElement] {
        elements(from: roots, viewport: nil)
    }

    /// Conservative physical-hit assessment, before availability or viewport filtering.
    /// This shares the normal role/action rules and does not authorize an input target.
    public static func hasPotentialTapAction(_ node: RuntimeSnapshotNode) -> Bool {
        let element = normalize(node, path: "", index: 0, ignoringAvailability: true)
        return element.actions.contains(.tap) || element.actions.contains(.typeText)
    }

    /// Container semantics before state, viewport or public-row filtering.
    /// Cells can accept a swipe but are not independent scroll containers.
    public static func hasPotentialScrollContainerAction(_ node: RuntimeSnapshotNode) -> Bool {
        let element = normalize(node, path: "", index: 0, ignoringAvailability: true)
        return element.role == .scrollView || element.role == .list
    }

    /// A verified selected-display viewport overrides the native root frame, which can remain
    /// in portrait coordinates after simulator rotation. Nil preserves raw hierarchy behaviour.
    public static func elements(from roots: [RuntimeSnapshotNode], viewport: AgentFrame?) -> [RuntimeSnapshotElement] {
        var flattened: [(node: RuntimeSnapshotNode, path: String)] = []
        func visit(_ node: RuntimeSnapshotNode, path: String) {
            flattened.append((node, path))
            for (index, child) in node.children.enumerated() {
                visit(child, path: "\(path).\(index)")
            }
        }
        for (index, root) in roots.enumerated() {
            visit(root, path: String(index))
        }

        var elements = flattened.enumerated().map { index, entry in
            normalize(entry.node, path: entry.path, index: index)
        }
        applyViewportVisibility(&elements, viewport: viewport)
        inferScrollableContainers(&elements)
        return elements
    }

    public static func viewportFrame(in elements: [RuntimeSnapshotElement]) -> AgentFrame? {
        elements.first {
            ($0.role == .application || $0.role == .window) && isVisible($0.frame)
        }?.frame
    }

    /// Order-insensitive screen hash. rs/1 hashes elements in traversal order, but some hierarchies
    /// (SpringBoard icon grids) reorder siblings between reads, so refs and paths are excluded and
    /// element rows are sorted before hashing.
    public static func screenHash(of elements: [RuntimeSnapshotElement]) -> String {
        let rows = elements.map { element in
            [
                element.role?.rawValue ?? "",
                element.label ?? "",
                element.value ?? "",
                element.identifier ?? "",
                String(element.frame.x),
                String(element.frame.y),
                String(element.frame.width),
                String(element.frame.height),
                String(element.state.enabled),
                String(element.state.visible),
                element.actions.map(\.rawValue).joined(separator: ","),
                element.customActionNames.map { "\($0.utf8.count):\($0)" }.joined(),
            ].joined(separator: "\u{1F}")
        }
        return fnv1a64(RuntimeSnapshotProtocol.version + "\n" + rows.sorted().joined(separator: "\n"))
    }

    /// Collapses whitespace runs and trims, returning nil for empty text.
    public static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Normalisation

    private static func normalize(
        _ node: RuntimeSnapshotNode,
        path: String,
        index: Int,
        ignoringAvailability: Bool = false
    ) -> RuntimeSnapshotElement {
        let frame = normalizedFrame(node.frame ?? AgentFrame(x: 0, y: 0, width: 0, height: 0))
        // Display content is exact. Search and capability checks normalize separately.
        let label = node.label
        let value = node.value
        let identifier = normalizedText(node.identifier)
        let role = deriveRole(node, identifier: identifier)
        let enabled = node.enabled != false
        let customActions = node.customActions.compactMap(normalizedText)
        let actions = deriveActions(
            role: role,
            enabled: enabled,
            frame: frame,
            hasCustomActions: !customActions.isEmpty,
            hasSemanticIdentity: normalizedText(label) != nil
                || normalizedText(value) != nil
                || (identifier != nil && !isGenericInternalIdentifier(identifier)),
            ignoringAvailability: ignoringAvailability
        )

        return RuntimeSnapshotElement(
            ref: "e\(index + 1)",
            role: role,
            label: label,
            value: value,
            identifier: identifier,
            frame: frame,
            state: RuntimeElementState(enabled: enabled, visible: isVisible(frame)),
            actions: actions,
            path: path,
            customActionNames: node.customActionNames
        )
    }

    private static func normalizedFrame(_ frame: AgentFrame) -> AgentFrame {
        func round2(_ value: Double) -> Double {
            value.isFinite ? (value * 100).rounded() / 100 : 0
        }
        return AgentFrame(
            x: round2(frame.x),
            y: round2(frame.y),
            width: round2(frame.width),
            height: round2(frame.height)
        )
    }

    static func deriveRole(_ node: RuntimeSnapshotNode, identifier: String?) -> RuntimeElementRole? {
        if normalizedText(node.roleDescription)?.lowercased() == "tab" {
            return .tab
        }

        let roleText = [node.role, node.type, node.subrole, node.roleDescription]
            .compactMap { normalizedText($0)?.lowercased() }
            .joined(separator: " ")

        if roleText.isEmpty { return nil }
        if roleText.contains("application") { return .application }
        if roleText.contains("window") { return .window }
        if roleText.contains("button") { return .button }
        if roleText.contains("key") { return .keyboardKey }
        if ["textfield", "text field", "searchfield", "search field", "securetext", "textarea", "textview", "text view", "combo box"]
            .contains(where: roleText.contains) {
            return .textField
        }
        if roleText.contains("menu") { return .menu }
        if roleText.contains("text") { return .text }
        if roleText.contains("image") { return .image }
        if ["switch", "checkbox", "check box"].contains(where: roleText.contains) { return .switch }
        if roleText.contains("slider") { return .slider }
        if roleText.contains("cell") || roleText.contains("row") { return .cell }
        if roleText.contains("scroll") { return .scrollView }
        if ["table", "list", "outline", "collection"].contains(where: roleText.contains) { return .list }
        if hasScrollSemanticIdentifier(identifier),
           ["group", "other", "view", "container"].contains(where: roleText.contains) {
            return .scrollView
        }
        if matches(#"(^|\b|ax)tab(\b|group|$)"#, roleText) { return .tab }
        return .other
    }

    private static func hasScrollSemanticIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return matches(
            #"(?:^|[._-])scroll(?:view|[-_.]view)?(?:$|[._-])|scrollView"#,
            identifier,
            options: [.caseInsensitive]
        )
    }

    private static func isGenericInternalIdentifier(_ identifier: String?) -> Bool {
        identifier == "label-view"
    }

    private static func isTapRole(_ role: RuntimeElementRole?) -> Bool {
        switch role {
        case .button, .cell, .keyboardKey, .switch, .tab, .textField:
            return true
        default:
            return false
        }
    }

    private static func deriveActions(
        role: RuntimeElementRole?,
        enabled: Bool,
        frame: AgentFrame,
        hasCustomActions: Bool,
        hasSemanticIdentity: Bool,
        ignoringAvailability: Bool = false
    ) -> [RuntimeElementAction] {
        guard ignoringAvailability || (enabled && isVisible(frame)) else { return [] }

        var actions: [RuntimeElementAction] = []
        if isTapRole(role) || (hasCustomActions && hasSemanticIdentity) {
            actions.append(.tap)
        }
        if role == .textField {
            actions.append(.typeText)
        }
        if role != .application && role != .window {
            actions.append(.longPress)
            actions.append(.touch)
        }
        if role == .scrollView || role == .list || role == .cell {
            actions.append(.swipeWithin)
        }
        return actions
    }

    // MARK: - Viewport visibility

    private static func applyViewportVisibility(_ elements: inout [RuntimeSnapshotElement], viewport: AgentFrame?) {
        guard let viewport = viewport ?? viewportFrame(in: elements) else { return }

        for index in elements.indices {
            let element = elements[index]
            if element.role == .application || element.role == .window {
                continue
            }

            if !framesIntersect(element.frame, viewport) {
                elements[index].state.visible = false
                elements[index].actions = []
                continue
            }

            if !point(element.defaultActivationPoint, isInside: viewport) {
                elements[index].actions = element.actions.filter { $0 == .swipeWithin }
                continue
            }

            if let adjusted = bottomClippedActivationPoint(for: element, viewport: viewport) {
                elements[index].activationPointOverride = adjusted
            }
        }
    }

    private static func bottomClippedActivationPoint(
        for element: RuntimeSnapshotElement,
        viewport: AgentFrame
    ) -> AgentPoint? {
        let hasPointAction = element.actions.contains {
            $0 == .tap || $0 == .typeText || $0 == .longPress || $0 == .touch
        }
        guard hasPointAction else { return nil }

        let defaultPoint = element.defaultActivationPoint
        guard defaultPoint.y >= viewport.y + viewport.height * 0.93 else { return nil }

        let frame = element.frame
        let verticalOffset = min(max(frame.height * 0.1, 8), frame.height / 2)
        let adjusted = AgentPoint(x: defaultPoint.x, y: jsRound(frame.y + verticalOffset))
        guard point(adjusted, isInside: frame), point(adjusted, isInside: viewport) else {
            return nil
        }
        return adjusted
    }

    // MARK: - Scroll inference

    private struct DescendantSummary {
        var hasOverflowingDescendant = false
        var hasSemanticVerticalOverflowingDescendant = false
        var hasSheetGrabberDescendant = false
        var hasPreferredDescendantSwipeTarget = false
    }

    private static func ancestorIndices(
        of element: RuntimeSnapshotElement,
        indexByPath: [String: Int]
    ) -> [Int] {
        var result: [Int] = []
        var path = Substring(element.path)
        while let separator = path.lastIndex(of: ".") {
            path = path[..<separator]
            if let index = indexByPath[String(path)] {
                result.append(index)
            }
        }
        return result
    }

    private static func inferScrollableContainers(_ elements: inout [RuntimeSnapshotElement]) {
        let indexByPath = Dictionary(
            elements.enumerated().map { ($0.element.path, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var summaries = Array(repeating: DescendantSummary(), count: elements.count)

        for descendant in elements {
            for ancestorIndex in ancestorIndices(of: descendant, indexByPath: indexByPath) {
                let ancestorFrame = elements[ancestorIndex].frame
                if frameOverflows(descendant.frame, container: ancestorFrame) {
                    summaries[ancestorIndex].hasOverflowingDescendant = true
                }
                if hasSemanticIdentity(descendant),
                   isVisible(descendant.frame),
                   frameVerticallyOverflows(descendant.frame, container: ancestorFrame) {
                    summaries[ancestorIndex].hasSemanticVerticalOverflowingDescendant = true
                }
                if normalizedText(descendant.label)?.lowercased() == "sheet grabber" {
                    summaries[ancestorIndex].hasSheetGrabberDescendant = true
                }
            }
        }

        for index in elements.indices {
            let element = elements[index]
            guard isContainerRole(element.role),
                  element.state.enabled,
                  element.state.visible,
                  isVisible(element.frame),
                  isLargeEnoughInferredScrollContainer(element),
                  !element.actions.contains(.swipeWithin) else {
                continue
            }
            let isViewportRole = element.role == .application || element.role == .window
            if isViewportRole, summaries[index].hasSheetGrabberDescendant {
                continue
            }
            if !isViewportRole, summaries[index].hasOverflowingDescendant {
                elements[index].actions.append(.swipeWithin)
            }
        }

        for descendant in elements where isPreferredSwipeTarget(descendant) {
            for ancestorIndex in ancestorIndices(of: descendant, indexByPath: indexByPath) {
                summaries[ancestorIndex].hasPreferredDescendantSwipeTarget = true
            }
        }

        for index in elements.indices {
            let element = elements[index]
            let summary = summaries[index]
            let isTopLevelViewport = (element.role == .application || element.role == .window)
                && !element.path.contains(".")
            guard isTopLevelViewport,
                  element.state.enabled,
                  element.state.visible,
                  isVisible(element.frame),
                  !element.actions.contains(.swipeWithin),
                  !summary.hasSheetGrabberDescendant,
                  !summary.hasPreferredDescendantSwipeTarget,
                  summary.hasSemanticVerticalOverflowingDescendant else {
                continue
            }
            elements[index].actions.append(.swipeWithin)
            elements[index].swipeFrame = element.frame
        }

        pruneGenericFallbackSwipeTargets(&elements)
    }

    private static func isContainerRole(_ role: RuntimeElementRole?) -> Bool {
        switch role {
        case .application, .window, .scrollView, .list, .other:
            return true
        default:
            return false
        }
    }

    private static func isLargeEnoughInferredScrollContainer(_ element: RuntimeSnapshotElement) -> Bool {
        guard element.role == .other else { return true }
        return element.frame.width >= 120 && element.frame.height >= 120
    }

    private static func hasSemanticIdentity(_ element: RuntimeSnapshotElement) -> Bool {
        normalizedText(element.label) != nil
            || normalizedText(element.value) != nil
            || (element.identifier != nil && !isGenericInternalIdentifier(element.identifier))
    }

    private static func isUnidentifiedOtherSwipeTarget(_ element: RuntimeSnapshotElement) -> Bool {
        element.role == .other
            && element.actions.contains(.swipeWithin)
            && normalizedText(element.label) == nil
            && normalizedText(element.value) == nil
            && element.identifier == nil
    }

    private static func isPreferredSwipeTarget(_ element: RuntimeSnapshotElement) -> Bool {
        element.actions.contains(.swipeWithin) && !isUnidentifiedOtherSwipeTarget(element)
    }

    private static func pruneGenericFallbackSwipeTargets(_ elements: inout [RuntimeSnapshotElement]) {
        guard elements.contains(where: isPreferredSwipeTarget) else { return }
        for index in elements.indices where isUnidentifiedOtherSwipeTarget(elements[index]) {
            elements[index].actions.removeAll { $0 == .swipeWithin }
        }
    }

    // MARK: - Geometry

    static func isVisible(_ frame: AgentFrame) -> Bool {
        frame.width > 0 && frame.height > 0
    }

    private static func framesIntersect(_ a: AgentFrame, _ b: AgentFrame) -> Bool {
        a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
    }

    private static func point(_ point: AgentPoint, isInside frame: AgentFrame) -> Bool {
        point.x >= frame.x
            && point.x <= frame.x + frame.width
            && point.y >= frame.y
            && point.y <= frame.y + frame.height
    }

    private static func frameOverflows(_ frame: AgentFrame, container: AgentFrame) -> Bool {
        let tolerance = 8.0
        return frame.x < container.x - tolerance
            || frame.y < container.y - tolerance
            || frame.x + frame.width > container.x + container.width + tolerance
            || frame.y + frame.height > container.y + container.height + tolerance
    }

    private static func frameVerticallyOverflows(_ frame: AgentFrame, container: AgentFrame) -> Bool {
        let tolerance = 8.0
        return frame.y < container.y - tolerance
            || frame.y + frame.height > container.y + container.height + tolerance
    }

    /// JavaScript `Math.round` semantics, so points match XcodeBuildMCP exactly.
    static func jsRound(_ value: Double) -> Double {
        (value + 0.5).rounded(.down)
    }

    static func roundedCentre(of frame: AgentFrame) -> AgentPoint {
        AgentPoint(x: jsRound(frame.x + frame.width / 2), y: jsRound(frame.y + frame.height / 2))
    }

    static func swipePoints(
        in frame: AgentFrame,
        role: RuntimeElementRole?,
        direction: RuntimeSwipeDirection,
        distance: Double
    ) -> (from: AgentPoint, to: AgentPoint)? {
        guard frame.width >= 2, frame.height >= 2 else { return nil }

        var centre = roundedCentre(of: frame)
        if role == .application || role == .window, direction == .left || direction == .right {
            centre = AgentPoint(x: centre.x, y: jsRound(frame.y + frame.height * 0.6))
        }

        let horizontalInset = max(1, min(max(frame.width * 0.15, 24), frame.width / 3))
        let verticalInset = max(1, min(max(frame.height * 0.15, 24), frame.height / 3))
        let left = jsRound(frame.x + horizontalInset)
        let right = jsRound(frame.x + frame.width - horizontalInset)
        let top = jsRound(frame.y + verticalInset)
        let bottom = jsRound(frame.y + frame.height - verticalInset)

        let stroke = min(max(distance, 0), 1)
        let horizontalCentre = (left + right) / 2
        let verticalCentre = (top + bottom) / 2
        let horizontalHalfStroke = ((right - left) * stroke) / 2
        let verticalHalfStroke = ((bottom - top) * stroke) / 2

        let from: AgentPoint
        let to: AgentPoint
        switch direction {
        case .up:
            from = AgentPoint(x: centre.x, y: jsRound(verticalCentre + verticalHalfStroke))
            to = AgentPoint(x: centre.x, y: jsRound(verticalCentre - verticalHalfStroke))
        case .down:
            from = AgentPoint(x: centre.x, y: jsRound(verticalCentre - verticalHalfStroke))
            to = AgentPoint(x: centre.x, y: jsRound(verticalCentre + verticalHalfStroke))
        case .left:
            from = AgentPoint(x: jsRound(horizontalCentre + horizontalHalfStroke), y: centre.y)
            to = AgentPoint(x: jsRound(horizontalCentre - horizontalHalfStroke), y: centre.y)
        case .right:
            from = AgentPoint(x: jsRound(horizontalCentre - horizontalHalfStroke), y: centre.y)
            to = AgentPoint(x: jsRound(horizontalCentre + horizontalHalfStroke), y: centre.y)
        }

        guard from != to else { return nil }
        return (from, to)
    }

    private static func matches(
        _ pattern: String,
        _ value: String,
        options: NSRegularExpression.Options = []
    ) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}

// MARK: - Compact projection

public struct RuntimeSnapshotRow: Equatable, Sendable {
    public let element: RuntimeSnapshotElement
    /// Compact `ref|action|role|label|value|id` row.
    public let text: String
}

public enum RuntimeSnapshotCompactor {
    private static let hiddenTargetLabels: Set<String> = ["sheet grabber"]
    private static let lowPriorityTargetLabels: Set<String> = [
        "sheet grabber", "close", "clear search", "remove", "delete", "clear",
        "c", "ac", "±", "%", "÷", "×", "-", "+", "=",
    ]

    /// Tap and text-entry targets in rs/1 display priority order, capped at the compact limit.
    public static func targets(in elements: [RuntimeSnapshotElement], offset: Int = 0, limit: Int = RuntimeSnapshotProtocol.targetLimit) -> [RuntimeSnapshotRow] {
        let candidates = elements.enumerated().filter { _, element in
            !hiddenTargetLabels.contains(compactText(element.label).lowercased())
                && (element.actions.contains(.tap) || element.actions.contains(.typeText))
        }
        return candidates
            .sorted {
                let left = displayPriority($0.element)
                let right = displayPriority($1.element)
                return left == right ? $0.offset < $1.offset : left < right
            }
            .dropFirst(max(0, offset))
            .prefix(max(0, limit))
            .map { _, element in
                row(element, action: element.actions.contains(.typeText) ? "typeText" : "tap")
            }
    }

    public static func scrollAreas(in elements: [RuntimeSnapshotElement], offset: Int = 0, limit: Int = RuntimeSnapshotProtocol.scrollLimit) -> [RuntimeSnapshotRow] {
        elements
            .filter {
                $0.actions.contains(.swipeWithin)
                    && !$0.actions.contains(.tap)
                    && !$0.actions.contains(.typeText)
            }
            .dropFirst(max(0, offset))
            .prefix(max(0, limit))
            .map { row($0, action: "swipe") }
    }

    public static func text(in elements: [RuntimeSnapshotElement], offset: Int = 0, limit: Int = RuntimeSnapshotProtocol.textLimit) -> [RuntimeSnapshotRow] {
        elements.enumerated()
            .filter { _, element in
                (element.role == .text || element.role == .image)
                    && element.state.visible
                    && (!compactText(element.label).isEmpty || !compactText(element.value).isEmpty)
            }
            .sorted {
                if $0.element.frame.y != $1.element.frame.y { return $0.element.frame.y < $1.element.frame.y }
                if $0.element.frame.x != $1.element.frame.x { return $0.element.frame.x < $1.element.frame.x }
                return $0.offset < $1.offset
            }
            .dropFirst(max(0, offset))
            .prefix(max(0, limit))
            .map { row($0.element, action: "text") }
    }

    public static func row(_ element: RuntimeSnapshotElement, action: String) -> RuntimeSnapshotRow {
        let text = [
            element.ref,
            action,
            element.role?.rawValue ?? "",
            displayText(element.label),
            displayText(element.value),
            compactText(element.identifier),
        ].joined(separator: "|")
        return RuntimeSnapshotRow(element: element, text: text)
    }

    /// Keep exact visible whitespace. Pipe replacement is the existing RS/1 cell convention;
    /// native --read-ref text remains the exact path for a literal pipe.
    private static func displayText(_ value: String?) -> String {
        (value ?? "").replacingOccurrences(of: "|", with: "/")
    }

    private static func compactText(_ value: String?) -> String {
        (RuntimeSnapshotBuilder.normalizedText(value) ?? "").replacingOccurrences(of: "|", with: "/")
    }

    private static func displayPriority(_ element: RuntimeSnapshotElement) -> Int {
        let label = compactText(element.label)
        if lowPriorityTargetLabels.contains(label.lowercased()) {
            return 90
        }
        if compactText(element.value).lowercased() == "selected" {
            return 70
        }
        if element.actions.contains(.tap),
           label.contains(",") || label.count >= 24 || compactText(element.identifier).lowercased().hasSuffix("card") {
            return 0
        }
        if element.actions.contains(.typeText) {
            return 10
        }
        if element.actions.contains(.tap) {
            return 20
        }
        return 50
    }
}
