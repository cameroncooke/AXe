import AXeCore
import Foundation
import FBSimulatorControl

/// A successful native point query can name a structural ancestor of a UIKit
/// scroll container. This admits one fresh scroll frame, not an exact pixel hit.
/// Only the swipe guard calls this policy; other input keeps its original proof.
enum AgentModeCoarseScrollAdmission {
    /// False keeps the existing exact/descendant path. An ancestor candidate must
    /// pass every check here; a failure never starts input or chooses another path.
    static func validateIfAncestor(hit: FBSimulatorAXNode, area: FBSimulatorAXNode,
                                   start: CGPoint, ends: [CGPoint], snapshot: AgentModeSnapshot,
                                   logicalSize: CGSize) throws -> Bool {
        let hitIndex = try AgentModePathIdentityPolicy.uniqueIndex(matching: hit,
            in: snapshot, usingNativeIdentity: true)
        let areaIndex = try AgentModePathIdentityPolicy.uniqueIndex(matching: area,
            in: snapshot, usingNativeIdentity: true)
        let hitPath = snapshot.elements[hitIndex].path
        let areaPath = snapshot.elements[areaIndex].path
        guard areaPath.hasPrefix(hitPath + ".") else { return false }

        let selected = snapshot.elements[areaIndex]
        guard area.type == "ScrollArea", selected.role == .scrollView,
              selected.actions.contains(.swipeWithin),
              hit.type == "Group", snapshot.elements[hitIndex].role == .other,
              !AgentModeSnapshot.hasPotentialTapAction(hit),
              let pid = area.pid, pid > 0, hit.pid == pid,
              logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0,
              !ends.isEmpty else { throw rejected() }
        let display = CGRect(origin: .zero, size: logicalSize)
        guard let areaFrame = area.frame, validFrame(areaFrame),
              ([start] + ends).allSatisfy({ finitePoint($0) && display.contains($0) && areaFrame.contains($0) })
        else { throw rejected() }

        // Check the real current ownership chain, not frame containment or labels.
        // Every occurrence is counted before hidden/disabled copies can disappear.
        for index in snapshot.nodes.indices {
            let path = snapshot.elements[index].path
            guard path == areaPath || areaPath.hasPrefix(path + ".") else { continue }
            let node = snapshot.nodes[index], element = snapshot.elements[index]
            _ = try AgentModePathIdentityPolicy.uniqueIndex(matching: node,
                in: snapshot, usingNativeIdentity: true)
            guard node.pid == pid, node.enabled == true, node.hidden == false,
                  element.state.enabled, element.state.visible,
                  let frame = node.frame, validFrame(frame) else { throw rejected() }
        }

        if let keyboard = AgentModeKeyboardDetector.occlusion(in: snapshot,
                expectedPID: pid, logicalSize: logicalSize) {
            let keyboardOwned = areaPath == keyboard.path || areaPath.hasPrefix(keyboard.path + ".")
            if !keyboardOwned, ([start] + ends).contains(where: { keyboard.frame.contains($0) }) {
                throw rejected()
            }
        }

        for index in snapshot.nodes.indices where index != areaIndex {
            let node = snapshot.nodes[index], element = snapshot.elements[index]
            let explicitContainer = AgentModeSnapshot.hasPotentialScrollContainerAction(node)
            let inferredContainer = element.role == .other && element.actions.contains(.swipeWithin)
            let externalControl = !element.path.hasPrefix(areaPath + ".")
                && AgentModeSnapshot.hasPotentialTapAction(node)
            // The native hit owns this branch. Unrelated background scroll
            // branches do not compete; explicit scroll ancestors still do.
            let withinHit = element.path == hitPath || element.path.hasPrefix(hitPath + ".")
            let explicitAncestor = explicitContainer && hitPath.hasPrefix(element.path + ".")
            guard ((explicitContainer || inferredContainer) && withinHit)
                || explicitAncestor || externalControl else { continue }
            guard try contenderContainsStart(node.frame, start: start) else { continue }
            // Only inferred structural wrappers are excluded. An actual outer
            // scroll container remains a competitor, as does any nested area.
            let structuralAncestor = !explicitContainer && inferredContainer
                && areaPath.hasPrefix(element.path + ".")
            if structuralAncestor && !externalControl { continue }
            throw rejected()
        }
        return true
    }

    /// Empty known geometry is not an overlap; unknown or malformed geometry refuses.
    static func contenderContainsStart(_ frame: CGRect?, start: CGPoint) throws -> Bool {
        guard let frame, finitePoint(start),
              [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite),
              frame.size.width >= 0, frame.size.height >= 0 else { throw rejected() }
        if frame.size.width == 0 || frame.size.height == 0 { return false }
        return frame.contains(start)
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
            && frame.size.width > 0 && frame.size.height > 0
    }

    private static func finitePoint(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func rejected() -> AgentModeFailure {
        AgentModeFailure("coarseScrollTargetRejected",
            "AXe could not confirm one scroll area at the swipe start, so nothing was sent. Swipe the innermost scroll-area ref from the capture in this reply, or run describe-ui --agent if it has none.")
    }
}
