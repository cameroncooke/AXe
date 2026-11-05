import AXeCore
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Fresh scroll frame with a coarse native ancestor hit")
struct AgentModeCoarseScrollAdmissionTests {
    private let start = CGPoint(x: 211, y: 443)
    private let end = CGPoint(x: 211, y: 298)
    private let size = CGSize(width: 402, height: 874)

    @Test("A content-sized explicit scroll area can use its unique structural ancestor")
    func contentFrameAndKeyboard() throws {
        let fixture = makeFixture(keyboard: true)
        #expect(try admits(fixture))
        let snapshot = try snapshot(fixture.root)
        #expect(snapshot.elements.contains { $0.role == .scrollView && $0.actions.contains(.swipeWithin) })
        #expect(AgentModeKeyboardDetector.occlusion(in: snapshot, expectedPID: 1234, logicalSize: size)?.frame
            == CGRect(x: 0, y: 546, width: 402, height: 328))
    }

    @Test("Exact and descendant hits retain the existing path policy")
    func exactAndDescendantUseOriginalBranch() throws {
        let fixture = makeFixture()
        let tree = try snapshot(fixture.root)
        let area = try node(fixture.area)
        #expect(try !AgentModeCoarseScrollAdmission.validateIfAncestor(hit: area, area: area,
            start: start, ends: [end], snapshot: tree, logicalSize: size))
        let text = try node(fixture.area.children[0])
        #expect(try !AgentModeCoarseScrollAdmission.validateIfAncestor(hit: text, area: area,
            start: start, ends: [end], snapshot: tree, logicalSize: size))
        let chain = try AgentModePathIdentityPolicy.ancestorChain(hit: text, area: area,
            roots: [node(fixture.root)], snapshot: tree, usingNativeIdentity: true)
        #expect(chain == [0, 1, 2, 3])
    }

    @Test("An unrelated equal-frame Group cannot become ancestor evidence")
    func unrelatedHit() throws {
        var fixture = makeFixture()
        let unrelated = Node(type: "Group", key: 20, frame: fixture.hit.frame)
        fixture.root.children.append(unrelated)
        let tree = try snapshot(fixture.root)
        #expect(try !AgentModeCoarseScrollAdmission.validateIfAncestor(hit: node(unrelated), area: node(fixture.area),
            start: start, ends: [end], snapshot: tree, logicalSize: size))
        #expect(throws: AgentModeFailure.self) {
            try AgentModePathIdentityPolicy.ancestorChain(hit: node(unrelated), area: node(fixture.area),
                roots: [node(fixture.root)], snapshot: tree, usingNativeIdentity: true)
        }
    }

    @Test("Only an explicit ScrollArea and a noninteractive Group can use this branch")
    func explicitScope() throws {
        for type in ["Group", "Table", "Cell"] {
            var fixture = makeFixture()
            fixture.area.type = type
            fixture.hit.children = [fixture.area]; fixture.root.children = [fixture.hit]
            #expect(throws: AgentModeFailure.self) { try admits(fixture) }
        }
        var fixture = makeFixture()
        fixture.hit.type = "Button"; fixture.root.children = [fixture.hit]
        #expect(throws: AgentModeFailure.self) { try admits(fixture) }
    }

    @Test("Nested and overlapping scroll areas block the coarse hit, including hidden or disabled copies")
    func competingScrollContainers() throws {
        for type in ["ScrollArea", "Table", "Group"] {
            for state in 0...2 {
                var fixture = makeFixture()
                var rival = Node(type: type, key: 20, frame: Frame(x: 100, y: 200, width: 250, height: 400))
                if type == "Group" { rival.AXUniqueId = "fixture.scroll-view" }
                if state == 1 { rival.hidden = true }
                if state == 2 { rival.enabled = false }
                fixture.hit.children.append(rival); fixture.root.children = [fixture.hit]
                #expect(throws: AgentModeFailure.self) { try admits(fixture) }
            }
        }
        var nested = makeFixture()
        nested.area.children.append(Node(type: "ScrollArea", key: 21,
            frame: Frame(x: 100, y: 200, width: 250, height: 400)))
        nested.hit.children = [nested.area]; nested.root.children = [nested.hit]
        #expect(throws: AgentModeFailure.self) { try admits(nested) }
        var outer = makeFixture()
        outer.hit = Node(type: "Group", key: 2, frame: outer.hit.frame, children: [
            Node(type: "ScrollArea", key: 22, frame: outer.hit.frame, children: [outer.area])])
        outer.root.children = [outer.hit]
        #expect(throws: AgentModeFailure.self) { try admits(outer) }
    }

    @Test("Known external controls at the start block input; content controls and ordinary cells do not invent scroll areas")
    func overlayAndContent() throws {
        for type in ["Button", "TextField", "CheckBox", "Cell"] {
            var fixture = makeFixture()
            fixture.root.children.append(Node(type: type, key: 30,
                frame: Frame(x: 200, y: 430, width: 40, height: 40)))
            #expect(throws: AgentModeFailure.self) { try admits(fixture) }
        }
        var fixture = makeFixture()
        fixture.area.children.append(Node(type: "Cell", key: 31,
            frame: Frame(x: 200, y: 430, width: 40, height: 40)))
        fixture.hit.children = [fixture.area]; fixture.root.children = [fixture.hit]
        fixture.root.children.append(Node(type: "Button", key: 32,
            frame: Frame(x: 5, y: 70, width: 40, height: 40)))
        #expect(try admits(fixture))
    }

    @Test("Duplicate keys are refused before state and frame filters")
    func duplicateKeys() throws {
        for duplicateArea in [false, true] {
            var fixture = makeFixture()
            var duplicate = duplicateArea ? fixture.area : fixture.hit
            duplicate.frame = Frame(x: 0, y: 0, width: 1, height: 1)
            duplicate.hidden = true; duplicate.children = []
            fixture.root.children.append(duplicate)
            #expect(throws: AgentModeFailure.self) { try admits(fixture) }
        }
    }

    @Test("Incomplete native data, wrong ownership and hidden ownership chains refuse the branch")
    func ownershipAndCompleteness() throws {
        let fixture = makeFixture()
        #expect(throws: AgentModeFailure.self) { try admits(fixture, complete: false) }
        for variant in 0...4 {
            var changed = fixture
            if variant == 0 { changed.hit.pid = 4321; changed.hit.key = 40 }
            if variant == 1 { changed.hit.hidden = true }
            if variant == 2 { changed.hit.enabled = false }
            if variant == 3 { changed.hit.key = nil }
            if variant == 4 { changed.area.hidden = true; changed.hit.children = [changed.area] }
            changed.root.children = [changed.hit]
            #expect(throws: AgentModeFailure.self) { try admits(changed) }
        }
    }

    @Test("Changed target identity, frame and semantic state do not bind the old target")
    func changedTarget() throws {
        let original = makeFixture()
        for variant in 0...3 {
            var changed = original
            if variant == 0 { changed.area.key = 50 }
            if variant == 1 { changed.area.frame.x += 1 }
            if variant == 2 { changed.area.AXLabel = "Changed" }
            if variant == 3 { changed.area.enabled = false }
            changed.hit.children = [changed.area]; changed.root.children = [changed.hit]
            #expect(throws: AgentModeFailure.self) {
                try AgentModeCoarseScrollAdmission.validateIfAncestor(hit: node(original.hit), area: node(original.area),
                    start: start, ends: [end], snapshot: snapshot(changed.root), logicalSize: size)
            }
        }
    }

    @Test("The current display and observed keyboard restrict every endpoint")
    func viewportAndKeyboardBounds() throws {
        let fixture = makeFixture(keyboard: true)
        for point in [CGPoint(x: 211, y: 600), CGPoint(x: 211, y: 900), CGPoint(x: 500, y: 400),
                      CGPoint(x: CGFloat.infinity, y: 400)] {
            #expect(throws: AgentModeFailure.self) {
                try AgentModeCoarseScrollAdmission.validateIfAncestor(hit: node(fixture.hit), area: node(fixture.area),
                    start: start, ends: [point], snapshot: snapshot(fixture.root), logicalSize: size)
            }
        }
    }

    @Test("Shared scroll-container classification runs before availability and excludes cells")
    func sharedContainerClassification() {
        for type in ["ScrollArea", "AXScrollArea", "Table", "List", "Outline", "Collection"] {
            #expect(RuntimeSnapshotBuilder.hasPotentialScrollContainerAction(
                .init(type: type, frame: nil, enabled: false)))
        }
        #expect(RuntimeSnapshotBuilder.hasPotentialScrollContainerAction(
            .init(type: "Group", identifier: "fixture.scroll-view", enabled: false)))
        for type in ["Cell", "Row", "Button", "Application", "Group"] {
            #expect(!RuntimeSnapshotBuilder.hasPotentialScrollContainerAction(.init(type: type, enabled: false)))
        }
    }

    @Test("Background scroll branches do not compete with a unique hit-owned modal area")
    func backgroundScrollBranch() throws {
        var fixture = makeFixture(keyboard: true)
        let background = Node(type: "Group", key: 50, AXLabel: "Background",
            frame: Frame(x: 0, y: 0, width: 402, height: 874), children: [
                Node(type: "StaticText", key: 51, AXLabel: "Content",
                    frame: Frame(x: 0, y: -40, width: 200, height: 20))])
        fixture.root.children.insert(background, at: 0)
        let tree = try snapshot(fixture.root)
        let fallback = try #require(tree.elements.first { $0.label == "Background" })
        #expect(fallback.role == .other && fallback.actions.contains(.swipeWithin))
        #expect(try admits(fixture))
        fixture.root.children.append(Node(type: "ScrollArea", key: 52,
            frame: Frame(x: 0, y: 0, width: 402, height: 874)))
        #expect(try admits(fixture))
    }

    @Test("The same overlapping scroll container is refused when the native hit owns both branches")
    func broaderNativeHitStillRefuses() throws {
        var fixture = makeFixture()
        let rival = Node(type: "ScrollArea", key: 53,
            frame: Frame(x: 0, y: 0, width: 402, height: 874))
        fixture.hit.children.append(rival)
        fixture.root.children = [fixture.hit]
        #expect(throws: AgentModeFailure.self) { try admits(fixture) }
    }

    @Test("An explicit scroll ancestor above the native hit remains a competitor")
    func explicitOuterAboveHitStillRefuses() throws {
        var fixture = makeFixture()
        let outer = Node(type: "ScrollArea", key: 54,
            frame: Frame(x: 0, y: 0, width: 402, height: 874), children: [fixture.hit])
        fixture.root.children = [outer]
        #expect(throws: AgentModeFailure.self) { try admits(fixture) }
    }

    @Test("Known empty keyboard control frames cannot cover the swipe start")
    func emptyControls() throws {
        var fixture = makeFixture(keyboard: true)
        for index in 0..<6 {
            fixture.root.children[1].children.append(Node(type: "Button", key: UInt64(100 + index),
                frame: Frame(x: 0, y: 590, width: 0, height: 0)))
        }
        #expect(try admits(fixture))
        for empty in [Frame(x: 211, y: 443, width: 0, height: 40),
                      Frame(x: 211, y: 443, width: 40, height: 0)] {
            var current = fixture
            current.root.children.append(Node(type: "Button", key: 110, frame: empty))
            #expect(try admits(current))
        }
    }

    @Test("Missing, negative and nonfinite contender geometry still refuses, even with a zero dimension")
    func unsafeContenderGeometry() throws {
        let invalid = [CGRect(x: 211, y: 443, width: -1, height: 40),
            CGRect(x: 211, y: 443, width: 40, height: -1),
            CGRect(x: CGFloat.nan, y: 590, width: 0, height: 0),
            CGRect(x: 0, y: 590, width: CGFloat.infinity, height: 0)]
        for shape in invalid {
            #expect(throws: AgentModeFailure.self) {
                try AgentModeCoarseScrollAdmission.contenderContainsStart(shape, start: start)
            }
        }
        #expect(throws: AgentModeFailure.self) {
            try AgentModeCoarseScrollAdmission.contenderContainsStart(nil, start: start)
        }
        var fixture = makeFixture()
        var missing = Node(type: "Button", key: 112, frame: Frame(x: 0, y: 590, width: 0, height: 0))
        missing.omitFrame = true
        fixture.root.children.append(missing)
        #expect(throws: AgentModeFailure.self) { try admits(fixture) }
    }

    @Test("An empty background duplicate cannot hide a selected native-key ambiguity")
    func emptyDuplicateIdentity() throws {
        for duplicateArea in [false, true] {
            var fixture = makeFixture()
            var duplicate = duplicateArea ? fixture.area : fixture.hit
            duplicate.children = []; duplicate.frame = Frame(x: 0, y: 590, width: 0, height: 0)
            fixture.root.children.append(duplicate)
            #expect(throws: AgentModeFailure.self) { try admits(fixture) }
        }
    }

    private func admits(_ fixture: Fixture, complete: Bool = true) throws -> Bool {
        try AgentModeCoarseScrollAdmission.validateIfAncestor(hit: node(fixture.hit), area: node(fixture.area),
            start: start, ends: [end], snapshot: snapshot(fixture.root, complete: complete), logicalSize: size)
    }

    private func makeFixture(keyboard: Bool = false) -> Fixture {
        let text = Node(type: "StaticText", key: 4, frame: Frame(x: 195, y: 433, width: 32, height: 20))
        let area = Node(type: "ScrollArea", key: 3,
            frame: Frame(x: 16, y: 132, width: 370, height: 1455.3333314259846), children: [text])
        let hit = Node(type: "Group", key: 2, frame: Frame(x: 0, y: 62, width: 402, height: 812), children: [area])
        var root = Node(type: "Application", key: 1, frame: Frame(x: 0, y: 0, width: 402, height: 874), children: [hit])
        if keyboard {
            root.children.append(Node(type: "Group", key: 5, frame: Frame(x: 0, y: 546, width: 402, height: 328), children: [
                Node(type: "Button", key: 6, AXUniqueId: "shift", frame: Frame(x: 0, y: 700, width: 40, height: 40)),
                Node(type: "Button", key: 7, AXUniqueId: "delete", frame: Frame(x: 350, y: 700, width: 40, height: 40))]))
        }
        return Fixture(root: root, hit: hit, area: area)
    }

    private func snapshot(_ root: Node, complete: Bool = true) throws -> AgentModeSnapshot {
        try AgentModeSnapshot(roots: [node(root)],
            nativeIdentityMetadata: .init(complete: complete, reason: complete ? nil : "fixture"), context: context())
    }

    private func context() throws -> SelectedHIDContext {
        try JSONDecoder().decode(SelectedHIDContext.self, from: Data(
            #"{"bootIdentity":"boot","screenID":1,"screenUUID":"DF1FB281-4CCC-4A62-88D3-635D18FAD832","logicalWidth":402,"logicalHeight":874,"rotationDegrees":0,"nativePixelWidth":1206,"nativePixelHeight":2622,"scale":3,"poseRevision":"open"}"#.utf8))
    }

    private func node(_ value: Node) throws -> FBSimulatorAXNode {
        try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(value))
    }

    private struct Fixture { var root: Node; var hit: Node; var area: Node }
    private struct Frame: Encodable {
        var x: Double; var y: Double; var width: Double; var height: Double
    }
    private struct Node: Encodable {
        var type: String
        var key: UInt64?
        var AXUniqueId: String? = nil
        var AXLabel: String? = nil
        var frame: Frame
        var pid: Int32 = 1234
        var enabled = true
        var hidden = false
        var focused = false
        var omitFrame = false
        var children: [Node] = []
        private enum CodingKeys: String, CodingKey { case type, AXUniqueId, AXLabel, frame, pid, enabled, hidden, focused, children, nativeIdentity }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(type, forKey: .type); try values.encodeIfPresent(AXUniqueId, forKey: .AXUniqueId)
            try values.encodeIfPresent(AXLabel, forKey: .AXLabel)
            if !omitFrame { try values.encode(frame, forKey: .frame) }
            try values.encode(pid, forKey: .pid); try values.encode(enabled, forKey: .enabled)
            try values.encode(hidden, forKey: .hidden); try values.encode(focused, forKey: .focused)
            try values.encode(children, forKey: .children)
            if let key { try values.encode(FBSimulatorAXNativeIdentity(pid: pid, objectID: key), forKey: .nativeIdentity) }
        }
    }
}
