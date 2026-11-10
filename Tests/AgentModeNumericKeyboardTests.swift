import AXeCore
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Numeric keyboard evidence and docked bounds")
struct AgentModeNumericKeyboardTests {
    private let size = CGSize(width: 402, height: 874)

    @Test("The observed OS numeric keyplane clips to its enclosing docked keyboard branch")
    func numericKeyboardUsesDockedBranch() throws {
        let fixture = try make()
        let capture = capture(fixture)
        let keyboard = try #require(capture.keyboard)
        #expect(keyboard.state == .likelyVisible)
        #expect(keyboard.signals.numericKeyCount == 10)
        #expect(keyboard.signals.letterKeyCount == 0)
        let occlusion = try #require(AgentModeKeyboardDetector.occlusion(in: fixture.snapshot,
            expectedPID: 1234, logicalSize: size))
        #expect(occlusion.frame == CGRect(x: 0, y: 572, width: 402, height: 302))
        let plan = try AgentModeSwipePlanner.plan(target: fixture.area, snapshot: fixture.snapshot,
            logicalSize: size, role: .scrollView, direction: .up, distance: 0.5)
        #expect(plan.visibleFrame == CGRect(x: 16, y: 39, width: 370, height: 533))
        #expect(plan.excludedKeyboardFrame == occlusion.frame)
        #expect(plan.points.from.y < 572 && plan.points.to.y < 572)
    }

    @Test("App dialpads do not become OS keyboard evidence from digits or delete alone")
    func ordinaryDialpadStaysUnknown() throws {
        let fixture = try make(variant: "unmarked")
        let keyboard = try #require(capture(fixture).keyboard)
        #expect(keyboard.state == .unknown)
        #expect(keyboard.signals.numericKeyCount == nil)
        #expect(AgentModeKeyboardDetector.occlusion(in: fixture.snapshot,
            expectedPID: 1234, logicalSize: size) == nil)
        let data = try JSONEncoder().encode(keyboard)
        #expect(!String(decoding: data, as: UTF8.self).contains("numericKeyCount"))
    }

    @Test(arguments: ["missing-digit", "duplicate-digit", "missing-delete", "unfocused", "hidden", "disabled", "foreign", "incomplete", "duplicate-marker"])
    func incompleteOrAmbiguousEvidenceStaysUnknown(variant: String) throws {
        let fixture = try make(variant: variant)
        let keyboard = try #require(capture(fixture).keyboard)
        #expect(keyboard.state == .unknown)
        #expect(keyboard.signals.numericKeyCount == nil)
        #expect(AgentModeKeyboardDetector.occlusion(in: fixture.snapshot,
            expectedPID: 1234, logicalSize: size) == nil)
    }

    @Test("A floating keyplane does not make a full application ancestor a keyboard")
    func noDockedContainerDoesNotGuess() throws {
        let fixture = try make(variant: "floating")
        let keyboard = try #require(capture(fixture).keyboard)
        #expect(keyboard.state == .likelyVisible)
        #expect(AgentModeKeyboardDetector.occlusion(in: fixture.snapshot,
            expectedPID: 1234, logicalSize: size) == nil)
    }

    @Test("An app control outside the trusted keyplane blocks enclosing-group ownership")
    func enclosingFormDoesNotBecomeKeyboard() throws {
        let fixture = try make(variant: "app-control")
        let keyboard = try #require(capture(fixture).keyboard)
        #expect(keyboard.state == .likelyVisible)
        #expect(AgentModeKeyboardDetector.occlusion(in: fixture.snapshot,
            expectedPID: 1234, logicalSize: size) == nil)
    }

    @Test("Cached pages keep the same numeric keyboard observation")
    func pagingKeepsEvidence() throws {
        let fixture = try make()
        let first = capture(fixture)
        let page = fixture.snapshot.capture(id: first.snapshotID, sequence: 1, udid: "fixture",
            request: .init(kind: .describe, rowOffset: 1, rowLimit: 1), applicationPID: 1234,
            context: fixture.context, unchanged: false, expiresIn: 60)
        let firstKeyboard = try #require(first.keyboard)
        let pageKeyboard = try #require(page.keyboard)
        #expect(pageKeyboard == firstKeyboard)
        #expect(page.snapshotID == first.snapshotID)
    }

    private struct Fixture {
        let snapshot: AgentModeSnapshot
        let area: FBSimulatorAXNode
        let context: SelectedHIDContext
    }

    private func capture(_ fixture: Fixture) -> AgentModeCapture {
        fixture.snapshot.capture(id: UUID(), sequence: 1, udid: "fixture", request: .init(kind: .describe),
            applicationPID: 1234, context: fixture.context, unchanged: false, expiresIn: 60)
    }

    private func make(variant: String = "valid") throws -> Fixture {
        let field = node(type: "TextField", key: 2, id: "editor", frame: Frame(x: 16, y: 90, width: 300, height: 44),
            focused: variant != "unfocused")
        let area = node(type: "ScrollArea", key: 3, id: "form", frame: Frame(x: 16, y: 39, width: 370, height: 1455))
        var keys: [AXNodeFixture] = []
        for digit in 0...9 {
            let x = 5.0 + Double(digit % 3) * 132.0
            let y = 596.0 + Double(digit / 3) * 54.0
            let bounds = Frame(x: x, y: y, width: 126, height: 50)
            let key = node(type: "Button", key: UInt64(100 + digit), label: String(digit), frame: bounds)
            keys.append(key)
        }
        keys.append(node(type: "Button", key: 120, label: "Delete", frame: Frame(x: 270, y: 758, width: 126, height: 50)))
        if variant == "missing-digit" { keys.removeFirst() }
        if variant == "duplicate-digit" { keys[0].label = "1" }
        if variant == "missing-delete" { keys.removeLast() }
        var marker = node(type: "Group", key: 11, id: variant == "unmarked" ? "app.dialpad" : "UIKeyboardLayoutStar Preview",
            frame: Frame(x: 0, y: 589, width: 402, height: 227), children: keys)
        if variant == "hidden" { marker.hidden = true }
        if variant == "disabled" { marker.enabled = false }
        if variant == "foreign" { marker.pid = 5678 }
        let dictation = node(type: "Button", key: 12, id: "dictation", label: "Dictate",
            frame: Frame(x: 326, y: 810, width: 60, height: 60))
        var dock = node(type: "Group", key: 10, frame: Frame(x: 0, y: 572, width: 402, height: 302),
            children: [marker, dictation])
        if variant == "floating" { dock.frame?.height = 244; dock.children = [marker] }
        if variant == "app-control" {
            dock.children?.append(node(type: "Button", key: 13, id: "app.action", label: "Continue",
                frame: Frame(x: 10, y: 820, width: 50, height: 30)))
        }
        var root = node(type: "Application", key: 1, frame: Frame(x: 0, y: 0, width: 402, height: 874),
            children: [field, area, dock])
        if variant == "duplicate-marker" { root.children?.append(marker) }
        let native = try root.decoded()
        let context = try SelectedHIDContext.fixture(boot: "boot", screenID: 1,
            screenUUID: "DF1FB281-4CCC-4A62-88D3-635D18FAD832", width: 402, height: 874, rotation: 0,
            pixelWidth: 1206, pixelHeight: 2622, pose: "rigid")
        return Fixture(snapshot: try AgentModeSnapshot(roots: [native],
            nativeIdentityMetadata: .init(complete: variant != "incomplete"), context: context),
            area: native.children[1], context: context)
    }

    private typealias Frame = AXNodeFixture.Frame
}

/// `key` becomes the native identity with the node's `pid` at encode time.
private func node(type: String, key: UInt64, id: String? = nil, label: String? = nil, frame: AXNodeFixture.Frame,
                  focused: Bool = false, children: [AXNodeFixture] = []) -> AXNodeFixture {
    AXNodeFixture(type: type, identifier: id, label: label, frame: frame, pid: 1234, focused: focused, enabled: true,
        hidden: false, nativeObjectID: key, children: children)
}
