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
    let timing: SimulatorAgentRunTiming
    let message: String
    let history: [AgentHistoryEntry]
    let finalScreen: AgentScreenSnapshot
}

/// Where run time went. `loopMilliseconds` starts at the first Jev request, after setup.
struct SimulatorAgentRunTiming: Codable, Sendable {
    var setupMilliseconds = 0
    var loopMilliseconds = 0
    var jevMilliseconds = 0
    var observationMilliseconds = 0
    var observations = 0
    var actionMilliseconds = 0
}

private struct SimulatorAgentStepTiming: Codable {
    let jevMilliseconds: Int
    let freshnessReadMilliseconds: Int
    let actionMilliseconds: Int
    let observeMilliseconds: Int
    let observeReads: Int
    let stepMilliseconds: Int
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
    var freshness: AgentFreshness.Reason?
    var timing: SimulatorAgentStepTiming?
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
    private(set) var timing = SimulatorAgentRunTiming()
    private var loopStarted: ContinuousClock.Instant?

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
        let observer = AgentScreenObserver(simulatorUDID: simulatorUDID, logger: logger)
        self.observer = observer
        self.executor = SimulatorAgentExecutor(simulatorUDID: simulatorUDID, logger: logger, observer: observer)
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
        let clock = ContinuousClock()
        let started = clock.now
        defer { observer.close() }

        // Open the TypeSafe connection while the simulator is inspected.
        let client = typeSafeClient
        async let warmUp: Void = client.warmUp()
        let applications = try await SimulatorApplicationCatalog.applications(on: observer.target())
        var currentApplication: AgentApplication?
        var screen = try await observeActionable(
            currentApplication: currentApplication,
            seed: try await observeSettled(currentApplication: currentApplication).screen
        ).screen
        if let inferredApplication = Self.inferCurrentApplication(from: screen, applications: applications) {
            currentApplication = inferredApplication
            screen = AgentScreenSnapshot(
                applicationName: inferredApplication.name,
                bundleIdentifier: inferredApplication.bundleIdentifier,
                elements: screen.elements
            )
        }
        await warmUp
        timing = SimulatorAgentRunTiming()
        timing.setupMilliseconds = Self.milliseconds(since: started)
        loopStarted = clock.now

        var history: [AgentHistoryEntry] = []
        var modelCalls = 0
        var consecutiveStaleDecisions = 0
        var blockedOnceAlready = false
        let maximumModelCalls = max(maximumSteps * 3, maximumSteps + 5)

