import Foundation
import Testing

enum PlaygroundAgentSliderVariant: String, Sendable {
    case minimum, alreadyMinimum, maximum, stale, wrongPID, buttonReference, mixedSelector, legacyBatch, selectedBatch
    case agentInterior, selectedInterior, selectedFromMaximum
}

@Suite("Playground Agent Slider E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentSliderTests {
    @Test("Native endpoints and interior values reach the actual UISlider", arguments: [
        PlaygroundAgentSliderVariant.minimum, .alreadyMinimum, .maximum, .stale, .wrongPID,
        .buttonReference, .mixedSelector, .legacyBatch, .selectedBatch,
        .agentInterior, .selectedInterior, .selectedFromMaximum,
    ])
    func slider(_ variant: PlaygroundAgentSliderVariant) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "slider-" + variant.rawValue)
        if [.alreadyMinimum, .maximum, .selectedFromMaximum].contains(variant) {
            let endpoint = variant == .selectedFromMaximum ? "maximum" : "minimum"
            let target = variant == .selectedFromMaximum ? ["--value", "100"] : ["--endpoint", endpoint]
            let setup = try await session.command(["slider", "--id", "feature.slider", "--element-type", "Slider",
                "--expected-pid", String(session.pid)] + target + session.selectedFlags)
            try #require(setup.exitCode == 0)
            _ = try await session.document.waitFor("normal endpoint setup") { abs($0.slider - (endpoint == "maximum" ? 100 : 0)) < 0.07 }
        }
        let capture = try await session.capture()
        var arguments = ["slider", "--endpoint", variant == .maximum ? "maximum" : "minimum"]
            + (try session.contextArguments(capture, identifier: variant == .buttonReference ? "feature.tap" : "feature.slider"))
        var code: String?
        var message: String?
        switch variant {
        case .minimum, .alreadyMinimum, .maximum, .buttonReference:
            if variant == .buttonReference { code = "unsupportedSliderReference" }
        case .stale:
            try await session.show("feature.showList")
            _ = try await session.capture()
            code = "snapshotMissing"
        case .wrongPID:
            let index = try #require(arguments.firstIndex(of: "--expected-pid"))
            arguments[index + 1] = String(session.pid + 1)
            code = "observationFailed"
            message = "processChanged"
        case .mixedSelector:
            arguments += ["--id", "feature.slider"]
            message = "Agent slider requires --snapshot-id, --ref and exactly one --endpoint or --value"
        case .legacyBatch, .selectedBatch:
            arguments = ["batch", "--step", arguments.joined(separator: " ")]
            if variant == .selectedBatch { arguments += session.selectedFlags }
            message = variant == .legacyBatch ? "Unsupported batch step 'slider'" : "Agent mode requires standalone commands"
        case .agentInterior:
            arguments = ["slider", "--value", "56.25"] + (try session.contextArguments(capture, identifier: "feature.slider"))
        case .selectedInterior, .selectedFromMaximum:
            arguments = ["slider", "--value", "63.25", "--id", "feature.slider", "--element-type", "Slider",
                "--expected-pid", String(session.pid)] + session.selectedFlags
        }
        let before = try session.document.read()
        let refused = code != nil || message != nil
        let output = try await session.command(arguments, allowFailure: refused)
        if refused {
            try session.requireRefusal(output, before: before, code: code, message: message)
        } else {
            let isInterior = [.agentInterior, .selectedInterior, .selectedFromMaximum].contains(variant)
            let target: Double = isInterior ? (variant == .agentInterior ? 56.25 : 63.25) : (variant == .maximum ? 100 : 0)
            let after = try await session.document.waitFor("real slider value and released input") {
                abs($0.slider - target) <= 0.07 && $0.activeWindowTouches == 0
            }
            let receipt = try PlaygroundAgentSliderEnvelope.decode(output.output)
            try #require(output.exitCode == 0)
            if variant == .selectedInterior || variant == .selectedFromMaximum {
                let raw = try session.rawReceipt(output.output)
                try #require(receipt.ax?.kind == "sliderPercentage")
                try #require(raw.outcome == "reached" && raw.enqueuedEventCount > 0 && raw.cleanup == "notNeeded"
                    && raw.error == nil && raw.quarantine == nil && raw.context == session.initialContext)
            } else {
                let action = try #require(receipt.data?.action)
                try #require(action.kind == (isInterior ? "sliderPercentage" : "sliderEndpoint"))
                try #require(!action.replayed && action.cleanup == "notNeeded")
                if isInterior { try #require(action.outcome == "reached") }
            }
            if isInterior {
                let value = try #require(receipt.data?.action?.sliderValue ?? receipt.ax?.sliderValue)
                let events = try #require(receipt.data?.action?.enqueuedEventCount ?? receipt.enqueuedEventCount)
                try value.requireReached(target: target, initial: before.slider, events: events)
                let contacts = try session.contacts(after: before, in: after, count: 1)
                let rows = try #require(contacts.first)
                try #require(rows.count >= 3 && rows.count <= events)
                try #require(after.count("sliderChanged") > before.count("sliderChanged"))
            } else {
                let value = try #require(receipt.data?.action?.slider)
                let expectedCalls = variant == .alreadyMinimum ? 0 : variant == .maximum ? 10 : 5
                try #require(value.actionsReturned == expectedCalls && value.actionAttempts == expectedCalls)
                try #require(value.outcome == (expectedCalls == 0 ? "alreadyAtEndpoint" : "endpointObserved"))
                try #require(value.delivery == (expectedCalls == 0 ? "notDispatched" : "valueObserved"))
                try #require(after.count("sliderChanged") == before.count("sliderChanged") + expectedCalls)
                try #require(after.inputState.windowTouchTrace == before.inputState.windowTouchTrace)
            }
            let state = try await session.core.state()
            let axValue = try #require(try session.core.element("feature.slider", in: state).value)
            let axPercent = try #require(session.core.sliderPercent(axValue))
            try #require(abs(axPercent - target) <= 0.07)
            try #require(after.text == before.text && after.switchOn == before.switchOn && after.count("tap") == before.count("tap"))
        }
        try capture.requireUnexpired("after slider action/refusal")
    }
}

