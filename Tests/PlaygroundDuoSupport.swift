import Darwin
import Foundation
import Testing

enum DuoPlaygroundPose: String, Hashable {
    case closed, tabletop, open

    var degrees: Double {
        switch self {
        case .closed: return 0
        case .tabletop: return 90
        case .open: return 180
        }
    }
}

/// A fixed Duo test target, scoped to one check and inherited only by its child tasks.
struct DuoPlaygroundLaunchTarget: Sendable {
    let bootIdentity: String
    let panel: DuoPanel

    @TaskLocal static var current: DuoPlaygroundLaunchTarget? = nil

    /// Called only after the requested app page is visible. No user input is replayed.
    static func prepareIfNeeded() async throws -> Bool {
        guard let target = current else { return false }
        let app = try DuoPlaygroundSession()
        var observed = try await app.catalogue(boot: target.bootIdentity)
        try #require(observed.activePanel.identity == target.panel.identity,
            "App launch changed the requested Duo display.")
        print("Duo catalogue after app launch: \(String(reflecting: observed))")
        let rotation = try target.panel.rotationDegrees()
        for _ in 0..<4 {
            if try observed.activePanel.rotationDegrees() == rotation { break }
            observed = try await app.rotateRight(catalogue: observed)
        }
        try #require(observed.activePanel == target.panel,
            "The requested Duo display and orientation were not restored after app launch.")
        print("Duo catalogue before fresh AX lookup: \(String(reflecting: observed))")
        return true
    }
}

/// Explicit test-only recovery. One Swift uptime deadline; this never retries an input or write.
struct DuoStateReadWait: Sendable {
    static let seconds: TimeInterval = 30
    @TaskLocal static var current: DuoStateReadWait? = nil
    @TaskLocal static var preparation: Preparation? = nil

    /// Configuration only. Each logical read wait starts its own deadline when the read begins.
    struct Preparation: Sendable {
        let phase: String
        let artifacts: URL?
        init(phase: String, artifacts: URL? = nil) { self.phase = phase; self.artifacts = artifacts }
    }

    static func preparationWindow(_ operation: String) throws -> DuoStateReadWait? {
        guard current == nil, let preparation else { return nil }
        return try DuoStateReadWait(phase: preparation.phase + "-" + operation, artifacts: preparation.artifacts)
    }
    let phase: String
    let startedUptime: TimeInterval
    let deadlineUptime: TimeInterval
    let artifacts: URL

    init(phase: String, artifacts: URL? = nil, started: TimeInterval = ProcessInfo.processInfo.systemUptime,
         deadline: TimeInterval? = nil) throws {
        self.phase = phase
        startedUptime = started
        deadlineUptime = deadline ?? started + Self.seconds
        guard started.isFinite, deadlineUptime.isFinite, deadlineUptime == started + Self.seconds else {
            throw TestError.unexpectedState("State recovery requires one explicit30second Swift deadline.")
        }
        if let artifacts { self.artifacts = artifacts }
        else {
            guard let root = ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"], root.hasPrefix("/") else {
                throw TestError.unexpectedState("State recovery requires an explicit artifact directory.")
            }
            self.artifacts = URL(fileURLWithPath: root)
        }
    }

    func remaining(minimum: TimeInterval) throws -> TimeInterval {
        try Task.checkCancellation()
        let value = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard value >= minimum else {
            throw TestError.unexpectedState("State recovery \(phase) has insufficient time for another read; no input is replayed.")
        }
        return value
    }

    func pause() async throws {
        let value = try remaining(minimum: 0.2)
        try await Task.sleep(nanoseconds: UInt64(min(0.2, value) * 1_000_000_000))
    }

    func record(command: String, started: TimeInterval, result: CommandOutput? = nil, error: String? = nil) throws {
        var value = ["phase": phase, "command": command, "waitStartedUptime": String(startedUptime),
            "deadlineUptime": String(deadlineUptime), "requestStartedUptime": String(started),
            "requestFinishedUptime": String(ProcessInfo.processInfo.systemUptime)]
        if let result { value["exitCode"] = String(result.exitCode); value["response"] = result.output }
        if let error { value["commandError"] = error }
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let url = artifacts.appendingPathComponent("duo-state-read-" + phase + "-" + UUID().uuidString + ".json")
        try JSONEncoder().encode(value).write(to: url, options: .withoutOverwriting)
    }
}

struct DuoPlaygroundSession {
    private let udid: String
    private let axePath: String
    private let bundleID = "com.cameroncooke.AxePlayground"
    private let buttonID = "slider-value-button"
    private let stateID = "slider-value-state"

    init() throws {
        udid = try TestHelpers.requireSimulatorUDID()
        axePath = try TestHelpers.getAxePath()
    }

