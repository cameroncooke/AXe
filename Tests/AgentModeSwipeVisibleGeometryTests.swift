import AXeCore
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Visible reference swipe geometry")
struct AgentModeSwipeVisibleGeometryTests {
    private let size = CGSize(width: 402, height: 874)
    private let content = Rect(x: 16, y: 132, width: 370, height: 1455.3333314259846)

    @Test("A content-sized native area uses the current display in every direction")
    func tallContentUsesDisplayIntersection() throws {
        let fixture = try make()
        for direction in [RuntimeSwipeDirection.up, .down, .left, .right] {
            let result = try plan(fixture, direction: direction)
            #expect(result.visibleFrame == CGRect(x: 16, y: 132, width: 370, height: 742))
            #expect(result.excludedKeyboardFrame == nil)
            #expect(inside(result.points, result.visibleFrame))
        }
    }

    @Test("The exact unique signal ancestor clips a docked keyboard without guessing its height")
    func observedDockedKeyboardUsesItsNativeBounds() throws {
        let fixture = try make(keyboard: keyboard())
        let result = try plan(fixture)
        #expect(result.excludedKeyboardFrame == CGRect(x: 0, y: 546, width: 402, height: 328))
        #expect(result.visibleFrame == CGRect(x: 16, y: 132, width: 370, height: 414))
        #expect(inside(result.points, result.visibleFrame))
        #expect(result.points.from.y < 546 && result.points.to.y < 546)
    }

    @Test("A uniquely bound scroll area in the keyboard tree keeps direct interaction")
    func keyboardOwnedScrollKeepsItsArea() throws {
        let bounds = Rect(x: 0, y: 546, width: 402, height: 44)
        let fixture = try make(frame: bounds, keyboard: keyboard(), targetWithinKeyboard: true)
        let result = try plan(fixture)
        #expect(result.visibleFrame == bounds.rect && result.excludedKeyboardFrame == nil)
        #expect(inside(result.points, bounds.rect))
    }

    @Test("Covered app content and a duplicated native target cannot claim proven keyboard ancestry")
    func keyboardCoordinatesAreNotOwnership() throws {
        let bounds = Rect(x: 0, y: 546, width: 402, height: 44)
        let coveredApp = try make(frame: bounds, keyboard: keyboard())
        #expect(throws: (any Error).self) { try plan(coveredApp) }
        let copy = Node(type: "Group", key: 2, frame: Rect(x: 0, y: 0, width: 40, height: 40))
        let duplicate = try make(frame: bounds, keyboard: keyboard(), extra: [copy], targetWithinKeyboard: true)
        #expect(duplicate.snapshot.nativeIdentityMetadata?.complete == true)
        #expect(AgentModeKeyboardDetector.occlusion(in: duplicate.snapshot, expectedPID: 1234, logicalSize: size) != nil)
        #expect(throws: (any Error).self) { try plan(duplicate) }
    }

    @Test("A missing native key makes keyboard geometry unknown and preserves existing semantic control binding")
    func missingIdentityIsUnknownNotAKeyboardOwnershipException() throws {
        let bounds = Rect(x: 0, y: 546, width: 402, height: 44)
        let missing = try make(frame: bounds, keyboard: keyboard(), targetWithinKeyboard: true, targetKey: nil)
        #expect(missing.snapshot.nativeIdentityMetadata?.complete == false)
        #expect(missing.snapshot.nativeIdentityMetadata?.reason == "missingNativeIdentity")
        #expect(AgentModeKeyboardDetector.occlusion(in: missing.snapshot, expectedPID: 1234, logicalSize: size) == nil)
        let index = try #require(missing.snapshot.nodes.firstIndex { $0.identifier == "canvas" })
        let ref = missing.snapshot.elements[index].ref
        let selected = try missing.snapshot.target(ref: ref)
        #expect(selected.semanticID == "canvas" && selected.nativeIdentity == nil)
        _ = try missing.snapshot.node(ref: ref, requiredAction: .swipeWithin)
        let result = try plan(missing)
        #expect(result.visibleFrame == bounds.rect && result.excludedKeyboardFrame == nil)
        // This is a geometry plan only. Native point/ancestry admission still runs before input.
    }

