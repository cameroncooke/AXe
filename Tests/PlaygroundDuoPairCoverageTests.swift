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
            try controlsRecognizer(after, before: before, name: counter, discrete: action == .twoFingerTap)
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
