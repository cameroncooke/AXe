import AXeCore
import Foundation
import FBSimulatorControl

/// Supplies the shared host action rules. Native code owns identity, full-tree,
/// point stability and input guards; an unmapped point is never a target alias.
struct SelectedOpaqueFrameTapAdmission: FBSimulatorAXOpaqueFrameTapAdmissionGuard {
    private let request: SelectedAXRequest
    private let nativeTarget: SelectedNativeTarget

    static func make(for request: SelectedAXRequest) throws -> Self? {
        guard request.kind == .tap, request.tapStyle == nil || request.tapStyle == .physical,
              let target = request.nativeTarget, target.nativeIdentity != nil else { return nil }
        try request.validate()
        return Self(request: request, nativeTarget: target)
    }

    func validate(roots: [FBSimulatorAXNode], nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata?,
                  target: FBSimulatorAXNode, point: CGPoint,
                  observation: FBSimulatorHIDSessionObservation) throws {
        guard try request.resolvedTapStyle(target: target) == .physical,
              nativeIdentityMetadata?.complete == true,
              point.x.isFinite, point.y.isFinite else { throw rejected() }
        let snapshot = try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: nativeIdentityMetadata,
            context: SelectedHIDContext(observation))
        guard snapshot.nativeIdentityMetadata?.complete == true else { throw rejected() }
        // match counts all occurrences before PID, type, state and visibility filters.
        let selected = try snapshot.match(target: nativeTarget)
        try AgentModeTarget(target, nativeTarget: nativeTarget).validate(selected)
        guard let selectedIndex = snapshot.nodes.firstIndex(where: {
            $0.nativeIdentity == nativeTarget.nativeIdentity
        }) else { throw rejected() }
        let selectedElement = snapshot.elements[selectedIndex]
        guard selectedElement.state.enabled, selectedElement.state.visible,
              selectedElement.actions.contains(.tap), let frame = selected.frame,
              frame.contains(point) else { throw rejected() }
        // Use the complete shared projection, never a public page or deduplicated ID table.
        // Raw frames retain exact point geometry; projection supplies the action rules.
        for node in snapshot.nodes {
            guard node.nativeIdentity != nativeTarget.nativeIdentity,
                  AgentModeSnapshot.hasPotentialTapAction(node) else { continue }
            guard let frame = node.frame,
                  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                  frame.width >= 0, frame.height >= 0 else { throw rejected() }
            if frame.contains(point) { throw rejected() }
        }
    }

    private func rejected() -> AgentModeFailure {
        AgentModeFailure("opaqueFrameTapRejected", "The fresh tap frame has no unique actionable control. Refresh the snapshot before more input.")
    }
}
