import Foundation
import FBSimulatorControl

extension AgentModeSnapshot {
    struct NativeSelector: Sendable {
        let kind: SelectedAXRequest.SelectorKind
        let value: String
    }

    /// Native selector matching trims only its ends. It does not use the RS/1 text projection.
    struct NativeIdentityIndex: Sendable {
        struct Entry: Sendable {
            var count: Int
            let index: Int
            var buttonLeaf = false
        }
        private struct Key: Hashable, Sendable {
            let kind: String
            let value: String
            let type: String?
        }
        private var entries: [Key: Entry] = [:]
        private var buttonChainAncestors: Set<Int> = []

        init(nodes: [FBSimulatorAXNode], roots: [FBSimulatorAXNode]) {
            for (index, node) in nodes.enumerated() {
                for (kind, raw) in [(SelectedAXRequest.SelectorKind.id, node.identifier), (.label, node.label), (.value, AgentModeSnapshot.text(node.value))] {
                    guard let raw else { continue }
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    let types: [String?] = node.type.map { [nil, $0] } ?? [nil]
                    for type in types {
                        let key = Key(kind: kind.rawValue, value: value, type: type)
                        if var entry = entries[key] { entry.count += 1; entries[key] = entry }
                        else { entries[key] = Entry(count: 1, index: index) }
                    }
                }
            }
            let duplicateEntries = entries.filter { $0.value.count > 1 }
            for (key, entry) in duplicateEntries {
                guard key.type == nil || key.type == "Button" else { continue }
                let selector: FBSimulatorAXSelector
                if key.kind == SelectedAXRequest.SelectorKind.id.rawValue {
                    selector = key.type == nil ? .identifier(key.value) : .identifierWithType(key.value, elementType: "Button")
                } else if key.kind == SelectedAXRequest.SelectorKind.label.rawValue {
                    selector = key.type == nil ? .label(key.value) : .labelWithType(key.value, elementType: "Button")
                } else { continue }
                guard let leaf = FBSimulatorAXButtonLeafSelection.resolve(in: roots, selector: selector),
                      leaf.matchingIndices.count == entry.count else { continue }
                entries[key] = Entry(count: 1, index: leaf.index, buttonLeaf: true)
                buttonChainAncestors.formUnion(leaf.matchingIndices.dropLast())
            }
        }

        func isButtonChainAncestor(at index: Int) -> Bool { buttonChainAncestors.contains(index) }

        func entry(kind: SelectedAXRequest.SelectorKind, value: String, type: String?) -> Entry? {
            entries[Key(kind: kind.rawValue, value: value.trimmingCharacters(in: .whitespacesAndNewlines), type: type)]
        }

        func selector(for node: FBSimulatorAXNode, nodes: [FBSimulatorAXNode]) -> NativeSelector? {
            guard let frame = node.frame else { return nil }
            for (kind, raw) in [(SelectedAXRequest.SelectorKind.id, node.identifier), (.label, node.label)] {
                guard let raw else { continue }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.utf8.count <= 4096,
                      let entry = entry(kind: kind, value: value, type: node.type), entry.count == 1,
                      nodes[entry.index].frame == frame,
                      !entry.buttonLeaf || node.children.isEmpty else { continue }
                return NativeSelector(kind: kind, value: value)
            }
            return nil
        }

        func hasUniqueTextFieldID(for node: FBSimulatorAXNode) -> Bool {
            guard node.type == "TextField", let identifier = node.identifier,
                  !identifier.isEmpty, identifier.utf8.count <= 4096,
                  identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                  let entry = entry(kind: .id, value: identifier, type: "TextField") else { return false }
            return entry.count == 1
        }
    }
}
