import AXeCore
import Foundation
import FBControlCore

@MainActor
struct AgentScreenObserver {
    let simulatorUDID: String
    let logger: AxeLogger

    func observe(currentApplication: AgentApplication?) async throws -> AgentScreenSnapshot {
        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(
            for: simulatorUDID,
            logger: logger
        )
        guard !roots.isEmpty else {
            throw CLIError(errorDescription: "The frontmost application returned an empty accessibility hierarchy.")
        }

        let applicationRoot = roots.first(where: { $0.type == "Application" }) ?? roots.first
        let applicationFrame = applicationRoot?.frame.map(Self.agentFrame)
        let applicationName = currentApplication?.name
            ?? applicationRoot?.normalizedLabel
            ?? applicationRoot?.normalizedValue
        let bundleIdentifier = currentApplication?.bundleIdentifier

        let contextualElements = roots.flatMap {
            Self.contextualElements(from: $0, inheritedLabel: nil)
        }
        let flattened = contextualElements.map(\.element)
        let candidates = contextualElements.compactMap { context -> (AgentObservedElement, Int)? in
            let element = context.element
            guard let frame = element.frame.map(Self.agentFrame), frame.isValid else { return nil }
            guard Self.isVisible(frame, within: applicationFrame) else { return nil }

            let supportsTextEntry = Self.supportsTextEntry(element)
            let supportsTap = Self.supportsTap(element, applicationFrame: applicationFrame)
            guard supportsTextEntry || supportsTap else { return nil }

            let stableMaterial = [
                element.normalizedStableUniqueId,
                element.normalizedUniqueId,
                element.type,
                element.role,
                context.displayLabel,
                element.normalizedValue,
                String(frame.x),
                String(frame.y),
                String(frame.width),
                String(frame.height),
            ]
            .compactMap { $0 }
            .joined(separator: "|")
            let stableKey = AgentScreenFingerprint.hash(stableMaterial)

            let observed = AgentObservedElement(
                stableKey: stableKey,
                type: element.type,
                role: element.role,
                roleDescription: element.roleDescription,
                label: Self.trimmed(context.displayLabel, maximumLength: 500),
                identifier: Self.trimmed(element.normalizedUniqueId, maximumLength: 500),
                value: Self.trimmed(element.normalizedValue, maximumLength: 500),
                frame: frame,
                isSwitchLike: element.isSwitchLikeControl,
                supportsTap: supportsTap,
                supportsTextEntry: supportsTextEntry
            )

            let priority: Int
            if supportsTextEntry {
                priority = 0
            } else if element.isActionable {
                priority = 1
            } else if element.normalizedUniqueId != nil {
                priority = 2
            } else {
                priority = 3
            }
            return (observed, priority)
        }

        var seen = Set<String>()
        let elements = candidates
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.0.frame.y != $1.0.frame.y { return $0.0.frame.y < $1.0.frame.y }
                if $0.0.frame.x != $1.0.frame.x { return $0.0.frame.x < $1.0.frame.x }
                // Break ties independently of traversal order so the 160-element cap is stable.
                return $0.0.stableKey < $1.0.stableKey
            }
            .compactMap { candidate -> AgentObservedElement? in
                guard seen.insert(candidate.0.stableKey).inserted else { return nil }
                return candidate.0
            }
            .prefix(160)

        let screenTextLines = Self.screenTextLines(from: flattened)
        let screenText = String(screenTextLines.joined(separator: "\n").prefix(8_000))

