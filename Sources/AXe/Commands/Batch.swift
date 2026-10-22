import ArgumentParser
import Foundation

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Execute ordered legacy steps or guarded complete selected steps.",
        discussion: """
        Batch executes multiple interaction steps in one command to reduce overhead.
        Steps are executed in order.
        Legacy mode uses one simulator/HID session and supports --continue-on-error.
        On Duo, one measured display/session is fixed for the whole ordinary batch.
        Folding, rotation, cancellation or an input failure stops later input without replay.
        --continue-on-error still permits pre-input step errors while that session is valid.
        The batch releases its remaining input before exit; no contact transfers to another command.
        Batch-level selected mode sends each complete step through the selected owner.
        It returns one JSON receipt per attempted step and stops on any failure.
        Earlier steps are not undone. AX targets and focus are read afresh per step.
        Selected mode has no whole-batch exclusive lock or cross-step context token.
        Selected button home and side-button use device-wide routes with active-screen admission.
        Their receipts prove transport and release, not UI or security state. Other buttons, retained
        touch and semantic press are not yet supported in selected batches.
        Selected type --stdin reads 1–256 UTF-8 bytes at its ordered step, before input ownership.
        It preserves newlines and uses the existing US keyboard conversion. Close the input to
        finish the read; there is no EOF deadline or task cancellation during a blocked read.
        Use --step or --file for the batch commands: batch --stdin consumes stdin itself.
        A later type --stdin sees EOF and rejects empty input; no input is replayed.
        Selected sleep accepts finite non-negative seconds with no total cap. It waits on the
        host without an input lease; a typed host-wait receipt has no request or broker ID.
        Cancellation or SIGINT/SIGTERM observed during that wait stops later steps.
        Signal handling is wait-only, not a whole-batch cancellation guarantee.
        Use per-step --expected-pid and --focus-id where required; Home and side-button support --expected-boot.

        Legacy step commands:
          tap, swipe, gesture, touch, type, button, key, key-sequence, key-combo

        Legacy and selected batch-only pseudo-step:
          sleep <seconds>

        Examples:
          axe batch --udid SIMULATOR_UDID --step "tap --id BackButton" --step "type 'hello'"
          axe batch --udid SIMULATOR_UDID --file steps.txt
          cat steps.txt | axe batch --udid SIMULATOR_UDID --stdin
        """
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @OptionGroup var selectedInput: SelectedInputOptions

    @Option(name: .customLong("step"), help: "Step to execute. Repeat for multiple steps.")
    var steps: [String] = []

    @Option(name: .customLong("file"), help: "Read steps from a file (one step per line).")
    var file: String?

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

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging to stderr.")
    var verbose: Bool = false

    func validate() throws {
        try selectedInput.validate()
        if selectedInput.mode == .selected {
            guard !continueOnError, axCachePolicy == .perBatch, typeSubmissionMode == .chunked,
                  typeChunkSize == 200, tapStyle == .automatic, waitTimeout == 0, pollInterval == 0.25 else {
                throw ValidationError("Selected batch stops on failure and does not use legacy cache, type chunk, tap-style or polling settings.")
            }
        }
        let sourceCount = [!steps.isEmpty, file != nil, useStdin].filter { $0 }.count
        guard sourceCount == 1 else {
            throw ValidationError("Specify exactly one step source: --step, --file, or --stdin.")
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
        if selectedInput.mode == .selected {
            let lines = try loadStepLines()
            guard !lines.isEmpty else { throw ValidationError("No executable steps found.") }
            try await SelectedBatchRunner.run(lines: lines, input: selectedInput, simulatorUDID: simulatorUDID)
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
        print("✓ Batch completed successfully (\(stepLines.count) steps)")
    }

    @MainActor
    private func runOrdinaryBatch(_ lines: [String], logger: AxeLogger) async throws {
        let measured = try await LegacyDuoInput.captureContext(
            simulatorUDID: simulatorUDID, preDelay: nil, logger: logger)
        let owner: SelectedHIDOwner?
        if measured != nil {
            guard let executable = Bundle.main.executableURL else {
                throw SelectedHIDFailure.invalid("Missing executable")
            }
            owner = SelectedHIDOwner(simulatorUDID: simulatorUDID, logger: logger,
                helperURL: executable.deletingLastPathComponent().appendingPathComponent("cadisplay-context"))
        } else {
            owner = nil
        }
        let context = BatchContext(simulatorUDID: simulatorUDID, axCachePolicy: axCachePolicy,
            typeSubmissionMode: typeSubmissionMode, typeChunkSize: typeChunkSize, tapStyle: tapStyle,
            waitTimeout: waitTimeout, pollInterval: pollInterval, duoOwner: owner)

        if let owner, let measured {
            let runner = BatchPlanRunner(duoOwner: owner, logger: logger)
            try await LegacyDuoBatchLifetime.run {
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
                try await context.validateCurrentContext()
                try await runner.run(BatchPlan(primitives: primitives))
            } catch {
                let stepError = error
                if context.duoOwner != nil {
                    do { try await context.validateCurrentContext() }
                    catch {
                        throw CLIError(errorDescription: "Step \(index + 1) failed: [\(stepName)]\n\(stepError.localizedDescription)\nDuo batch stopped; \(error.localizedDescription). Later input was not replayed.")
                    }
                }
                if continueOnError {
                    failures.append("Step \(index + 1) failed: [\(stepName)] -> \(stepError.localizedDescription)")
                } else {
                    throw CLIError(errorDescription: "Step \(index + 1) failed: [\(stepName)]\n\(stepError.localizedDescription)")
                }
            }
        }

        if !failures.isEmpty {
            let failureMessage = failures.joined(separator: "\n")
            throw CLIError(errorDescription: "Batch completed with \(failures.count) failure(s):\n\(failureMessage)")
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

