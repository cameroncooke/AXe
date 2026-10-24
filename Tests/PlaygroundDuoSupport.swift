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

    func catalogue(boot: String? = nil) async throws -> DuoCatalogue {
        let value: DuoCatalogue = try await decode(["list-simulators", "--displays"])
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
        let before: DuoCLIResponse = try await decode(["hinge", "read", "--expected-boot", boot])
        try before.requireSuccess("observedHinge")
        guard before.hinge?.readback?.bootIdentity == boot else {
            throw TestError.unexpectedState("Hinge read returned a different boot.")
        }
        let response: DuoCLIResponse = try await decode([
            "hinge", "set", pose.rawValue, "--expected-boot", boot, "--tolerance", "0.1",
        ])
        try response.requireSuccess("observedMechanicalTarget")
        guard let receipt = response.hinge?.receipt, receipt.expectedBootIdentity == boot,
              receipt.requestedDegrees == pose.degrees, receipt.matchingSamples.count == 2,
              receipt.matchingSamples.allSatisfy({ abs($0.mechanicalDegrees - pose.degrees) <= 0.1 }) else {
            throw TestError.unexpectedState("Hinge \(pose.rawValue) lacks two matching measured samples.")
        }
        let readback: DuoCLIResponse = try await decode(["hinge", "read", "--expected-boot", boot])
        try readback.requireSuccess("observedHinge")
        guard let measured = readback.hinge?.readback, measured.bootIdentity == boot,
              abs(measured.sample.mechanicalDegrees - pose.degrees) <= 0.1 else {
            throw TestError.unexpectedState("A fresh hinge read did not retain \(pose.rawValue).")
        }
        return try await stableCatalogue(boot: boot)
    }

    func rotateRight(catalogue before: DuoCatalogue) async throws -> DuoCatalogue {
        let pair = before.activePanel.identity
        let response: DuoCLIResponse = try await decode([
            "rotate", "right", "--screen-id", String(pair.displayID), "--screen-uuid", pair.uniqueID.uuidString,
            "--expected-boot", before.bootIdentity,
        ])
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
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var lastValue = "missing"
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            let response = try await buttonDescription(catalogue: catalogue, pid: pid, timeout: remaining)
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

    private func buttonDescription(catalogue: DuoCatalogue, pid: Int32, timeout: TimeInterval) async throws -> DuoCLIResponse {
        let arguments = ["describe-ui", "--expected-pid", String(pid)] + selection(catalogue)
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        let result = try await CommandRunner.run(command, allowFailure: true, timeout: timeout)
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

    private func stableCatalogue(boot: String) async throws -> DuoCatalogue {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var previous: DuoPanel?
        repeat {
            let current = try await catalogue(boot: boot)
            if current.activePanel == previous { return current }
            previous = current.activePanel
            try await Task.sleep(nanoseconds: 250_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("Two consecutive display reads did not show the same active panel and geometry.")
    }

    private func selection(_ catalogue: DuoCatalogue) -> [String] {
        let pair = catalogue.activePanel.identity
        return ["--input-mode", "selected", "--screen-id", String(pair.displayID), "--screen-uuid", pair.uniqueID.uuidString]
    }

    private func decode<Value: Decodable>(_ arguments: [String]) async throws -> Value {
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        let output: String
        do {
            output = try await CommandRunner.run(command, timeout: 35).output
        } catch {
            throw TestError.commandError("\(command)\n\(error)")
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
        let readback: HingeReadback?
        let receipt: HingeReceipt?
    }

    struct HingeReadback: Decodable {
        let bootIdentity: String
        let sample: HingeSample
    }

    struct HingeSample: Decodable {
        let mechanicalDegrees: Double
    }

    struct HingeReceipt: Decodable {
        let requestedDegrees: Double
        let expectedBootIdentity: String
        let matchingSamples: [HingeSample]
    }

    struct Rotation: Decodable {
        let receipt: RotationReceipt?
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