    func launch(screen: String = "slider-value-test") async throws -> Int32 {
        let command = [
            "xcrun", "simctl", "launch", "--terminate-running-process", udid, bundleID,
            "--launch-arg", "screen=\(screen)",
        ]
        let output = try await CommandRunner.run(command.map(Self.quote).joined(separator: " "), timeout: 30).output
        let prefix = bundleID + ": "
        let pids = output.split(separator: "\n").compactMap { line -> Int32? in
            guard line.hasPrefix(prefix) else { return nil }
            return Int32(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        }
        guard pids.count == 1, let pid = pids.first, pid > 0 else {
            throw TestError.unexpectedState("No unique Playground PID in simctl launch output.\n\(output)")
        }
        return pid
    }

    func catalogue(boot: String? = nil, timeout: TimeInterval = 35) async throws -> DuoCatalogue {
        if let wait = try DuoStateReadWait.preparationWindow("catalogue") {
            return try await DuoStateReadWait.$current.withValue(wait) {
                try await catalogue(boot: boot, timeout: timeout)
            }
        }
        guard let wait = DuoStateReadWait.current else { return try await catalogueOnce(boot: boot, timeout: timeout) }
        while true {
            do { return try await catalogueOnce(boot: boot, timeout: min(timeout, wait.remaining(minimum: 5.5))) }
            catch CatalogueReadFailure.serviceUnavailable { try await wait.pause() }
            catch CatalogueReadFailure.changedDuringRead { try await wait.pause() }
        }
    }

    private func catalogueOnce(boot: String?, timeout: TimeInterval) async throws -> DuoCatalogue {
        let value = try await catalogueDescription(boot: boot, timeout: timeout)
        guard value.requestedSimulatorUDID == UUID(uuidString: udid), !value.bootIdentity.isEmpty,
              value.panels.count == 2, Set(value.panels.map(\.identity)).count == 2,
              value.activePanel.active == true,
              value.panels.filter({ $0.active == true }).map(\.identity) == [value.activePanel.identity],
              boot == nil || value.bootIdentity == boot else {
            throw TestError.unexpectedState("The measured Duo catalogue has the wrong device, boot or active panel.")
        }
        _ = try value.activePanel.rotationDegrees()
        return value
    }

    func setPose(_ pose: DuoPlaygroundPose, boot: String) async throws -> DuoCatalogue {
        let before = try await readHinge(boot: boot)
        try before.requireSuccess("observedHinge")
        guard let beforeReadback = before.hinge?.readback, beforeReadback.bootIdentity == boot else {
            throw TestError.unexpectedState("Hinge read returned a different boot.")
        }
        if abs(beforeReadback.sample.mechanicalDegrees - pose.degrees) > 0.1 {
            let response: DuoCLIResponse = try await decode([
                "hinge", "set", pose.rawValue, "--expected-boot", boot, "--tolerance", "0.1",
            ])
            try response.requireSuccess("observedMechanicalTarget")
            guard let receipt = response.hinge?.receipt, receipt.expectedBootIdentity == boot,
                  receipt.requestedDegrees == pose.degrees, receipt.matchingSamples.count == 2,
                  receipt.matchingSamples.allSatisfy({ abs($0.mechanicalDegrees - pose.degrees) <= 0.1 }) else {
                throw TestError.unexpectedState("Hinge \(pose.rawValue) lacks two matching measured samples.")
            }
        }
        let readback = try await readHinge(boot: boot)
        try readback.requireSuccess("observedHinge")
        guard let measured = readback.hinge?.readback, measured.bootIdentity == boot,
              abs(measured.sample.mechanicalDegrees - pose.degrees) <= 0.1 else {
            throw TestError.unexpectedState("A fresh hinge read did not retain \(pose.rawValue).")
        }
        // This test fixture uses the verified Duo outer1/inner3 display contract.
        let expectedScreenID: UInt32 = pose == .closed ? 1 : 3
        return try await stableCatalogue(boot: boot, expectedScreenID: expectedScreenID)
    }

    /// Confirm an external write only after the original input has stopped and released.
    /// A held writer can wait for convergence within its existing absolute Swift deadline.
    func requireExternalFold(_ write: DuoExternalLayoutWrite, boot: String, degrees: Double,
                             after writerFinished: TimeInterval, artifacts: URL,
                             deadline: TimeInterval? = nil,
                             artifactPrefix: String = "external-fold-confirmation") async throws {
        guard write.source == "hinge-slider-control", write.outcome == "writeEnqueued", write.expectedBootIdentity == boot,
              UUID(uuidString: write.simulatorUDID) == UUID(uuidString: udid),
              write.requestedDegrees == degrees, write.vendorEventCount == 1,
              write.hostSendDrained, !write.guestWriteAcknowledged, !write.mechanicalTargetObserved,
              [0.0, 180.0].contains(degrees), writerFinished.isFinite, writerFinished > 0,
              writerFinished <= ProcessInfo.processInfo.systemUptime else {
            throw TestError.unexpectedState("External fold lacks one truthful host-drained write.")
        }
        var previousTimestamp = writerFinished
        var matching = 0
        var attempt = 0
        while matching < 2 {
            try Task.checkCancellation()
            let remaining = deadline.map { $0 - ProcessInfo.processInfo.systemUptime } ?? 35
            guard remaining > 0 else {
                throw TestError.unexpectedState("Held fold did not reach two fresh target samples before its advertised deadline.")
            }
            attempt += 1
            let response = try await readHinge(boot: boot, timeout: remaining,
                artifactURL: artifacts.appendingPathComponent("\(artifactPrefix)-\(attempt).json"))
            try response.requireSuccess("observedHinge")
            guard response.enqueuedEventCount == 0, response.cleanup == "notNeeded",
                  let readback = response.hinge?.readback, readback.bootIdentity == boot,
                  readback.sample.mechanicalDegrees.isFinite,
                  let timestamp = readback.sample.timestampUptime, timestamp.isFinite,
                  let received = readback.sample.receivedUptime, received.isFinite,
                  timestamp > previousTimestamp, received >= timestamp,
                  received <= ProcessInfo.processInfo.systemUptime,
                  deadline.map { ProcessInfo.processInfo.systemUptime < $0 } ?? true else {
                throw TestError.unexpectedState("External fold lacks distinct fresh native samples after input release.")
            }
            previousTimestamp = timestamp
            if abs(readback.sample.mechanicalDegrees - degrees) <= 0.5 {
                matching += 1
            } else {
                guard deadline != nil else {
                    throw TestError.unexpectedState("External fold lacks two native target samples after writer exit.")
                }
                matching = 0
            }
            if matching < 2, let deadline {
                let pause = min(0.1, deadline - ProcessInfo.processInfo.systemUptime)
                if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
            }
        }
    }

    /// A public selected read, without agent capture or input, preserves the old reference table.
    func nativeContext(catalogue: DuoCatalogue, pid: Int32, artifacts: URL, name: String) async throws -> DuoContext {
        if let wait = try DuoStateReadWait.preparationWindow("native-context") {
            return try await DuoStateReadWait.$current.withValue(wait) {
                try await nativeContext(catalogue: catalogue, pid: pid, artifacts: artifacts, name: name)
            }
        }
        let wait = try #require(DuoStateReadWait.current)
        let arguments = ["describe-ui", "--expected-pid", String(pid)] + selection(catalogue)
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        var attempt = 0
        while true {
            attempt += 1
            let started = ProcessInfo.processInfo.systemUptime
            let result: CommandOutput
            do {
                let value = try await CommandRunner.run(command, allowFailure: true, timeout: wait.remaining(minimum: 8))
                result = CommandOutput(output: value.output, exitCode: value.exitCode)
            } catch { try wait.record(command: command, started: started, error: String(describing: error)); throw error }
            try wait.record(command: command, started: started, result: result)
            try Data(result.output.utf8).write(to: artifacts.appendingPathComponent(name + "-attempt-" + String(attempt) + ".json"), options: .withoutOverwriting)
            _ = try wait.remaining(minimum: 0)
            let line = result.output.split(separator: "\n").first ?? ""
            let response = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(line.utf8))
            guard response.enqueuedEventCount == 0, response.cleanup == "notNeeded", response.quarantine == nil,
                  let ax = response.ax, ax.schemaVersion == 1, ax.kind == "describe", ax.expectedPID == pid else {
                throw TestError.unexpectedState("Selected rotation read has wrong ownership, input or uncertain cleanup evidence.")
            }
            if let context = response.context { try context.requireMatch(catalogue) }
            if result.exitCode == 0 {
                guard response.outcome == "ready", response.error == nil, ax.failure == nil,
                      ax.acquisition?.outcome == .ready, let context = response.context else {
                    throw TestError.unexpectedState("Successful selected rotation read lacks a ready native context.")
                }
                try context.requireMatch(catalogue)
                return context
            }
            let error = response.error ?? ""
            let knownHingeUnavailable = ax.failure == .setupFailed && ax.acquisition == nil
                && response.context == nil && (error.contains("Context hinge sample timed out")
                    || error.contains("Fresh motion subscription timed out"))
            let knownCatalogueUnavailable = ax.failure == .setupFailed && ax.acquisition == nil
                && response.context == nil && ProcessInfo.processInfo.systemUptime - started >= 4.5
                && error.contains("ActivePanelReadError(childFailure: Optional(FBSimulatorControl.ActivePanelChildFailure.nonzeroExit), validationFailure: nil")
                && error.contains("terminationStatus: Optional(2)") && error.contains("exitConfirmed: true")
                && error.contains("sentTerminate: false") && error.contains("sentKill: false")
                && error.contains("\"--timeout\", \"5\"")
            // The prior native context and actual app PID still matched; retry only this read.
            let acquisitionError = ax.acquisition?.failureDescription ?? ""
            let matchedCatalogueUnavailable = response.context != nil && ax.failure == .acquisitionFailed
                && ax.acquisition?.outcome == .failed && ax.acquisition?.attempts.count == 1
                && ax.acquisition?.attempts.allSatisfy({ $0.outcome == .failed && $0.rootPID == pid }) == true
                && acquisitionError.contains("ActivePanelReadError(childFailure: Optional(FBSimulatorControl.ActivePanelChildFailure.nonzeroExit), validationFailure: nil")
                && acquisitionError.contains("/usr/bin/devicectl\"")
                && acquisitionError.contains("terminationStatus: Optional(1)")
                && acquisitionError.contains("terminationReason: Optional(\"exit\")")
                && acquisitionError.contains("launchAttempted: true") && acquisitionError.contains("launchReturned: true")
                && acquisitionError.contains("exitConfirmed: true") && acquisitionError.contains("sentTerminate: false")
                && acquisitionError.contains("sentKill: false")
                && acquisitionError.contains("[\"device\", \"info\", \"displays\", \"--device\", \"\(udid)\", \"--timeout\", \"5\", \"--json-output\",")
            let notReady = ax.failure == .acquisitionFailed && ax.acquisition?.outcome == .notReady
                && ax.acquisition?.failureDescription == nil && ax.acquisition?.attempts.isEmpty == false
                && ax.acquisition?.attempts.allSatisfy({ $0.outcome == .notReady && $0.rootPID == pid }) == true
            guard result.exitCode == 1, response.outcome == "failedBeforeInput", !error.isEmpty,
                  knownHingeUnavailable || knownCatalogueUnavailable || matchedCatalogueUnavailable || notReady else {
                throw TestError.unexpectedState("Selected rotation read failure is terminal; it is not replayed.")
            }
            try await wait.pause()
        }
    }

