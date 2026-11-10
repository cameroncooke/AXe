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
        let before = try snapshot(buttons: ["A", "B"], text: node(type: "StaticText", label: "00:01",
            frame: frame(x: 20, y: 400, width: 60)))
        let after = try snapshot(buttons: ["A", "B"], text: node(type: "StaticText", label: "00:02", value: "2",
            frame: frame(x: 20, y: 400, width: 64)))
        #expect(before.visibleFingerprint == after.visibleFingerprint)
        // The semantic hash still reports the new text, and a new or removed text node still counts.
        #expect(before.hash != after.hash)
        #expect(before.visibleFingerprint != (try snapshot(buttons: ["A", "B"])).visibleFingerprint)
    }

    @Test("Text inside a control, and a control's own label, stay bound")
    func controlTextIsBound() throws {
        func cell(_ text: String) throws -> AgentModeSnapshot {
            try snapshot(buttons: ["A"], text: node(type: "Button", label: "Row",
                frame: frame(x: 20, y: 400, width: 300),
                children: [node(type: "StaticText", label: text, frame: frame(x: 24, y: 404, width: 100))]))
        }
        #expect(try cell("Delete").visibleFingerprint != cell("Keep").visibleFingerprint)
        #expect(try snapshot(buttons: ["A"]).visibleFingerprint != snapshot(buttons: ["B"]).visibleFingerprint)
    }

    enum Extra: Sendable { case inertGroup, hidden, offDisplay, groupWithVisibleChild }

    private func snapshot(buttons: [String], value: String? = nil, offset: Double = 0,
                          extra: Extra? = nil, text: AXNodeFixture? = nil) throws -> AgentModeSnapshot {
        var children = buttons.enumerated().map { index, label in
            node(type: "Button", label: label, frame: frame(x: 20 + offset, y: 100 + Double(index) * 50))
        }
        if let text { children.append(text) }
        if let value { children[0].value = .string(value) }
        switch extra {
        case .inertGroup?:
            children.append(node(type: "Group", label: nil, frame: frame(x: 8, y: 370, width: 386, height: 496)))
        case .hidden?:
            children.append(node(type: "Button", label: "Hidden", frame: frame(x: 20, y: 300), hidden: true))
        case .offDisplay?:
            children.append(node(type: "Button", label: "Below", frame: frame(x: 20, y: 2000)))
        case .groupWithVisibleChild?:
            children.append(node(type: "Group", label: nil, frame: frame(x: 0, y: 2000, width: 402, height: 400),
                                 children: [node(type: "Button", label: "Child", frame: frame(x: 20, y: 300))]))
        case nil: break
        }
        let root = node(type: "Application", label: "App", frame: frame(x: 0, y: 0, width: 402, height: 874),
                        children: children)
        return try AgentModeSnapshot(roots: AXNodeFixture.decode([root]), context: try context())
    }

    private func context() throws -> SelectedHIDContext {
        try .fixture(screenID: 1, screenUUID: "DFEBAD86-C7D4-45CA-BB20-2D73B355B0A1", width: 402, height: 874,
            rotation: 0, pixelWidth: 1206, pixelHeight: 2622, pose: "rigid")
    }
}

private func frame(x: Double, y: Double, width: Double = 300, height: Double = 44) -> AXNodeFixture.Frame {
    .init(x: x, y: y, width: width, height: height)
}

private func node(type: String, label: String?, value: String? = nil, frame: AXNodeFixture.Frame,
                  children: [AXNodeFixture] = [], hidden: Bool = false) -> AXNodeFixture {
    AXNodeFixture(type: type, label: label, value: value.map { .string($0) }, frame: frame, pid: 1234,
        enabled: true, hidden: hidden, children: children)
}
