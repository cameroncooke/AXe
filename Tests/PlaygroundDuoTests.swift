import Foundation
import Testing

private let isDuoPlaygroundE2EEnabled = {
    let value = ProcessInfo.processInfo.environment["AXE_DUO_E2E"]?.lowercased() ?? ""
    return isE2EEnabled && ["1", "true", "yes"].contains(value)
}()

/// Run alone on the dedicated Duo simulator. Every input uses a fresh measured panel.
@Suite("Playground Duo E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoTests {
    @Test("Closed, tabletop and open poses permit a fresh lookup and real button action")
    func namedHingePoses() async throws {
        let app = try DuoPlaygroundSession()
        let original = try await app.catalogue()
        let initialPID = try await app.launch()
        _ = try await app.waitForButtonState("Initial", catalogue: original, pid: initialPID, bootstrap: true)
        _ = try await app.setPose(.open, boot: original.bootIdentity)
        var panels: [DuoPlaygroundPose: DuoPanelIdentity] = [:]

        for pose in [DuoPlaygroundPose.closed, .tabletop, .open] {
            let pid = try await app.launch()
            let before = try await app.catalogue(boot: original.bootIdentity)
            _ = try await app.waitForButtonState("Initial", catalogue: before, pid: pid, bootstrap: true)
            let catalogue = try await app.setPose(pose, boot: original.bootIdentity)
            let fresh = try await app.waitForButtonState("Initial", catalogue: catalogue, pid: pid, bootstrap: true)
            try await app.tapAndVerify(catalogue: catalogue, pid: pid, fresh: fresh)
            panels[pose] = catalogue.activePanel.identity
            app.report("hinge \(pose.rawValue)", catalogue: catalogue)
        }

        let closed = try #require(panels[.closed])
        let open = try #require(panels[.open])
        #expect(closed != open, "Closed and open must select different measured Duo panels.")
    }

    @Test("All four open-panel rotations permit a fresh lookup and real button action")
    func openPanelRotations() async throws {
        try await supportedRotations(pose: .open)
    }

    @Test("All three closed-panel rotations permit a fresh lookup and real button action")
    func closedPanelRotations() async throws {
        try await supportedRotations(pose: .closed)
    }

    @Test("A fold rejects the old agent reference and a fresh reference changes the app")
    func foldInvalidatesAgentReference() async throws {
        try await verifyAgentReferenceInvalidation(fold: true)
    }

    @Test("An inner-panel rotation rejects the old agent reference and a fresh reference changes the app")
    func rotationInvalidatesAgentReference() async throws {
        try await verifyAgentReferenceInvalidation(fold: false)
    }

    private func verifyAgentReferenceInvalidation(fold: Bool) async throws {
        let app = try DuoPlaygroundSession()
        let agent = try AgentPlaygroundSession()
        let original = try await app.catalogue()
        let open = try await app.setPose(.open, boot: original.bootIdentity)
        let pid = try await app.launch()
        _ = try await app.waitForButtonState("Initial", catalogue: open, pid: pid, bootstrap: true)
        let old = try await agent.timedCapture(pid: pid)
        let oldButton = try old.capture.target(id: "slider-value-button")

        let after: DuoCatalogue
        if fold {
            after = try await app.setPose(.closed, boot: original.bootIdentity)
            try #require(after.activePanel.identity != open.activePanel.identity, "The fold did not change the active panel.")
        } else {
            let before = try await app.catalogue(boot: original.bootIdentity)
            after = try await app.rotateRight(catalogue: before)
            try #require(after.activePanel.identity == open.activePanel.identity)
        }
        _ = try await app.waitForButtonState("Initial", catalogue: after, pid: pid, bootstrap: true)
        try await agent.requireRefusal(oldButton.ref, capture: old, pid: pid)
        _ = try await app.waitForButtonState("Initial", catalogue: after, pid: pid)

        let fresh = try await agent.timedCapture(pid: pid)
        try #require(fresh.capture.snapshotID != old.capture.snapshotID)
        try #require(fresh.capture.applicationPID == pid)
        let button = try fresh.capture.target(id: "slider-value-button")
        try old.requireUnexpired("before fresh reference input after Duo transition")
        try fresh.requireUnexpired("before fresh reference input after Duo transition")
        let result = try await agent.tap(button.ref, snapshot: fresh.capture.snapshotID, pid: pid)
        let action = try #require(result.data.action)
        #expect(action.kind == "tap")
        #expect(action.outcome == "enqueuedAndDrained")
        #expect(action.enqueuedEventCount > 0)
        #expect(action.cleanup != "uncertain")
        #expect(!action.replayed)
        _ = try await app.waitForButtonState("Tapped", catalogue: after, pid: pid)
        try old.requireUnexpired("after app recovery from Duo transition")
        try fresh.requireUnexpired("after app recovery from Duo transition")
        app.report(fold ? "agent reference recovered after fold" : "agent reference recovered after rotation", catalogue: after)
    }

    private func supportedRotations(pose: DuoPlaygroundPose) async throws {
        let app = try DuoPlaygroundSession()
        let original = try await app.catalogue()
        let start = try await app.setPose(pose, boot: original.bootIdentity)
        let expectedPositions = pose == .open ? Set([0, 90, 180, 270]) : Set([0, 90, 270])
        let startingRotation = try start.activePanel.rotationDegrees()
        var observedPositions = Set([startingRotation])

        for _ in 0..<expectedPositions.count {
            let pid = try await app.launch()
            let before = try await app.catalogue(boot: original.bootIdentity)
            _ = try await app.waitForButtonState("Initial", catalogue: before, pid: pid, bootstrap: true)
            let after = try await app.rotateRight(catalogue: before)
            #expect(after.activePanel.identity == start.activePanel.identity)
            observedPositions.insert(try after.activePanel.rotationDegrees())
            let fresh = try await app.waitForButtonState("Initial", catalogue: after, pid: pid, bootstrap: true)
            try await app.tapAndVerify(catalogue: after, pid: pid, fresh: fresh)
            app.report("rotate right, hinge \(pose.rawValue)", catalogue: after)
        }

        let final = try await app.catalogue(boot: original.bootIdentity)
        #expect(observedPositions == expectedPositions)
        #expect(try final.activePanel.rotationDegrees() == startingRotation)
    }
}

