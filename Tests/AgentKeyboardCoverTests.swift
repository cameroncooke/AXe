import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Keyboard-covered tap targets")
struct AgentKeyboardCoverTests {
    @Test("A target under the keyboard is covered, with the scroll area that holds it")
    func coveredRowInForm() throws {
        let snapshot = try make()
        let ref = try reference("add email", in: snapshot)
        let cover = try #require(AgentKeyboardCover.find(ref: ref, in: snapshot, pid: 1234, context: context()))
        #expect(cover.keyboard.minY == 540)
        #expect(cover.scrollArea?.label == "Form")
        let message = cover.failure.message
        #expect(cover.scrollArea.map { message.contains("ref \($0.ref) up") } == true)
        #expect(message.contains("\"add email\" is under the keyboard") && message.contains("nothing was sent"))
    }

    @Test("Targets above the keyboard and the keyboard's own keys are not covered")
    func clearTargets() throws {
        let snapshot = try make()
        #expect(AgentKeyboardCover.find(ref: try reference("add name", in: snapshot), in: snapshot,
            pid: 1234, context: try context()) == nil)
        #expect(AgentKeyboardCover.find(ref: try reference("q", in: snapshot), in: snapshot,
            pid: 1234, context: try context()) == nil)
    }

    @Test("A covered target outside any scroll area has nothing to scroll")
    func coveredWithoutScrollArea() throws {
        let snapshot = try make(outsideForm: true)
        let cover = try #require(AgentKeyboardCover.find(ref: try reference("add email", in: snapshot),
            in: snapshot, pid: 1234, context: context()))
        #expect(cover.scrollArea == nil)
        #expect(!cover.failure.message.contains("ref "))
    }

    @Test("Without a measured keyboard nothing is reported as covered")
    func noKeyboard() throws {
        let snapshot = try make(keyboard: false)
        #expect(AgentKeyboardCover.find(ref: try reference("add email", in: snapshot), in: snapshot,
            pid: 1234, context: try context()) == nil)
    }

    private func reference(_ label: String, in snapshot: AgentModeSnapshot) throws -> String {
        try #require(snapshot.elements.first { $0.label == label }).ref
    }

    private func make(keyboard: Bool = true, outsideForm: Bool = false) throws -> AgentModeSnapshot {
        var next: UInt64 = 10
        func node(_ type: String, _ label: String, _ frame: Node.Frame, role: String? = nil, children: [Node] = []) -> Node {
            next += 1
            return Node(type: type, label: label, frame: frame, role: role, key: next, children: children)
        }
        let rows = [node("Button", "add name", .init(x: 16, y: 300, width: 370, height: 51), role: "AXButton"),
                    node("Button", "add phone", .init(x: 16, y: 470, width: 370, height: 51), role: "AXButton")]
        let email = node("Button", "add email", .init(x: 16, y: 632, width: 370, height: 51), role: "AXButton")
        let form = node("ScrollView", "Form", .init(x: 0, y: 100, width: 402, height: 774), role: "AXScrollArea",
            children: outsideForm ? rows : rows + [email])
        var children = [form] + (outsideForm ? [email] : [])
        if keyboard {
            let letters = Array("qwertyuiopasdfghjklzxcvbnm").enumerated().map { index, letter in
                node("Button", String(letter), .init(x: Double(index % 10) * 40 + 2, y: 597 + Double(index / 10) * 54,
                    width: 36, height: 46), role: "AXButton")
            }
            children.append(node("Group", "", .init(x: 0, y: 540, width: 402, height: 334), children: letters))
        }
        let root = Node(type: "Application", label: "Contacts", frame: .init(x: 0, y: 0, width: 402, height: 874),
            key: 1, children: children)
        let native = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode([root]))
        return try AgentModeSnapshot(roots: native, nativeIdentityMetadata: .init(complete: true, reason: nil),
            context: try context())
    }

    private func context() throws -> SelectedHIDContext {
        try JSONDecoder().decode(SelectedHIDContext.self, from: Data("""
        {"bootIdentity":"1:2:3","screenID":1,"screenUUID":"DF1FB281-4CCC-4A62-88D3-635D18FAD832",
         "logicalWidth":402,"logicalHeight":874,"rotationDegrees":0,
         "nativePixelWidth":1206,"nativePixelHeight":2622,"scale":3,"poseRevision":"mechanicalDegrees=180"}
        """.utf8))
    }

    private struct Node: Encodable {
        struct Frame: Encodable { var x = 0.0; var y = 0.0; var width = 0.0; var height = 0.0 }
        let type: String
        let label: String
        let frame: Frame
        var role: String? = nil
        var key: UInt64? = nil
        var children: [Node] = []
        let pid: Int32 = 1234
        let enabled = true
        let hidden = false
        private enum CodingKeys: String, CodingKey {
            case type, label = "AXLabel", frame, role, children, pid, enabled, hidden, nativeIdentity
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(type, forKey: .type); try values.encode(label, forKey: .label)
            try values.encode(frame, forKey: .frame); try values.encodeIfPresent(role, forKey: .role)
            try values.encode(children, forKey: .children); try values.encode(pid, forKey: .pid)
            try values.encode(enabled, forKey: .enabled); try values.encode(hidden, forKey: .hidden)
            if let key { try values.encode(FBSimulatorAXNativeIdentity(pid: pid, objectID: key), forKey: .nativeIdentity) }
        }
    }
}