    @Test("Text below the visible region cannot move the start back behind the keyboard")
    func clippedOutTextCannotAnchor() throws {
        let text = Node(type: "StaticText", label: "Output", key: 3,
            frame: Rect(x: 136, y: 850, width: 20, height: 20))
        let result = try plan(make(keyboard: keyboard(), text: text))
        #expect(result.points.from == result.standard.from && result.points.to == result.standard.to)
        #expect(inside(result.points, result.visibleFrame))
    }

    @Test("Incomplete, missing, duplicate, wrong-owner or unavailable group authority cannot supply keyboard bounds")
    func unavailableKeyboardEvidenceIsNotInvented() throws {
        let original = keyboard()
        var absent = original; absent.key = nil
        var hidden = original; hidden.hidden = true
        var disabled = original; disabled.enabled = false
        var foreign = original; foreign.pid = 9999; foreign.keyPID = 9999
        let copy = Node(type: "Group", key: original.key, frame: Rect(x: 0, y: 0, width: 40, height: 40))
        let fixtures = [try make(keyboard: original, complete: false), try make(keyboard: absent),
            try make(keyboard: hidden), try make(keyboard: disabled), try make(keyboard: foreign),
            try make(keyboard: original, extra: [copy])]
        for fixture in fixtures {
            let result = try plan(fixture)
            #expect(result.excludedKeyboardFrame == nil)
            #expect(result.visibleFrame == CGRect(x: 16, y: 132, width: 370, height: 742))
        }
    }

    @Test("Floating bounds or signals without one shared Group do not become a docked keyboard")
    func unsupportedKeyboardShapesHaveNoGuessedHeight() throws {
        let floating = keyboard(frame: Rect(x: 80, y: 546, width: 242, height: 328))
        let floatPlan = try plan(make(keyboard: floating))
        #expect(floatPlan.excludedKeyboardFrame == nil)
        let directKeys = keyboard().children
        let noGroup = try plan(make(extra: directKeys))
        #expect(noGroup.excludedKeyboardFrame == nil)
    }

    @Test("Already visible content keeps the previous standard geometry")
    func visibleAreaIsUnchanged() throws {
        let bounds = Rect(x: 8, y: 370, width: 386, height: 495)
        let fixture = try make(frame: bounds)
        let result = try plan(fixture)
        let previous = RuntimeSnapshotElement(ref: "e2", role: .scrollView,
            frame: AgentFrame(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height), actions: [.swipeWithin])
        let expected = try #require(previous.swipePoints(direction: .up, distance: 0.5))
        #expect(result.standard.from == expected.from && result.standard.to == expected.to)
        #expect(result.visibleFrame == bounds.rect)
    }

    @Test("Missing and nonpositive control owners refuse before geometry planning")
    func invalidTargetOwnerStopsBeforeInput() throws {
        let owners: [Int32?] = [nil, 0, -1]
        for owner in owners {
            let fixture = try make(targetPID: owner)
            #expect(throws: (any Error).self) { try plan(fixture) }
        }
    }

