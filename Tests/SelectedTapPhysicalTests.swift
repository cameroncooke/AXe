import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected physical tap")
@MainActor
struct SelectedTapPhysicalTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func parse(_ arguments: [String]) throws -> Tap {
        try Tap.parse(["--udid", udid] + selection + arguments)
    }
    private func samePayload(_ left: SelectedHIDRequest, _ right: SelectedHIDRequest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(left.version == SelectedHIDRequest.version && right.version == left.version)
        #expect(left.requestID != right.requestID)
        for request in [left, right] {
            try request.validate()
            #expect(request.screenID == 3 && request.screenUUID == UUID(uuidString: screen))
            #expect(request.operation == .complete && request.token == nil)
            #expect(request.path == nil && request.pinch == nil && request.gesture == nil)
            #expect(request.home == nil && request.keyboard == nil && request.hinge == nil)
        }
        #expect(try encoder.encode(left.primitives) == encoder.encode(right.primitives))
        #expect(try encoder.encode(left.ax) == encoder.encode(right.ax))
    }

    @Test(arguments: [
        ["-x", "12.5", "-y", "20.25"],
        ["-x", "12.5", "-y", "20.25", "--pre-delay", "0.2", "--post-delay", "0.3"],
        ["--id", "target", "--expected-pid", "42"],
        ["--id", "target", "--expected-pid", "42", "--element-type", "Button", "--pre-delay", "0.2"],
        ["--label", "Tap target", "--expected-pid", "42"],
        ["--label", "Tap target", "--expected-pid", "42", "--element-type", "Button", "--post-delay", "0.3"],
        ["--value", " Ready ", "--expected-pid", "42"],
        ["--value", " Ready ", "--expected-pid", "42", "--element-type", "TextField", "--ax-preparation", "existing-bridge"]
    ])
    func physicalAndOmittedStyleProduceEquivalentRequests(arguments: [String]) throws {
        let implicit = try parse(arguments)
        let physical = try parse(arguments + ["--tap-style", "physical"])
        #expect(implicit.tapStyle == nil && physical.tapStyle == .physical)
        let direct = try physical.selectedRequest()
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(direct))
        #expect(decoded.requestID == direct.requestID)
        try samePayload(implicit.selectedRequest(), decoded)
    }

    @Test func coordinatePhysicalKeepsDownHoldUpAndDelays() throws {
        let request = try parse(["-x", "12.5", "-y", "20.25", "--tap-style", "physical",
                                 "--pre-delay", "0.2", "--post-delay", "0.3"]).selectedRequest()
        #expect(request.ax == nil)
        #expect(request.event == .composite([.delay(0.2), .touch(direction: .down, x: 12.5, y: 20.25),
            .delay(TapTiming.defaultHoldDuration), .touch(direction: .up, x: 12.5, y: 20.25), .delay(0.3)]))
    }

    @Test(arguments: [
        ["-x", "12.5", "-y", "20.25"],
        ["--id", "target", "--expected-pid", "42", "--element-type", "Button"],
        ["--label", "Tap target", "--expected-pid", "42"],
        ["--value", "Ready", "--expected-pid", "42", "--element-type", "TextField"]
    ])
    func batchUsesTheSamePhysicalRequest(arguments: [String]) throws {
        let options = arguments + ["--tap-style", "physical", "--pre-delay", "0.2", "--post-delay", "0.3"]
        let direct = try parse(options).selectedRequest()
        let batch = try SelectedBatchStep.request(["tap"] + options,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        try samePayload(direct, batch)
    }

    @Test(arguments: ["unknown"])
    func unknownStyleStillRejects(style: String) throws {
        for arguments in [["-x", "1", "-y", "2"], ["--id", "target", "--expected-pid", "42"]] {
            #expect(throws: (any Error).self) { _ = try parse(arguments + ["--tap-style", style]) }
        }
    }

    @Test(arguments: ["physical", "automatic", "simulator"])
    func semanticPressRejectsEveryExplicitStyle(style: String) throws {
        #expect(throws: (any Error).self) {
            _ = try parse(["--id", "target", "--expected-pid", "42", "--semantic-press", "--tap-style", style])
        }
        let unchanged = try parse(["--id", "target", "--expected-pid", "42", "--semantic-press"])
        #expect(try unchanged.selectedRequest().ax?.kind == .semanticPress)
    }

    @Test(arguments: [["--wait-timeout", "31"], ["--poll-interval", "0.1"]])
    func physicalRejectsInvalidPolling(extra: [String]) throws {
        #expect(throws: (any Error).self) {
            _ = try parse(["--id", "target", "--expected-pid", "42", "--tap-style", "physical"] + extra)
        }
    }

    @Test(arguments: [
        "tap --id target --expected-pid 42 --tap-style simulator --semantic-press",
        "tap --id target --expected-pid 42 --tap-style automatic --semantic-press",
        "tap --id target --expected-pid 42 --tap-style physical --wait-timeout 31",
        "tap --id target --expected-pid 42 --tap-style physical --semantic-press"
    ])
    func invalidPhysicalCombinationsStopBeforeSend(line: String) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [line, "tap -x 2 -y 3"],
                input: SelectedInputOptions.parse(selection), simulatorUDID: udid,
                send: { _, _ in sends += 1; throw CLIError(errorDescription: "Unexpected send") },
                emit: { receipts.append($0) })
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts[0].status == .rejectedBeforeSend && receipts[0].requestID == nil && receipts[0].response == nil)
    }
}
