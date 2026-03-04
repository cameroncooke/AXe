import ArgumentParser
import Foundation

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Execute ordered interaction steps using one simulator/HID session.",
        discussion: """
        Batch executes multiple interaction steps in one command to reduce overhead.
        Steps are executed in order.

        Supported step commands:
          tap, swipe, gesture, touch, type, button, key, key-sequence, key-combo

        Batch-only pseudo-step:
          sleep <seconds>

        Examples:
          axe batch --udid SIMULATOR_UDID --step "tap --id BackButton" --step "type 'hello'"
          axe batch --udid SIMULATOR_UDID --file steps.txt
          cat steps.txt | axe batch --udid SIMULATOR_UDID --stdin
        """
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

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

    @Flag(name: .customLong("continue-on-error"), help: "Continue executing later steps even if one step fails.")
    var continueOnError: Bool = false

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for selector-based elements before failing (0 = no waiting).")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active.")
    var pollInterval: Double = 0.25

    func validate() throws {
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
        let logger = AxeLogger(writeToStdErr: true)
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let stepLines = try loadStepLines()
        if stepLines.isEmpty {
            throw ValidationError("No executable steps found.")
        }

        let context = await MainActor.run {
            BatchContext(
                simulatorUDID: simulatorUDID,
                axCachePolicy: axCachePolicy,
                typeSubmissionMode: typeSubmissionMode,
                typeChunkSize: typeChunkSize,
                waitTimeout: waitTimeout,
                pollInterval: pollInterval
            )
        }

        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        let runner = BatchPlanRunner(session: session, logger: logger)

        var failures: [String] = []

        for (index, line) in stepLines.enumerated() {
            var stepName = "<unparsed>"
            do {
                let tokens = try ShellTokenizer.tokenize(line)
                stepName = tokens.first ?? "<empty>"
                let primitives = try await BatchStepParser.parseStepTokens(
                    tokens,
                    globalUDID: simulatorUDID,
                    context: context,
                    logger: logger
                )
                try await runner.run(BatchPlan(primitives: primitives))
            } catch {
                if continueOnError {
                    failures.append("Step \(index + 1) failed: [\(stepName)] -> \(error.localizedDescription)")
                } else {
                    throw CLIError(errorDescription: "Step \(index + 1) failed: [\(stepName)]\n\(error.localizedDescription)")
                }
            }
        }

        if !failures.isEmpty {
            let failureMessage = failures.joined(separator: "\n")
            throw CLIError(errorDescription: "Batch completed with \(failures.count) failure(s):\n\(failureMessage)")
        }

        print("✓ Batch completed successfully (\(stepLines.count) steps)")
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