        return AgentScreenSnapshot(
            fingerprint: AgentScreenFingerprint.make(
                screenTextLines: screenTextLines,
                elements: Array(elements)
            ),
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            text: screenText,
            applicationFrame: applicationFrame,
            elements: Array(elements)
        )
    }

    private struct ContextualElement {
        let element: AccessibilityElement
        let displayLabel: String?
    }

    private static func contextualElements(
        from element: AccessibilityElement,
        inheritedLabel: String?
    ) -> [ContextualElement] {
        let ownLabel = element.normalizedLabel
        let children = element.children ?? []
        let directDescriptiveLabels = children.compactMap { child -> String? in
            guard !child.isSwitchLikeControl else { return nil }
            guard let label = child.normalizedLabel, !isGenericControlState(label) else { return nil }
            return label
        }
        let containerLabel = ownLabel.flatMap { isGenericControlState($0) ? nil : $0 }
            ?? directDescriptiveLabels.first
            ?? inheritedLabel
        let displayLabel: String?
        if element.isSwitchLikeControl,
           ownLabel == nil || ownLabel.map(isGenericControlState) == true {
            displayLabel = containerLabel ?? ownLabel
        } else {
            displayLabel = ownLabel ?? (element.isActionable ? containerLabel : nil)
        }

        var result = [ContextualElement(element: element, displayLabel: displayLabel)]
        for (index, child) in children.enumerated() {
            let siblingLabel = children.enumerated().first { siblingIndex, sibling in
                siblingIndex != index
                    && !sibling.isSwitchLikeControl
                    && sibling.normalizedLabel.map { !isGenericControlState($0) } == true
            }?.element.normalizedLabel
            let childContext = ownLabel.flatMap { isGenericControlState($0) ? nil : $0 }
                ?? siblingLabel
                ?? containerLabel
            result.append(contentsOf: contextualElements(from: child, inheritedLabel: childContext))
        }
        return result
    }

    private static func isGenericControlState(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["on", "off", "yes", "no", "true", "false", "0", "1"].contains(normalized)
    }

    private static func supportsTextEntry(_ element: AccessibilityElement) -> Bool {
        let textTypes: Set<String> = [
            "TextField",
            "SecureTextField",
            "SearchField",
            "TextView",
            "TextArea",
        ]
        if let type = element.type, textTypes.contains(type) {
            return true
        }
        let role = [element.role, element.subrole, element.roleDescription]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return role.contains("textfield") || role.contains("text field") || role.contains("textarea")
    }

    private static func supportsTap(
        _ element: AccessibilityElement,
        applicationFrame: AgentFrame?
    ) -> Bool {
        if element.isActionable || supportsTextEntry(element) {
            return true
        }
        guard element.normalizedLabel != nil || element.normalizedUniqueId != nil else {
            return false
        }

        let supplementaryTypes: Set<String> = ["StaticText", "Image", "Icon", "Other"]
        guard element.type.map(supplementaryTypes.contains) == true else {
            return false
        }
        guard let frame = element.frame.map(agentFrame) else { return false }
        if let applicationFrame {
            let applicationArea = applicationFrame.width * applicationFrame.height
            let elementArea = frame.width * frame.height
            if applicationArea > 0, elementArea > applicationArea * 0.65 {
                return false
            }
        }
        return true
    }

    private static func isVisible(_ frame: AgentFrame, within applicationFrame: AgentFrame?) -> Bool {
        guard let applicationFrame else { return true }
        let right = frame.x + frame.width
        let bottom = frame.y + frame.height
        let applicationRight = applicationFrame.x + applicationFrame.width
        let applicationBottom = applicationFrame.y + applicationFrame.height
        return right > applicationFrame.x
            && bottom > applicationFrame.y
            && frame.x < applicationRight
            && frame.y < applicationBottom
    }

    /// Returns every distinct line, untruncated, so the fingerprint does not depend on which
    /// lines fall inside the model's text limit.
    private static func screenTextLines(from elements: [AccessibilityElement]) -> [String] {
        var seen = Set<String>()
        var lines: [String] = []
        for element in elements {
            let label = trimmed(element.normalizedLabel, maximumLength: 500)
            let value = trimmed(element.normalizedValue, maximumLength: 500)
            let line: String?
            switch (label, value) {
            case let (label?, value?) where label.caseInsensitiveCompare(value) != .orderedSame:
                line = "\(label): \(value)"
            case let (label?, _):
                line = label
            case let (_, value?):
                line = value
            default:
                line = nil
            }
            guard let line, seen.insert(line).inserted else { continue }
            lines.append(line)
        }
        return lines
    }

    private static func agentFrame(_ frame: AccessibilityElement.Frame) -> AgentFrame {
        AgentFrame(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    private static func trimmed(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }
}
