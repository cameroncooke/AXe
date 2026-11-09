import ArgumentParser
import Foundation
import FBSimulatorControl

/// A selected batch contains complete input requests and host waits, never a legacy session.
/// Each broker call resolves its own current context, AX target or focused field.
enum SelectedBatchStep {
    case input(SelectedHIDRequest)
    case hostWait(Double)

    static func parseStep(_ tokens: [String], input: SelectedInputOptions,
                          simulatorUDID: String, standardInput: FileHandle = .standardInput) throws -> SelectedBatchStep {
        guard tokens.first == "sleep" else {
            return .input(try request(tokens, input: input, simulatorUDID: simulatorUDID, standardInput: standardInput))
        }
        try input.validate()
        guard input.mode == .selected else {
            throw ValidationError("Selected batch requires --input-mode selected.")
        }
        guard tokens.count == 2, let seconds = Double(tokens[1]), seconds.isFinite, seconds >= 0 else {
            throw ValidationError("Selected sleep requires one finite, non-negative duration in seconds.")
        }
        return .hostWait(seconds)
    }

    static func request(_ tokens: [String], input: SelectedInputOptions,
                        simulatorUDID: String, standardInput: FileHandle = .standardInput) throws -> SelectedHIDRequest {
        try input.validate()
        guard input.mode == .selected, let name = tokens.first else {
            throw ValidationError("Selected batch requires --input-mode selected and a step command.")
        }
        let stepArguments = Array(tokens.dropFirst())
        let options = stepArguments.prefix(while: { $0 != "--" })
        let batchOnly = ["--udid", "--input-mode", "--screen-id", "--screen-uuid", "--verbose"]
        guard !options.contains(where: { token in
            batchOnly.contains(where: { token == $0 || token.hasPrefix($0 + "=") })
        }) else {
            throw ValidationError("UDID, input mode, display selection and --verbose belong at batch level.")
        }
        // Without a batch-level pair, each step binds the screen that is active when it is admitted.
        var inherited = ["--udid", simulatorUDID, "--input-mode", "selected"]
        if let screenID = input.screenID, let screenUUID = input.screenUUID {
            inherited += ["--screen-id", String(screenID), "--screen-uuid", screenUUID]
        }
        // Put inherited options before a possible '--' literal-text separator.
        let arguments = inherited + stepArguments
        let request: SelectedHIDRequest
        switch name {
        case "tap":
            let command = try parse(Tap.self, arguments)
            guard !command.agentMode.enabled else {
                throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
            }
            guard !command.semanticPress else {
                throw ValidationError("Semantic press is not yet supported in selected batch steps.")
            }
            request = try command.selectedRequest()
        case "button":
            let command = try parse(Button.self, arguments)
            request = try command.selectedRequest()
        case "slider":
            let command = try parse(Slider.self, arguments)
            guard command.value == nil else {
                throw ValidationError("Selected slider percentages require a standalone command and are not supported in batch steps.")
            }
            guard !command.agentMode.enabled else {
                throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
            }
            request = try command.selectedRequest()
        case "swipe":
            let command = try parse(Swipe.self, arguments)
            guard !command.agentMode.enabled else {
                throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
            }
            request = try command.selectedInput.pathRequest(command.selectedPath)
        case "drag":
            let command = try parse(Drag.self, arguments)
            request = try command.selectedRequest()
        case "gesture":
            let command = try parse(Gesture.self, arguments)
            guard !command.agentMode.enabled else {
                throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
            }
            switch command.gesture {
            case .twoFingerSwipe:
                throw ValidationError("Two-finger-swipe is not supported in batch steps. Use a standalone selected gesture.")
            case .preset: request = try command.selectedInput.pathRequest(command.selectedPath())
            case .pinch: request = try command.selectedInput.pinchRequest(command.selectedPinch())
            case .doubleTap, .rotate, .twoFingerTap, .twoFingerHold:
                request = try command.selectedInput.gestureRequest(command.selectedCompleteGesture())
            }
        case "touch":
            let command = try parse(Touch.self, arguments)
            guard command.touchDown, command.touchUp, command.contactToken == nil else {
                throw ValidationError("Selected batch touch requires --down --up and no retained token.")
            }
            request = try command.selectedRequest()
        case "type":
            let command = try parse(Type.self, arguments)
            guard !command.agentMode.enabled else {
                throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
            }
            request = try command.selectedRequest(standardInput: standardInput)
        case "key":
            let command = try parse(Key.self, arguments)
            guard !command.agentMode.enabled else {
                throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
            }
            request = try command.selectedKeyboard.request(input: command.selectedInput, event: command.selectedKeyboardEvent())
        case "key-sequence":
            let command = try parse(KeySequence.self, arguments)
            guard !command.agentMode.enabled else {
                throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
            }
            request = try command.selectedKeyboard.request(input: command.selectedInput, event: command.selectedKeyboardEvent())
        case "key-combo":
            let command = try parse(KeyCombo.self, arguments)
            guard !command.agentMode.enabled else {
                throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
            }
            request = try command.selectedKeyboard.request(input: command.selectedInput, event: command.selectedKeyboardEvent())
        default:
            throw ValidationError("Selected batch does not yet support step '\(name)'.")
        }
        try request.validate()
        guard request.operation == .complete, request.token == nil, request.hinge == nil else {
            throw ValidationError("Selected batch accepts only complete selected screen operations.")
        }
        return request
    }

