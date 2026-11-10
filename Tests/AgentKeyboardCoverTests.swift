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
        func node(_ type: String, _ label: String, _ frame: AXNodeFixture.Frame, role: String? = nil,
                  children: [AXNodeFixture] = [], key: UInt64? = nil) -> AXNodeFixture {
            next += 1
            return AXNodeFixture(type: type, label: label, role: role, frame: frame, pid: 1234, enabled: true,
                hidden: false, nativeIdentity: .init(pid: 1234, objectID: key ?? next), children: children)
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
        let root = node("Application", "Contacts", .init(x: 0, y: 0, width: 402, height: 874),
            children: children, key: 1)
        return try AgentModeSnapshot(roots: AXNodeFixture.decode([root]),
            nativeIdentityMetadata: .init(complete: true, reason: nil), context: try context())
    }

    private func context() throws -> SelectedHIDContext {
        try .fixture(screenID: 1, screenUUID: "DF1FB281-4CCC-4A62-88D3-635D18FAD832", width: 402, height: 874,
            rotation: 0, pixelWidth: 1206, pixelHeight: 2622, pose: "mechanicalDegrees=180")
    }
}
