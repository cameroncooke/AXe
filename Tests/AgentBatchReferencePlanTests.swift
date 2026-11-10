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
        changed[3].value = .string("0")
        let fresh = try snapshot(changed)
        #expect(original.nativeFingerprint != fresh.nativeFingerprint)
        #expect(try plan.resolve(index: 1, snapshot: fresh, context: context(), pid: 1234).selectorValue == "7")
        #expect(try plan.resolve(index: 2, snapshot: fresh, context: context(), pid: 1234).selectorValue == "Animations")
    }

    @Test("Calculator result glyphs can resize while fresh native input evidence remains exact")
    func resultGlyphBoundsCanChange() throws {
        var zero = controls()
        zero[2].frame = frame(x: 344, y: 250.5, width: 34, height: 67)
        let original = try snapshot(zero)
        let plan = try plan(#"[{"action":"tap","ref":"e2"},{"action":"tap","ref":"e3"}]"#,
            snapshot: original)
        var five = zero
        five[2].label = "5"
        five[2].frame?.x = 345
        five[2].frame?.width = 33
        let fresh = try snapshot(five)
        let target = try plan.resolve(index: 1, snapshot: fresh, context: context(), pid: 1234)
        #expect(target.node.label == "7" && target.node.frame == original.nodes[2].frame)
        #expect(original.nativeFingerprint != fresh.nativeFingerprint)

        let admission = AgentModeAdmission(context: try context(), expectedPID: 1234,
            visibleFingerprint: fresh.visibleFingerprint,
            target: try AgentModeTarget(target.node))
        try admission.validateScreen([fresh.nodes[0]])
        // Single-action admission uses the same rule: the result text is ordinary text.
        try admission.validateScreen([original.nodes[0]])
    }

    @Test("Container and control descendant frames remain bound")
    func protectedGeometryCannotChange() throws {
        let group = node(type: "Group", label: "Controls", children: controls())
        let grouped = try snapshot([group])
        let groupPlan = try plan(#"[{"action":"tap","ref":"e3"}]"#, snapshot: grouped)
        var movedGroup = group
        movedGroup.frame?.x += 1
        #expect(throws: (any Error).self) {
            try groupPlan.resolve(index: 0, snapshot: snapshot([movedGroup]), context: context(), pid: 1234)
        }

        var buttonNodes = controls()
        buttonNodes[1].children = [node(type: "StaticText", label: "7")]
        let buttonPlan = try self.plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot(buttonNodes))
        buttonNodes[1].children?[0].frame?.x += 1
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
        var field = node(type: "TextField", label: "Search", identifier: "field")
        field.focused = true
        let original = try snapshot([field, node(type: "StaticText", label: "Search", identifier: "field")])
        let plan = try plan(#"[{"action":"type","ref":"e2","text":"London"}]"#, snapshot: original)
        field.value = .string("London")
        let changed = try snapshot([field, node(type: "StaticText", label: "Search", identifier: "field")])
        let resolved = try plan.resolve(index: 0, snapshot: changed, context: context(), pid: 1234)
        #expect(resolved.selectorKind == .id && resolved.selectorValue == "field")
        let keyboard = try snapshot([field, node(type: "Button", label: "A", frame: frame(y: 700))])
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
        var variants: [[AXNodeFixture]] = []
        var changed = controls(); changed[1].label = "8"; variants.append(changed)
        changed = controls(); changed[1].frame?.x += 1; variants.append(changed)
        changed = controls(); changed[1].hidden = true; variants.append(changed)
        changed = controls(); changed[1].enabled = false; variants.append(changed)
        changed = controls(); changed[1].focused = true; variants.append(changed)
        changed = controls(); changed.append(node(type: "Button", label: "Overlay")); variants.append(changed)
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
        var variants: [[AXNodeFixture]] = []
        var changed = controls(); changed.append(node(type: "Group", label: "", frame: frame(x: 8, y: 370, width: 300, height: 400))); variants.append(changed)
        changed = controls(); changed.append(node(type: "Button", label: "Hidden", frame: frame(x: 10, y: 300), hidden: true)); variants.append(changed)
        changed = controls(); changed.append(node(type: "Button", label: "Below", frame: frame(x: 10, y: 2000))); variants.append(changed)
        for nodes in variants {
            _ = try plan.resolve(index: 1, snapshot: snapshot(nodes), context: context(), pid: 1234)
        }
    }

    @Test("Text container labels remain identity evidence")
    func ordinaryTextExceptionIsNarrow() throws {
        var original = controls()
        original[2].children = [node(type: "StaticText", label: "child")]
        let plan = try plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot(original))
        var changed = original
        changed[2].label = "new container label"
        #expect(throws: (any Error).self) {
            try plan.resolve(index: 0, snapshot: snapshot(changed), context: context(), pid: 1234)
        }

        var buttonNodes = controls()
        buttonNodes[1].children = [node(type: "StaticText", label: "7")]
        let buttonPlan = try self.plan(#"[{"action":"tap","ref":"e2"}]"#, snapshot: snapshot(buttonNodes))
        buttonNodes[1].children?[0].label = "8"
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

    @Test("Focus type steps are type-only and keep their flag on a new table")
    func focusStepDocument() throws {
        let request = try decode(document(#"[{"action":"type","ref":"e2","text":"MCP","focus":true}]"#))
        try request.validate()
        #expect(request.steps[0].focus == true)
        #expect(try request.steps[0].replacingReference("e7").focus == true)
        let plain = try decode(document(#"[{"action":"type","ref":"e2","text":"MCP"}]"#))
        #expect(plain.steps[0].focus == nil)
        #expect(try plain.steps[0].replacingReference("e7").focus == nil)
        try decode(#"{"steps":[{"action":"type","id":"first","text":"MCP","focus":true}]}"#).validate()
        for json in [document(#"[{"action":"tap","ref":"e2","focus":true}]"#),
                     document(#"[{"action":"type","ref":"e2","text":"x","focus":"yes"}]"#)] {
            #expect(throws: (any Error).self) { try decode(json).validate() }
        }
    }

    @Test("A focus step needs a tap-capable field identity, not existing focus")
    func focusStepPlan() throws {
        let snapshot = try snapshot(form())
        _ = try plan(#"[{"action":"type","ref":"e2","text":"MCP","focus":true},{"action":"type","ref":"e3","text":"B","focus":true},{"action":"tap","ref":"e4"}]"#,
            snapshot: snapshot)
        // Without focus, a type step still needs a field that is focused already.
        #expect(throws: (any Error).self) {
            try plan(#"[{"action":"type","ref":"e2","text":"MCP"}]"#, snapshot: snapshot)
        }
        // A button is not a field.
        #expect(throws: (any Error).self) {
            try plan(#"[{"action":"type","ref":"e4","text":"x","focus":true}]"#, snapshot: snapshot)
        }
        let target = try plan(#"[{"action":"type","ref":"e3","text":"B","focus":true}]"#, snapshot: snapshot)
            .resolve(index: 0, snapshot: snapshot, context: context(), pid: 1234)
        #expect(target.node.identifier == "last" && target.selectorKind == .id)
    }

    @Test("A completed focus step rebases later targets that only moved")
    func focusStepRebasesMovedTargets() throws {
        let plan = try plan(#"[{"action":"type","ref":"e2","text":"MCP","focus":true},{"action":"type","ref":"e3","text":"B","focus":true},{"action":"tap","ref":"e4"}]"#,
            snapshot: snapshot(form()))
        // The keyboard appears, the form scrolls up and the first field holds its text.
        var moved = form()
        moved[0].value = .string("MCP"); moved[0].focused = true
        moved[0].frame?.y -= 60; moved[1].frame?.y -= 60
        let keyboard = moved + [node(type: "Button", label: "return", frame: frame(x: 300, y: 760))]
        let after = try snapshot(keyboard)
        // Without the rebase, the original layout no longer admits the later tap.
        #expect(throws: (any Error).self) {
            try plan.resolve(index: 2, snapshot: after, context: context(), pid: 1234)
        }
        let rebased = try plan.rebased(afterFocusStep: 0, snapshot: after, context: context(), pid: 1234)
        let field = try rebased.resolve(index: 1, snapshot: after, context: context(), pid: 1234)
        #expect(field.node.identifier == "last" && field.node.frame?.minY == 160)
        #expect(try rebased.resolve(index: 2, snapshot: after, context: context(), pid: 1234).node.label == "Done")
        // Layout immutability resumes from the new baseline.
        var shifted = keyboard
        shifted[2].frame?.x += 1
        #expect(throws: (any Error).self) {
            try rebased.resolve(index: 2, snapshot: snapshot(shifted), context: context(), pid: 1234)
        }
    }

    @Test("A rebase refuses later targets whose identity, value or availability changed")
    func focusRebaseRejectsChangedTargets() throws {
        let tapPlan = try plan(#"[{"action":"type","ref":"e2","text":"MCP","focus":true},{"action":"tap","ref":"e4"}]"#,
            snapshot: snapshot(form()))
        var variants: [[AXNodeFixture]] = []
        var changed = form(); changed[2].label = "Cancel"; variants.append(changed)
        changed = form(); changed[2].enabled = false; variants.append(changed)
        changed = form(); changed[2].hidden = true; variants.append(changed)
        changed = form(); changed.append(node(type: "Button", label: "Done", frame: frame(x: 200, y: 40))); variants.append(changed)
        changed = form(); changed[2].frame?.y = 2000; variants.append(changed)
        for nodes in variants {
            #expect(throws: (any Error).self) {
                try tapPlan.rebased(afterFocusStep: 0, snapshot: snapshot(nodes), context: context(), pid: 1234)
            }
        }
        #expect(throws: (any Error).self) {
            try tapPlan.rebased(afterFocusStep: 0, snapshot: snapshot(form()), context: context(rotation: 90), pid: 1234)
        }
        // A later field whose value changed is a changed state, not a moved control.
        let fieldPlan = try plan(#"[{"action":"type","ref":"e2","text":"MCP","focus":true},{"action":"type","ref":"e3","text":"B","focus":true}]"#,
            snapshot: snapshot(form()))
        changed = form(); changed[1].value = .string("autocorrected")
        #expect(throws: (any Error).self) {
            try fieldPlan.rebased(afterFocusStep: 0, snapshot: snapshot(changed), context: context(), pid: 1234)
        }
    }

    @Test("A focus step finds its field by identity after earlier typing changed the layout")
    func focusStepAfterEarlierTyping() throws {
        var fields = form()
        fields[0].focused = true
        let plan = try plan(#"[{"action":"type","ref":"e2","text":"MCP"},{"action":"type","ref":"e3","text":"B","focus":true}]"#,
            snapshot: snapshot(fields))
        // Typing filled the first field, moved the form and changed the keyboard's suggestions.
        var typed = fields
        typed[0].value = .string("MCP")
        typed[1].frame?.y -= 20
        let suggestions = typed + [node(type: "Button", label: "“MCP”", frame: frame(x: 10, y: 700))]
        let fresh = try snapshot(suggestions)
        #expect(try plan.resolve(index: 1, snapshot: fresh, context: context(), pid: 1234).node.identifier == "last")
        var renamed = suggestions
        renamed[1].label = "Surname"
        #expect(throws: (any Error).self) {
            try plan.resolve(index: 1, snapshot: snapshot(renamed), context: context(), pid: 1234)
        }
        var autocorrected = suggestions
        autocorrected[1].value = .string("changed")
        #expect(throws: (any Error).self) {
            try plan.resolve(index: 1, snapshot: snapshot(autocorrected), context: context(), pid: 1234)
        }
    }

    @Test("A rebase refuses a different native field that reuses a later target's ID")
    func focusRebaseRejectsReplacementField() throws {
        var fields = form()
        fields[1].nativeIdentity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: 202)
        let plan = try plan(#"[{"action":"type","ref":"e2","text":"MCP","focus":true},{"action":"type","ref":"e3","text":"B","focus":true}]"#,
            snapshot: snapshot(fields, complete: true))
        var same = fields
        same[1].frame?.y -= 60
        _ = try plan.rebased(afterFocusStep: 0, snapshot: snapshot(same, complete: true), context: context(), pid: 1234)
        var replaced = same
        replaced[1].nativeIdentity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: 303)
        #expect(throws: (any Error).self) {
            try plan.rebased(afterFocusStep: 0, snapshot: snapshot(replaced, complete: true), context: context(), pid: 1234)
        }
    }

    @Test("Anonymous fields keep their native identity while focus moves between them")
    func focusRebaseFollowsAnonymousFields() throws {
        // No ID and a shared label: only native identity can tell these fields apart.
        var fields = form()
        fields[0].identifier = nil; fields[0].label = "Name"
        fields[0].nativeIdentity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: 101)
        fields[1].identifier = nil; fields[1].label = "Name"
        fields[1].nativeIdentity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: 102)
        fields[1].focused = true
        let plan = try plan(#"[{"action":"type","ref":"e2","text":"MCP","focus":true},{"action":"type","ref":"e3","text":"B","focus":true}]"#,
            snapshot: snapshot(fields, complete: true))
        // Step one's field takes focus and text; step two's field loses focus; both move.
        var after = fields
        after[0].focused = true; after[0].value = .string("MCP"); after[0].frame?.y -= 60
        after[1].focused = false; after[1].frame?.y -= 60
        let fresh = try snapshot(after, complete: true)
        let rebased = try plan.rebased(afterFocusStep: 0, snapshot: fresh, context: context(), pid: 1234)
        let target = try rebased.resolve(index: 1, snapshot: fresh, context: context(), pid: 1234)
        #expect(target.node.nativeIdentity?.objectID == 102)
    }

    private func form() -> [AXNodeFixture] {
        [node(type: "TextField", label: "First name", identifier: "first", frame: frame(x: 20, y: 160, width: 300), role: "AXTextField"),
         node(type: "TextField", label: "Last name", identifier: "last", frame: frame(x: 20, y: 220, width: 300), role: "AXTextField"),
         node(type: "Button", label: "Done", frame: frame(x: 300, y: 40))]
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

    private func snapshot(_ controls: [AXNodeFixture], complete: Bool = false) throws -> AgentModeSnapshot {
        let roots = [node(type: "Application", label: "Example", frame: frame(width: 390, height: 844), children: controls)]
        guard complete else { return try AgentModeSnapshot(roots: AXNodeFixture.decode(roots), context: context()) }
        // A complete identity read reports the root and every control, as the native reader does.
        var identified = roots
        identified[0].nativeIdentity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: 1)
        for index in controls.indices where controls[index].nativeIdentity == nil {
            identified[0].children?[index].nativeIdentity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: UInt64(900 + index))
        }
        return try AgentModeSnapshot(roots: AXNodeFixture.decode(identified),
            nativeIdentityMetadata: .init(complete: true, reason: nil), context: context())
    }

    private func context(boot: String = "1:2:3", screenID: Int = 1, rotation: Int = 0,
                         pose: String = "mechanicalDegrees=180") throws -> SelectedHIDContext {
        try .fixture(boot: boot, screenID: screenID, screenUUID: "DF1FB281-4CCC-4A62-88D3-635D18FAD832",
            width: 390, height: 844, rotation: rotation, pixelWidth: 1170, pixelHeight: 2532, pose: pose)
    }

    private func controls() -> [AXNodeFixture] {
        [node(type: "Button", label: "Clear", frame: frame(x: 10)),
         node(type: "Button", label: "7", frame: frame(x: 110)),
         node(type: "StaticText", label: "0", frame: frame(x: 210)),
         node(type: "Switch", label: "Animations", value: "1", frame: frame(x: 10, y: 100))]
    }
}

private func frame(x: Double = 0, y: Double = 0, width: Double = 80, height: Double = 44) -> AXNodeFixture.Frame {
    .init(x: x, y: y, width: width, height: height)
}

private func node(type: String, label: String, identifier: String? = nil, value: String? = nil,
                  frame: AXNodeFixture.Frame = frame(), role: String? = nil, hidden: Bool = false,
                  children: [AXNodeFixture] = []) -> AXNodeFixture {
    AXNodeFixture(type: type, identifier: identifier, label: label, value: value.map { .string($0) }, role: role,
        frame: frame, pid: 1234, focused: false, enabled: true, hidden: hidden, children: children)
}