        while history.count < maximumSteps, modelCalls < maximumModelCalls {
            let prepared = try policy.prepareRequest(
                goal: goal,
                screen: screen,
                applications: applications,
                history: history,
                model: model,
                textHelperAvailable: textModelClient != nil
            )

            // Jev decides while the freshness read runs, instead of reading after the answer.
            let stepStarted = clock.now
            async let modelResult = Self.timedSystemOne(client, prepared.payload)
            let freshnessReadStarted = clock.now
            let freshScreen = try await read(currentApplication: currentApplication, handle: .reuse)
            let freshnessReadMilliseconds = Self.milliseconds(since: freshnessReadStarted)
            let (response, latency) = try await modelResult
            modelCalls += 1
            usage.record(response)
            timing.jevMilliseconds += latency
            let proposed = try policy.resolveDecision(
                response: response,
                prepared: prepared,
                minimumActionProbability: minimumActionProbability
            )

            let freshness = AgentFreshness.evaluate(proposed, observed: screen, fresh: freshScreen)
            var freshnessReason = freshness.reason
            var actingScreen = freshScreen
            var accepted = freshness.decision
            if let resolved = accepted?.element,
               let original = proposed.element,
               resolved.frame != original.frame {
                // A moved target may still be animating. Act only once its frame is stable across reads.
                let confirmation = try await read(currentApplication: currentApplication, handle: .reuse)
                if let confirmed = AgentFreshness.resolve(resolved, for: proposed.operation, in: confirmation.elements),
                   confirmed.frame == resolved.frame {
                    actingScreen = confirmation
                } else {
                    accepted = nil
                    freshnessReason = .stale
                }
            }

            guard let decision = accepted else {
                // The freshness read becomes the next observation. Only a screen that keeps changing
                // across decisions pays for a full settle.
                consecutiveStaleDecisions += 1
                var settled = consecutiveStaleDecisions >= 2
                    ? try await observeSettled(currentApplication: currentApplication, seed: actingScreen)
                    : (screen: actingScreen, milliseconds: 0, reads: 0)
                let actionableAfterStale = try await observeActionable(
                    currentApplication: currentApplication,
                    seed: settled.screen
                )
                settled = (actionableAfterStale.screen, settled.milliseconds, settled.reads + actionableAfterStale.reads)
                try traceRecorder?.append(
                    SimulatorAgentTraceEvent(
                        modelCall: modelCalls,
                        observedFingerprint: screen.fingerprint,
                        request: prepared.payload,
                        response: response,
                        decision: proposed,
                        discardedAsStale: true,
                        action: nil,
                        latencyMilliseconds: latency,
                        freshness: freshnessReason,
                        timing: SimulatorAgentStepTiming(
                            jevMilliseconds: latency,
                            freshnessReadMilliseconds: freshnessReadMilliseconds,
                            actionMilliseconds: 0,
                            observeMilliseconds: settled.milliseconds,
                            observeReads: settled.reads,
                            stepMilliseconds: Self.milliseconds(since: stepStarted)
                        )
                    )
                )
                progress("↻ Screen changed while Jev was deciding; discarded the stale action.")
                screen = settled.screen
                continue
            }
            consecutiveStaleDecisions = 0

            // BLOCKED ends the run, so confirm it on a settled screen first. A screen caught during an
            // app launch has no targets at all, which reads to Jev as "nothing can make progress".
            if decision.operation == .blocked, !blockedOnceAlready {
                blockedOnceAlready = true
                let resettled = try await observeSettled(currentApplication: currentApplication, seed: actingScreen)
                let actionableAfterBlock = try await observeActionable(
                    currentApplication: currentApplication,
                    seed: resettled.screen
                )
                let settled = (
                    screen: actionableAfterBlock.screen,
                    milliseconds: resettled.milliseconds,
                    reads: resettled.reads + actionableAfterBlock.reads
                )
                try traceRecorder?.append(
                    SimulatorAgentTraceEvent(
                        modelCall: modelCalls,
                        observedFingerprint: screen.fingerprint,
                        request: prepared.payload,
                        response: response,
                        decision: decision,
                        discardedAsStale: true,
                        action: nil,
                        latencyMilliseconds: latency,
                        freshness: freshnessReason,
                        timing: SimulatorAgentStepTiming(
                            jevMilliseconds: latency,
                            freshnessReadMilliseconds: freshnessReadMilliseconds,
                            actionMilliseconds: 0,
                            observeMilliseconds: settled.milliseconds,
                            observeReads: settled.reads,
                            stepMilliseconds: Self.milliseconds(since: stepStarted)
                        )
                    )
                )
                progress("↻ BLOCKED on a screen that was still changing; asking again once it settled.")
                screen = settled.screen
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
                        latencyMilliseconds: latency,
                        freshness: freshnessReason,
                        timing: SimulatorAgentStepTiming(
                            jevMilliseconds: latency,
                            freshnessReadMilliseconds: freshnessReadMilliseconds,
                            actionMilliseconds: 0,
                            observeMilliseconds: 0,
                            observeReads: 0,
                            stepMilliseconds: Self.milliseconds(since: stepStarted)
                        )
                    )
                )
                return result(
                    status: status,
                    message: message,
                    model: response.model,
                    modelCalls: modelCalls,
                    history: history,
                    screen: actingScreen,
                    started: started
                )
            }

            let actionStarted = clock.now
            let executed = try await executor.execute(
                decision,
                screen: actingScreen,
                goal: goal,
                history: history,
                textModelClient: textModelClient
            )
            let actionMilliseconds = Self.milliseconds(since: actionStarted)
            timing.actionMilliseconds += actionMilliseconds
            blockedOnceAlready = false
            if let launchedApplication = executed.launchedApplication {
                currentApplication = launchedApplication
            }

            // One observation after the action, like jev-ultrafast. The freshness read made while Jev
            // decides acts as the second read; a transition still in progress resolves or discards there.
            let settled: (screen: AgentScreenSnapshot, milliseconds: Int, reads: Int)
            if let launchedApplication = executed.launchedApplication {
                settled = try await observeLaunched(launchedApplication)
            } else {
                // Re-acquiring the frontmost handle costs 250-700 ms on large screens, so reuse it. A
                // handle for an app that lost focus serializes empty and refreshes automatically; an
                // apparently unchanged screen also refreshes, in case a system alert took focus.
                let observeStarted = clock.now
                // A read that starts immediately still serializes the pre-action screen, and one taken
                // during a UIKit transition (about 350 ms) shows both screens. Waiting here is cheaper
                // than a discarded decision.
                try await Task.sleep(for: .milliseconds(300))
                var observed = try await read(currentApplication: currentApplication, handle: .reuse)
                var reads = 1
                if observed.fingerprint == actingScreen.fingerprint {
                    observed = try await read(currentApplication: currentApplication, handle: .refresh)
                    reads += 1
                }
                // A tap that launches an app leaves SpringBoard's launch transition on screen, which has
                // no targets at all. Keep reading rather than asking Jev to choose from nothing.
                let actionable = try await observeActionable(
                    currentApplication: currentApplication,
                    seed: observed
                )
                settled = (actionable.screen, Self.milliseconds(since: observeStarted), reads + actionable.reads)
            }
            let afterScreen = settled.screen
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

            let stepMilliseconds = Self.milliseconds(since: stepStarted)
            try traceRecorder?.append(
                SimulatorAgentTraceEvent(
                    modelCall: modelCalls,
                    observedFingerprint: screen.fingerprint,
                    request: prepared.payload,
                    response: response,
                    decision: decision,
                    discardedAsStale: false,
                    action: action,
                    latencyMilliseconds: latency,
                    freshness: freshnessReason,
                    timing: SimulatorAgentStepTiming(
                        jevMilliseconds: latency,
                        freshnessReadMilliseconds: freshnessReadMilliseconds,
                        actionMilliseconds: actionMilliseconds,
                        observeMilliseconds: settled.milliseconds,
                        observeReads: settled.reads,
                        stepMilliseconds: stepMilliseconds
                    )
                )
            )
            progress(Self.progressDescription(
                action,
                probability: decision.operationProbability,
                latency: latency,
                stepMilliseconds: stepMilliseconds
            ))
            screen = afterScreen

            if Self.isRepeatedNoProgress(history) {
                return result(
                    status: .blocked,
                    message: "Stopped after three repeated actions made no observable change.",
                    model: response.model,
                    modelCalls: modelCalls,
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
        return result(
            status: .blocked,
            message: message,
            model: model,
            modelCalls: modelCalls,
            history: history,
            screen: screen,
            started: started
        )
    }

    private func read(
        currentApplication: AgentApplication?,
        handle: AgentScreenObserver.HandlePolicy
    ) async throws -> AgentScreenSnapshot {
        let started = ContinuousClock.now
        defer {
            timing.observationMilliseconds += Self.milliseconds(since: started)
            timing.observations += 1
        }
        return try await observer.observe(currentApplication: currentApplication, handle: handle)
    }

    /// Reads until two consecutive observations share a screen hash, like XcodeBuildMCP's rs/1
    /// post-action settle. Used at start-up and after repeated stale decisions. A read takes 130-250 ms,
    /// which spaces reads without extra sleeps. The first read refreshes the frontmost-application handle
    /// so alerts and app switches are seen. Returns the latest observation if the screen is still
    /// changing after 2.5 s.
    private func observeSettled(
        currentApplication: AgentApplication?,
        seed: AgentScreenSnapshot? = nil
    ) async throws -> (screen: AgentScreenSnapshot, milliseconds: Int, reads: Int) {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .milliseconds(2_500))
        var reads = 0
        var previous: AgentScreenSnapshot
        if let seed {
            previous = seed
        } else {
            previous = try await read(currentApplication: currentApplication, handle: .refresh)
            reads += 1
        }
        while clock.now < deadline {
            let current = try await read(currentApplication: currentApplication, handle: .reuse)
            reads += 1
            if current.fingerprint == previous.fingerprint {
                return (current, Self.milliseconds(since: started), reads)
            }
            previous = current
        }
        return (previous, Self.milliseconds(since: started), reads)
    }

    /// Waits for a screen that offers at least one tap or text-entry target, so a launch or dismissal
    /// transition is never sent to Jev as "nothing can be done here".
    private func observeActionable(
        currentApplication: AgentApplication?,
        seed: AgentScreenSnapshot
    ) async throws -> (screen: AgentScreenSnapshot, reads: Int) {
        guard RuntimeSnapshotCompactor.targets(in: seed.elements).isEmpty else {
            return (seed, 0)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(3_000))
        var latest = seed
        var reads = 0
        while clock.now < deadline {
            latest = try await read(currentApplication: currentApplication, handle: .refresh)
            reads += 1
            if !RuntimeSnapshotCompactor.targets(in: latest.elements).isEmpty {
                break
            }
        }
        return (latest, reads)
    }

    /// After OPEN_APP, waits for the launched application to become frontmost, so the launch
    /// animation's SpringBoard hierarchy is never sent to Jev.
    private func observeLaunched(
        _ application: AgentApplication
    ) async throws -> (screen: AgentScreenSnapshot, milliseconds: Int, reads: Int) {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .milliseconds(3_000))
        var reads = 0
        var latest: AgentScreenSnapshot
        repeat {
            latest = try await read(currentApplication: application, handle: .refresh)
            reads += 1
            let frontmost = latest.elements.first(where: { $0.role == .application })?.label
            if frontmost?.caseInsensitiveCompare(application.name) == .orderedSame {
                break
            }
        } while clock.now < deadline
        return (latest, Self.milliseconds(since: started), reads)
    }

    nonisolated private static func timedSystemOne(
        _ client: TypeSafeClient,
        _ payload: TypeSafeSystemOneRequest
    ) async throws -> (TypeSafeSystemOneResponse, Int) {
        let started = ContinuousClock.now
        let response = try await client.systemOne(payload)
        return (response, milliseconds(since: started))
    }

    nonisolated private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func progress(_ value: String) {
        guard emitProgress else { return }
        print(value, to: &standardError)
    }

    private static func progressDescription(
        _ action: AgentHistoryEntry,
        probability: Double,
        latency: Int,
        stepMilliseconds: Int
    ) -> String {
        var description = "\(action.step). \(action.operation.rawValue)"
        if let target = action.target {
            description += " → \(target)"
        }
        if let text = action.text {
            description += " = \(String(text.prefix(80)))"
        }
        description += String(format: " [p=%.3f, Jev %d ms, step %d ms]", probability, latency, stepMilliseconds)
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

    private func result(
        status: SimulatorAgentRunResult.Status,
        message: String,
        model: String,
        modelCalls: Int,
        history: [AgentHistoryEntry],
        screen: AgentScreenSnapshot,
        started: ContinuousClock.Instant
    ) -> SimulatorAgentRunResult {
        if let loopStarted {
            timing.loopMilliseconds = Self.milliseconds(since: loopStarted)
        }
        return SimulatorAgentRunResult(
            status: status,
            goal: goal,
            model: model,
            steps: history.count,
            modelCalls: modelCalls,
            usage: usage,
            elapsedMilliseconds: Self.milliseconds(since: started),
            timing: timing,
            message: message,
            history: history,
            finalScreen: screen
        )
    }
}
