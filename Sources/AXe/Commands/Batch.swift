import ArgumentParser
import Foundation

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run input steps in order in one command.",
        discussion: """
        Each step is an AXe command line without --udid. Steps run in order in one input session; a failed step stops the batch, and earlier steps are not undone. Blank lines and lines starting with # are skipped.

        Steps: tap, swipe, gesture, draw, touch, type, button, key, key-sequence, key-combo and sleep <seconds>. Selected input also accepts slider and drag.

        With --agent, pass a JSON document of 1 to 8 tap and type steps with --file or --steps-json; see the batch reference in the AXe skill.

        Examples:
          axe batch --udid <UDID> --step "tap --id BackButton" --step "type 'hello'"
          axe batch --udid <UDID> --file steps.txt
          axe batch --udid <UDID> --step "tap --label Search" --step "sleep 0.5"
          axe batch --agent --udid <UDID> --file steps.json
        """
    )

    @Option(name: .customLong("udid"), help: "UDID of the simulator or physical device.")
    var simulatorUDID: String

    @OptionGroup var selectedInput: SelectedInputOptions

    @Flag(name: .customLong("agent"), help: "Run a JSON document of 1 to 8 tap and type steps.")
    var agentMode = false

    @Option(name: .customLong("view"), help: "Agent only: result detail; reading by default.")
    var agentView: AgentOutputView?

    @Option(name: .customLong("expected-pid"), help: "Agent only: require this frontmost app PID.")
    var expectedPID: Int32?

    @Option(name: .customLong("step"), help: "One step, such as \"tap --id Save\". Repeat for more steps.")
    var steps: [String] = []

    @Option(name: .customLong("file"), help: "Read steps from this file, one per line, or the JSON document with --agent.")
    var file: String?

    @Option(name: .customLong("steps-json"), help: "Agent only: the JSON document inline, at most 16384 bytes.")
    var stepsJSON: String?

    @Flag(name: .customLong("stdin"), help: "Read steps from standard input, one per line.")
    var useStdin: Bool = false

    @Option(name: .customLong("ax-cache"), help: "When selector taps reuse the accessibility tree.")
    var axCachePolicy: AXCachePolicy = .perBatch

    @Option(name: .customLong("type-submission"), help: "How type steps send their key events.")
    var typeSubmissionMode: TypeSubmissionMode = .chunked

    @Option(name: .customLong("type-chunk-size"), help: "Key events per chunk with --type-submission chunked (default 200).")
    var typeChunkSize: Int?

    @Option(name: .customLong("tap-style"), help: "Default style of tap steps, as in tap --tap-style; selected input accepts only automatic.")
    var tapStyle: TapStyle = .automatic

    @Flag(name: .customLong("continue-on-error"), help: "Simulators: run the remaining steps after a failed step. The iPhone Duo still stops after a screen change or input failure.")
    var continueOnError: Bool = false

    @Option(name: .customLong("wait-timeout"), help: "Seconds selector taps wait for their element to appear.")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility reads while waiting (default 0.25).")
    var pollInterval: Double?

    @Flag(name: .customLong("verbose"), help: "Log progress to stderr; with selected input, print each step's JSON receipt instead.")
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
                  typeSubmissionMode == .chunked, typeChunkSize == nil, tapStyle == .automatic,
                  waitTimeout == 0, pollInterval == nil else {
                throw ValidationError("Agent batch requires exactly one --file or --steps-json JSON source; screen, legacy batch settings, stdin and continued errors are unsupported.")
            }
        } else if expectedPID != nil {
            throw ValidationError("Batch-level --expected-pid requires --agent; selected steps keep their own PID options.")
        }
        if selectedInput.mode == .selected {
            guard !continueOnError, axCachePolicy == .perBatch, typeSubmissionMode == .chunked,
                  typeChunkSize == nil, tapStyle == .automatic, waitTimeout == 0, pollInterval == nil else {
                throw ValidationError("Selected batch stops on failure and does not use legacy cache, type chunk, tap-style or polling settings.")
            }
        }
        let sourceCount = [!steps.isEmpty, file != nil, useStdin, stepsJSON != nil].filter { $0 }.count
        guard sourceCount == 1 else {
            throw ValidationError(agentMode
                ? "Specify exactly one agent JSON source: --file or --steps-json."
                : "Specify exactly one step source: --step, --file, or --stdin.")
        }

        if let typeChunkSize, typeChunkSize <= 0 {
            throw ValidationError("--type-chunk-size must be greater than 0.")
        }

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0, let pollInterval {
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
        try await SelectedBatchRunner.writeSummary(steps: stepLines.count)
    }

    @MainActor
    private func runPhysicalBatch(on device: CoreDevice) async throws {
        guard !agentMode, selectedInput.mode == .legacy, !continueOnError, !verbose,
              axCachePolicy == .perBatch, typeSubmissionMode == .chunked, typeChunkSize == nil,
              tapStyle != .simulator, waitTimeout == 0, pollInterval == nil else {
            throw AutomationTarget.unsupportedOnDevice(
                "Use ordinary input and default batch settings on a physical device. Physical batches stop after a failure.")
        }
        let lines = try loadStepLines()
        guard !lines.isEmpty else { throw ValidationError("No executable steps found.") }
        try await PhysicalDeviceBatch.run(lines, on: device, udid: simulatorUDID)
        try SelectedBatchRunner.writeSummary(steps: lines.count)
    }

    @MainActor
    private func runOrdinaryBatch(_ lines: [String], logger: AxeLogger) async throws {
        let measured = try await OrdinaryBrokerInput.captureRoute(
            simulatorUDID: simulatorUDID, preDelay: nil, logger: logger)?.context
        let owner: SelectedHIDOwner?
        if measured != nil {
            owner = SelectedHIDOwner(simulatorUDID: simulatorUDID, logger: logger)
        } else {
            owner = nil
        }
        let context = BatchContext(simulatorUDID: simulatorUDID, axCachePolicy: axCachePolicy,
            typeSubmissionMode: typeSubmissionMode, typeChunkSize: typeChunkSize ?? 200, tapStyle: tapStyle,
            waitTimeout: waitTimeout, pollInterval: pollInterval ?? 0.25, duoOwner: owner,
            duoLogicalSize: measured.map { ($0.logicalWidth, $0.logicalHeight) })

        if let owner, let measured {
            let runner = BatchPlanRunner(duoOwner: owner, logger: logger)
            try await SignalScope.cancellingOnSignal {
                try await owner.withOrdinaryBatch(context: measured) {
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

