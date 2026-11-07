import Foundation
import Testing

enum PlaygroundAgentPinchVariant: String, Sendable {
    case normal, stale, wrongPID, mixedCoordinates, outsideArea, legacyBatch, selectedBatch, selectedCompatibility
}

@Suite("Playground Agent Pinch E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentPinchTests {
    @Test("Area reference pinch releases both moving contacts", arguments: [
        PlaygroundAgentPinchVariant.normal, .stale, .wrongPID, .mixedCoordinates,
        .outsideArea, .legacyBatch, .selectedBatch, .selectedCompatibility,
    ])
    func pinch(_ variant: PlaygroundAgentPinchVariant) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "pinch-" + variant.rawValue)
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element("feature.pad", in: state))
        let radius = min(28, frame.height / 4)
        let capture = try await session.capture()
        var arguments = ["gesture", "pinch", "--radius", String(radius), "--scale", "1.5", "--duration", "0.6", "--delta", "5"]
            + (try session.contextArguments(capture, identifier: "feature.pad"))
        var code: String?
        var message: String?
        switch variant {
        case .normal: break
        case .stale:
            let tap = try await session.command(["tap", "--agent", "--expected-pid", String(session.pid),
                "--id", "feature.tap", "--element-type", "Button"])
            try session.requireHIDSuccess(tap, kind: "tap", events: 2)
            _ = try await session.capture()
            code = "snapshotMissing"
        case .wrongPID:
            let index = try #require(arguments.firstIndex(of: "--expected-pid"))
            arguments[index + 1] = String(session.pid + 1)
            code = "contextChanged"
        case .mixedCoordinates:
            arguments += ["-x", "20", "-y", "20"]
            message = "Agent pinch accepts an area reference, radius, scale, duration, delta and delays only"
        case .outsideArea:
            let endRadius = frame.width / 2 + 4
            let centerX = frame.x + frame.width / 2
            try #require(centerX - endRadius > 0 && centerX + endRadius < session.initialContext.logicalWidth)
            let outsideRadius = endRadius / 1.5
            try #require(outsideRadius > 0 && outsideRadius < frame.width / 2)
            let index = try #require(arguments.firstIndex(of: "--radius"))
            arguments[index + 1] = String(outsideRadius)
        case .legacyBatch, .selectedBatch:
            arguments = ["batch", "--step", arguments.joined(separator: " ")]
            if variant == .selectedBatch { arguments += session.selectedFlags }
            message = "Agent mode requires standalone commands"
        case .selectedCompatibility:
            arguments = ["gesture", "pinch", "-x", String(frame.x + frame.width / 2),
                "-y", String(frame.y + frame.height / 2), "--radius", String(radius),
                "--scale", "1.5", "--duration", "0.6", "--delta", "5"] + session.selectedFlags
        }
        let before = try session.document.read()
        let refused = code != nil || message != nil || variant == .outsideArea
        let result = try await session.command(arguments, allowFailure: refused)
        if variant == .outsideArea {
            try #require(result.exitCode != 0)
            let envelope = try session.decodeAgent(result.output)
            // The path guard's typed refusal reaches the agent with its own code and message.
            try #require(envelope.didError && envelope.error?.code == "pinchTargetMismatch")
            let action = try #require(envelope.data.action)
            try #require(action.kind == "pinch" && action.outcome == "failedBeforeInput"
                && action.enqueuedEventCount == 0 && action.cleanup == "notNeeded" && !action.replayed)
            try #require(result.output.contains("outside the selected area"))
            let after = try session.document.read()
            try #require(after.inputState == before.inputState)
        } else if refused {
            try session.requireRefusal(result, before: before, code: code, message: message)
        } else {
            if variant == .selectedCompatibility {
                try #require(result.exitCode == 0)
                let receipt = try session.rawReceipt(result.output)
                try receipt.requireCompleted()
                try #require(receipt.outcome == "enqueuedAndDrained" && receipt.cleanup == "notNeeded"
                    && receipt.enqueuedEventCount > 0 && receipt.context == session.initialContext)
            } else { try session.requireHIDSuccess(result, kind: "pinch") }
            let after = try await session.document.waitFor("real pinch callback and both releases") {
                $0.count("pinch") == before.count("pinch") + 1 && $0.activeWindowTouches == 0
            }
            let groups = try session.contacts(after: before, in: after, count: 2)
                .sorted { ($0.first?.x ?? 0) < ($1.first?.x ?? 0) }
            let cx = frame.x + frame.width / 2
            let cy = frame.y + frame.height / 2
            for (index, rows) in groups.enumerated() {
                let direction = index == 0 ? -1.0 : 1.0
                let first = try #require(rows.first)
                let last = try #require(rows.last)
                try #require(rows.contains { $0.phase == "windowTouchMoved" })
                try #require(hypot(first.x - (cx + direction * radius), first.y - cy) <= 2)
                try #require(hypot(last.x - (cx + direction * radius * 1.5), last.y - cy) <= 2)
            }
            let allContacts = groups.flatMap { $0 }
            try #require(allContacts.map(\.activeTouches).max() == 2)
            try #require(after.pinchScale > 1.05)
            try #require(after.text == before.text && after.slider == before.slider && after.switchOn == before.switchOn)
            try #require(after.count("tap") == before.count("tap") && after.listOffsetY == before.listOffsetY
                && abs(after.pageOffsetY - before.pageOffsetY) < 1 && after.panX == before.panX && after.panY == before.panY
                && after.rotationRadians == before.rotationRadians
                && after.canvasOffsetX == before.canvasOffsetX && after.canvasOffsetY == before.canvasOffsetY)
        }
        try capture.requireUnexpired("after reference pinch check")
    }
}