    func requireExternalRotation(_ write: DuoExternalLayoutWrite, plan: DuoRotationPlan, pid: Int32,
                                 after writerTime: TimeInterval, artifacts: URL,
                                 artifactPrefix: String) async throws -> DuoRotationConfirmation {
        guard write.source == "orientation-picker-control", write.outcome == "writeEnqueued",
              write.expectedBootIdentity == plan.before.bootIdentity,
              UUID(uuidString: write.simulatorUDID) == UUID(uuidString: udid),
              write.requestedDegrees == Double(plan.target), write.vendorEventCount == 1,
              write.hostSendDrained, !write.guestWriteAcknowledged, !write.mechanicalTargetObserved,
              writerTime.isFinite, writerTime > 0, writerTime < ProcessInfo.processInfo.systemUptime else {
            throw TestError.unexpectedState("External rotation lacks one truthful host-drained orientation write.")
        }
        let catalogue = try await stableCatalogue(boot: plan.before.bootIdentity,
            expectedScreenID: plan.before.screenID, expectedRotation: plan.target)
        let first = try await nativeContext(catalogue: catalogue, pid: pid, artifacts: artifacts, name: artifactPrefix + "-1")
        let second = try await nativeContext(catalogue: catalogue, pid: pid, artifacts: artifacts, name: artifactPrefix + "-2")
        guard first == second, second.bootIdentity == plan.before.bootIdentity,
              second.screenID == plan.before.screenID, second.screenUUID == plan.before.screenUUID,
              second.poseRevision == plan.before.poseRevision, second.rotationDegrees == plan.target,
              second.rotationDegrees != plan.before.rotationDegrees else {
            throw TestError.unexpectedState("Two fresh native reads did not retain the intended rotation and original hinge context.")
        }
        return DuoRotationConfirmation(before: plan.before, after: second, catalogue: catalogue, matchingObservationCount: 2)
    }

