import Foundation
import Testing

enum PlaygroundAgentDoubleTapVariant: String, Sendable {
    case normal, stale, wrongPID, mixedCoordinates, legacyBatch, selectedBatch, selectedPad
}

@Suite("Playground Agent Double Tap E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentDoubleTapTests {
    @Test("Double tap invokes the real two-tap recognizer and releases both contacts", arguments: [
        PlaygroundAgentDoubleTapVariant.normal, .stale, .wrongPID, .mixedCoordinates,
        .legacyBatch, .selectedBatch, .selectedPad,
    ])
    func doubleTap(_ variant: PlaygroundAgentDoubleTapVariant) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "double-tap-" + variant.rawValue)
        if variant != .selectedPad { try await session.show("feature.showTargets") }
        let targetID = variant == .selectedPad ? "feature.pad" : "feature.doubleTapCounter"
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element(targetID, in: state))
        let point = (x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        let capture = try await session.capture()
        var arguments = ["gesture", "double-tap"]
        if variant != .selectedPad {
            arguments += try session.contextArguments(capture, identifier: "feature.doubleTapCounter")
        }
        var code: String?
        var message: String?
        switch variant {
        case .normal: break
        case .stale:
            try await session.show("feature.showList")
            _ = try await session.capture()
            code = "snapshotMissing"
        case .wrongPID:
            let index = try #require(arguments.firstIndex(of: "--expected-pid"))
            arguments[index + 1] = String(session.pid + 1)
            code = "observationFailed"
            message = "processChanged"
        case .mixedCoordinates:
            arguments += ["-x", "20", "-y", "20"]
            message = "Agent double-tap accepts a reference and timing only, without coordinates, geometry or dimension overrides."
        case .legacyBatch, .selectedBatch:
            arguments = ["batch", "--step", arguments.joined(separator: " ")]
            if variant == .selectedBatch { arguments += session.selectedFlags }
            message = "Agent mode requires standalone commands"
        case .selectedPad:
            arguments = ["gesture", "double-tap", "-x", String(frame.x + frame.width / 2),
                "-y", String(frame.y + frame.height / 2)] + session.selectedFlags
        }
        let before = try session.document.read()
        let refused = code != nil || message != nil
        let result = try await session.command(arguments, allowFailure: refused)
        if refused {
            try session.requireRefusal(result, before: before, code: code, message: message)
        } else {
            let callback = variant == .selectedPad ? "doubleTap" : "buttonDoubleTap"
            if variant == .selectedPad {
                try session.requireSelectedSuccess(result, events: 4)
            } else { try session.requireHIDSuccess(result, kind: "doubleTap", events: 4) }
            let after = try await session.document.waitFor("one actual double-tap callback") {
                $0.count(callback) == before.count(callback) + 1 && $0.activeWindowTouches == 0
            }
            for rows in try session.contacts(after: before, in: after, count: 2, minimumHold: 0.04) {
                let first = try #require(rows.first)
                let last = try #require(rows.last)
                try #require(hypot(first.x - point.x, first.y - point.y) <= 2)
                try #require(hypot(last.x - point.x, last.y - point.y) <= 2)
            }
            if variant != .selectedPad {
                try session.requireReturnedValueIfPresent(result, identifier: "feature.doubleTapCounter", expected: "1", action: "tap")
                let state = try await session.core.state()
                try #require(try session.core.element("feature.doubleTapCounter", in: state).value == "1")
            }
        }
        try capture.requireUnexpired("after double-tap action or refusal")
    }
}
