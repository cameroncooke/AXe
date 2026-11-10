import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected complete batch routing")
@MainActor
struct SelectedBatchRoutingTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func options() throws -> SelectedInputOptions {
        try SelectedInputOptions.parse(selection)
    }
    private func request(_ line: String) throws -> SelectedHIDRequest {
        try SelectedBatchStep.request(ShellTokenizer.tokenize(line), input: options(), simulatorUDID: udid)
    }
    private func response(_ request: SelectedHIDRequest, error: String? = nil,
                          cleanup: String = "notNeeded", outcome: String = "enqueuedAndDrained",
                          requestID: UUID? = nil) throws -> SelectedHIDResponse {
        let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "test-boot",
            screenID: 3, screenUniqueID: screen, axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 900, height: 1800), scale: 3, rotation: .rot0),
            poseRevision: "test-pose")
        return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: requestID ?? request.requestID,
            brokerID: UUID(), outcome: outcome, token: nil, enqueuedEventCount: 3,
            cleanup: cleanup, error: error, context: SelectedHIDContext(observation))
    }

    @Test(arguments: [["--continue-on-error"], ["--ax-cache", "none"],
        ["--type-submission", "composite"], ["--type-chunk-size", "2"],
        ["--tap-style", "physical"], ["--wait-timeout", "1"], ["--poll-interval", "0.1"],
        // An explicit default is still a legacy setting.
        ["--type-chunk-size", "200"], ["--poll-interval", "0.25"]])
    func selectedBatchRejectsLegacyTuning(extra: [String]) throws {
        #expect(throws: (any Error).self) {
            _ = try Batch.parse(["--udid", udid, "--step", "tap -x 10 -y 20"] + selection + extra)
        }
    }

    @Test func legacyBatchDefaultsAndContinueOptionRemain() throws {
        let command = try Batch.parse(["--udid", udid, "--step", "gesture scroll-up", "--continue-on-error"])
        #expect(command.selectedInput.mode == .legacy && command.continueOnError)
        #expect(command.axCachePolicy == .perBatch && command.typeSubmissionMode == .chunked)
        // Omitted chunk size and poll interval take their defaults (200 and 0.25) when the batch runs.
        #expect(command.typeChunkSize == nil && command.waitTimeout == 0 && command.pollInterval == nil)
    }

    @Test(arguments: ["tap -x 10 -y 20", "tap --id feature.tap --expected-pid 123",
        "tap --label Tap --expected-pid 123", "swipe --start-x 10 --start-y 20 --end-x 40 --end-y 20",
        "gesture scroll-up", "gesture pinch -x 100 -y 200 --radius 20 --scale 2",
        "gesture double-tap -x 100 -y 200", "gesture rotate -x 100 -y 200 --radius 20 --degrees=-90",
        "gesture two-finger-tap -x 100 -y 200 --x2 140 --y2 200",
        "gesture two-finger-hold -x 100 -y 200 --x2 140 --y2 200 --hold 0.5",
        "touch -x 10 -y 20 --down --up --delay 0.2", "type Ab --expected-pid 123 --focus-id field",
        "key 4 --expected-pid 123 --focus-id field",
        "key-sequence --keycodes 4,5 --expected-pid 123 --focus-id field",
        "key-combo --modifiers 225 --key 4 --expected-pid 123 --focus-id field"])
    func completeStepsProduceSelectedRequests(line: String) throws {
        let original = try request(line)
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(original))
        try decoded.validate()
        #expect(decoded.version == SelectedHIDRequest.version)
        #expect(decoded.operation == .complete && decoded.token == nil && decoded.hinge == nil)
        #expect(decoded.screenID == 3 && decoded.screenUUID == UUID(uuidString: screen))
    }

    @Test func selectorsStayUnresolvedAndEachStepGetsNewRequestIdentity() throws {
        let first = try request("tap --id dynamic.target --expected-pid 123")
        let next = try request("tap --id dynamic.target --expected-pid 123")
        #expect(first.requestID != next.requestID)
        #expect(first.primitives.isEmpty && next.primitives.isEmpty)
        #expect(first.ax?.selectorValue == "dynamic.target" && next.ax?.selectorValue == "dynamic.target")
        #expect(first.ax?.expectedPID == 123 && first.ax?.kind == .tap)
    }

    @Test(arguments: ["button HOME", "sleep inf", "touch -x 10 -y 20 --down",
        "touch -x 10 -y 20 --up --contact-token 00000000-0000-0000-0000-000000000004",
        "tap --semantic-press --id switch --expected-pid 123",
        "type --stdin --expected-pid 123", "key 4 --expected-pid 123",
        "tap -x 10 -y 20 --wait-timeout 1", "gesture pinch -x 10 -y 20 --radius 5 --scale 1"])
    func unsupportedOrIncompleteStepsDoNotSend(line: String) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [line, "tap -x 10 -y 20"], input: options(), simulatorUDID: udid,
                send: { request, _ in sends += 1; return try response(request) }, emit: { receipts.append($0) })
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts.first?.status == .rejectedBeforeSend && receipts.first?.response == nil)
    }

    @Test(arguments: ["--input-mode legacy", "--input-mode=selected", "--screen-id=1",
                      "--screen-uuid 00000000-0000-0000-0000-000000000004", "--udid other"])
    func stepCannotOverrideBatchIdentity(extra: String) throws {
        #expect(throws: (any Error).self) { _ = try request("tap -x 10 -y 20 " + extra) }
    }

    @Test func literalOptionTextIsNotAnOverrideAfterSeparator() throws {
        let actual = try request("type --expected-pid 123 --focus-id field -- --screen-id")
        let expected = try KeyboardPrimitives.from(SelectedKeyboardRequest.textEvent("--screen-id"))
        #expect(actual.keyboard?.events.map(\.event) == expected.map(\.event))
    }

    @Test func fileTextKeepsBytesAndUsesCurrentFocusRequest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("A\nb\n".utf8).write(to: file)
        let actual = try request("type --file '\(file.path)' --expected-pid 123 --focus-id field")
        let expected = try KeyboardPrimitives.from(SelectedKeyboardRequest.textEvent("A\nb\n"))
        #expect(actual.keyboard?.events.map(\.event) == expected.map(\.event))
        #expect(actual.keyboard?.focusID == "field" && actual.keyboard?.expectedPID == 123)
    }

    @Test func nextStepStartsOnlyAfterReceiptAndUsesNewRequest() async throws {
        var events: [String] = []
        var identities: [UUID] = []
        try await SelectedBatchRunner.run(lines: ["tap -x 10 -y 20", "tap --id next --expected-pid 123"],
            input: options(), simulatorUDID: udid, send: { request, actualUDID in
                #expect(actualUDID == udid)
                identities.append(request.requestID); events.append("send")
                return try response(request)
            }, emit: { receipt in
                #expect(receipt.status == .completed && receipt.totalSteps == 2)
                #expect(receipt.requestID == receipt.response?.requestID)
                events.append("receipt")
            })
        #expect(events == ["send", "receipt", "send", "receipt"])
        #expect(Set(identities).count == 2)
    }

    @Test func returnedFailureKeepsReceiptAndStopsWithoutReplay() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["tap -x 10 -y 20", "tap -x 20 -y 30"],
                input: options(), simulatorUDID: udid, send: { request, _ in
                    sends += 1
                    return try response(request, error: "stale context", cleanup: "uncertain", outcome: "failedNoReplay")
                }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1)
        #expect(receipts[0].status == .failedResponse && receipts[0].response?.cleanup == "uncertain")
    }

    private enum Fault: Error { case exchange, output }
    @Test func exchangeFailureRemainsUnknownAndStops() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["tap -x 10 -y 20", "tap -x 20 -y 30"],
                input: options(), simulatorUDID: udid,
                send: { _, _ in sends += 1; throw Fault.exchange }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1)
        #expect(receipts[0].status == .outcomeUnknown && receipts[0].response == nil)
    }

    @Test func outputFailureCannotRepeatInputOrStartNextStep() async throws {
        var sends = 0
        var outputs = 0
        await #expect(throws: Fault.self) {
            try await SelectedBatchRunner.run(lines: ["tap -x 10 -y 20", "tap -x 20 -y 30"],
                input: options(), simulatorUDID: udid,
                send: { request, _ in sends += 1; return try response(request) },
                emit: { _ in outputs += 1; throw Fault.output })
        }
        #expect(sends == 1 && outputs == 1)
    }

    @Test func laterParseFailureDoesNotEraseEarlierReceipt() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["tap -x 10 -y 20", "button HOME", "tap -x 20 -y 30"],
                input: options(), simulatorUDID: udid,
                send: { request, _ in sends += 1; return try response(request) }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.map(\.index) == [1, 2])
        #expect(receipts.map(\.status) == [.completed, .rejectedBeforeSend])
    }

    @Test func completionRejectsUncertainOrUnrelatedResponse() throws {
        let item = try request("tap -x 10 -y 20")
        #expect(try SelectedBatchRunner.completed(response(item), for: item))
        #expect(try !SelectedBatchRunner.completed(response(item, cleanup: "uncertain"), for: item))
        #expect(try !SelectedBatchRunner.completed(response(item, outcome: "retained"), for: item))
        #expect(try !SelectedBatchRunner.completed(response(item, requestID: UUID()), for: item))
        var quarantined = try response(item)
        quarantined.quarantine = .init(recordPath: nil, persisted: false, error: "failed storage")
        #expect(!SelectedBatchRunner.completed(quarantined, for: item))
    }

    @Test func extractedBuildersPreserveStandaloneRetainedAndSemanticRoutes() throws {
        let global = ["--udid", udid] + selection
        let touch = try Touch.parse(["-x", "10", "-y", "20", "--down"] + global)
        #expect(try touch.selectedRequest().operation == .begin)
        let press = try Tap.parse(["--semantic-press", "--id", "switch", "--expected-pid", "123"] + global)
        #expect(try press.selectedRequest().ax?.kind == .semanticPress)
    }

    @Test(arguments: ["", " --duration 1.2 --steps 3 --pre-delay 0.2 --post-delay 0.4"])
    func dragBatchMatchesStandaloneRequest(extra: String) throws {
        let line = "drag --start-x 10 --start-y 20 --end-x 40 --end-y 50" + extra
        let batch = try request(line)
        let standalone = try Drag.parse(Array(ShellTokenizer.tokenize(line).dropFirst()) + ["--udid", udid] + selection)
        let direct = try standalone.selectedRequest()
        let batchPath = try #require(batch.path)
        let directPath = try #require(direct.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(batchPath) == encoder.encode(directPath))
        #expect(batchPath.kind == .drag)
        #expect(batchPath.startX == 10 && batchPath.startY == 20)
        #expect(batchPath.endX == 40 && batchPath.endY == 50)
        #expect(batchPath.duration == (extra.isEmpty ? 0.6 : 1.2))
        #expect(batchPath.steps == (extra.isEmpty ? 60 : 3))
        #expect(batchPath.preDelay == (extra.isEmpty ? 0 : 0.2))
        #expect(batchPath.postDelay == (extra.isEmpty ? 0 : 0.4))
        #expect(batch.version == direct.version && batch.operation == .complete)
        #expect(batch.screenID == direct.screenID && batch.screenUUID == direct.screenUUID)
        #expect(batch.requestID != direct.requestID)
        #expect(batch.primitives.isEmpty && batch.token == nil && batch.ax == nil && batch.keyboard == nil)
        try JSONDecoder().decode(SelectedHIDRequest.self, from: encoder.encode(batch)).validate()
    }

    @Test(arguments: [
        "--start-x 10 --start-y 20 --end-x 10 --end-y 20",
        "--start-x=-1 --start-y 20 --end-x 40 --end-y 50",
        "--start-x nan --start-y 20 --end-x 40 --end-y 50",
        "--start-x 10 --start-y 20 --end-x 40 --end-y 50 --duration 0",
        "--start-x 10 --start-y 20 --end-x 40 --end-y 50 --steps 0",
        "--start-x 10 --start-y 20 --end-x 40 --end-y 50 --steps 1001",
        "--start-x 10 --start-y 20 --end-x 40 --end-y 50 --pre-delay 11",
        "--start-x 10 --start-y 20 --end-x 40 --end-y 50 --duration 10 --post-delay 10"
    ])
    func invalidDragStopsBeforeSend(arguments: String) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["drag " + arguments, "tap -x 10 -y 20"],
                input: options(), simulatorUDID: udid,
                send: { request, _ in sends += 1; return try response(request) }, emit: { receipts.append($0) })
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts.first?.command == "drag" && receipts.first?.status == .rejectedBeforeSend)
        #expect(receipts.first?.requestID == nil && receipts.first?.response == nil)
    }

    @Test(arguments: ["--screen-id=1", "--screen-uuid 00000000-0000-0000-0000-000000000004", "--input-mode legacy"])
    func dragCannotOverrideBatchSelection(extra: String) throws {
        #expect(throws: ValidationError.self) {
            _ = try request("drag --start-x 10 --start-y 20 --end-x 40 --end-y 50 " + extra)
        }
    }

    @Test func invalidLaterDragPreservesEarlierReceiptAndStops() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["drag --start-x 10 --start-y 20 --end-x 40 --end-y 50",
                "drag --start-x 10 --start-y 20 --end-x 40 --end-y 50 --steps 0", "tap -x 10 -y 20"],
                input: options(), simulatorUDID: udid,
                send: { request, _ in
                    #expect(request.path?.kind == .drag)
                    sends += 1
                    return try response(request)
                }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.map(\.index) == [1, 2])
        #expect(receipts.map(\.status) == [.completed, .rejectedBeforeSend])
        #expect(receipts[0].requestID == receipts[0].response?.requestID)
        #expect(receipts[1].requestID == nil && receipts[1].response == nil)
    }

    @Test func failedDragResponseStopsWithoutReplay() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["drag --start-x 10 --start-y 20 --end-x 40 --end-y 50",
                "tap -x 10 -y 20"], input: options(), simulatorUDID: udid,
                send: { request, _ in
                    #expect(request.path?.kind == .drag)
                    sends += 1
                    return try response(request, error: "changed context", cleanup: "releaseEnqueuedAndDrained", outcome: "failedNoReplay")
                }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1)
        #expect(receipts.first?.status == .failedResponse)
        #expect(receipts.first?.response?.cleanup == "releaseEnqueuedAndDrained")
    }
    @Test(arguments: [0.0, -0.0, 0.125, 21.0, Double.greatestFiniteMagnitude])
    func sleepAcceptsEveryFiniteNonnegativeDuration(seconds: Double) throws {
        let step = try SelectedBatchStep.parseStep(["sleep", String(seconds)], input: options(), simulatorUDID: udid)
        guard case .hostWait(let actual) = step else { Issue.record("Expected host wait"); return }
        #expect(actual == seconds)
    }

    @Test(arguments: ["sleep", "sleep -1", "sleep nan", "sleep inf", "sleep -inf",
                      "sleep 1e309", "sleep 0 extra", "sleep 0 --screen-id 1"])
    func invalidSleepStopsBeforeAnyInput(line: String) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [line, "tap -x 10 -y 20"], input: options(), simulatorUDID: udid,
                send: { request, _ in sends += 1; return try response(request) }, emit: { receipts.append($0) })
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts[0].status == .rejectedBeforeSend && receipts[0].hostWait == nil)
        #expect(receipts[0].requestID == nil && receipts[0].response == nil)
    }

    @Test(arguments: [0.0, 0.01])
    func sleepReturnsHostTimeWithoutInputIdentity(seconds: Double) async throws {
        var receipts: [SelectedBatchStepReceipt] = []
        try await SelectedBatchRunner.run(lines: ["sleep \(seconds)"], input: options(), simulatorUDID: udid,
            send: { _, _ in Issue.record("Sleep must not send input"); throw Fault.exchange },
            emit: { receipts.append($0) })
        let item = try #require(receipts.first)
        let wait = try #require(item.hostWait)
        #expect(item.status == .completed && item.command == "sleep")
        #expect(item.requestID == nil && item.response == nil)
        #expect(wait.requestedSeconds == seconds && wait.elapsedSeconds >= seconds)
        #expect(wait.elapsedSeconds.isFinite && wait.outcome == .completed && wait.error == nil)
        let encoded = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        #expect(!encoded.contains("requestID") && !encoded.contains("brokerID") && !encoded.contains("response"))
    }

    @Test func sleepPreservesReceiptOrderAndFreshInputRequests() async throws {
        var events: [String] = []
        var identities: [UUID] = []
        try await SelectedBatchRunner.run(lines: ["tap --id first --expected-pid 123", "sleep 0.001",
            "tap --id next --expected-pid 123"], input: options(), simulatorUDID: udid,
            send: { request, _ in identities.append(request.requestID); events.append("send"); return try response(request) },
            emit: { events.append($0.hostWait == nil ? "inputReceipt" : "waitReceipt") })
        #expect(events == ["send", "inputReceipt", "waitReceipt", "send", "inputReceipt"])
        #expect(identities.count == 2 && Set(identities).count == 2)
    }

    @Test func greatestFiniteWaitCanBeCancelledWithoutOverflow() async {
        let task = Task { @MainActor in await SelectedBatchHostWait.wait(seconds: .greatestFiniteMagnitude) }
        await Task.yield()
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .interrupted && result.error != nil)
        #expect(result.requestedSeconds == .greatestFiniteMagnitude && result.elapsedSeconds.isFinite)
    }

    @Test func cancelledWaitStopsLaterInput() async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["sleep 100", "tap -x 10 -y 20"], input: options(), simulatorUDID: udid,
                send: { request, _ in sends += 1; return try response(request) }, emit: { receipts.append($0) },
                wait: { seconds in
                    let task = Task { @MainActor in await SelectedBatchHostWait.wait(seconds: seconds) }
                    await Task.yield()
                    task.cancel()
                    return await task.value
                })
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts[0].status == .waitInterrupted && receipts[0].hostWait?.outcome == .interrupted)
        #expect(receipts[0].requestID == nil && receipts[0].response == nil)
    }

    @Test func waitOutputFailureStopsBeforeNextInput() async throws {
        var sends = 0
        var outputs = 0
        await #expect(throws: Fault.self) {
            try await SelectedBatchRunner.run(lines: ["sleep 0", "tap -x 10 -y 20"], input: options(), simulatorUDID: udid,
                send: { request, _ in sends += 1; return try response(request) }, emit: { item in
                    #expect(item.hostWait?.outcome == .completed)
                    outputs += 1
                    throw Fault.output
                })
        }
        #expect(sends == 0 && outputs == 1)
    }
}
