import Foundation
import Testing

@Suite("Playground Duo Selected Home Batch", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoSelectedHomeBatchTests {
    @Test("Selected Home releases, rejects a later invalid step, and returns to the same app")
    func homeThenInvalidStep() async throws {
        let controls = try await prepareDuoControls(.inner90)
        let hardware = HardwareAcceptanceSession(controls: controls)
        let before = try controls.documents.read()
        try before.requireClear()
        let steps = [
            "button home --duration 0.2 --expected-boot \(controls.catalogue.bootIdentity)",
            // Lock is now supported. An unknown button preserves the parse rejection check.
            "button unknown",
            "tap --id feature.tap --element-type Button --tap-style physical --expected-pid \(controls.pid)",
        ]
        let output = try await hardware.command(batchArguments(steps) + controls.selection(), allowFailure: true)
        let lines = output.output.split(separator: "\n").filter { $0.hasPrefix("{") }
        try #require(lines.count == 2, "The failed batch must emit exactly two step receipts.")
        let rows = try lines.map { try JSONDecoder().decode(HomeBatchStep.self, from: Data($0.utf8)) }
        let completed = rows[0]
        try #require(completed.schemaVersion == 1 && completed.index == 1 && completed.totalSteps == 3)
        try #require(completed.command == "button" && completed.status == "completed" && completed.error == nil)
        let requestID = try #require(completed.requestID)
        let home = try #require(completed.response)
        try home.requireComplete(requestID: requestID, controls: controls)
        let rejected = rows[1]
        try #require(rejected.schemaVersion == 1 && rejected.index == 2 && rejected.totalSteps == 3)
        try #require(rejected.command == "button" && rejected.status == "rejectedBeforeSend")
        try #require(rejected.requestID == nil && rejected.response == nil && rejected.error != nil)
        try #require(output.output.contains("Selected batch step 2 failed before send. Earlier steps are not undone."))
        let after = try controls.documents.read()
        try after.requireClear()
        try #require(after.counts == before.counts && after.text == before.text)
        try #require(after.slider == before.slider && after.switchOn == before.switchOn)
        try #require(after.windowTouchTrace.count == before.windowTouchTrace.count,
            "The final physical Button step must not run after rejection.")
        try controls.preserveState("home-batch-before-return")

        // Read the real system process, then require selected AX to acquire its foreground tree.
        let launchctl = ["xcrun", "simctl", "spawn", controls.app.udid, "launchctl", "list"]
        let processes = try await CommandRunner.run(launchctl.map(playgroundShellQuote).joined(separator: " "), timeout: 30)
        let springboard = processes.output.split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[2] == "com.apple.SpringBoard" else { return nil }
            return Int32(fields[0])
        }
        try #require(springboard.count == 1)
        let systemPID = try #require(springboard.first)
        try #require(systemPID > 0 && systemPID != controls.pid)
        let current = try await DuoPlaygroundSession().catalogue(boot: controls.catalogue.bootIdentity)
        let panel = current.activePanel.identity
        // Home completes when its events are delivered; SpringBoard takes the foreground a moment
        // later. Until then selected AX refuses the read with processChanged, so read again.
        let describe = ["describe-ui", "--expected-pid", String(systemPID),
            "--input-mode", "selected", "--screen-id", String(panel.displayID), "--screen-uuid", panel.uniqueID.uuidString, "--verbose"]
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var tree: DuoCLIResponse
        while true {
            let foreground = try await hardware.command(describe, allowFailure: true, allowAnyExit: true)
            let firstLine = foreground.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
            tree = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(firstLine.utf8))
            if foreground.exitCode == 0 { break }
            try #require(tree.ax?.acquisition?.outcome == .processChanged && tree.enqueuedEventCount == 0
                && ProcessInfo.processInfo.systemUptime < deadline,
                "Selected AX did not acquire SpringBoard after Home: \(foreground.output)")
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try tree.requireSuccess("ready")
        try #require(tree.enqueuedEventCount == 0 && tree.cleanup == "notNeeded")
        let context = try #require(tree.context)
        try context.requireMatch(current)
        let ax = try #require(tree.ax)
        try #require(ax.schemaVersion == 1 && ax.kind == "describe" && ax.expectedPID == systemPID && ax.failure == nil)
        let acquisition = try #require(ax.acquisition)
        try #require(acquisition.outcome == .ready && !acquisition.attempts.isEmpty)
        try #require(acquisition.attempts.allSatisfy { $0.rootPID == systemPID })
        let roots = try #require(ax.roots)
        try #require(roots.contains { $0.type == "Application" })

        try await hardware.returnToSameApp()
        let resumed = try controls.documents.read()
        try #require(resumed.pid == controls.pid && resumed.generation == before.generation)
        try #require(resumed.counts == before.counts && resumed.text == before.text)
        try resumed.requireClear()
        try await controls.freshTap()
        let final = try controls.documents.read()
        try #require(final.count("tap") == before.count("tap") + 1)
        try controls.preserveState("home-batch-after-fresh-physical-tap")
    }
}

