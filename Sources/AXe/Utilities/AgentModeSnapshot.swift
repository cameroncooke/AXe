import AXeCore
import CryptoKit
import Foundation
import FBSimulatorControl

/// One bounded native read, with the complete reference table kept inside the broker.
struct AgentModeSnapshot: Sendable {
    static let maximumElements = 4096
    static let maximumDepth = 64
    let nodes: [FBSimulatorAXNode]
    let elements: [RuntimeSnapshotElement]
    let hash: String
    let nativeFingerprint: String
    private let identityIndex: NativeIdentityIndex
    private let referenceIndices: [String: Int]
    private let selectors: [NativeSelector?]

    init(roots: [FBSimulatorAXNode]) throws {
        var nodes: [FBSimulatorAXNode] = []
        var inheritedHidden: [Bool] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func collect(_ node: FBSimulatorAXNode, depth: Int, parentHidden: Bool) throws -> String {
            guard depth <= Self.maximumDepth, nodes.count < Self.maximumElements else {
                throw AgentModeFailure("hierarchyTooLarge", "The accessibility hierarchy exceeds the agent query bound.")
            }
            let hidden = parentHidden || node.hidden == true
            nodes.append(node)
            inheritedHidden.append(hidden)
            let children = try node.children.map { try collect($0, depth: depth + 1, parentHidden: hidden) }
            return Self.digest(try encoder.encode(NativeFingerprintNode(node, children: children.sorted())))
        }
        let rootFingerprints = try roots.map { try collect($0, depth: 0, parentHidden: false) }
        nativeFingerprint = Self.digest(try encoder.encode(rootFingerprints.sorted()))
        self.nodes = nodes
        let identities = NativeIdentityIndex(nodes: nodes)
        identityIndex = identities
        let selectors = nodes.map { identities.selector(for: $0, nodes: nodes) }
        self.selectors = selectors
        let baseElements = RuntimeSnapshotBuilder.elements(from: roots.map(Self.runtimeNode))
        let projected = baseElements.enumerated().map { index, element in
            let node = nodes[index]
            let hidden = inheritedHidden[index]
            let canType = node.type == "TextField" && node.focused == true && node.enabled == true
                && node.hidden == false && identities.hasExactUniqueID(for: node)
            let state = RuntimeElementState(enabled: element.state.enabled, visible: element.state.visible && !hidden)
            let actions = hidden ? [] : element.actions.filter { canType || $0 != .typeText }
            return RuntimeSnapshotElement(ref: element.ref, role: element.role,
                label: element.label, value: element.value, identifier: element.identifier, frame: element.frame,
                state: state, actions: actions, path: element.path,
                activationPointOverride: element.activationPointOverride, swipeFrame: element.swipeFrame)
        }
        elements = projected
        referenceIndices = Dictionary(uniqueKeysWithValues: projected.enumerated().map { ($0.element.ref, $0.offset) })
        hash = RuntimeSnapshotBuilder.screenHash(of: projected)
    }

    func node(ref: String, requiredAction: RuntimeElementAction) throws -> FBSimulatorAXNode {
        guard let index = referenceIndices[ref],
              elements[index].state.visible, elements[index].state.enabled,
              elements[index].actions.contains(requiredAction) else {
            throw AgentModeFailure("unsupportedReference", "The reference is missing, hidden, disabled, or does not support this action.")
        }
        guard selectors[index] != nil else {
            throw AgentModeFailure("unsupportedIdentity", "The target has no unique native ID or label. Cached coordinates cannot authorize this action.")
        }
        return nodes[index]
    }

    func resolve(_ original: FBSimulatorAXNode) throws -> FBSimulatorAXNode {
        let selector = try uniqueSelector(for: original)
        return try match(kind: selector.kind, value: selector.value, type: original.type)
    }

    func match(kind: SelectedAXRequest.SelectorKind, value: String, type: String?) throws -> FBSimulatorAXNode {
        let entry = identityIndex.entry(kind: kind, value: value, type: type)
        guard let entry, entry.count == 1 else {
            throw AgentModeFailure(entry == nil ? "targetMissing" : "targetAmbiguous",
                                   "The exact native selector did not identify one target. Refresh the snapshot or use a unique ID.")
        }
        return nodes[entry.index]
    }

    func uniqueSelector(for node: FBSimulatorAXNode) throws -> (kind: SelectedAXRequest.SelectorKind, value: String) {
        guard let selector = identityIndex.selector(for: node, nodes: nodes) else {
            throw AgentModeFailure("unsupportedIdentity", "The target has no unique native ID or label. Cached coordinates cannot authorize this action.")
        }
        return (selector.kind, selector.value)
    }