    private static func parse<C: AsyncParsableCommand>(_ type: C.Type, _ arguments: [String]) throws -> C {
        guard var command = try C.parseAsRoot(arguments) as? C else {
            throw ValidationError("The selected step did not parse as its expected command.")
        }
        try command.validate()
        return command
    }
}

struct SelectedBatchStepReceipt: Encodable {
    enum Status: String, Encodable { case completed, rejectedBeforeSend, failedResponse, outcomeUnknown, waitInterrupted, waitFailed }
    let schemaVersion = 1
    let index: Int
    let totalSteps: Int
    let command: String?
    let requestID: UUID?
    let status: Status
    let response: SelectedHIDResponse?
    let error: String?
    var hostWait: SelectedBatchHostWaitReceipt? = nil
}

/// The default result of a successful selected batch. Step receipts stay behind `--verbose`.
struct SelectedBatchSummary: Encodable {
    let steps: Int
    let outcome: String
}

/// With `verbose`, responses are emitted as JSON lines before the next step starts. Without it the
/// batch reports one summary, or the failing step's error. Failure stops the loop.
/// An output failure also stops; it never causes the input request to be sent again.
@MainActor
enum SelectedBatchRunner {
    static func run(lines: [String], input: SelectedInputOptions, simulatorUDID: String,
                    verbose: Bool = false) async throws {
        let send: (SelectedHIDRequest, String) throws -> SelectedHIDResponse = {
            try SelectedHIDBroker.send($0, simulatorUDID: $1)
        }
        let wait: (Double) async -> SelectedBatchHostWaitReceipt = {
            await SelectedBatchHostWait.runWithSignals(seconds: $0)
        }
        if verbose {
            try await run(lines: lines, input: input, simulatorUDID: simulatorUDID, send: send,
                emit: { try writeReceipt($0) }, wait: wait, standardInput: .standardInput)
            return
        }
        var last: SelectedBatchStepReceipt?
        do {
            try await run(lines: lines, input: input, simulatorUDID: simulatorUDID, send: send,
                emit: { last = $0 }, wait: wait, standardInput: .standardInput)
        } catch {
            throw failure(last, stopError: error)
        }
        try writeSummary(steps: lines.count)
    }

    static func writeSummary(steps: Int) throws {
        if CLIOutput.isFormatted {
            try CLIOutput.writeJSON(SelectedBatchSummary(steps: steps, outcome: "completed"))
        } else {
            CLIOutput.message("✓ Batch completed successfully (\(steps) steps)")
        }
    }

    /// The failing step's own error, without its receipt. Nothing is replayed.
    static func failure(_ receipt: SelectedBatchStepReceipt?, stopError: Error) -> Error {
        guard let receipt, receipt.status != .completed else { return stopError }
        let step = "Selected batch step \(receipt.index) of \(receipt.totalSteps)" +
            (receipt.command.map { " [\($0)]" } ?? "")
        let earlier = receipt.index > 1 ? " Earlier steps are not undone." : ""
        let code: String
        let detail: String
        switch receipt.status {
        case .failedResponse:
            if let response = receipt.response {
                let native = SelectedInputOutput.failure(response)
                code = native.code
                detail = native.message
            } else {
                code = "inputFailed"
                detail = receipt.error ?? "The selected operation failed."
            }
        case .rejectedBeforeSend:
            code = "rejectedBeforeInput"
            detail = (receipt.error ?? "The step was rejected.") + " This step sent no input."
        case .outcomeUnknown:
            code = "outcomeUnknown"
            detail = (receipt.error ?? "The broker exchange failed.") + " The step was not replayed; read the screen before trying again."
        case .waitInterrupted, .waitFailed:
            code = receipt.status.rawValue
            detail = receipt.error ?? "The host wait did not complete."
        case .completed:
            return stopError
        }
        return CLIOutputFailure(code: code,
            message: "\(step) failed: \(detail)\(earlier) Later steps were not run; --verbose prints each step's receipt.")
    }

