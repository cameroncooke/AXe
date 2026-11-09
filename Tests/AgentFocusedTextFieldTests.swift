import AXeCore
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Agent focused TextField identity")
struct AgentFocusedTextFieldTests {
    @Test("A container's inherited ID does not hide a uniquely identified TextField")
    func inheritedContainerIDAdmitsFocusedField() throws {
        let field = Fixture(type: "TextField", id: "shared", label: "Search")
        let group = Fixture(type: "Group", id: "shared", label: "Locations", children: [field,
            Fixture(type: "Button", id: "shared", label: "Close"),
            Fixture(type: "StaticText", id: "shared", label: "Locations")])
        let (snapshot, context) = try makeSnapshot([group])
        let ref = try snapshot.reference(id: "shared", action: .typeText)
        let native = try snapshot.node(ref: ref, requiredAction: .typeText)
        #expect(native.type == "TextField" && native.identifier == "shared")
        try SelectedKeyboardFocusPolicy.validate(native, expectedPID: 1234,
            fieldTarget: .semantic(kind: .id, value: "shared", elementType: "TextField"))
        let selector = try snapshot.uniqueSelector(for: native)
        #expect(selector.kind == .id && selector.value == "shared")
        let capture = snapshot.capture(id: UUID(), sequence: 1, udid: "fixture",
            request: .init(kind: .describe), applicationPID: 1234, context: context,
            unchanged: false, expiresIn: 60)
        #expect(capture.targets.contains { $0.hasPrefix(ref + "|typeText|text-field|") })
        // Untyped batch taps still require global ID uniqueness.
        #expect(throws: AgentModeFailure.self) {
            _ = try snapshot.reference(id: "shared", action: .tap)
        }
    }

    @Test(arguments: ["unfocused", "hidden", "disabled", "foreign-process"])
    func duplicateFieldsRemainAmbiguousBeforeStateFiltering(variant: String) throws {
        let field = Fixture(type: "TextField", id: "shared", label: "Search")
        var other = Fixture(type: "TextField", id: "shared", label: "Another field")
        switch variant {
        case "unfocused": other.focused = false
        case "hidden": other.hidden = true
        case "disabled": other.enabled = false
        default: other.pid = 5678
        }
        let (snapshot, _) = try makeSnapshot([field, other])
        #expect(snapshot.elements.allSatisfy { !$0.actions.contains(.typeText) })
        do {
            _ = try snapshot.reference(id: "shared", action: .typeText)
            Issue.record("A duplicate TextField ID authorized typing.")
        } catch let error as AgentModeFailure {
            #expect(error.code == "batchTargetMissing")
        }
    }

    @Test(arguments: ["unfocused", "missing-focus", "disabled", "missing-enabled", "hidden", "missing-hidden"])
    func focusedStateMustStillBeExplicit(variant: String) throws {
        var field = Fixture(type: "TextField", id: "shared", label: "Search")
        switch variant {
        case "unfocused": field.focused = false
        case "missing-focus": field.focused = nil
        case "disabled": field.enabled = false
        case "missing-enabled": field.enabled = nil
        case "hidden": field.hidden = true
        default: field.hidden = nil
        }
        let (snapshot, _) = try makeSnapshot([Fixture(type: "Group", id: "shared", children: [field])])
        #expect(snapshot.elements.allSatisfy { !$0.actions.contains(.typeText) })
        #expect(throws: AgentModeFailure.self) {
            _ = try snapshot.reference(id: "shared", action: .typeText)
        }
    }

    @Test(arguments: ["hidden-parent", "outside-viewport"])
    func typedIDDoesNotBypassVisibleReferenceAdmission(variant: String) throws {
        var field = Fixture(type: "TextField", id: "shared", label: "Search")
        if variant == "outside-viewport" { field.frame.y = 800 }
        var parent = Fixture(type: "Group", id: "shared", children: [field])
        if variant == "hidden-parent" { parent.hidden = true }
        let (snapshot, _) = try makeSnapshot([parent])
        #expect(throws: AgentModeFailure.self) {
            _ = try snapshot.reference(id: "shared", action: .typeText)
        }
    }

    @Test(arguments: ["", " shared", "shared ", String(repeating: "a", count: 4097)])
    func malformedFieldIDsDoNotGainTyping(id: String) throws {
        let (snapshot, _) = try makeSnapshot([Fixture(type: "TextField", id: id, label: "Search")])
        #expect(snapshot.elements.allSatisfy { !$0.actions.contains(.typeText) })
    }

    @Test(arguments: ["SearchField", "TextArea", "TextView", "SecureTextField", "AXTextField"])
    func presentationAliasesDoNotExpandTheNativeKeyboardContract(type: String) throws {
        let (snapshot, _) = try makeSnapshot([Fixture(type: type, id: "field", label: "Search")])
        #expect(snapshot.elements.allSatisfy { !$0.actions.contains(.typeText) })
    }

    private func makeSnapshot(_ children: [Fixture]) throws -> (AgentModeSnapshot, SelectedHIDContext) {
        let context = try JSONDecoder().decode(SelectedHIDContext.self, from: Data(
            #"{"bootIdentity":"1:2:3","screenID":3,"screenUUID":"DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0","logicalWidth":951,"logicalHeight":669,"rotationDegrees":90,"nativePixelWidth":2007,"nativePixelHeight":2853,"scale":3,"poseRevision":"mechanicalDegrees=90.0"}"#.utf8))
        let root = Fixture(type: "Application", id: "application", label: "Application", children: children)
        let nodes = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode([root]))
        return (try AgentModeSnapshot(roots: nodes, context: context), context)
    }

    private struct Fixture: Encodable {
        struct Frame: Encodable {
            var x = 10.0
            var y = 100.0
            var width = 300.0
            var height = 44.0
        }
        let type: String
        var id: String
        var label = ""
        var children: [Fixture] = []
        var frame = Frame()
        var pid: Int32 = 1234
        var focused: Bool? = true
        var enabled: Bool? = true
        var hidden: Bool? = false
        private enum CodingKeys: String, CodingKey {
            case type, id = "AXUniqueId", label = "AXLabel", children, frame, pid, focused, enabled, hidden
        }
    }
}
