import AXeCore
import CryptoKit
import Foundation
import FBSimulatorControl

/// References bind one published table. Later steps resolve native identities again;
/// no stored point can authorize input. Only state values and ordinary text may change.
struct AgentBatchReferencePlan: Sendable {
    struct ResolvedTarget: Sendable {
        let node: FBSimulatorAXNode
        let nativeTarget: SelectedNativeTarget
        var selectorKind: SelectedAXRequest.SelectorKind? {
            guard case let .semantic(kind, _, _) = nativeTarget else { return nil }
            return kind
        }
        var selectorValue: String? {
            guard case let .semantic(_, value, _) = nativeTarget else { return nil }
            return value
        }
    }

    private struct Target: Sendable {
        let action: RuntimeElementAction
        let identity: AgentModeTarget
        let nativeTarget: SelectedNativeTarget
    }

    private let context: SelectedHIDContext
    private let expectedPID: Int32
    private let layout: String
    private let targets: [Target]

    var requiresNativeIdentity: Bool { targets.contains { $0.nativeTarget.nativeIdentity != nil } }

    init(request: AgentBatchRequest, snapshotID: UUID, snapshot: AgentModeSnapshot,
         context: SelectedHIDContext, pid: Int32) throws {
        try request.validate()
        guard request.usesReferences, request.snapshotID == snapshotID else {
            throw AgentModeFailure("snapshotMissing", "The reference batch does not name the current published table. Refresh the snapshot.")
        }
        _ = try AgentModePIDPolicy.verifiedPID(pid, expected: request.expectedPID)
        self.context = context
        expectedPID = pid
        layout = try Self.layoutFingerprint(snapshot, display: Self.display(of: context))
        targets = try request.steps.map { step in
            guard let ref = step.ref else {
                throw AgentModeFailure("mixedBatchTargets", "Reference batches cannot contain native ID steps.")
            }
            let action: RuntimeElementAction = step.action == .tap ? .tap : .typeText
            let node = try snapshot.node(ref: ref, requiredAction: action)
            let nativeTarget = try snapshot.target(ref: ref)
            if action == .typeText {
                try SelectedKeyboardFocusPolicy.validate(node, expectedPID: pid, fieldTarget: nativeTarget)
            }
            return Target(action: action, identity: try AgentModeTarget(node, nativeTarget: nativeTarget),
                nativeTarget: nativeTarget)
        }
    }

    func resolve(index: Int, snapshot: AgentModeSnapshot, context: SelectedHIDContext,
                 pid: Int32) throws -> ResolvedTarget {
        guard targets.indices.contains(index) else {
            throw AgentModeFailure("invalidBatchStep", "The reference batch step is outside its validated plan.")
        }
        try validateContext(context, pid: pid)
        guard try Self.layoutFingerprint(snapshot, display: Self.display(of: context)) == layout else {
            throw AgentModeFailure("batchLayoutChanged", "The app layout or control identity changed during the reference batch. Later steps were stopped.")
        }
        // Optional object metadata is not part of the shared semantic layout hash.
        // Check every original opaque key before any step can authorize input.
        for bound in targets where bound.nativeTarget.nativeIdentity != nil {
            let fresh = try snapshot.match(target: bound.nativeTarget)
            try bound.identity.validate(fresh, allowingValueChange: true)
        }
        let target = targets[index]
        let node = try snapshot.match(target: target.nativeTarget)
        try target.identity.validate(node, allowingValueChange: true)
        // Ordinals come from the same identity resolver as single reference actions.
        // A consistent object class supplies tap identity, never an ancestry path.
        let ref = try snapshot.reference(target: target.nativeTarget)
        _ = try snapshot.node(ref: ref, requiredAction: target.action)
        if target.action == .typeText {
            try SelectedKeyboardFocusPolicy.validate(node, expectedPID: pid, fieldTarget: target.nativeTarget)
        }
        return ResolvedTarget(node: node, nativeTarget: target.nativeTarget)
    }

    func validateContext(_ context: SelectedHIDContext, pid: Int32) throws {
        _ = try AgentModePIDPolicy.verifiedPID(pid, expected: expectedPID)
        guard self.context == context else {
            throw AgentModeFailure("batchContextChanged", "The batch boot, display, orientation or hinge changed. Later steps were stopped.")
        }
    }

