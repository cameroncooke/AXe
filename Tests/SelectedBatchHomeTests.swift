import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected batch Home")
@MainActor
struct SelectedBatchHomeTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func options() throws -> SelectedInputOptions { try .parse(selection) }
    private func request(_ line: String = "button home") throws -> SelectedHIDRequest {
        try SelectedBatchStep.request(ShellTokenizer.tokenize(line), input: options(), simulatorUDID: udid)
    }
    private func context() throws -> SelectedHIDContext {
        SelectedHIDContext(try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "boot-one",
            screenID: 3, screenUniqueID: screen, axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 300, height: 600), scale: 3, rotation: .rot0),
            poseRevision: "pose-one"))
    }

    @Test(arguments: ["", " --duration 0.2", " --duration 10 --expected-boot boot-one"])
    func matchesStandalone(extra: String) throws {
        let batch = try request("button home" + extra)
        let standalone = try Button.parse(["home", "--udid", udid] + selection + ShellTokenizer.tokenize(extra))
        let direct = try standalone.selectedRequest()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(batch.button?.kind == .home)
        #expect(try encoder.encode(batch.button) == encoder.encode(direct.button))
        #expect(batch.operation == .complete && batch.primitives.isEmpty && batch.token == nil)
        #expect(batch.screenID == direct.screenID && batch.screenUUID == direct.screenUUID)
        #expect(batch.requestID != direct.requestID)
    }

    @Test(arguments: ["button unknown",
        "button home --duration 0", "button home --duration nan", "button home --duration 10.1",
        "button home --expected-boot ''", "button home --expected-pid 123",
        "button home --screen-id 1", "button home --input-mode legacy", "button home --udid other"])
    func invalidStepStopsBeforeSend(line: String) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [line, "button home"], input: options(), simulatorUDID: udid,
                send: { item, _ in sends += 1; return try response(item) }, emit: { receipts.append($0) })
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts[0].status == .rejectedBeforeSend && receipts[0].requestID == nil)
    }

    // Typed synthetic wire data checks the owner's contract and batch acceptance, not native button
    // delivery. Each send passes the receipt through the contract as the owner does.
    private struct HomeWire: Encodable {
        let schemaVersion = 1
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
        let startedUptime = 1.0
        var finishedUptime = 2.0
        var cleanupEvidence: FBSimulatorHIDCleanupEvidence?
    }
    private enum Fault: String, CaseIterable {
        case missingHome, wrongRequest, wrongVersion
        case partial, undrained, unreleased, interrupted, cleanup, missingCleanup, count, mixed, failed
    }
    private func response(_ item: SelectedHIDRequest, fault: Fault? = nil) throws -> SelectedHIDResponse {
        let cleanupJSON = """
        {"boundSimulatorUDID":"\(udid)","boundBootIdentity":"boot-one","boundScreenID":3,
         "boundScreenUUID":"\(screen)","boundNativeWidth":300,"boundNativeHeight":600,
         "boundScale":3,"boundRotation":0,"boundPoseRevision":"pose-one","startedUptime":2,
         "trigger":"close","contextValidation":"noOwnedInput","releases":[],
         "timedOut":false,"outcome":"notNeeded"}
        """
        var cleanup = try JSONDecoder().decode(FBSimulatorHIDCleanupEvidence.self, from: Data(cleanupJSON.utf8))
        if fault == .cleanup { cleanup.timedOut = true }
        var wire = HomeWire(simulatorUDID: udid, boundContext: try context(),
            cleanupEvidence: fault == .missingCleanup ? nil : cleanup)
        if fault == .partial { wire.sentPrimitiveCount = 1 }
        if fault == .undrained { wire.drainCompleted = false }
        if fault == .unreleased { wire.allInputsReleasedBeforeCleanup = false }
        if fault == .interrupted { wire.interruption = .init(.cancelled) }
        let home = try JSONDecoder().decode(SelectedButtonExecutionEvidence.self, from: JSONEncoder().encode(wire))
        var actual = SelectedHIDResponse(version: fault == .wrongVersion ? 12 : SelectedHIDRequest.version,
            requestID: fault == .wrongRequest ? UUID() : item.requestID, brokerID: UUID(),
            outcome: fault == .failed ? "failedNoReplay" : "enqueuedAndDrained", token: nil,
            enqueuedEventCount: fault == .count ? 1 : 2, cleanup: "notNeeded", error: nil,
            context: try context(), button: fault == .missingHome ? nil : SelectedButtonResult(kind: .home, execution: home))
        if fault == .mixed { actual.ax = .init(kind: .describe, expectedPID: 123) }
        return SelectedHIDContract.checked(actual, for: item)
    }

    @Test func cleanHomeCompletesBeforeNextStep() async throws {
        var sequence: [String] = []
        var ids: [UUID] = []
        try await SelectedBatchRunner.run(lines: ["button home", "button home --duration 0.2 --expected-boot boot-one"],
            input: options(), simulatorUDID: udid, send: { item, device in
                #expect(device == udid); ids.append(item.requestID); sequence.append("send")
                return try response(item)
            }, emit: { receipt in #expect(receipt.status == .completed); sequence.append("receipt") })
        #expect(sequence == ["send", "receipt", "send", "receipt"] && Set(ids).count == 2)
    }

    @Test(arguments: Fault.allCases)
    private func failedEvidenceStopsWithoutReplay(fault: Fault) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        let first = "button home"
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [first, "button home"], input: options(), simulatorUDID: udid,
                send: { item, _ in sends += 1; return try response(item, fault: fault) }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1 && receipts[0].status == .failedResponse)
        #expect(receipts[0].response != nil)
    }

    @Test func laterInvalidButtonKeepsCompletedReceiptAndStops() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["button home", "button unknown", "button home"],
                input: options(), simulatorUDID: udid,
                send: { item, _ in sends += 1; return try response(item) }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.map(\.status) == [.completed, .rejectedBeforeSend])
        #expect(receipts[1].requestID == nil && receipts[1].response == nil)
        // The step's error is the parser's sentence, never a Swift value dump, and keeps its code.
        let failure = CLIErrorMapping.failure(for: SelectedBatchRunner.failure(receipts[1],
            stopError: CLIError(errorDescription: "stopped", code: .rejectedBeforeInput)))
        #expect(failure.code == "rejectedBeforeInput")
        #expect(failure.message.contains("'unknown'") && !failure.message.contains("CommandError")
            && !failure.message.contains("ArgumentParser."), "\(failure.message)")
    }

    private enum ExchangeFailure: Error { case disconnected }
    @Test func missingResponseIsUnknownAndNeverReplayed() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["button home", "button home"], input: options(), simulatorUDID: udid,
                send: { _, _ in sends += 1; throw ExchangeFailure.disconnected }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1 && receipts[0].status == .outcomeUnknown)
    }
}