    static func run(lines: [String], input: SelectedInputOptions, simulatorUDID: String,
                    send: (SelectedHIDRequest, String) throws -> SelectedHIDResponse,
                    emit: (SelectedBatchStepReceipt) throws -> Void,
                    wait: (Double) async -> SelectedBatchHostWaitReceipt = {
                        await SelectedBatchHostWait.wait(seconds: $0)
                    },
                    standardInput: FileHandle = .standardInput) async throws {
        for (offset, line) in lines.enumerated() {
            var name: String?
            let step: SelectedBatchStep
            do {
                try Task.checkCancellation()
                let tokens = try ShellTokenizer.tokenize(line)
                name = tokens.first
                // Text is read only at this step, before any broker send or input lease.
                step = try SelectedBatchStep.parseStep(tokens, input: input, simulatorUDID: simulatorUDID,
                    standardInput: standardInput)
                // A synchronous EOF read cannot observe cancellation until it returns.
                try Task.checkCancellation()
            } catch {
                try emit(.init(index: offset + 1, totalSteps: lines.count, command: name, requestID: nil,
                    status: .rejectedBeforeSend, response: nil, error: String(describing: error)))
                throw CLIError(errorDescription: "Selected batch step \(offset + 1) failed before send. Earlier steps are not undone.")
            }
            let request: SelectedHIDRequest
            switch step {
            case .hostWait(let seconds):
                var result = await wait(seconds)
                if Task.isCancelled && result.outcome == .completed {
                    result = .init(requestedSeconds: seconds, elapsedSeconds: result.elapsedSeconds,
                        outcome: .interrupted, error: "The host wait was cancelled.")
                }
                let completed = result.outcome == .completed
                try emit(.init(index: offset + 1, totalSteps: lines.count, command: name, requestID: nil,
                    status: completed ? .completed : (result.outcome == .failed ? .waitFailed : .waitInterrupted), response: nil,
                    error: completed ? nil : (result.error ?? "The host wait was interrupted."), hostWait: result))
                guard completed else {
                    throw CLIError(errorDescription: "Selected batch stopped during host wait at step \(offset + 1).")
                }
                continue
            case .input(let value):
                request = value
            }
            let response: SelectedHIDResponse
            do {
                response = try send(request, simulatorUDID)
            } catch {
                try emit(.init(index: offset + 1, totalSteps: lines.count, command: name, requestID: request.requestID,
                    status: .outcomeUnknown, response: nil, error: String(describing: error)))
                throw CLIError(errorDescription: "Selected batch step \(offset + 1) has an unknown outcome. No request was replayed.")
            }
            let accepted = completed(response, for: request, simulatorUDID: simulatorUDID)
            try emit(.init(index: offset + 1, totalSteps: lines.count, command: name, requestID: request.requestID,
                status: accepted ? .completed : .failedResponse, response: response,
                error: accepted ? nil : "The selected operation did not return a clean complete receipt."))
            guard accepted else {
                throw CLIError(errorDescription: "Selected batch stopped at step \(offset + 1). Inspect its receipt; no input was replayed.")
            }
        }
    }

    static func completed(_ response: SelectedHIDResponse, for request: SelectedHIDRequest,
                          simulatorUDID: String? = nil) -> Bool {
        if request.home != nil || request.button != nil { return completedButton(response, for: request, simulatorUDID: simulatorUDID) }
        guard response.home == nil, response.button == nil else { return false }
        if request.ax?.kind == .sliderEndpoint { return completedSlider(response, for: request) }
        return response.version == request.version && response.requestID == request.requestID &&
        response.error == nil && response.outcome == "enqueuedAndDrained" &&
        response.token == nil && response.quarantine == nil && response.enqueuedEventCount > 0 &&
        (response.cleanup == "notNeeded" || response.cleanup == "releaseEnqueuedAndDrained") &&
        boundScreen(response, for: request)
    }

    /// An explicit pair must match the receipt. Without one the broker bound the active screen,
    /// and the receipt must still carry that bound context.
    private static func boundScreen(_ response: SelectedHIDResponse, for request: SelectedHIDRequest) -> Bool {
        guard let context = response.context, let screenUUID = UUID(uuidString: context.screenUUID) else { return false }
        if request.screenID == nil, request.screenUUID == nil { return request.activeDisplay == true }
        return context.screenID == request.screenID && screenUUID == request.screenUUID
    }

