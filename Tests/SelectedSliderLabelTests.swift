import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected slider label endpoints")
@MainActor
struct SelectedSliderLabelTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] { ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen] }

    @Test(arguments: ["minimum", "maximum"], [nil, "Slider", "Button"] as [String?])
    func labelRequestMatchesStandaloneAndBatch(endpoint: String, type: String?) throws {
        var args = ["--label", "Horizontal value", "--endpoint", endpoint, "--expected-pid", "42",
                    "--ax-preparation", "existing-bridge"]
        if let type { args += ["--element-type", type] }
        let direct = try Slider.parse(args + ["--udid", udid] + selection).selectedRequest()
        let batch = try SelectedBatchStep.request(["slider"] + args,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(direct.ax) == encoder.encode(batch.ax))
        #expect(direct.requestID != batch.requestID && direct.primitives.isEmpty && batch.primitives.isEmpty)
        #expect(batch.ax?.selectorKind == .label && batch.ax?.selectorValue == "Horizontal value")
        #expect(batch.ax?.elementType == type && batch.ax?.expectedPID == 42)
        #expect(batch.ax?.endpoint?.rawValue == endpoint && batch.ax?.preparation == .existingBridge)
        try JSONDecoder().decode(SelectedHIDRequest.self, from: encoder.encode(batch)).validate()
    }

    @Test(arguments: ["", " ", "\n"])
    func emptyLabelStopsBeforeAnySend(label: String) async throws {
        var sends = 0
        var rows: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["slider --label '\(label)' --endpoint maximum --expected-pid 42", "sleep 0"],
                input: SelectedInputOptions.parse(selection), simulatorUDID: udid,
                send: { _, _ in sends += 1; throw SelectedHIDFailure.busy }, emit: { rows.append($0) })
        }
        #expect(sends == 0 && rows.count == 1 && rows[0].status == .rejectedBeforeSend)
        #expect(rows[0].requestID == nil && rows[0].response == nil)
    }

    @Test(arguments: [
        ["--id", "target"], ["--value", "50"], ["--wait-timeout", "1"],
        ["--poll-interval", "0.1"], ["--element-type", " "]
    ])
    func labelDoesNotAdmitMixedOrUnsupportedOptions(extra: [String]) throws {
        #expect(throws: (any Error).self) {
            _ = try Slider.parse(["--label", "Horizontal value", "--endpoint", "maximum", "--expected-pid", "42",
                                  "--udid", udid] + selection + extra)
        }
    }

    @Test func labelRequestRejectsOldWireBeforeOwnership() throws {
        let current = try Slider.parse(["--label", "Horizontal value", "--endpoint", "maximum",
            "--expected-pid", "42", "--udid", udid] + selection).selectedRequest()
        #expect(current.version == 22)
        let old = SelectedHIDRequest(version: 18, requestID: current.requestID,
            screenID: current.screenID, screenUUID: current.screenUUID, operation: .complete,
            token: nil, primitives: [], ax: current.ax)
        var admission = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try admission.enter(old) }
        #expect(!admission.inFlight)
        try admission.enter(current)
        #expect(admission.inFlight)
    }

    @Test func labelExchangeFailureStopsWithoutReplay() async throws {
        var sends = 0
        var rows: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["slider --label 'Horizontal value' --endpoint maximum --expected-pid 42", "sleep 0"],
                input: SelectedInputOptions.parse(selection), simulatorUDID: udid,
                send: { item, _ in
                    sends += 1
                    #expect(item.ax?.selectorKind == .label)
                    throw SelectedHIDFailure.busy
                }, emit: { rows.append($0) })
        }
        #expect(sends == 1 && rows.count == 1 && rows[0].status == .outcomeUnknown)
        #expect(rows[0].requestID != nil && rows[0].response == nil)
    }

    @Test func sliderValueSelectorRemainsUnsupportedOnWire() throws {
        let ax = SelectedAXRequest(kind: .sliderEndpoint, expectedPID: 42, preparation: .existingBridge,
            endpoint: .maximum, selectorKind: .value, selectorValue: "50", preDelay: 0, postDelay: 0)
        #expect(throws: (any Error).self) { try ax.validate() }
    }
}