    func rotateRight(catalogue before: DuoCatalogue) async throws -> DuoCatalogue {
        let pair = before.activePanel.identity
        let arguments = ["rotate", "right", "--screen-id", String(pair.displayID), "--screen-uuid", pair.uniqueID.uuidString,
            "--expected-boot", before.bootIdentity]
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await CommandRunner.run(command, allowFailure: true, timeout: 35)
        let finished = ProcessInfo.processInfo.systemUptime
        if let preparation = DuoStateReadWait.preparation {
            let directory = try preparation.artifacts ?? DuoStateReadWait(phase: preparation.phase).artifacts
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = ["command": command, "requestStartedUptime": String(started),
                "requestFinishedUptime": String(finished), "exitCode": String(result.exitCode), "response": result.output]
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(
                "duo-preparation-rotation-write-" + UUID().uuidString + ".json"), options: .withoutOverwriting)
        }
        let line = result.output.split(separator: "\n").first ?? ""
        let response = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(line.utf8))
        if result.exitCode != 0 {
            guard let wait = try DuoStateReadWait.preparationWindow("rotation-after-uncertain-write"),
                  result.exitCode == 1, response.outcome == "failedNoReplay", response.enqueuedEventCount == 0,
                  response.cleanup == "notNeeded", response.quarantine == nil,
                  let error = response.error, error.contains("Context hinge sample timed out"),
                  response.rotation?.direction == "right", let failure = response.rotation?.failure,
                  failure.delivery == "uncertain", failure.detail == error, let measured = failure.before,
                  measured.bootIdentity == before.bootIdentity, measured.screenID == pair.displayID,
                  measured.screenUniqueID == pair.uniqueID, measured.rotation == (try before.activePanel.rotationDegrees()),
                  let context = response.context, context.poseRevision == measured.poseRevision else {
                throw TestError.commandError("Preparation rotation failed; it is not replayed.\n\(result.output)")
            }
            try context.requireMatch(before)
            let poseFields = measured.poseRevision.split(separator: ";")
            guard poseFields.count == 2, poseFields[0].hasPrefix("mechanicalDegrees="),
                  poseFields[1] == "range=0.0...180.0",
                  let degrees = Double(poseFields[0].dropFirst("mechanicalDegrees=".count)),
                  degrees.isFinite, (0...180).contains(degrees) else {
                throw TestError.unexpectedState("Uncertain preparation rotation has an unverified hinge context.")
            }
            let positions = pair.displayID == 1 ? [0, 90, 270] : [0, 90, 180, 270]
            guard [UInt32(1), 3].contains(pair.displayID), let index = positions.firstIndex(of: measured.rotation) else {
                throw TestError.unexpectedState("Uncertain preparation rotation has an unverified screen mapping.")
            }
            let target = positions[(index + 1) % positions.count]
            return try await DuoStateReadWait.$current.withValue(wait) {
                var previousTimestamp = finished
                for _ in 0..<2 {
                    let observed = try await readHinge(boot: before.bootIdentity)
                    guard let sample = observed.hinge?.readback?.sample,
                          abs(sample.mechanicalDegrees - degrees) <= 0.1,
                          let timestamp = sample.timestampUptime, timestamp > previousTimestamp else {
                        throw TestError.unexpectedState("Fresh hinge reads did not retain the preparation pose after the one rotation write.")
                    }
                    previousTimestamp = timestamp
                }
                let after = try await stableCatalogue(boot: before.bootIdentity,
                    expectedScreenID: pair.displayID, expectedRotation: target)
                guard after.activePanel.identity == pair, Set(after.panels.map(\.identity)) == Set(before.panels.map(\.identity)) else {
                    throw TestError.unexpectedState("The physical display pair changed after the one preparation rotation write.")
                }
                return after
            }
        }
        try response.requireSuccess("observedRotation")
        guard let receipt = response.rotation?.receipt, receipt.direction == "right",
              receipt.vendorEventCount == 1, receipt.matchingObservationCount == 2,
              receipt.before.rotation == (try before.activePanel.rotationDegrees()),
              receipt.after.rotation != receipt.before.rotation else {
            throw TestError.unexpectedState("Rotation lacks one request and two matching changed positions.")
        }
        let after = try await stableCatalogue(boot: before.bootIdentity)
        guard after.activePanel.identity == pair,
              try after.activePanel.rotationDegrees() == receipt.after.rotation else {
            throw TestError.unexpectedState("Fresh discovery does not match the completed rotation.")
        }
        guard let context = response.context else {
            throw TestError.unexpectedState("Completed rotation has no measured context.")
        }
        try context.requireMatch(after)
        return after
    }

    func waitForButtonState(
        _ expected: String, catalogue: DuoCatalogue, pid: Int32
    ) async throws -> DuoSnapshot {
        let diagnosticID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 10
        var attempt = 0
        var lastValue = "missing"
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            attempt += 1
            let trace = ButtonReadTrace(identifier: diagnosticID, attempt: attempt, expected: expected,
                waitStarted: started, requestStarted: ProcessInfo.processInfo.systemUptime,
                deadline: deadline, timeout: remaining)
            let response = try await buttonDescription(catalogue: catalogue, pid: pid, timeout: remaining, trace: trace)
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard let context = response.context, let ax = response.ax else {
                throw TestError.unexpectedState("Selected description has no matching app or measured context.")
            }
            if let acquisition = ax.acquisition, acquisition.outcome == .notReady {
                lastValue = "notReady for PID \(pid), attempts=\(acquisition.attempts.count)"
            } else {
                guard let roots = ax.roots else {
                    throw TestError.unexpectedState("Ready selected description has no roots.")
                }
                let snapshot = DuoSnapshot(context: context, roots: roots)
                lastValue = UIStateParser.findElement(in: roots, withIdentifier: stateID)?.value ?? "missing"
                if lastValue == expected, let button = UIStateParser.findElement(in: roots, withIdentifier: buttonID),
                   button.type == "Button", button.enabled == true, let frame = button.frame,
                   [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
                   frame.x >= 0, frame.y >= 0, frame.width > 0, frame.height > 0,
                   frame.x + frame.width <= context.logicalWidth, frame.y + frame.height <= context.logicalHeight {
                    return snapshot
                }
            }
            let pause = min(0.2, deadline - ProcessInfo.processInfo.systemUptime)
            if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        }
        throw TestError.unexpectedState("Playground button did not become ready within 10 seconds with state \(expected); last state: \(lastValue).")
    }

    private func buttonDescription(catalogue: DuoCatalogue, pid: Int32, timeout: TimeInterval,
                                   trace: ButtonReadTrace) async throws -> DuoCLIResponse {
        let arguments = ["describe-ui", "--expected-pid", String(pid)] + selection(catalogue)
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        let result: (output: String, exitCode: Int32)
        do {
            result = try await CommandRunner.run(command, allowFailure: true, timeout: timeout)
        } catch {
            recordButtonRead(trace, catalogue: catalogue, pid: pid, command: command, error: String(describing: error))
            throw error
        }
        recordButtonRead(trace, catalogue: catalogue, pid: pid, command: command,
            result: CommandOutput(output: result.output, exitCode: result.exitCode))
        // printResponse writes one compact JSON line before any failure diagnostic on stderr.
        // CommandRunner appends stderr after stdout; no error-text search is used here.
        let receiptLine = result.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let response: DuoCLIResponse
        do {
            response = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(receiptLine.utf8))
        } catch {
            throw TestError.invalidJSON("Selected description exit=\(result.exitCode): \(error)\n\(result.output.prefix(4096))")
        }
        guard let context = response.context, let ax = response.ax,
              ax.schemaVersion == 1, ax.kind == "describe", ax.expectedPID == pid else {
            throw TestError.unexpectedState("Selected description has the wrong kind, app or measured context.")
        }
        try context.requireMatch(catalogue)
        guard response.enqueuedEventCount == 0, response.cleanup == "notNeeded", response.quarantine == nil else {
            throw TestError.unexpectedState("Selected description has input or uncertain cleanup evidence.")
        }
        if result.exitCode == 0 {
            try response.requireSuccess("ready")
            guard ax.failure == nil, ax.acquisition?.outcome == .ready else {
                throw TestError.unexpectedState("Successful selected description lacks a ready acquisition.")
            }
            return response
        }
        guard result.exitCode == 1, response.outcome == "failedBeforeInput", response.error != nil,
              ax.failure == .acquisitionFailed, let acquisition = ax.acquisition,
              acquisition.outcome == .notReady, acquisition.failureDescription == nil,
              !acquisition.attempts.isEmpty,
              acquisition.attempts.allSatisfy({ $0.outcome == .notReady && $0.rootPID == pid }) else {
            throw TestError.commandError("Selected description exit=\(result.exitCode) is terminal.\n\(result.output.prefix(4096))")
        }
        return response
    }

    private struct ButtonReadTrace {
        let identifier: String
        let attempt: Int
        let expected: String
        let waitStarted: TimeInterval
        let requestStarted: TimeInterval
        let deadline: TimeInterval
        let timeout: TimeInterval
    }

    private func recordButtonRead(_ trace: ButtonReadTrace, catalogue: DuoCatalogue, pid: Int32,
                                  command: String, result: CommandOutput? = nil, error: String? = nil) {
        guard let artifactRoot = ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"] else { return }
        let finished = ProcessInfo.processInfo.systemUptime
        var fields = [
            "command": command, "expectedPID": String(pid), "expectedState": trace.expected,
            "attempt": String(trace.attempt), "timeoutSeconds": String(trace.timeout),
            "waitElapsedSeconds": String(finished - trace.waitStarted),
            "requestElapsedSeconds": String(finished - trace.requestStarted),
            "remainingSeconds": String(trace.deadline - finished),
            "catalogue.bootIdentity": catalogue.bootIdentity,
            "catalogue.screenID": String(catalogue.activePanel.identity.displayID),
            "catalogue.screenUUID": catalogue.activePanel.identity.uniqueID.uuidString,
            "catalogue.orientation": catalogue.activePanel.currentOrientation,
            "catalogue.boundsWidth": String(catalogue.activePanel.boundsWidth),
            "catalogue.boundsHeight": String(catalogue.activePanel.boundsHeight),
        ]
        if let error { fields["commandError"] = error }
        if let result {
            fields["exitCode"] = String(result.exitCode)
            fields["response"] = result.output
            let receiptLine = result.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
            if let response = try? JSONDecoder().decode(DuoCLIResponse.self, from: Data(receiptLine.utf8)) {
                fields["outcome"] = response.outcome
                fields["acquisition.outcome"] = response.ax?.acquisition?.outcome.rawValue ?? "missing"
                fields["acquisition.attempts"] = String(reflecting: response.ax?.acquisition?.attempts)
                fields["display.logicalWidth"] = response.context.map { String($0.logicalWidth) } ?? "missing"
                fields["display.logicalHeight"] = response.context.map { String($0.logicalHeight) } ?? "missing"
                fields["display.rotationDegrees"] = response.context.map { String($0.rotationDegrees) } ?? "missing"
                let roots = response.ax?.roots ?? []
                let state = UIStateParser.findElement(in: roots, withIdentifier: stateID)
                let button = UIStateParser.findElement(in: roots, withIdentifier: buttonID)
                fields["state.label"] = state?.label ?? "missing"
                fields["state.value"] = state?.value ?? "missing"
                fields["button.type"] = button?.type ?? "missing"
                fields["button.enabled"] = button?.enabled.map { String($0) } ?? "missing"
                fields["button.frame"] = String(reflecting: button?.frame)
            }
        }
        do {
            let directory = URL(fileURLWithPath: artifactRoot)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(
                "duo-button-read-\(trace.identifier)-\(trace.attempt).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(fields).write(to: destination, options: .withoutOverwriting)
        } catch {
            print("Could not save Duo button read diagnostics: \(error)")
        }
    }

    func tapAndVerify(catalogue: DuoCatalogue, pid: Int32, fresh: DuoSnapshot) async throws {
        guard UIStateParser.findElement(in: fresh.roots, withIdentifier: stateID)?.value == "Initial" else {
            throw TestError.unexpectedState("A fresh Initial button state is required before input.")
        }
        let response: DuoCLIResponse = try await decode([
            "tap", "--id", buttonID, "--element-type", "Button", "--tap-style", "physical",
            "--expected-pid", String(pid),
        ] + selection(catalogue))
        try response.requireSuccess("enqueuedAndDrained")
        // Direct native hits have hitPID only. A second hit exists for descendant/switch validation.
        guard response.enqueuedEventCount == 2, response.cleanup == "notNeeded",
              response.context == fresh.context, let validation = response.ax?.validation,
              validation.expectedPID == pid, validation.frontmostPID == pid, validation.hitPID == pid,
              validation.confirmedHitPID == nil || validation.confirmedHitPID == pid,
              validation.verifiedTarget.identifier == buttonID else {
            let validation = response.ax?.validation
            let evidence = [
                "outcome=\(response.outcome.prefix(64)) enqueued=\(response.enqueuedEventCount) cleanup=\(response.cleanup.prefix(64))",
                "expectedPID=\(pid) axPID=\(response.ax.map { String($0.expectedPID) } ?? "missing")",
                "validationExpectedPID=\(validation.map { String($0.expectedPID) } ?? "missing") "
                    + "frontmostPID=\(validation.map { String($0.frontmostPID) } ?? "missing") "
                    + "hitPID=\(validation.map { String($0.hitPID) } ?? "missing") "
                    + "confirmedHitPID=\(validation?.confirmedHitPID.map { String($0) } ?? "missing")",
                "verifiedTargetID=\((validation?.verifiedTarget.identifier ?? "missing").prefix(128))",
                "freshContext: \(fresh.context.diagnosticSummary)",
                "responseContext: \(response.context?.diagnosticSummary ?? "missing")",
            ].joined(separator: "\n")
            throw TestError.unexpectedState("Fresh button input lacks matching target, PID or release/drain evidence.\n\(evidence)")
        }
        _ = try await waitForButtonState("Tapped", catalogue: catalogue, pid: pid)
    }

    func requireInactivePanelRefusal(_ panel: DuoPanelIdentity, pid: Int32) async throws {
        let arguments = [
            "tap", "--id", buttonID, "--element-type", "Button", "--tap-style", "physical",
            "--expected-pid", String(pid), "--input-mode", "selected",
            "--screen-id", String(panel.displayID), "--screen-uuid", panel.uniqueID.uuidString,
        ]
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        let result = try await CommandRunner.run(command, allowFailure: true, timeout: 35)
        let receiptLine = result.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let response = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(receiptLine.utf8))
        try #require(result.exitCode != 0, "Inactive screen input succeeded.")
        try #require(response.outcome == "failedBeforeInput" && response.error != nil)
        try #require(response.enqueuedEventCount == 0 && response.cleanup == "notNeeded")
        try #require(response.quarantine == nil, "Inactive screen refusal left uncertain input state.")
    }

    func report(_ action: String, catalogue: DuoCatalogue) {
        let panel = catalogue.activePanel
        print("Duo \(action): boot=\(catalogue.bootIdentity) screen=\(panel.identity.displayID) "
            + "uuid=\(panel.identity.uniqueID) orientation=\(panel.currentOrientation) appState=Tapped")
    }

    func stableCatalogue(boot: String, expectedScreenID: UInt32? = nil, expectedRotation: Int? = nil) async throws -> DuoCatalogue {
        if let wait = try DuoStateReadWait.preparationWindow("stable-catalogue") {
            return try await DuoStateReadWait.$current.withValue(wait) {
                try await stableCatalogue(boot: boot, expectedScreenID: expectedScreenID, expectedRotation: expectedRotation)
            }
        }
        let recovery = DuoStateReadWait.current
        let deadline = recovery?.deadlineUptime ?? ProcessInfo.processInfo.systemUptime + 10
        var previous: DuoPanel?
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            do {
                let timeout = try recovery.map { try min(remaining, $0.remaining(minimum: 5.5)) } ?? remaining
                let current = try await catalogueOnce(boot: boot, timeout: timeout)
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                let matchesTarget: Bool
                if let expectedScreenID {
                    guard Set(current.panels.map({ $0.identity.displayID })) == Set<UInt32>([1, 3]) else {
                        throw TestError.unexpectedState("Named-pose readiness requires the verified Duo outer1/inner3 fixture.")
                    }
                    let currentRotation = try current.activePanel.rotationDegrees()
                    matchesTarget = current.activePanel.identity.displayID == expectedScreenID
                        && (expectedRotation == nil || currentRotation == expectedRotation)
                } else {
                    matchesTarget = true
                }
                if matchesTarget && current.activePanel == previous { return current }
                previous = matchesTarget ? current.activePanel : nil
            } catch CatalogueReadFailure.changedDuringRead {
                previous = nil
            } catch CatalogueReadFailure.serviceUnavailable {
                guard recovery != nil else { throw CatalogueReadFailure.serviceUnavailable }
                previous = nil
            }
            let pause = min(0.25, deadline - ProcessInfo.processInfo.systemUptime)
            if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        }
        throw TestError.unexpectedState("Two consecutive display reads did not show the intended active panel and stable geometry before the advertised deadline.")
    }

    private enum CatalogueReadFailure: Error {
        case changedDuringRead, serviceUnavailable
    }

    private func catalogueDescription(boot: String?, timeout: TimeInterval) async throws -> DuoCatalogue {
        let arguments = ["list-simulators", "--displays"]
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        let started = ProcessInfo.processInfo.systemUptime
        let result: (output: String, exitCode: Int32)
        do {
            result = try await CommandRunner.run(command, allowFailure: true, timeout: timeout)
        } catch {
            try DuoStateReadWait.current?.record(command: command, started: started, error: String(describing: error))
            recordCatalogueFailure(command: command, boot: boot, timeout: timeout, started: started,
                error: String(describing: error))
            throw TestError.commandError("\(command)\n\(error)")
        }
        if let wait = DuoStateReadWait.current {
            try wait.record(command: command, started: started, result: CommandOutput(output: result.output, exitCode: result.exitCode))
            guard ProcessInfo.processInfo.systemUptime < wait.deadlineUptime else {
                throw TestError.unexpectedState("Display read completed after its recovery deadline.")
            }
        }
        guard result.exitCode == 0 else {
            recordCatalogueFailure(command: command, boot: boot, timeout: timeout, started: started,
                result: CommandOutput(output: result.output, exitCode: result.exitCode))
            if result.exitCode == 1,
               result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Error: changedDuringRead" {
                throw CatalogueReadFailure.changedDuringRead
            }
            if DuoStateReadWait.current != nil, result.exitCode == 1,
               ProcessInfo.processInfo.systemUptime - started >= 4.5,
               result.output.contains("ActivePanelReadError(childFailure: Optional(FBSimulatorControl.ActivePanelChildFailure.nonzeroExit), validationFailure: nil"),
               result.output.contains("terminationStatus: Optional(2)"),
               result.output.contains("exitConfirmed: true"), result.output.contains("sentTerminate: false"),
               result.output.contains("sentKill: false"), result.output.contains("\"--timeout\", \"5\"") {
                throw CatalogueReadFailure.serviceUnavailable
            }
            throw TestError.commandError("\(command)\nCatalogue command exit=\(result.exitCode).\n\(result.output)")
        }
        do {
            return try JSONDecoder().decode(DuoCatalogue.self, from: Data(result.output.utf8))
        } catch {
            recordCatalogueFailure(command: command, boot: boot, timeout: timeout, started: started,
                result: CommandOutput(output: result.output, exitCode: result.exitCode), error: String(describing: error))
            throw TestError.invalidJSON("\(command)\n\(error)\n\(result.output)")
        }
    }

    private func recordCatalogueFailure(command: String, boot: String?, timeout: TimeInterval, started: TimeInterval,
                                        result: CommandOutput? = nil, error: String? = nil) {
        guard let artifactRoot = ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"] else { return }
        var fields = [
            "command": command, "expectedBoot": boot ?? "unspecified", "timeoutSeconds": String(timeout),
            "requestStartedUptime": String(started),
            "requestElapsedSeconds": String(ProcessInfo.processInfo.systemUptime - started),
        ]
        if let result {
            fields["exitCode"] = String(result.exitCode)
            fields["response"] = result.output
        }
        if let error { fields["commandError"] = error }
        do {
            let directory = URL(fileURLWithPath: artifactRoot)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("duo-catalogue-failure-\(UUID().uuidString).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(fields).write(to: destination, options: .withoutOverwriting)
        } catch {
            print("Could not save Duo catalogue failure: \(error)")
        }
    }

    /// Only the measured zero-event unavailable read is recoverable. Writes never enter this loop.
    private func readHinge(boot: String, timeout: TimeInterval = 35, artifactURL: URL? = nil) async throws -> DuoCLIResponse {
        if let wait = try DuoStateReadWait.preparationWindow("hinge") {
            return try await DuoStateReadWait.$current.withValue(wait) {
                try await readHinge(boot: boot, timeout: timeout, artifactURL: artifactURL)
            }
        }
        guard let wait = DuoStateReadWait.current else {
            return try await decode(["hinge", "read", "--expected-boot", boot], timeout: timeout, artifactURL: artifactURL)
        }
        let command = ([axePath, "hinge", "read", "--expected-boot", boot, "--udid", udid]).map(Self.quote).joined(separator: " ")
        while true {
            let remaining = min(timeout, try wait.remaining(minimum: 3.5))
            let started = ProcessInfo.processInfo.systemUptime
            let result: (output: String, exitCode: Int32)
            do { result = try await CommandRunner.run(command, allowFailure: true, timeout: remaining) }
            catch {
                try wait.record(command: command, started: started, error: String(describing: error))
                throw error
            }
            try wait.record(command: command, started: started, result: CommandOutput(output: result.output, exitCode: result.exitCode))
            let line = result.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
            let response = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(line.utf8))
            guard ProcessInfo.processInfo.systemUptime < wait.deadlineUptime,
                  response.enqueuedEventCount == 0, response.cleanup == "notNeeded", response.quarantine == nil,
                  response.hinge?.kind == "read" else {
                throw TestError.unexpectedState("State read has expired, changed kind or uncertain input state; no retry.")
            }
            if result.exitCode == 0 {
                try response.requireSuccess("observedHinge")
                guard let readback = response.hinge?.readback, readback.bootIdentity == boot,
                      let timestamp = readback.sample.timestampUptime, let received = readback.sample.receivedUptime,
                      timestamp.isFinite, received.isFinite, timestamp >= started,
                      received >= timestamp, received <= ProcessInfo.processInfo.systemUptime else {
                    throw TestError.unexpectedState("State read lacks a fresh sample for the current boot; no retry.")
                }
                if let artifactURL { try Data(line.utf8).write(to: artifactURL, options: .withoutOverwriting) }
                return response
            }
            guard result.exitCode == 1, response.outcome == "failedBeforeInput",
                  response.hinge?.failure?.reason == "unavailable", response.hinge?.failure?.delivery == "notDispatched",
                  response.error?.contains("Context hinge sample timed out") == true else {
                throw TestError.commandError("Terminal hinge read refusal: \(result.output)")
            }
            try await wait.pause()
        }
    }

    private func selection(_ catalogue: DuoCatalogue) -> [String] {
        let pair = catalogue.activePanel.identity
        return ["--input-mode", "selected", "--screen-id", String(pair.displayID), "--screen-uuid", pair.uniqueID.uuidString]
    }

    private func decode<Value: Decodable>(_ arguments: [String], timeout: TimeInterval = 35,
                                          artifactURL: URL? = nil) async throws -> Value {
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        let output: String
        do {
            output = try await CommandRunner.run(command, timeout: timeout).output
        } catch {
            throw TestError.commandError("\(command)\n\(error)")
        }
        if let artifactURL {
            try Data(output.utf8).write(to: artifactURL, options: .withoutOverwriting)
        }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(output.utf8))
        } catch {
            throw TestError.invalidJSON("\(command)\n\(error)\n\(output)")
        }
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}


