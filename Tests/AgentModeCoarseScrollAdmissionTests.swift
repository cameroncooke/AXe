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
        let area = try fixture.area.decoded()
        #expect(try !AgentModeCoarseScrollAdmission.validateIfAncestor(hit: area, area: area,
            start: start, ends: [end], snapshot: tree, logicalSize: size))
        let text = try #require(fixture.area.children?[0]).decoded()
        #expect(try !AgentModeCoarseScrollAdmission.validateIfAncestor(hit: text, area: area,
            start: start, ends: [end], snapshot: tree, logicalSize: size))
        let chain = try AgentModePathIdentityPolicy.ancestorChain(hit: text, area: area,
            roots: [fixture.root.decoded()], snapshot: tree, usingNativeIdentity: true)
        #expect(chain == [0, 1, 2, 3])
    }

    @Test("An unrelated equal-frame Group cannot become ancestor evidence")
    func unrelatedHit() throws {
        var fixture = makeFixture()
        let unrelated = node(type: "Group", key: 20, frame: fixture.hit.frame)
        fixture.root.children?.append(unrelated)
        let tree = try snapshot(fixture.root)
        #expect(try !AgentModeCoarseScrollAdmission.validateIfAncestor(hit: unrelated.decoded(), area: fixture.area.decoded(),
            start: start, ends: [end], snapshot: tree, logicalSize: size))
        #expect(throws: AgentModeFailure.self) {
            try AgentModePathIdentityPolicy.ancestorChain(hit: unrelated.decoded(), area: fixture.area.decoded(),
                roots: [fixture.root.decoded()], snapshot: tree, usingNativeIdentity: true)
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
                var rival = node(type: type, key: 20, frame: Frame(x: 100, y: 200, width: 250, height: 400))
                if type == "Group" { rival.identifier = "fixture.scroll-view" }
                if state == 1 { rival.hidden = true }
                if state == 2 { rival.enabled = false }
                fixture.hit.children?.append(rival); fixture.root.children = [fixture.hit]
                #expect(throws: AgentModeFailure.self) { try admits(fixture) }
            }
        }
        var nested = makeFixture()
        nested.area.children?.append(node(type: "ScrollArea", key: 21,
            frame: Frame(x: 100, y: 200, width: 250, height: 400)))
        nested.hit.children = [nested.area]; nested.root.children = [nested.hit]
        #expect(throws: AgentModeFailure.self) { try admits(nested) }
        var outer = makeFixture()
        outer.hit = node(type: "Group", key: 2, frame: outer.hit.frame, children: [
            node(type: "ScrollArea", key: 22, frame: outer.hit.frame, children: [outer.area])])
        outer.root.children = [outer.hit]
        #expect(throws: AgentModeFailure.self) { try admits(outer) }
    }

    @Test("Known external controls at the start block input; content controls and ordinary cells do not invent scroll areas")
    func overlayAndContent() throws {
        for type in ["Button", "TextField", "CheckBox", "Cell"] {
            var fixture = makeFixture()
            fixture.root.children?.append(node(type: type, key: 30,
                frame: Frame(x: 200, y: 430, width: 40, height: 40)))
            #expect(throws: AgentModeFailure.self) { try admits(fixture) }
        }
        var fixture = makeFixture()
        fixture.area.children?.append(node(type: "Cell", key: 31,
            frame: Frame(x: 200, y: 430, width: 40, height: 40)))
        fixture.hit.children = [fixture.area]; fixture.root.children = [fixture.hit]
        fixture.root.children?.append(node(type: "Button", key: 32,
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
            fixture.root.children?.append(duplicate)
            #expect(throws: AgentModeFailure.self) { try admits(fixture) }
        }
    }

    @Test("Incomplete native data, wrong ownership and hidden ownership chains refuse the branch")
    func ownershipAndCompleteness() throws {
        let fixture = makeFixture()
        #expect(throws: AgentModeFailure.self) { try admits(fixture, complete: false) }
        for variant in 0...4 {
            var changed = fixture
            if variant == 0 { changed.hit.pid = 4321; changed.hit.nativeObjectID = 40 }
            if variant == 1 { changed.hit.hidden = true }
            if variant == 2 { changed.hit.enabled = false }
            if variant == 3 { changed.hit.nativeObjectID = nil }
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
            if variant == 0 { changed.area.nativeObjectID = 50 }
            if variant == 1 { changed.area.frame?.x += 1 }
            if variant == 2 { changed.area.label = "Changed" }
            if variant == 3 { changed.area.enabled = false }
            changed.hit.children = [changed.area]; changed.root.children = [changed.hit]
            #expect(throws: AgentModeFailure.self) {
                try AgentModeCoarseScrollAdmission.validateIfAncestor(hit: original.hit.decoded(), area: original.area.decoded(),
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
                try AgentModeCoarseScrollAdmission.validateIfAncestor(hit: fixture.hit.decoded(), area: fixture.area.decoded(),
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
        let background = node(type: "Group", key: 50, label: "Background",
            frame: Frame(x: 0, y: 0, width: 402, height: 874), children: [
                node(type: "StaticText", key: 51, label: "Content",
                    frame: Frame(x: 0, y: -40, width: 200, height: 20))])
        fixture.root.children?.insert(background, at: 0)
        let tree = try snapshot(fixture.root)
        let fallback = try #require(tree.elements.first { $0.label == "Background" })
        #expect(fallback.role == .other && fallback.actions.contains(.swipeWithin))
        #expect(try admits(fixture))
        fixture.root.children?.append(node(type: "ScrollArea", key: 52,
            frame: Frame(x: 0, y: 0, width: 402, height: 874)))
        #expect(try admits(fixture))
    }

    @Test("The same overlapping scroll container is refused when the native hit owns both branches")
    func broaderNativeHitStillRefuses() throws {
        var fixture = makeFixture()
        let rival = node(type: "ScrollArea", key: 53,
            frame: Frame(x: 0, y: 0, width: 402, height: 874))
        fixture.hit.children?.append(rival)
        fixture.root.children = [fixture.hit]
        #expect(throws: AgentModeFailure.self) { try admits(fixture) }
    }

    @Test("An explicit scroll ancestor above the native hit remains a competitor")
    func explicitOuterAboveHitStillRefuses() throws {
        var fixture = makeFixture()
        let outer = node(type: "ScrollArea", key: 54,
            frame: Frame(x: 0, y: 0, width: 402, height: 874), children: [fixture.hit])
        fixture.root.children = [outer]
        #expect(throws: AgentModeFailure.self) { try admits(fixture) }
    }

    @Test("Known empty keyboard control frames cannot cover the swipe start")
    func emptyControls() throws {
        var fixture = makeFixture(keyboard: true)
        for index in 0..<6 {
            fixture.root.children?[1].children?.append(node(type: "Button", key: UInt64(100 + index),
                frame: Frame(x: 0, y: 590, width: 0, height: 0)))
        }
        #expect(try admits(fixture))
        for empty in [Frame(x: 211, y: 443, width: 0, height: 40),
                      Frame(x: 211, y: 443, width: 40, height: 0)] {
            var current = fixture
            current.root.children?.append(node(type: "Button", key: 110, frame: empty))
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
        var missing = node(type: "Button", key: 112, frame: Frame(x: 0, y: 590, width: 0, height: 0))
        missing.frame = nil
        fixture.root.children?.append(missing)
        #expect(throws: AgentModeFailure.self) { try admits(fixture) }
    }

    @Test("An empty background duplicate cannot hide a selected native-key ambiguity")
    func emptyDuplicateIdentity() throws {
        for duplicateArea in [false, true] {
            var fixture = makeFixture()
            var duplicate = duplicateArea ? fixture.area : fixture.hit
            duplicate.children = []; duplicate.frame = Frame(x: 0, y: 590, width: 0, height: 0)
            fixture.root.children?.append(duplicate)
            #expect(throws: AgentModeFailure.self) { try admits(fixture) }
        }
    }

    private func admits(_ fixture: Fixture, complete: Bool = true) throws -> Bool {
        try AgentModeCoarseScrollAdmission.validateIfAncestor(hit: fixture.hit.decoded(), area: fixture.area.decoded(),
            start: start, ends: [end], snapshot: snapshot(fixture.root, complete: complete), logicalSize: size)
    }

    private func makeFixture(keyboard: Bool = false) -> Fixture {
        let text = node(type: "StaticText", key: 4, frame: Frame(x: 195, y: 433, width: 32, height: 20))
        let area = node(type: "ScrollArea", key: 3,
            frame: Frame(x: 16, y: 132, width: 370, height: 1455.3333314259846), children: [text])
        let hit = node(type: "Group", key: 2, frame: Frame(x: 0, y: 62, width: 402, height: 812), children: [area])
        var root = node(type: "Application", key: 1, frame: Frame(x: 0, y: 0, width: 402, height: 874), children: [hit])
        if keyboard {
            root.children?.append(node(type: "Group", key: 5, frame: Frame(x: 0, y: 546, width: 402, height: 328), children: [
                node(type: "Button", key: 6, id: "shift", frame: Frame(x: 0, y: 700, width: 40, height: 40)),
                node(type: "Button", key: 7, id: "delete", frame: Frame(x: 350, y: 700, width: 40, height: 40))]))
        }
        return Fixture(root: root, hit: hit, area: area)
    }

    private func snapshot(_ root: AXNodeFixture, complete: Bool = true) throws -> AgentModeSnapshot {
        try AgentModeSnapshot(roots: [root.decoded()],
            nativeIdentityMetadata: .init(complete: complete, reason: complete ? nil : "fixture"), context: context())
    }

    private func context() throws -> SelectedHIDContext {
        try .fixture(boot: "boot", screenID: 1, screenUUID: "DF1FB281-4CCC-4A62-88D3-635D18FAD832", width: 402,
            height: 874, rotation: 0, pixelWidth: 1206, pixelHeight: 2622, pose: "open")
    }

    private struct Fixture { var root: AXNodeFixture; var hit: AXNodeFixture; var area: AXNodeFixture }
    private typealias Frame = AXNodeFixture.Frame
}

/// `key` becomes the native identity with the node's `pid` at encode time.
private func node(type: String, key: UInt64?, id: String? = nil, label: String? = nil, frame: AXNodeFixture.Frame?,
                  children: [AXNodeFixture] = []) -> AXNodeFixture {
    AXNodeFixture(type: type, identifier: id, label: label, frame: frame, pid: 1234, focused: false, enabled: true,
        hidden: false, nativeObjectID: key, children: children)
}