    @Test("No visible area, invalid dimensions and nonfinite geometry refuse planning")
    func invalidCanvasStopsBeforeInput() throws {
        for bounds in [Rect(x: 0, y: 900, width: 300, height: 100),
                       Rect(x: 0, y: 0, width: -10, height: 100),
                       Rect(x: 0, y: 0, width: 300, height: -100)] {
            let fixture = try make(frame: bounds)
            #expect(throws: (any Error).self) { try plan(fixture) }
        }
        let fixture = try make()
        for shape in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 874), CGSize(width: 402, height: -1)] {
            #expect(throws: (any Error).self) {
                try AgentModeSwipePlanner.plan(target: fixture.target, snapshot: fixture.snapshot,
                    logicalSize: shape, role: .scrollView, direction: .up, distance: 0.5)
            }
        }
    }

    private func plan(_ fixture: Fixture, direction: RuntimeSwipeDirection = .up) throws -> AgentModeSwipePlanner.Plan {
        try AgentModeSwipePlanner.plan(target: fixture.target, snapshot: fixture.snapshot,
            logicalSize: size, role: .scrollView, direction: direction, distance: 0.5)
    }
    private func inside(_ points: AgentModeSwipePlanner.Points, _ frame: CGRect) -> Bool {
        [points.from, points.to].allSatisfy { frame.contains(CGPoint(x: $0.x, y: $0.y)) }
    }
    private func keyboard(frame: Rect = Rect(x: 0, y: 546, width: 402, height: 328)) -> Node {
        let keys = ["shift", "delete"].enumerated().map { offset, identifier in
            Node(type: "Button", id: identifier, key: UInt64(41 + offset),
                frame: Rect(x: frame.x + 15 + Double(offset) * 70, y: frame.y + 50, width: 40, height: 40))
        }
        return Node(type: "Group", key: 40, frame: frame, children: keys)
    }
    private struct Fixture { let snapshot: AgentModeSnapshot; let target: FBSimulatorAXNode }
    private func make(frame: Rect? = nil, keyboard: Node? = nil, text: Node? = nil,
                      extra: [Node] = [], complete: Bool = true, targetWithinKeyboard: Bool = false,
                      targetKey: UInt64? = 2, targetPID: Int32? = 1234) throws -> Fixture {
        let area = Node(type: "ScrollArea", id: "canvas", key: targetKey, pid: targetPID, frame: frame ?? content,
            children: text.map { [$0] } ?? [])
        var children = [area] + (keyboard.map { [$0] } ?? []) + extra
        if targetWithinKeyboard, var keyboard {
            keyboard.children.insert(area, at: 0)
            children = [keyboard] + extra
        }
        let root = Node(type: "Application", key: 1, frame: Rect(x: 0, y: 0, width: 402, height: 874),
            children: children)
        let native = try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(root))
        let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "00000000-0000-0000-0000-000000000001",
            bootIdentity: "boot", screenID: 1, screenUniqueID: "5D3C4CC2-87E2-4A57-AB7B-565B1B4F14F9", axDisplayID: 1,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 1,
                nativePixelSize: CGSize(width: 1206, height: 2622), scale: 3, rotation: .rot0), poseRevision: "rigid")
        return Fixture(snapshot: try AgentModeSnapshot(roots: [native], nativeIdentityMetadata: .init(complete: complete),
            context: SelectedHIDContext(observation)),
            target: targetWithinKeyboard ? native.children[0].children[0] : native.children[0])
    }
    private struct Rect: Encodable {
        var x: Double, y: Double, width: Double, height: Double
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    private struct Node: Encodable {
        var type: String
        var id: String? = nil
        var label: String? = nil
        var key: UInt64?
        var pid: Int32? = 1234
        var keyPID: Int32 = 1234
        var enabled = true, hidden = false
        var frame: Rect
        var children: [Node] = []
        private enum CodingKeys: String, CodingKey {
            case type, id = "AXUniqueId", label = "AXLabel", nativeIdentity, role, enabled, hidden, pid, frame, children
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(type, forKey: .type); try values.encodeIfPresent(id, forKey: .id)
            try values.encodeIfPresent(label, forKey: .label); try values.encode("AX" + type, forKey: .role)
            try values.encode(enabled, forKey: .enabled); try values.encode(hidden, forKey: .hidden)
            try values.encodeIfPresent(pid, forKey: .pid); try values.encode(frame, forKey: .frame)
            try values.encode(children, forKey: .children)
            if let key { try values.encode(FBSimulatorAXNativeIdentity(pid: keyPID, objectID: key), forKey: .nativeIdentity) }
        }
    }
}
