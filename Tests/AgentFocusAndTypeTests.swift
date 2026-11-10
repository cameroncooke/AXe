import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Explicit reference focus and type")
struct AgentFocusAndTypeTests {
    @Test("The CLI makes focus explicit and preserves default typing")
    func cliContract() throws {
        let suffix = ["--agent", "--udid", "fixture", "--snapshot-id", table.uuidString, "--ref", "e2"]
        let focus = try Type.parse(["Hello", "--focus"] + suffix)
        try focus.validate()
        #expect(try focus.agentRequest().agent?.kind == .focusAndType)
        let ordinary = try Type.parse(["Hello"] + suffix)
        try ordinary.validate()
        #expect(try ordinary.agentRequest().agent?.kind == .typeText)
        let asserted = try Type.parse(["Hello", "--agent", "--udid", "fixture", "--focus-id", "field"])
        try asserted.validate()
        #expect(try asserted.agentRequest().agent?.kind == .typeText)
        for args in [
            ["Hello", "--focus", "--udid", "fixture"],
            ["Hello", "--agent", "--focus", "--udid", "fixture", "--focus-id", "field"],
            ["Hello", "--agent", "--focus", "--udid", "fixture"],
            ["Hello", "--focus", "--focus-id", "field"] + suffix,
        ] {
            #expect(throws: (any Error).self) { try Type.parse(args).validate() }
        }
    }

    @Test("Whole text and all mixed payloads reject before a composite can dispatch")
    func requestPrevalidation() throws {
        try request().validate()
        for text in ["", "£", String(repeating: "a", count: 257)] {
            var invalid = request(); invalid.text = text
            #expect(throws: (any Error).self) { try invalid.validate() }
        }
        var variants: [AgentModeRequest] = []
        var invalid = request(); invalid.ref = nil; variants.append(invalid)
        invalid = request(); invalid.snapshotID = nil; variants.append(invalid)
        invalid = request(); invalid.ref = "e0"; variants.append(invalid)
        invalid = request(); invalid.selectorKind = .id; invalid.selectorValue = "field"; variants.append(invalid)
        invalid = request(); invalid.tapStyle = .physical; variants.append(invalid)
        invalid = request(); invalid.duration = 2; variants.append(invalid)
        invalid = request(); invalid.point = .init(x: 10, y: 10); variants.append(invalid)
        invalid = request(); invalid.keyEvents = [.down(4), .up(4)]; variants.append(invalid)
        invalid = request(); invalid.rowOffset = 1; variants.append(invalid)
        for invalid in variants {
            #expect(throws: (any Error).self) { try invalid.validate() }
        }
    }