/// Owns only the external writer's artifact handshake. The test owns input and sensor checks.
struct DuoRotationPlan {
    let before: DuoContext
    let target: Int

    init(catalogue: DuoCatalogue, context: DuoContext) throws {
        try context.requireMatch(catalogue)
        let positions = context.screenID == 1 ? [0, 90, 270] : [0, 90, 180, 270]
        guard [UInt32(1), 3].contains(context.screenID), let index = positions.firstIndex(of: context.rotationDegrees) else {
            throw TestError.unexpectedState("Rotation mapping requires the verified Duo outer1/inner3 positions.")
        }
        before = context; target = positions[(index + 1) % positions.count]
    }
}

struct DuoRotationConfirmation {
    let before: DuoContext
    let after: DuoContext
    let catalogue: DuoCatalogue
    let matchingObservationCount: Int
}

final class DuoHeldLayoutControl {
    private let boot: String
    private let udid: String
    private let degrees: Double
    private let rotation: DuoRotationPlan?
    private let artifacts: URL
    private let readyURL: URL
    private let releaseURL: URL
    private var ready: Ready?
    private var releasePublished = false

    init(boot: String, udid: String, degrees: Double, artifacts: URL, rotation: DuoRotationPlan? = nil) throws {
        self.boot = boot; self.udid = udid; self.degrees = degrees; self.artifacts = artifacts; self.rotation = rotation
        readyURL = artifacts.appendingPathComponent("fold-protocol-ready.json")
        releaseURL = artifacts.appendingPathComponent("fold-connection-release.json")
        for url in [readyURL, releaseURL] {
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) != 0, errno == ENOENT else {
                throw TestError.unexpectedState("Held fold control files must be new.")
            }
        }
    }

    var arguments: [String] {
        [readyURL.path, releaseURL.path, "state-wait=30"]
            + (rotation.map { ["rotation-from=\($0.before.rotationDegrees)"] } ?? [])
    }

    func waitForReady(_ external: PlaygroundTestProcess) async throws {
        let deadline = external.startedUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard external.isRunning else {
                throw TestError.unexpectedState("External writer ended before protocol-ready.\n\(try external.diagnostics())")
            }
            if let value = try readReady() {
                ready = value
                _ = try remaining()
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestError.unexpectedState("External writer did not publish protocol-ready within8seconds.")
    }

    func remaining() throws -> TimeInterval {
        guard let ready else { throw TestError.unexpectedState("Held writer is not protocol-ready.") }
        let value = ready.deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard value > 0 else { throw TestError.unexpectedState("Held fold exceeded its original8second input deadline.") }
        return value
    }

    /// Used only after the original input has joined and its native release was checked.
    func stateRemaining() throws -> TimeInterval {
        let value = try recoveryWindow().remaining(minimum: 0)
        guard value > 0 else { throw TestError.unexpectedState("Held fold exceeded its advertised30second state deadline.") }
        return value
    }

    /// Called only after the original input has joined and its native cleanup was checked.
    func confirmTargetAndRelease(_ external: PlaygroundTestProcess, device: DuoPlaygroundSession, pid: Int32) async throws -> DuoRotationConfirmation? {
        guard let ready, external.isRunning else {
            throw TestError.unexpectedState("Target confirmation requires the same live external writer.")
        }
        let recovery = try recoveryWindow()
        let observed = try await DuoStateReadWait.$current.withValue(recovery) { () async throws -> DuoRotationConfirmation? in
            if let rotation {
                return try await device.requireExternalRotation(ready.write, plan: rotation, pid: pid,
                    after: ready.readyUptime, artifacts: artifacts, artifactPrefix: "held-rotation-confirmation")
            }
            try await device.requireExternalFold(ready.write, boot: boot, degrees: degrees,
                after: ready.readyUptime, artifacts: artifacts, deadline: recovery.deadlineUptime,
                artifactPrefix: "held-fold-confirmation")
            return nil
        }
        guard external.isRunning else {
            throw TestError.unexpectedState("External writer closed before both real target samples.")
        }
        _ = try stateRemaining()
        try publishRelease(ready, reason: "targetObserved")
        try await external.wait(timeout: stateRemaining())
        return observed
    }

    func recoveryWindow() throws -> DuoStateReadWait {
        guard let ready, ready.stateWaitBudgetSeconds == DuoStateReadWait.seconds,
              let deadline = ready.stateWaitDeadlineUptime else {
            throw TestError.unexpectedState("Held writer did not advertise the explicit state-read window.")
        }
        return try DuoStateReadWait(phase: "after-input-release", artifacts: artifacts,
            started: ready.vendorProtocol.startedUptime, deadline: deadline)
    }

    func requireCompleted(_ hold: DuoExternalConnectionHold?, started: TimeInterval, finished: TimeInterval) throws {
        guard let ready, let hold, releasePublished, hold.outcome == "releasedByCaller",
              hold.connectionHeldUntilRelease, !hold.mechanicalTargetObserved,
              hold.releaseToken == ready.releaseToken, hold.connectionID == ready.connectionID,
              hold.readyUptime == ready.readyUptime, hold.releaseReason == "targetObserved",
              started == ready.vendorProtocol.startedUptime, started <= ready.readyUptime,
              hold.stateWaitBudgetSeconds == ready.stateWaitBudgetSeconds,
              hold.stateWaitDeadlineUptime == ready.stateWaitDeadlineUptime,
              hold.releaseReceivedUptime >= ready.readyUptime,
              hold.releaseReceivedUptime <= finished,
              finished < (try recoveryWindow()).deadlineUptime else {
            throw TestError.unexpectedState("External writer lacks the matching target-observed release and close receipt.")
        }
    }

    func abort() throws {
        guard !releasePublished else { return }
        if ready == nil { ready = try readReady() }
        if let ready { try publishRelease(ready, reason: "abort") }
    }

    private func readReady() throws -> Ready? {
        var info = stat()
        guard readyURL.path.withCString({ lstat($0, &info) }) == 0 else {
            if errno == ENOENT { return nil }
            throw TestError.unexpectedState("Cannot inspect held fold protocol-ready file.")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw TestError.unexpectedState("Held fold protocol-ready is not a regular file.")
        }
        let value = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: readyURL))
        let protocolReceipt = value.vendorProtocol
        guard value.state == "protocolReadyConnectionHeld", UUID(uuidString: value.releaseToken) != nil,
              UUID(uuidString: value.connectionID) != nil, value.expectedBootIdentity == boot,
              UUID(uuidString: value.simulatorUDID) == UUID(uuidString: udid), value.requestedDegrees == degrees,
              value.write.source == (rotation == nil ? "hinge-slider-control" : "orientation-picker-control"),
              value.readyUptime.isFinite, value.deadlineUptime.isFinite,
              value.readyUptime <= ProcessInfo.processInfo.systemUptime,
              value.readyUptime < value.deadlineUptime,
              protocolReceipt.activation == "xpc_connection_activate",
              protocolReceipt.connectionIdentitySource == "fixture-owned-connection-token",
              protocolReceipt.connectionID == value.connectionID, protocolReceipt.vendorEventCount == 1,
              !protocolReceipt.eventAcknowledged, !protocolReceipt.mechanicalTargetObserved,
              protocolReceipt.deadlineUptime == value.deadlineUptime,
              protocolReceipt.startedUptime + 8 == value.deadlineUptime,
              value.stateWaitBudgetSeconds == DuoStateReadWait.seconds,
              value.stateWaitDeadlineUptime == protocolReceipt.startedUptime + DuoStateReadWait.seconds,
              protocolReceipt.startedUptime <= protocolReceipt.preBarrier.requestEnqueuedUptime,
              protocolReceipt.preBarrier.replyReceivedUptime <= protocolReceipt.eventEnqueuedUptime,
              protocolReceipt.eventEnqueuedUptime <= protocolReceipt.eventHostSendDrainedUptime,
              protocolReceipt.eventHostSendDrainedUptime <= protocolReceipt.postBarrier.requestEnqueuedUptime,
              protocolReceipt.postBarrier.replyReceivedUptime <= protocolReceipt.finishedUptime,
              protocolReceipt.finishedUptime <= value.readyUptime else {
            throw TestError.unexpectedState("Held fold protocol-ready has the wrong identity, order or deadline.")
        }
        try protocolReceipt.preBarrier.requireReply(phase: "beforeWrite", connectionID: value.connectionID)
        try protocolReceipt.postBarrier.requireReply(phase: "afterWrite", connectionID: value.connectionID)
        return value
    }

    private func publishRelease(_ ready: Ready, reason: String) throws {
        let release = Release(state: "releaseVendorConnection", releaseToken: ready.releaseToken,
            connectionID: ready.connectionID, expectedBootIdentity: boot, simulatorUDID: ready.simulatorUDID,
            requestedDegrees: degrees, reason: reason)
        let temporary = artifacts.appendingPathComponent(".fold-release-" + UUID().uuidString)
        try JSONEncoder().encode(release).write(to: temporary, options: .withoutOverwriting)
        defer { _ = temporary.path.withCString { unlink($0) } }
        guard temporary.path.withCString({ source in releaseURL.path.withCString { link(source, $0) } }) == 0 else {
            throw TestError.unexpectedState("Cannot atomically publish the one-use held fold release.")
        }
        releasePublished = true
    }

    private struct Ready: Decodable {
        let state: String; let releaseToken: String; let connectionID: String
        let expectedBootIdentity: String; let simulatorUDID: String; let requestedDegrees: Double
        let readyUptime: TimeInterval; let deadlineUptime: TimeInterval
        let write: DuoExternalLayoutWrite; let vendorProtocol: ProtocolReceipt
        let stateWaitBudgetSeconds: TimeInterval?; let stateWaitDeadlineUptime: TimeInterval?
    }
    private struct Release: Encodable {
        let state: String; let releaseToken: String; let connectionID: String
        let expectedBootIdentity: String; let simulatorUDID: String; let requestedDegrees: Double
        let reason: String
    }
    private struct ProtocolReceipt: Decodable {
        let activation: String; let connectionIdentitySource: String; let connectionID: String
        let startedUptime: TimeInterval; let deadlineUptime: TimeInterval
        let preBarrier: Barrier; let eventEnqueuedUptime: TimeInterval
        let eventHostSendDrainedUptime: TimeInterval; let postBarrier: Barrier
        let finishedUptime: TimeInterval; let vendorEventCount: Int
        let eventAcknowledged: Bool; let mechanicalTargetObserved: Bool
    }
    private struct Barrier: Decodable {
        let phase: String; let connectionID: String; let requestEnqueuedUptime: TimeInterval
        let replyReceivedUptime: TimeInterval; let replyType: String
        let remainingBudgetSecondsAtRequest: TimeInterval; let replyReceived: Bool; let replyWasXPCError: Bool

        func requireReply(phase expectedPhase: String, connectionID expectedID: String) throws {
            guard phase == expectedPhase, connectionID == expectedID, replyReceived, !replyWasXPCError,
                  !replyType.isEmpty, remainingBudgetSecondsAtRequest > 0,
                  remainingBudgetSecondsAtRequest <= 8, requestEnqueuedUptime <= replyReceivedUptime else {
                throw TestError.unexpectedState("Held fold lacks a real non-error vendor barrier reply.")
            }
        }
    }
}

