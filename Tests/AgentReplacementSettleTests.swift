import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Post-action replacement settle")
struct AgentReplacementSettleTests {
    @Test("An unchanged screen is published at once")
    func unchangedIsSmall() throws {
        let screen = try snapshot(buttons: ["A", "B", "C"], status: "tap 1")
        #expect(!AgentReplacementSettle.isLargeChange(from: screen, to: screen))
    }

    @Test("An in-place label change is published at once")
    func labelChangeIsSmall() throws {
        let before = try snapshot(buttons: ["A", "B", "C"], status: "tap 1")
        let after = try snapshot(buttons: ["A", "B", "C"], status: "tap 2")
        #expect(!AgentReplacementSettle.isLargeChange(from: before, to: after))
    }

    @Test("A replaced screen is confirmed before publication")
    func replacedScreenIsLarge() throws {
        let before = try snapshot(buttons: ["A", "B", "C", "D"], status: "list")
        let after = try snapshot(buttons: ["E", "F", "G", "H"], status: "detail")
        #expect(AgentReplacementSettle.isLargeChange(from: before, to: after))
    }

    @Test("A screen that slides every control is confirmed before publication")
    func movedControlsAreLarge() throws {
        let before = try snapshot(buttons: ["A", "B", "C", "D"], status: "list")
        let after = try snapshot(buttons: ["A", "B", "C", "D"], status: "list", offset: 40)
        #expect(AgentReplacementSettle.isLargeChange(from: before, to: after))
    }

    private func snapshot(buttons: [String], status: String, offset: Double = 0) throws -> AgentModeSnapshot {
        let children = buttons.enumerated().map { index, label in
            Node(type: "Button", label: label, frame: .init(x: 20 + offset, y: 100 + Double(index) * 50))
        } + [Node(type: "StaticText", label: status, frame: .init(x: 20, y: 40))]
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
        let label: String
        let frame: Frame
        var children: [Node] = []
        let pid: Int32 = 1234
        let enabled = true
        let hidden = false
        private enum CodingKeys: String, CodingKey {
            case type, label = "AXLabel", frame, children, pid, enabled, hidden
        }
    }
}
