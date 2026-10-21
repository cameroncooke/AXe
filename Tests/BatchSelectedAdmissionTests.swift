import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Batch selected input admission")
@MainActor
struct BatchSelectedAdmissionTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let selection = ["--input-mode", "selected", "--screen-id", "3",
                             "--screen-uuid", "00000000-0000-0000-0000-000000000003"]
    private let rejection = "Selected input is not supported in batch steps. Run the selected command separately."

    private func context() -> BatchContext {
        BatchContext(simulatorUDID: udid, axCachePolicy: .none,
                     typeSubmissionMode: .composite, typeChunkSize: 200)
    }

    private func parse(_ tokens: [String]) async throws -> [BatchPrimitive] {
        try await BatchStepParser.parseStepTokens(tokens, globalUDID: udid,
                                                  context: context(), logger: AxeLogger())
    }

    // These are valid standalone selected commands. The exact error distinguishes
    // batch admission from ordinary parser failure or an attempted SDK lookup.
    @Test(arguments: [
        ["tap", "-x", "10", "-y", "20"],
        ["tap", "--id", "feature.tap", "--expected-pid", "123"],
        ["tap", "--label", "Tap", "--expected-pid", "123"],
        ["swipe", "--start-x", "10", "--start-y", "20", "--end-x", "110", "--end-y", "20"],
        ["gesture", "scroll-up"],
        ["touch", "-x", "10", "-y", "20", "--down"],
        ["touch", "-x", "10", "-y", "20", "--down", "--up", "--delay", "0.1"],
        ["touch", "-x", "10", "-y", "20", "--up", "--contact-token", "00000000-0000-0000-0000-000000000004"]
    ])
    func selectedStepFailsBeforeConversion(tokens: [String]) async throws {
        do {
            _ = try await parse(tokens + selection)
            Issue.record("Selected batch step reached conversion")
        } catch let error as ValidationError {
            #expect(error.description == rejection)
        }
    }

    @Test func equalsOptionSyntaxUsesTypedAdmission() async throws {
        do {
            _ = try await parse(["gesture", "scroll-up", "--input-mode=selected", "--screen-id=3",
                                 "--screen-uuid=00000000-0000-0000-0000-000000000003"])
            Issue.record("Selected batch step reached conversion")
        } catch let error as ValidationError {
            #expect(error.description == rejection)
        }
    }

    private func admitLegacy<C: AsyncParsableCommand & BatchConvertible>(
        _ type: C.Type, _ arguments: [String]
    ) throws {
        var command = try C.parse(arguments + ["--udid", udid])
        try command.validate()
        #expect(command.batchInputMode == .legacy)
        try command.validateBatchAdmission()
    }

    // Do not call coordinate converters here: they need real orientation reads.
    @Test func legacySelectableCommandsStillPassAdmission() throws {
        try admitLegacy(Tap.self, ["-x", "10", "-y", "20"])
        try admitLegacy(Swipe.self, ["--start-x", "10", "--start-y", "20", "--end-x", "110", "--end-y", "20"])
        try admitLegacy(Gesture.self, ["scroll-up"])
        try admitLegacy(Touch.self, ["-x", "10", "-y", "20", "--down", "--up"])
    }

    @Test func legacyPresetKeepsItsActualEventPlan() async throws {
        let plan = try await parse(["gesture", "scroll-up"])
        #expect(plan.count == 1)
        guard case let .hidMergeable(event) = try #require(plan.first) else {
            Issue.record("Expected the legacy mergeable gesture"); return
        }
        let events = try #require(event.subEvents)
        #expect(events.count == 21)
        #expect(events.first == .touch(direction: .down, x: 195, y: 522))
        #expect(events.last == .touch(direction: .up, x: 195, y: 322))
        let delays = events.compactMap { event -> TimeInterval? in
            if case let .delay(seconds) = event { return seconds }
            return nil
        }
        #expect(delays.count == 10)
        #expect(abs(delays.reduce(0, +) - 0.5) < 0.000001)
    }

    @Test func explicitLegacyPresetKeepsDelaysAndDimensions() async throws {
        let plan = try await parse(["gesture", "scroll-up", "--input-mode", "legacy",
                                    "--screen-width", "400", "--screen-height", "800",
                                    "--duration", "1", "--delta", "50", "--pre-delay", "0.2", "--post-delay", "0.3"])
        guard case let .hidMergeable(event) = try #require(plan.first) else {
            Issue.record("Expected the legacy mergeable gesture"); return
        }
        let events = try #require(event.subEvents)
        #expect(events.count == 3)
        #expect(events.first == .delay(0.2))
        #expect(events.last == .delay(0.3))
        let gesture = try #require(events[1].subEvents)
        #expect(gesture.first == .touch(direction: .down, x: 200, y: 500))
        #expect(gesture.last == .touch(direction: .up, x: 200, y: 300))
    }

    @Test func optionWordsInsideTypedTextAreNotSelection() async throws {
        let plan = try await parse(["type", "literal --input-mode selected"])
        #expect(plan.count == 1)
        guard case let .hidMergeable(event) = try #require(plan.first) else {
            Issue.record("Expected legacy text events"); return
        }
        #expect(event.subEvents?.isEmpty == false)
    }

    @Test func batchContinueOnErrorOptionIsUnchanged() throws {
        let args = ["--udid", udid, "--step", "gesture scroll-up"]
        #expect(try Batch.parse(args).continueOnError == false)
        #expect(try Batch.parse(args + ["--continue-on-error"]).continueOnError == true)
    }
}