    @Test("Shared container IDs do not require app-wide ID uniqueness")
    func typedFieldIdentityBeforeFocus() throws {
        let field = fixture(id: "shared", key: 101)
        let snapshot = try make([fixture(type: "Group", id: "shared", key: 102, children: [field])])
        let plan = try AgentFocusAndTypePlan(snapshot: snapshot, ref: "e3", context: context(), pid: 1234)
        #expect(plan.fieldTarget.semanticID == "shared")
        #expect(throws: (any Error).self) { _ = try snapshot.reference(id: "shared", action: .tap) }
        #expect(throws: (any Error).self) { _ = try snapshot.node(ref: "e3", requiredAction: .typeText) }
        // Public reference batches still reject an unfocused type step before the tap.
        let document = try JSONDecoder().decode(AgentBatchDocument.self, from: Data("""
            {"snapshotID":"\(table)","steps":[{"action":"tap","ref":"e3"},{"action":"type","ref":"e3","text":"x"}]}
            """.utf8))
        let batch = AgentBatchRequest(expectedPID: nil, snapshotID: document.snapshotID, steps: document.steps)
        #expect(throws: (any Error).self) {
            _ = try AgentBatchReferencePlan(request: batch, snapshotID: table, snapshot: snapshot, context: context(), pid: 1234)
        }
    }

    @Test("Keyboard appearance can move the same field and reorder siblings")
    func ownedFocusTransition() throws {
        let field = fixture(id: "field", key: 101)
        let before = try make([field])
        let plan = try AgentFocusAndTypePlan(snapshot: before, ref: "e2", context: context(), pid: 1234)
        var focused = field; focused.focused = true; focused.frame?.y = 80; focused.frame?.width = 200
        let after = try make([fixture(type: "Button", id: "keyboard", key: 102), focused])
        let baseline = try plan.focusedBaseline(snapshot: after, context: context(), pid: 1234)
        #expect(try baseline.focusedReference(snapshot: after, context: context(), pid: 1234) == "e3")
        let node = try after.node(ref: "e3", requiredAction: .typeText)
        try SelectedKeyboardFocusPolicy.validate(node, expectedPID: 1234, fieldTarget: baseline.fieldTarget)
        let exact = try AgentModeTarget(node, nativeTarget: baseline.fieldTarget)
        var edited = focused; edited.value = .string("other")
        let changed = try make([edited]).match(target: baseline.fieldTarget)
        #expect(throws: (any Error).self) {
            try SelectedKeyboardEditingTargetPolicy.validate(changed, against: exact, expectedPID: 1234,
                fieldTarget: baseline.fieldTarget, logicalSize: .init(width: 390, height: 800), editingStarted: false)
        }
    }

    @Test("Keyboard reparenting keeps the exact field authority despite new parent IDs and paths")
    func sameFieldCanChangeParent() throws {
        let field = fixture(id: "field", key: 101)
        let oldParent = fixture(type: "Group", id: "old-parent", role: "AXGroup", key: 102, children: [field],
            frame: frame(x: 0, y: 0, width: 390, height: 800))
        let plan = try AgentFocusAndTypePlan(snapshot: make([oldParent]), ref: "e3", context: context(), pid: 1234)
        var focused = field; focused.focused = true; focused.frame?.y = 80
        let newParent = fixture(type: "Group", id: "new-parent", role: "AXGroup", key: 103, children: [focused],
            frame: frame(x: 0, y: 0, width: 390, height: 800))
        let keyboard = fixture(type: "Button", id: "keyboard", role: "AXButton", key: 104)
        let fresh = try make([keyboard, newParent])
        let baseline = try plan.focusedBaseline(snapshot: fresh, context: context(), pid: 1234)
        #expect(baseline.fieldTarget.semanticID == "field")
        #expect(try baseline.focusedReference(snapshot: fresh, context: context(), pid: 1234) == "e4")
        #expect(try fresh.node(ref: "e4", requiredAction: .typeText).nativeIdentity?.objectID == 101)
    }

    @Test("The tap can change value, but the exact post-focus baseline cannot change before typing")
    func postFocusValueBaseline() throws {
        var field = fixture(id: "field", value: "Before", key: 101)
        let plan = try AgentFocusAndTypePlan(snapshot: make([field]), ref: "e2", context: context(), pid: 1234)
        field.focused = true; field.value = .string("After focus")
        let focused = try make([field])
        let baseline = try plan.focusedBaseline(snapshot: focused, context: context(), pid: 1234)
        #expect(try baseline.focusedReference(snapshot: focused, context: context(), pid: 1234) == "e2")
        field.value = .string("Changed before keys")
        #expect(throws: (any Error).self) {
            _ = try baseline.focusedReference(snapshot: make([field]), context: context(), pid: 1234)
        }
    }

    @Test("Anonymous fields keep one native keyboard authority with exact UInt64 identity")
    func anonymousAuthority() throws {
        let key: UInt64 = 9_007_199_254_740_993
        let field = fixture(id: nil, key: key)
        let plan = try AgentFocusAndTypePlan(snapshot: make([field]), ref: "e2", context: context(), pid: 1234)
        #expect(plan.fieldTarget.nativeIdentity?.objectID == key)
        var focused = field; focused.focused = true
        _ = try plan.focusedBaseline(snapshot: make([focused]), context: context(), pid: 1234)
        focused.nativeObjectID = key + 1
        #expect(throws: (any Error).self) {
            _ = try plan.focusedBaseline(snapshot: make([focused]), context: context(), pid: 1234)
        }
    }

    @Test("Unavailable state, label-only fields and tap-only aliases cannot authorize typing",
          arguments: ["role", "disabled", "hidden", "missingFocus", "outside", "negativeWidth", "duplicateID", "labelOnly", "alias", "incomplete"])
    func invalidInitialField(variant: String) throws {
        var field = fixture(id: "field", key: 101)
        var nodes: [AXNodeFixture] = []
        var complete = true
        switch variant {
        case "role": field.type = "Button"
        case "disabled": field.enabled = false
        case "hidden": field.hidden = true
        case "missingFocus": field.focused = nil
        case "outside": field.frame?.y = 790
        case "negativeWidth": field.frame?.width = -20
        case "duplicateID": nodes.append(fixture(id: "field", label: "Other", key: 102))
        case "labelOnly": field.identifier = " bad "
        case "alias": field.identifier = nil; nodes.append(field)
        default: field.identifier = nil; complete = false
        }
        nodes.insert(field, at: 0)
        #expect(throws: (any Error).self) {
            _ = try AgentFocusAndTypePlan(snapshot: make(nodes, complete: complete), ref: "e2", context: context(), pid: 1234)
        }
    }

    @Test("Post-focus identity, owner, focus and state changes stop typing",
          arguments: ["key", "id", "label", "role", "pid", "focus", "hidden", "disabled", "missingKey", "duplicateKey", "duplicateID"])
    func changedFieldRefuses(variant: String) throws {
        let initial = fixture(id: "field", key: 101)
        let plan = try AgentFocusAndTypePlan(snapshot: make([initial]), ref: "e2", context: context(), pid: 1234)
        var changed = initial; changed.focused = true
        var extra: [AXNodeFixture] = []
        switch variant {
        case "key": changed.nativeObjectID = 103
        case "id": changed.identifier = "replacement"
        case "label": changed.label = "Changed"
        case "role": changed.role = "AXButton"
        case "pid": changed.pid = 9999
        case "focus": changed.focused = false
        case "hidden": changed.hidden = true
        case "disabled": changed.enabled = false
        case "missingKey": changed.nativeObjectID = nil
        case "duplicateKey": extra.append(fixture(type: "Button", id: "another", key: 101))
        default: extra.append(fixture(id: "field", key: 104))
        }
        #expect(throws: (any Error).self) {
            _ = try plan.focusedBaseline(snapshot: make([changed] + extra), context: context(), pid: 1234)
        }
    }

    @Test("Semantic fields without optional UID keep the existing identity boundary")
    func semanticCompatibility() throws {
        var field = fixture(id: "field", key: nil)
        let plan = try AgentFocusAndTypePlan(snapshot: make([field], complete: false), ref: "e2", context: context(), pid: 1234)
        #expect(plan.fieldTarget.semanticID == "field")
        field.focused = true
        _ = try plan.focusedBaseline(snapshot: make([field], complete: false), context: context(), pid: 1234)
    }

    @Test("App, boot, display, geometry, rotation and hinge stay bound")
    func changedContextRefuses() throws {
        var field = fixture(id: "field", key: 101)
        let plan = try AgentFocusAndTypePlan(snapshot: make([field]), ref: "e2", context: context(), pid: 1234)
        field.focused = true
        for fresh in [try context(boot: "new"), try context(screen: 3), try context(rotation: 90),
                      try context(pose: "folded"), try context(width: 800)] {
            #expect(throws: (any Error).self) {
                _ = try plan.focusedBaseline(snapshot: make([field], context: fresh), context: fresh, pid: 1234)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try plan.focusedBaseline(snapshot: make([field]), context: context(), pid: 9999)
        }
    }

    @Test("Root owner changes refuse focus even when the field keeps its expected PID",
          arguments: ["otherRoot", "mixedRoots", "nonpositiveRoot", "emptyRoots"])
    func rootOwnerRefuses(variant: String) throws {
        let field = fixture(id: "field", key: 101)
        let before = try make([field])
        #expect(before.hasNativeOwner(1234))
        #expect(!before.hasNativeOwner(9999) && !before.hasNativeOwner(0))
        let plan = try AgentFocusAndTypePlan(snapshot: before, ref: "e2", context: context(), pid: 1234)
        var focused = field
        focused.focused = true
        let ownRoot = fixture(type: "Application", id: "app", key: 1, children: [focused],
            frame: frame(x: 0, y: 0, width: 390, height: 800))
        var otherRoot = fixture(type: "Application", id: "other-app", pid: 9999, key: 2,
            frame: frame(x: 0, y: 0, width: 390, height: 800))
        let roots: [AXNodeFixture]
        switch variant {
        case "otherRoot":
            otherRoot.children = [focused]
            roots = [otherRoot]
        case "mixedRoots": roots = [ownRoot, otherRoot]
        case "nonpositiveRoot":
            otherRoot.pid = 0
            otherRoot.nativeObjectID = nil
            otherRoot.children = [focused]
            roots = [otherRoot]
        default: roots = []
        }
        let nodes = try AXNodeFixture.decode(roots)
        let fresh = try AgentModeSnapshot(roots: nodes,
            nativeIdentityMetadata: .init(complete: true, reason: nil), context: context())
        #expect(!fresh.hasNativeOwner(1234))
        do {
            _ = try plan.focusedBaseline(snapshot: fresh, context: context(), pid: 1234)
            Issue.record("A changed or unavailable snapshot root owner permitted focus.")
        } catch let error as AgentModeFailure {
            #expect(error.code == "focusContextChanged")
        }
    }

    @Test("Partial failure keeps the completed focus and zero later key events")
    func partialProgress() throws {
        var progress = AgentFocusAndTypeProgress()
        try progress.append(response(kind: .tap, count: 2), action: .tap)
        progress.reject(AgentModeFailure("focusTargetChanged", "Changed."), context: nil)
        let result = progress.receipt(stopped: true)
        #expect(result.totalSteps == 2 && result.completedSteps == 1 && result.stoppedAt == 2)
        #expect(result.steps[0].receipt?.enqueuedEventCount == 2 && result.steps[1].receipt == nil)
        #expect(result.steps[1].status == "rejectedBeforeInput" && !result.replayed && !result.rolledBack)
    }

    @Test("A batch focus step that typed nothing after its focus tap is never completed")
    func focusStepOutcome() throws {
        var partial = AgentFocusAndTypeProgress()
        try partial.append(response(kind: .tap, count: 2), action: .tap)
        partial.reject(AgentModeFailure("focusTargetChanged", "Changed."), context: nil)
        let typedNothing = AgentFocusAndTypeProgress.stepAction(partial.receipt(stopped: true), failed: true,
            cleanup: "notNeeded", quarantine: nil, retried: false)
        #expect(typedNothing.outcome == "failedNoReplay" && typedNothing.enqueuedEventCount == 2)

        var refused = AgentFocusAndTypeProgress()
        refused.reject(AgentModeFailure("targetChanged", "Moved."), context: nil)
        let sentNothing = AgentFocusAndTypeProgress.stepAction(refused.receipt(stopped: true), failed: true,
            cleanup: "notNeeded", quarantine: nil, retried: false)
        #expect(sentNothing.outcome == "failedBeforeInput" && sentNothing.enqueuedEventCount == 0)

        var done = AgentFocusAndTypeProgress()
        try done.append(response(kind: .tap, count: 2), action: .tap)
        try done.append(response(kind: .typeText, count: 8), action: .type)
        let both = AgentFocusAndTypeProgress.stepAction(done.receipt(stopped: false), failed: false,
            cleanup: "notNeeded", quarantine: nil, retried: false)
        #expect(both.outcome == "enqueuedAndDrained" && both.enqueuedEventCount == 10 && both.kind == .focusAndType)
    }

    @Test("Failed focus does not become a failed type attempt")
    func failedFirstPhase() throws {
        var progress = AgentFocusAndTypeProgress()
        let error = AgentModeFailure("nativeActionFailed", "Rejected.")
        #expect(throws: AgentModeFailure.self) {
            try progress.append(response(kind: .tap, count: 0, error: error), action: .tap)
        }
        progress.reject(error, context: nil)
        #expect(progress.receipt(stopped: true).stoppedAt == 1 && progress.steps.count == 1)
        #expect(progress.completed == 0)
    }

    @Test("Partial or uncertain typing preserves prior focus and the actual key receipt",
          arguments: ["releaseEnqueuedAndDrained", "uncertain"])
    func partialTyping(cleanup: String) throws {
        var progress = AgentFocusAndTypeProgress()
        try progress.append(response(kind: .tap, count: 2), action: .tap)
        let error = AgentModeFailure("nativeActionFailed", "Interrupted.")
        #expect(throws: AgentModeFailure.self) {
            try progress.append(response(kind: .typeText, count: 2, cleanup: cleanup, error: error), action: .type)
        }
        progress.reject(error, context: nil)
        let result = progress.receipt(stopped: true)
        #expect(result.completedSteps == 1 && result.steps.count == 2 && result.stoppedAt == 2)
        #expect(result.steps[1].receipt?.enqueuedEventCount == 2 && result.steps[1].receipt?.cleanup == cleanup)
        #expect(!result.replayed && !result.rolledBack)
    }

    @Test("Refresh quarantine does not erase an already drained input phase")
    func refreshQuarantineKeepsCompletedInput() throws {
        var progress = AgentFocusAndTypeProgress()
        var phase = response(kind: .tap, count: 2)
        let input = phase.agent?.data.action
        let quarantine = SelectedHIDQuarantine(recordPath: "owned-recovery", persisted: true, error: nil)
        phase.quarantine = quarantine
        phase.agent = AgentModeResult(error: AgentModeFailure("postActionRefreshQuarantined", "Refresh failed."),
            action: input, cache: .init(status: "quarantined", reason: "refresh", requiresRefresh: true),
            quarantine: quarantine)
        #expect(throws: AgentModeFailure.self) { try progress.append(phase, action: .tap) }
        #expect(progress.completed == 1 && progress.steps.first?.status == "completed")
        progress.reject(AgentModeFailure("postActionRefreshQuarantined", "Refresh failed."), context: nil)
        #expect(progress.receipt(stopped: true).completedSteps == 1)
        #expect(progress.steps.last?.receipt == nil && progress.steps.last?.action == .type)
    }

    @Test("Successful phases and failed final observation retain both completions")
    func finalObservationFailure() throws {
        var progress = AgentFocusAndTypeProgress()
        try progress.append(response(kind: .tap, count: 2), action: .tap)
        try progress.append(response(kind: .typeText, count: 4), action: .type)
        progress.reject(AgentModeFailure("focusTypeRefreshFailed", "Refresh."), context: nil)
        let result = progress.receipt(stopped: true)
        #expect(result.completedSteps == 2 && result.steps.count == 2 && result.stoppedAt == 2)
        #expect(result.steps.reduce(0) { $0 + ($1.receipt?.enqueuedEventCount ?? 0) } == 6)
        #expect(!result.replayed && !result.rolledBack)
    }

    private let table = UUID(uuidString: "3FF70D78-26DA-4314-B37B-4CB57D2A1A85")!
    private func request() -> AgentModeRequest {
        .init(kind: .focusAndType, snapshotID: table, ref: "e2", text: "Hello")
    }
    private func response(kind: AgentModeRequest.Kind, count: Int, cleanup: String = "notNeeded", error: AgentModeFailure? = nil) -> SelectedHIDResponse {
        let outcome = error == nil ? "enqueuedAndDrained" : "failedBeforeInput"
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: UUID(),
            outcome: outcome, token: nil, enqueuedEventCount: count, cleanup: cleanup, error: error?.message, context: nil)
        response.agent = AgentModeResult(error: error,
            action: .init(kind: kind, outcome: outcome, enqueuedEventCount: count, cleanup: cleanup, replayed: false, quarantine: nil),
            cache: .init(status: "refreshed", reason: nil, requiresRefresh: false))
        return response
    }
    private func context(boot: String = "fixture", screen: Int = 1, rotation: Int = 0,
                         pose: String = "rigid", width: Int = 390) throws -> SelectedHIDContext {
        try .fixture(boot: boot, screenID: screen, width: width, height: 800, rotation: rotation,
            pixelWidth: 1170, pixelHeight: 2400, pose: pose)
    }
    private func make(_ children: [AXNodeFixture], complete: Bool = true,
                      context selectedContext: SelectedHIDContext? = nil) throws -> AgentModeSnapshot {
        let root = fixture(type: "Application", id: "app", key: 1, children: children,
            frame: frame(x: 0, y: 0, width: 390, height: 800))
        return try AgentModeSnapshot(roots: AXNodeFixture.decode([root]),
            nativeIdentityMetadata: .init(complete: complete, reason: complete ? nil : "incomplete"),
            context: try selectedContext ?? context())
    }
}

private func frame(x: Double = 10, y: Double = 200, width: Double = 200, height: Double = 44) -> AXNodeFixture.Frame {
    .init(x: x, y: y, width: width, height: height)
}

/// `key` becomes the native identity with the node's `pid` at encode time.
private func fixture(type: String = "TextField", id: String? = nil, label: String = "Field",
                     role: String = "AXTextField", value: String = "", pid: Int32 = 1234, key: UInt64? = nil,
                     children: [AXNodeFixture] = [], frame: AXNodeFixture.Frame = frame()) -> AXNodeFixture {
    AXNodeFixture(type: type, identifier: id, label: label, value: .string(value), role: role, frame: frame,
        pid: pid, focused: false, enabled: true, hidden: false, nativeObjectID: key, children: children)
}
