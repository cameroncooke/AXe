import AXeCore
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Agent reference swipe planning")
struct AgentModeSwipePlannerTests {
    private let standard: AgentModeSwipePlanner.Points = (.init(x: 201, y: 705), .init(x: 201, y: 532))
    private let viewport = CGSize(width: 402, height: 874)
    private let area = Frame(x: 8, y: 370.21724709784417, width: 386, height: 495.78275290215583)
    private let distance = Node(type: "StaticText", AXLabel: "Distance",
        frame: Frame(x: 42.56716417910448, y: 691.723880597015,
                     width: 57.61194029850746, height: 17.28358208955217))

    @Test("The retained Settings geometry starts on its real text descendant and keeps the original stroke")
    func settingsTextAnchorKeepsTheStroke() throws {
        let fixture = try makeFixture(children: [distance])
        let planned = try plan(fixture)
        #expect(planned.from == AgentPoint(x: 71, y: 700))
        #expect(planned.to == AgentPoint(x: 71, y: 527))
        #expect(planned.to.y - planned.from.y == standard.to.y - standard.from.y)
        #expect(fixture.target.frame?.contains(CGPoint(x: planned.to.x, y: planned.to.y)) == true)
    }

    @Test("An original start already on a unique safe descendant stays exact")
    func existingSafeStartIsNotMoved() throws {
        var leaf = distance
        leaf.frame = Frame(x: 190, y: 695, width: 30, height: 20)
        let planned = try plan(makeFixture(children: [leaf]))
        #expect(planned.from == standard.from && planned.to == standard.to)
    }

    @Test("Text inside controls, nested scrolling, hidden containers or disabled state cannot anchor input")
    func unsafeDescendantsAreNotUsed() throws {
        let button = Node(type: "Button", AXLabel: "Press", frame: area, children: [distance])
        let nested = Node(type: "ScrollArea", AXUniqueId: "nested", frame: area, children: [distance])
        let hidden = Node(type: "Group", frame: area, hidden: true, children: [distance])
        let disabled = Node(type: "Group", frame: area, enabled: false, children: [distance])
        var hiddenLeaf = distance; hiddenLeaf.hidden = true
        var disabledLeaf = distance; disabledLeaf.enabled = false
        var foreignLeaf = distance; foreignLeaf.pid = 999
        for child in [button, nested, hidden, disabled, hiddenLeaf, disabledLeaf, foreignLeaf] {
            let planned = try plan(makeFixture(children: [child]))
            #expect(planned.from == standard.from && planned.to == standard.to)
        }
        let duplicate = try plan(makeFixture(children: [distance, distance]))
        #expect(duplicate.from == standard.from && duplicate.to == standard.to)
    }

    @Test("Both translated ends must remain in the target area and current display")
    func outOfBoundsAnchorsKeepTheStandardPath() throws {
        var tooHigh = distance
        tooHigh.frame = Frame(x: 60, y: 390, width: 20, height: 20)
        let areaRefusal = try plan(makeFixture(children: [tooHigh]))
        #expect(areaRefusal.from == standard.from && areaRefusal.to == standard.to)
        let clippedDisplay = try plan(makeFixture(children: [distance]), viewport: CGSize(width: 874, height: 402))
        #expect(clippedDisplay.from == standard.from && clippedDisplay.to == standard.to)
        for shape in [CGSize.zero, CGSize(width: -1, height: 874), CGSize(width: CGFloat.infinity, height: 874)] {
            #expect(throws: (any Error).self) { try plan(makeFixture(children: [distance]), viewport: shape) }
        }
    }

    @Test("Up, down, left and right retain the exact requested movement vector")
    func allDirectionsUseTheSameTranslation() throws {
        let wide = Frame(x: 0, y: 0, width: 600, height: 800)
        let leaf = Node(type: "StaticText", AXLabel: "Output", frame: Frame(x: 290, y: 390, width: 20, height: 20))
        let fixture = try makeFixture(children: [leaf], frame: wide)
        let paths: [AgentModeSwipePlanner.Points] = [
            (.init(x: 300, y: 600), .init(x: 300, y: 400)),
            (.init(x: 300, y: 200), .init(x: 300, y: 400)),
            (.init(x: 450, y: 400), .init(x: 250, y: 400)),
            (.init(x: 150, y: 400), .init(x: 350, y: 400)),
        ]
        for original in paths {
            let planned = try plan(fixture, standard: original, viewport: CGSize(width: 600, height: 800))
            #expect(planned.from == AgentPoint(x: 300, y: 400))
            #expect(planned.to.x - planned.from.x == original.to.x - original.from.x)
            #expect(planned.to.y - planned.from.y == original.to.y - original.from.y)
        }
    }

