import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected side button")
@MainActor
struct SelectedSideButtonTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen.uuidString]
    }
    private func parse(_ extra: [String] = []) throws -> Button {
        try Button.parse(["side-button", "--udid", udid] + selection + extra)
    }
    private func options() throws -> SelectedInputOptions { try .parse(selection) }
    private func observation(boot: String = "boot-one", changedPose: Bool = false) throws -> FBSimulatorHIDSessionObservation {
        try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: boot,
            screenID: 3, screenUniqueID: screen.uuidString, axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 300, height: 600), scale: 3,
                rotation: changedPose ? .rot180 : .rot0), poseRevision: "pose-one")
    }
    private func batch(_ line: String = "button side-button") throws -> SelectedHIDRequest {
        try SelectedBatchStep.request(ShellTokenizer.tokenize(line), input: options(), simulatorUDID: udid)
    }

    @Test(arguments: [nil, 0.2, 1.0, 10.0] as [Double?])
    func standaloneAndBatchKeepExactSideButtonEvents(duration: Double?) throws {
        let extra = duration.map { ["--duration", String($0)] } ?? []
        let direct = try parse(extra + ["--expected-boot", "boot-one"]).selectedRequest()
        let batched = try batch("button side-button --expected-boot boot-one" + (duration.map { " --duration \($0)" } ?? ""))
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(direct))
        try decoded.validate()
        let payload = try #require(decoded.button)
        #expect(SelectedHIDRequest.version == 21 && decoded.version == 21)
        #expect(payload.kind == .sideButton && payload.duration == duration && payload.expectedBoot == "boot-one")
        #expect(decoded.screenID == 3 && decoded.screenUUID == screen && decoded.home == nil)
        #expect(decoded.operation == .complete && decoded.token == nil && decoded.primitives.isEmpty)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(payload) == encoder.encode(batched.button))
        #expect(direct.requestID != batched.requestID)
        let events: [FBSimulatorHIDEvent] = [.button(direction: .down, button: .sideButton)] +
            (duration.map { [.delay($0)] } ?? []) + [.button(direction: .up, button: .sideButton)]
        let actual = try decoded.completeEvent(observation: observation())
        #expect(actual == .composite(events))
        #expect(try batched.completeEvent(observation: observation()) == actual)
        let plan = try FBSimulatorHIDSession.preflight(actual, observation: observation())
        #expect(plan.primitiveCount == 2 && plan.requestedDelaySeconds == (duration ?? 0))
        #expect(throws: (any Error).self) { _ = try decoded.completeEvent(logicalSize: CGSize(width: 100, height: 200)) }
    }

    @Test(arguments: [0.0, -0.1, 10.001, Double.infinity, -Double.infinity, Double.nan])
    func invalidDurationRejectsBeforeInput(duration: Double) throws {
        let payload = SelectedButtonRequest(kind: .sideButton, duration: duration, expectedBoot: nil)
        #expect(throws: (any Error).self) { try payload.validate() }
        #expect(throws: (any Error).self) { _ = try payload.event(observation: observation()) }
        #expect(throws: (any Error).self) { _ = try parse(["--duration", String(duration)]) }
    }

    @Test func exactBootAndCompleteSelectionAreRequired() throws {
        for value in ["", " ", "\n"] {
            #expect(throws: (any Error).self) { _ = try parse(["--expected-boot", value]) }
        }
        let request = try parse(["--expected-boot", "boot-one"]).selectedRequest()
        let payload = try #require(request.button)
        try payload.validate(observation: observation())
        for boot in ["boot-two", " boot-one"] {
            #expect(throws: (any Error).self) { try payload.validate(observation: observation(boot: boot)) }
            #expect(throws: (any Error).self) { _ = try request.completeEvent(observation: observation(boot: boot)) }
        }
        for arguments in [["--input-mode", "selected"], ["--input-mode", "selected", "--screen-id", "3"],
                          ["--input-mode", "selected", "--screen-uuid", screen.uuidString],
                          ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", "invalid"],
                          ["--expected-boot", "boot-one"]] {
            #expect(throws: (any Error).self) { _ = try Button.parse(["side-button", "--udid", udid] + arguments) }
        }
    }

    @Test func oldWireMixedAndRetainedRequestsCannotEnterOwner() throws {
        let clean = try parse().selectedRequest()
        func make(version: Int = SelectedHIDRequest.version, operation: SelectedHIDRequest.Operation = .complete,
                  token: UUID? = nil, screenID: UInt32? = 3,
                  primitives: [SelectedHIDPrimitive] = []) -> SelectedHIDRequest {
            SelectedHIDRequest(version: version, requestID: UUID(), screenID: screenID,
                screenUUID: screen, operation: operation, token: token,
                primitives: primitives, button: clean.button)
        }
        var invalid = [make(version: 19), make(token: UUID()), make(screenID: nil),
                       make(primitives: [.touch(.down, x: 1, y: 2)])]
        invalid += [SelectedHIDRequest.Operation.begin, .move, .end, .close].map { make(operation: $0) }
        invalid.append(SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: nil, operation: .complete, token: nil, primitives: [], button: clean.button))
        var mixed = clean; mixed.home = .init(duration: nil, expectedBoot: nil); invalid.append(mixed)
        mixed = clean; mixed.keyboard = .init(expectedPID: 123, focusID: "field", events: [.down(4), .up(4)]); invalid.append(mixed)
        mixed = clean; mixed.ax = .init(kind: .describe, expectedPID: 123, preparation: .existingBridge,
            endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0); invalid.append(mixed)
        mixed = clean; mixed.hinge = .init(kind: .read, expectedBootIdentity: nil, degrees: nil,
            toleranceDegrees: nil, timeoutSeconds: nil); invalid.append(mixed)
        mixed = clean; mixed.path = .init(kind: .preset, preset: .scrollUp, duration: 0.5, delta: 25); invalid.append(mixed)
        mixed = clean; mixed.pinch = .init(centerX: 50, centerY: 100, scale: 2, radius: 10); invalid.append(mixed)
        mixed = clean; mixed.gesture = .doubleTap(.init(point: .init(x: 50, y: 100))); invalid.append(mixed)
        for request in invalid {
            var owner = SelectedHIDAdmission()
            #expect(throws: (any Error).self) { try owner.enter(request) }
            #expect(!owner.inFlight && owner.token == nil)
        }
        var owner = SelectedHIDAdmission()
        try owner.enter(clean)
        #expect(throws: (any Error).self) { try owner.enter(clean) }
        owner.finish()
        let contact = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: screen, operation: .begin, token: nil, primitives: [.touch(.down, x: 1, y: 2)])
        let token = UUID()
        try owner.enter(contact); owner.retain(contact, token: token); owner.finish()
        #expect(throws: (any Error).self) { try owner.enter(clean) }
        #expect(!owner.inFlight && owner.token == token)
    }

    @Test func publicPreflightRejectsIncompleteSideButtonLifetime() throws {
        for event in [FBSimulatorHIDEvent.button(direction: .down, button: .sideButton),
                      .button(direction: .up, button: .sideButton),
                      .composite([.button(direction: .down, button: .sideButton), .delay(0.2)])] {
            #expect(throws: (any Error).self) { _ = try FBSimulatorHIDSession.preflight(event, observation: observation()) }
        }
    }

    @Test(arguments: ["home", "lock", "siri", "SIDE-BUTTON"])
    func unknownButtonKindsCannotDecode(kind: String) throws {
        let data = Data("{\"kind\":\"\(kind)\"}".utf8)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(SelectedButtonRequest.self, from: data) }
        let valid = try response(batch())
        let execution = try #require(valid.button?.execution)
        struct UnknownResult: Encodable { let kind: String; let execution: SelectedButtonExecutionEvidence }
        let resultData = try JSONEncoder().encode(UnknownResult(kind: kind, execution: execution))
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(SelectedButtonResult.self, from: resultData) }
    }

    @Test(arguments: [[], ["--duration", "0.2"]])
    func legacySideAndHomeKeepTheirExistingRoutes(extra: [String]) async throws {
        let context = BatchContext(simulatorUDID: udid, axCachePolicy: .none,
            typeSubmissionMode: .composite, typeChunkSize: 200)
        let tokens = ["button", "side-button"] + extra
        let plan = try await BatchStepParser.parseStepTokens(tokens, globalUDID: udid, context: context, logger: AxeLogger())
        guard case let .hidMergeable(event) = try #require(plan.first) else {
            Issue.record("Expected legacy side-button event"); return
        }
        let selectedEvent = try parse(extra).selectedRequest().completeEvent(observation: observation())
        #expect(plan.count == 1 && event == selectedEvent)
        do {
            _ = try await BatchStepParser.parseStepTokens(tokens + selection, globalUDID: udid, context: context, logger: AxeLogger())
            Issue.record("Selected side button reached legacy conversion")
        } catch let error as ValidationError {
            #expect(error.description == "Selected input is not supported in batch steps. Run the selected command separately.")
        }
        let home = try Button.parse(["home", "--udid", udid] + selection + extra).selectedRequest()
        #expect(home.home != nil && home.button == nil)
        #expect(try home.completeEvent(observation: observation()) != event)
        for name in ["lock", "siri", "apple-pay"] {
            #expect(throws: (any Error).self) { _ = try Button.parse([name, "--udid", udid] + selection + extra) }
            #expect(try Button.parse([name, "--udid", udid] + extra).selectedInput.mode == .legacy)
        }
    }

    // Synthetic wire data exercises receipt admission, not real button execution.
    private struct ExecutionWire: Encodable {
        var schemaVersion = 1
        let operationID = UUID()
        var simulatorUDID: String
        var axDisplayID: UInt32 = 3
        var boundContext: SelectedHIDContext
        var phase = "completed"
        var plannedPrimitiveCount = 2
        var sentPrimitiveCount = 2
        var allInputsReleasedBeforeCleanup = true
        var drainCompleted = true
        var interruption: SelectedButtonExecutionEvidence.Interruption?
        var executionCleanup = "notNeeded"
        var startedUptime = 1.0
        var finishedUptime = 2.0
        var cleanupEvidence: FBSimulatorHIDCleanupEvidence?
    }
    private enum Fault: CaseIterable {
        case missingButton, wrongRequest, wrongVersion, wrongDevice, wrongAXDisplay, wrongPose, wrongBoot
        case partial, wrongPlan, undrained, unreleased, interrupted, cleanup, missingCleanup, count
        case mixedHome, mixedAX, failed, executionCleanup, reversedTime, wrongSchema
    }
    private func response(_ request: SelectedHIDRequest, fault: Fault? = nil) throws -> SelectedHIDResponse {
        let cleanupJSON = """
        {"boundSimulatorUDID":"\(udid)","boundBootIdentity":"boot-one","boundScreenID":3,
         "boundScreenUUID":"\(screen.uuidString)","boundNativeWidth":300,"boundNativeHeight":600,
         "boundScale":3,"boundRotation":0,"boundPoseRevision":"pose-one","startedUptime":2,
         "trigger":"close","contextValidation":"noOwnedInput","releases":[],"timedOut":false,"outcome":"notNeeded"}
        """
        var cleanup = try JSONDecoder().decode(FBSimulatorHIDCleanupEvidence.self, from: Data(cleanupJSON.utf8))
        if fault == .cleanup { cleanup.timedOut = true }
        var wire = ExecutionWire(simulatorUDID: fault == .wrongDevice ? "other" : udid,
            boundContext: SelectedHIDContext(try observation(changedPose: fault == .wrongPose)),
            cleanupEvidence: fault == .missingCleanup ? nil : cleanup)
        if fault == .wrongSchema { wire.schemaVersion = 2 }
        if fault == .wrongAXDisplay { wire.axDisplayID = 1 }
        if fault == .partial { wire.sentPrimitiveCount = 1 }
        if fault == .wrongPlan { wire.plannedPrimitiveCount = 3 }
        if fault == .undrained { wire.drainCompleted = false }
        if fault == .unreleased { wire.allInputsReleasedBeforeCleanup = false }
        if fault == .interrupted { wire.interruption = .init(.cancelled) }
        if fault == .executionCleanup { wire.executionCleanup = "uncertain" }
        if fault == .reversedTime { wire.finishedUptime = 0 }
        let execution = try JSONDecoder().decode(SelectedButtonExecutionEvidence.self, from: JSONEncoder().encode(wire))
        var result = SelectedHIDResponse(version: fault == .wrongVersion ? 19 : SelectedHIDRequest.version,
            requestID: fault == .wrongRequest ? UUID() : request.requestID, brokerID: UUID(),
            outcome: fault == .failed ? "failedNoReplay" : "enqueuedAndDrained", token: nil,
            enqueuedEventCount: fault == .count ? 1 : 2, cleanup: "notNeeded", error: nil,
            context: SelectedHIDContext(try observation()))
        if request.home != nil { result.home = execution }
        else if fault != .missingButton { result.button = .init(kind: .sideButton, execution: execution) }
        if fault == .mixedHome { result.home = execution }
        if fault == .mixedAX { result.ax = .init(kind: .describe, expectedPID: 123, preparation: .existingBridge) }
        return result
    }

    @Test func cleanSideThenHomeUsesDistinctOrderedReceipts() async throws {
        var order: [String] = []; var ids: [UUID] = []
        try await SelectedBatchRunner.run(lines: ["button side-button --duration 0.2", "button home"],
            input: options(), simulatorUDID: udid, send: { request, device in
                #expect(device == udid); ids.append(request.requestID); order.append("send")
                return try response(request)
            }, emit: { receipt in
                #expect(receipt.status == .completed)
                let actual = try #require(receipt.response)
                let decoded = try JSONDecoder().decode(SelectedHIDResponse.self, from: JSONEncoder().encode(actual))
                if receipt.index == 1 {
                    #expect(decoded.button?.kind == .sideButton && decoded.home == nil)
                    #expect(decoded.button?.execution.schemaVersion == 1)
                } else {
                    #expect(decoded.home?.schemaVersion == 1 && decoded.button == nil)
                }
                order.append("receipt")
            })
        #expect(order == ["send", "receipt", "send", "receipt"] && Set(ids).count == 2)
    }

    @Test(arguments: Fault.allCases)
    private func incompleteOrMismatchedResponseStopsWithoutReplay(fault: Fault) async throws {
        var sends = 0; var receipts: [SelectedBatchStepReceipt] = []
        let first = fault == .wrongBoot ? "button side-button --expected-boot boot-two" : "button side-button"
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [first, "tap -x 1 -y 2"], input: options(), simulatorUDID: udid,
                send: { request, _ in sends += 1; return try response(request, fault: fault) }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1 && receipts[0].status == .failedResponse)
        #expect(receipts[0].response != nil && receipts[0].requestID != nil)
    }

    @Test(arguments: ["button lock", "button side-button --duration 0", "button side-button --expected-pid 123",
                      "button side-button --screen-id 1", "button side-button --input-mode legacy"])
    func invalidLaterStepStopsBeforeSend(line: String) async throws {
        var sends = 0; var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["button side-button", line, "tap -x 1 -y 2"],
                input: options(), simulatorUDID: udid,
                send: { request, _ in sends += 1; return try response(request) }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.map(\.status) == [.completed, .rejectedBeforeSend])
        #expect(receipts[1].requestID == nil && receipts[1].response == nil)
    }

    @Test(arguments: ["wrongSchema", "mixedButton", "sideOnly"])
    func homeCannotAcceptSideOrNewSchemaEvidence(fault: String) throws {
        let request = try batch("button home")
        var actual = try response(request, fault: fault == "wrongSchema" ? .wrongSchema : nil)
        if fault != "wrongSchema" {
            let execution = try #require(actual.home)
            actual.button = .init(kind: .sideButton, execution: execution)
            if fault == "sideOnly" { actual.home = nil }
        }
        #expect(!SelectedBatchRunner.completed(actual, for: request, simulatorUDID: udid))
    }

    private enum ExchangeFailure: Error { case disconnected }
    @Test func unknownDeliveryStopsWithoutReplay() async throws {
        var sends = 0; var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["button side-button", "button home"],
                input: options(), simulatorUDID: udid,
                send: { _, _ in sends += 1; throw ExchangeFailure.disconnected }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1 && receipts[0].status == .outcomeUnknown)
    }
}
