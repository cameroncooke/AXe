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
        let field = Node(id: "shared", key: 101)
        let snapshot = try make([Node(type: "Group", id: "shared", key: 102, children: [field])])
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
        let field = Node(id: "field", key: 101)
        let before = try make([field])
        let plan = try AgentFocusAndTypePlan(snapshot: before, ref: "e2", context: context(), pid: 1234)
        var focused = field; focused.focused = true; focused.frame.y = 80; focused.frame.width = 200
        let after = try make([Node(type: "Button", id: "keyboard", key: 102), focused])
        let baseline = try plan.focusedBaseline(snapshot: after, context: context(), pid: 1234)
        #expect(try baseline.focusedReference(snapshot: after, context: context(), pid: 1234) == "e3")
        let node = try after.node(ref: "e3", requiredAction: .typeText)
        try SelectedKeyboardFocusPolicy.validate(node, expectedPID: 1234, fieldTarget: baseline.fieldTarget)
        let exact = try AgentModeTarget(node, nativeTarget: baseline.fieldTarget)
        var edited = focused; edited.value = "other"
        let changed = try make([edited]).match(target: baseline.fieldTarget)
        #expect(throws: (any Error).self) {
            try SelectedKeyboardEditingTargetPolicy.validate(changed, against: exact, expectedPID: 1234,
                fieldTarget: baseline.fieldTarget, logicalSize: .init(width: 390, height: 800), editingStarted: false)
        }
    }

    @Test("Keyboard reparenting keeps the exact field authority despite new parent IDs and paths")
    func sameFieldCanChangeParent() throws {
        let field = Node(id: "field", key: 101)
        let oldParent = Node(type: "Group", id: "old-parent", role: "AXGroup", key: 102, children: [field],
            frame: .init(x: 0, y: 0, width: 390, height: 800))
        let plan = try AgentFocusAndTypePlan(snapshot: make([oldParent]), ref: "e3", context: context(), pid: 1234)
        var focused = field; focused.focused = true; focused.frame.y = 80
        let newParent = Node(type: "Group", id: "new-parent", role: "AXGroup", key: 103, children: [focused],
            frame: .init(x: 0, y: 0, width: 390, height: 800))
        let keyboard = Node(type: "Button", id: "keyboard", role: "AXButton", key: 104)
        let fresh = try make([keyboard, newParent])
        let baseline = try plan.focusedBaseline(snapshot: fresh, context: context(), pid: 1234)
        #expect(baseline.fieldTarget.semanticID == "field")
        #expect(try baseline.focusedReference(snapshot: fresh, context: context(), pid: 1234) == "e4")
        #expect(try fresh.node(ref: "e4", requiredAction: .typeText).nativeIdentity?.objectID == 101)
    }

    @Test("The tap can change value, but the exact post-focus baseline cannot change before typing")
    func postFocusValueBaseline() throws {
        var field = Node(id: "field", value: "Before", key: 101)
        let plan = try AgentFocusAndTypePlan(snapshot: make([field]), ref: "e2", context: context(), pid: 1234)
        field.focused = true; field.value = "After focus"
        let focused = try make([field])
        let baseline = try plan.focusedBaseline(snapshot: focused, context: context(), pid: 1234)
        #expect(try baseline.focusedReference(snapshot: focused, context: context(), pid: 1234) == "e2")
        field.value = "Changed before keys"
        #expect(throws: (any Error).self) {
            _ = try baseline.focusedReference(snapshot: make([field]), context: context(), pid: 1234)
        }
    }

    @Test("Anonymous fields keep one native keyboard authority with exact UInt64 identity")
    func anonymousAuthority() throws {
        let key: UInt64 = 9_007_199_254_740_993
        let field = Node(id: nil, key: key)
        let plan = try AgentFocusAndTypePlan(snapshot: make([field]), ref: "e2", context: context(), pid: 1234)
        #expect(plan.fieldTarget.nativeIdentity?.objectID == key)
        var focused = field; focused.focused = true
        _ = try plan.focusedBaseline(snapshot: make([focused]), context: context(), pid: 1234)
        focused.key = key + 1
        #expect(throws: (any Error).self) {
            _ = try plan.focusedBaseline(snapshot: make([focused]), context: context(), pid: 1234)
        }
    }

    @Test("Unavailable state, label-only fields and tap-only aliases cannot authorize typing",
          arguments: ["role", "disabled", "hidden", "missingFocus", "outside", "negativeWidth", "duplicateID", "labelOnly", "alias", "incomplete"])
    func invalidInitialField(variant: String) throws {
        var field = Node(id: "field", key: 101)
        var nodes: [Node] = []
        var complete = true
        switch variant {
        case "role": field.type = "Button"
        case "disabled": field.enabled = false
        case "hidden": field.hidden = true
        case "missingFocus": field.focused = nil
        case "outside": field.frame.y = 790
        case "negativeWidth": field.frame.width = -20
        case "duplicateID": nodes.append(Node(id: "field", label: "Other", key: 102))
        case "labelOnly": field.id = " bad "
        case "alias": field.id = nil; nodes.append(field)
        default: field.id = nil; complete = false
        }
        nodes.insert(field, at: 0)
        #expect(throws: (any Error).self) {
            _ = try AgentFocusAndTypePlan(snapshot: make(nodes, complete: complete), ref: "e2", context: context(), pid: 1234)
        }
    }

    @Test("Post-focus identity, owner, focus and state changes stop typing",
          arguments: ["key", "id", "label", "role", "pid", "focus", "hidden", "disabled", "missingKey", "duplicateKey", "duplicateID"])
    func changedFieldRefuses(variant: String) throws {
        let initial = Node(id: "field", key: 101)
        let plan = try AgentFocusAndTypePlan(snapshot: make([initial]), ref: "e2", context: context(), pid: 1234)
        var changed = initial; changed.focused = true
        var extra: [Node] = []
        switch variant {
        case "key": changed.key = 103
        case "id": changed.id = "replacement"
        case "label": changed.label = "Changed"
        case "role": changed.role = "AXButton"
        case "pid": changed.pid = 9999
        case "focus": changed.focused = false
        case "hidden": changed.hidden = true
        case "disabled": changed.enabled = false
        case "missingKey": changed.key = nil
        case "duplicateKey": extra.append(Node(type: "Button", id: "another", key: 101))
        default: extra.append(Node(id: "field", key: 104))
        }
        #expect(throws: (any Error).self) {
            _ = try plan.focusedBaseline(snapshot: make([changed] + extra), context: context(), pid: 1234)
        }
    }

    @Test("Semantic fields without optional UID keep the existing identity boundary")
    func semanticCompatibility() throws {
        var field = Node(id: "field", key: nil)
        let plan = try AgentFocusAndTypePlan(snapshot: make([field], complete: false), ref: "e2", context: context(), pid: 1234)
        #expect(plan.fieldTarget.semanticID == "field")
        field.focused = true
        _ = try plan.focusedBaseline(snapshot: make([field], complete: false), context: context(), pid: 1234)
    }

    @Test("App, boot, display, geometry, rotation and hinge stay bound")
    func changedContextRefuses() throws {
        var field = Node(id: "field", key: 101)
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
        let field = Node(id: "field", key: 101)
        let before = try make([field])
        #expect(before.hasNativeOwner(1234))
        #expect(!before.hasNativeOwner(9999) && !before.hasNativeOwner(0))
        let plan = try AgentFocusAndTypePlan(snapshot: before, ref: "e2", context: context(), pid: 1234)
        var focused = field
        focused.focused = true
        let ownRoot = Node(type: "Application", id: "app", key: 1, children: [focused],
            frame: .init(x: 0, y: 0, width: 390, height: 800))
        var otherRoot = Node(type: "Application", id: "other-app", pid: 9999, key: 2,
            frame: .init(x: 0, y: 0, width: 390, height: 800))
        let roots: [Node]
        switch variant {
        case "otherRoot":
            otherRoot.children = [focused]
            roots = [otherRoot]
        case "mixedRoots": roots = [ownRoot, otherRoot]
        case "nonpositiveRoot":
            otherRoot.pid = 0
            otherRoot.key = nil
            otherRoot.children = [focused]
            roots = [otherRoot]
        default: roots = []
        }
        let nodes = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode(roots))
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
        try JSONDecoder().decode(SelectedHIDContext.self, from: Data("""
        {"bootIdentity":"\(boot)","screenID":\(screen),"screenUUID":"DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0",
        "logicalWidth":\(width),"logicalHeight":800,"rotationDegrees":\(rotation),"nativePixelWidth":1170,
        "nativePixelHeight":2400,"scale":3,"poseRevision":"\(pose)"}
        """.utf8))
    }
    private func make(_ children: [Node], complete: Bool = true,
                      context selectedContext: SelectedHIDContext? = nil) throws -> AgentModeSnapshot {
        let root = Node(type: "Application", id: "app", key: 1, children: children,
            frame: .init(x: 0, y: 0, width: 390, height: 800))
        let nodes = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode([root]))
        return try AgentModeSnapshot(roots: nodes,
            nativeIdentityMetadata: .init(complete: complete, reason: complete ? nil : "incomplete"),
            context: try selectedContext ?? context())
    }
    private struct Node: Encodable {
        struct Frame: Encodable { var x = 10.0; var y = 200.0; var width = 200.0; var height = 44.0 }
        var type = "TextField"
        var id: String? = nil
        var label = "Field"
        var role = "AXTextField"
        var value = ""
        var focused: Bool? = false
        var pid: Int32 = 1234
        var enabled = true
        var hidden = false
        var key: UInt64? = nil
        var children: [Node] = []
        var frame = Frame()
        private enum CodingKeys: String, CodingKey {
            case type, id = "AXUniqueId", label = "AXLabel", value = "AXValue", role, focused, pid, enabled, hidden, nativeIdentity, children, frame
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(type, forKey: .type); try values.encodeIfPresent(id, forKey: .id)
            try values.encode(label, forKey: .label); try values.encode(value, forKey: .value)
            try values.encode(role, forKey: .role); try values.encodeIfPresent(focused, forKey: .focused)
            try values.encode(pid, forKey: .pid); try values.encode(enabled, forKey: .enabled)
            try values.encode(hidden, forKey: .hidden); try values.encode(children, forKey: .children)
            try values.encode(frame, forKey: .frame)
            if let key { try values.encode(FBSimulatorAXNativeIdentity(pid: pid, objectID: key), forKey: .nativeIdentity) }
        }
    }
}
