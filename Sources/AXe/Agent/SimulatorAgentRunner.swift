import AXeCore
import Foundation
import FBControlCore

struct SimulatorAgentRunResult: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case completed
        case blocked
    }

    let status: Status
    let goal: String
    let model: String
    let steps: Int
    let modelCalls: Int
    let usage: TypeSafeUsageSummary
    let elapsedMilliseconds: Int
    let message: String
    let history: [AgentHistoryEntry]
    let finalScreen: AgentScreenSnapshot
}

private struct SimulatorAgentTraceEvent: Codable {
    let modelCall: Int
    let observedFingerprint: String
    let request: TypeSafeSystemOneRequest
    let response: TypeSafeSystemOneResponse
    let decision: AgentDecision
    let discardedAsStale: Bool
    let action: AgentHistoryEntry?
    let latencyMilliseconds: Int
}

private struct SimulatorAgentTraceDocument: Codable {
    let schemaVersion: Int
    let goal: String
    let simulatorUDID: String
    let model: String
    var events: [SimulatorAgentTraceEvent]
}

@MainActor
private final class SimulatorAgentTraceRecorder {
    private let outputURL: URL
    private var document: SimulatorAgentTraceDocument

    init(outputURL: URL, goal: String, simulatorUDID: String, model: String) {
        self.outputURL = outputURL
        self.document = SimulatorAgentTraceDocument(
            schemaVersion: 1,
            goal: goal,
            simulatorUDID: simulatorUDID,
            model: model,
            events: []
        )
    }

    func append(_ event: SimulatorAgentTraceEvent) throws {
        document.events.append(event)
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: outputURL, options: .atomic)
    }
}

@MainActor
final class SimulatorAgentRunner {
    private let goal: String
    private let simulatorUDID: String
    private let model: String
    private let maximumSteps: Int
    private let minimumActionProbability: Double
    private let typeSafeClient: TypeSafeClient
    private let textModelClient: AgentTextModelClient?
    private let logger: AxeLogger
    private let emitProgress: Bool
    private let observer: AgentScreenObserver
    private let executor: SimulatorAgentExecutor
    private let policy = AgentPolicy()
    private let traceRecorder: SimulatorAgentTraceRecorder?
    /// Includes calls whose decisions were discarded as stale, because they are still billed.
    private(set) var usage: TypeSafeUsageSummary

    init(
        goal: String,
        simulatorUDID: String,
        model: String,
        maximumSteps: Int,
        minimumActionProbability: Double,
        inputUSDPerMillionTokens: Double,
        typeSafeClient: TypeSafeClient,
        textModelClient: AgentTextModelClient?,
        traceURL: URL?,
        logger: AxeLogger,
        emitProgress: Bool
    ) {
        self.goal = goal
        self.simulatorUDID = simulatorUDID
        self.model = model
        self.maximumSteps = maximumSteps
        self.minimumActionProbability = minimumActionProbability
        self.usage = TypeSafeUsageSummary(inputUSDPerMillionTokens: inputUSDPerMillionTokens)
        self.typeSafeClient = typeSafeClient
        self.textModelClient = textModelClient
        self.logger = logger
        self.emitProgress = emitProgress
        self.observer = AgentScreenObserver(simulatorUDID: simulatorUDID, logger: logger)
        self.executor = SimulatorAgentExecutor(simulatorUDID: simulatorUDID, logger: logger)
        self.traceRecorder = traceURL.map {
            SimulatorAgentTraceRecorder(
                outputURL: $0,
                goal: goal,
                simulatorUDID: simulatorUDID,
                model: model
            )
        }
    }