struct DuoExternalConnectionHold: Decodable {
    let outcome: String; let connectionHeldUntilRelease: Bool; let mechanicalTargetObserved: Bool
    let releaseToken: String; let connectionID: String; let readyUptime: TimeInterval
    let releaseReceivedUptime: TimeInterval; let releaseReason: String
    let stateWaitBudgetSeconds: TimeInterval?; let stateWaitDeadlineUptime: TimeInterval?
}

/// This fixture receipt is host-send evidence, never a mechanical observation.
struct DuoExternalLayoutWrite: Decodable {
    let source: String
    let outcome: String
    let requestedDegrees: Double
    let expectedBootIdentity: String
    let simulatorUDID: String
    let vendorEventCount: Int
    let hostSendDrained: Bool
    let guestWriteAcknowledged: Bool
    let mechanicalTargetObserved: Bool
}

struct DuoPanelIdentity: Decodable, Hashable, Sendable {
    let displayID: UInt32
    let uniqueID: UUID
}

struct DuoPanel: Decodable, Equatable, Sendable {
    let identity: DuoPanelIdentity
    let active: Bool?
    let currentOrientation: String
    let nativePixelWidth: Double
    let nativePixelHeight: Double
    let boundsWidth: Double
    let boundsHeight: Double
    let pointScale: Int

