import Foundation
import Testing

/// Each argument is one named device position and one public input interface.
@Suite("Playground Duo Swipe and Drag Coverage", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoGestureCoverageTests {
    @Test("Swipe reaches its physical endpoints after rotation", arguments: DuoControlsPosition.allCases, [false, true])
    func swipe(position: DuoControlsPosition, selected: Bool) async throws {
        try await checkMotion("swipe", position: position, selected: selected)
    }

    @Test("Drag reaches its physical endpoints after rotation", arguments: DuoControlsPosition.allCases, [false, true])
    func drag(position: DuoControlsPosition, selected: Bool) async throws {
        try await checkMotion("drag", position: position, selected: selected)
    }

    private func checkMotion(_ verb: String, position: DuoControlsPosition, selected: Bool) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            try #require(frame.width > 220 && frame.height > 80)
            let start = (frame.x + frame.width / 2 - 80, frame.y + frame.height / 2)
            let end = (start.0 + 160, start.1)
            let before = try app.documents.read()
            let arguments = [verb, "--start-x", String(start.0), "--start-y", String(start.1),
                "--end-x", String(end.0), "--end-y", String(end.1)]
            if selected {
                let result = try await app.selected(arguments)
                try #require(result.outcome == "enqueuedAndDrained" && result.enqueuedEventCount > 2)
            } else {
                _ = try await app.app.run(arguments)
            }
            let after = try await app.documents.waitFor("one real completed pan and release") {
                $0.count("pan") == before.count("pan") + 1 && $0.activeWindowTouches == 0
                    && $0.recognizerTrace.last(where: { $0.name == "pan" })?.state == 3
            }
            try app.requireContact(after, since: before, start: start, end: end)
            try controlsRecognizer(after, before: before, name: "pan")
            try #require(after.panX > 120 && abs(after.panY) <= 2)
            try #require(after.text == before.text && after.slider == before.slider && after.switchOn == before.switchOn)
            try #require(after.pageOffsetY == before.pageOffsetY && after.listOffsetY == before.listOffsetY)
            print("Duo \(verb) proved: \(position.rawValue), selected=\(selected), start=\(start), end=\(end), pan=\(after.panX).")
        }
    }
}

@Suite("Playground Duo Coordinate Coverage", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoCoordinateCoverageTests {
    @Test("Legacy coordinate tap after rotation", arguments: DuoControlsPosition.allCases)
    func rawTap(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.tap")
            let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
            let before = try app.documents.read()
            _ = try await app.app.run(["tap", "-x", String(point.0), "-y", String(point.1)])
            let after = try await app.documents.waitFor("one raw coordinate Button callback") {
                $0.count("tap") == before.count("tap") + 1 && $0.activeWindowTouches == 0
            }
            try app.requireContact(after, since: before, start: point, end: point)
        }
    }

    @Test("Selected coordinate tap, hold and double tap after rotation", arguments: DuoControlsPosition.allCases, CoordinateAction.allCases)
    func selectedPadAction(position: DuoControlsPosition, action: CoordinateAction) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
            let before = try app.documents.read()
            let requestedHoldDuration: TimeInterval = 0.7
            let arguments: [String]
            switch action {
            case .tap: arguments = ["tap", "-x", String(point.0), "-y", String(point.1)]
            case .hold: arguments = ["touch", "-x", String(point.0), "-y", String(point.1), "--down", "--up", "--delay", String(requestedHoldDuration)]
            case .doubleTap: arguments = ["gesture", "double-tap", "-x", String(point.0), "-y", String(point.1)]
            }
            let result = try await app.selected(arguments)
            try #require(result.outcome == "enqueuedAndDrained")
            let after = try await app.documents.waitFor("one real \(action.rawValue) callback and release") {
                $0.count(action.rawValue) == before.count(action.rawValue) + 1 && $0.activeWindowTouches == 0
                    && $0.recognizerTrace.last(where: { $0.name == action.rawValue })?.state == 3
                    && (action != .hold || $0.count("padTap") == before.count("padTap") + 1)
            }
            try app.requireContact(after, since: before, start: point, end: point, contacts: action == .doubleTap ? 2 : 1)
            try controlsRecognizer(after, before: before, name: action.rawValue, discrete: action != .hold,
                padTapAfterHold: action == .hold)
            if action == .hold {
                let trace = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
                let first = try #require(trace.first), last = try #require(trace.last)
                let timestampTolerance: TimeInterval = 0.02
                try #require(last.timestamp - first.timestamp >= requestedHoldDuration - timestampTolerance)
            }
            try #require(after.text == before.text && after.slider == before.slider && after.switchOn == before.switchOn)
        }
    }
}

enum CoordinateAction: String, CaseIterable { case tap = "padTap", hold = "longPress", doubleTap }
