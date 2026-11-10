import AXeCore
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Anonymous native keyboard, batch and path authority")
struct AnonymousNativeInputPolicyTests {
    private let viewport = CGSize(width: 402, height: 874)
    private let key = FBSimulatorAXNativeIdentity(pid: 1234, objectID: 12001969888172651012)

    @Test("Private native keys retain exact UInt64 values and reject noncanonical wire values")
    func exactIntegerContract() throws {
        for value in [UInt64(1), UInt64(9007199254740993), UInt64.max] {
            let identity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: value)
            let bytes = try JSONEncoder().encode(identity)
            let text = try #require(String(data: bytes, encoding: .utf8))
            #expect(text.contains("\"objectID\":\"\(value)\""))
            #expect(try JSONDecoder().decode(FBSimulatorAXNativeIdentity.self, from: bytes) == identity)
        }
        for encoded in ["0", "-1", "01", "+1", "1.0", "1e3", " 1", "1 ", "18446744073709551616"] {
            let bytes = Data("{\"pid\":1234,\"objectID\":\"\(encoded)\"}".utf8)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(FBSimulatorAXNativeIdentity.self, from: bytes) }
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FBSimulatorAXNativeIdentity.self,
                from: Data(#"{"pid":1234,"objectID":9007199254740993}"#.utf8))
        }
    }

    @Test("Keyboard carries one explicit field target on the wire")
    func keyboardWireHasNoFakeFocusID() throws {
        let events: [SelectedKeyboardPrimitive] = [.down(4), .up(4)]
        let semantic = SelectedKeyboardRequest(expectedPID: 1234, focusID: "field", events: events)
        let semanticBytes = try JSONEncoder().encode(semantic)
        #expect(!String(decoding: semanticBytes, as: UTF8.self).contains("focusID"))
        let restored = try JSONDecoder().decode(SelectedKeyboardRequest.self, from: semanticBytes)
        try restored.validate()
        #expect(restored.focusID == "field" && restored.fieldTarget == semantic.fieldTarget)
        let object = SelectedKeyboardRequest(expectedPID: 1234,
            fieldTarget: .nativeObject(identity: key, elementType: "TextField"), events: events)
        try object.validate()
        let bytes = try JSONEncoder().encode(object)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("focusID"))
        #expect(try JSONDecoder().decode(SelectedKeyboardRequest.self, from: bytes).fieldTarget == object.fieldTarget)
        let focusIDOnly = Data("{\"expectedPID\":1234,\"focusID\":\"field\",\"events\":[]}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SelectedKeyboardRequest.self, from: focusIDOnly) }
        for target in [SelectedNativeTarget.semantic(kind: .label, value: "Title", elementType: "TextField"),
                       .nativeObject(identity: key, elementType: "TextView"),
                       .nativeObject(identity: key, elementType: "SecureTextField"),
                       .nativeObject(identity: .init(pid: 999, objectID: key.objectID), elementType: "TextField")] {
            #expect(throws: (any Error).self) {
                try SelectedKeyboardRequest(expectedPID: 1234, fieldTarget: target, events: events).validate()
            }
        }
    }

    @Test("Anonymous typing retains key, label and ID absence while allowing owned value and frame changes")
    func ownedAnonymousEdit() throws {
        let selected = SelectedNativeTarget.nativeObject(identity: key, elementType: "TextField")
        let initial = field()
        let original = try AgentModeTarget(initial.decoded(), nativeTarget: selected)
        var changed = initial
        changed.value = .string("OpaqueIdentityProbe")
        changed.frame?.width -= 10
        #expect(throws: (any Error).self) { try edit(changed, against: original, target: selected, started: false) }
        try edit(changed, against: original, target: selected, started: true)
        var variants: [AXNodeFixture] = []
        var invalid = changed; invalid.nativeIdentity = .init(pid: 1234, objectID: key.objectID + 1); variants.append(invalid)
        invalid = changed; invalid.label = "Other title"; variants.append(invalid)
        invalid = changed; invalid.identifier = "newly.materialized.id"; variants.append(invalid)
        invalid = changed; invalid.identifier = ""; variants.append(invalid)
        invalid = changed; invalid.focused = false; variants.append(invalid)
        invalid = changed; invalid.pid = 999; variants.append(invalid)
        invalid = changed; invalid.type = "TextView"; variants.append(invalid)
        invalid = changed; invalid.hidden = true; variants.append(invalid)
        invalid = changed; invalid.enabled = false; variants.append(invalid)
        invalid = changed; invalid.frame?.x = -1; variants.append(invalid)
        for value in variants {
            #expect(throws: (any Error).self) { try edit(value, against: original, target: selected, started: true) }
        }
    }

    @Test("Existing exact-ID edits do not depend on incidental optional native metadata")
    func semanticFocusDoesNotRequireObjectMetadata() throws {
        var initial = field(); initial.identifier = "field"
        let original = try AgentModeTarget(initial.decoded())
        var current = initial; current.nativeIdentity = nil; current.value = .string("a")
        try SelectedKeyboardEditingTargetPolicy.validate(current.decoded(), against: original,
            expectedPID: 1234, focusID: "field", logicalSize: viewport, editingStarted: true)
    }

    @Test("Every original batch object is checked before the first tap, with no identity rebinding")
    func batchBindsAllOriginalKeys() throws {
        let first = node(type: "Button", nativeIdentity: .init(pid: 1234, objectID: 101))
        let second = node(type: "Button", frame: frame(x: 100), nativeIdentity: .init(pid: 1234, objectID: 102))
        let original = try snapshot([first, second])
        let plan = try batchPlan(snapshot: original)
        let resolved = try plan.resolve(index: 0, snapshot: original, context: context(), pid: 1234)
        #expect(resolved.nativeTarget.nativeIdentity == first.nativeIdentity)
        #expect(resolved.selectorKind == nil && resolved.selectorValue == nil)
        let request = try plan.tapRequest(index: 0, requestID: UUID())
        #expect(request.ax?.nativeTarget?.nativeIdentity == first.nativeIdentity)
        var replacement = second
        replacement.nativeIdentity = .init(pid: 1234, objectID: 103)
        let replaced = try snapshot([first, replacement])
        #expect(original.nativeFingerprint == replaced.nativeFingerprint)
        #expect(throws: (any Error).self) {
            try plan.resolve(index: 0, snapshot: replaced, context: context(), pid: 1234)
        }
        #expect(throws: (any Error).self) {
            try plan.resolve(index: 0, snapshot: snapshot([first, second], complete: false), context: context(), pid: 1234)
        }
        var hiddenDuplicate = second; hiddenDuplicate.hidden = true; hiddenDuplicate.type = "Group"
        #expect(throws: (any Error).self) { try batchPlan(snapshot: snapshot([first, second, hiddenDuplicate])) }
    }

    @Test("Point uniqueness counts wrong-type and hidden copies before filtering")
    func pointIdentityNeedsCompleteUniqueTree() throws {
        let hit = field()
        let native = try hit.decoded()
        let complete = try snapshot([hit])
        #expect(try AgentModePathIdentityPolicy.uniqueIndex(matching: native, in: complete, usingNativeIdentity: true) == 1)
        var duplicate = hit; duplicate.type = "Group"; duplicate.hidden = true; duplicate.focused = false
        for tree in [try snapshot([hit, duplicate]), try snapshot([hit], complete: false),
                     try snapshot([hit], complete: nil)] {
            #expect(throws: (any Error).self) {
                try AgentModePathIdentityPolicy.uniqueIndex(matching: native, in: tree, usingNativeIdentity: true)
            }
        }
        var replacement = hit; replacement.nativeIdentity = .init(pid: 1234, objectID: key.objectID + 1)
        #expect(throws: (any Error).self) {
            try AgentModePathIdentityPolicy.uniqueIndex(matching: native, in: snapshot([replacement]), usingNativeIdentity: true)
        }
        var changedPoint = hit; changedPoint.label = "changed"
        #expect(!AgentModePathIdentityPolicy.sameSignature(native, try changedPoint.decoded(), usingNativeIdentity: true))
    }

    @Test("Equal-signature anonymous scroll areas use the chosen object's actual descendants")
    func swipePlannerKeepsChosenArea() throws {
        let area = frame(x: 8, y: 370, width: 386, height: 496)
        let leftText = node(type: "StaticText", label: "Left", frame: frame(x: 60, y: 690, width: 20, height: 20),
            nativeIdentity: .init(pid: 1234, objectID: 201))
        let rightText = node(type: "StaticText", label: "Right", frame: frame(x: 300, y: 690, width: 20, height: 20),
            nativeIdentity: .init(pid: 1234, objectID: 202))
        let left = node(type: "ScrollArea", frame: area, nativeIdentity: .init(pid: 1234, objectID: 301), children: [leftText])
        let right = node(type: "ScrollArea", frame: area, nativeIdentity: .init(pid: 1234, objectID: 302), children: [rightText])
        let tree = try snapshot([left, right])
        let points = try AgentModeSwipePlanner.points(standard: (.init(x: 201, y: 705), .init(x: 201, y: 532)),
            target: right.decoded(), snapshot: tree, logicalSize: viewport,
            nativeTarget: .nativeObject(identity: #require(right.nativeIdentity), elementType: "ScrollArea"))
        #expect(points.from == AgentPoint(x: 310, y: 700))
        #expect(points.to == AgentPoint(x: 310, y: 527))
        #expect(throws: (any Error).self) {
            try AgentModeSwipePlanner.points(standard: (.init(x: 201, y: 705), .init(x: 201, y: 532)),
                target: right.decoded(), snapshot: snapshot([left, right], complete: false), logicalSize: viewport,
                nativeTarget: .nativeObject(identity: #require(right.nativeIdentity), elementType: "ScrollArea"))
        }
    }

    @Test("A current point must belong to the selected area's actual ancestor chain")
    func pointCannotTransferBetweenEqualAreas() throws {
        let area = frame(x: 8, y: 370, width: 386, height: 496)
        let hit = node(type: "StaticText", label: "Text", frame: frame(x: 60, y: 690, width: 20, height: 20),
            nativeIdentity: .init(pid: 1234, objectID: 401))
        let left = node(type: "ScrollArea", frame: area, nativeIdentity: .init(pid: 1234, objectID: 501), children: [hit])
        let right = node(type: "ScrollArea", frame: area, nativeIdentity: .init(pid: 1234, objectID: 502))
        let tree = try snapshot([left, right])
        let chain = try AgentModePathIdentityPolicy.ancestorChain(hit: hit.decoded(), area: left.decoded(),
            roots: [tree.nodes[0]], snapshot: tree, usingNativeIdentity: true)
        #expect(chain == [0, 1, 2])
        #expect(throws: (any Error).self) {
            try AgentModePathIdentityPolicy.ancestorChain(hit: hit.decoded(), area: right.decoded(),
                roots: [tree.nodes[0]], snapshot: tree, usingNativeIdentity: true)
        }
        var movedLeft = left; movedLeft.children = []
        var movedRight = right; movedRight.children = [hit]
        let moved = try snapshot([movedLeft, movedRight])
        #expect(throws: (any Error).self) {
            try AgentModePathIdentityPolicy.ancestorChain(hit: hit.decoded(), area: movedLeft.decoded(),
                roots: [moved.nodes[0]], snapshot: moved, usingNativeIdentity: true)
        }
    }

    @Test("Anonymous batch typing keeps the same object and rejects a stale published table")
    func batchTypingUsesOneChosenObject() throws {
        let fieldNode = field()
        let tree = try snapshot([fieldNode])
        let table = UUID()
        let steps = try JSONDecoder().decode([AgentBatchStep].self,
            from: Data(#"[{"action":"type","ref":"e2","text":"hello"}]"#.utf8))
        let request = AgentBatchRequest(expectedPID: nil, snapshotID: table, steps: steps)
        let plan = try AgentBatchReferencePlan(request: request, snapshotID: table,
            snapshot: tree, context: context(), pid: 1234)
        let resolved = try plan.resolve(index: 0, snapshot: tree, context: context(), pid: 1234)
        #expect(resolved.nativeTarget == .nativeObject(identity: key, elementType: "TextField"))
        #expect(throws: (any Error).self) {
            try AgentBatchReferencePlan(request: request, snapshotID: UUID(),
                snapshot: tree, context: context(), pid: 1234)
        }
        var unfocused = fieldNode; unfocused.focused = false
        #expect(throws: (any Error).self) {
            try AgentBatchReferencePlan(request: request, snapshotID: table,
                snapshot: snapshot([unfocused]), context: context(), pid: 1234)
        }
    }

    private func edit(_ field: AXNodeFixture, against original: AgentModeTarget,
                      target: SelectedNativeTarget, started: Bool) throws {
        try SelectedKeyboardEditingTargetPolicy.validate(field.decoded(), against: original,
            expectedPID: 1234, fieldTarget: target, logicalSize: viewport, editingStarted: started)
    }

    private func field() -> AXNodeFixture {
        node(type: "TextField", label: "Title", value: "", frame: frame(x: 10, y: 100, width: 300, height: 44),
            focused: true, nativeIdentity: key)
    }

    private func batchPlan(snapshot: AgentModeSnapshot) throws -> AgentBatchReferencePlan {
        let table = UUID()
        let steps = try JSONDecoder().decode([AgentBatchStep].self,
            from: Data(#"[{"action":"tap","ref":"e2"},{"action":"tap","ref":"e3"}]"#.utf8))
        return try AgentBatchReferencePlan(request: .init(expectedPID: nil, snapshotID: table, steps: steps),
            snapshotID: table, snapshot: snapshot, context: context(), pid: 1234)
    }

    private func snapshot(_ children: [AXNodeFixture], complete: Bool? = true) throws -> AgentModeSnapshot {
        let root = node(type: "Application", label: "Example", frame: frame(x: 0, y: 0, width: 402, height: 874),
            nativeIdentity: .init(pid: 1234, objectID: 1), children: children)
        let metadata: FBSimulatorAXNativeIdentityMetadata?
        if let complete {
            metadata = try JSONDecoder().decode(FBSimulatorAXNativeIdentityMetadata.self,
                from: Data("{\"complete\":\(complete),\"reason\":null}".utf8))
        } else { metadata = nil }
        return try AgentModeSnapshot(roots: [root.decoded()], nativeIdentityMetadata: metadata, context: context())
    }

    private func context() throws -> SelectedHIDContext {
        try .fixture(boot: "boot", screenID: 1, screenUUID: "DF1FB281-4CCC-4A62-88D3-635D18FAD832", width: 402,
            height: 874, rotation: 0, pixelWidth: 1206, pixelHeight: 2622, pose: "open")
    }
}

private func frame(x: Double = 10, y: Double = 10, width: Double = 80, height: Double = 44) -> AXNodeFixture.Frame {
    .init(x: x, y: y, width: width, height: height)
}

private func node(type: String, label: String? = nil, value: String? = nil, frame: AXNodeFixture.Frame = frame(),
                  focused: Bool = false, nativeIdentity: FBSimulatorAXNativeIdentity? = nil,
                  children: [AXNodeFixture] = []) -> AXNodeFixture {
    AXNodeFixture(type: type, label: label, value: value.map { .string($0) }, frame: frame, pid: 1234,
        focused: focused, enabled: true, hidden: false, nativeIdentity: nativeIdentity, children: children)
}