    func rotationDegrees() throws -> Int {
        guard currentOrientation.hasPrefix("rot"), let degrees = Int(currentOrientation.dropFirst(3)),
              [0, 90, 180, 270].contains(degrees) else {
            throw TestError.unexpectedState("Unsupported measured orientation: \(currentOrientation).")
        }
        return degrees
    }
}

struct DuoCatalogue: Decodable {
    let requestedSimulatorUDID: UUID
    let bootIdentity: String
    let activePanel: DuoPanel
    let panels: [DuoPanel]
}

struct DuoContext: Decodable, Equatable {
    let bootIdentity: String
    let screenID: UInt32
    let screenUUID: UUID
    let logicalWidth: Double
    let logicalHeight: Double
    let rotationDegrees: Int
    let poseRevision: String

    var diagnosticSummary: String {
        "boot=\(bootIdentity.prefix(128)) screenID=\(screenID) screenUUID=\(screenUUID) "
            + "logicalWidth=\(logicalWidth) logicalHeight=\(logicalHeight) rotationDegrees=\(rotationDegrees) "
            + "poseRevision=\(poseRevision.prefix(256))"
    }

    func requireMatch(_ catalogue: DuoCatalogue) throws {
        guard bootIdentity == catalogue.bootIdentity, screenID == catalogue.activePanel.identity.displayID,
              screenUUID == catalogue.activePanel.identity.uniqueID,
              rotationDegrees == (try catalogue.activePanel.rotationDegrees()),
              logicalWidth.isFinite, logicalHeight.isFinite, logicalWidth > 0, logicalHeight > 0,
              !poseRevision.isEmpty else {
            throw TestError.unexpectedState("Selected context does not match fresh display discovery.")
        }
    }
}

