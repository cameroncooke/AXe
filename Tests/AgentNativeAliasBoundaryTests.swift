import AXeCore
import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

@Suite("Tap-only consistent native aliases")
struct AgentNativeAliasBoundaryTests {
    @Test func consistentObjectEnablesOnlyTapAndKeepsBothRows() throws {
        let button = node(type: "Button", key: 100, label: "Repeated")
        let fixture = try make([button, button])
        let index = try FBSimulatorAXNativeObjectIndex(roots: fixture.roots, metadata: .init(complete: true))
        #expect(try index.resolve(identity: button.identity, elementType: "Button", expectedPID: 42).isAlias)
        for ref in ["e2", "e3"] {
            _ = try fixture.snapshot.node(ref: ref, requiredAction: .tap)
            let target = try fixture.snapshot.target(ref: ref)
            #expect(target.nativeIdentity == button.identity)
            #expect(try fixture.snapshot.reference(target: target) == "e2")
        }
        #expect(fixture.snapshot.elements.count == 3)
        #expect(fixture.snapshot.elements[1].actions == [.tap])
        #expect(fixture.snapshot.elements[2].actions == [.tap])
        for action in [RuntimeElementAction.touch, .swipeWithin, .typeText] {
            #expect(throws: (any Error).self) { _ = try fixture.snapshot.node(ref: "e2", requiredAction: action) }
        }
    }

