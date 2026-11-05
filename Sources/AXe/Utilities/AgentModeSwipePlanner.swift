import AXeCore
import Foundation
import FBSimulatorControl

/// Choose geometry from the current tree before input. Native hit, ancestry and
/// fingerprint checks still decide whether the one planned path can start.
enum AgentModeSwipePlanner {
    typealias Points = (from: AgentPoint, to: AgentPoint)

    struct Plan {
        let standard: Points
        let points: Points
        let visibleFrame: CGRect
        let excludedKeyboardFrame: CGRect?
    }

    /// Size the stroke from visible content, not a content-sized accessibility frame.
    static func plan(target: FBSimulatorAXNode, snapshot: AgentModeSnapshot,
                     logicalSize: CGSize, role: RuntimeElementRole?, direction: RuntimeSwipeDirection,
                     distance: Double, nativeTarget: SelectedNativeTarget? = nil) throws -> Plan {
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0,
              let targetPID = target.pid, targetPID > 0,
              let frame = target.frame, validFrame(frame), distance.isFinite,
              distance > 0, distance <= 1 else {
            throw AgentModeFailure("invalidSwipeGeometry", "The current swipe area, display or distance is invalid.")
        }
        let display = CGRect(origin: .zero, size: logicalSize)
        var visible = frame.intersection(display)
        var excludedKeyboard: CGRect?
        if let keyboard = AgentModeKeyboardDetector.occlusion(in: snapshot,
                expectedPID: targetPID, logicalSize: logicalSize) {
            // Only current native ancestry identifies a keyboard-owned scroll area.
            // App content at the same coordinates does not receive this exception.
            let targetIndex = try? AgentModePathIdentityPolicy.uniqueIndex(matching: target,
                in: snapshot, usingNativeIdentity: true)
            let keyboardOwned = targetIndex.map { index in
                let path = snapshot.elements[index].path
                return path == keyboard.path || path.hasPrefix(keyboard.path + ".")
            } ?? false
            if !keyboardOwned, keyboard.frame.minX <= visible.minX, keyboard.frame.maxX >= visible.maxX,
               keyboard.frame.maxY >= display.maxY, keyboard.frame.intersects(visible) {
                visible = CGRect(x: visible.minX, y: visible.minY, width: visible.width,
                    height: max(0, keyboard.frame.minY - visible.minY))
                excludedKeyboard = keyboard.frame
            }
        }
        guard validFrame(visible), visible.width >= 2, visible.height >= 2 else {
            throw AgentModeFailure("invalidSwipeGeometry", "The selected scroll area has no usable visible region.")
        }
        let area = RuntimeSnapshotElement(ref: "", role: role,
            frame: AgentFrame(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height),
            actions: [.swipeWithin])
        guard let standard = area.swipePoints(direction: direction, distance: distance) else {
            throw AgentModeFailure("invalidSwipeGeometry", "The visible swipe area is too small.")
        }
        let planned = try points(standard: standard, target: target, snapshot: snapshot,
            logicalSize: logicalSize, nativeTarget: nativeTarget, planningBounds: visible)
        return Plan(standard: standard, points: planned, visibleFrame: visible,
            excludedKeyboardFrame: excludedKeyboard)
    }

