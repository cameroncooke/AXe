import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Agent reference batches")
struct AgentBatchReferencePlanTests {
    @Test("Existing ID-only documents retain their contract")
    func nativeIDDocument() throws {
        let request = try decode(#"{"steps":[{"action":"tap","id":"clear"},{"action":"type","id":"field","text":"London"}]}"#)
        try request.validate()
        #expect(!request.usesReferences && request.snapshotID == nil)
        #expect(request.steps[0].id == "clear" && request.steps[0].ref == nil)
        #expect(request.steps[1].text == "London")
    }

    @Test("Reference documents require one table and cannot mix target contracts")
    func referenceDocumentValidation() throws {
        let valid = try decode(document(#"[{"action":"tap","ref":"e2"}]"#))
        try valid.validate()
        #expect(valid.usesReferences && valid.snapshotID == table)
        for json in [
            #"{"steps":[{"action":"tap","ref":"e2"}]}"#,
            document(#"[{"action":"tap","id":"clear"}]"#),
            document(#"[{"action":"tap","id":"clear"},{"action":"tap","ref":"e2"}]"#),
            document(#"[{"action":"tap","id":"clear","ref":"e2"}]"#),
            document(#"[{"action":"tap"}]"#),
            document(#"[{"action":"tap","ref":"e0"}]"#),
            document(#"[{"action":"tap","ref":"e-1"}]"#),
            document(#"[{"action":"tap","ref":"e１"}]"#),
            document(#"[{"action":"tap","ref":"e2","text":"unexpected"}]"#),
            document(#"[{"action":"type","ref":"e2"}]"#),
            document(#"[{"action":"tap","ref":"e2","x":10}]"#),
            #"{"snapshotID":"bad-uuid","steps":[{"action":"tap","ref":"e2"}]}"#,
        ] {
            #expect(throws: (any Error).self) { try decode(json).validate() }
        }
    }

    @Test("All refs and actions are checked before a plan can authorize input")
    func planPrevalidation() throws {
        let snapshot = try snapshot(controls())
        for steps in [
            #"[{"action":"tap","ref":"e2"},{"action":"tap","ref":"e999"}]"#,
            #"[{"action":"tap","ref":"e2"},{"action":"type","ref":"e3","text":"x"}]"#,
            #"[{"action":"tap","ref":"e4"}]"#,
        ] {
            #expect(throws: (any Error).self) { try plan(steps, snapshot: snapshot) }
        }
        #expect(throws: (any Error).self) {
            try AgentBatchReferencePlan(request: decode(document(#"[{"action":"tap","ref":"e2"}]"#)),
                snapshotID: UUID(), snapshot: snapshot, context: context(), pid: 1234)
        }
    }

    @Test("Unique typed labels authorize buttons without native IDs")
    func labelOnlyTargets() throws {
        let snapshot = try snapshot(controls())
        let plan = try plan(#"[{"action":"tap","ref":"e2"},{"action":"tap","ref":"e3"}]"#,
            snapshot: snapshot)
        let resolved = try plan.resolve(index: 0, snapshot: snapshot, context: context(), pid: 1234)
        #expect(resolved.selectorKind == .label && resolved.selectorValue == "Clear")
        #expect(resolved.node.type == "Button" && resolved.node.identifier == nil)
    }

    @Test("Ambiguous labels and unavailable controls fail plan construction")
    func invalidNativeIdentity() throws {
        var duplicate = controls()
        duplicate[1].label = "Clear"
        #expect(throws: (any Error).self) {
            try plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot(duplicate))
        }
        var disabled = controls()
        disabled[0].enabled = false
        #expect(throws: (any Error).self) {
            try plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot(disabled))
        }
    }

    @Test("Normal text results and switch values can change without moving controls")
    func stateChangesKeepBoundLayout() throws {
        let original = try snapshot(controls())
        let plan = try plan(#"[{"action":"tap","ref":"e2"},{"action":"tap","ref":"e3"},{"action":"tap","ref":"e5"}]"#,
            snapshot: original)
        var changed = controls()
        changed[2].label = "77"
        changed[3].value = "0"
        let fresh = try snapshot(changed)
        #expect(original.nativeFingerprint != fresh.nativeFingerprint)
        #expect(try plan.resolve(index: 1, snapshot: fresh, context: context(), pid: 1234).selectorValue == "7")
        #expect(try plan.resolve(index: 2, snapshot: fresh, context: context(), pid: 1234).selectorValue == "Animations")
    }

    @Test("Calculator result glyphs can resize while fresh native input evidence remains exact")
    func resultGlyphBoundsCanChange() throws {
        var zero = controls()
        zero[2].frame = .init(x: 344, y: 250.5, width: 34, height: 67)
        let original = try snapshot(zero)
        let plan = try plan(#"[{"action":"tap","ref":"e2"},{"action":"tap","ref":"e3"}]"#,
            snapshot: original)
        var five = zero
        five[2].label = "5"
        five[2].frame.x = 345
        five[2].frame.width = 33
        let fresh = try snapshot(five)
        let target = try plan.resolve(index: 1, snapshot: fresh, context: context(), pid: 1234)
        #expect(target.node.label == "7" && target.node.frame == original.nodes[2].frame)
        #expect(original.nativeFingerprint != fresh.nativeFingerprint)

        let admission = AgentModeAdmission(context: try context(), expectedPID: 1234,
            screenHash: fresh.hash, nativeFingerprint: fresh.nativeFingerprint, visibleFingerprint: fresh.visibleFingerprint,
            target: try AgentModeTarget(target.node))
        try admission.validateScreen([fresh.nodes[0]])
        #expect(throws: (any Error).self) { try admission.validateScreen([original.nodes[0]]) }
    }

    @Test("Container and control descendant frames remain bound")
    func protectedGeometryCannotChange() throws {
        let group = Node(type: "Group", label: "Controls", children: controls())
        let grouped = try snapshot([group])
        let groupPlan = try plan(#"[{"action":"tap","ref":"e3"}]"#, snapshot: grouped)
        var movedGroup = group
        movedGroup.frame.x += 1
        #expect(throws: (any Error).self) {
            try groupPlan.resolve(index: 0, snapshot: snapshot([movedGroup]), context: context(), pid: 1234)
        }

        var buttonNodes = controls()
        buttonNodes[1].children = [Node(type: "StaticText", label: "7")]
        let buttonPlan = try self.plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot(buttonNodes))
        buttonNodes[1].children[0].frame.x += 1
        #expect(throws: (any Error).self) {
            try buttonPlan.resolve(index: 0, snapshot: snapshot(buttonNodes), context: context(), pid: 1234)
        }
    }

    @Test("Fresh resolution follows identity after sibling order changes")
    func noStoredOrdinalAuthority() throws {
        let plan = try plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot(controls()))
        let fresh = try snapshot(Array(controls().reversed()))
        let resolved = try plan.resolve(index: 0, snapshot: fresh, context: context(), pid: 1234)
        #expect(resolved.node.label == "Clear")
        #expect(fresh.elements[1].label == "Animations")
    }

    @Test("Typing retains a unique focused field ID and rejects new keyboard layout")
    func typingUsesNativeFocusIdentity() throws {
        var field = Node(type: "TextField", label: "Search", identifier: "field")
        field.focused = true
        let original = try snapshot([field, Node(type: "StaticText", label: "Search", identifier: "field")])
        let plan = try plan(#"[{"action":"type","ref":"e2","text":"London"}]"#, snapshot: original)
        field.value = "London"
        let changed = try snapshot([field, Node(type: "StaticText", label: "Search", identifier: "field")])
        let resolved = try plan.resolve(index: 0, snapshot: changed, context: context(), pid: 1234)
        #expect(resolved.selectorKind == .id && resolved.selectorValue == "field")
        let keyboard = try snapshot([field, Node(type: "Button", label: "A", frame: .init(y: 700))])
        #expect(throws: (any Error).self) {
            try plan.resolve(index: 0, snapshot: keyboard, context: context(), pid: 1234)
        }
        #expect(throws: (any Error).self) {
            try self.plan(#"[{"action":"type","ref":"e2","text":"London"}]"#,
                snapshot: snapshot([field, field]))
        }
    }

    @Test("Changed labels, layout, overlays and control state stop later input")
    func layoutChangesReject() throws {
        let plan = try plan(#"[{"action":"tap","ref":"e2"},{"action":"tap","ref":"e3"}]"#,
            snapshot: snapshot(controls()))
        var variants: [[Node]] = []
        var changed = controls(); changed[1].label = "8"; variants.append(changed)
        changed = controls(); changed[1].frame.x += 1; variants.append(changed)
        changed = controls(); changed[1].hidden = true; variants.append(changed)
        changed = controls(); changed[1].enabled = false; variants.append(changed)
        changed = controls(); changed[1].focused = true; variants.append(changed)
        changed = controls(); changed.append(Node(type: "Button", label: "Overlay")); variants.append(changed)
        changed = controls(); let movedChild = changed.removeLast()
        changed[0].children = [movedChild]; variants.append(changed)
        for nodes in variants {
            #expect(throws: (any Error).self) {
                try plan.resolve(index: 1, snapshot: snapshot(nodes), context: context(), pid: 1234)
            }
        }
    }

    @Test("Inert, hidden and off-display additions do not stop later input")
    func inertAdditionsKeepTheLayout() throws {
        let plan = try plan(#"[{"action":"tap","ref":"e2"},{"action":"tap","ref":"e3"}]"#,
            snapshot: snapshot(controls()))
        var variants: [[Node]] = []
        var changed = controls(); changed.append(Node(type: "Group", label: "", frame: .init(x: 8, y: 370, width: 300, height: 400))); variants.append(changed)
        changed = controls(); changed.append(Node(type: "Button", label: "Hidden", frame: .init(x: 10, y: 300), hidden: true)); variants.append(changed)
        changed = controls(); changed.append(Node(type: "Button", label: "Below", frame: .init(x: 10, y: 2000))); variants.append(changed)
        for nodes in variants {
            _ = try plan.resolve(index: 1, snapshot: snapshot(nodes), context: context(), pid: 1234)
        }
    }

    @Test("Text container labels remain identity evidence")
    func ordinaryTextExceptionIsNarrow() throws {
        var original = controls()
        original[2].children = [Node(type: "StaticText", label: "child")]
        let plan = try plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot(original))
        var changed = original
        changed[2].label = "new container label"
        #expect(throws: (any Error).self) {
            try plan.resolve(index: 0, snapshot: snapshot(changed), context: context(), pid: 1234)
        }

        var buttonNodes = controls()
        buttonNodes[1].children = [Node(type: "StaticText", label: "7")]
        let buttonPlan = try self.plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot(buttonNodes))
        buttonNodes[1].children[0].label = "8"
        #expect(throws: (any Error).self) {
            try buttonPlan.resolve(index: 0, snapshot: snapshot(buttonNodes), context: context(), pid: 1234)
        }
    }

    @Test("Process, display, boot, hinge and rotation remain bound")
    func deviceContextRejects() throws {
        let snapshot = try snapshot(controls())
        let plan = try plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot)
        #expect(throws: (any Error).self) {
            try plan.resolve(index: 0, snapshot: snapshot, context: context(), pid: 4321)
        }
        for changed in [try context(boot: "changed"), try context(screenID: 2),
                        try context(rotation: 90), try context(pose: "mechanicalDegrees=90")] {
            #expect(throws: (any Error).self) {
                try plan.resolve(index: 0, snapshot: snapshot, context: changed, pid: 1234)
            }
        }
    }

    private let table = UUID(uuidString: "3FF70D78-26DA-4314-B37B-4CB57D2A1A85")!

    private func document(_ steps: String) -> String {
        "{\"snapshotID\":\"\(table.uuidString)\",\"steps\":\(steps)}"
    }

    private func decode(_ json: String) throws -> AgentBatchRequest {
        let document = try JSONDecoder().decode(AgentBatchDocument.self, from: Data(json.utf8))
        return AgentBatchRequest(expectedPID: nil, snapshotID: document.snapshotID, steps: document.steps)
    }

    private func plan(_ steps: String, snapshot: AgentModeSnapshot) throws -> AgentBatchReferencePlan {
        try AgentBatchReferencePlan(request: decode(document(steps)), snapshotID: table,
            snapshot: snapshot, context: context(), pid: 1234)
    }

    private func snapshot(_ controls: [Node]) throws -> AgentModeSnapshot {
        let roots = [Node(type: "Application", label: "Example", frame: .init(width: 390, height: 844), children: controls)]
        let native = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode(roots))
        return try AgentModeSnapshot(roots: native, context: context())
    }

    private func context(boot: String = "1:2:3", screenID: Int = 1, rotation: Int = 0,
                         pose: String = "mechanicalDegrees=180") throws -> SelectedHIDContext {
        try JSONDecoder().decode(SelectedHIDContext.self, from: Data("""
        {"bootIdentity":"\(boot)","screenID":\(screenID),"screenUUID":"DF1FB281-4CCC-4A62-88D3-635D18FAD832",
         "logicalWidth":390,"logicalHeight":844,"rotationDegrees":\(rotation),
         "nativePixelWidth":1170,"nativePixelHeight":2532,"scale":3,"poseRevision":"\(pose)"}
        """.utf8))
    }

    private func controls() -> [Node] {
        [Node(type: "Button", label: "Clear", frame: .init(x: 10)),
         Node(type: "Button", label: "7", frame: .init(x: 110)),
         Node(type: "StaticText", label: "0", frame: .init(x: 210)),
         Node(type: "Switch", label: "Animations", value: "1", frame: .init(x: 10, y: 100))]
    }

    private struct Node: Encodable {
        struct Frame: Encodable {
            var x = 0.0
            var y = 0.0
            var width = 80.0
            var height = 44.0
        }
        let type: String
        var label: String
        var identifier: String? = nil
        var value: String? = nil
        var frame = Frame()
        var children: [Node] = []
        let pid: Int32 = 1234
        var focused = false
        var enabled = true
        var hidden = false
        private enum CodingKeys: String, CodingKey {
            case type, label = "AXLabel", identifier = "AXUniqueId", value = "AXValue"
            case frame, children, pid, focused, enabled, hidden
        }
    }
}