struct PlaygroundAgentSliderEnvelope: Decodable {
    struct Payload: Decodable { let action: Action? }
    struct Action: Decodable {
        let kind: String
        let outcome: String
        let enqueuedEventCount: Int
        let cleanup: String
        let replayed: Bool
        let slider: Endpoint?
        let sliderValue: Percentage?
    }
    struct AX: Decodable { let kind: String; let sliderValue: Percentage? }
    struct Endpoint: Decodable {
        let outcome: String
        let delivery: String
        let actionAttempts: Int
        let actionsReturned: Int
    }
    struct Percentage: Decodable {
        let phase: String
        let outcome: String
        let reason: String?
        let delivery: String
        let requestedPercent: Double
        let initialValue: Double?
        let finalValue: Double?
        let nativeTarget: Double?
        let domainMinimum: Double?
        let domainMaximum: Double?
        let tolerance: Double?
        let moves: Int
        let pickupReadPhases: Int
        let elapsedSeconds: Double
        let replayed: Bool

        func requireReached(target: Double, initial: Double, events: Int) throws {
            try #require(phase == "physicalOwnedValue" && outcome == "reached" && reason == nil
                && delivery == "enqueuedAndDrained" && requestedPercent == target && !replayed)
            try #require(domainMinimum == 0 && domainMaximum == 100)
            let nativeTarget = try #require(self.nativeTarget)
            try #require(nativeTarget.isFinite && abs(nativeTarget - target) <= 0.000000001)
            let tolerance = try #require(self.tolerance)
            let initialValue = try #require(self.initialValue)
            let finalValue = try #require(self.finalValue)
            try #require(abs(tolerance - 0.07) < 0.000000001 && abs(initialValue - initial) <= tolerance
                && abs(finalValue - target) <= tolerance)
            try #require(moves > 0 && events == moves + 2 && pickupReadPhases == 6)
            try #require(elapsedSeconds.isFinite && elapsedSeconds >= 0 && elapsedSeconds <= 15)
        }
    }
    let enqueuedEventCount: Int?
    let data: Payload?
    let ax: AX?
    static func decode(_ output: String) throws -> Self {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No slider result: \(output)")
    }
}