    static func points(standard: Points, target: FBSimulatorAXNode,
                       snapshot: AgentModeSnapshot, logicalSize: CGSize,
                       nativeTarget: SelectedNativeTarget? = nil, planningBounds: CGRect? = nil) throws -> Points {
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0,
              let area = target.frame, validFrame(area),
              [standard.from.x, standard.from.y, standard.to.x, standard.to.y].allSatisfy(\.isFinite),
              standard.from != standard.to else {
            throw AgentModeFailure("invalidSwipeGeometry", "The current swipe area, display or stroke is invalid.")
        }
        guard snapshot.nodes.count == snapshot.elements.count else { return standard }
        let useNativeIdentity = nativeTarget?.nativeIdentity != nil
        let targetIndex: Int
        if useNativeIdentity {
            guard nativeTarget?.nativeIdentity == target.nativeIdentity else {
                throw AgentModeFailure("pathIdentityChanged", "The swipe area does not match its selected native object.")
            }
            targetIndex = try AgentModePathIdentityPolicy.uniqueIndex(matching: target, in: snapshot,
                usingNativeIdentity: true)
        } else {
            let matches = snapshot.nodes.indices.filter { sameSignature(snapshot.nodes[$0], target) }
            guard matches.count == 1, let index = matches.first else { return standard }
            targetIndex = index
        }
        let targetPath = snapshot.elements[targetIndex].path
        let indexByPath = Dictionary(uniqueKeysWithValues: snapshot.elements.enumerated().map { ($0.element.path, $0.offset) })
        let display = CGRect(origin: .zero, size: logicalSize)
        if let planningBounds {
            guard validFrame(planningBounds), area.contains(planningBounds), display.contains(planningBounds) else {
                throw AgentModeFailure("invalidSwipeGeometry", "The planned swipe bounds are outside the current target or display.")
            }
        }
        let delta = AgentPoint(x: standard.to.x - standard.from.x, y: standard.to.y - standard.from.y)
        var nearest: (points: Points, distance: Double)?

        for index in snapshot.nodes.indices {
            let node = snapshot.nodes[index]
            let element = snapshot.elements[index]
            guard node.type == "StaticText", node.children.isEmpty,
                  node.pid == target.pid, node.enabled == true, node.hidden == false,
                  element.role == .text, element.state.enabled, element.state.visible,
                  element.path.hasPrefix(targetPath + "."),
                  let frame = node.frame, validFrame(frame),
                  hasSafeAncestors(of: element.path, targetPath: targetPath,
                      indexByPath: indexByPath, snapshot: snapshot),
                  (try? AgentModePathIdentityPolicy.uniqueIndex(matching: node, in: snapshot,
                      usingNativeIdentity: useNativeIdentity)) != nil else { continue }
            let centre = AgentPoint(x: floor(frame.midX + 0.5), y: floor(frame.midY + 0.5))
            let translated = (from: centre, to: AgentPoint(x: centre.x + delta.x, y: centre.y + delta.y))
            guard frame.contains(CGPoint(x: centre.x, y: centre.y)),
                  inside(translated, area: planningBounds ?? area, display: display) else { continue }
            if frame.contains(CGPoint(x: standard.from.x, y: standard.from.y)),
               inside(standard, area: planningBounds ?? area, display: display) {
                return standard
            }
            let distance = hypot(centre.x - standard.from.x, centre.y - standard.from.y)
            // Native tree order breaks equal-distance ties without an app-specific rule.
            if nearest == nil || distance < nearest!.distance { nearest = (translated, distance) }
        }
        return nearest?.points ?? standard
    }

    private static func hasSafeAncestors(of path: String, targetPath: String,
                                         indexByPath: [String: Int], snapshot: AgentModeSnapshot) -> Bool {
        var current = path
        while let separator = current.lastIndex(of: ".") {
            current = String(current[..<separator])
            if current == targetPath { return true }
            guard let index = indexByPath[current] else { return false }
            let element = snapshot.elements[index]
            let node = snapshot.nodes[index]
            guard element.state.enabled, element.state.visible, node.enabled == true, node.hidden == false,
                  !element.actions.contains(.tap), !element.actions.contains(.typeText) else { return false }
            switch element.role {
            case .button, .cell, .keyboardKey, .list, .menu, .scrollView, .slider, .switch, .tab, .textField:
                return false
            case .other where element.actions.contains(.swipeWithin): return false
            default: break
            }
        }
        return false
    }

    private static func inside(_ points: Points, area: CGRect, display: CGRect) -> Bool {
        [points.from, points.to].allSatisfy {
            let point = CGPoint(x: $0.x, y: $0.y)
            return area.contains(point) && display.contains(point)
        }
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
            && frame.size.width > 0 && frame.size.height > 0
    }

    private static func sameSignature(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode) -> Bool {
        left.pid == right.pid && left.type == right.type && left.identifier == right.identifier
            && left.label == right.label && left.value == right.value && left.frame == right.frame
    }
}
