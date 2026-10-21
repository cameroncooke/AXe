import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected tap value")
@MainActor
struct SelectedTapValueTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func parse(_ arguments: [String]) throws -> Tap {
        try Tap.parse(["--udid", udid] + selection + arguments)
    }
    private func valueRequest(_ value: String = "Ready") throws -> SelectedHIDRequest {
        try parse(["--value", value, "--expected-pid", "42"]).selectedRequest()
    }

    @Test(arguments: ["Ready", " Ready \n", "1", "1.0", "true", "TRUE", "9007199254740993"])
    func valueIsPreservedThroughParserWireAndLibrarySelector(value: String) throws {
        let original = try valueRequest(value)
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(original))
        try decoded.validate()
        #expect(decoded.version == 23 && decoded.requestID == original.requestID)
        #expect(decoded.screenID == 3 && decoded.screenUUID == UUID(uuidString: screen))
        #expect(decoded.operation == .complete && decoded.token == nil && decoded.primitives.isEmpty)
        let ax = try #require(decoded.ax)
        #expect(ax.kind == .tap && ax.selectorKind == .value && ax.selectorValue == value)
        #expect(ax.expectedPID == 42 && ax.preparation == .automationSession && ax.elementType == nil)
        guard case .value(let raw) = try #require(ax.selector) else {
            Issue.record("Value did not reach the library selector"); return
        }
        #expect(raw == value) // Matching normalizes at the library boundary, not in the wire.
    }

    @Test(arguments: ["Button", "button", " Button "])
    func exactOptionalTypeAndDelaysAreSharedWithBatch(type: String) throws {
        let arguments = ["--value", " Ready ", "--element-type", type, "--expected-pid", "42",
                         "--ax-preparation", "existing-bridge", "--pre-delay", "0.2", "--post-delay", "0.3"]
        let direct = try parse(arguments).selectedRequest()
        let batch = try SelectedBatchStep.request(["tap"] + arguments,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(direct.ax) == encoder.encode(batch.ax))
        #expect(direct.requestID != batch.requestID)
        let ax = try #require(batch.ax)
        #expect(ax.preDelay == 0.2 && ax.postDelay == 0.3 && ax.preparation == .existingBridge)
        guard case .valueWithType(let value, let elementType) = try #require(ax.selector) else {
            Issue.record("Value type filter was lost"); return
        }
        #expect(value == " Ready " && elementType == type)
    }

    @Test(arguments: [
        ["--value", "", "--expected-pid", "42"],
        ["--value", " \n", "--expected-pid", "42"],
        ["--value", "Ready", "-x", "1", "-y", "2", "--expected-pid", "42"],
        ["--value", "Ready", "--id", "target", "--expected-pid", "42"],
        ["--value", "Ready", "--label", "Target", "--expected-pid", "42"],
        ["--value", "Ready", "--semantic-press", "--expected-pid", "42"],
        ["--value", "Ready", "--element-type", " ", "--expected-pid", "42"],
        ["--value", "Ready", "--tap-style", "automatic", "--semantic-press", "--expected-pid", "42"],
        ["--value", "Ready", "--wait-timeout", "31", "--expected-pid", "42"],
        ["--value", "Ready", "--poll-interval", "0.1", "--expected-pid", "42"],
        ["--value", "Ready", "--expected-pid", "0"],
        ["--value", "Ready"]
    ])
    func invalidValueCombinationsRejectBeforeRequest(arguments: [String]) throws {
        #expect(throws: (any Error).self) { _ = try parse(arguments) }
    }

    @Test(arguments: [
        ["--input-mode", "selected"],
        ["--input-mode", "selected", "--screen-id", "3"],
        ["--input-mode", "selected", "--screen-uuid", "00000000-0000-0000-0000-000000000003"],
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", "invalid"]
    ])
    func valueRequiresCompleteValidSelection(options: [String]) throws {
        #expect(throws: (any Error).self) {
            _ = try Tap.parse(["--udid", udid, "--value", "Ready", "--expected-pid", "42"] + options)
        }
    }

    @Test(arguments: [SelectedAXRequest.Kind.describe, .describePoint, .sliderEndpoint, .semanticPress])
    func valueCannotEnterOtherAXOperations(kind: SelectedAXRequest.Kind) throws {
        let ax = SelectedAXRequest(kind: kind, expectedPID: 42, preparation: .existingBridge,
            endpoint: kind == .sliderEndpoint ? .minimum : nil, selectorKind: .value,
            selectorValue: "Ready", preDelay: 0, postDelay: 0,
            point: kind == .describePoint ? .init(x: 1, y: 2) : nil)
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: 3, screenUUID: UUID(uuidString: screen), operation: .complete,
            token: nil, primitives: [], ax: ax)
        var admission = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try admission.enter(request) }
        #expect(!admission.inFlight && admission.token == nil)
    }

    @Test func oldWireAndMixedPayloadsRejectBeforeOwnership() throws {
        let current = try valueRequest()
        let old = SelectedHIDRequest(version: 14, requestID: current.requestID,
            screenID: current.screenID, screenUUID: current.screenUUID, operation: .complete,
            token: nil, primitives: [], ax: current.ax)
        var withHome = current
        withHome.home = SelectedHomeRequest(duration: nil, expectedBoot: nil)
        let withPrimitive = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: current.screenID, screenUUID: current.screenUUID, operation: .complete,
            token: nil, primitives: [.touch(.down, x: 1, y: 2)], ax: current.ax)
        let withToken = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: current.screenID, screenUUID: current.screenUUID, operation: .complete,
            token: UUID(), primitives: [], ax: current.ax)
        for request in [old, withHome, withPrimitive, withToken] {
            var admission = SelectedHIDAdmission()
            #expect(throws: (any Error).self) { try admission.enter(request) }
            #expect(!admission.inFlight && admission.token == nil)
        }
        var admission = SelectedHIDAdmission()
        try admission.enter(current)
        #expect(admission.inFlight)
    }

    @Test func invalidBatchValueStopsBeforeSendAndSentinel() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["tap --value Ready -x 1 -y 2 --expected-pid 42", "tap -x 2 -y 3"],
                input: SelectedInputOptions.parse(selection), simulatorUDID: udid,
                send: { _, _ in sends += 1; throw CLIError(errorDescription: "Unexpected send") },
                emit: { receipts.append($0) })
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts[0].status == .rejectedBeforeSend && receipts[0].requestID == nil && receipts[0].response == nil)
    }

    @Test(arguments: ["failedBeforeInput", "failedNoReplay"])
    func failedValueResponseStopsBatchWithoutReplay(outcome: String) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["tap --value Ready --element-type Button --expected-pid 42", "tap -x 2 -y 3"],
                input: SelectedInputOptions.parse(selection), simulatorUDID: udid,
                send: { request, _ in
                    sends += 1
                    #expect(request.ax?.selectorKind == .value && request.ax?.selectorValue == "Ready")
                    #expect(request.ax?.elementType == "Button")
                    return SelectedHIDResponse(version: request.version, requestID: request.requestID,
                        brokerID: UUID(), outcome: outcome, token: nil, enqueuedEventCount: 0,
                        cleanup: "notNeeded", error: "Fresh target rejected", context: nil)
                }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1 && receipts[0].status == .failedResponse)
        #expect(receipts[0].response?.outcome == outcome)
    }

    @Test func legacyValueOptionsAndCoordinatePriorityRemainAvailable() throws {
        let legacy = try Tap.parse(["--udid", udid, "--value", " Ready ", "--element-type", "Button",
                                    "--tap-style", "physical", "--wait-timeout", "1", "--poll-interval", "0.1"])
        #expect(legacy.selectedInput.mode == .legacy && legacy.elementValue == " Ready ")
        #expect(legacy.elementType == "Button" && legacy.waitTimeout == 1 && legacy.pollInterval == 0.1)
        let coordinates = try Tap.parse(["--udid", udid, "-x", "1", "-y", "2", "--value", "Ready"])
        #expect(coordinates.selectedInput.mode == .legacy && coordinates.pointX == 1 && coordinates.pointY == 2)
    }
}
