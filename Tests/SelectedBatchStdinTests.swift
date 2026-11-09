import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected batch stdin")
@MainActor
struct SelectedBatchStdinTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private let stdinStep = "type --stdin --expected-pid 123 --focus-id field"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func options() throws -> SelectedInputOptions { try SelectedInputOptions.parse(selection) }

    // Each test owns a finite pipe. No test replaces process stdin or starts a producer task.
    private func closedPipe(_ data: Data) throws -> Pipe {
        let pipe = Pipe()
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
            try pipe.fileHandleForWriting.close()
            return pipe
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
            throw error
        }
    }
    private func request(_ tokens: [String], stdin: FileHandle) throws -> SelectedHIDRequest {
        try SelectedBatchStep.request(tokens, input: options(), simulatorUDID: udid, standardInput: stdin)
    }
    private func response(_ request: SelectedHIDRequest, failed: Bool = false) throws -> SelectedHIDResponse {
        let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "test-boot",
            screenID: 3, screenUniqueID: screen, axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 900, height: 1800), scale: 3, rotation: .rot0),
            poseRevision: "test-pose")
        return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: UUID(), outcome: failed ? "failedNoReplay" : "enqueuedAndDrained", token: nil,
            enqueuedEventCount: failed ? 0 : 2, cleanup: "notNeeded", error: failed ? "stale focus" : nil,
            context: SelectedHIDContext(observation))
    }
    private var dEvents: [FBSimulatorHIDEvent] {
        [.keyboard(direction: .down, keyCode: 7), .keyboard(direction: .up, keyCode: 7)]
    }

    @Test(arguments: ["d", "A\nb\n", " ab ", String(repeating: "a", count: 256)])
    func stdinMatchesStandaloneWithoutTrimming(text: String) throws {
        let batchPipe = try closedPipe(Data(text.utf8))
        let directPipe = try closedPipe(Data(text.utf8))
        defer { try? batchPipe.fileHandleForReading.close(); try? directPipe.fileHandleForReading.close() }
        let batch = try request(ShellTokenizer.tokenize(stdinStep), stdin: batchPipe.fileHandleForReading)
        let command = try Type.parse(["--stdin", "--expected-pid", "123", "--focus-id", "field",
            "--udid", udid] + selection)
        let direct = try command.selectedRequest(standardInput: directPipe.fileHandleForReading)
        let keyboard = try #require(batch.keyboard)
        #expect(keyboard.events.map(\.event) == direct.keyboard?.events.map(\.event))
        let expected = try SelectedKeyboardRequest.primitives(from: SelectedKeyboardRequest.textEvent(text))
        #expect(keyboard.events.map(\.event) == expected.map(\.event))
        #expect(keyboard.expectedPID == 123 && keyboard.focusID == "field")
        #expect(batch.screenID == direct.screenID && batch.screenUUID == direct.screenUUID)
        #expect(batch.requestID != direct.requestID && batch.operation == .complete)
        #expect(batch.primitives.isEmpty && batch.ax == nil && batch.path == nil && batch.token == nil)
        try batch.validate()
        if text == "d" { #expect(keyboard.events.map(\.event) == dEvents) }
    }

    @Test(arguments: [Data(), Data([0xff]), Data("é".utf8), Data(repeating: 97, count: 257)])
    func invalidStdinStopsBeforeSend(bytes: Data) async throws {
        let pipe = try closedPipe(bytes)
        defer { try? pipe.fileHandleForReading.close() }
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [stdinStep, "sleep 0"], input: options(), simulatorUDID: udid,
                send: { item, _ in sends += 1; return try response(item) },
                emit: { receipts.append($0) }, standardInput: pipe.fileHandleForReading)
        }
        #expect(sends == 0 && receipts.count == 1)
        #expect(receipts.first?.status == .rejectedBeforeSend && receipts.first?.index == 1)
        #expect(receipts.first?.requestID == nil && receipts.first?.response == nil)
    }

    @Test(arguments: [
        "type --stdin --expected-pid 123",
        "type --stdin --expected-pid 0 --focus-id field",
        "type literal --stdin --expected-pid 123 --focus-id field",
        "type --file /unused --stdin --expected-pid 123 --focus-id field",
        "type --stdin --expected-pid 123 --focus-id field --screen-id 1",
        "type --stdin --expected-pid 123 --focus-id field --unknown-option"
    ])
    func invalidOptionsLeaveStdinUnread(line: String) async throws {
        let pipe = try closedPipe(Data("d".utf8))
        defer { try? pipe.fileHandleForReading.close() }
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [line, stdinStep], input: options(), simulatorUDID: udid,
                send: { item, _ in sends += 1; return try response(item) },
                emit: { receipts.append($0) }, standardInput: pipe.fileHandleForReading)
        }
        #expect(sends == 0 && receipts.count == 1 && receipts[0].status == .rejectedBeforeSend)
        #expect(try pipe.fileHandleForReading.readToEnd() == Data("d".utf8))
    }

    @Test func laterStdinIsReadOnlyAfterEarlierReceipt() async throws {
        let pipe = try closedPipe(Data("Xd".utf8))
        defer { try? pipe.fileHandleForReading.close() }
        var order: [String] = []
        try await SelectedBatchRunner.run(lines: ["sleep 0", stdinStep], input: options(), simulatorUDID: udid,
            send: { item, actualUDID in
                #expect(actualUDID == udid && item.keyboard?.events.map(\.event) == dEvents)
                order.append("send")
                return try response(item)
            }, emit: { receipt in
                #expect(receipt.status == .completed)
                if receipt.index == 1 {
                    // A preread would consume X before this receipt and make both assertions fail.
                    let marker = try pipe.fileHandleForReading.read(upToCount: 1)
                    #expect(marker == Data("X".utf8))
                    order.append("waitReceipt")
                } else {
                    #expect(receipt.requestID == receipt.response?.requestID)
                    order.append("inputReceipt")
                }
            }, standardInput: pipe.fileHandleForReading)
        #expect(order == ["waitReceipt", "send", "inputReceipt"])
    }

    enum Fault: String, CaseIterable, Error { case parse, response, exchange, output }
    @Test(arguments: Fault.allCases)
    func earlierFailureDoesNotReadLaterStdin(fault: Fault) async throws {
        let pipe = try closedPipe(Data("d".utf8))
        defer { try? pipe.fileHandleForReading.close() }
        var sends = 0
        var outputs = 0
        let first = fault == .parse ? "button HOME" : "tap -x 10 -y 20"
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [first, stdinStep], input: options(), simulatorUDID: udid,
                send: { item, _ in
                    sends += 1
                    if fault == .exchange { throw Fault.exchange }
                    return try response(item, failed: fault == .response)
                }, emit: { _ in
                    outputs += 1
                    if fault == .output { throw Fault.output }
                }, standardInput: pipe.fileHandleForReading)
        }
        #expect(sends == (fault == .parse ? 0 : 1) && outputs == 1)
        #expect(try pipe.fileHandleForReading.readToEnd() == Data("d".utf8))
    }

    @Test func secondStdinSeesEOFAndCannotReplayFirstRequest() async throws {
        let pipe = try closedPipe(Data("d".utf8))
        defer { try? pipe.fileHandleForReading.close() }
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: [stdinStep, stdinStep, "sleep 0"],
                input: options(), simulatorUDID: udid, send: { item, _ in
                    sends += 1
                    #expect(item.keyboard?.events.map(\.event) == dEvents)
                    return try response(item)
                }, emit: { receipts.append($0) }, standardInput: pipe.fileHandleForReading)
        }
        #expect(sends == 1 && receipts.map(\.index) == [1, 2])
        #expect(receipts.map(\.status) == [.completed, .rejectedBeforeSend])
        #expect(receipts[0].requestID == receipts[0].response?.requestID)
        #expect(receipts[1].requestID == nil && receipts[1].response == nil)
    }

    @Test(arguments: [false, true])
    func literalAndFileSourcesDoNotConsumeStdin(useFile: Bool) throws {
        let pipe = try closedPipe(Data("d".utf8))
        defer { try? pipe.fileHandleForReading.close() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = " A\nb\n"
        try Data(text.utf8).write(to: file)
        let source = useFile ? ["--file", file.path] : ["--", text]
        let item = try request(["type", "--expected-pid", "123", "--focus-id", "field"] + source,
            stdin: pipe.fileHandleForReading)
        let expected = try SelectedKeyboardRequest.primitives(from: SelectedKeyboardRequest.textEvent(text))
        #expect(item.keyboard?.events.map(\.event) == expected.map(\.event))
        #expect(try pipe.fileHandleForReading.readToEnd() == Data("d".utf8))
        let legacy = try Type.parse(["--udid", udid] + source)
        #expect(legacy.selectedInput.mode == .legacy)
        if useFile { #expect(try legacy.readFromFile(file.path) == text) }
        else { #expect(legacy.text == text) }
    }

    @Test func cancelledRunnerDoesNotReadOrSend() async throws {
        let pipe = try closedPipe(Data("d".utf8))
        defer { try? pipe.fileHandleForReading.close() }
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        let task = Task { @MainActor in
            do {
                try await SelectedBatchRunner.run(lines: [stdinStep, "sleep 0"], input: options(), simulatorUDID: udid,
                    send: { item, _ in sends += 1; return try response(item) },
                    emit: { receipts.append($0) }, standardInput: pipe.fileHandleForReading)
                return false
            } catch { return true }
        }
        // This actor has not yielded; the task is cancelled before it can enter the runner.
        task.cancel()
        #expect(await task.value)
        #expect(sends == 0 && receipts.count == 1 && receipts[0].status == .rejectedBeforeSend)
        #expect(try pipe.fileHandleForReading.readToEnd() == Data("d".utf8))
    }
}
