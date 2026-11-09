import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Visible admission fingerprint")
struct AgentVisibleFingerprintTests {
    @Test("An identical tree has equal native and visible fingerprints")
    func identicalTrees() throws {
        let a = try snapshot(buttons: ["A", "B"])
        let b = try snapshot(buttons: ["A", "B"])
        #expect(a.nativeFingerprint == b.nativeFingerprint && a.visibleFingerprint == b.visibleFingerprint)
    }

    @Test("Inert, hidden and off-display nodes change the native fingerprint only",
          arguments: [Extra.inertGroup, .hidden, .offDisplay])
    func inertChangesAreInvisible(extra: Extra) throws {
        let before = try snapshot(buttons: ["A", "B"])
        let after = try snapshot(buttons: ["A", "B"], extra: extra)
        #expect(before.nativeFingerprint != after.nativeFingerprint)
        #expect(before.visibleFingerprint == after.visibleFingerprint)
    }

    @Test("A visible label, value, frame or control change is an admission change")
    func visibleChangesRefuse() throws {
        let before = try snapshot(buttons: ["A", "B"])
        #expect(before.visibleFingerprint != (try snapshot(buttons: ["A", "C"])).visibleFingerprint)
        #expect(before.visibleFingerprint != (try snapshot(buttons: ["A", "B"], value: "1")).visibleFingerprint)
        #expect(before.visibleFingerprint != (try snapshot(buttons: ["A", "B"], offset: 1)).visibleFingerprint)
        #expect(before.visibleFingerprint != (try snapshot(buttons: ["A", "B", "Overlay"])).visibleFingerprint)
    }

    @Test("A visible descendant of an off-display or inert parent still counts")
    func descendantsOfExcludedParentsCount() throws {
        let before = try snapshot(buttons: ["A", "B"])
        let after = try snapshot(buttons: ["A", "B"], extra: .groupWithVisibleChild)
        #expect(before.visibleFingerprint != after.visibleFingerprint)
    }

    @Test("A ticking leaf StaticText does not change the admission fingerprint")
    func ordinaryTextChangesAreInvisible() throws {
        let before = try snapshot(buttons: ["A", "B"], text: Node(type: "StaticText", label: "00:01",
            frame: .init(x: 20, y: 400, width: 60)))
        let after = try snapshot(buttons: ["A", "B"], text: Node(type: "StaticText", label: "00:02", value: "2",
            frame: .init(x: 20, y: 400, width: 64)))
        #expect(before.visibleFingerprint == after.visibleFingerprint)
        // The semantic hash still reports the new text, and a new or removed text node still counts.
        #expect(before.hash != after.hash)
        #expect(before.visibleFingerprint != (try snapshot(buttons: ["A", "B"])).visibleFingerprint)
    }

    @Test("Text inside a control, and a control's own label, stay bound")
    func controlTextIsBound() throws {
        func cell(_ text: String) throws -> AgentModeSnapshot {
            try snapshot(buttons: ["A"], text: Node(type: "Button", label: "Row",
                frame: .init(x: 20, y: 400, width: 300),
                children: [Node(type: "StaticText", label: text, frame: .init(x: 24, y: 404, width: 100))]))
        }
        #expect(try cell("Delete").visibleFingerprint != cell("Keep").visibleFingerprint)
        #expect(try snapshot(buttons: ["A"]).visibleFingerprint != snapshot(buttons: ["B"]).visibleFingerprint)
    }

    enum Extra: Sendable { case inertGroup, hidden, offDisplay, groupWithVisibleChild }

    private func snapshot(buttons: [String], value: String? = nil, offset: Double = 0,
                          extra: Extra? = nil, text: Node? = nil) throws -> AgentModeSnapshot {
        var children = buttons.enumerated().map { index, label in
            Node(type: "Button", label: label, frame: .init(x: 20 + offset, y: 100 + Double(index) * 50))
        }
        if let text { children.append(text) }
        if let value { children[0].value = value }
        switch extra {
        case .inertGroup?:
            children.append(Node(type: "Group", label: nil, frame: .init(x: 8, y: 370, width: 386, height: 496)))
        case .hidden?:
            children.append(Node(type: "Button", label: "Hidden", frame: .init(x: 20, y: 300), hidden: true))
        case .offDisplay?:
            children.append(Node(type: "Button", label: "Below", frame: .init(x: 20, y: 2000)))
        case .groupWithVisibleChild?:
            children.append(Node(type: "Group", label: nil, frame: .init(x: 0, y: 2000, width: 402, height: 400),
                                 children: [Node(type: "Button", label: "Child", frame: .init(x: 20, y: 300))]))
        case nil: break
        }
        let root = Node(type: "Application", label: "App", frame: .init(x: 0, y: 0, width: 402, height: 874),
                        children: children)
        let roots = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode([root]))
        return try AgentModeSnapshot(roots: roots, context: try context())
    }

    private func context() throws -> SelectedHIDContext {
        try JSONDecoder().decode(SelectedHIDContext.self, from: Data("""
            {"bootIdentity":"1:2:3","screenID":1,"screenUUID":"DFEBAD86-C7D4-45CA-BB20-2D73B355B0A1",\
            "logicalWidth":402,"logicalHeight":874,"rotationDegrees":0,"nativePixelWidth":1206,\
            "nativePixelHeight":2622,"scale":3,"poseRevision":"rigid"}
            """.utf8))
    }

    private struct Node: Encodable {
        struct Frame: Encodable {
            var x: Double; var y: Double; var width = 300.0; var height = 44.0
        }
        let type: String
        let label: String?
        var value: String? = nil
        let frame: Frame
        var children: [Node] = []
        var hidden = false
        let pid: Int32 = 1234
        let enabled = true
        private enum CodingKeys: String, CodingKey {
            case type, label = "AXLabel", value = "AXValue", frame, children, pid, enabled, hidden
        }
    }
}
