import Foundation
import FBSimulatorControl

/// One explicit focus transition. Public reference-batch layouts remain immutable.
/// Path ordinals do not identify a field when the keyboard changes sibling order.
struct AgentFocusAndTypePlan: Sendable {
    let fieldTarget: SelectedNativeTarget
    private let expectedPID: Int32
    private let context: SelectedHIDContext
    private var original: FBSimulatorAXNode
    private var observedIdentity: FBSimulatorAXNativeIdentity?

    init(snapshot: AgentModeSnapshot, ref: String, context: SelectedHIDContext, pid: Int32) throws {
        let node = try snapshot.node(ref: ref, requiredAction: .tap)
        let target = try snapshot.target(ref: ref)
        try SelectedKeyboardFocusPolicy.validateIdentity(node, expectedPID: pid, fieldTarget: target)
        self.fieldTarget = target
        self.expectedPID = pid
        self.context = context
        self.original = node
        self.observedIdentity = node.nativeIdentity
        _ = try resolve(snapshot: snapshot, context: context, pid: pid, requiringFocus: false)
    }

    func validateBeforeTap(snapshot: AgentModeSnapshot, context: SelectedHIDContext, pid: Int32) throws {
        _ = try resolve(snapshot: snapshot, context: context, pid: pid, requiringFocus: false)
    }

    /// This read establishes the new baseline. The later ordinary type path still
    /// compares its exact value/frame before the first key and checks every DOWN.
    func focusedBaseline(snapshot: AgentModeSnapshot, context: SelectedHIDContext,
                         pid: Int32) throws -> AgentFocusAndTypePlan {
        let resolved = try resolve(snapshot: snapshot, context: context, pid: pid, requiringFocus: true,
            allowingFocusValueChange: true)
        var baseline = self
        baseline.original = resolved.node
        baseline.observedIdentity = observedIdentity ?? resolved.node.nativeIdentity
        return baseline
    }

    func focusedReference(snapshot: AgentModeSnapshot, context: SelectedHIDContext, pid: Int32) throws -> String {
        try resolve(snapshot: snapshot, context: context, pid: pid, requiringFocus: true).ref
    }

    private func resolve(snapshot: AgentModeSnapshot, context: SelectedHIDContext, pid: Int32,
                         requiringFocus: Bool, allowingFocusValueChange: Bool = false) throws -> (node: FBSimulatorAXNode, ref: String) {
        _ = try AgentModePIDPolicy.verifiedPID(pid, expected: expectedPID)
        guard self.context == context, snapshot.hasNativeOwner(expectedPID) else {
            throw AgentModeFailure("focusContextChanged", "The focus action's app or display context changed. Typing was stopped.")
        }
        let ref = try snapshot.reference(target: fieldTarget)
        let node = try snapshot.node(ref: ref, requiredAction: requiringFocus ? .typeText : .tap)
        guard try snapshot.target(ref: ref) == fieldTarget else {
            throw AgentModeFailure("focusTargetChanged", "The field's chosen identity changed. Typing was stopped.")
        }
        try SelectedKeyboardFocusPolicy.validateIdentity(node, expectedPID: expectedPID, fieldTarget: fieldTarget)
        guard node.type == original.type, node.identifier == original.identifier, node.label == original.label,
              node.role == original.role, node.subrole == original.subrole,
              node.roleDescription == original.roleDescription, node.customActionNames == original.customActionNames,
              allowingFocusValueChange || node.value == original.value,
              node.pid == original.pid, node.enabled == true, node.hidden == false, node.focused != nil else {
            throw AgentModeFailure("focusTargetChanged", "The field's identity, owner or available state changed. Typing was stopped.")
        }
        if let observedIdentity {
            try observedIdentity.validate()
            guard observedIdentity.pid == expectedPID, node.nativeIdentity == observedIdentity else {
                throw AgentModeFailure("focusTargetChanged", "The observed native field changed during focus. Typing was stopped.")
            }
        }
        // Retain object evidence when available, without granting anonymous or alias authority.
        if let identity = node.nativeIdentity {
            try identity.validate()
            guard identity.pid == expectedPID,
                  snapshot.nodes.filter({ $0.nativeIdentity == identity }).count == 1 else {
                throw AgentModeFailure("focusTargetChanged", "The observed native field has conflicting occurrences. Typing was stopped.")
            }
        }
        guard let frame = node.frame,
              [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite),
              frame.size.width > 0, frame.size.height > 0,
              CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight).contains(frame) else {
            throw AgentModeFailure("focusTargetChanged", "The focused field has no positive frame inside the current display.")
        }
        if requiringFocus {
            try SelectedKeyboardFocusPolicy.validate(node, expectedPID: expectedPID, fieldTarget: fieldTarget)
        }
        return (node, ref)
    }
}

/// The existing batch output represents two input phases, including partial failure.
struct AgentFocusAndTypeProgress {
    private(set) var steps: [AgentBatchStepReceipt] = []
    private(set) var completed = 0
    var pendingIndex: Int { steps.count + 1 }

    mutating func append(_ response: SelectedHIDResponse, action: AgentBatchStep.Action) throws {
        guard steps.count < 2, let result = response.agent else {
            throw AgentModeFailure("missingFocusTypeResult", "A focus/type phase returned no usable result. Inspect input before more actions.")
        }
        let receipt = result.data.action
        let didComplete = receipt?.outcome == "enqueuedAndDrained" && receipt?.cleanup != "uncertain"
            && receipt?.quarantine == nil
        if didComplete { completed += 1 }
        steps.append(AgentBatchStepReceipt(index: pendingIndex, action: action,
            status: didComplete ? "completed" : "failed", requestID: response.requestID,
            receipt: receipt, error: result.error, cache: result.data.cache, context: result.data.context))
        if let error = result.error { throw error }
        guard didComplete else {
            throw AgentModeFailure("focusTypeInputFailed", "The focus/type phase did not finish. Later input was stopped; no input was replayed.")
        }
    }

    mutating func reject(_ error: AgentModeFailure, context: SelectedHIDContext?) {
        guard steps.count < 2, steps.last?.status != "failed" else { return }
        steps.append(AgentBatchStepReceipt(index: pendingIndex, action: steps.isEmpty ? .tap : .type,
            status: "rejectedBeforeInput", requestID: UUID(), receipt: nil, error: error,
            cache: AgentModeCacheState(status: "invalidated", reason: error.code, requiresRefresh: true), context: context))
    }

    func receipt(stopped: Bool) -> AgentBatchReceipt {
        AgentBatchReceipt(totalSteps: 2, completedSteps: completed, steps: steps,
            stoppedAt: stopped ? min(2, max(1, steps.count)) : nil)
    }
}
