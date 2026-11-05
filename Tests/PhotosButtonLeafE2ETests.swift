import Foundation
import Testing

@Suite("Photos Button leaf E2E", .serialized, .enabled(if: isE2EEnabled))
struct PhotosButtonLeafE2ETests: Sendable {
    @Test("Normal Photos denial works by fresh agent reference and selected ID", arguments: [false, true])
    func normalPermission(selectedID: Bool) async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let cli = try TestHelpers.getAxePath()
        let reset = ["xcrun", "simctl", "privacy", udid, "reset", "photos", "com.cameroncooke.AxePlayground"]
        let resetResult = try await CommandRunner.run(reset.map(Self.quote).joined(separator: " "), timeout: 15)
        try #require(resetResult.exitCode == 0)
        let session = try await PlaygroundAgentExamplesSession.open()
        let before = try session.document.read()
        try #require(before.photosStatus == 0 && before.activeWindowTouches == 0)
        var requestAttempted = false
        var primaryDenyAttempted = false
        var primary: Error?
        do {

            // The existing visible example has two separate Same buttons. They must remain ambiguous.
            let duplicate = try await command(["tap", "--agent", "--expected-pid", String(session.pid),
                "--label", "Same", "--element-type", "Button"], session: session, name: "duplicate-refusal")
            let refusal = try session.decode(duplicate.output)
            try #require(duplicate.exitCode != 0 && refusal.didError && refusal.error?.code == "targetAmbiguous"
                && refusal.data.action == nil)
            try #require(try session.document.read() == before)

