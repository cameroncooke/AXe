import Foundation
import Testing

@Suite("Playground Duo Scrolling", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoScrollCoverageTests {
    @Test("Default legacy scroll after outer rotation reveals and activates a new row")
    func defaultOuterLandscapeScroll() async throws {
        try await withDuoPlaygroundScreen(pose: .closed, rotation: 90) {
            let app = try CorePlaygroundSession()
            let before = try await app.open("long-scroll-test", readyID: "long-scroll-test-scroll-view")
            let list = try app.frame(of: app.element("long-scroll-test-scroll-view", in: before))
            let previous = try #require(app.visibleRows(in: before, listFrame: list).max())
            // These are the public defaults. Do not repair their coordinates in this check.
            try await app.run(["gesture", "scroll-up"])
            _ = try await app.waitFor("a newly revealed list row after default scroll") {
                app.visibleRows(in: $0, listFrame: list).contains { $0 > previous }
            }
            // A tap while the list still coasts only stops the scroll, so tap once it has settled.
            try await TestHelpers.waitForSettledAccessibility(simulatorUDID: app.simulatorUDID,
                description: "long scroll list after default scroll")
            let after = try await app.state()
            let row = try #require(app.visibleRows(in: after, listFrame: list).filter { $0 > previous }.min())
            try await app.run(["tap", "--id", "long-scroll-test-row-\(row)"])
            try await app.waitForValue("long-scroll-test-state", equals: "Row \(row)")
        }
    }

    @Test("Nested list scrolls both ways while the page stays fixed", arguments: DuoControlsPosition.allCases)
    func nestedList(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            try await app.show("feature.showList")
            let frame = try await app.frame("feature.list")
            let before = try app.documents.read()
            let originalRows = try await rowFrames(app)
            let x = frame.x + frame.width / 2
            let y = frame.y + frame.height / 2
            try await motion(app, start: (x, y + 40), end: (x, y - 40))
            let down = try await app.documents.waitFor("list content moved down 70 points and released") {
                abs($0.listOffsetY - 70) <= 2 && $0.activeWindowTouches == 0
            }
            try #require(down.pageOffsetY == before.pageOffsetY)
            try verifyRows(try await rowFrames(app), original: originalRows, displacement: down.listOffsetY - before.listOffsetY)
            try await motion(app, start: (x, y - 40), end: (x, y + 40))
            let up = try await app.documents.waitFor("list returned to its initial offset and released") {
                abs($0.listOffsetY) <= 2 && $0.activeWindowTouches == 0
            }
            try #require(up.pageOffsetY == before.pageOffsetY)
            try verifyRows(try await rowFrames(app), original: originalRows, displacement: up.listOffsetY - before.listOffsetY)
            try controlsScrollUnchanged(up, before: before)
            try up.requireClear()
            try app.preserveState("nested-final")
        }
    }

    @Test("Page scroll preserves nested content and controls", arguments: [DuoControlsPosition.outer90, .outer270])
    func page(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.mainScroll")
            let before = try app.documents.read()
            let x = frame.x + 4 // A visible page gutter, outside the nested controls.
            let y = frame.y + frame.height / 2
            for (forward, expected) in [(true, 50.0), (true, 100.0), (false, 50.0)] {
                let start = (x, y + (forward ? 30 : -30))
                let end = (x, y + (forward ? -30 : 30))
                try await motion(app, start: start, end: end)
                let after = try await app.documents.waitFor("settled page offset \(expected)") {
                    abs($0.pageOffsetY - expected) <= 2 && $0.activeWindowTouches == 0
                }
                try #require(after.listOffsetY == before.listOffsetY && after.canvasOffsetX == before.canvasOffsetX && after.canvasOffsetY == before.canvasOffsetY)
                try controlsScrollUnchanged(after, before: before)
                try after.requireClear()
            }
            try app.preserveState("page-final")
        }
    }

    @Test("Canvas scrolls in all four directions", arguments: [DuoControlsPosition.outer0, .inner90])
    func fourWayCanvas(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            try await app.show("feature.showCanvas")
            let frame = try await app.frame("feature.canvas")
            let catalogue = app.catalogue.activePanel
            let width = catalogue.boundsWidth
            let height = catalogue.boundsHeight
            let x = max(frame.x + 110, min(frame.x + frame.width / 2, width - 110))
            let y = max(frame.y + 110, min(frame.y + frame.height / 2, height - 110))
            let before = try app.documents.read()
            for (dx, dy) in [(-160.0, 0.0), (160.0, 0.0), (0.0, -160.0), (0.0, 160.0)] {
                let prior = try app.documents.read()
                let start = (x - dx / 2, y - dy / 2)
                let end = (x + dx / 2, y + dy / 2)
                try await motion(app, start: start, end: end)
                let after = try await app.documents.waitFor("real canvas displacement and release") {
                    let xChange = $0.canvasOffsetX - prior.canvasOffsetX
                    let yChange = $0.canvasOffsetY - prior.canvasOffsetY
                    return $0.activeWindowTouches == 0 && (dx < 0 ? xChange > 100 : dx > 0 ? xChange < -100 : dy < 0 ? yChange > 100 : yChange < -100)
                }
                try #require(after.pageOffsetY == before.pageOffsetY && after.listOffsetY == before.listOffsetY)
                try controlsScrollUnchanged(after, before: before)
                try after.requireClear()
            }
            try app.preserveState("canvas-final")
        }
    }

    private func rowFrames(_ app: PlaygroundControlsSession) async throws -> [UIElement.Frame] {
        let output = try await app.app.run(["describe-ui"])
        let roots = try UIStateParser.parseDescribeUIRoots(output.output)
        return try (1...30).map { index in
            let id = String(format: "feature.row.%02d", index)
            let element = try #require(UIStateParser.findElement(in: roots, withIdentifier: id))
            return try #require(element.frame)
        }
    }

    private func verifyRows(_ actual: [UIElement.Frame], original: [UIElement.Frame], displacement: Double) throws {
        try #require(actual.count == 30 && original.count == 30)
        for (new, old) in zip(actual, original) {
            try #require(abs(new.y - (old.y - displacement)) <= 0.5)
            try #require(abs(new.x - old.x) <= 0.5 && abs(new.width - old.width) <= 0.5 && abs(new.height - old.height) <= 0.5)
        }
    }

    private func motion(_ app: PlaygroundControlsSession, start: (Double, Double), end: (Double, Double)) async throws {
        let before = try app.documents.read()
        _ = try await app.selected(["swipe", "--start-x", String(start.0), "--start-y", String(start.1),
            "--end-x", String(end.0), "--end-y", String(end.1), "--duration", "1", "--delta", "5"])
        let after = try await app.documents.waitFor("scroll touch released") { $0.activeWindowTouches == 0 && $0.windowTouchTrace.count > before.windowTouchTrace.count }
        try app.requireContact(after, since: before, start: start, end: end)
    }
}