    @Test("Equal-distance safe text uses native tree order and absent anchors keep the original path")
    func selectionIsDeterministicWithoutFallbackInput() throws {
        let wide = Frame(x: 0, y: 0, width: 600, height: 800)
        let left = Node(type: "StaticText", AXLabel: "Left", frame: Frame(x: 90, y: 390, width: 20, height: 20))
        let right = Node(type: "StaticText", AXLabel: "Right", frame: Frame(x: 490, y: 390, width: 20, height: 20))
        let original: AgentModeSwipePlanner.Points = (.init(x: 300, y: 600), .init(x: 300, y: 400))
        let planned = try plan(makeFixture(children: [left, right], frame: wide), standard: original,
            viewport: CGSize(width: 600, height: 800))
        #expect(planned.from == AgentPoint(x: 100, y: 400))
        #expect(planned.to == AgentPoint(x: 100, y: 200))
        let empty = try plan(makeFixture(children: []))
        #expect(empty.from == standard.from && empty.to == standard.to)
    }

    @Test("A stroke that would start on a text field moves to the nearest start clear of it")
    func strokeStartsClearOfTextFields() throws {
        // On a form a drag that starts on a field edits or focuses it and nothing scrolls.
        let field = Node(type: "TextField", AXLabel: "First name", frame: Frame(x: 36, y: 690, width: 330, height: 30))
        let other = Node(type: "TextField", AXLabel: "Last name", frame: Frame(x: 36, y: 760, width: 330, height: 30))
        let planned = try plan(makeFixture(children: [field, other]))
        // The nearest clear start on the same line: 6 pt below the field (720), 21 pt from the
        // planned start, against 22 pt to clear its top edge. The movement is unchanged.
        #expect(planned.from == AgentPoint(x: 201, y: 726), "\(planned)")
        #expect(planned.to.y - planned.from.y == standard.to.y - standard.from.y)
        #expect(planned.to.x == planned.from.x)

        // A stroke that already starts clear of every field stays exact.
        var lower = field
        lower.frame = Frame(x: 36, y: 800, width: 330, height: 30)
        let untouched = try plan(makeFixture(children: [lower]))
        #expect(untouched.from == standard.from && untouched.to == standard.to)
    }

    private func plan(_ fixture: Fixture, standard: AgentModeSwipePlanner.Points? = nil,
                      viewport: CGSize? = nil) throws -> AgentModeSwipePlanner.Points {
        try AgentModeSwipePlanner.points(standard: standard ?? self.standard, target: fixture.target,
            snapshot: fixture.snapshot, logicalSize: viewport ?? self.viewport)
    }

    private struct Fixture { let snapshot: AgentModeSnapshot; let target: FBSimulatorAXNode }
    private func makeFixture(children: [Node], frame: Frame? = nil) throws -> Fixture {
        let target = Node(type: "ScrollArea", AXUniqueId: "area", frame: frame ?? area, children: children)
        let root = Node(type: "Application", AXLabel: "Example", frame: Frame(x: 0, y: 0, width: 1000, height: 1000),
            children: [target])
        let native = try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(root))
        let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "00000000-0000-0000-0000-000000000001",
            bootIdentity: "test-boot", screenID: 1, screenUniqueID: "5D3C4CC2-87E2-4A57-AB7B-565B1B4F14F9", axDisplayID: 1,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 1,
                nativePixelSize: CGSize(width: 3000, height: 3000), scale: 3, rotation: .rot0), poseRevision: "rigid")
        return Fixture(snapshot: try AgentModeSnapshot(roots: [native], context: SelectedHIDContext(observation)),
            target: native.children[0])
    }

    private struct Frame: Encodable { var x: Double; var y: Double; var width: Double; var height: Double }
    private struct Node: Encodable {
        var type: String
        var AXUniqueId: String? = nil
        var AXLabel: String? = nil
        var frame: Frame
        var pid: Int32 = 2934
        var enabled = true
        var hidden = false
        var children: [Node] = []
    }
}