    private static func completedButton(_ response: SelectedHIDResponse, for request: SelectedHIDRequest,
                                      simulatorUDID: String?) -> Bool {
        do { try request.validate() } catch { return false }
        let execution: SelectedButtonExecutionEvidence
        let expectedBoot: String?
        let expectedPrimitiveCount: Int
        if let expected = request.home {
            guard let home = response.home, response.button == nil else { return false }
            execution = home
            expectedBoot = expected.expectedBoot
            expectedPrimitiveCount = 2
        } else if let expected = request.button {
            guard let button = response.button, button.kind == expected.kind, response.home == nil else { return false }
            execution = button.execution
            expectedBoot = expected.expectedBoot
            expectedPrimitiveCount = expected.expectedPrimitiveCount
        } else { return false }
        guard let context = response.context,
              let cleanup = execution.cleanupEvidence, let simulatorUDID,
              let deviceID = UUID(uuidString: simulatorUDID),
              response.version == request.version, response.requestID == request.requestID,
              response.outcome == "enqueuedAndDrained", response.enqueuedEventCount == expectedPrimitiveCount,
              response.error == nil, response.token == nil, response.quarantine == nil,
              response.ax == nil, response.hinge == nil, response.keyboard == nil,
              response.cleanup == "notNeeded", boundScreen(response, for: request),
              expectedBoot == nil || expectedBoot == context.bootIdentity,
              execution.schemaVersion == 1, UUID(uuidString: execution.simulatorUDID) == deviceID,
              execution.axDisplayID == context.screenID,
              execution.phase == "completed", execution.plannedPrimitiveCount == expectedPrimitiveCount,
              execution.sentPrimitiveCount == expectedPrimitiveCount,
              execution.allInputsReleasedBeforeCleanup, execution.drainCompleted, execution.interruption == nil,
              execution.executionCleanup == "notNeeded", execution.startedUptime.isFinite,
              execution.finishedUptime.isFinite, execution.finishedUptime >= execution.startedUptime,
              sameContext(execution.boundContext, context),
              UUID(uuidString: cleanup.boundSimulatorUDID) == deviceID, cleanup.boundBootIdentity == context.bootIdentity,
              cleanup.boundScreenID == context.screenID,
              UUID(uuidString: cleanup.boundScreenUUID) == UUID(uuidString: context.screenUUID),
              cleanup.boundNativeWidth == context.nativePixelWidth,
              cleanup.boundNativeHeight == context.nativePixelHeight, cleanup.boundScale == context.scale,
              cleanup.boundRotation == context.rotationDegrees, cleanup.boundPoseRevision == context.poseRevision,
              cleanup.outcome == "notNeeded", cleanup.contextValidation == "noOwnedInput",
              cleanup.releases.isEmpty, !cleanup.timedOut, cleanup.errorDescription == nil else { return false }
        // The owner proves button transport and release. This does not prove foreground UI.
        return true
    }

    private static func sameContext(_ left: SelectedHIDContext, _ right: SelectedHIDContext) -> Bool {
        left.bootIdentity == right.bootIdentity && left.screenID == right.screenID &&
        UUID(uuidString: left.screenUUID) == UUID(uuidString: right.screenUUID) &&
        left.logicalWidth == right.logicalWidth && left.logicalHeight == right.logicalHeight &&
        left.rotationDegrees == right.rotationDegrees && left.nativePixelWidth == right.nativePixelWidth &&
        left.nativePixelHeight == right.nativePixelHeight && left.scale == right.scale &&
        left.poseRevision == right.poseRevision
    }

    private static func completedSlider(_ response: SelectedHIDResponse, for request: SelectedHIDRequest) -> Bool {
        do { try request.validate() } catch { return false }
        guard let expected = request.ax, let actual = response.ax, let slider = actual.slider,
              response.version == request.version, response.requestID == request.requestID,
              response.error == nil, response.token == nil, response.quarantine == nil,
              response.cleanup == "notNeeded", response.enqueuedEventCount == 0,
              response.hinge == nil, response.keyboard == nil,
              boundScreen(response, for: request),
              actual.kind == expected.kind, let boundPID = actual.expectedPID, boundPID > 0,
              expected.expectedPID == nil || boundPID == expected.expectedPID,
              actual.failure == nil, actual.press == nil,
              slider.endpoint == expected.endpoint, slider.outcome == response.outcome,
              slider.reason == nil, !slider.reasonTruncated,
              slider.actionAttempts == slider.actionsReturned,
              slider.actionsReturned == slider.actions.count else { return false }
        if let elementType = expected.elementType {
            guard !slider.samples.isEmpty,
                  slider.samples.allSatisfy({ $0.elementType?.rawValue == elementType }),
                  slider.actions.allSatisfy({ $0.elementType?.rawValue == elementType }) else { return false }
        }
        // The controller owns target, domain, value and settled-read verification.
        // Batch accepts its two complete semantic outcomes, never a HID count or failed action.
        switch slider.outcome {
        case "endpointObserved":
            return slider.delivery == "valueObserved" && (1...20).contains(slider.actionsReturned)
        case "alreadyAtEndpoint":
            return slider.delivery == "notDispatched" && slider.actionsReturned == 0
        default:
            return false
        }
    }

    static func writeReceipt(_ receipt: SelectedBatchStepReceipt) throws {
        if CLIOutput.isFormatted {
            try CLIOutput.writeJSON(receipt)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(receipt)
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}
