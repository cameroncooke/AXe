import Foundation
import Testing

enum PlaygroundPairAction: String, CaseIterable { case pinch, rotate, twoFingerTap = "two-finger-tap", twoFingerHold = "two-finger-hold" }
struct PlaygroundPairPoint { let x: Double; let y: Double }

@Suite("Playground Duo Complete Pair Gestures", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoPairCoverageTests {
    @Test("Complete pair gestures produce real effects and release both contacts", arguments: DuoControlsPosition.allCases, PlaygroundPairAction.allCases)
    func pair(position: DuoControlsPosition, action: PlaygroundPairAction) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let x = frame.x + frame.width / 2
            let y = frame.y + frame.height / 2
            let radius: Double
            switch action { case .pinch: radius = 26; case .rotate: radius = 25; default: radius = 24 }
            let starts = [PlaygroundPairPoint(x: x - radius, y: y), PlaygroundPairPoint(x: x + radius, y: y)]
            var ends = starts
            var arguments = ["gesture", action.rawValue, "-x", String(x), "-y", String(y)]
            let counter: String
            switch action {
            case .pinch:
                arguments += ["--radius", "26", "--scale", "1.5", "--duration", "0.6", "--delta", "3"]
                ends = [PlaygroundPairPoint(x: x - 39, y: y), PlaygroundPairPoint(x: x + 39, y: y)]
                counter = "pinch"
            case .rotate:
                arguments += ["--radius", "25", "--degrees", "45", "--duration", "0.6", "--delta", "3"]
                let distance = 25 / sqrt(2.0)
                ends = [PlaygroundPairPoint(x: x - distance, y: y - distance), PlaygroundPairPoint(x: x + distance, y: y + distance)]
                counter = "rotation"
            case .twoFingerTap, .twoFingerHold:
                arguments = ["gesture", action.rawValue, "-x", String(starts[0].x), "-y", String(y), "--x2", String(starts[1].x), "--y2", String(y)]
                if action == .twoFingerHold { arguments += ["--hold", "0.7"] }
                counter = action == .twoFingerTap ? "twoFingerTap" : "twoFingerHold"
            }
            let before = try app.documents.read()
            let receipt = try await app.selected(arguments)
            try #require(receipt.outcome == "enqueuedAndDrained")
            if action == .twoFingerTap || action == .twoFingerHold {
                try #require(receipt.enqueuedEventCount == 2)
            } else {
                try #require(receipt.enqueuedEventCount > 2)
            }
            let after = try await app.documents.waitFor("one complete \(counter) and both releases") {
                $0.count(counter) == before.count(counter) + 1 && $0.activeWindowTouches == 0
                    && $0.recognizerTrace.last(where: { $0.name == counter })?.state == 3
            }
            try requirePairTrace(after, before: before, starts: starts, ends: ends,
                rotationCenter: action == .rotate ? PlaygroundPairPoint(x: x, y: y) : nil)
            try requirePairRecognizers(after, before: before, action: action)
            if action == .pinch { try #require(after.pinchScale > 1.1 && after.pinchScale < 1.5) }
            if action == .rotate { try #require(abs(after.rotationRadians - Double.pi / 4) <= 0.15) }
            if action == .twoFingerHold {
                let events = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
                let first = try #require(events.first), last = try #require(events.last)
                try #require(last.timestamp - first.timestamp >= 0.5)
            }
            try #require(after.text == before.text && after.slider == before.slider && after.switchOn == before.switchOn)
            try #require(after.pageOffsetY == before.pageOffsetY && after.listOffsetY == before.listOffsetY)
            try app.preserveState("complete-pair-final")
        }
    }
}

func requirePairTrace(_ after: PlaygroundControlsDocument, before: PlaygroundControlsDocument,
                      starts: [PlaygroundPairPoint], ends: [PlaygroundPairPoint],
                      rotationCenter: PlaygroundPairPoint? = nil) throws {
    let groups = try controlsContactGroups(after, before: before, expected: 2)
        .sorted { ($0.first?.x ?? 0) < ($1.first?.x ?? 0) }
    try #require(starts.count == 2 && ends.count == 2)
    let added = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
    try #require(added.map(\.activeTouches).max() == 2)
    for (index, rows) in groups.enumerated() {
        let first = try #require(rows.first), last = try #require(rows.last)
        let start = (starts[index].x, starts[index].y), end = (ends[index].x, ends[index].y)
        try controlsNear(first, point: start)
        try controlsNear(last, point: end)
        for row in rows {
            if let center = rotationCenter {
                try #require(abs(hypot(row.x - center.x, row.y - center.y) - 25) <= 0.5)
            } else { try controlsOnLine(row, start: start, end: end) }
        }
        if start != end { try #require(rows.contains { $0.phase == "windowTouchMoved" }) }
    }
    let firstEnd = try #require(groups[0].last), secondStart = try #require(groups[1].first)
    let secondEnd = try #require(groups[1].last), firstStart = try #require(groups[0].first)
    try #require(firstEnd.timestamp >= secondStart.timestamp && secondEnd.timestamp >= firstStart.timestamp)
}

// This normal pad permits these exact recognizers to run together.
private func requirePairRecognizers(_ after: PlaygroundControlsDocument, before: PlaygroundControlsDocument,
                                    action: PlaygroundPairAction) throws {
    let expectedNames: [String]
    switch action {
    case .pinch: expectedNames = ["pinch", "twoFingerHold", "twoFingerTap"]
    case .rotate: expectedNames = ["rotation", "twoFingerHold", "twoFingerTap"]
    case .twoFingerTap: expectedNames = ["twoFingerTap"]
    case .twoFingerHold: expectedNames = ["twoFingerHold", "twoFingerTap"]
    }
    try #require(after.pid == before.pid && after.generation == before.generation)
    try #require(Array(after.recognizerTrace.prefix(before.recognizerTrace.count)) == before.recognizerTrace)
    let records = Array(after.recognizerTrace.dropFirst(before.recognizerTrace.count))
    let contacts = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
    try #require(contacts.allSatisfy { $0.hitView == "feature.pad" })
    try #require(Set(records.map(\.name)) == Set(expectedNames))
    var previousTime = before.recognizerTrace.last?.timestamp ?? 0
    for record in records {
        let finite = [record.timestamp, record.x, record.y].allSatisfy(\.isFinite)
        try #require(finite)
        try #require(record.timestamp >= previousTime && record.touches == 2)
        try #require([1, 2, 3].contains(record.state))
        previousTime = record.timestamp
    }
    for name in expectedNames {
        let matching = records.filter { $0.name == name }
        let first = try #require(matching.first), last = try #require(matching.last)
        let discrete = name == "twoFingerTap"
        try #require(first.state == (discrete ? 3 : 1) && last.state == 3)
        try #require(matching.filter { $0.state == 1 }.count == (discrete ? 0 : 1))
        try #require(matching.filter { $0.state == 3 }.count == 1)
        if discrete { try #require(matching.count == 1) }
        try #require(after.count(name) == before.count(name) + 1)
    }
    if action != .twoFingerTap {
        let holdStart = try #require(records.first { $0.name == "twoFingerHold" })
        let holdEnd = try #require(records.last { $0.name == "twoFingerHold" })
        let tap = try #require(records.first { $0.name == "twoFingerTap" })
        try #require(holdStart.timestamp <= tap.timestamp && tap.timestamp <= holdEnd.timestamp)
        if action == .pinch || action == .rotate {
            let primaryName = action == .pinch ? "pinch" : "rotation"
            let primaryStart = try #require(records.first { $0.name == primaryName })
            let primaryEnd = try #require(records.last { $0.name == primaryName })
            try #require(primaryStart.timestamp <= holdStart.timestamp && holdEnd.timestamp <= primaryEnd.timestamp)
        }
    }
    let allowedCounters = Set(expectedNames + ["touchBegan", "touchMoved", "touchEnded",
        "windowTouchBegan", "windowTouchMoved", "windowTouchEnded"])
    for name in Set(after.counts.keys).union(before.counts.keys) where !allowedCounters.contains(name) {
        try #require(after.count(name) == before.count(name))
    }
    try #require(after.geometry == before.geometry)
    try #require(after.textFocused == before.textFocused && after.advancedSliders == before.advancedSliders)
    try #require(after.canvasOffsetX == before.canvasOffsetX && after.canvasOffsetY == before.canvasOffsetY)
    try #require(after.panX == before.panX && after.panY == before.panY)
    if action != .pinch { try #require(after.pinchScale == before.pinchScale) }
    if action != .rotate { try #require(after.rotationRadians == before.rotationRadians) }
    try #require(after.waitTargetVisible == before.waitTargetVisible && after.waitDuplicateVisible == before.waitDuplicateVisible)
    try #require(after.targetAppearedUptime == before.targetAppearedUptime && after.scheduleGeneration == before.scheduleGeneration)
}