            // This taps the normal visible button. The app uses the public asynchronous Photos request.
            requestAttempted = true
            let requested = try await command(["tap", "--agent", "--expected-pid", String(session.pid),
                "--id", "agent-examples.photos"], session: session, name: "normal-request")
            let request = try session.decode(requested.output)
            let requestAction = try #require(request.data.action)
            try #require(requested.exitCode == 0 && !request.didError && requestAction.enqueuedEventCount == 2
                && requestAction.outcome == "enqueuedAndDrained" && !requestAction.replayed)
            let owner = try await waitForOwner(session: session)

            // Each wait yields the executor; it sends no input and never changes the expected PID.
            let captureReply = try await waitForPrompt(session: session, owner: owner)
            let captured = try session.decode(captureReply.output)
            let capture = try #require(captured.data.capture)
            let context = try #require(try decode(Envelope.self, captureReply.output).data?.context)
            let rows = try capture.targets.map(AgentPlaygroundRow.init).filter { $0.identifier == "kTCCServicePhotos-deny-button" }
            let available = rows.filter { $0.action == "tap" }
            try #require(rows.count == 2 && available.count == 2 && Set(rows.map(\.ref)).count == 2)
            let initialBodies = Set(capture.targets.filter { $0.contains("|kTCCServicePhotos-deny-button") }.map {
                $0.split(separator: "|", omittingEmptySubsequences: false).dropFirst().joined(separator: "|")
            })
            try #require(initialBodies.count == 1)

            let flags = ["--input-mode", "selected", "--screen-id", String(context.screenID), "--screen-uuid", context.screenUUID.uuidString]
            let rawReply = try await command(["describe-ui", "--expected-pid", String(owner)] + flags,
                session: session, name: "raw-chain")
            let raw = try decode(Envelope.self, rawReply.output)
            let roots = try #require(raw.ax?.roots)
            func flatten(_ node: RawNode) -> [RawNode] { [node] + node.children.flatMap(flatten) }
            let deny = roots.flatMap(flatten).filter { $0.identifier == "kTCCServicePhotos-deny-button" }
            try #require(deny.count == 2 && deny.filter { $0.children.isEmpty }.count == 1)

            let arguments: [String]
            if selectedID {
                arguments = ["tap", "--id", "kTCCServicePhotos-deny-button", "--element-type", "Button", "--expected-pid", String(owner)] + flags
            } else {
                // The raw read can replace broker state. Get a new immutable reference immediately before input.
                let freshReply = try await waitForPrompt(session: session, owner: owner)
                let fresh = try #require(try session.decode(freshReply.output).data.capture)
                let matches = try fresh.targets.map { ($0, try AgentPlaygroundRow($0)) }.filter {
                    $0.1.identifier == "kTCCServicePhotos-deny-button"
                }
                try #require(matches.count == 2 && Set(matches.map { $0.1.ref }).count == 2)
                try #require(matches.allSatisfy { $0.1.action == "tap" })
                let rowBodies = Set(matches.map {
                    $0.0.split(separator: "|", omittingEmptySubsequences: false).dropFirst().joined(separator: "|")
                })
                try #require(rowBodies.count == 1)
                // Equal target priority preserves native preorder: the matching child follows its parent.
                let leaf = try #require(matches.last?.1)
                arguments = ["tap", "--agent", "--expected-pid", String(owner), "--snapshot-id", fresh.snapshotID.uuidString, "--ref", leaf.ref]
            }
            primaryDenyAttempted = true
            let denied = try await command(arguments, session: session, name: "deny")
            try #require(denied.exitCode == 0)
            if selectedID {
                let result = try decode(Envelope.self, denied.output)
                let validation = try #require(result.ax?.validation)
                try #require(result.outcome == "enqueuedAndDrained" && result.enqueuedEventCount == 2
                    && result.cleanup == "notNeeded" && validation.matchKind == "singleChildButtonLeaf"
                    && validation.expectedPID == owner && validation.hitPID == owner
                    && validation.frontmostPID == owner && validation.confirmedHitPID == owner)
            } else {
                let result = try session.decode(denied.output)
                let action = try #require(result.data.action)
                try #require(!result.didError && action.outcome == "enqueuedAndDrained"
                    && action.enqueuedEventCount == 2 && action.cleanup == "notNeeded" && !action.replayed)
            }
            _ = try await session.document.waitFor("normal Photos denial and released app input") {
                $0.photosStatus == 2 && $0.activeWindowTouches == 0
            }
            let freshApp = try await session.capture()
            try #require(freshApp.capture.applicationPID == session.pid)
            try await session.tap("agent-examples.tap")
            _ = try await session.document.waitFor("one button callback after Photos closes") {
                $0.taps == before.taps + 1 && $0.activeWindowTouches == 0
            }
        } catch { primary = error }
        let cleanupContext = CleanupContext(cli: cli, udid: session.app.udid,
            appPID: session.pid, documentURL: session.document.url, artifacts: session.artifacts)
        let cleanupRequestAttempted = requestAttempted
        let cleanupPrimaryDenyAttempted = primaryDenyAttempted
        var cleanup = await Task {
            await cleanupPrompt(context: cleanupContext, requestAttempted: cleanupRequestAttempted,
                primaryDenyAttempted: cleanupPrimaryDenyAttempted)
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
            try JSONEncoder().encode(record).write(to: session.artifacts.appendingPathComponent("photos-proof-v5-outcome.json"), options: .atomic)
        } catch { cleanup.errors.append("Outcome record failed: " + String(describing: error)) }
        if let primary {
            if cleanup.errors.isEmpty && cleanup.closed { throw primary }
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

    private func waitForOwner(session: PlaygroundAgentExamplesSession) async throws -> Int32 {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        repeat {
            try Task.checkCancellation()
            let reply = try await command(["describe-ui", "--agent", "--view", "full", "--expected-pid", String(session.pid)],
                session: session, name: "wait-system-owner-" + UUID().uuidString, deadline: deadline)
            if let owner = observedOwner(in: reply.output, expectedPID: session.pid) { return owner }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("The asynchronous Photos request did not expose a measured system owner")
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

    /// No second request, coordinate input, guessed PID or acceptance fallback.
    /// A primary or cleanup Deny attempt is never repeated; only read-only closure checks can follow.
    private func cleanupPrompt(context: CleanupContext, requestAttempted: Bool,
        primaryDenyAttempted: Bool) async -> Cleanup {
        var result = Cleanup()
        result.denyAttempted = primaryDenyAttempted
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        do {
            repeat {
                let reply = try await command(["describe-ui", "--agent", "--view", "full", "--expected-pid", String(context.appPID)],
                    context: context, name: "cleanup-observe-" + UUID().uuidString, deadline: deadline)
                if reply.exitCode == 0, let capture = try? decode(AgentPlaygroundResult.self, reply.output).data.capture,
                   capture.applicationPID == context.appPID,
                   try (!requestAttempted || JSONDecoder().decode(PlaygroundAgentExamplesDocument.self, from: Data(contentsOf: context.documentURL)).photosStatus != 0) {
                    result.closed = true
                    return result
                }
                if !result.denyAttempted, ProcessInfo.processInfo.systemUptime < deadline,
                   let owner = observedOwner(in: reply.output, expectedPID: context.appPID) {
                    let promptReply = try await command(["describe-ui", "--agent", "--view", "full", "--expected-pid", String(owner)],
                        context: context, name: "cleanup-prompt-" + UUID().uuidString, deadline: deadline)
                    if promptReply.exitCode == 0, let capture = try? decode(AgentPlaygroundResult.self, promptReply.output).data.capture,
                       capture.applicationPID == owner,
                       capture.targets.contains(where: { $0.contains("kTCCServicePhotos-deny-button") }) {
                        // An observation can overrun the soft cleanup deadline. Do not start late input.
                        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                        result.denyAttempted = true
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
            let reply = try await command(["describe-ui", "--agent", "--view", "full", "--expected-pid", String(owner)],
                session: session, name: "wait-prompt-" + UUID().uuidString, deadline: deadline)
            if reply.exitCode == 0, let capture = try? session.decode(reply.output).data.capture,
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
        let argv = [context.cli] + arguments + ["--udid", context.udid]
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
            try #require(receipt.schemaVersion == 1)
            try #require(receipt.directCLIReaped && receipt.groupCheckDeferred)
            try #require(receipt.forcedCleanup.isEmpty && receipt.failures.isEmpty)
            try #require(!receipt.owned.isEmpty)
            let ownsCLI = receipt.owned.contains { $0.pid == receipt.cliPID }
            try #require(ownsCLI)
            try #require(process.exitCode == receipt.cliExitCode)
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
            let receipt = context.artifacts.appendingPathComponent(name + "-ownership.json")
            let process = try PlaygroundTestProcess(executable: "/usr/bin/env", arguments: ["python3", observer,
                "--receipt", receipt.path, "--timeout", "75", "--verify-deferred-directory", context.artifacts.path,
                "--", context.cli, "--udid", context.udid], directory: context.artifacts, name: name)
            do {
                try process.start()
                // Agent snapshots retain the idle broker for 60 seconds. This waits for normal expiry.
                try await process.wait(timeout: 80)
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
