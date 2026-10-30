import Foundation
import Testing

enum PlaygroundAgentTouchVariant: String, Sendable {
    case normal, stale, wrongPID, mixedCoordinates, downOnly, upOnly, retainedToken
    case zeroDelay, negativeDelay, excessiveDelay, nonFiniteDelay, selectedBatch
    case rawCompatibility, selectedCompatibility, freshReference, legacyBatch, fieldLongHold
}

@Suite("Playground Agent Complete Touch E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentTouchTests {
    @Test("Complete reference touches release contacts and enforce target rules", arguments: agentTouchVariants([
        PlaygroundAgentTouchVariant.normal, .stale, .wrongPID, .mixedCoordinates, .downOnly, .upOnly,
        .retainedToken, .zeroDelay, .negativeDelay, .excessiveDelay, .nonFiniteDelay, .selectedBatch,
        .rawCompatibility, .selectedCompatibility, .freshReference, .legacyBatch, .fieldLongHold,
    ]))
    func completeTouch(_ variant: PlaygroundAgentTouchVariant) async throws {
        let position: DuoControlsPosition = isDuoPlaygroundE2EEnabled ? .inner270 : .outer0
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "touch-" + variant.rawValue, position: position)
        if variant == .fieldLongHold {
            try await session.focusField()
            _ = try await session.rawCommand(["type", "holdproof"])
            _ = try await session.document.waitFor("long-hold text seed") { $0.text == "holdproof" }
        }
        let identifier = variant == .fieldLongHold ? "feature.text" : "feature.tap"
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element(identifier, in: state))
        let point = (x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        let capture = try await session.capture()
        var arguments = ["touch", "--down", "--up"] + (try session.contextArguments(capture, identifier: identifier))
        var code: String?
        var message: String?
        var isAgent = true
        switch variant {
        case .normal: break
        case .stale:
            let tap = try await session.command(["tap"] + (try session.contextArguments(capture, identifier: "feature.tap")))
            try session.requireHIDSuccess(tap, kind: "tap", events: 2)
            _ = try await session.capture()
            code = "snapshotMissing"
        case .wrongPID:
            let index = try #require(arguments.firstIndex(of: "--expected-pid"))
            arguments[index + 1] = String(session.pid + 1)
            code = "contextChanged"
        case .mixedCoordinates:
            arguments += ["-x", "20", "-y", "20"]
            message = touchAdmissionDiagnostic
        case .downOnly, .upOnly:
            arguments.removeAll { $0 == (variant == .downOnly ? "--up" : "--down") }
            message = touchAdmissionDiagnostic
        case .retainedToken:
            arguments += ["--contact-token", UUID().uuidString]
            message = touchAdmissionDiagnostic
        case .zeroDelay, .negativeDelay, .excessiveDelay, .nonFiniteDelay:
            let delays: [PlaygroundAgentTouchVariant: String] = [
                .zeroDelay: "0", .negativeDelay: "-0.1", .excessiveDelay: "10.1", .nonFiniteDelay: "nan",
            ]
            let delay = try #require(delays[variant])
            arguments += ["--delay=\(delay)"]
            message = "Agent query and timing limits are invalid"
        case .selectedBatch, .legacyBatch:
            arguments = ["batch", "--step", arguments.joined(separator: " ")]
            if variant == .selectedBatch { arguments += session.selectedFlags }
            message = "Agent mode requires standalone commands"
        case .rawCompatibility, .selectedCompatibility:
            arguments = ["touch", "--down", "--up", "-x", String(frame.x + frame.width / 2),
                "-y", String(frame.y + frame.height / 2)]
            if variant == .selectedCompatibility { arguments += session.selectedFlags }
            isAgent = false
        case .freshReference:
            let beforeRefusal = try session.document.read()
            let refused = try await session.command(arguments + ["-x", "20", "-y", "20"], allowFailure: true)
            try session.requireRefusal(refused, before: beforeRefusal, message: touchAdmissionDiagnostic)
        case .fieldLongHold:
            arguments += ["--delay", "0.7"]
        }
        let before = try session.document.read()
        let refused = code != nil || message != nil
        let result: CommandOutput
        if variant == .rawCompatibility { result = try await session.rawCommand(arguments) }
        else { result = try await session.command(arguments, allowFailure: refused) }
        if refused {
            try session.requireRefusal(result, before: before, code: code, message: message)
        } else {
            try #require(result.exitCode == 0)
            if isAgent { try session.requireHIDSuccess(result, kind: "hold", events: 2) }
            else if variant == .selectedCompatibility { try session.requireSelectedSuccess(result, events: 2) }
            if variant == .fieldLongHold {
                let after = try await session.document.waitFor("released focused field hold") { $0.activeWindowTouches == 0 }
                _ = try session.contacts(after: before, in: after, count: 1, minimumHold: 0.65)
                try #require(after.text == "holdproof" && after.textFocused)
                let menu = try await session.core.waitFor("normal Select and Select All text actions") { state in
                    let labels = Set(session.core.elements(in: state).compactMap(\.label))
                    return labels.contains("Select") && labels.contains("Select All")
                }
                try #require(session.core.elements(in: menu).contains { $0.label == "Select All" })
            } else {
                try await session.requireButtonTap(after: before)
            }
            let after = try session.document.read()
            for rows in try session.contacts(after: before, in: after, count: 1) {
                let first = try #require(rows.first)
                let last = try #require(rows.last)
                try #require(hypot(first.x - point.x, first.y - point.y) <= 2)
                try #require(hypot(last.x - point.x, last.y - point.y) <= 2)
            }
        }
        try capture.requireUnexpired("after complete reference touch check")
    }
}

private let touchAdmissionDiagnostic = "Agent touch requires --ref, --down and --up, without coordinates or a contact token."

/// Select an original parameterized case without changing its app setup or assertions.
private func agentTouchVariants(_ original: [PlaygroundAgentTouchVariant]) -> [PlaygroundAgentTouchVariant] {
    let environmentKey = "AXE_E2E_AGENT_TOUCH_VARIANT"
    guard let requested = ProcessInfo.processInfo.environment[environmentKey] else { return original }
    guard let variant = PlaygroundAgentTouchVariant(rawValue: requested), original.contains(variant) else {
        let allowed = original.map(\.rawValue).joined(separator: ", ")
        fatalError("Invalid \(environmentKey)=\(requested). Expected exactly one of: \(allowed).")
    }
    return [variant]
}
