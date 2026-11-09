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
    }

    private struct Target: Sendable {
        let action: RuntimeElementAction
        let identity: AgentModeTarget
        let nativeTarget: SelectedNativeTarget
        /// A focus step's field is admitted for its focus tap, not as an already focused field.
        var focus = false
        /// The native object observed at binding, even for an ID or label target. A rebase requires
        /// the same object whenever both reads report one, so a replacement field cannot pass.
        var observedIdentity: FBSimulatorAXNativeIdentity? = nil
        /// Steps at or before a completed focus step are done; their controls may have changed.
        var completed = false
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
            throw AgentModeFailure("snapshotMissing", "The batch's snapshotID is not the latest capture, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        _ = try AgentModePIDPolicy.verifiedPID(pid, expected: request.expectedPID)
        self.context = context
        expectedPID = pid
        layout = try Self.layoutFingerprint(snapshot, display: Self.display(of: context))
        targets = try request.steps.map { step in
            guard let ref = step.ref else {
                throw AgentModeFailure("mixedBatchTargets", "Reference batches cannot contain native ID steps.")
            }
            let focus = step.action == .type && step.focuses
            let action: RuntimeElementAction = step.action == .tap || focus ? .tap : .typeText
            let node = try snapshot.node(ref: ref, requiredAction: action)
            let nativeTarget = try snapshot.target(ref: ref)
            try Self.validateField(node, focus: focus, action: action, pid: pid, nativeTarget: nativeTarget)
            return Target(action: action, identity: try AgentModeTarget(node, nativeTarget: nativeTarget),
                nativeTarget: nativeTarget, focus: focus, observedIdentity: node.nativeIdentity)
        }
    }

    private init(context: SelectedHIDContext, expectedPID: Int32, layout: String, targets: [Target]) {
        self.context = context
        self.expectedPID = expectedPID
        self.layout = layout
        self.targets = targets
    }

    private static func validateField(_ node: FBSimulatorAXNode, focus: Bool, action: RuntimeElementAction,
                                      pid: Int32, nativeTarget: SelectedNativeTarget) throws {
        if focus {
            // The same field authority `type --focus` uses before its focus tap.
            try SelectedKeyboardFocusPolicy.validateIdentity(node, expectedPID: pid, fieldTarget: nativeTarget)
        } else if action == .typeText {
            try SelectedKeyboardFocusPolicy.validate(node, expectedPID: pid, fieldTarget: nativeTarget)
        }
    }

    /// A completed focus step is a declared layout transition: its keyboard can move and reorder
    /// the screen. Every later target must be the same control on the new screen, found by its bound
    /// identity, with only its position changed, still available and inside the display. The new
    /// screen then becomes the layout that later steps must keep.
    func rebased(afterFocusStep index: Int, snapshot: AgentModeSnapshot, context: SelectedHIDContext,
                 pid: Int32) throws -> AgentBatchReferencePlan {
        guard targets.indices.contains(index), targets[index].focus else {
            throw AgentModeFailure("invalidBatchStep", "Only a completed focus step can change the batch layout.")
        }
        try validateContext(context, pid: pid)
        let display = Self.display(of: context)
        var rebound = targets
        for done in targets.indices where done <= index { rebound[done].completed = true }
        for later in targets.indices where later > index {
            let target = targets[later]
            let node = try Self.movedTarget(target, in: snapshot, display: display, pid: pid)
            rebound[later] = Target(action: target.action,
                identity: try AgentModeTarget(node, nativeTarget: target.nativeTarget),
                nativeTarget: target.nativeTarget, focus: target.focus,
                observedIdentity: target.observedIdentity ?? node.nativeIdentity)
        }
        return AgentBatchReferencePlan(context: self.context, expectedPID: expectedPID,
            layout: try Self.layoutFingerprint(snapshot, display: display), targets: rebound)
    }

    /// The same control on a new screen: found by its bound identity, with only its position
    /// changed (focus may move to or from it), the same native object whenever both reads report
    /// one, still enabled, shown, inside the display and offering its action.
    private static func movedTarget(_ target: Target, in snapshot: AgentModeSnapshot, display: CGRect,
                                    pid: Int32) throws -> FBSimulatorAXNode {
        let node = try snapshot.match(target: target.nativeTarget)
        try target.identity.validateMoved(node)
        if let observed = target.observedIdentity, let fresh = node.nativeIdentity, observed != fresh {
            throw AgentModeFailure("targetChanged", "A later batch target was replaced by another control, so the remaining steps were not sent. \(AgentModeFailure.batchRest)")
        }
        guard node.enabled != false, node.hidden != true, let frame = node.frame,
              frame.isUsableAgentFrame, display.contains(frame) else {
            throw AgentModeFailure("batchLayoutChanged", "A batch target is unavailable or outside the display. Later steps were stopped.")
        }
        let ref = try snapshot.reference(target: target.nativeTarget)
        _ = try snapshot.node(ref: ref, requiredAction: target.action)
        try validateField(node, focus: target.focus, action: target.action, pid: pid, nativeTarget: target.nativeTarget)
        return node
    }

    func isFocusStep(_ index: Int) -> Bool { targets.indices.contains(index) && targets[index].focus }

    /// The layout a batch step must keep, for comparing reads of one screen.
    static func layoutKey(_ snapshot: AgentModeSnapshot, context: SelectedHIDContext) throws -> String {
        try layoutFingerprint(snapshot, display: display(of: context))
    }

    func resolve(index: Int, snapshot: AgentModeSnapshot, context: SelectedHIDContext,
                 pid: Int32) throws -> ResolvedTarget {
        guard targets.indices.contains(index) else {
            throw AgentModeFailure("invalidBatchStep", "The reference batch step is outside its validated plan.")
        }
        try validateContext(context, pid: pid)
        if targets[index].focus {
            // A focus step is itself a declared layout change, as `type --focus` is: its authority is
            // the bound field wherever earlier input moved it. Its focus tap still passes the native
            // hit and target checks before input, and later steps are rebased after it.
            let node = try Self.movedTarget(targets[index], in: snapshot, display: Self.display(of: context), pid: pid)
            return ResolvedTarget(node: node, nativeTarget: targets[index].nativeTarget)
        }
        guard try Self.layoutFingerprint(snapshot, display: Self.display(of: context)) == layout else {
            throw AgentModeFailure("batchLayoutChanged", "The screen changed during the batch, so the remaining steps were not sent; completed steps are in the receipt and were not undone. Plan the rest from the capture in this reply. Do not resend the batch.")
        }
        // Optional object metadata is not part of the shared semantic layout hash.
        // Check every original opaque key before any step can authorize input.
        for bound in targets where bound.nativeTarget.nativeIdentity != nil && !bound.completed {
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
        try Self.validateField(node, focus: target.focus, action: target.action, pid: pid,
            nativeTarget: target.nativeTarget)
        return ResolvedTarget(node: node, nativeTarget: target.nativeTarget)
    }

    func validateContext(_ context: SelectedHIDContext, pid: Int32) throws {
        _ = try AgentModePIDPolicy.verifiedPID(pid, expected: expectedPID)
        guard self.context == context else {
            throw AgentModeFailure("batchContextChanged", "The simulator restarted, rotated or changed its display during the batch, so the remaining steps were not sent. \(AgentModeFailure.batchRest)")
        }
    }

    /// This selector opens a native operation. Its owned tree must still pass resolve before input.
    func tapRequest(index: Int, requestID: UUID) throws -> SelectedHIDRequest {
        guard targets.indices.contains(index), targets[index].action == .tap, !targets[index].focus,
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
