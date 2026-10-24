import Foundation
import Testing

@Suite("Playground Agent Selectors E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentSelectorTests {
    @Test("A partial label taps the real counter")
    func substringTap() async throws { try await verify(.substring) }
    @Test("A grouped text pattern taps the real counter")
    func regexTap() async throws { try await verify(.regex) }
    @Test("Decimal screen bounds include the intended counter")
    func decimalFrameTap() async throws { try await verify(.decimalFrame) }
    @Test("A missing partial label has no input effect")
    func missingSelector() async throws { try await verify(.missing) }
    @Test("A pattern that matches two Buttons has no input effect")
    func duplicateSelector() async throws { try await verify(.duplicate) }
    @Test("An excluded screen area has no input effect")
    func excludedFrame() async throws { try await verify(.excludedFrame) }
    @Test("Exact identifier input remains available in agent mode")
    func exactIDCompatibility() async throws { try await verify(.exactID) }
    @Test("Exact label input remains available in agent mode")
    func exactLabelCompatibility() async throws { try await verify(.exactLabel) }
    @Test("A saved current reference taps the same real counter")
    func referenceCompatibility() async throws { try await verify(.reference) }

    private enum SelectorCase { case substring, regex, decimalFrame, missing, duplicate, excludedFrame, exactID, exactLabel, reference }

    private func verify(_ kind: SelectorCase) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "selector-\(kind)")
        let raw = try await session.core.state()
        let target = try session.core.element("feature.tap", in: raw)
        let frame = try session.core.frame(of: target)
        try #require(target.type == "Button" && target.enabled == true)
        let before = try session.document.read()
        var arguments = ["tap", "--agent", "--expected-pid", String(session.pid)]
        var refusal: String?
        var timed: AgentPlaygroundTimedCapture?
        switch kind {
        case .substring:
            arguments += ["--label-contains", "Tap coun", "--element-type", "Button"]
        case .regex:
            arguments += ["--label-regex", "^Tap coun(er|ter)$", "--element-type", "Button"]
        case .decimalFrame:
            try #require(frame.x > 0.25 && frame.y > 0.25)
            let bounds = "minX=\(frame.x - 0.25),maxX=\(frame.x + frame.width + 0.25),"
                + "minY=\(frame.y - 0.25),maxY=\(frame.y + frame.height + 0.25)"
            arguments += ["--label-contains", "counter", "--element-type", "Button", "--frame", bounds]
        case .missing:
            arguments += ["--label-contains", "AXe absent 7d53", "--element-type", "Button"]
            refusal = "targetMissing"
        case .duplicate:
            arguments += ["--label-regex", "^(Reset|Dismiss keyboard)$", "--element-type", "Button"]
            refusal = "targetAmbiguous"
        case .excludedFrame:
            arguments += ["--label-contains", "counter", "--element-type", "Button",
                "--frame", "minX=0,maxX=0.25,minY=0,maxY=0.25"]
            refusal = "targetMissing"
        case .exactID:
            arguments += ["--id", "feature.tap"]
        case .exactLabel:
            arguments += ["--label", "Tap counter", "--element-type", "Button"]
        case .reference:
            let capture = try await session.capture()
            timed = capture
            arguments += ["--snapshot-id", capture.capture.snapshotID.uuidString,
                "--ref", try session.reference("feature.tap", in: capture.capture)]
        }
        let result = try await session.command(arguments, allowFailure: refusal != nil)
        if let refusal {
            try session.requireRefusal(result, before: before, code: refusal)
        } else {
            try session.requireHIDSuccess(result, kind: "tap", events: 2)
            try await session.requireButtonTap(after: before)
        }
        try timed?.requireUnexpired("after selector compatibility check")
        print("Manual selector coverage: \(kind), pid=\(session.pid), frame=\(frame)")
    }
}