private struct HomeBatchStep: Decodable {
    let schemaVersion: Int
    let index: Int
    let totalSteps: Int
    let command: String?
    let requestID: UUID?
    let status: String
    let response: HomeBatchResponse?
    let error: String?
}

private struct HomeBatchResponse: Decodable {
    let requestID: UUID
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let token: UUID?
    let quarantine: DuoCLIResponse.Quarantine?
    let error: String?
    let context: DuoContext?
    let home: Execution?

    struct Execution: Decodable {
        let schemaVersion: Int
        let simulatorUDID: String
        let axDisplayID: UInt32
        let boundContext: DuoContext
        let phase: String
        let plannedPrimitiveCount: Int
        let sentPrimitiveCount: Int
        let allInputsReleasedBeforeCleanup: Bool
        let drainCompleted: Bool
        let interruption: HardwareAcceptanceReceipt.Execution.Interruption?
        let executionCleanup: String
        let startedUptime: Double
        let finishedUptime: Double
        let cleanupEvidence: Cleanup?
    }

    struct Cleanup: Decodable {
        let boundSimulatorUDID: String
        let boundBootIdentity: String
        let boundScreenID: UInt32
        let boundScreenUUID: UUID
        let outcome: String
        let contextValidation: String
        let releases: [Release]
        let timedOut: Bool
        let errorDescription: String?
        struct Release: Decodable { let kind: String }
    }

    func requireComplete(requestID expectedID: UUID, controls: PlaygroundControlsSession) throws {
        try #require(requestID == expectedID && outcome == "enqueuedAndDrained" && enqueuedEventCount == 2)
        try #require(cleanup == "notNeeded" && token == nil && quarantine == nil && error == nil)
        let context = try #require(context)
        try context.requireMatch(controls.catalogue)
        let execution = try #require(home)
        try #require(execution.schemaVersion == 1 && UUID(uuidString: execution.simulatorUDID) == UUID(uuidString: controls.app.udid))
        try #require(execution.axDisplayID == context.screenID && execution.boundContext == context)
        try #require(execution.phase == "completed" && execution.plannedPrimitiveCount == 2 && execution.sentPrimitiveCount == 2)
        try #require(execution.allInputsReleasedBeforeCleanup && execution.drainCompleted)
        try #require(execution.interruption == nil && execution.executionCleanup == "notNeeded")
        let finite = execution.startedUptime.isFinite && execution.finishedUptime.isFinite
        try #require(finite && execution.finishedUptime >= execution.startedUptime)
        let released = try #require(execution.cleanupEvidence)
        try #require(UUID(uuidString: released.boundSimulatorUDID) == UUID(uuidString: controls.app.udid))
        try #require(released.boundBootIdentity == context.bootIdentity && released.boundScreenID == context.screenID
            && released.boundScreenUUID == context.screenUUID)
        try #require(released.outcome == "notNeeded" && released.contextValidation == "noOwnedInput")
        try #require(released.releases.isEmpty && !released.timedOut && released.errorDescription == nil)
    }
}