struct DuoSnapshot {
    let context: DuoContext
    let roots: [UIElement]
}

struct DuoCLIResponse: Decodable {
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let error: String?
    let context: DuoContext?
    let ax: AX?
    let hinge: Hinge?
    let rotation: Rotation?
    let quarantine: Quarantine?

    func requireSuccess(_ expected: String? = nil) throws {
        guard error == nil, quarantine == nil, cleanup != "uncertain", expected == nil || outcome == expected else {
            throw TestError.unexpectedState("CLI outcome=\(outcome), cleanup=\(cleanup), error=\(error ?? "none"). Input is not replayed.")
        }
    }

    struct AX: Decodable {
        let schemaVersion: Int
        let kind: String
        let expectedPID: Int32
        let failure: AXFailure?
        let acquisition: Acquisition?
        let roots: [UIElement]?
        let validation: Validation?
    }

    enum AXFailure: String, Decodable {
        case ownershipRejected, acquisitionFailed, targetRejected, pressFailed, sliderFailed, inputFailed
        case cleanupUncertain, responseTooLarge, setupFailed, waitTimedOut, waitCancelled
    }

    enum AcquisitionOutcome: String, Decodable {
        case ready, notReady, cancelled, deadlineExceeded, requestTimedOut, processChanged, contextChanged, failed
    }

    struct Acquisition: Decodable {
        let outcome: AcquisitionOutcome
        let attempts: [AcquisitionAttempt]
        let failureDescription: String?
    }

    struct AcquisitionAttempt: Decodable {
        let rootPID: Int32
        let outcome: AcquisitionOutcome
    }

    struct Validation: Decodable {
        let expectedPID: Int32
        let hitPID: Int32
        let frontmostPID: Int32
        let confirmedHitPID: Int32?
        let verifiedTarget: UIElement
    }

    struct Quarantine: Decodable {
        let persisted: Bool
    }

    struct Hinge: Decodable {
        let kind: String?
        let failure: HingeFailure?
        let readback: HingeReadback?
        let receipt: HingeReceipt?
    }

    struct HingeFailure: Decodable {
        let delivery: String
        let reason: String
    }

    struct HingeReadback: Decodable {
        let bootIdentity: String
        let sample: HingeSample
    }

    struct HingeSample: Decodable {
        let mechanicalDegrees: Double
        let timestampUptime: TimeInterval?
        let receivedUptime: TimeInterval?
    }

    struct HingeReceipt: Decodable {
        let requestedDegrees: Double
        let expectedBootIdentity: String
        let matchingSamples: [HingeSample]
    }

    struct Rotation: Decodable {
        let direction: String?
        let receipt: RotationReceipt?
        let failure: RotationFailure?
    }

    struct RotationFailure: Decodable {
        let delivery: String
        let detail: String
        let before: RotationFailureContext?
    }

    struct RotationFailureContext: Decodable {
        let bootIdentity: String
        let screenID: UInt32
        let screenUniqueID: UUID
        let rotation: Int
        let poseRevision: String
    }

    struct RotationReceipt: Decodable {
        let direction: String
        let vendorEventCount: Int
        let matchingObservationCount: Int
        let before: RotationObservation
        let after: RotationObservation
    }

    struct RotationObservation: Decodable {
        let rotation: Int
    }
}