    func capture(id: UUID, sequence: Int, udid: String, request: AgentModeRequest,
                 applicationPID: Int32, context: SelectedHIDContext,
                 unchanged: Bool, expiresIn: Double) -> AgentModeCapture {
        let targets = RuntimeSnapshotCompactor.targets(in: elements, limit: Self.maximumElements)
        let scroll = RuntimeSnapshotCompactor.scrollAreas(in: elements, limit: Self.maximumElements)
        let text = RuntimeSnapshotCompactor.text(in: elements, limit: Self.maximumElements)
        func page(_ rows: [RuntimeSnapshotRow], requiresSelector: Bool) -> [String] {
            guard !unchanged else { return [] }
            return rows.dropFirst(request.rowOffset).prefix(request.rowLimit).map { row in
                guard requiresSelector, let index = referenceIndices[row.element.ref], selectors[index] == nil else {
                    return row.text
                }
                return RuntimeSnapshotCompactor.row(row.element, action: "unavailable").text
            }
        }
        let remaining = max(0, targets.count - request.rowOffset) > request.rowLimit
            || max(0, scroll.count - request.rowOffset) > request.rowLimit
            || max(0, text.count - request.rowOffset) > request.rowLimit
        return AgentModeCapture(type: unchanged ? "runtime-snapshot-unchanged" : "runtime-snapshot", rs: "1",
            snapshotID: id, screenHash: hash, seq: sequence, count: elements.count,
            targets: page(targets, requiresSelector: true), scroll: page(scroll, requiresSelector: true),
            text: page(text, requiresSelector: false), udid: udid,
            applicationPID: applicationPID, context: context,
            rowOffset: request.rowOffset, rowLimit: request.rowLimit, targetCount: targets.count,
            scrollCount: scroll.count, textCount: text.count, truncated: remaining, expiresInSeconds: expiresIn)
    }

    private static func runtimeNode(_ node: FBSimulatorAXNode) -> RuntimeSnapshotNode {
        RuntimeSnapshotNode(type: node.type, role: node.role, subrole: node.subrole,
            roleDescription: node.roleDescription, label: node.label, value: text(node.value),
            identifier: node.identifier, frame: node.frame.map {
                AgentFrame(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
            }, enabled: node.enabled != false && node.hidden != true,
            children: node.children.map(runtimeNode))
    }

    private static func text(_ value: FBSimulatorAXValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text): return text
        case .number(let number): return String(number)
        case .boolean(let boolean): return String(boolean)
        case .null, .array, .object: return nil
        }
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Each node encodes only its own exact fields and fixed-size child digests.
    /// Sorting child digests preserves sibling reorder while retaining ancestry.
    private struct NativeFingerprintNode: Encodable {
        let type: String?
        let role: String?
        let subrole: String?
        let roleDescription: String?
        let identifier: String?
        let label: String?
        let value: FBSimulatorAXValue?
        let frame: AgentFrame?
        let pid: Int32?
        let focused: Bool?
        let enabled: Bool?
        let hidden: Bool?
        let children: [String]

        init(_ node: FBSimulatorAXNode, children: [String]) {
            type = node.type; role = node.role; subrole = node.subrole; roleDescription = node.roleDescription
            identifier = node.identifier; label = node.label; value = node.value; pid = node.pid
            focused = node.focused; enabled = node.enabled; hidden = node.hidden
            frame = node.frame.map { AgentFrame(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height) }
            self.children = children
        }
    }

    private struct NativeSelector: Sendable {
        let kind: SelectedAXRequest.SelectorKind
        let value: String
    }

    /// Native selector matching trims only its ends. It does not use the RS/1 text projection.
    private struct NativeIdentityIndex: Sendable {
        struct Entry: Sendable {
            var count: Int
            let index: Int
        }
        private struct Key: Hashable, Sendable {
            let kind: String
            let value: String
            let type: String?
        }
        private var entries: [Key: Entry] = [:]

        init(nodes: [FBSimulatorAXNode]) {
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
        }

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
                      nodes[entry.index].frame == frame else { continue }
                return NativeSelector(kind: kind, value: value)
            }
            return nil
        }

        func hasExactUniqueID(for node: FBSimulatorAXNode) -> Bool {
            guard let identifier = node.identifier, !identifier.isEmpty, identifier.utf8.count <= 4096,
                  identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                  let entry = entry(kind: .id, value: identifier, type: nil) else { return false }
            return entry.count == 1
        }
    }
}
