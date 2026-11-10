import Foundation
import Testing

@Suite("Playground Agent System Owner E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentSystemOwnerTests: Sendable {
    @Test("A real Photos permission alert keeps the completed tap and requires its own PID")
    func photosPermissionOwner() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let cli = try TestHelpers.getAxePath()
        let reset = ["xcrun", "simctl", "privacy", udid, "reset", "photos", "com.cameroncooke.AxePlayground"]
        _ = try await CommandRunner.run(reset.map(Self.quote).joined(separator: " "), timeout: 15)
        let session = try await PlaygroundAgentExamplesSession.open()
        let before = try session.document.read()
        try #require(before.photosStatus == 0)
        var requestAttempted = false
        var primaryDenyDelivery = DenyDelivery.notAttempted
        var primary: Error?
        do {
            requestAttempted = true
            let output = try await command(["tap", "--agent", "--expected-pid", String(session.pid),
                "--id", "agent-examples.photos"], session: session, name: "normal-request")
            let envelope = try session.decode(output.output)
            try #require(output.exitCode == 0 && !envelope.didError)
            let action = try #require(envelope.data.action)
            try #require(action.kind == "tap" && action.outcome == "enqueuedAndDrained" && action.enqueuedEventCount == 2
                && action.cleanup == "notNeeded" && !action.replayed)
            // Photos opens asynchronously. The completed tap can still return an app capture.
            if let capture = envelope.data.capture { try #require(capture.applicationPID == session.pid) }
            else { try #require(envelope.data.cache.requiresRefresh) }

            let ownerReply = try await waitForOwnerReceipt(session: session)
            let details = try AgentOwnerDiagnostic.decode(ownerReply.output)
            let observation = try #require(details.data.observation)
            let owner = try #require(observation.observedPID)
            try #require(observation.outcome == "processChanged" && observation.expectedPID == session.pid && owner != session.pid)
            try #require(!observation.attempts.isEmpty && observation.attempts.allSatisfy {
                $0.rootPID == owner && $0.outcome == "processChanged" && $0.endUptime >= $0.startUptime
            })
            try #require(details.nextSteps.contains { $0.contains("describe-ui --agent") && $0.contains("fresh snapshot") })
            let wrong = try await command(["describe-ui", "--agent", "--expected-pid", String(session.pid)],
                session: session, name: "wrong-pid")
            let wrongEnvelope = try session.decode(wrong.output)
            try #require(wrong.exitCode != 0 && wrongEnvelope.didError && wrongEnvelope.error?.code == "observationFailed"
                && wrongEnvelope.data.action == nil && wrongEnvelope.data.capture == nil)
            let wrongObservation = try #require(try AgentOwnerDiagnostic.decode(wrong.output).data.observation)
            try #require(wrongObservation.expectedPID == session.pid && wrongObservation.observedPID == owner
                && wrongObservation.outcome == "processChanged")
            let currentReply = try await waitForPrompt(session: session, owner: owner)
            let current = try #require(try session.decode(currentReply.output).data.capture)
            try #require(current.applicationPID == owner)
            let denyContext = CleanupContext(cli: cli, udid: session.app.udid, appPID: session.pid,
                documentURL: session.document.url, artifacts: session.artifacts)
            let denyDeadline = ProcessInfo.processInfo.systemUptime + 30
            primaryDenyDelivery = .inputPossible
            var denied = try await denyCommand(["tap", "--agent", "--expected-pid", String(owner),
                "--label-regex", "^Don.t Allow$", "--element-type", "Button"],
                context: denyContext, name: "deny", deadline: denyDeadline)
            if isZeroInputScreenChange(denied, appPID: session.pid, generation: before.generation) {
                primaryDenyDelivery = .provedNoInput
                // A proved zero-input refusal permits one new observation and a new request.
                let refreshedReply = try await command(["describe-ui", "--agent", "--expected-pid", String(owner)],
                    context: denyContext, name: "deny-refresh", deadline: denyDeadline)
                let refreshedEnvelope = try session.decode(refreshedReply.output)
                let refreshed = try #require(refreshedEnvelope.data.capture)
                try #require(refreshedReply.exitCode == 0 && !refreshedEnvelope.didError
                    && refreshed.applicationPID == owner
                    && refreshed.targets.contains { $0.contains("|tap|") && $0.hasSuffix("|kTCCServicePhotos-deny-button") })
                primaryDenyDelivery = .inputPossible
                denied = try await denyCommand(["tap", "--agent", "--expected-pid", String(owner),
                    "--id", "kTCCServicePhotos-deny-button", "--element-type", "Button"],
                    context: denyContext, name: "deny-after-refresh", deadline: denyDeadline)
            }
            if isZeroInputScreenChange(denied, appPID: session.pid, generation: before.generation) {
                primaryDenyDelivery = .provedNoInput
            }
            let deniedEnvelope = try session.decode(denied.output.output)
            let deniedAction = try #require(deniedEnvelope.data.action)
            try #require(denied.output.exitCode == 0 && !deniedEnvelope.didError
                && deniedAction.kind == "tap" && deniedAction.outcome == "enqueuedAndDrained"
                && deniedAction.enqueuedEventCount == 2 && deniedAction.cleanup == "notNeeded" && !deniedAction.replayed)
            primaryDenyDelivery = .completed
            _ = try await session.document.waitFor("normal denied Photos permission") { $0.photosStatus == 2 }
            // The app records the denial while the alert is still leaving; wait until it is frontmost again.
            _ = try await session.captureWhenFrontmost()
            try await session.tap("agent-examples.tap")
            _ = try await session.document.waitFor("real button after system permission closes") { $0.taps == before.taps + 1 }
        } catch { primary = error }
        let cleanupContext = CleanupContext(cli: cli, udid: session.app.udid, appPID: session.pid,
            documentURL: session.document.url, artifacts: session.artifacts)
        let cleanupRequestAttempted = requestAttempted
        let cleanupPrimaryDenyDelivery = primaryDenyDelivery
        var cleanup = await Task {
            await cleanupPrompt(context: cleanupContext, requestAttempted: cleanupRequestAttempted,
                primaryDenyDelivery: cleanupPrimaryDenyDelivery)
        }.value
        if cleanup.closed {
            let finalProcessErrors = await Task { await verifyProcesses(context: cleanupContext) }.value
            cleanup.errors.append(contentsOf: finalProcessErrors)
        } else {
            cleanup.errors.append("Owned-process verification was not accepted because the Photos prompt is not proved closed")
        }
        let record = Outcome(primaryError: primary.map { String(describing: $0) }, cleanup: cleanup,
            primaryPassed: primary == nil, accepted: primary == nil && cleanup.closed && cleanup.errors.isEmpty)
        do {
            try JSONEncoder().encode(record).write(to: session.artifacts.appendingPathComponent("photos-owner-outcome.json"), options: .atomic)
        } catch { cleanup.errors.append("Outcome record failed: " + String(describing: error)) }
        if let primary {
            if cleanup.closed && cleanup.errors.isEmpty { throw primary }
            throw TestError.unexpectedState("Primary failure: \(primary). Prompt cleanup: \(cleanup.errors.joined(separator: "; "))")
        }
        try #require(cleanup.closed && cleanup.errors.isEmpty, "Prompt cleanup failed: \(cleanup.errors.joined(separator: "; "))")
    }

    private func observedOwner(in output: String, expectedPID: Int32) -> Int32? {
        guard let value = try? decode(Envelope.self, output), let observation = value.data?.observation,
              observation.expectedPID == expectedPID, observation.outcome == "processChanged",
              let owner = observation.observedPID, owner > 0, owner != expectedPID,
              !observation.attempts.isEmpty, observation.attempts.allSatisfy({
                  $0.rootPID == owner && $0.outcome == "processChanged"
              }) else { return nil }
        return owner
    }

    private func waitForOwnerReceipt(session: PlaygroundAgentExamplesSession) async throws -> CommandOutput {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        repeat {
            try Task.checkCancellation()
            let reply = try await command(["describe-ui", "--agent", "--expected-pid", String(session.pid)],
                session: session, name: "wait-system-owner-" + UUID().uuidString, deadline: deadline)
            if observedOwner(in: reply.output, expectedPID: session.pid) != nil { return reply }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("The asynchronous Photos request did not expose a measured system owner")
    }

    private enum DenyDelivery: Sendable {
        case notAttempted, provedNoInput, inputPossible, completed
    }

    private struct DenyAttempt {
        let output: CommandOutput
        let before: PlaygroundAgentExamplesDocument
        let after: PlaygroundAgentExamplesDocument
    }

    /// A screen-change refusal before input: typed code, no events and clean release. When AXe could
    /// read the screen, the reply carries it as a new table; otherwise it asks for a refresh.
    private func isZeroInputScreenChange(_ attempt: DenyAttempt, appPID: Int32, generation: UUID) -> Bool {
        guard attempt.before.pid == appPID, attempt.before.generation == generation,
              attempt.before.photosStatus == 0, attempt.before == attempt.after,
              let envelope = try? decode(AgentPlaygroundResult.self, attempt.output.output),
              attempt.output.exitCode != 0, envelope.schema == "axe.output.agent-result", envelope.schemaVersion == "1",
              envelope.didError, ["screenChanged", "targetChanged"].contains(envelope.error?.code ?? ""),
              envelope.data.capture == nil
                ? envelope.data.cache.requiresRefresh
                : envelope.data.cache.status == "refreshed" && !envelope.data.cache.requiresRefresh,
              let action = envelope.data.action, action.kind == "tap", action.outcome == "failedBeforeInput",
              action.enqueuedEventCount == 0, action.cleanup == "notNeeded", !action.replayed else { return false }
        return true
    }

    private func denyCommand(_ arguments: [String], context: CleanupContext, name: String,
        deadline: Double) async throws -> DenyAttempt {
        let beforeBytes = try Data(contentsOf: context.documentURL)
        let before = try JSONDecoder().decode(PlaygroundAgentExamplesDocument.self, from: beforeBytes)
        try beforeBytes.write(to: context.artifacts.appendingPathComponent(name + "-before.json"), options: .withoutOverwriting)
        do {
            let output = try await command(arguments, context: context, name: name, deadline: deadline)
            let afterBytes = try Data(contentsOf: context.documentURL)
            try afterBytes.write(to: context.artifacts.appendingPathComponent(name + "-after.json"), options: .withoutOverwriting)
            let after = try JSONDecoder().decode(PlaygroundAgentExamplesDocument.self, from: afterBytes)
            return DenyAttempt(output: output, before: before, after: after)
        } catch {
            try? Data(contentsOf: context.documentURL).write(
                to: context.artifacts.appendingPathComponent(name + "-after-failure.json"), options: .withoutOverwriting)
            throw error
        }
    }

    private struct CleanupContext: Sendable {
        let cli: String
        let udid: String
        let appPID: Int32
        let documentURL: URL
        let artifacts: URL
    }
    private struct Cleanup: Encodable, Sendable {
        var closed = false
        var denyAttempted = false
        var errors: [String] = []
        let purpose = "Owned normal prompt dismissal only; not acceptance evidence"
    }
    private struct Outcome: Encodable {
        let primaryError: String?
        let cleanup: Cleanup
        let primaryPassed: Bool
        let accepted: Bool
    }

    /// Cleanup never changes the primary result and never repeats possible or uncertain input.
    /// One fresh normal Deny is allowed only when no Deny was attempted or zero input was proved.
    private func cleanupPrompt(context: CleanupContext, requestAttempted: Bool,
        primaryDenyDelivery: DenyDelivery) async -> Cleanup {
        var result = Cleanup()
        result.denyAttempted = primaryDenyDelivery != .notAttempted
        var maySendDeny = primaryDenyDelivery == .notAttempted || primaryDenyDelivery == .provedNoInput
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        do {
            repeat {
                let reply = try await command(["describe-ui", "--agent", "--expected-pid", String(context.appPID)],
                    context: context, name: "cleanup-observe-" + UUID().uuidString, deadline: deadline)
                if reply.exitCode == 0, let capture = try? decode(AgentPlaygroundResult.self, reply.output).data.capture,
                   capture.applicationPID == context.appPID,
                   try (!requestAttempted || JSONDecoder().decode(PlaygroundAgentExamplesDocument.self, from: Data(contentsOf: context.documentURL)).photosStatus != 0) {
                    result.closed = true
                    return result
                }
                if maySendDeny, ProcessInfo.processInfo.systemUptime < deadline,
                   let owner = observedOwner(in: reply.output, expectedPID: context.appPID) {
                    let promptReply = try await command(["describe-ui", "--agent", "--expected-pid", String(owner)],
                        context: context, name: "cleanup-prompt-" + UUID().uuidString, deadline: deadline)
                    if promptReply.exitCode == 0, let capture = try? decode(AgentPlaygroundResult.self, promptReply.output).data.capture,
                       capture.applicationPID == owner,
                       capture.targets.contains(where: { $0.contains("kTCCServicePhotos-deny-button") }) {
                        // An observation can overrun the soft cleanup deadline. Do not start late input.
                        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                        result.denyAttempted = true
                        maySendDeny = false
                        do {
                            let denied = try await command(["tap", "--agent", "--expected-pid", String(owner),
                                "--id", "kTCCServicePhotos-deny-button", "--element-type", "Button"],
                                context: context, name: "cleanup-deny", deadline: deadline)
                            let envelope = try decode(AgentPlaygroundResult.self, denied.output)
                            guard denied.exitCode == 0, !envelope.didError,
                                  let action = envelope.data.action, action.outcome == "enqueuedAndDrained",
                                  action.enqueuedEventCount == 2, action.cleanup == "notNeeded", !action.replayed else {
                                throw TestError.unexpectedState("The owned normal Deny cleanup did not return clean input; see cleanup-deny diagnostics")
                            }
                        } catch { result.errors.append("Normal Deny cleanup failed: " + String(describing: error)) }
                    }
                }
                // Do not let cancellation skip prompt cleanup. This pause is read-only and bounded.
                await Task.detached { try? await Task.sleep(nanoseconds: 50_000_000) }.value
            } while ProcessInfo.processInfo.systemUptime < deadline
            result.errors.append("The normal Photos prompt was not proved closed before the cleanup deadline")
        } catch { result.errors.append("Prompt cleanup observation failed: " + String(describing: error)) }
        return result
    }

    private func waitForPrompt(session: PlaygroundAgentExamplesSession, owner: Int32) async throws -> CommandOutput {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        repeat {
            try Task.checkCancellation()
            let reply = try await command(["describe-ui", "--agent"],
                session: session, name: "wait-prompt-" + UUID().uuidString, deadline: deadline)
            if reply.exitCode == 0, let capture = try? session.decode(reply.output).data.capture,
               capture.applicationPID > 0, capture.applicationPID == owner,
               capture.targets.contains(where: { $0.contains("kTCCServicePhotos-deny-button") }) { return reply }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("Normal Photos prompt did not become visible for its expected owner")
    }

    private func command(_ arguments: [String], session: PlaygroundAgentExamplesSession, name: String,
        deadline: Double? = nil) async throws -> CommandOutput {
        let context = CleanupContext(cli: try TestHelpers.getAxePath(), udid: session.app.udid,
            appPID: session.pid, documentURL: session.document.url, artifacts: session.artifacts)
        return try await command(arguments, context: context, name: name, deadline: deadline)
    }

    private struct DeferredCommandReceipt: Decodable {
        let schemaVersion: Int
        let cliPID: Int32
        let cliExitCode: Int32
        let directCLIReaped: Bool
        let groupCheckDeferred: Bool
        let owned: [MediaOwnedProcess]
        let forcedCleanup: [MediaForcedCleanup]
        let failures: [String]
    }

    /// Return at direct CLI exit. An idle reusable broker does not delay UI observations.
    private func command(_ arguments: [String], context: CleanupContext, name: String,
        deadline: Double? = nil) async throws -> CommandOutput {
        let observer = try #require(ProcessInfo.processInfo.environment["AXE_MEDIA_PROCESS_OBSERVER_PATH"])
        let remaining = (deadline ?? (ProcessInfo.processInfo.systemUptime + 30)) - ProcessInfo.processInfo.systemUptime
        try #require(remaining > 0, "No UI command starts after its observation deadline")
        let limit = min(30, remaining)
        let argv = [context.cli] + canonicalAgentArguments(arguments) + ["--udid", context.udid]
        try JSONEncoder().encode(argv).write(to: context.artifacts.appendingPathComponent(name + "-argv.json"), options: .withoutOverwriting)
        let receiptURL = context.artifacts.appendingPathComponent(name + "-ownership.json")
        let process = try PlaygroundTestProcess(executable: "/usr/bin/env", arguments: ["python3", observer,
            "--receipt", receiptURL.path, "--timeout", String(limit), "--defer-group-check", "--"] + argv,
            directory: context.artifacts, name: name)
        do {
            try process.start()
            // The extra five seconds permit test process cleanup after a failed direct-command deadline.
            try await process.wait(timeout: limit + 5)
            let receipt = try JSONDecoder().decode(DeferredCommandReceipt.self, from: Data(contentsOf: receiptURL))
            try #require(receipt.schemaVersion == 1 && receipt.directCLIReaped && receipt.groupCheckDeferred
                && receipt.forcedCleanup.isEmpty && receipt.failures.isEmpty
                && !receipt.owned.isEmpty && receipt.owned.contains { $0.pid == receipt.cliPID }
                && process.exitCode == receipt.cliExitCode)
            let result = CommandOutput(output: try process.diagnostics(), exitCode: receipt.cliExitCode)
            await process.finish()
            return result
        } catch { await process.finish(); throw error }
    }

    /// One read-only ownership check after the prompt is proved closed. It cannot signal product processes.
    private func verifyProcesses(context: CleanupContext) async -> [String] {
        do {
            let observer = try #require(ProcessInfo.processInfo.environment["AXE_MEDIA_PROCESS_OBSERVER_PATH"])
            let name = "final-processes"
            // The final capture retains its broker for the 60-second reference lifetime.
            // The documented public reference lifetime is 60 seconds. This suite also runs in the
            // matrix's standalone check package, which does not link the AXe module.
            let limit = 60.0 + 5
            let receipt = context.artifacts.appendingPathComponent(name + "-ownership.json")
            let process = try PlaygroundTestProcess(executable: "/usr/bin/env", arguments: ["python3", observer,
                "--receipt", receipt.path, "--timeout", String(limit), "--verify-deferred-directory", context.artifacts.path,
                "--", context.cli, "--udid", context.udid], directory: context.artifacts, name: name)
            do {
                try process.start()
                try await process.wait(timeout: limit + 5)
                let diagnostics = try process.diagnostics()
                try #require(process.exitCode == 0, "Final owned-process verification failed: \(diagnostics)")
                _ = try PlaygroundMediaProcess.requireClean(directory: context.artifacts, name: name)
                await process.finish()
                return []
            } catch { await process.finish(); throw error }
        } catch { return ["Final owned-process verification failed: " + String(describing: error)] }
    }

    private struct RawNode: Decodable {
        let identifier: String?
        let children: [RawNode]
        enum CodingKeys: String, CodingKey { case identifier = "AXUniqueId", children }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
            children = try values.decodeIfPresent([RawNode].self, forKey: .children) ?? []
        }
    }

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Observation: Decodable {
                struct Attempt: Decodable { let rootPID: Int32; let outcome: String }
                let expectedPID: Int32
                let observedPID: Int32?
                let outcome: String
                let attempts: [Attempt]
            }
            let observation: Observation?
            let context: DuoContext?
        }
        struct AX: Decodable {
            struct Validation: Decodable {
                let matchKind: String
                let expectedPID: Int32
                let hitPID: Int32
                let frontmostPID: Int32
                let confirmedHitPID: Int32?
            }
            let roots: [RawNode]?
            let validation: Validation?
        }
        let data: Payload?
        let ax: AX?
        let outcome: String?
        let enqueuedEventCount: Int?
        let cleanup: String?
    }
    private func decode<Value: Decodable>(_ type: Value.Type, _ output: String) throws -> Value {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(Value.self, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No Photos proof envelope")
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct AgentOwnerDiagnostic: Decodable {
    struct Payload: Decodable { let observation: Observation? }
    struct Observation: Decodable {
        struct Attempt: Decodable {
            let rootPID: Int32
            let outcome: String
            let startUptime: Double
            let endUptime: Double
        }
        let expectedPID: Int32
        let observedPID: Int32?
        let outcome: String
        let attempts: [Attempt]
    }
    let data: Payload
    let nextSteps: [String]
    static func decode(_ output: String) throws -> Self {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No owner observation envelope: \(output)")
    }
}
