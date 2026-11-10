import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected keyboard")
struct SelectedKeyboardTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private var options: [String] {
        ["--udid", udid, "--input-mode", "selected", "--screen-id", "3",
         "--screen-uuid", screen.uuidString, "--expected-pid", "123", "--focus-id", "field"]
    }
    private func observation() throws -> FBSimulatorHIDSessionObservation {
        try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "test-boot",
            screenID: 3, screenUniqueID: screen.uuidString, axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 300, height: 600), scale: 3, rotation: .rot0),
            poseRevision: "test-pose")
    }
    private func request(_ events: [SelectedKeyboardPrimitive]) -> SelectedHIDRequest {
        SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: screen, operation: .complete, token: nil, primitives: [],
            keyboard: SelectedKeyboardRequest(expectedPID: 123, focusID: "field", events: events))
    }

    @Test(arguments: ["type", "key", "key-sequence", "key-combo"])
    func selectedCommandsBuildBalancedKeyboardOnlyRequests(name: String) throws {
        let original: SelectedHIDRequest
        switch name {
        case "type":
            let command = try Type.parse(["Ab"] + options)
            original = try command.selectedKeyboard.request(input: command.selectedInput,
                event: SelectedKeyboardRequest.textEvent(try #require(command.text)))
        case "key":
            let command = try Key.parse(["42", "--duration", "0.2"] + options)
            original = try command.selectedKeyboard.request(input: command.selectedInput, event: command.selectedKeyboardEvent())
        case "key-sequence":
            let command = try KeySequence.parse(["--keycodes", "4,40,5", "--delay", "0.1"] + options)
            original = try command.selectedKeyboard.request(input: command.selectedInput, event: command.selectedKeyboardEvent())
        default:
            let command = try KeyCombo.parse(["--modifiers", "227,225", "--key", "4"] + options)
            original = try command.selectedKeyboard.request(input: command.selectedInput, event: command.selectedKeyboardEvent())
        }
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(original))
        try decoded.validate()
        let keyboard = try #require(decoded.keyboard)
        #expect(decoded.operation == .complete && decoded.token == nil && decoded.primitives.isEmpty)
        #expect(keyboard.expectedPID == 123 && keyboard.focusID == "field")
        #expect(try FBSimulatorHIDSession.preflight(keyboard.event, observation: observation()).primitiveCount > 0)
        #expect(throws: (any Error).self) { _ = try decoded.completeEvent(observation: observation()) }
    }

    @Test func textAndChordUseExactExistingKeyOrder() throws {
        let text = try KeyboardPrimitives.from(SelectedKeyboardRequest.textEvent("A"))
        #expect(text.map(\.event) == [.keyboard(direction: .down, keyCode: 225),
            .keyboard(direction: .down, keyCode: 4), .keyboard(direction: .up, keyCode: 4),
            .keyboard(direction: .up, keyCode: 225)])
        let command = try KeyCombo.parse(["--modifiers", "227,225", "--key", "4"] + options)
        let events = try KeyboardPrimitives.from(command.selectedKeyboardEvent()).map(\.event)
        #expect(events == [.keyboard(direction: .down, keyCode: 227), .keyboard(direction: .down, keyCode: 225),
            .keyboard(direction: .down, keyCode: 4), .keyboard(direction: .up, keyCode: 4),
            .keyboard(direction: .up, keyCode: 225), .keyboard(direction: .up, keyCode: 227)])
    }

    @Test func unbalancedOrInvalidKeysFailBeforeOwnerAdmission() throws {
        let invalidEvents: [[SelectedKeyboardPrimitive]] = [[.down(4)], [.up(4)], [.down(4), .down(4), .up(4)],
            [.down(256), .up(256)], [.delay(.nan)], [.delay(10), .delay(10), .delay(1), .down(4), .up(4)]]
        for events in invalidEvents {
            var owner = SelectedHIDAdmission()
            #expect(throws: (any Error).self) { try owner.enter(request(events)) }
            #expect(!owner.inFlight && owner.token == nil)
        }
        #expect(throws: (any Error).self) {
            _ = try KeyboardPrimitives.from(.touch(direction: .down, x: 1, y: 1))
        }
        #expect(throws: (any Error).self) {
            _ = try FBSimulatorHIDSession.preflight(.keyboard(direction: .down, keyCode: 4), observation: observation())
        }
    }

    @Test func mixedInputPayloadsCannotReachKeyboardOwner() throws {
        let clean = request([.down(4), .up(4)])
        var ax = clean
        ax.ax = .init(kind: .describe, expectedPID: 123,
            endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0)
        var pinch = clean
        pinch.pinch = .init(centerX: 50, centerY: 100, scale: 2, radius: 10)
        var path = clean
        path.path = .init(kind: .preset, preset: .scrollUp, duration: 0.5, delta: 25)
        var gesture = clean
        gesture.gesture = .doubleTap(.init(point: .init(x: 50, y: 100)))
        var hinge = try SelectedHingeRequest(kind: .read, expectedBootIdentity: nil,
            degrees: nil, toleranceDegrees: nil, timeoutSeconds: nil).brokerRequest()
        hinge.keyboard = clean.keyboard
        let touch = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: screen, operation: .complete, token: nil, primitives: [.touch(.down, x: 1, y: 2)], keyboard: clean.keyboard)
        for item in [ax, pinch, path, gesture, hinge, touch] {
            var owner = SelectedHIDAdmission()
            #expect(throws: (any Error).self) { try owner.enter(item) }
            #expect(!owner.inFlight)
        }
    }

    private struct Field: Encodable {
        var type = "TextField"
        var AXUniqueId = "field"
        var pid: Int32 = 123
        var focused: Bool? = true
        var enabled: Bool? = true
        var hidden: Bool? = false
        func node() throws -> FBSimulatorAXNode {
            try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(self))
        }
    }

    @Test func focusPolicyRequiresEveryTypedFieldAndExactIdentity() throws {
        try SelectedKeyboardFocusPolicy.validate(Field().node(), expectedPID: 123, fieldTarget: .semantic(kind: .id, value: "field", elementType: "TextField"))
        var variants: [Field] = []
        var field = Field(); field.focused = false; variants.append(field)
        field = Field(); field.focused = nil; variants.append(field)
        field = Field(); field.enabled = false; variants.append(field)
        field = Field(); field.enabled = nil; variants.append(field)
        field = Field(); field.hidden = true; variants.append(field)
        field = Field(); field.hidden = nil; variants.append(field)
        field = Field(); field.pid = 124; variants.append(field)
        field = Field(); field.AXUniqueId = "other"; variants.append(field)
        field = Field(); field.type = "Group"; variants.append(field)
        for invalid in variants {
            #expect(throws: (any Error).self) {
                try SelectedKeyboardFocusPolicy.validate(invalid.node(), expectedPID: 123,
                    fieldTarget: .semantic(kind: .id, value: "field", elementType: "TextField"))
            }
        }
    }

    @Test func textInputIsBoundedAndNeverTruncated() throws {
        #expect(throws: (any Error).self) { _ = try SelectedKeyboardRequest.textEvent("") }
        #expect(throws: (any Error).self) { _ = try SelectedKeyboardRequest.textEvent(String(repeating: "a", count: 257)) }
        #expect(throws: (any Error).self) { _ = try SelectedKeyboardRequest.textEvent("é") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let exact = "A\nb\n"
        try Data(exact.utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        #expect(try SelectedKeyboardOptions.readText(from: handle) == exact)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 97, count: 257))
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        #expect(throws: (any Error).self) { _ = try SelectedKeyboardOptions.readText(from: pipe.fileHandleForReading) }
    }

    @Test func legacyParsersStayExplicitAndSelectedRequiresFocus() throws {
        let legacy = try Key.parse(["4", "--udid", udid])
        #expect(legacy.selectedInput.mode == .legacy)
        #expect(throws: (any Error).self) { _ = try Key.parse(["4", "--udid", udid, "--focus-id", "field"]) }
        #expect(throws: (any Error).self) { _ = try Key.parse(["4"] + Array(options.dropLast(2))) }
        let command = try KeyCombo.parse(["--modifiers", "4", "--key", "5"] + options)
        #expect(throws: (any Error).self) { _ = try command.selectedKeyboardEvent() }
    }

    @Test(arguments: [["type", "a"], ["type", "--stdin"], ["type", "--file", "/unused"],
                      ["key", "4"], ["key-sequence", "--keycodes", "4,5"],
                      ["key-combo", "--modifiers", "225", "--key", "4"]])
    @MainActor func batchRejectsSelectedKeyboardBeforeReadingInput(tokens: [String]) async throws {
        let context = BatchContext(simulatorUDID: udid, axCachePolicy: .none, typeSubmissionMode: .composite, typeChunkSize: 200)
        do {
            _ = try await BatchStepParser.parseStepTokens(tokens + Array(options.dropFirst(2)), globalUDID: udid, context: context, logger: AxeLogger())
            Issue.record("Selected keyboard reached batch conversion")
        } catch let error as ValidationError {
            #expect(error.description == "Selected input is not supported in batch steps. Run the selected command separately.")
        }
    }
    private enum FocusReadFailure: Error { case deadlineExpired }

    @Test @MainActor func disconnectedFocusReadReacquiresOnceWithRemainingBudget() async throws {
        let deadline = 8.0
        var now = 0.0
        var timeouts: [Double] = []
        let expected = try Field().node()
        let field = try await SelectedKeyboardFocusRead.perform(remainingSeconds: { deadline - now }) { timeout in
            timeouts.append(timeout)
            if timeouts.count == 1 {
                now = 1.5
                throw NSError(domain: "DTXProxyChannel", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Channel disconnected"])
            }
            return expected
        }
        #expect(timeouts == [8, 6.5])
        #expect(field.pid == 123 && field.identifier == "field")
    }

    @Test @MainActor func aSecondDisconnectedFocusReadFailsWithoutAnotherAttempt() async {
        var attempts = 0
        do {
            _ = try await SelectedKeyboardFocusRead.perform(remainingSeconds: { 8 }) { _ in
                attempts += 1
                throw NSError(domain: "DTXProxyChannel", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Channel disconnected"])
            }
            Issue.record("A second disconnected read must fail")
        } catch {
            let nativeError = error as NSError
            #expect(nativeError.domain == "DTXProxyChannel" && nativeError.code == 1)
            #expect(nativeError.localizedDescription == "Channel disconnected")
        }
        #expect(attempts == 2)
    }

    @Test @MainActor func otherFocusReadErrorsDoNotReacquire() async {
        let disconnected = NSError(domain: "DTXProxyChannel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Channel disconnected"])
        let failures = [
            NSError(domain: "OtherChannel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Channel disconnected"]),
            NSError(domain: "DTXProxyChannel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Channel disconnected"]),
            NSError(domain: "DTXProxyChannel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Other failure"]),
            NSError(domain: "OuterError", code: 1, userInfo: [NSUnderlyingErrorKey: disconnected]),
        ]
        for failure in failures {
            var attempts = 0
            do {
                _ = try await SelectedKeyboardFocusRead.perform(remainingSeconds: { 8 }) { _ in
                    attempts += 1
                    throw failure
                }
                Issue.record("A different read error must fail")
            } catch {
                let nativeError = error as NSError
                #expect(nativeError.domain == failure.domain && nativeError.code == failure.code)
                #expect(nativeError.localizedDescription == failure.localizedDescription)
            }
            #expect(attempts == 1)
        }
    }

    @Test @MainActor func expiredOriginalFocusBudgetPreventsTheSecondRead() async {
        let deadline = 8.0
        var now = 0.0
        var attempts = 0
        do {
            _ = try await SelectedKeyboardFocusRead.perform(remainingSeconds: {
                guard now < deadline else { throw FocusReadFailure.deadlineExpired }
                return deadline - now
            }) { _ in
                attempts += 1
                now = deadline
                throw NSError(domain: "DTXProxyChannel", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Channel disconnected"])
            }
            Issue.record("An expired original deadline must fail")
        } catch FocusReadFailure.deadlineExpired {
            #expect(now == deadline)
        } catch {
            Issue.record("The original budget error must propagate")
        }
        #expect(attempts == 1)
    }

    @Test @MainActor func cancelledFocusReadDoesNotReacquire() async {
        var attempts = 0
        do {
            _ = try await SelectedKeyboardFocusRead.perform(remainingSeconds: { 8 }) { _ in
                attempts += 1
                throw CancellationError()
            }
            Issue.record("A cancelled read must fail")
        } catch is CancellationError {
            #expect(attempts == 1)
        } catch {
            Issue.record("Cancellation must propagate unchanged")
        }
        #expect(attempts == 1)
    }

}
