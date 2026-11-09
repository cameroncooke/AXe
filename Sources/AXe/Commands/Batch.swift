import ArgumentParser
import Foundation

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Execute ordered interaction steps on a simulator or physical device.",
        discussion: """
        Batch executes multiple interaction steps in one command to reduce overhead.
        Steps are executed in order.
        --agent accepts 1...8 JSON tap/type steps with native IDs or published refs.
        Supply exactly one --file steps.json or --steps-json '<JSON document>'.
        Ref JSON includes one snapshotID and ref on every step; do not mix refs with IDs.
        Optional --expected-pid asserts that app PID for every step.
        It resolves each target again, stops on failed action/refresh or changed device context,
        and reports completed steps without rollback or replay. See the agent guide for JSON.
        Legacy mode uses one simulator/HID session and supports --continue-on-error.
        A physical device uses one input session for ordered steps and stops on failure.
        Physical batches accept coordinate taps, preset gestures and supported physical input.
        The batch releases any held touch when it ends.
        Simulator selection, agent mode and custom simulator batch settings are unavailable.
        On Duo, one measured display/session is fixed for the whole ordinary batch.
        Folding, rotation, cancellation or an input failure stops later input without replay.
        --continue-on-error still permits pre-input step errors while that session is valid.
        The batch releases its remaining input before exit; no contact transfers to another command.
        Batch-level selected mode sends each complete step through the selected owner.
        It stops on any failure and reports the failing step's error; on success it prints the
        plain batch summary. --verbose also prints one JSON receipt per attempted step.
        Without --screen-id/--screen-uuid each step uses the screen that is active when it starts.
        Earlier steps are not undone. AX targets and focus are read afresh per step.
        Selected mode has no whole-batch exclusive lock or cross-step context token.
        Selected button steps (home, side-button, siri, lock, apple-pay) use device-wide routes with
        active-screen admission. They prove transport and release, not UI or security state. Retained
        touch and semantic press are not supported in selected batches.
        Selected type --stdin reads 1–256 UTF-8 bytes at its ordered step, before input ownership.
        It preserves newlines and uses the existing US keyboard conversion. Close the input to
        finish the read; there is no EOF deadline or task cancellation during a blocked read.
        Use --step or --file for the batch commands: batch --stdin consumes stdin itself.
        A later type --stdin sees EOF and rejects empty input; no input is replayed.
        Selected sleep accepts finite non-negative seconds with no total cap. It waits on the
        host without an input lease; a typed host-wait receipt has no request or broker ID.
        Cancellation or SIGINT/SIGTERM observed during that wait stops later steps.
        Signal handling is wait-only, not a whole-batch cancellation guarantee.
        Keyboard steps require --focus-id; per-step --expected-pid is an optional guard.

        Legacy step commands:
          tap, swipe, gesture, touch, type, button, key, key-sequence, key-combo

        Batch-only pseudo-step:
          sleep <seconds>

        Examples:
          axe batch --udid SIMULATOR_UDID --step "tap --id BackButton" --step "type 'hello'"
          axe batch --udid SIMULATOR_UDID --file steps.txt
          cat steps.txt | axe batch --udid SIMULATOR_UDID --stdin
        """
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator or physical device.")
    var simulatorUDID: String

    @OptionGroup var selectedInput: SelectedInputOptions

    @Flag(name: .customLong("agent"), help: "Execute 1...8 JSON tap/type steps with native IDs or one snapshot's refs and one agent result.")
    var agentMode = false

    @Option(name: .customLong("view"), help: "Agent output: reading (default), navigation, or full canonical detail. Raw commands are unchanged.")
    var agentView: AgentOutputView?

    @Option(name: .customLong("expected-pid"), help: "Agent batch only: optionally require this app PID for every step.")
    var expectedPID: Int32?

    @Option(name: .customLong("step"), help: "Step to execute. Repeat for multiple steps.")
    var steps: [String] = []

    @Option(name: .customLong("file"), help: "Read steps from a file: one step per line, or JSON with --agent.")
    var file: String?

    @Option(name: .customLong("steps-json"), help: "Agent only: inline JSON document, instead of --file. The same 16384-byte and eight-step limits apply.")
    var stepsJSON: String?

    @Flag(name: .customLong("stdin"), help: "Read steps from stdin (one step per line).")
    var useStdin: Bool = false

    @Option(name: .customLong("ax-cache"), help: "Accessibility snapshot cache policy for selector-based taps.")
    var axCachePolicy: AXCachePolicy = .perBatch

    @Option(name: .customLong("type-submission"), help: "Type step submission mode.")
    var typeSubmissionMode: TypeSubmissionMode = .chunked

    @Option(name: .customLong("type-chunk-size"), help: "Maximum HID events per chunk when type-submission is chunked.")
    var typeChunkSize: Int = 200

    @Option(name: .customLong("tap-style"), help: "Legacy default tap event style: automatic uses physical touch for switches/toggles and simulator tap for other targets; simulator always uses FBSimulator tapAt; physical uses touch down/up. Selected mode uses per-step styles only: batch-level automatic is accepted as the default but does not change step style; physical and simulator reject.")
    var tapStyle: TapStyle = .automatic

    @Flag(name: .customLong("continue-on-error"), help: "Continue after step errors. Duo still stops after context loss or native input failure.")
    var continueOnError: Bool = false

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for selector-based elements before failing (0 = no waiting).")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active.")
    var pollInterval: Double = 0.25

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging to stderr. Selected batch: print each step's full JSON receipt instead of the summary.")
    var verbose: Bool = false

    func validate() throws {
        try selectedInput.validate()
        guard agentMode || agentView == nil else {
            throw ValidationError("--view requires --agent.")
        }
        guard agentMode || stepsJSON == nil else {
            throw ValidationError("--steps-json requires --agent.")
        }
        if agentMode {
            CLIOutput.setAgentView(agentView ?? .reading)
            if let expectedPID, expectedPID <= 0 {
                throw ValidationError("--expected-pid must be positive when provided with --agent.")
            }
            guard (file != nil) != (stepsJSON != nil), steps.isEmpty, !useStdin,
                  selectedInput.screenID == nil, selectedInput.screenUUID == nil,
                  selectedInput.mode != .selected, !continueOnError, !verbose, axCachePolicy == .perBatch,
                  typeSubmissionMode == .chunked, typeChunkSize == 200, tapStyle == .automatic,
                  waitTimeout == 0, pollInterval == 0.25 else {
                throw ValidationError("Agent batch requires exactly one --file or --steps-json JSON source; screen, legacy batch settings, stdin and continued errors are unsupported.")
            }
        } else if expectedPID != nil {
            throw ValidationError("Batch-level --expected-pid requires --agent; selected steps keep their own PID options.")
        }
        if selectedInput.mode == .selected {
            guard !continueOnError, axCachePolicy == .perBatch, typeSubmissionMode == .chunked,
                  typeChunkSize == 200, tapStyle == .automatic, waitTimeout == 0, pollInterval == 0.25 else {
                throw ValidationError("Selected batch stops on failure and does not use legacy cache, type chunk, tap-style or polling settings.")
            }
        }
        let sourceCount = [!steps.isEmpty, file != nil, useStdin, stepsJSON != nil].filter { $0 }.count
        guard sourceCount == 1 else {
            throw ValidationError(agentMode
                ? "Specify exactly one agent JSON source: --file or --steps-json."
                : "Specify exactly one step source: --step, --file, or --stdin.")
        }

        guard typeChunkSize > 0 else {
            throw ValidationError("--type-chunk-size must be greater than 0.")
        }

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    func run() async throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID),
           let device = try await AutomationTarget.physicalInputDevice(udid: simulatorUDID) {
            try await runPhysicalBatch(on: device)
            return
        }
        if agentMode {
            try validate()
            if let stepsJSON {
                try AgentBatchCommandAdapter.run(data: Data(stepsJSON.utf8), expectedPID: expectedPID,
                    simulatorUDID: simulatorUDID)
            } else {
                guard let file else { throw ValidationError("Missing agent batch JSON source.") }
                try AgentBatchCommandAdapter.run(file: file, expectedPID: expectedPID, simulatorUDID: simulatorUDID)
            }
            return
        }
        if selectedInput.mode == .selected {
            let lines = try loadStepLines()
            guard !lines.isEmpty else { throw ValidationError("No executable steps found.") }
            try await SelectedBatchRunner.run(lines: lines, input: selectedInput, simulatorUDID: simulatorUDID,
                verbose: verbose)
            return
        }
        let logger = AxeLogger(writeToStdErr: verbose)
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let stepLines = try loadStepLines()
        if stepLines.isEmpty {
            throw ValidationError("No executable steps found.")
        }

        try await runOrdinaryBatch(stepLines, logger: logger)
        CLIOutput.message("✓ Batch completed successfully (\(stepLines.count) steps)")
    }

    @MainActor
    private func runPhysicalBatch(on device: CoreDevice) async throws {
        guard !agentMode, selectedInput.mode == .legacy, !continueOnError, !verbose,
              axCachePolicy == .perBatch, typeSubmissionMode == .chunked, typeChunkSize == 200,
              tapStyle != .simulator, waitTimeout == 0, pollInterval == 0.25 else {
            throw AutomationTarget.unsupportedOnDevice(
                "Use ordinary input and default batch settings on a physical device. Physical batches stop after a failure.")
        }
        let lines = try loadStepLines()
        guard !lines.isEmpty else { throw ValidationError("No executable steps found.") }
        try await PhysicalDeviceBatch.run(lines, on: device, udid: simulatorUDID)
        CLIOutput.message("Batch completed successfully (\(lines.count) steps)")
    }

    @MainActor
    private func runOrdinaryBatch(_ lines: [String], logger: AxeLogger) async throws {
        let measured = try await LegacyDuoInput.captureRoute(
            simulatorUDID: simulatorUDID, preDelay: nil, logger: logger)?.context
        let owner: SelectedHIDOwner?
        if measured != nil {
            owner = SelectedHIDOwner(simulatorUDID: simulatorUDID, logger: logger)
        } else {
            owner = nil
        }
        let context = BatchContext(simulatorUDID: simulatorUDID, axCachePolicy: axCachePolicy,
            typeSubmissionMode: typeSubmissionMode, typeChunkSize: typeChunkSize, tapStyle: tapStyle,
            waitTimeout: waitTimeout, pollInterval: pollInterval, duoOwner: owner,
            duoLogicalSize: measured.map { ($0.logicalWidth, $0.logicalHeight) })

        if let owner, let measured {
            let runner = BatchPlanRunner(duoOwner: owner, logger: logger)
            try await SignalScope.cancellingOnSignal {
                try await owner.withLegacyBatch(context: measured) {
                    try await runSteps(lines, context: context, runner: runner, logger: logger)
                }
            }
            return
        }
        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        let runner = BatchPlanRunner(session: session, logger: logger)
        try await runSteps(lines, context: context, runner: runner, logger: logger)
    }

    @MainActor
    private func runSteps(_ lines: [String], context: BatchContext,
                          runner: BatchPlanRunner, logger: AxeLogger) async throws {
        var failures: [String] = []

        for (index, line) in lines.enumerated() {
            var stepName = "<unparsed>"
            do {
                try await context.validateCurrentContext()
                let tokens = try ShellTokenizer.tokenize(line)
                stepName = tokens.first ?? "<empty>"
                let primitives = try await BatchStepParser.parseStepTokens(
                    tokens,
                    globalUDID: simulatorUDID,
                    context: context,
                    logger: logger
                )
                try await context.validateInputBoundary()
                try await runner.run(BatchPlan(primitives: primitives))
            } catch {
                // A failed step keeps its own code.
                let stepFailure = CLIErrorMapping.failure(for: error)
                if context.duoOwner != nil {
                    do { try await context.validateCurrentContext() }
                    catch {
                        let stopped = CLIErrorMapping.failure(for: error)
                        throw CLIOutputFailure(code: stopped.code,
                            message: "Step \(index + 1) failed: [\(stepName)]\n\(stepFailure.message)\nThe batch stopped: \(stopped.message)")
                    }
                }
                if continueOnError {
                    failures.append("Step \(index + 1) failed: [\(stepName)] -> \(stepFailure.message)")
                } else {
                    throw CLIOutputFailure(code: stepFailure.code,
                        message: "Step \(index + 1) failed: [\(stepName)]\n\(stepFailure.message)")
                }
            }
        }

        if !failures.isEmpty {
            let failureMessage = failures.joined(separator: "\n")
            throw CLIError(errorDescription: "Batch completed with \(failures.count) failure(s):\n\(failureMessage)", code: .inputFailed)
        }
    }

    private func loadStepLines() throws -> [String] {
        let rawLines: [String]
        if !steps.isEmpty {
            rawLines = steps
        } else if let file {
            let contents: String
            do {
                contents = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                throw ValidationError("Failed to read step file '\(file)': \(error.localizedDescription)")
            }
            rawLines = contents.components(separatedBy: .newlines)
        } else {
            rawLines = readStdinLines()
        }

        return rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func readStdinLines() -> [String] {
        var lines: [String] = []
        while let line = readLine() {
            lines.append(line)
        }
        return lines
    }
}

