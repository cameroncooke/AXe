import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

/// Long press, double tap and two-finger tap on `tap`; the drag hold; scroll distance, the Control
/// Centre preset and scrolling until an element is on screen.
@Suite("Gesture conveniences")
struct GestureConvenienceTests {
    private let udid = "00000000-0000-0000-0000-000000000001"

    // MARK: tap --hold, --count, --touches

    @Test func aPlainTapIsNotATouchGesture() throws {
        #expect(try !Tap.parse(["-x", "10", "-y", "20", "--udid", udid]).isTouchGesture)
        #expect(try Tap.parse(["--id", "Photo", "--hold", "1", "--udid", udid]).isTouchGesture)
    }

    @Test func eachTapGestureRunsTheCommandThatSendsIt() throws {
        let long = try Tap.parse(["--label", "Photo", "--hold", "1.5", "--udid", udid])
        #expect(long.simulatorGestureArguments(at: (100, 200))
            == ["touch", "-x", "100.0", "-y", "200.0", "--down", "--up", "--delay", "1.5", "--udid", udid])
        let double = try Tap.parse(["--id", "Map", "--count", "2", "--udid", udid])
        #expect(double.simulatorGestureArguments(at: (100, 200))
            == ["gesture", "double-tap", "-x", "100.0", "-y", "200.0", "--udid", udid])
        let two = try Tap.parse(["-x", "100", "-y", "200", "--touches", "2", "--udid", udid])
        #expect(two.simulatorGestureArguments(at: (100, 200))
            == ["gesture", "two-finger-tap", "-x", "80.0", "-y", "200.0", "--x2", "120.0", "--y2", "200.0", "--udid", udid])
        let twoHeld = try Tap.parse(["-x", "100", "-y", "200", "--touches", "2", "--hold", "0.8", "--udid", udid])
        #expect(twoHeld.simulatorGestureArguments(at: (100, 200)).prefix(2) == ["gesture", "two-finger-hold"])
        #expect(twoHeld.simulatorGestureArguments(at: (100, 200)).contains("0.8"))
        // Every generated command parses, so its own validation accepts it.
        for tap in [long, double, two, twoHeld] {
            let arguments = tap.simulatorGestureArguments(at: (100, 200))
            if arguments[0] == "touch" { _ = try Touch.parse(Array(arguments.dropFirst())) }
            else { _ = try Gesture.parse(Array(arguments.dropFirst())) }
        }
    }

    @Test func twoContactsStayOnTheScreenAtItsLeftEdge() {
        #expect(Tap.contacts(at: CGPoint(x: 5, y: 50), touches: 2) == [CGPoint(x: 0, y: 50), CGPoint(x: 40, y: 50)])
        #expect(Tap.contacts(at: CGPoint(x: 5, y: 50), touches: 1) == [CGPoint(x: 5, y: 50)])
    }

    @Test func aDeviceLongPressDoubleTapAndTwoFingerTapHaveTheRightContacts() throws {
        let long = try Tap.parse(["-x", "100", "-y", "200", "--hold", "1", "--udid", udid]).deviceSteps(at: CGPoint(x: 100, y: 200))
        #expect(long.map(\.phase) == [.down, .up] && long[0].delayAfter == 1 && long[0].points.count == 1)
        let double = try Tap.parse(["-x", "100", "-y", "200", "--count", "2", "--udid", udid]).deviceSteps(at: CGPoint(x: 100, y: 200))
        #expect(double.map(\.phase) == [.down, .up, .down, .up] && double[1].delayAfter == 0.1 && double[3].delayAfter == 0)
        let two = try Tap.parse(["-x", "100", "-y", "200", "--touches", "2", "--udid", udid]).deviceSteps(at: CGPoint(x: 100, y: 200))
        #expect(two.count == 2 && two[0].points == [CGPoint(x: 80, y: 200), CGPoint(x: 120, y: 200)])
    }

    @Test(arguments: [
        ["-x", "1", "-y", "2", "--hold", "0"], ["-x", "1", "-y", "2", "--hold", "11"],
        ["-x", "1", "-y", "2", "--count", "3"], ["-x", "1", "-y", "2", "--touches", "3"],
        ["-x", "1", "-y", "2", "--count", "2", "--touches", "2"],
        ["-x", "1", "-y", "2", "--hold", "1", "--tap-style", "simulator"],
        ["--id", "a", "--hold", "1", "--input-mode", "selected"],
    ])
    func tapGestureOptionsThatAreRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { _ = try Tap.parse(arguments + ["--udid", udid]) }
    }

    // MARK: drag --hold

    @Test func aDragHoldRestsOnTheStartBeforeTheFirstMove() throws {
        let drag = try Drag.parse(["--start-x", "10", "--start-y", "10", "--end-x", "10", "--end-y", "110", "--hold", "0.6", "--udid", udid])
        let path = drag.selectedPath
        try path.validate()
        #expect(path.hold == 0.6 && path.initialHold == 0.6)
        let primitives = try path.primitives(logicalSize: CGSize(width: 400, height: 800))
        guard case .down = primitives[0].kind, case .delay = primitives[1].kind else {
            Issue.record("A drag starts with a touch down and its hold"); return
        }
        #expect(primitives[1].duration == 0.6)
        let plain = try Drag.parse(["--start-x", "10", "--start-y", "10", "--end-x", "10", "--end-y", "110", "--udid", udid]).selectedPath
        #expect(plain.hold == nil && plain.initialHold == Drag.initialHold)
        #expect(try plain.primitives(logicalSize: CGSize(width: 400, height: 800))[1].duration == Drag.initialHold)
    }

    @Test func aHoldIsADragOptionWithinTenSeconds() {
        #expect(throws: (any Error).self) {
            _ = try Drag.parse(["--start-x", "1", "--start-y", "1", "--end-x", "9", "--end-y", "9", "--hold", "11", "--udid", udid])
        }
        var swipe = SelectedHIDPath(kind: .swipe, startX: 1, startY: 1, endX: 9, endY: 9, duration: 1, delta: 5)
        swipe.hold = 0.5
        #expect(throws: (any Error).self) { try swipe.validate() }
    }

    // MARK: scroll distance and the Control Centre preset

    @Test func aScrollDistanceIsAFractionOfTheAxisItMovesAlong() {
        let down = GesturePreset.scrollDown.coordinates(screenWidth: 400, screenHeight: 800, distance: 0.5)
        #expect(down.startX == 200 && down.endX == 200 && down.endY - down.startY == 400)
        let left = GesturePreset.scrollLeft.coordinates(screenWidth: 400, screenHeight: 800, distance: 0.5)
        #expect(left.startX - left.endX == 200 && left.startY == 400)
        // Without a distance a scroll keeps its 200 points.
        let plain = GesturePreset.scrollUp.coordinates(screenWidth: 400, screenHeight: 800)
        #expect(plain.startY - plain.endY == 200)
    }

    @Test func aDistanceIsForScrollPresetsOnly() throws {
        _ = try Gesture.parse(["scroll-down", "--distance", "0.8", "--udid", udid])
        for arguments in [["scroll-down", "--distance", "1.2"], ["swipe-from-left-edge", "--distance", "0.5"],
                          ["pinch", "--scale", "2", "--distance", "0.5"]] {
            #expect(throws: (any Error).self) { _ = try Gesture.parse(arguments + ["--udid", udid]) }
        }
        let path = try Gesture.parse(["scroll-down", "--distance", "0.8", "--udid", udid]).selectedPath()
        #expect(path.distance == 0.8)
        try path.validate()
    }

    @Test func theTopRightCornerPresetSwipesDownInsideTheRightEdge() throws {
        let command = try Gesture.parse(["swipe-from-top-right-corner", "--udid", udid])
        guard case .preset(let preset) = command.gesture else { Issue.record("Not a preset"); return }
        let points = preset.coordinates(screenWidth: 400, screenHeight: 800)
        #expect(points.startX == 370 && points.endX == 370 && points.startY == 20 && points.endY == 400)
        #expect(!preset.isScroll)
    }

    // MARK: scroll until an element is on screen

    @Test func untilOptionsNeedAScrollPresetAndPlainInput() throws {
        _ = try Gesture.parse(["scroll-down", "--until-id", "row-40", "--max-swipes", "20", "--udid", udid])
        _ = try Gesture.parse(["scroll-left", "--inside-id", "Drawing-Palette", "--until-label", "Watercolor", "--udid", udid])
        for arguments in [["scroll-down", "--until-id", "a", "--until-label", "b"], ["scroll-down", "--max-swipes", "5"],
                          ["swipe-from-left-edge", "--until-id", "a"], ["scroll-down", "--until-id", "a", "--max-swipes", "0"],
                          ["scroll-down", "--until-id", "a", "--input-mode", "selected"],
                          ["scroll-down", "--inside-id", "a", "--inside-label", "b"], ["pinch", "--scale", "2", "--inside-id", "a"]] {
            #expect(throws: (any Error).self) { _ = try Gesture.parse(arguments + ["--udid", udid]) }
        }
    }

    @Test func aSwipeCanRepeatUntilAnElementIsOnScreen() throws {
        let line = ["--start-x", "300", "--start-y", "800", "--end-x", "100", "--end-y", "800"]
        let swipe = try Swipe.parse(line + ["--until-label", "Watercolor", "--max-swipes", "6", "--udid", udid])
        #expect(swipe.until.maxSwipes == 6)
        guard case .label("Watercolor")? = swipe.until.query else { Issue.record("No label query"); return }
        #expect(throws: (any Error).self) { _ = try Swipe.parse(line + ["--until-id", "a", "--input-mode", "selected", "--udid", udid]) }
        #expect(throws: (any Error).self) { _ = try Swipe.parse(line + ["--max-swipes", "3", "--udid", udid]) }
    }

    /// A list that moves one step with every scroll, up to `length` steps, and shows the element after
    /// `shownAfter` scrolls.
    private final class FakeList {
        var scrolls = 0, reads = 0
        let shownAfter: Int?, length: Int
        init(shownAfter: Int?, length: Int = .max) { self.shownAfter = shownAfter; self.length = length }
        func observe() -> ScrollUntilOptions.Observation {
            reads += 1
            return .init(visible: shownAfter.map { scrolls >= $0 } ?? false, signature: "position \(min(scrolls, length))")
        }
    }

    @Test func scrollingStopsAtTheFirstRestingReadThatSeesTheElement() async throws {
        let until = try Gesture.parse(["scroll-down", "--until-label", "Row 40", "--udid", udid]).until
        let list = FakeList(shownAfter: 2)
        try await until.run(.label("Row 40"), observe: { list.observe() }, scroll: { list.scrolls += 1 })
        // Every look is two matching reads: before the first scroll and after each of the two.
        #expect(list.scrolls == 2 && list.reads == 6)
        // Already on screen: no input at all.
        let shown = FakeList(shownAfter: 0)
        try await until.run(.label("Row 40"), observe: { shown.observe() }, scroll: { shown.scrolls += 1 })
        #expect(shown.scrolls == 0 && shown.reads == 2)
        // On a physical device one read is slower than the glide, so each look is one read.
        let device = FakeList(shownAfter: 2)
        try await until.run(.label("Row 40"), waitsForRest: false, observe: { device.observe() }, scroll: { device.scrolls += 1 })
        #expect(device.scrolls == 2 && device.reads == 3)
    }

    @Test func anElementIsJudgedOnlyOnceTheContentRests() async throws {
        let until = try Gesture.parse(["scroll-down", "--until-label", "Row 40", "--udid", udid]).until
        // The element is in view while the content glides for three reads, and gone when it comes to rest.
        var reads = 0, scrolls = 0
        try await until.run(.label("Row 40"), observe: {
            reads += 1
            if scrolls == 0 { return .init(visible: reads < 4, signature: "gliding \(min(reads, 4))") }
            return .init(visible: true, signature: "after a scroll")
        }, scroll: { scrolls += 1 })
        // Seen mid-glide does not count: it scrolled once more and found it at rest.
        #expect(scrolls == 1 && reads == 7)
    }

    @Test func scrollingGivesUpAfterTheLimitWithElementNotFound() async throws {
        let until = try Gesture.parse(["scroll-down", "--until-id", "missing", "--max-swipes", "2", "--udid", udid]).until
        let list = FakeList(shownAfter: nil)
        do {
            try await until.run(.id("missing"), observe: { list.observe() }, scroll: { list.scrolls += 1 })
            Issue.record("A missing element was reported as found")
        } catch let error as CLIError {
            #expect(error.code == .elementNotFound && error.errorDescription.contains("2 scrolls"))
        }
        #expect(list.scrolls == 2 && list.reads == 6)
    }

    @Test func scrollingStopsWhenAScrollMovesNothing() async throws {
        let until = try Gesture.parse(["scroll-left", "--until-label", "Missing", "--max-swipes", "20", "--udid", udid]).until
        // The content moves twice, then is at its end: the third scroll changes nothing.
        let list = FakeList(shownAfter: nil, length: 2)
        do {
            try await until.run(.label("Missing"), observe: { list.observe() }, scroll: { list.scrolls += 1 })
            Issue.record("A missing element was reported as found")
        } catch let error as CLIError {
            #expect(error.code == .elementNotFound && error.errorDescription.contains("stopped moving after 2 scrolls"))
        }
        // It does not keep bouncing the content against its end for the other 17 scrolls.
        #expect(list.scrolls == 3 && list.reads == 8)
    }

    @Test func aScreenSignatureChangesWhenAnElementMoves() throws {
        func tree(y: Int) throws -> [AccessibilityElement] {
            try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
                [{"type":"Application","frame":{"x":0,"y":0,"width":400,"height":800},"children":[
                  {"type":"Button","AXLabel":"Row","frame":{"x":0,"y":\(y),"width":400,"height":44}}]}]
                """.utf8))
        }
        #expect(ScrollUntilOptions.signature(of: try tree(y: 100)) == ScrollUntilOptions.signature(of: try tree(y: 100)))
        #expect(ScrollUntilOptions.signature(of: try tree(y: 100)) != ScrollUntilOptions.signature(of: try tree(y: 60)))
    }

    @Test func anElementOwnsItsCentreWhenTheLookupFindsItItsParentOrItsOwnPart() throws {
        func elements(_ json: String) throws -> [AccessibilityElement] {
            try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
        }
        let row = try elements("""
            [{"type":"Cell","AXUniqueId":"row-5","frame":{"x":0,"y":100,"width":400,"height":44},"children":[
              {"type":"StaticText","AXLabel":"Row 5","frame":{"x":16,"y":110,"width":80,"height":24}}]}]
            """)[0]
        // The lookup at a row's centre returns its label.
        let label = try elements(#"[{"type":"StaticText","AXLabel":"Row 5","frame":{"x":16,"y":110,"width":80,"height":24}}]"#)
        #expect(ScrollUntilOptions.owns(row, hit: label))
        #expect(ScrollUntilOptions.owns(row, hit: [row]))
        // A lookup at a point can give the same element another type.
        let asButton = try elements(#"[{"type":"Button","AXUniqueId":"row-5","frame":{"x":0,"y":100,"width":400,"height":44}}]"#)
        #expect(ScrollUntilOptions.owns(row, hit: asButton))
        // The lookup returns a container that holds the row.
        let table = try elements("""
            [{"type":"Table","frame":{"x":0,"y":0,"width":400,"height":800},"children":[
              {"type":"Cell","AXUniqueId":"row-5","frame":{"x":0,"y":100,"width":400,"height":44}}]}]
            """)
        #expect(ScrollUntilOptions.owns(row, hit: table))
        // Another control covers the centre.
        let cover = try elements(#"[{"type":"Button","AXLabel":"Color picker","frame":{"x":0,"y":100,"width":400,"height":44}}]"#)
        #expect(!ScrollUntilOptions.owns(row, hit: cover))
        // The same kind of element somewhere else is not this one.
        let other = try elements(#"[{"type":"StaticText","AXLabel":"Row 5","frame":{"x":16,"y":300,"width":80,"height":24}}]"#)
        #expect(!ScrollUntilOptions.owns(row, hit: other))
    }
}