private enum DuoPlaygroundPose: String, Hashable {
    case closed, tabletop, open

    var degrees: Double {
        switch self {
        case .closed: return 0
        case .tabletop: return 90
        case .open: return 180
        }
    }
}

private struct DuoPlaygroundSession {
    private let udid: String
    private let axePath: String
    private let bundleID = "com.cameroncooke.AxePlayground"
    private let buttonID = "slider-value-button"
    private let stateID = "slider-value-state"

    init() throws {
        udid = try TestHelpers.requireSimulatorUDID()
        axePath = try TestHelpers.getAxePath()
    }

    func launch() async throws -> Int32 {
        let command = [
            "xcrun", "simctl", "launch", "--terminate-running-process", udid, bundleID,
            "--launch-arg", "screen=slider-value-test",
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
        _ expected: String, catalogue: DuoCatalogue, pid: Int32, bootstrap: Bool = false
    ) async throws -> DuoSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var preparation = bootstrap ? "automation-session" : "existing-bridge"
        var lastValue = "missing"
        repeat {
            let response: DuoCLIResponse = try await decode([
                "describe-ui", "--expected-pid", String(pid), "--ax-preparation", preparation,
            ] + selection(catalogue))
            try response.requireSuccess()
            guard let context = response.context, let roots = response.ax?.roots, response.ax?.expectedPID == pid else {
                throw TestError.unexpectedState("Selected description has no matching app or measured context.")
            }
            try context.requireMatch(catalogue)
            preparation = "existing-bridge"
            let snapshot = DuoSnapshot(context: context, roots: roots)
            lastValue = UIStateParser.findElement(in: roots, withIdentifier: stateID)?.value ?? "missing"
            if lastValue == expected, let button = UIStateParser.findElement(in: roots, withIdentifier: buttonID),
               button.type == "Button", button.enabled == true, let frame = button.frame,
               [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
               frame.x >= 0, frame.y >= 0, frame.width > 0, frame.height > 0,
               frame.x + frame.width <= context.logicalWidth, frame.y + frame.height <= context.logicalHeight {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("Playground button did not become ready with state \(expected); last state: \(lastValue).")
    }

    func tapAndVerify(catalogue: DuoCatalogue, pid: Int32, fresh: DuoSnapshot) async throws {
        guard UIStateParser.findElement(in: fresh.roots, withIdentifier: stateID)?.value == "Initial" else {
            throw TestError.unexpectedState("A fresh Initial button state is required before input.")
        }
        let response: DuoCLIResponse = try await decode([
            "tap", "--id", buttonID, "--element-type", "Button", "--tap-style", "physical",
            "--expected-pid", String(pid), "--ax-preparation", "existing-bridge",
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

private struct DuoPanelIdentity: Decodable, Hashable {
    let displayID: UInt32
    let uniqueID: UUID
}

private struct DuoPanel: Decodable, Equatable {
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

private struct DuoCatalogue: Decodable {
    let requestedSimulatorUDID: UUID
    let bootIdentity: String
    let activePanel: DuoPanel
    let panels: [DuoPanel]
}

private struct DuoContext: Decodable, Equatable {
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

private struct DuoSnapshot {
    let context: DuoContext
    let roots: [UIElement]
}

private struct DuoCLIResponse: Decodable {
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
        let expectedPID: Int32
        let roots: [UIElement]?
        let validation: Validation?
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
