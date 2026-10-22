import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected simulator tap")
@MainActor
struct SelectedTapSimulatorTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func parse(_ arguments: [String]) throws -> Tap {
        try Tap.parse(["--udid", udid] + selection + arguments)
    }
    private func observation() throws -> FBSimulatorHIDSessionObservation {
        try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "test-boot",
            screenID: 3, screenUniqueID: screen, axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 300, height: 600), scale: 3, rotation: .rot0),
            poseRevision: "test-pose")
    }

    @Test(arguments: [false, true])
    func simulatorCoordinatesUseFactoryWithoutHold(withDelays: Bool) throws {
        var arguments = ["-x", "12.5", "-y", "20.25", "--tap-style", "simulator"]
        if withDelays { arguments += ["--pre-delay", "0.2", "--post-delay", "0.3"] }
        let request = try parse(arguments).selectedRequest()
        try request.validate()
        #expect(request.version == 25 && request.ax == nil && request.token == nil)
        #expect(request.operation == .complete && request.screenID == 3 && request.screenUUID == UUID(uuidString: screen))
        let touch: [FBSimulatorHIDEvent] = [.touch(direction: .down, x: 12.5, y: 20.25),
                                          .touch(direction: .up, x: 12.5, y: 20.25)]
        #expect(FBSimulatorHIDEvent.tapAt(x: 12.5, y: 20.25) == .composite(touch))
        let expected = withDelays ? [.delay(0.2)] + touch + [.delay(0.3)] : touch
        #expect(request.event == .composite(expected))
        let plan = try FBSimulatorHIDSession.preflight(request.event, observation: observation())
        #expect(plan.primitiveCount == 2 && plan.requestedDelaySeconds == (withDelays ? 0.5 : 0))
    }

    @Test(arguments: [false, true])
    func coordinateSimulatorBatchUsesTheSameFactoryPlan(withDelays: Bool) throws {
        var arguments = ["-x", "12.5", "-y", "20.25", "--tap-style", "simulator"]
        if withDelays { arguments += ["--pre-delay", "0.2", "--post-delay", "0.3"] }
        let direct = try parse(arguments).selectedRequest()
        let batch = try SelectedBatchStep.request(["tap"] + arguments,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        try batch.validate()
        #expect(batch.ax == nil && batch.event == direct.event && batch.requestID != direct.requestID)
        #expect(batch.version == 25 && batch.operation == .complete && batch.token == nil)
        #expect(batch.screenID == direct.screenID && batch.screenUUID == direct.screenUUID)
    }

    @Test(arguments: [
        ["--id", "target"], ["--id", "target", "--element-type", "Button"],
        ["--label", "Tap target"], ["--label", "Tap target", "--element-type", "Button"],
        ["--value", " Ready "], ["--value", " Ready ", "--element-type", "TextField"]
    ])
    func selectorStyleTypeAndDelaysReachWireAndBatch(selectorArguments: [String]) throws {
        let arguments = selectorArguments + ["--expected-pid", "42", "--tap-style", "simulator",
            "--ax-preparation", "existing-bridge", "--pre-delay", "0.2", "--post-delay", "0.3"]
        let direct = try parse(arguments).selectedRequest()
        let batch = try SelectedBatchStep.request(["tap"] + arguments,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(direct.ax) == encoder.encode(batch.ax))
        #expect(direct.requestID != batch.requestID && direct.primitives.isEmpty && batch.primitives.isEmpty)
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: encoder.encode(direct))
        try decoded.validate()
        let ax = try #require(decoded.ax)
        #expect(ax.kind == .tap && ax.tapStyle == .simulator && ax.expectedPID == 42)
        #expect(ax.preparation == .existingBridge && ax.preDelay == 0.2 && ax.postDelay == 0.3)
        #expect(ax.selectorValue == selectorArguments[1])
        #expect(ax.elementType == (selectorArguments.count == 4 ? selectorArguments[3] : nil))
        #expect(ax.selectorKind?.rawValue == String(selectorArguments[0].dropFirst(2)))
        #expect(ax.selector != nil)
        // This is the same builder used after the real AX operation obtains its guarded point.
        let event = try ax.tapEvent(at: CGPoint(x: 12.5, y: 20.25))
        #expect(event == .tapAt(x: 12.5, y: 20.25))
        let plan = try FBSimulatorHIDSession.preflight(event, observation: observation())
        #expect(plan.primitiveCount == 2 && plan.requestedDelaySeconds == 0)
    }

    @Test(arguments: [[], ["--tap-style", "physical"]])
    func omittedAndPhysicalKeepExistingHoldAndAbsentWireField(style: [String]) throws {
        let coordinate = try parse(["-x", "12.5", "-y", "20.25"] + style).selectedRequest()
        let ax = try #require(parse(["--id", "target", "--expected-pid", "42"] + style).selectedRequest().ax)
        let expected = FBSimulatorHIDEvent.composite([.touch(direction: .down, x: 12.5, y: 20.25),
            .delay(0.1), .touch(direction: .up, x: 12.5, y: 20.25)])
        #expect(coordinate.event == expected && ax.tapStyle == nil)
        #expect(try ax.tapEvent(at: CGPoint(x: 12.5, y: 20.25)) == expected)
        #expect(!String(decoding: try JSONEncoder().encode(ax), as: UTF8.self).contains("tapStyle"))
    }

    @Test(arguments: [SelectedTapStyle.physical, .simulator])
    func typedStyleRoundTripKeepsExactEvent(style: SelectedTapStyle) throws {
        var ax = try #require(parse(["--id", "target", "--expected-pid", "42"]).selectedRequest().ax)
        ax.tapStyle = style
        let decoded = try JSONDecoder().decode(SelectedAXRequest.self, from: JSONEncoder().encode(ax))
        try decoded.validate()
        #expect(decoded.tapStyle == style)
        let event = try decoded.tapEvent(at: CGPoint(x: 12.5, y: 20.25))
        let expected = style == .simulator ? FBSimulatorHIDEvent.tapAt(x: 12.5, y: 20.25)
            : FBSimulatorHIDEvent.tapAt(x: 12.5, y: 20.25, duration: 0.1)
        #expect(event == expected)
    }

    @Test(arguments: [SelectedAXRequest.Kind.describe, .describePoint, .sliderEndpoint, .semanticPress])
    func styleCannotEnterOtherAXOperations(kind: SelectedAXRequest.Kind) throws {
        var ax = SelectedAXRequest(kind: kind, expectedPID: 42, preparation: .existingBridge,
            endpoint: kind == .sliderEndpoint ? .minimum : nil,
            selectorKind: kind == .sliderEndpoint || kind == .semanticPress ? .id : nil,
            selectorValue: kind == .sliderEndpoint || kind == .semanticPress ? "target" : nil,
            preDelay: 0, postDelay: 0, point: kind == .describePoint ? .init(x: 1, y: 2) : nil)
        try ax.validate()
        #expect(throws: (any Error).self) { _ = try ax.tapEvent(at: CGPoint(x: 1, y: 2)) }
        for style in [SelectedTapStyle.physical, .simulator] {
            ax.tapStyle = style
            let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                screenID: 3, screenUUID: UUID(uuidString: screen), operation: .complete,
                token: nil, primitives: [], ax: ax)
            var owner = SelectedHIDAdmission()
            #expect(throws: (any Error).self) { try owner.enter(request) }
            #expect(!owner.inFlight && owner.token == nil)
        }
    }

    @Test(arguments: ["unknown", "SIMULATOR"])
    func unsupportedWireStyleCannotDecode(style: String) throws {
        let bytes = Data("""
        {"kind":"tap","expectedPID":42,"preparation":"existing-bridge",
         "selectorKind":"id","selectorValue":"target","preDelay":0,"postDelay":0,"tapStyle":"\(style)"}
        """.utf8)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(SelectedAXRequest.self, from: bytes) }
    }

    @Test func wireFifteenCannotSilentlyDropSimulatorStyle() throws {
        #expect(SelectedHIDRequest.version == 25)
        let current = try parse(["--id", "target", "--expected-pid", "42", "--tap-style", "simulator"]).selectedRequest()
        let old = SelectedHIDRequest(version: 15, requestID: current.requestID, screenID: current.screenID,
            screenUUID: current.screenUUID, operation: .complete, token: nil, primitives: [], ax: current.ax)
        var owner = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try owner.enter(old) }
        #expect(!owner.inFlight && owner.token == nil)
        try owner.enter(current)
        #expect(owner.inFlight)
    }

    @Test(arguments: [
        ["-x", "1", "-y", "2", "--tap-style", "automatic", "--wait-timeout", "1"],
        ["--id", "target", "--expected-pid", "42", "--tap-style", "automatic", "--semantic-press"],
        ["--id", "target", "--expected-pid", "42", "--tap-style", "simulator", "--semantic-press"],
        ["--id", "target", "--expected-pid", "42", "--tap-style", "physical", "--semantic-press"],
        ["--id", "target", "--expected-pid", "42", "--tap-style", "simulator", "--wait-timeout", "31"],
        ["--id", "target", "--expected-pid", "42", "--tap-style", "simulator", "--poll-interval", "0.1"],
        ["--id", "target", "--tap-style", "simulator"],
        ["-x", "1", "-y", "2", "--tap-style", "simulator", "--element-type", "Button"]
    ])
    func unsupportedOptionsStillReject(arguments: [String]) throws {
        #expect(throws: (any Error).self) { _ = try parse(arguments) }
    }

    @Test(arguments: ["simulator", "physical"])
    func batchLevelStyleStillRejects(style: String) throws {
        #expect(throws: (any Error).self) {
            _ = try Batch.parse(["--udid", udid] + selection + ["--tap-style", style, "--step", "tap -x 1 -y 2"])
        }
    }

    @Test(arguments: [
        "tap --id target --expected-pid 42 --tap-style automatic --semantic-press",
        "tap --id target --expected-pid 42 --tap-style simulator --wait-timeout 31",
        "tap --id target --expected-pid 42 --tap-style simulator --semantic-press"
    ])
    func invalidBatchStyleStopsBeforeSendAndSentinel(line: String) async throws {
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

    @Test(arguments: ["failedBeforeInput", "failedNoReplay"])
    func failedSimulatorResponseStopsBatchWithoutReplay(outcome: String) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["tap --id target --expected-pid 42 --tap-style simulator", "tap -x 2 -y 3"],
                input: SelectedInputOptions.parse(selection), simulatorUDID: udid,
                send: { request, _ in
                    sends += 1
                    #expect(request.ax?.tapStyle == .simulator)
                    return SelectedHIDResponse(version: request.version, requestID: request.requestID,
                        brokerID: UUID(), outcome: outcome, token: nil, enqueuedEventCount: 0,
                        cleanup: "notNeeded", error: "Target or input rejected", context: nil)
                }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1 && receipts[0].status == .failedResponse)
    }

    @Test(arguments: ["automatic", "physical", "simulator"])
    func legacyStyleOptionsRemainAvailable(style: String) throws {
        let command = try Tap.parse(["--udid", udid, "--id", "target", "--tap-style", style,
            "--wait-timeout", "1", "--poll-interval", "0.1"])
        #expect(command.selectedInput.mode == .legacy && command.tapStyle?.rawValue == style)
        #expect(command.waitTimeout == 1 && command.pollInterval == 0.1)
    }

    @Test(arguments: ["-1", "nan", "inf", "-inf"])
    func invalidSimulatorCoordinatesCannotBuildRequest(value: String) throws {
        #expect(throws: (any Error).self) {
            _ = try parse(["-x", value, "-y", "2", "--tap-style", "simulator"]).selectedRequest()
        }
    }
}
