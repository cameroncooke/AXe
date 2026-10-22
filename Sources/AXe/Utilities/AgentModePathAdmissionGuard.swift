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
    private let kind: SelectedHIDPath.Kind
    private let start: CGPoint
    private let end: CGPoint
    private let deadline: DispatchTime
    private(set) var failure: AgentModeFailure?

    init(simulator: FBSimulator, feed: FBSimulatorHIDNativeFreshnessProvider,
         admission: AgentModeAdmission, path: SelectedHIDPath) throws {
        guard path.kind == .swipe || path.kind == .drag, let startX = path.startX, let startY = path.startY,
              let endX = path.endX, let endY = path.endY, admission.target != nil,
              admission.selectorKind == .id || admission.selectorKind == .label,
              admission.selectorValue != nil else {
            throw AgentModeFailure("unsupportedTargetPath", "A reference path requires an exact native target and complete path.")
        }
        self.simulator = simulator
        self.feed = feed
        self.admission = admission
        kind = path.kind
        start = CGPoint(x: startX, y: startY)
        end = CGPoint(x: endX, y: endY)
        deadline = DispatchTime.now() + 8
    }

    func validate(observation: FBSimulatorHIDSessionObservation, firstEvent: FBSimulatorHIDEvent) async throws {
        do {
            try checkDeadline()
            try admission.validateContext(observation)
            if kind == .drag {
                let size = observation.displayContext.logicalSize
                let bounds = CGRect(origin: .zero, size: size)
                guard bounds.contains(start), bounds.contains(end) else {
                    throw AgentModeFailure("invalidDragGeometry", "The drag path is outside the current selected display.")
                }
            }
            guard case let .touch(.down, x, y) = firstEvent, x == start.x, y == start.y else {
                throw AgentModeFailure("\(kind.rawValue)StartChanged", "The \(kind.rawValue) start changed before input. Refresh the snapshot.")
            }
            let initialHit = try await pointHit(observation: observation)
            let tree = try await FBSimulatorAXSnapshot.acquire(for: simulator, expectedPID: admission.expectedPID,
                observation: observation, freshnessProvider: feed, policy: try policy(), preparation: .automationSession)
            guard tree.outcome == .ready, let snapshot = tree.snapshot else {
                throw AgentModeFailure("\(kind.rawValue)TreeReadFailed", "The \(kind.rawValue) target could not be confirmed before input. Refresh the snapshot.")
            }
            try checkDeadline()
            try admission.validateScreen(snapshot.roots)
            try validateRelationship(hit: initialHit, roots: snapshot.roots)
            // A fresh tree cannot validate an earlier point result on its own.
            let confirmedHit = try await pointHit(observation: observation)
            guard sameSignature(initialHit, confirmedHit) else {
                throw AgentModeFailure("\(kind.rawValue)HitChanged", "The control at the \(kind.rawValue) start changed. Refresh the snapshot.")
            }
            try checkDeadline()
            try feed.validateCurrentRevision(expected: observation)
        } catch {
            let reported: AgentModeFailure
            if let known = error as? AgentModeFailure {
                reported = known
            } else if error is CancellationError {
                reported = AgentModeFailure("\(kind.rawValue)Cancelled", "The \(kind.rawValue) was cancelled before input. Refresh the snapshot.")
            } else {
                reported = AgentModeFailure("\(kind.rawValue)AdmissionFailed", "The native \(kind.rawValue) check failed. Refresh the snapshot.")
            }
            failure = reported
            throw reported
        }
    }

    private func pointHit(observation: FBSimulatorHIDSessionObservation) async throws -> FBSimulatorAXNode {
        let result = try await FBSimulatorAXSnapshot.acquire(at: start, for: simulator,
            expectedPID: admission.expectedPID, observation: observation, freshnessProvider: feed,
            policy: try policy(), preparation: .automationSession)
        guard result.outcome == .ready, let snapshot = result.snapshot, snapshot.roots.count == 1,
              let hit = snapshot.roots.first, hit.pid == admission.expectedPID,
              hit.type?.isEmpty == false, hit.hidden != true, hit.enabled != false,
              let frame = hit.frame, validFrame(frame), frame.contains(start) else {
            throw AgentModeFailure("\(kind.rawValue)PointReadFailed", "The control at the \(kind.rawValue) start could not be confirmed. Refresh the snapshot.")
        }
        try checkDeadline()
        return hit
    }

    private func validateRelationship(hit: FBSimulatorAXNode, roots: [FBSimulatorAXNode]) throws {
        guard let expected = admission.target, let selectorKind = admission.selectorKind,
              let value = admission.selectorValue else {
            throw AgentModeFailure("unsupportedIdentity", "The \(kind.rawValue) target has no exact native selector.")
        }
        let tree = try AgentModeSnapshot(roots: roots)
        let target = try tree.match(kind: selectorKind, value: value, type: expected.type)
        try expected.validate(target)
        guard target.pid == admission.expectedPID, target.hidden != true, target.enabled != false,
              let frame = target.frame, validFrame(frame), frame.contains(start), kind == .drag || frame.contains(end) else {
            throw AgentModeFailure("\(kind.rawValue)TargetMismatch", "The \(kind.rawValue) path is outside the selected area. Refresh the snapshot.")
        }
        if kind == .drag, start != CGPoint(x: frame.midX, y: frame.midY) {
            throw AgentModeFailure("dragStartChanged", "The drag start is not the fresh target centre. Refresh the snapshot.")
        }
        guard tree.nodes.count == tree.elements.count else {
            throw AgentModeFailure("\(kind.rawValue)TargetMismatch", "The \(kind.rawValue) hierarchy could not be matched to its reference table. Refresh the snapshot.")
        }
        var hitCount = 0
        var nextNodeIndex = 0
        var hitChain: [Int]?
        func walk(_ node: FBSimulatorAXNode, parents: [Int]) {
            guard hitCount < 2 else { return }
            let nodeIndex = nextNodeIndex
            nextNodeIndex += 1
            let chain = parents + [nodeIndex]
            if sameSignature(node, hit) {
                hitCount += 1
                if hitCount == 1 { hitChain = chain }
            }
            for child in node.children { walk(child, parents: chain) }
        }
        // AgentModeSnapshot already checked the complete tree's size and depth.
        for root in roots { walk(root, parents: []) }
        guard hitCount == 1, let chain = hitChain,
              let targetIndex = chain.firstIndex(where: { sameSignature(tree.nodes[$0], target) }) else {
            throw AgentModeFailure("\(kind.rawValue)TargetMismatch", "The \(kind.rawValue) start is outside the selected area. Refresh the snapshot.")
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

    private func sameSignature(_ left: FBSimulatorAXNode, _ right: FBSimulatorAXNode) -> Bool {
        left.pid == right.pid && left.type == right.type && left.identifier == right.identifier &&
            left.label == right.label && left.value == right.value && left.frame == right.frame
    }

    private func validFrame(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }

    private func policy() throws -> FBSimulatorAXAcquisitionPolicy {
        try Task.checkCancellation()
        let now = DispatchTime.now()
        guard now < deadline else {
            throw AgentModeFailure("\(kind.rawValue)AdmissionTimeout", "The \(kind.rawValue) check timed out before input. Refresh the snapshot.")
        }
        let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
        return try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: remaining, maximumAttempts: 1)
    }

    private func checkDeadline() throws {
        try Task.checkCancellation()
        guard DispatchTime.now() < deadline else {
            throw AgentModeFailure("\(kind.rawValue)AdmissionTimeout", "The \(kind.rawValue) check timed out before input. Refresh the snapshot.")
        }
    }
}
