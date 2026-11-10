import ArgumentParser
import AXeCore
import Foundation

struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Reach a natural-language goal on a simulator with TypeSafe AI.",
        discussion: """
        AXe reads the frontmost app's accessibility tree, asks TypeSafe AI's Jev model for one action at a time and checks each action before sending it; screenshots are not sent. Set TYPESAFE_API_KEY. Text that the goal does not state also needs AXE_TEXT_MODEL_API_KEY for an OpenAI-compatible text model. This command is separate from the --agent option of other commands.

        Examples:
          axe agent "Open Settings and turn on Airplane Mode" --udid <UDID>
          axe agent "Create a note saying 'Buy milk'" --trace trace.json --udid <UDID>
        """
    )

    @Argument(help: "The outcome to reach, in plain language.")
    var goal: String

    @Option(name: .customLong("udid"), help: "UDID of the booted simulator.")
    var simulatorUDID: String

    @Option(name: .customLong("max-steps"), help: "Most actions before stopping, 1 to 200.")
    var maximumSteps: Int = 40

    @Option(name: .customLong("model"), help: "TypeSafe model (default: TYPESAFE_MODEL, TYPESAFE_DEFAULT_MODEL or jev-latest).")
    var model: String?

    @Option(name: .customLong("base-url"), help: "TypeSafe API base URL, HTTPS unless on this Mac (default: TYPESAFE_BASE_URL or https://api.typesafe.ai).")
    var baseURL: String?

    @Option(
        name: .customLong("minimum-action-probability"),
        help: "Refuse actions that the model rates below this probability, 0 to 1."
    )
    var minimumActionProbability: Double = 0

    @Option(name: .customLong("trace"), help: "Write a JSON decision trace to this path. It can contain screen text and entered values.")
    var tracePath: String?

    @Flag(name: .customLong("json"), help: "Print only the final result as JSON.")
    var jsonOutput: Bool = false

    func validate() throws {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("The goal must not be empty.")
        }
        guard (1...200).contains(maximumSteps) else {
            throw ValidationError("--max-steps must be between 1 and 200.")
        }
        guard minimumActionProbability.isFinite,
              (0...1).contains(minimumActionProbability) else {
            throw ValidationError("--minimum-action-probability must be between 0 and 1.")
        }
        if let baseURL {
            _ = try Self.validatedHTTPURL(baseURL, optionName: "--base-url")
        }
        if let tracePath, tracePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--trace must not be empty.")
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["TYPESAFE_API_KEY"],
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(
                errorDescription: "TYPESAFE_API_KEY is required for `axe agent`. Create a TypeSafe API key and export it before running the command."
            )
        }

        let resolvedModel = model
            ?? environment["TYPESAFE_MODEL"]
            ?? environment["TYPESAFE_DEFAULT_MODEL"]
            ?? TypeSafeClient.defaultModel
        let resolvedBaseURLString = baseURL
            ?? environment["TYPESAFE_BASE_URL"]
            ?? TypeSafeClient.defaultBaseURL.absoluteString
        let resolvedBaseURL = try Self.validatedHTTPURL(
            resolvedBaseURLString,
            optionName: "TypeSafe base URL"
        )
        let typeSafeClient = try TypeSafeClient(
            apiKey: apiKey,
            baseURL: resolvedBaseURL
        )
        let inputUSDPerMillionTokens = try Self.inputUSDPerMillionTokens(environment: environment)
        let textModelClient = try Self.makeTextModelClient(environment: environment)
        let traceURL = tracePath.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
        }

        let runner = await SimulatorAgentRunner(
            goal: goal,
            simulatorUDID: simulatorUDID,
            model: resolvedModel,
            maximumSteps: maximumSteps,
            minimumActionProbability: minimumActionProbability,
            inputUSDPerMillionTokens: inputUSDPerMillionTokens,
            typeSafeClient: typeSafeClient,
            textModelClient: textModelClient,
            traceURL: traceURL,
            logger: logger,
            emitProgress: !jsonOutput && !CLIOutput.isFormatted
        )
        let result: SimulatorAgentRunResult
        do {
            result = try await runner.run()
        } catch {
            let usage = await runner.usage
            if !jsonOutput, !CLIOutput.isFormatted, usage.calls > 0 {
                print(Self.usageDescription(usage), to: &standardError)
            }
            throw error
        }

        if CLIOutput.isFormatted {
            try CLIOutput.writeJSON(result)
        } else if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(result)
            guard let value = String(data: data, encoding: .utf8) else {
                throw CLIError(errorDescription: "Unable to encode the agent result as JSON.")
            }
            print(value)
        } else {
            let symbol = result.status == .completed ? "✓" : "✗"
            print("\(symbol) \(result.message)")
            print("Steps: \(result.steps), model calls: \(result.modelCalls), elapsed: \(result.elapsedMilliseconds) ms")
            let timing = result.timing
            print(
                "Time: setup \(timing.setupMilliseconds) ms, loop \(timing.loopMilliseconds) ms "
                    + "(Jev \(timing.jevMilliseconds) ms, \(timing.observations) screen reads \(timing.observationMilliseconds) ms, "
                    + "actions \(timing.actionMilliseconds) ms)"
            )
            print(Self.usageDescription(result.usage))
        }

        if result.status == .blocked {
            throw ExitCode.failure
        }
    }

    private static func inputUSDPerMillionTokens(environment: [String: String]) throws -> Double {
        guard let rawValue = environment["TYPESAFE_INPUT_USD_PER_MTOK"] else {
            return TypeSafePricing.defaultInputUSDPerMillionTokens
        }
        guard let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite,
              value >= 0 else {
            throw CLIError(errorDescription: "TYPESAFE_INPUT_USD_PER_MTOK must be a non-negative number.")
        }
        return value
    }

    private static func usageDescription(_ usage: TypeSafeUsageSummary) -> String {
        var description = "Jev usage: \(usage.calls) calls, \(usage.inputTokens) input tokens, "
            + "\(usage.outputTokens) output tokens, "
            + String(
                format: "estimated cost $%.6f (input $%g per MTok, output free)",
                usage.estimatedCostUSD,
                usage.inputUSDPerMillionTokens
            )
        if usage.callsWithoutUsage > 0 {
            description += "; \(usage.callsWithoutUsage) responses did not report usage"
        }
        return description
    }

    private static func makeTextModelClient(
        environment: [String: String]
    ) throws -> AgentTextModelClient? {
        guard let apiKey = environment["AXE_TEXT_MODEL_API_KEY"]
                ?? environment["TEXT_MODEL_API_KEY"],
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let baseURLString = environment["AXE_TEXT_MODEL_BASE_URL"]
            ?? environment["TEXT_MODEL_BASE_URL"]
            ?? "https://api.deepseek.com/v1"
        let model = environment["AXE_TEXT_MODEL"]
            ?? environment["TEXT_MODEL"]
            ?? "deepseek-chat"
        return try AgentTextModelClient(
            apiKey: apiKey,
            baseURL: try validatedHTTPURL(baseURLString, optionName: "text-model base URL"),
            model: model
        )
    }

    /// Both clients send their API key with every request, so plain HTTP is accepted only for a
    /// server on this Mac.
    static func validatedHTTPURL(
        _ rawValue: String,
        optionName: String
    ) throws -> URL {
        guard let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw ValidationError("\(optionName) must be an absolute HTTP or HTTPS URL.")
        }
        guard scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
            throw ValidationError("\(optionName) must use HTTPS, because the API key is sent with every request. Plain HTTP is accepted only for localhost, 127.0.0.1 or ::1.")
        }
        return url
    }
}