    func run() async throws -> SimulatorAgentRunResult {
        let started = Date()
        let applications = try await SimulatorApplicationCatalog.applications(for: simulatorUDID)
        var currentApplication: AgentApplication?
        var screen = try await observer.observe(currentApplication: currentApplication)
        if let inferredApplication = Self.inferCurrentApplication(from: screen, applications: applications) {
            currentApplication = inferredApplication
            screen = try await observer.observe(currentApplication: inferredApplication)
        }

        var history: [AgentHistoryEntry] = []
        var modelCalls = 0
        let maximumModelCalls = max(maximumSteps * 3, maximumSteps + 5)

        while history.count < maximumSteps, modelCalls < maximumModelCalls {
            let prepared = try policy.prepareRequest(
                goal: goal,
                screen: screen,
                applications: applications,
                history: history,
                model: model
            )

            let predictionStarted = Date()
            let response = try await typeSafeClient.systemOne(prepared.payload)
            modelCalls += 1
            usage.record(response)
            let latency = Int(Date().timeIntervalSince(predictionStarted) * 1_000)
            let decision = try policy.resolveDecision(
                response: response,
                prepared: prepared,
                minimumActionProbability: minimumActionProbability
            )

            let freshScreen = try await observer.observe(currentApplication: currentApplication)
            guard freshScreen.fingerprint == screen.fingerprint else {
                try traceRecorder?.append(
                    SimulatorAgentTraceEvent(
                        modelCall: modelCalls,
                        observedFingerprint: screen.fingerprint,
                        request: prepared.payload,
                        response: response,
                        decision: decision,
                        discardedAsStale: true,
                        action: nil,
                        latencyMilliseconds: latency
                    )
                )
                screen = freshScreen
                progress("↻ Screen changed while Jev was deciding; discarded the stale action.")
                continue
            }

            if decision.operation == .done || decision.operation == .blocked {
                let status: SimulatorAgentRunResult.Status = decision.operation == .done ? .completed : .blocked
                let message = decision.operation == .done
                    ? "TypeSafe confirmed that every requested requirement is visible."
                    : "TypeSafe reported that no offered action could make further progress."
                try traceRecorder?.append(
                    SimulatorAgentTraceEvent(
                        modelCall: modelCalls,
                        observedFingerprint: screen.fingerprint,
                        request: prepared.payload,
                        response: response,
                        decision: decision,
                        discardedAsStale: false,
                        action: nil,
                        latencyMilliseconds: latency
                    )
                )
                return Self.result(
                    status: status,
                    message: message,
                    goal: goal,
                    model: response.model,
                    modelCalls: modelCalls,
                    usage: usage,
                    history: history,
                    screen: screen,
                    started: started
                )
            }

            let executed = try await executor.execute(
                decision,
                screen: screen,
                goal: goal,
                history: history,
                textModelClient: textModelClient
            )
            if let launchedApplication = executed.launchedApplication {
                currentApplication = launchedApplication
            }

            let afterScreen = try await observeAfterAction(
                beforeFingerprint: screen.fingerprint,
                currentApplication: currentApplication
            )
            let action = AgentHistoryEntry(
                step: history.count + 1,
                operation: decision.operation,
                target: executed.targetDescription,
                text: executed.text,
                beforeFingerprint: screen.fingerprint,
                afterFingerprint: afterScreen.fingerprint,
                pageChanged: afterScreen.fingerprint != screen.fingerprint
            )
            history.append(action)

            try traceRecorder?.append(
                SimulatorAgentTraceEvent(
                    modelCall: modelCalls,
                    observedFingerprint: screen.fingerprint,
                    request: prepared.payload,
                    response: response,
                    decision: decision,
                    discardedAsStale: false,
                    action: action,
                    latencyMilliseconds: latency
                )
            )
            progress(Self.progressDescription(action, probability: decision.operationProbability, latency: latency))
            screen = afterScreen

            if Self.isRepeatedNoProgress(history) {
                return Self.result(
                    status: .blocked,
                    message: "Stopped after three repeated actions made no observable change.",
                    goal: goal,
                    model: response.model,
                    modelCalls: modelCalls,
                    usage: usage,
                    history: history,
                    screen: screen,
                    started: started
                )
            }
        }

        let message: String
        if history.count >= maximumSteps {
            message = "Stopped after reaching the \(maximumSteps)-action limit."
        } else {
            message = "Stopped after repeated screen changes exhausted the model-call budget."
        }
        return Self.result(
            status: .blocked,
            message: message,
            goal: goal,
            model: model,
            modelCalls: modelCalls,
            usage: usage,
            history: history,
            screen: screen,
            started: started
        )
    }

    private func observeAfterAction(
        beforeFingerprint: String,
        currentApplication: AgentApplication?
    ) async throws -> AgentScreenSnapshot {
        let delays: [Duration] = [
            .milliseconds(40),
            .milliseconds(80),
            .milliseconds(140),
            .milliseconds(250),
            .milliseconds(400),
            .milliseconds(650),
        ]
        var latest: AgentScreenSnapshot?
        for delay in delays {
            try await Task.sleep(for: delay)
            let observed = try await observer.observe(currentApplication: currentApplication)
            latest = observed
            if observed.fingerprint != beforeFingerprint {
                return observed
            }
        }
        if let latest {
            return latest
        }
        return try await observer.observe(currentApplication: currentApplication)
    }

    private func progress(_ value: String) {
        guard emitProgress else { return }
        print(value, to: &standardError)
    }

    private static func progressDescription(
        _ action: AgentHistoryEntry,
        probability: Double,
        latency: Int
    ) -> String {
        var description = "\(action.step). \(action.operation.rawValue)"
        if let target = action.target {
            description += " → \(target)"
        }
        if let text = action.text {
            description += " = \(String(text.prefix(80)))"
        }
        description += String(format: " [p=%.3f, %d ms]", probability, latency)
        return description
    }

    private static func isRepeatedNoProgress(_ history: [AgentHistoryEntry]) -> Bool {
        let recent = history.suffix(3)
        guard recent.count == 3 else { return false }
        guard recent.allSatisfy({ $0.pageChanged == false }) else {
            return false
        }
        let signatures = Set(recent.map {
            "\($0.operation.rawValue)|\($0.target ?? "")|\($0.text ?? "")"
        })
        return signatures.count == 1
    }

    private static func inferCurrentApplication(
        from screen: AgentScreenSnapshot,
        applications: [AgentApplication]
    ) -> AgentApplication? {
        guard let name = screen.applicationName else { return nil }
        return applications.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
                || $0.bundleIdentifier.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func result(
        status: SimulatorAgentRunResult.Status,
        message: String,
        goal: String,
        model: String,
        modelCalls: Int,
        usage: TypeSafeUsageSummary,
        history: [AgentHistoryEntry],
        screen: AgentScreenSnapshot,
        started: Date
    ) -> SimulatorAgentRunResult {
        SimulatorAgentRunResult(
            status: status,
            goal: goal,
            model: model,
            steps: history.count,
            modelCalls: modelCalls,
            usage: usage,
            elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
            message: message,
            history: history,
            finalScreen: screen
        )
    }
}
