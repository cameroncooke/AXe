import Foundation

/// Decides whether a decision made on an observed screen is still valid on a fresh observation.
///
/// A whole-hierarchy hash changes for reasons the model never saw (frames of animating or hidden
/// elements), so the check is tiered like rs/1 ref resolution in XcodeBuildMCP: accept when the
/// compact rows sent to the model are unchanged, otherwise re-resolve the chosen element semantically.
public enum AgentFreshness {
    public enum Reason: String, Codable, Sendable {
        /// Full screen hash is identical.
        case unchanged
        /// Only details outside the compact rs/1 rows changed.
        case sameCompactRows
        /// The chosen element was re-resolved uniquely on the fresh screen.
        case targetResolved
        /// The operation does not depend on the current screen.
        case screenIndependent
        /// The decision can no longer be trusted.
        case stale
    }

    public struct Outcome: Sendable {
        public let reason: Reason
        /// The decision to execute, with its element taken from the fresh screen; nil when stale.
        public let decision: AgentDecision?
    }

    public static func evaluate(
        _ decision: AgentDecision,
        observed: AgentScreenSnapshot,
        fresh: AgentScreenSnapshot
    ) -> Outcome {
        if observed.fingerprint == fresh.fingerprint {
            return Outcome(reason: .unchanged, decision: decision)
        }

        let sameRows = compactRowsKey(observed.elements) == compactRowsKey(fresh.elements)

        switch decision.operation {
        case .openApp, .wait:
            return Outcome(reason: .screenIndependent, decision: decision)

        case .tap, .typeText, .clearText, .scrollDown, .scrollUp:
            guard let element = decision.element else {
                // Viewport scroll: valid while the viewport is unchanged.
                return observed.viewport == fresh.viewport
                    ? Outcome(reason: .screenIndependent, decision: decision)
                    : stale
            }
            // New or removed targets mean the context changed (a sheet, alert or screen appeared), even
            // if the chosen element still resolves behind it. Text and position changes are tolerated.
            guard sameRows || targetRowsKey(observed.elements) == targetRowsKey(fresh.elements),
                  let resolved = resolve(element, for: decision.operation, in: fresh.elements) else {
                return stale
            }
            return Outcome(
                reason: sameRows ? .sameCompactRows : .targetResolved,
                decision: decision.replacingElement(resolved)
            )

        case .pressReturn, .done, .blocked:
            // Terminal and focus-dependent decisions also require unchanged target positions: during a
            // navigation push both screens are in the hierarchy with identical rows but moving frames.
            return sameRows && targetLayoutKey(observed.elements) == targetLayoutKey(fresh.elements)
                ? Outcome(reason: .sameCompactRows, decision: decision)
                : stale
        }
    }

    /// Finds the fresh element matching a previously chosen one by role and a unique identifier,
    /// label or value (the rs/1 semantic selector order), falling back to an identical frame for
    /// unlabelled elements such as scroll areas.
    public static func resolve(
        _ element: RuntimeSnapshotElement,
        for operation: AgentOperation,
        in elements: [RuntimeSnapshotElement]
    ) -> RuntimeSnapshotElement? {
        guard let action = requiredAction(for: operation) else { return nil }
        let candidates = elements.filter { $0.role == element.role && $0.actions.contains(action) }

        func unique(_ matches: (RuntimeSnapshotElement) -> Bool) -> RuntimeSnapshotElement? {
            let matched = candidates.filter(matches)
            return matched.count == 1 ? matched[0] : nil
        }

        // Missing or ambiguous matches fall through to the next selector, as in rs/1 semantic taps.
        if let identifier = element.identifier, identifier != "label-view",
           let match = unique({ $0.identifier == identifier }) {
            return match
        }
        if let label = element.label, let match = unique({ $0.label == label }) {
            return match
        }
        if let value = element.value, let match = unique({ $0.value == value }) {
            return match
        }
        return unique { $0.frame == element.frame && $0.label == element.label && $0.value == element.value }
    }

    private static let stale = Outcome(reason: .stale, decision: nil)

    private static func requiredAction(for operation: AgentOperation) -> RuntimeElementAction? {
        switch operation {
        case .tap:
            return .tap
        case .typeText, .clearText:
            return .typeText
        case .scrollDown, .scrollUp:
            return .swipeWithin
        default:
            return nil
        }
    }

    /// The rows the model sees, without refs (which follow traversal order), as an order-insensitive key.
    static func compactRowsKey(_ elements: [RuntimeSnapshotElement]) -> String {
        rowsKey(
            RuntimeSnapshotCompactor.targets(in: elements)
                + RuntimeSnapshotCompactor.scrollAreas(in: elements)
                + RuntimeSnapshotCompactor.text(in: elements)
        )
    }

    /// Target and scroll rows only, so text updates do not invalidate a resolved target.
    static func targetRowsKey(_ elements: [RuntimeSnapshotElement]) -> String {
        rowsKey(RuntimeSnapshotCompactor.targets(in: elements) + RuntimeSnapshotCompactor.scrollAreas(in: elements))
    }

    /// Target and scroll rows with their frames.
    static func targetLayoutKey(_ elements: [RuntimeSnapshotElement]) -> String {
        let rows = RuntimeSnapshotCompactor.targets(in: elements) + RuntimeSnapshotCompactor.scrollAreas(in: elements)
        return rows
            .map { row in
                let frame = row.element.frame
                return "\(row.text.drop(while: { $0 != "|" }))|\(frame.x),\(frame.y),\(frame.width),\(frame.height)"
            }
            .sorted()
            .joined(separator: "\n")
    }

    private static func rowsKey(_ rows: [RuntimeSnapshotRow]) -> String {
        rows
            .map { $0.text.drop(while: { $0 != "|" }) }
            .map(String.init)
            .sorted()
            .joined(separator: "\n")
    }
}

extension AgentDecision {
    func replacingElement(_ element: RuntimeSnapshotElement) -> AgentDecision {
        AgentDecision(
            operation: operation,
            element: element,
            application: application,
            text: text,
            operationConfidence: operationConfidence,
            operationProbability: operationProbability,
            targetConfidence: targetConfidence,
            targetProbability: targetProbability
        )
    }
}
