import Foundation
import FBSimulatorControl

/// Checks the owned native tree of one AX tap operation against a published table.
/// The operation's own read is the fresh screen evidence; no separate pre-description
/// is compared with it. Native temporal target, point, PID and live-context validation
/// before the first event are unchanged.
protocol AgentOwnedTapAdmission: Sendable {
    var requiresNativeIdentity: Bool { get }
    func validateContext(_ context: SelectedHIDContext, pid: Int32) throws
    func validateOwnedSnapshot(roots: [FBSimulatorAXNode], nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata?,
                               context: SelectedHIDContext, pid: Int32,
                               nativeTarget: FBSimulatorAXNode) throws -> AgentModeAdmission
}

extension AgentOwnedTapAdmission {
    func validateOwnedSnapshot(roots: [FBSimulatorAXNode], context: SelectedHIDContext, pid: Int32,
                               nativeTarget: FBSimulatorAXNode) throws -> AgentModeAdmission {
        try validateOwnedSnapshot(roots: roots, nativeIdentityMetadata: nil, context: context, pid: pid,
            nativeTarget: nativeTarget)
    }
}

/// One `tap --agent --snapshot-id --ref`. The owned tree must have the published table's
/// exact native fingerprint, the same as the former pre-description had to; the target
/// and its execution authority are resolved on that owned tree before input.
struct AgentReferenceTapAdmission: AgentOwnedTapAdmission {
    private let published: AgentModeSnapshot
    private let context: SelectedHIDContext
    private let expectedPID: Int32
    private let ref: String
    private let original: FBSimulatorAXNode
    private let reference: SelectedNativeTarget
    private let execution: SelectedNativeTarget
    private let upgradesPhysicalButton: Bool
    private let tapStyle: SelectedTapStyle?
    private let preDelay: Double
    private let postDelay: Double

    init(published: AgentModeSnapshot, context: SelectedHIDContext, pid: Int32, mode: AgentModeRequest) throws {
        try mode.validate()
        guard mode.kind == .tap, let ref = mode.ref, mode.point == nil, mode.selectorKind == nil,
              mode.tapSelector == nil, pid > 0 else {
            throw AgentModeFailure("invalidReference", "An owned reference tap requires one published reference.")
        }
        self.published = published
        self.context = context
        expectedPID = pid
        self.ref = ref
        original = try published.node(ref: ref, requiredAction: .tap)
        reference = try published.target(ref: ref)
        // The same resolution the pre-description applied to its fresh tree, now on the table.
        upgradesPhysicalButton = (mode.tapStyle == nil || mode.tapStyle == .physical) && original.type == "Button"
        execution = try Self.executionTarget(in: published, reference: reference, node: original,
            context: context, upgrade: upgradesPhysicalButton)
        tapStyle = mode.tapStyle
        preDelay = mode.preDelay
        postDelay = mode.postDelay
    }

    var requiresNativeIdentity: Bool { execution.nativeIdentity != nil }

    func request(requestID: UUID) throws -> SelectedHIDRequest {
        guard let uuid = UUID(uuidString: context.screenUUID) else {
            throw AgentModeFailure("missingContext", "The selected runtime context is incomplete.")
        }
        let ax = SelectedAXRequest(kind: .tap, expectedPID: expectedPID, endpoint: nil,
            selectorKind: nil, selectorValue: nil, preDelay: preDelay, postDelay: postDelay,
            elementType: original.type, tapStyle: tapStyle, nativeTarget: execution)
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: requestID,
            screenID: context.screenID, screenUUID: uuid, operation: .complete, token: nil, primitives: [], ax: ax)
        try request.validate()
        return request
    }

    func validateContext(_ context: SelectedHIDContext, pid: Int32) throws {
        _ = try AgentModePIDPolicy.verifiedPID(pid, expected: expectedPID)
        guard self.context == context else {
            throw AgentModeFailure("contextChanged", "The native runtime context changed. Refresh the snapshot.")
        }
    }

    func validateOwnedSnapshot(roots: [FBSimulatorAXNode], nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata?,
                               context: SelectedHIDContext, pid: Int32,
                               nativeTarget: FBSimulatorAXNode) throws -> AgentModeAdmission {
        try validateContext(context, pid: pid)
        let fresh = try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: nativeIdentityMetadata, context: context)
        guard fresh.nativeFingerprint == published.nativeFingerprint else {
            throw AgentModeFailure("screenChanged", "The screen changed outside this reference table. Refresh the snapshot.")
        }
        try published.validateProtectedReference(ref, in: fresh)
        let current = try fresh.match(target: reference)
        try AgentModeTarget(original, nativeTarget: reference).validate(current)
        let currentExecution = try Self.executionTarget(in: fresh, reference: reference, node: current,
            context: context, upgrade: upgradesPhysicalButton)
        guard currentExecution == execution else {
            throw AgentModeFailure("targetChanged", "The native target identity or frame changed before input. Refresh the snapshot.")
        }
        let target = try AgentModeTarget(current, nativeTarget: execution)
        try target.validate(nativeTarget)
        var admission = AgentModeAdmission(context: context, expectedPID: pid, screenHash: fresh.hash,
            nativeFingerprint: fresh.nativeFingerprint, target: target, nativeTarget: execution)
        if case let .semantic(kind, value, _) = execution {
            admission.selectorKind = kind
            admission.selectorValue = value
        }
        return admission
    }

    private static func executionTarget(in snapshot: AgentModeSnapshot, reference: SelectedNativeTarget,
                                        node: FBSimulatorAXNode, context: SelectedHIDContext,
                                        upgrade: Bool) throws -> SelectedNativeTarget {
        guard upgrade else { return reference }
        return try snapshot.physicalButtonExecutionTarget(reference: reference, node: node, context: context)
    }
}
