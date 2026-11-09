import FBSimulatorControl
@testable import AXe

/// Conveniences only tests use; production code passes the native identity metadata and
/// reads the chosen native target itself.
extension AgentOwnedTapAdmission {
    func validateOwnedSnapshot(roots: [FBSimulatorAXNode], context: SelectedHIDContext, pid: Int32,
                               nativeTarget: FBSimulatorAXNode) throws -> AgentModeAdmission {
        try validateOwnedSnapshot(roots: roots, nativeIdentityMetadata: nil, context: context, pid: pid,
            nativeTarget: nativeTarget)
    }
}

extension AgentBatchReferencePlan.ResolvedTarget {
    var selectorKind: SelectedAXRequest.SelectorKind? {
        guard case let .semantic(kind, _, _) = nativeTarget else { return nil }
        return kind
    }
    var selectorValue: String? {
        guard case let .semantic(_, value, _) = nativeTarget else { return nil }
        return value
    }
}
