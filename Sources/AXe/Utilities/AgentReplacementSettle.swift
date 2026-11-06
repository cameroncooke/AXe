import Foundation
import FBSimulatorControl

/// Decides whether a post-action replacement read may still be mid-transition.
/// An in-place change (a label, a value, a toggle) touches a few nodes and is published at once.
/// A screen transition (a push, a sheet, a keyboard) adds, removes or moves many nodes; that
/// replacement is confirmed by two equal consecutive reads before publication.
enum AgentReplacementSettle {
    /// More changed node signatures than this is treated as a possible transition.
    static let maximumInPlaceChanges = 6

    static func isLargeChange(from before: AgentModeSnapshot, to after: AgentModeSnapshot) -> Bool {
        guard before.nativeFingerprint != after.nativeFingerprint else { return false }
        let old = signatures(before.nodes)
        let new = signatures(after.nodes)
        var changes = 0
        for (signature, count) in old { changes += max(0, count - (new[signature] ?? 0)) }
        for (signature, count) in new { changes += max(0, count - (old[signature] ?? 0)) }
        return changes > maximumInPlaceChanges
    }

    /// Type, identity text and frame. Values are excluded: a changed value is an in-place edit.
    private static func signatures(_ nodes: [FBSimulatorAXNode]) -> [String: Int] {
        var result: [String: Int] = [:]
        for node in nodes {
            let frame = node.frame.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "-"
            let key = [node.type ?? "-", node.identifier ?? "-", node.label ?? "-", frame].joined(separator: "|")
            result[key, default: 0] += 1
        }
        return result
    }
}
