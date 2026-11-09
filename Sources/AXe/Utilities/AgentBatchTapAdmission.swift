import Foundation
import FBSimulatorControl

/// Internal to the owned AX tap path. This is not a broker wire payload.
/// The original published plan is checked against the operation's latest native tree.
/// It replaces the controller pre-description and its two-tree fingerprint equality;
/// it does not replace native temporal target, point, PID or live-context validation.
struct AgentBatchTapAdmission: AgentOwnedTapAdmission {
    let plan: AgentBatchReferencePlan
    let index: Int

    var requiresNativeIdentity: Bool { plan.requiresNativeIdentity }

    func request(requestID: UUID) throws -> SelectedHIDRequest {
        try plan.tapRequest(index: index, requestID: requestID)
    }

    func validateContext(_ context: SelectedHIDContext, pid: Int32) throws {
        try plan.validateContext(context, pid: pid)
    }

    func validateOwnedSnapshot(roots: [FBSimulatorAXNode], nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata?,
                               context: SelectedHIDContext,
                               pid: Int32, nativeTarget: FBSimulatorAXNode) throws -> AgentModeAdmission {
        let snapshot = try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: nativeIdentityMetadata, context: context)
        let resolved = try plan.resolve(index: index, snapshot: snapshot, context: context, pid: pid)
        let target = try AgentModeTarget(resolved.node, nativeTarget: resolved.nativeTarget)
        try target.validate(nativeTarget)
        // The target value is bound to this owned snapshot for the later native hit check.
        // No comparison of a snapshot fingerprint with itself is used as an input guard.
        return AgentModeAdmission(context: context, expectedPID: pid, screenHash: snapshot.hash,
            visibleFingerprint: snapshot.visibleFingerprint,
            target: target, nativeTarget: resolved.nativeTarget)
    }
}