    @Test func differentAliasPathsStillRefuseGestureAncestry() throws {
        let button = node(type: "Button", key: 100, label: "Repeated")
        let area = node(type: "ScrollArea", key: 200, children: [button])
        let fixture = try make([area, button])
        let index = try FBSimulatorAXNativeObjectIndex(roots: fixture.roots, metadata: .init(complete: true))
        #expect(try index.resolve(identity: button.identity, elementType: "Button", expectedPID: 42).occurrences.count == 2)
        let nativeArea = fixture.roots[0].children[0]
        let hit = nativeArea.children[0]
        #expect(throws: (any Error).self) {
            _ = try AgentModePathIdentityPolicy.ancestorChain(hit: hit, area: nativeArea,
                roots: fixture.roots, snapshot: fixture.snapshot, usingNativeIdentity: true)
        }
        #expect(throws: (any Error).self) {
            _ = try AgentModePathIdentityPolicy.uniqueIndex(matching: hit, in: fixture.snapshot, usingNativeIdentity: true)
        }
    }

    @Test func equalFieldAliasesCannotAdvertiseTyping() throws {
        let field = node(type: "TextField", key: 100, focused: true)
        let fixture = try make([field, field])
        let index = try FBSimulatorAXNativeObjectIndex(roots: fixture.roots, metadata: .init(complete: true))
        #expect(try index.resolve(identity: field.identity, elementType: "TextField", expectedPID: 42).isAlias)
        #expect(!fixture.snapshot.elements[1].actions.contains(.typeText))
        #expect(!fixture.snapshot.elements[2].actions.contains(.typeText))
        #expect(throws: (any Error).self) { _ = try fixture.snapshot.node(ref: "e2", requiredAction: .typeText) }
    }

    @Test(arguments: ["label", "hidden", "disabled", "type", "number", "ancestor"])
    func conflictingOrUnprovableAliasesRefuseTap(change: String) throws {
        let first = node(type: "Button", key: 100, label: "Repeated")
        var second = first
        switch change {
        case "label": second.label = "Changed"
        case "hidden": second.hidden = true
        case "disabled": second.enabled = false
        case "type": second.type = "Group"; second.role = "AXGroup"
        case "number": second.value = .number(1)
        default: break
        }
        let children: [AXNodeFixture]
        if change == "ancestor" {
            children = [first, node(type: "Group", key: 200, enabled: false, children: [second])]
        } else { children = [first, second] }
        let fixture = try make(children)
        let native = SelectedNativeTarget.nativeObject(identity: first.identity, elementType: "Button")
        #expect(throws: (any Error).self) { _ = try fixture.snapshot.match(target: native) }
    }

    @Test func singletonNumericTapRemainsOnItsExistingRoute() throws {
        let button = node(type: "CheckBox", key: 100, value: .number(1))
        let fixture = try make([button])
        _ = try fixture.snapshot.node(ref: "e2", requiredAction: .tap)
        #expect(try fixture.snapshot.target(ref: "e2").nativeIdentity == button.identity)
        #expect(try fixture.snapshot.match(target: fixture.snapshot.target(ref: "e2")).value == .number(1))
    }

    @Test func incompleteAliasMetadataDoesNotRemoveSemanticSingleton() throws {
        let singleton = node(type: "Button", key: 300, label: "Unique")
        let alias = node(type: "Button", key: 100, label: "Repeated")
        let fixture = try make([singleton, alias, alias], complete: false)
        _ = try fixture.snapshot.node(ref: "e2", requiredAction: .tap)
        #expect(try fixture.snapshot.target(ref: "e2").nativeIdentity == nil)
        #expect(throws: (any Error).self) { _ = try fixture.snapshot.node(ref: "e3", requiredAction: .tap) }
    }

    @Test func invalidLaterReferencePreventsWholeBatchPlanning() throws {
        let alias = node(type: "Button", key: 100, label: "Repeated")
        let fixture = try make([alias, alias])
        let table = UUID()
        let document = try JSONDecoder().decode(AgentBatchDocument.self, from: Data("""
            {"snapshotID":"\(table.uuidString)","steps":[{"action":"tap","ref":"e2"},{"action":"tap","ref":"e999"}]}
            """.utf8))
        let request = AgentBatchRequest(expectedPID: nil, snapshotID: table, steps: document.steps)
        #expect(throws: (any Error).self) {
            _ = try AgentBatchReferencePlan(request: request, snapshotID: table,
                snapshot: fixture.snapshot, context: fixture.context, pid: 42)
        }
    }

    @Test func aliasBatchResolvesCurrentClassButRejectsChangedCopiesOrContext() throws {
        let alias = node(type: "Button", key: 100, label: "Repeated")
        let fixture = try make([alias, alias])
        let table = UUID()
        let document = try JSONDecoder().decode(AgentBatchDocument.self, from: Data("""
            {"snapshotID":"\(table.uuidString)","steps":[{"action":"tap","ref":"e3"}]}
            """.utf8))
        let plan = try AgentBatchReferencePlan(request: .init(expectedPID: nil, snapshotID: table, steps: document.steps),
            snapshotID: table, snapshot: fixture.snapshot, context: fixture.context, pid: 42)
        #expect(try plan.resolve(index: 0, snapshot: fixture.snapshot,
            context: fixture.context, pid: 42).nativeTarget.nativeIdentity == alias.identity)
        var changed = alias; changed.value = .string("changed")
        let fresh = try make([alias, changed])
        #expect(throws: (any Error).self) {
            _ = try plan.resolve(index: 0, snapshot: fresh.snapshot, context: fixture.context, pid: 42)
        }
        #expect(throws: (any Error).self) {
            _ = try plan.resolve(index: 0, snapshot: fixture.snapshot, context: fixture.context, pid: 43)
        }
    }

    private func make(_ children: [AXNodeFixture], complete: Bool = true) throws -> (roots: [FBSimulatorAXNode], snapshot: AgentModeSnapshot, context: SelectedHIDContext) {
        let root = node(type: "Application", key: 1, children: children)
        let roots = try AXNodeFixture.decode([root])
        let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "00000000-0000-0000-0000-000000000001",
            bootIdentity: "test-boot", screenID: 1, screenUniqueID: "DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0", axDisplayID: 1,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 1,
                nativePixelSize: CGSize(width: 1200, height: 2400), scale: 3, rotation: .rot0), poseRevision: "rigid")
        let context = SelectedHIDContext(observation)
        return (roots, try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: .init(complete: complete),
            context: context), context)
    }

}

/// Every node is owned by PID 42 and carries the native identity for its `key`.
private func node(type: String, key: UInt64, label: String? = nil, focused: Bool = false, enabled: Bool = true,
                  value: FBSimulatorAXValue? = nil, children: [AXNodeFixture] = []) -> AXNodeFixture {
    AXNodeFixture(type: type, label: label, value: value, role: "AX" + type,
        frame: .init(x: 10, y: 100, width: 300, height: 50), pid: 42, focused: focused, enabled: enabled,
        hidden: false, nativeIdentity: .init(pid: 42, objectID: key), children: children)
}

private extension AXNodeFixture {
    var identity: FBSimulatorAXNativeIdentity {
        guard let nativeIdentity else { preconditionFailure("Every node in this file has a native identity.") }
        return nativeIdentity
    }
}
