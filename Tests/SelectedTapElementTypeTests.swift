import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected tap element type")
@MainActor
struct SelectedTapElementTypeTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func parse(_ arguments: [String]) throws -> Tap {
        try Tap.parse(["--udid", udid] + selection + arguments)
    }

    @Test(arguments: ["--id", "--label"])
    func typedSelectorSurvivesWireAndBatch(option: String) throws {
        let arguments = [option, "Tap target", "--element-type", "Button", "--expected-pid", "42"]
        let direct = try parse(arguments).selectedRequest()
        let batch = try SelectedBatchStep.request(["tap"] + arguments,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(direct.ax) == encoder.encode(batch.ax))
        #expect(direct.requestID != batch.requestID)
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: encoder.encode(direct))
        try decoded.validate()
        #expect(decoded.version == SelectedHIDRequest.version && decoded.ax?.elementType == "Button")
        #expect(decoded.ax?.expectedPID == 42 && decoded.primitives.isEmpty)
        let selector = try #require(decoded.ax?.selector)
        switch selector {
        case .identifierWithType(let value, let type):
            #expect(option == "--id" && value == "Tap target" && type == "Button")
        case .labelWithType(let value, let type):
            #expect(option == "--label" && value == "Tap target" && type == "Button")
        default: Issue.record("Type filter was lost before library resolution")
        }
    }

    @Test func omittedTypeKeepsExistingSelectorAndLegacyOption() throws {
        let request = try parse(["--id", "feature.tap", "--expected-pid", "42"]).selectedRequest()
        #expect(request.ax?.elementType == nil)
        guard case .identifier("feature.tap") = try #require(request.ax?.selector) else {
            Issue.record("The old selector case changed"); return
        }
        let bytes = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: bytes)
        #expect(decoded.ax?.elementType == nil)
        let legacy = try Tap.parse(["--udid", udid, "--label", "Tap target", "--element-type", "Button"])
        #expect(legacy.selectedInput.mode == .legacy && legacy.elementType == "Button")
    }

    @Test(arguments: [
        ["-x", "1", "-y", "2", "--element-type", "Button"],
        ["--id", "target", "--semantic-press", "--element-type", "CheckBox", "--expected-pid", "42"],
        ["--id", "target", "--element-type", "", "--expected-pid", "42"],
        ["--id", "target", "--element-type", "  ", "--expected-pid", "42"],
        ["--element-type", "Button", "--expected-pid", "42"],
        ["--value", "1", "--semantic-press", "--element-type", "Button", "--expected-pid", "42"],
        ["--id", "target", "--label", "target", "--element-type", "Button", "--expected-pid", "42"]
    ])
    func unsupportedCombinationsRejectBeforeSend(arguments: [String]) throws {
        #expect(throws: (any Error).self) { _ = try parse(arguments) }
    }

    @Test func unsupportedBatchTypeStopsBeforeSend() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["tap -x 1 -y 2 --element-type Button", "tap -x 2 -y 3"],
                input: SelectedInputOptions.parse(selection), simulatorUDID: udid,
                send: { _, _ in sends += 1; throw CLIError(errorDescription: "Unexpected send") },
                emit: { receipts.append($0) })
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts[0].status == .rejectedBeforeSend && receipts[0].requestID == nil)
    }

    @Test(arguments: [SelectedAXRequest.Kind.describe, .describePoint, .semanticPress])
    func typeCannotBeSmuggledIntoOtherAXOperations(kind: SelectedAXRequest.Kind) throws {
        var ax = SelectedAXRequest(kind: kind, expectedPID: 42,
            endpoint: nil,
            selectorKind: kind == .semanticPress ? .id : nil,
            selectorValue: kind == .semanticPress ? "target" : nil,
            preDelay: 0, postDelay: 0,
            point: kind == .describePoint ? .init(x: 1, y: 2) : nil)
        try ax.validate()
        ax.elementType = "Button"
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: UUID(uuidString: screen), operation: .complete, token: nil, primitives: [], ax: ax)
        var owner = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try owner.enter(request) }
        #expect(!owner.inFlight)
    }

    @Test func oldWireCannotSilentlyDropType() throws {
        let request = try parse(["--id", "target", "--element-type", "Button", "--expected-pid", "42"]).selectedRequest()
        let old = SelectedHIDRequest(version: 13, requestID: request.requestID,
            screenID: request.screenID, screenUUID: request.screenUUID, operation: .complete,
            token: nil, primitives: [], ax: request.ax)
        var owner = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try owner.enter(old) }
        #expect(!owner.inFlight)
    }

    @Test func targetRejectionStopsBatchWithoutReplay() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["tap --label Target --element-type Button --expected-pid 42",
                "tap -x 2 -y 3"], input: SelectedInputOptions.parse(selection), simulatorUDID: udid,
                send: { request, _ in
                    sends += 1
                    #expect(request.ax?.elementType == "Button")
                    return SelectedHIDResponse(version: request.version, requestID: request.requestID,
                        brokerID: UUID(), outcome: "failedBeforeInput", token: nil, enqueuedEventCount: 0,
                        cleanup: "notNeeded", error: "Target rejected", context: nil)
                }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1 && receipts[0].status == .failedResponse)
    }
}