    /// This selector opens a native operation. Its owned tree must still pass resolve before input.
    func tapRequest(index: Int, requestID: UUID) throws -> SelectedHIDRequest {
        guard targets.indices.contains(index), targets[index].action == .tap,
              let uuid = UUID(uuidString: context.screenUUID) else {
            throw AgentModeFailure("invalidBatchStep", "The reference batch step is not a validated tap.")
        }
        let target = targets[index]
        var ax = SelectedAXRequest(kind: .tap, expectedPID: expectedPID, endpoint: nil,
            selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0)
        switch target.nativeTarget {
        case let .semantic(kind, value, type):
            ax = SelectedAXRequest(kind: .tap, expectedPID: expectedPID, endpoint: nil,
                selectorKind: kind, selectorValue: value, preDelay: 0, postDelay: 0, elementType: type)
        case .nativeObject:
            ax.nativeTarget = target.nativeTarget
        }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: requestID,
            screenID: context.screenID, screenUUID: uuid, operation: .complete,
            token: nil, primitives: [], ax: ax)
        try request.validate()
        return request
    }

    private static func display(of context: SelectedHIDContext) -> CGRect {
        CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight)
    }

    /// Nodes that cannot affect a tap or typing (hidden, wholly off the display, or an empty inert
    /// group) contribute only their descendants, as input admission already treats them, so a
    /// transient decorative layer does not stop a batch.
    private static func layoutFingerprint(_ snapshot: AgentModeSnapshot, display: CGRect) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var offset = 0
        func collect(controlAncestor: Bool = false, parentHidden: Bool = false) throws -> [String] {
            guard snapshot.nodes.indices.contains(offset), snapshot.semanticElements.indices.contains(offset) else {
                throw AgentModeFailure("invalidBatchLayout", "The native layout cannot be bound to its reference table.")
            }
            let index = offset
            let node = snapshot.nodes[index]
            offset += 1
            let hidden = parentHidden || node.hidden == true
            let actions = snapshot.semanticElements[index].actions
            let semanticControl = actions.contains(.tap) || actions.contains(.typeText)
            let children = try node.children.flatMap { _ in
                try collect(controlAncestor: controlAncestor || semanticControl, parentHidden: hidden)
            }.sorted()
            guard AgentModeSnapshot.affectsAdmission(node, hidden: hidden, display: display) else { return children }
            let ordinaryText = !controlAncestor && node.type == "StaticText" && node.children.isEmpty &&
                snapshot.semanticElements[index].actions.allSatisfy {
                    $0 != .tap && $0 != .typeText && $0 != .swipeWithin
                }
            let shape = LayoutNode(node, ordinaryText: ordinaryText, children: children)
            return [digest(try encoder.encode(shape))]
        }
        var roots: [String] = []
        while offset < snapshot.nodes.count { roots += try collect() }
        return digest(try encoder.encode(roots.sorted()))
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Values may change after an action. Labels and glyph bounds may change only on leaf StaticText
    /// nodes outside controls and without semantic activation actions. Generic touch/hold capability does
    /// not make ordinary text an interactive control. Control and ancestor identities,
    /// control/ancestor geometry, ancestry, visibility, enabled state and focus stay bound to the original layout.
    private struct LayoutNode: Encodable {
        let type: String?
        let role: String?
        let subrole: String?
        let roleDescription: String?
        let identifier: String?
        let label: String?
        let customActionNames: [String]
        let frame: AgentFrame?
        let pid: Int32?
        let focused: Bool?
        let enabled: Bool?
        let hidden: Bool?
        let children: [String]

        init(_ node: FBSimulatorAXNode, ordinaryText: Bool, children: [String]) {
            type = node.type; role = node.role; subrole = node.subrole; roleDescription = node.roleDescription
            identifier = node.identifier; label = ordinaryText ? nil : node.label; pid = node.pid
            focused = node.focused; enabled = node.enabled; hidden = node.hidden
            customActionNames = node.customActionNames
            // A number's glyph bounds change with its text, even while every control stays fixed.
            // This exception never covers a control, its descendant text, or a container frame.
            frame = ordinaryText ? nil : node.frame.map {
                AgentFrame(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
            }
            self.children = children
        }
    }
}
