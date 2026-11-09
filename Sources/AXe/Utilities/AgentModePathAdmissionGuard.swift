import AXeCore
import Foundation
import FBSimulatorControl

/// The selected broker and HID session own this action. Each read has its own
/// native reservation; no tap operation is retained across the point reads.
@MainActor
final class AgentModePathAdmissionGuard: FBSimulatorHIDInputAdmissionGuard {
    private let simulator: FBSimulator
    private let feed: FBSimulatorHIDNativeFreshnessProvider
    private let admission: AgentModeAdmission
    private let nativeTarget: SelectedNativeTarget
    private enum Kind: String { case swipe, drag, pinch }
    private let kind: Kind
    private let starts: [CGPoint]
    private let ends: [CGPoint]
    private let centre: CGPoint?
    private let deadline: DispatchTime
    private(set) var failure: AgentModeFailure?

    init(simulator: FBSimulator, feed: FBSimulatorHIDNativeFreshnessProvider,
         admission: AgentModeAdmission, path: SelectedHIDPath) throws {
        guard path.kind == .swipe || path.kind == .drag, let startX = path.startX, let startY = path.startY,
              let endX = path.endX, let endY = path.endY, admission.target != nil else {
            throw AgentModeFailure("unsupportedTargetPath", "AXe could not check the whole path to this control, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        self.simulator = simulator
        self.feed = feed
        self.admission = admission
        nativeTarget = try Self.target(from: admission)
        kind = path.kind == .drag ? .drag : .swipe
        starts = [CGPoint(x: startX, y: startY)]
        ends = [CGPoint(x: endX, y: endY)]
        centre = nil
        deadline = DispatchTime.now() + 8
    }

    init(simulator: FBSimulator, feed: FBSimulatorHIDNativeFreshnessProvider,
         admission: AgentModeAdmission, pinch: SelectedHIDPinch) throws {
        try pinch.validate()
        guard admission.target != nil else {
            throw AgentModeFailure("unsupportedPinchReference", "A reference pinch requires an exact native area.")
        }
        self.simulator = simulator
        self.feed = feed
        self.admission = admission
        nativeTarget = try Self.target(from: admission)
        kind = .pinch
        centre = CGPoint(x: pinch.centerX, y: pinch.centerY)
        starts = [CGPoint(x: pinch.centerX - pinch.radius, y: pinch.centerY),
                  CGPoint(x: pinch.centerX + pinch.radius, y: pinch.centerY)]
        let endRadius = pinch.radius * pinch.scale
        ends = [CGPoint(x: pinch.centerX - endRadius, y: pinch.centerY),
                CGPoint(x: pinch.centerX + endRadius, y: pinch.centerY)]
        deadline = DispatchTime.now() + 8
    }

    func validate(observation: FBSimulatorHIDSessionObservation, firstEvent: FBSimulatorHIDEvent) async throws {
        do {
            try checkDeadline()
            try admission.validateContext(observation)
            if kind == .drag || kind == .pinch {
                let bounds = CGRect(origin: .zero, size: observation.displayContext.logicalSize)
                guard (starts + ends).allSatisfy({ bounds.contains($0) }) else {
                    throw AgentModeFailure("invalid\(kind.rawValue.capitalized)Geometry", "The \(kind.rawValue) path is outside the current selected display.")
                }
            }
            try validateFirstEvent(firstEvent)
            var initialHits: [FBSimulatorAXNode?] = []
            for start in starts { initialHits.append(try await pointHit(at: start, observation: observation)) }
            let tree = try await PhaseTimer.measure("native.pathGuard.tree") {
                try await FBSimulatorAXSnapshot.acquire(for: simulator, expectedPID: admission.expectedPID,
                    observation: observation, freshnessProvider: feed, policy: try policy(attempts: 2),
                    includeNativeIdentity: nativeTarget.nativeIdentity != nil)
            }
            guard tree.outcome == .ready, let snapshot = tree.snapshot else {
                throw AgentModeFailure("\(kind.rawValue)TreeReadFailed", "AXe could not read the \(kind.rawValue) target before input, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            }
            try checkDeadline()
            let currentTree = try AgentModeSnapshot(roots: snapshot.roots, nativeIdentityMetadata: snapshot.nativeIdentityMetadata,
                context: admission.context)
            try admission.validateScreen(currentTree)
            for (start, hit) in zip(starts, initialHits) {
                try validateRelationship(hit: hit, start: start, tree: currentTree, roots: snapshot.roots)
            }
            // Confirm every initial hit after the same fresh tree, before either DOWN.
            for (start, initialHit) in zip(starts, initialHits) {
                let confirmedHit = try await pointHit(at: start, observation: observation)
                let same: Bool
                switch (initialHit, confirmedHit) {
                case (nil, nil): same = true
                case let (initial?, confirmed?): same = sameSignature(initial, confirmed)
                default: same = false
                }
                guard same else {
                    throw AgentModeFailure("\(kind.rawValue)HitChanged", "A different control is now at the \(kind.rawValue) start, so nothing was sent. \(AgentModeFailure.actFromCapture)")
                }
            }
            try checkDeadline()
            try feed.validateCurrentRevision(expected: observation)
        } catch {
            let reported: AgentModeFailure
            if let known = error as? AgentModeFailure {
                reported = known
            } else if error is CancellationError {
                reported = AgentModeFailure("\(kind.rawValue)Cancelled", "The \(kind.rawValue) was cancelled before input, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            } else {
                reported = AgentModeFailure("\(kind.rawValue)AdmissionFailed", "AXe's \(kind.rawValue) check failed before input, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            }
            failure = reported
            throw reported
        }
    }

    private func validateFirstEvent(_ event: FBSimulatorHIDEvent) throws {
        switch kind {
        case .swipe, .drag:
            guard case let .touch(.down, x, y) = event, starts[0] == CGPoint(x: x, y: y) else {
                throw AgentModeFailure("\(kind.rawValue)StartChanged", "The \(kind.rawValue) start point changed before input, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            }
        case .pinch:
            guard case let .twoFingerTouch(.down, first, second) = event,
                  first == starts[0], second == starts[1], first != second else {
                throw AgentModeFailure("pinchStartChanged", "The pinch start points changed before input, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            }
        }
    }

    /// Nil only for a swipe start in empty space; the fresh tree must then account for the point.
    private func pointHit(at start: CGPoint, observation: FBSimulatorHIDSessionObservation) async throws -> FBSimulatorAXNode? {
        let result = try await PhaseTimer.measure("native.pathGuard.pointHit") {
            try await FBSimulatorAXSnapshot.acquire(at: start, for: simulator,
                expectedPID: admission.expectedPID, observation: observation, freshnessProvider: feed,
                policy: try policy(), includeNativeIdentity: nativeTarget.nativeIdentity != nil)
        }
        if kind == .swipe, result.outcome == .noElementAtPoint {
            try checkDeadline()
            return nil
        }
        guard result.outcome == .ready, let snapshot = result.snapshot, snapshot.roots.count == 1,
              let hit = snapshot.roots.first, hit.pid == admission.expectedPID,
              hit.type?.isEmpty == false, hit.hidden != true, hit.enabled != false,
              let frame = hit.frame, frame.isUsableAgentFrame, frame.contains(start) else {
            throw AgentModeFailure("\(kind.rawValue)PointReadFailed", "AXe could not confirm the control at the \(kind.rawValue) start, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        try checkDeadline()
        return hit
    }

    private func validateRelationship(hit: FBSimulatorAXNode?, start: CGPoint, tree: AgentModeSnapshot,
                                      roots: [FBSimulatorAXNode]) throws {
        guard let expected = admission.target else {
            throw AgentModeFailure("unsupportedIdentity", "This control has no unique ID or label for AXe to check, so nothing was sent. Choose a labelled control or scroll area from the capture in this reply, or use coordinates.")
        }
        let target: FBSimulatorAXNode
        if kind == .pinch, case let .semantic(selectorKind, value, _) = nativeTarget {
            target = try tree.pinchNode(kind: selectorKind, value: value, type: expected.type)
        } else {
            target = try tree.match(target: nativeTarget)
        }
        try expected.validate(target)
        guard target.pid == admission.expectedPID, target.hidden != true, target.enabled != false,
              let frame = target.frame, frame.isUsableAgentFrame, frame.contains(start),
              kind == .drag || ends.allSatisfy({ frame.contains($0) }) else {
            throw AgentModeFailure("\(kind.rawValue)TargetMismatch", "The \(kind.rawValue) path is outside the selected area now, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        if kind == .pinch, centre != CGPoint(x: frame.midX, y: frame.midY) {
            throw AgentModeFailure("pinchStartChanged", "The pinch area moved before input, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        if kind == .drag, start != CGPoint(x: frame.midX, y: frame.midY) {
            throw AgentModeFailure("dragStartChanged", "The drag target moved before input, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        guard let hit else {
            try validateEmptyStart(start, area: target, tree: tree)
            return
        }
        if kind == .swipe, nativeTarget.nativeIdentity != nil,
           try AgentModeCoarseScrollAdmission.validateIfAncestor(hit: hit, area: target,
                start: start, ends: ends, snapshot: tree,
                logicalSize: CGSize(width: admission.context.logicalWidth, height: admission.context.logicalHeight)) {
            return
        }
        let chain = try AgentModePathIdentityPolicy.ancestorChain(hit: hit, area: target,
            roots: roots, snapshot: tree, usingNativeIdentity: nativeTarget.nativeIdentity != nil)
        guard let targetIndex = chain.firstIndex(where: { sameSignature(tree.nodes[$0], target) }) else {
            throw AgentModeFailure("\(kind.rawValue)TargetMismatch", "The \(kind.rawValue) start is outside the selected area now, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        if kind == .pinch, let hitIndex = chain.last {
            let element = tree.elements[hitIndex]
            guard element.state.visible, element.state.enabled else {
                throw AgentModeFailure("pinchTargetMismatch", "A pinch start point is on a hidden or disabled element, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            }
        }
        let descendants = chain.dropFirst(targetIndex + 1)
        guard !descendants.contains(where: { index in
            let element = tree.elements[index]
            return element.role == .list || element.role == .scrollView ||
                (element.role == .other && element.actions.contains(.swipeWithin))
        }) else {
            throw AgentModeFailure("nestedScrollTarget", "The \(kind.rawValue) starts inside another scroll area. Select that scroll area.")
        }
    }

    /// A swipe may start where accessibility reports no element, as in the blank part of a scroll
    /// view. The fresh complete tree must account for the start: every element covering it is the
    /// selected area, one of its ancestors, or a passive descendant such as the area's content
    /// group (only the generic touch and long-press actions; no tap, typing or nested scrolling).
    /// A hittable gesture surface would have been the point read's hit, so it cannot pass here.
    private func validateEmptyStart(_ start: CGPoint, area: FBSimulatorAXNode, tree: AgentModeSnapshot) throws {
        guard kind == .swipe else {
            throw AgentModeFailure("\(kind.rawValue)PointReadFailed", "AXe could not confirm the control at the \(kind.rawValue) start, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        let areaIndex = try AgentModePathIdentityPolicy.uniqueIndex(matching: area, in: tree,
            usingNativeIdentity: nativeTarget.nativeIdentity != nil)
        let areaPath = tree.elements[areaIndex].path
        for (index, node) in tree.nodes.enumerated() where index != areaIndex {
            guard node.hidden != true, let frame = node.frame, frame.contains(start) else { continue }
            let element = tree.elements[index]
            if areaPath.hasPrefix(element.path + ".") { continue }
            let passive: Bool
            switch element.role {
            case .other, .image, .text: passive = element.actions.allSatisfy { $0 == .touch || $0 == .longPress }
            default: passive = false
            }
            guard element.path.hasPrefix(areaPath + "."), passive else {
                throw AgentModeFailure("swipeStartCovered", "Another element covers the swipe start, so nothing was sent. Close what covers it or swipe another area, using the capture in this reply or describe-ui --agent if it has none.")
            }
        }
    }

    private func sameSignature(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode) -> Bool {
        AgentModePathIdentityPolicy.sameSignature(left, right,
            usingNativeIdentity: nativeTarget.nativeIdentity != nil)
    }

    private static func target(from admission: AgentModeAdmission) throws -> SelectedNativeTarget {
        let target: SelectedNativeTarget
        if let selected = admission.nativeTarget { target = selected }
        else if let kind = admission.selectorKind, let value = admission.selectorValue {
            target = .semantic(kind: kind, value: value, elementType: admission.target?.type)
        } else {
            throw AgentModeFailure("unsupportedIdentity", "AXe could not resolve this gesture target to one control, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        try target.validate()
        switch target {
        case let .semantic(kind, _, _):
            guard kind == .id || kind == .label else {
                throw AgentModeFailure("unsupportedIdentity", "This control has no unique ID or label for AXe to check, so nothing was sent. Choose a labelled control or scroll area from the capture in this reply, or use coordinates.")
            }
        case let .nativeObject(identity, _):
            guard identity.pid == admission.expectedPID else {
                throw AgentModeFailure("unsupportedIdentity", "That control belongs to another app, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            }
        }
        return target
    }

    /// Point reads keep one attempt. The tree read uses two: a direct first read, with runtime
    /// preparation only after a verified empty tree, as ordinary descriptions do.
    private func policy(attempts: Int = 1) throws -> FBSimulatorAXAcquisitionPolicy {
        try Task.checkCancellation()
        let now = DispatchTime.now()
        guard now < deadline else {
            throw AgentModeFailure("\(kind.rawValue)AdmissionTimeout", "AXe's \(kind.rawValue) check timed out before input; the app may be busy, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
        return try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: remaining, maximumAttempts: attempts)
    }

    private func checkDeadline() throws {
        try Task.checkCancellation()
        guard DispatchTime.now() < deadline else {
            throw AgentModeFailure("\(kind.rawValue)AdmissionTimeout", "AXe's \(kind.rawValue) check timed out before input; the app may be busy, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
    }
}

/// A point identity is evidence only when it occurs once in the current complete tree.
/// The semantic signature remains independent of optional native-object metadata.
enum AgentModePathIdentityPolicy {
    static func ancestorChain(hit: FBSimulatorAXNode, area: FBSimulatorAXNode,
                              roots: [FBSimulatorAXNode], snapshot: AgentModeSnapshot,
                              usingNativeIdentity: Bool) throws -> [Int] {
        if usingNativeIdentity {
            // Count every occurrence before type, focus or visibility can hide a copy.
            _ = try uniqueIndex(matching: hit, in: snapshot, usingNativeIdentity: true)
            _ = try uniqueIndex(matching: area, in: snapshot, usingNativeIdentity: true)
        }
        var count = 0
        var offset = 0
        var matched: [Int]?
        func walk(_ node: FBSimulatorAXNode, parents: [Int]) {
            guard count < 2 else { return }
            let index = offset
            offset += 1
            let chain = parents + [index]
            if sameSignature(node, hit, usingNativeIdentity: usingNativeIdentity) {
                count += 1
                if count == 1 { matched = chain }
            }
            for child in node.children { walk(child, parents: chain) }
        }
        for root in roots { walk(root, parents: []) }
        guard count == 1, let chain = matched,
              chain.allSatisfy({ snapshot.nodes.indices.contains($0) }),
              chain.contains(where: { sameSignature(snapshot.nodes[$0], area,
                  usingNativeIdentity: usingNativeIdentity) }) else {
            throw AgentModeFailure("pathIdentityChanged", "The swipe's start point is no longer inside the scroll area you chose (the screen moved), so nothing was sent. Swipe again with the area's ref from a current capture.")
        }
        return chain
    }

    static func uniqueIndex(matching node: FBSimulatorAXNode, in snapshot: AgentModeSnapshot,
                            usingNativeIdentity: Bool) throws -> Int {
        let candidates: [Int]
        if usingNativeIdentity {
            guard snapshot.nativeIdentityMetadata?.complete == true, let identity = node.nativeIdentity,
                  identity.pid > 0, identity.objectID > 0, identity.pid == node.pid else {
                throw AgentModeFailure("incompleteNativeIdentity", "The reference path requires complete current native identity evidence.")
            }
            candidates = snapshot.nodes.indices.filter { snapshot.nodes[$0].nativeIdentity == identity }
        } else {
            candidates = snapshot.nodes.indices.filter {
                sameSignature(snapshot.nodes[$0], node, usingNativeIdentity: false)
            }
        }
        guard candidates.count == 1, let index = candidates.first,
              sameSignature(snapshot.nodes[index], node, usingNativeIdentity: usingNativeIdentity) else {
            throw AgentModeFailure("pathIdentityChanged", "The control for this gesture is gone, duplicated or changed, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        return index
    }

    static func sameSignature(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode,
                              usingNativeIdentity: Bool) -> Bool {
        let semantic = left.pid == right.pid && left.type == right.type &&
            left.identifier == right.identifier && left.label == right.label &&
            left.value == right.value && left.frame == right.frame
        guard usingNativeIdentity else { return semantic }
        return semantic && left.nativeIdentity != nil && left.nativeIdentity == right.nativeIdentity &&
            left.role == right.role && left.subrole == right.subrole && left.roleDescription == right.roleDescription &&
            left.focused == right.focused && left.enabled == right.enabled && left.hidden == right.hidden
    }
}
