import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected batch slider endpoints")
@MainActor
struct SelectedBatchSliderTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func options() throws -> SelectedInputOptions { try .parse(selection) }
    private func request(_ line: String) throws -> SelectedHIDRequest {
        try SelectedBatchStep.request(ShellTokenizer.tokenize(line), input: options(), simulatorUDID: udid)
    }
    private let minimum = "slider --id feature.slider --endpoint minimum --expected-pid 123"

    @Test(arguments: ["minimum", "maximum"], ["automation-session", "existing-bridge"])
    func endpointRequestMatchesStandalone(endpoint: String, preparation: String) throws {
        let line = "slider --id feature.slider --endpoint \(endpoint) --expected-pid 123 --ax-preparation \(preparation)"
        let batch = try request(line)
        let standalone = try Slider.parse(Array(ShellTokenizer.tokenize(line).dropFirst()) + ["--udid", udid] + selection)
        let direct = try standalone.selectedRequest()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(batch.ax) == encoder.encode(direct.ax))
        #expect(batch.ax?.kind == .sliderEndpoint && batch.ax?.expectedPID == 123)
        #expect(batch.ax?.selectorKind == .id && batch.ax?.selectorValue == "feature.slider")
        #expect(batch.ax?.endpoint?.rawValue == endpoint && batch.ax?.preparation.rawValue == preparation)
        #expect(batch.operation == .complete && batch.token == nil && batch.primitives.isEmpty)
        #expect(batch.path == nil && batch.keyboard == nil && batch.hinge == nil)
        #expect(batch.screenID == 3 && batch.screenUUID == UUID(uuidString: screen))
        #expect(batch.requestID != direct.requestID)
        try JSONDecoder().decode(SelectedHIDRequest.self, from: encoder.encode(batch)).validate()
    }

    @Test(arguments: [
        "slider --endpoint minimum --expected-pid 123",
        "slider --id feature.slider --endpoint minimum",
        "slider --id feature.slider --endpoint minimum --expected-pid 0",
        "slider --id feature.slider --expected-pid 123",
        "slider --id feature.slider --endpoint midpoint --expected-pid 123",
        "slider --id feature.slider --endpoint minimum --value 25 --expected-pid 123",
        "slider --id feature.slider --label Volume --endpoint minimum --expected-pid 123",
        "slider --id feature.slider --endpoint minimum --element-type '' --expected-pid 123",
        "slider --id feature.slider --endpoint minimum --wait-timeout 1 --expected-pid 123",
        "slider --id feature.slider --endpoint minimum --poll-interval 0.1 --expected-pid 123",
        "slider --id feature.slider --endpoint minimum --expected-pid 123 --screen-id 1",
        "slider --id feature.slider --endpoint minimum --expected-pid 123 --input-mode legacy"
    ])
    func invalidSliderStopsBeforeSend(line: String) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [line, minimum], input: options(), simulatorUDID: udid,
                send: { item, _ in sends += 1; return try response(item) }, emit: { receipts.append($0) })
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts.first?.status == .rejectedBeforeSend)
        #expect(receipts.first?.requestID == nil && receipts.first?.response == nil)
    }

    @Test(arguments: ["endpointObserved", "alreadyAtEndpoint"])
    func semanticCompletionAllowsNextStepWithoutHID(outcome: String) async throws {
        var events: [String] = []
        var ids: [UUID] = []
        var receipts: [SelectedBatchStepReceipt] = []
        try await SelectedBatchRunner.run(lines: [minimum, minimum], input: options(), simulatorUDID: udid,
            send: { item, actualUDID in
                #expect(actualUDID == udid)
                ids.append(item.requestID); events.append("send")
                return try response(item, outcome: outcome)
            }, emit: { receipt in receipts.append(receipt); events.append("receipt") })
        #expect(events == ["send", "receipt", "send", "receipt"] && Set(ids).count == 2)
        #expect(receipts.map(\.status) == [.completed, .completed])
        #expect(receipts.allSatisfy { $0.response?.enqueuedEventCount == 0 && $0.response?.cleanup == "notNeeded" })
        #expect(receipts.allSatisfy { $0.requestID == $0.response?.requestID })
    }

    @Test(arguments: ReceiptFault.allCases)
    func unrelatedOrIncompleteSemanticReceiptStopsWithoutReplay(fault: ReceiptFault) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [minimum, "tap -x 10 -y 20"], input: options(), simulatorUDID: udid,
                send: { item, _ in sends += 1; return try response(item, fault: fault) },
                emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1)
        #expect(receipts.first?.status == .failedResponse && receipts.first?.response != nil)
    }

    @Test(arguments: [0, 1, 20, 21])
    func semanticActionCountBoundaries(count: Int) throws {
        let item = try request(minimum)
        let observed = try response(item, actionCount: count)
        let already = try response(item, outcome: "alreadyAtEndpoint", actionCount: count)
        #expect(SelectedBatchRunner.completed(observed, for: item) == (count >= 1 && count <= 20))
        #expect(SelectedBatchRunner.completed(already, for: item) == (count == 0))
    }

    @Test func successfulSliderReceiptDoesNotCompleteHIDTap() throws {
        let slider = try request(minimum)
        let tap = try request("tap -x 10 -y 20")
        let semantic = try response(slider, identity: tap.requestID)
        #expect(!SelectedBatchRunner.completed(semantic, for: tap))
    }

    @Test func laterInvalidSliderPreservesCompletedSemanticReceipt() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [minimum, "slider --id feature.slider --value 25 --expected-pid 123", minimum],
                input: options(), simulatorUDID: udid,
                send: { item, _ in sends += 1; return try response(item) }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.map(\.status) == [.completed, .rejectedBeforeSend])
        #expect(receipts.map(\.index) == [1, 2])
        #expect(receipts[0].response?.ax?.slider?.outcome == "endpointObserved")
        #expect(receipts[1].requestID == nil && receipts[1].response == nil)
    }

    private enum ExchangeFailure: Error { case disconnected }
    @Test func sliderExchangeFailureDoesNotReplayPotentialAction() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [minimum, minimum], input: options(), simulatorUDID: udid,
                send: { _, _ in sends += 1; throw ExchangeFailure.disconnected }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1)
        #expect(receipts.first?.status == .outcomeUnknown && receipts.first?.response == nil)
    }


    @Test(arguments: ["Slider", "slider", "Button", " Slider "], ["minimum", "maximum"])
    func exactTypeIsPreservedByStandaloneBatchAndWire(type: String, endpoint: String) throws {
        let arguments = ["--id", "feature.slider", "--endpoint", endpoint, "--expected-pid", "123",
                         "--element-type", type, "--ax-preparation", "existing-bridge"]
        let direct = try Slider.parse(arguments + ["--udid", udid] + selection).selectedRequest()
        let batch = try SelectedBatchStep.request(["slider"] + arguments, input: options(), simulatorUDID: udid)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(direct.ax) == encoder.encode(batch.ax))
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: encoder.encode(batch))
        try decoded.validate()
        #expect(decoded.ax?.elementType == type && decoded.ax?.selectorKind == .id)
        #expect(decoded.ax?.expectedPID == 123 && decoded.ax?.preparation == .existingBridge)
        #expect(decoded.ax?.endpoint?.rawValue == endpoint && decoded.primitives.isEmpty)
        #expect(direct.requestID != batch.requestID)
    }

    @Test(arguments: ["endpointObserved", "alreadyAtEndpoint"])
    func filteredSemanticCompletionRequiresNativeTypeEvidence(outcome: String) throws {
        let item = try request(minimum + " --element-type Slider")
        let actual = try response(item, outcome: outcome, sampleTypes: ["Slider", "Slider", "Slider"],
                                  actionType: "Slider")
        #expect(SelectedBatchRunner.completed(actual, for: item))
        #expect(actual.ax?.slider?.samples.allSatisfy { $0.elementType == .slider } == true)
        #expect(actual.enqueuedEventCount == 0)
    }

    enum TypeEvidenceFault: CaseIterable { case noSamples, missingSample, missingAction, differentRequest }
    @Test(arguments: TypeEvidenceFault.allCases)
    func missingOrMismatchedTypeEvidenceStopsWithoutReplay(fault: TypeEvidenceFault) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        let line = minimum + " --element-type " + (fault == .differentRequest ? "Button" : "Slider")
        let samples: [String?] = fault == .noSamples ? [] : ["Slider", fault == .missingSample ? nil : "Slider"]
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [line, minimum], input: options(), simulatorUDID: udid,
                send: { item, _ in
                    sends += 1
                    return try response(item, sampleTypes: samples,
                                        actionType: fault == .missingAction ? nil : "Slider")
                }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1 && receipts[0].status == .failedResponse)
    }

    @Test func unfilteredReceiptKeepsItsExistingCompletionContract() throws {
        let item = try request(minimum)
        #expect(item.ax?.elementType == nil)
        #expect(SelectedBatchRunner.completed(try response(item), for: item))
    }

    @Test func oldWireRejectsFilteredRequestBeforeOwnership() throws {
        let current = try request(minimum + " --element-type Slider")
        #expect(current.version == 28)
        let old = SelectedHIDRequest(version: 27, requestID: current.requestID,
            screenID: current.screenID, screenUUID: current.screenUUID, operation: .complete,
            token: nil, primitives: [], ax: current.ax)
        var admission = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try admission.enter(old) }
        #expect(!admission.inFlight && admission.token == nil)
        try admission.enter(current)
        #expect(admission.inFlight)
    }

    @Test(arguments: ["Button", "slider", " Slider "])
    func receiptTypeCannotDecodeUnboundedNativeText(type: String) throws {
        let bytes = try JSONEncoder().encode(type)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SelectedSliderResult.ElementType.self, from: bytes)
        }
    }


    @Test(arguments: [nil, "Slider", "Button", String(repeating: "x", count: 8192)] as [String?])
    func capabilityMappingKeepsOnlyBoundedActualType(type: String?) throws {
        let typeJSON = String(decoding: try JSONEncoder().encode(type), as: UTF8.self)
        let capability = """
        {"snapshotID":"00000000-0000-0000-0000-000000000010",
         "observation":{"simulatorUDID":"test","bootIdentity":"boot","screenID":3,
          "screenUniqueID":"00000000-0000-0000-0000-000000000003","axDisplayID":3,
          "nativePixelWidth":900,"nativePixelHeight":1800,"scale":3,"rotation":0,"poseRevision":"open"},
         "node":{"type":\(typeJSON),"AXUniqueId":"target","pid":123},
         "raw":{"advertisedAttributes":[],"declaredActions":[],"attributes":{}},"geometryStatus":"unknown"}
        """
        let sample = try JSONDecoder().decode(FBSimulatorSliderSample.self, from: Data("""
        {"phase":"initial","elapsedSeconds":0,"capabilities":\(capability)}
        """.utf8))
        let action = try JSONDecoder().decode(FBSimulatorSliderActionReceipt.self, from: Data("""
        {"action":"increment","verifiedBeforeAction":\(capability),
         "callStartedUptime":1,"callReturnedUptime":2,"guestAcknowledged":false}
        """.utf8))
        let mappedSample = SelectedSliderResult.Sample(sample)
        let mappedAction = SelectedSliderResult.Action(action)
        #expect(mappedSample.elementType?.rawValue == (type == "Slider" ? "Slider" : nil))
        #expect(mappedAction.elementType == mappedSample.elementType)
        #expect(try JSONEncoder().encode(mappedSample).count < 2048)
        #expect(try JSONEncoder().encode(mappedAction).count < 2048)
    }

    enum ReceiptFault: String, CaseIterable {
        case version, requestIdentity, screenID, screenUUID, cleanup, hidEvents, error, token, quarantine
        case missingAX, missingSlider, kind, pid, preparation, endpoint, outerOutcome, delivery
        case reason, truncatedReason, attemptCount, actionArrayCount, actionLimit, failedStaleContext
    }

    // Synthetic public wire receipts exercise batch admission only. The library controller
    // owns target freshness, value/domain checks and settled native samples; these are not native proofs.
    private struct WireSample: Encodable {
        let phase = "initial"
        let elapsedSeconds = 0.0
        let snapshotID = UUID()
        let elementType: String?
        let minimum = 0.0
        let maximum = 100.0
        let tolerance = 0.07
        let value = 0.0
    }
    private struct WireAction: Encodable {
        var elementType: String? = nil
        let action = "decrement"
        let valueBeforeAction = 10.0
        let callStartedUptime = 101.0
        let callReturnedUptime = 101.1
        let guestAcknowledged = false
    }
    private struct WireSlider: Encodable {
        var outcome = "endpointObserved"
        var reason: String?
        var reasonTruncated = false
        var delivery = "valueObserved"
        var endpoint = "minimum"
        var actionAttempts = 1
        var actionsReturned = 1
        let startedUptime = 100.0
        let deadlineUptime = 115.0
        let elapsedSeconds = 6.0
        var samples: [WireSample] = []
        var actions = [WireAction()]
    }

    private func response(_ item: SelectedHIDRequest, outcome: String = "endpointObserved",
                          identity: UUID? = nil, actionCount: Int? = nil, fault: ReceiptFault? = nil,
                          sampleTypes: [String?] = [], actionType: String? = nil) throws -> SelectedHIDResponse {
        let expected = try #require(item.ax)
        var wire = WireSlider()
        wire.outcome = outcome
        wire.endpoint = try #require(expected.endpoint).rawValue
        if outcome == "alreadyAtEndpoint" {
            wire.delivery = "notDispatched"; wire.actionAttempts = 0; wire.actionsReturned = 0; wire.actions = []
        }
        if let actionCount {
            wire.actionAttempts = actionCount; wire.actionsReturned = actionCount
            wire.actions = Array(repeating: WireAction(), count: actionCount)
        }
        switch fault {
        case .endpoint: wire.endpoint = "maximum"
        case .delivery: wire.delivery = "uncertain"
        case .reason: wire.reason = "unexpected reason"
        case .truncatedReason: wire.reasonTruncated = true
        case .attemptCount: wire.actionAttempts += 1
        case .actionArrayCount: wire.actions = []
        case .actionLimit:
            wire.actionAttempts = 21; wire.actionsReturned = 21; wire.actions = Array(repeating: WireAction(), count: 21)
        case .failedStaleContext: wire.outcome = "failed"; wire.reason = "staleContext"
        default: break
        }
        wire.samples = sampleTypes.map { WireSample(elementType: $0) }
        wire.actions = wire.actions.map { action in
            var action = action; action.elementType = actionType; return action
        }
        let slider = try JSONDecoder().decode(SelectedSliderResult.self, from: JSONEncoder().encode(wire))
        var ax = SelectedAXResult(kind: fault == .kind ? .describe : .sliderEndpoint,
            expectedPID: fault == .pid ? 124 : expected.expectedPID,
            preparation: fault == .preparation ? .existingBridge : expected.preparation)
        ax.slider = fault == .missingSlider ? nil : slider
        if fault == .failedStaleContext { ax.failure = .sliderFailed }
        let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "test-boot",
            screenID: fault == .screenID ? 1 : 3,
            screenUniqueID: fault == .screenUUID ? UUID().uuidString : screen, axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 900, height: 1800), scale: 3, rotation: .rot0), poseRevision: "test-pose")
        var result = SelectedHIDResponse(version: fault == .version ? 27 : item.version,
            requestID: fault == .requestIdentity ? UUID() : identity ?? item.requestID,
            brokerID: UUID(), outcome: fault == .outerOutcome ? "enqueuedAndDrained" : wire.outcome,
            token: fault == .token ? UUID() : nil, enqueuedEventCount: fault == .hidEvents ? 1 : 0,
            cleanup: fault == .cleanup ? "uncertain" : "notNeeded",
            error: fault == .error ? "failed" : nil, context: SelectedHIDContext(observation))
        result.ax = fault == .missingAX ? nil : ax
        if fault == .quarantine { result.quarantine = .init(recordPath: nil, persisted: false, error: "storage failed") }
        return try JSONDecoder().decode(SelectedHIDResponse.self, from: JSONEncoder().encode(result))
    }
}
