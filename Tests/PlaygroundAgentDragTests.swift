import Foundation
import Testing

enum PlaygroundAgentDragVariant: String, Sendable {
    case normal, endOutsideTarget, stale, wrongPID, outsideDisplay, rawCompatibility, referenceSwipe
}

@Suite("Playground Agent Drag E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentDragTests {
    @Test("Reference drag and swipe move only the chosen list", arguments: [
        PlaygroundAgentDragVariant.normal, .endOutsideTarget, .stale, .wrongPID,
        .outsideDisplay, .rawCompatibility, .referenceSwipe,
    ])
    func drag(_ variant: PlaygroundAgentDragVariant) async throws {
        let position: DuoControlsPosition = isDuoPlaygroundE2EEnabled ? .inner270 : .outer0
        try await verify(variant, position: position)
        if isDuoPlaygroundE2EEnabled && (variant == .normal || variant == .referenceSwipe) {
            try await verify(variant, position: .outer0)
        }
    }

    private func verify(_ variant: PlaygroundAgentDragVariant, position: DuoControlsPosition) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "drag-" + variant.rawValue + "-" + position.rawValue, position: position)
        try await session.show("feature.showList")
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element("feature.list", in: state))
        let start = (x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        let end = (x: start.x, y: variant == .endOutsideTarget ? frame.y - 20 : start.y - 50)
        try #require(end.y > 0)
        let capture = try await session.capture()
        var arguments = ["drag", "--end-x", String(end.x), "--end-y", String(end.y),
            "--duration", "0.7", "--steps", "30"]
            + (try session.contextArguments(capture, identifier: "feature.list"))
        var code: String?
        var message: String?
        switch variant {
        case .normal, .endOutsideTarget: break
        case .stale:
            try await session.show("feature.reset")
            _ = try await session.capture()
            code = "snapshotMissing"
        case .wrongPID:
            let index = try #require(arguments.firstIndex(of: "--expected-pid"))
            arguments[index + 1] = String(session.pid + 1)
            code = "observationFailed"
            message = "processChanged"
        case .outsideDisplay:
            let index = try #require(arguments.firstIndex(of: "--end-y"))
            arguments[index + 1] = "10000"
            code = "invalidDragGeometry"
        case .rawCompatibility:
            arguments = ["drag", "--start-x", String(start.x), "--start-y", String(start.y),
                "--end-x", String(end.x), "--end-y", String(end.y), "--duration", "0.7", "--steps", "30"]
        case .referenceSwipe:
            arguments = ["swipe", "--direction", "up", "--distance", "0.5", "--duration", "0.7"]
                + (try session.contextArguments(capture, identifier: "feature.list"))
        }
        let before = try session.document.read()
        let refused = code != nil
        let result = try await session.command(arguments, allowFailure: refused)
        if refused {
            try session.requireRefusal(result, before: before, code: code, message: message)
        } else {
            if variant != .rawCompatibility {
                try session.requireHIDSuccess(result, kind: variant == .referenceSwipe ? "swipe" : "drag")
            } else { try #require(result.exitCode == 0) }
            let after = try await session.document.waitFor("selected list movement and released contact") {
                $0.listOffsetY > before.listOffsetY + 5 && $0.activeWindowTouches == 0
            }
            let groups = try session.contacts(after: before, in: after, count: 1)
            let rows = try #require(groups.first)
            try #require(rows.contains { $0.phase == "windowTouchMoved" })
            if variant != .referenceSwipe {
                let first = try #require(rows.first)
                let last = try #require(rows.last)
                try #require(hypot(first.x - start.x, first.y - start.y) <= 2)
                try #require(hypot(last.x - end.x, last.y - end.y) <= 2)
            }
            try #require(abs(after.pageOffsetY - before.pageOffsetY) < 1)
            try #require(after.text == before.text && after.slider == before.slider && after.switchOn == before.switchOn)
            try #require(after.panX == before.panX && after.panY == before.panY
                && after.pinchScale == before.pinchScale && after.rotationRadians == before.rotationRadians)
        }
        try capture.requireUnexpired("after reference drag check")
    }
}
