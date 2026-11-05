import Foundation
import FBSimulatorControl

/// Bounded diagnostics for an exact native fingerprint refusal. Node content is never logged.
enum AgentModeSnapshotDifference {
    static func summary(previous: [FBSimulatorAXNode], current: [FBSimulatorAXNode]) -> String {
        let previousPaths = paths(in: previous)
        let currentPaths = paths(in: current)
        var counts: [String: Int] = [:]
        var samples: [String] = []
        var changedNodes = 0
        for index in 0..<min(previous.count, current.count) {
            let before = previous[index]
            let after = current[index]
            var fields: [String] = []
            func changed<T: Equatable>(_ field: String, _ left: T, _ right: T) {
                if left != right { fields.append(field); counts[field, default: 0] += 1 }
            }
            changed("path", previousPaths[index], currentPaths[index])
            changed("type", before.type, after.type)
            changed("role", before.role, after.role)
            changed("subrole", before.subrole, after.subrole)
            changed("roleDescription", before.roleDescription, after.roleDescription)
            changed("identifier", before.identifier, after.identifier)
            changed("label", before.label, after.label)
            changed("value", before.value, after.value)
            changed("customActionNames", before.customActionNames, after.customActionNames)
            changed("frame", before.frame, after.frame)
            changed("pid", before.pid, after.pid)
            changed("focused", before.focused, after.focused)
            changed("enabled", before.enabled, after.enabled)
            changed("hidden", before.hidden, after.hidden)
            changed("children", before.children.count, after.children.count)
            guard !fields.isEmpty else { continue }
            changedNodes += 1
            if samples.count < 8 {
                let path = previousPaths[index]
                let boundedPath = path.count <= 80 ? path : "…" + String(path.suffix(79))
                samples.append("node[\(index)]@\(boundedPath):\(fields.joined(separator: ","))")
            }
        }
        let fields = counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ",")
        return "nodes=\(previous.count)->\(current.count) pairedChanges=\(changedNodes) fields=[\(fields)] samples=[\(samples.joined(separator: ";"))]"
    }

    /// The snapshots are bounded preorder tables. Paths distinguish hierarchy changes from field changes.
    private static func paths(in nodes: [FBSimulatorAXNode]) -> [String] {
        var result: [String] = []
        var index = 0
        func walk(_ path: String) {
            guard index < nodes.count else { return }
            let childCount = nodes[index].children.count
            index += 1
            result.append(path)
            for child in 0..<childCount { walk("\(path).\(child)") }
        }
        var root = 0
        while index < nodes.count { walk(String(root)); root += 1 }
        return result
    }
}
