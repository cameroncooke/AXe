import Foundation
import Testing

/// Each case observes real UIKit contacts before changing the device, then checks release and fresh input.
@Suite("Playground Duo Interruption E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoInterruptionTests {
    @Test("Folding stops a long hold, releases its contact and permits a fresh button tap")
    func holdDuringFold() async throws { try await verify(.hold, change: .fold) }

    @Test("Rotating stops a long hold, releases its contact and permits a fresh button tap")
    func holdDuringRotation() async throws { try await verify(.hold, change: .rotate) }

    @Test("Folding stops a moving drag before its old endpoint and permits a fresh button tap")
    func dragDuringFold() async throws { try await verify(.drag, change: .fold) }

    @Test("Rotating stops a moving drag before its old endpoint and permits a fresh button tap")
    func dragDuringRotation() async throws { try await verify(.drag, change: .rotate) }

    @Test("Folding stops a moving pinch, releases both contacts and permits a fresh button tap")
    func pinchDuringFold() async throws { try await verify(.pinch, change: .fold) }

    @Test("Rotating stops a moving pinch, releases both contacts and permits a fresh button tap")
    func pinchDuringRotation() async throws { try await verify(.pinch, change: .rotate) }

    private func verify(_ gesture: InterruptedGesture, change: InterruptedLayoutChange) async throws {
        let session = try PlaygroundInterruptionSession(gesture: gesture, change: change)
        try await session.run()
    }
}

private enum InterruptedGesture: String {
    case hold, drag, pinch
    var contactCount: Int { self == .pinch ? 2 : 1 }
    var normalEventCount: Int { self == .hold ? 2 : self == .drag ? 122 : 123 }
}

private enum InterruptedLayoutChange: String { case fold, rotate }

private struct InterruptionPoint: Codable {
    let x: Double
    let y: Double
    func distance(from event: PlaygroundContactEvent) -> Double { hypot(event.x - x, event.y - y) }
}

private struct InterruptedGeometry: Codable {
    let starts: [InterruptionPoint]
    let ends: [InterruptionPoint]
    let arguments: [String]

    init(gesture: InterruptedGesture, frame: UIElement.Frame) throws {
        let frameIsFinite = [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
        try #require(frameIsFinite)
        try #require(frame.width > 240 && frame.height > 80, "The visible pad is too small for this gesture.")
        let center = InterruptionPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        switch gesture {
        case .hold:
            starts = [center]
            ends = [center]
            arguments = ["touch", "-x", String(center.x), "-y", String(center.y), "--down", "--up", "--delay", "8"]
        case .drag:
            starts = [InterruptionPoint(x: center.x - 100, y: center.y)]
            ends = [InterruptionPoint(x: center.x + 100, y: center.y)]
            arguments = ["drag", "--start-x", String(starts[0].x), "--start-y", String(starts[0].y),
                "--end-x", String(ends[0].x), "--end-y", String(ends[0].y), "--steps", "120", "--duration", "8"]
        case .pinch:
            starts = [InterruptionPoint(x: center.x - 40, y: center.y), InterruptionPoint(x: center.x + 40, y: center.y)]
            ends = [InterruptionPoint(x: center.x - 100, y: center.y), InterruptionPoint(x: center.x + 100, y: center.y)]
            arguments = ["gesture", "pinch", "-x", String(center.x), "-y", String(center.y),
                "--radius", "40", "--scale", "2.5", "--delta", "0.5", "--duration", "8"]
        }
        for point in starts + ends {
            try #require(point.x > frame.x + 8 && point.x < frame.x + frame.width - 8
                && point.y > frame.y + 8 && point.y < frame.y + frame.height - 8,
                "Every planned point must remain inside the visible pad.")
        }
    }
}

private struct PlaygroundInterruptionSession {
    let gesture: InterruptedGesture
    let change: InterruptedLayoutChange
    let udid: String
    let cli: String
    let stateOperator: String
    let directory: URL

    init(gesture: InterruptedGesture, change: InterruptedLayoutChange) throws {
        self.gesture = gesture
        self.change = change
        udid = try TestHelpers.requireSimulatorUDID()
        cli = try TestHelpers.getAxePath()
        let environment = ProcessInfo.processInfo.environment
        stateOperator = try #require(environment["AXE_DUO_STATE_CHANGE_PATH"], "Run the Playground matrix to build the external state operator.")
        try #require(FileManager.default.isExecutableFile(atPath: stateOperator))
        let artifacts = try #require(environment["AXE_E2E_ARTIFACT_DIR"], "Set the matrix artifact directory.")
        directory = URL(fileURLWithPath: artifacts).appendingPathComponent(gesture.rawValue + "-" + change.rawValue)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func run() async throws {
        let app = try DuoPlaygroundSession()
        let original = try await app.catalogue()
        var before = try await app.position(.open, rotation: 90, boot: original.bootIdentity)
        try #require(try before.activePanel.rotationDegrees() == 90)
        let pid = try await app.launch(screen: "touch-monitor")
        before = try await app.catalogue(boot: original.bootIdentity)
        let fresh = try await snapshot(catalogue: before, pid: pid)
        let pad = try #require(UIStateParser.findElement(in: fresh.roots, withIdentifier: "touch-monitor-pad"))
        let frame = try #require(pad.frame)
        let geometry = try InterruptedGeometry(gesture: gesture, frame: frame)
        let monitor = try await PlaygroundTouchMonitor(udid: udid, pid: pid)
        let baseline = try monitor.read()
        try #require(baseline.activeContacts.isEmpty && baseline.events.isEmpty && baseline.buttonTapCount == 0)
        try save(geometry, name: "planned-geometry")
        try save(baseline, name: "before-input")
        let input = try PlaygroundTestProcess(executable: cli,
            arguments: geometry.arguments + selection(before) + ["--udid", udid], directory: directory, name: "input")
        let panel = before.activePanel.identity
        let external = try PlaygroundTestProcess(executable: stateOperator,
            arguments: [change.rawValue, before.bootIdentity, String(panel.displayID), panel.uniqueID.uuidString, "0",
                directory.appendingPathComponent("state-change-marker.json").path, udid],
            directory: directory, name: "external-change")
        do {
            try input.start()
            let held = try await monitor.waitFor("live \(gesture.rawValue) contacts before \(change.rawValue)", while: input) {
                try witness($0, baseline: baseline, geometry: geometry)
            }
            try save(held, name: "contacts-before-change")
            try #require(input.isRunning, "Input ended before the external change.")
            try external.start()
            try await external.wait(timeout: 20)
            let externalDiagnostics = try external.diagnostics()
            try #require(external.exitCode == 0, "External change failed: \(externalDiagnostics)")
            let changed = try JSONDecoder().decode(ExternalStateReceipt.self, from: Data(try external.output().utf8))
            try await input.wait(timeout: 15)
            try #require(input.exitCode != 0, "The original input continued to normal completion.")
            let response: DuoCLIResponse = try input.receipt(DuoCLIResponse.self)
            try requireOwnedRelease(response, original: fresh.context)
            let released = try await monitor.waitFor("all original contacts released") { $0.activeContacts.isEmpty }
            try requireTerminalContacts(released, held: held, baseline: baseline, geometry: geometry)
            try save(released, name: "after-release")
            try await Task.sleep(nanoseconds: 500_000_000)
            let settled = try monitor.read()
            try #require(settled.generation == baseline.generation && settled.activeContacts.isEmpty
                && settled.events == released.events && settled.buttonTapCount == 0,
                "Input continued after the owned release or caused a button action.")
            try save(settled, name: "settled-release")
            let after = try await app.catalogue(boot: before.bootIdentity)
            try requireLayoutChange(changed, before: before, after: after)
            try await freshTap(catalogue: after, pid: pid, monitor: monitor, baseline: settled, original: fresh.context)
            print("Duo interruption passed: \(gesture.rawValue), \(change.rawValue), contacts=\(gesture.contactCount), "
                + "eventsSent=\(response.enqueuedEventCount)/\(gesture.normalEventCount), cleanup=\(response.cleanup), "
                + "screen=\(before.activePanel.identity.displayID)->\(after.activePanel.identity.displayID), "
                + "rotation=\(before.activePanel.currentOrientation)->\(after.activePanel.currentOrientation)")
        } catch {
            await external.finish()
            await input.finish()
            throw error
        }
        await external.finish()
        await input.finish()
    }

    private func witness(_ value: PlaygroundContactSnapshot, baseline: PlaygroundContactSnapshot,
                         geometry: InterruptedGeometry) throws -> Bool {
        try #require(value.generation == baseline.generation && value.buttonTapCount == 0)
        let contacts = traces(value)
        guard value.activeContacts.count == gesture.contactCount, contacts.count == gesture.contactCount else { return false }
        for (index, rows) in contacts.enumerated() {
            let first = try #require(rows.first)
            try #require(first.phase == "began" && first.contactID > 0 && geometry.starts[index].distance(from: first) < 2)
            try #require(!rows.contains { ["ended", "cancelled"].contains($0.phase) }, "A contact ended before layout change.")
            if gesture != .hold {
                guard rows.contains(where: { $0.phase == "moved" && geometry.starts[index].distance(from: $0) > 2 }) else { return false }
                if gesture == .pinch {
                    let last = try #require(rows.last)
                    guard (last.x - first.x) * (index == 0 ? -1 : 1) > 2 else { return false }
                }
            }
        }
        return Set(value.activeContacts) == Set(contacts.compactMap { $0.first?.contactID })
    }

    private func requireOwnedRelease(_ response: DuoCLIResponse, original: DuoContext) throws {
        try #require(response.outcome == "failedNoReplay" && response.error?.contains("staleContext") == true,
            "The original path was not stopped by the layout change.")
        try #require(response.context == original, "The interruption receipt lost its original measured display.")
        try #require(response.cleanup == "releaseEnqueuedAndDrained" && response.quarantine == nil,
            "The owned release was not confirmed.")
        if gesture == .hold {
            try #require(response.enqueuedEventCount == 1, "A normal UP was sent instead of interruption cleanup.")
        } else {
            try #require(response.enqueuedEventCount >= 2 && response.enqueuedEventCount < gesture.normalEventCount,
                "The original path did not stop before its final event.")
        }
    }

    private func requireTerminalContacts(_ value: PlaygroundContactSnapshot, held: PlaygroundContactSnapshot,
                                         baseline: PlaygroundContactSnapshot, geometry: InterruptedGeometry) throws {
        try #require(value.generation == baseline.generation && value.buttonTapCount == 0 && value.events.count < 512,
            "The original contact log was replaced or truncated.")
        let beforeContacts = traces(held)
        let afterContacts = traces(value)
        try #require(afterContacts.count == gesture.contactCount && beforeContacts.count == gesture.contactCount)
        for (index, rows) in afterContacts.enumerated() {
            let first = try #require(rows.first)
            let last = try #require(rows.last)
            try #require(first.contactID == beforeContacts[index].first?.contactID)
            try #require(["ended", "cancelled"].contains(last.phase)
                && rows.filter({ ["ended", "cancelled"].contains($0.phase) }).count == 1,
                "Each original contact must have one terminal event.")
            try #require(rows.starts(with: beforeContacts[index]), "The original contact history changed.")
            if gesture != .hold {
                try #require(rows.filter({ $0.phase == "moved" }).allSatisfy { geometry.ends[index].distance(from: $0) > 3 },
                    "The interrupted path reached an old endpoint.")
            }
        }
    }

    private func requireLayoutChange(_ value: ExternalStateReceipt, before: DuoCatalogue, after: DuoCatalogue) throws {
        try #require(value.mode == change.rawValue && value.finishedUptime >= value.startedUptime)
        if change == .fold {
            let hinge = try #require(value.hinge)
            try #require(hinge.outcome == "observedMechanicalTarget" && !hinge.wasAlreadyWithinTolerance
                && hinge.requestedDegrees == 0 && hinge.matchingSamples.count == 2
                && hinge.matchingSamples.allSatisfy { abs($0.mechanicalDegrees) <= 0.5 })
            try #require(after.activePanel.identity != before.activePanel.identity, "Folding did not switch to the outer screen.")
        } else {
            let rotation = try #require(value.rotation)
            try #require(rotation.vendorEventCount == 1 && rotation.matchingObservationCount == 2
                && rotation.before.rotation != rotation.after.rotation)
            try #require(after.activePanel.identity == before.activePanel.identity
                && (try after.activePanel.rotationDegrees()) == rotation.after.rotation,
                "Rotation did not change the measured inner-screen orientation.")
        }
    }

    private func freshTap(catalogue: DuoCatalogue, pid: Int32, monitor: PlaygroundTouchMonitor,
                          baseline: PlaygroundContactSnapshot, original: DuoContext) async throws {
        let fresh = try await snapshot(catalogue: catalogue, pid: pid)
        try #require(fresh.context != original, "A fresh lookup did not observe the changed layout.")
        let button = try #require(UIStateParser.findElement(in: fresh.roots, withIdentifier: "touch-monitor-button"))
        try #require(button.type == "Button" && button.enabled == true)
        let response: DuoCLIResponse = try await command([
            "tap", "--id", "touch-monitor-button", "--element-type", "Button", "--tap-style", "physical",
            "--expected-pid", String(pid),
        ] + selection(catalogue), name: "fresh-tap")
        try response.requireSuccess("enqueuedAndDrained")
        try #require(response.enqueuedEventCount == 2 && response.cleanup == "notNeeded" && response.context == fresh.context)
        let validation = try #require(response.ax?.validation)
        try #require(validation.expectedPID == pid && validation.frontmostPID == pid && validation.hitPID == pid
            && (validation.confirmedHitPID == nil || validation.confirmedHitPID == pid)
            && validation.verifiedTarget.identifier == "touch-monitor-button")
        let result = try await monitor.waitFor("one fresh real button callback") { $0.buttonTapCount == 1 }
        try #require(result.generation == baseline.generation && result.activeContacts.isEmpty && result.events == baseline.events,
            "The fresh tap changed pad contacts or left input held.")
        try save(result, name: "fresh-button-callback")
        let observed = try await snapshot(catalogue: catalogue, pid: pid)
        try #require(UIStateParser.findElement(in: observed.roots, withIdentifier: "touch-monitor-tap-count")?.value == "1")
    }

    private func snapshot(catalogue: DuoCatalogue, pid: Int32) async throws -> DuoSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var attempt = 0
        var expectedContext: DuoContext?
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            let response = try await command(["describe-ui", "--expected-pid", String(pid)] + selection(catalogue),
                name: "description-\(attempt)", timeout: remaining, notReadyPID: pid)
            try #require(ProcessInfo.processInfo.systemUptime < deadline, "The read exceeded the existing readiness deadline.")
            let context = try #require(response.context)
            try context.requireMatch(catalogue)
            if let expectedContext {
                try #require(context == expectedContext, "Readiness changed the measured context.")
            } else {
                expectedContext = context
            }
            let ax = try #require(response.ax)
            try #require(ax.schemaVersion == 1 && ax.kind == "describe" && ax.expectedPID == pid)
            if ax.acquisition?.outcome != .notReady, ax.acquisition?.outcome != .processChanged {
                try response.requireSuccess("ready")
                try #require(ax.failure == nil && ax.acquisition?.outcome == .ready)
                let roots = try #require(ax.roots)
                if UIStateParser.findElement(in: roots, withIdentifier: "touch-monitor-pad") != nil,
                   UIStateParser.findElement(in: roots, withIdentifier: "touch-monitor-button") != nil {
                    return DuoSnapshot(context: context, roots: roots)
                }
            }
            attempt += 1
            let pause = min(0.1, deadline - ProcessInfo.processInfo.systemUptime)
            if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        }
        throw TestError.unexpectedState("The visible touch-monitor page did not appear.")
    }

    private func command(_ arguments: [String], name: String, timeout: TimeInterval = 35,
                         notReadyPID: Int32? = nil) async throws -> DuoCLIResponse {
        let operation = try PlaygroundTestProcess(executable: cli, arguments: arguments + ["--udid", udid],
            directory: directory, name: name + "-" + UUID().uuidString)
        do {
            try operation.start()
            try await operation.wait(timeout: timeout)
            let commandDiagnostics = try operation.diagnostics()
            let response = try operation.receipt(DuoCLIResponse.self)
            if let notReadyPID, response.isForegroundNotYetOwned(by: notReadyPID, exitCode: operation.exitCode) {
                try #require(arguments.first == "describe-ui")
            } else if let notReadyPID, response.ax?.acquisition?.outcome == .notReady {
                let ax = try #require(response.ax)
                let acquisition = try #require(ax.acquisition)
                try #require(arguments.first == "describe-ui" && operation.exitCode == 1)
                try #require(response.outcome == "failedBeforeInput" && response.enqueuedEventCount == 0
                    && response.cleanup == "notNeeded" && response.quarantine == nil && response.error?.isEmpty == false)
                try #require(ax.schemaVersion == 1 && ax.kind == "describe" && ax.expectedPID == notReadyPID
                    && ax.failure == .acquisitionFailed && acquisition.failureDescription == nil)
                try #require(!acquisition.attempts.isEmpty && acquisition.attempts.allSatisfy {
                    $0.rootPID == notReadyPID && $0.outcome == .notReady
                })
            } else {
                try #require(operation.exitCode == 0, "AXe command failed: \(commandDiagnostics)")
            }
            await operation.finish()
            return response
        } catch {
            await operation.finish()
            throw error
        }
    }

    private func selection(_ catalogue: DuoCatalogue) -> [String] {
        ["--input-mode", "selected", "--screen-id", String(catalogue.activePanel.identity.displayID),
         "--screen-uuid", catalogue.activePanel.identity.uniqueID.uuidString, "--verbose"]
    }

    private func traces(_ value: PlaygroundContactSnapshot) -> [[PlaygroundContactEvent]] {
        Dictionary(grouping: value.events, by: \.contactID).values.sorted { ($0.first?.x ?? 0) < ($1.first?.x ?? 0) }
    }

    private func save<Value: Encodable>(_ value: Value, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
    }
}

private struct ExternalStateReceipt: Decodable {
    let mode: String
    let startedUptime: TimeInterval
    let finishedUptime: TimeInterval
    let hinge: Hinge?
    let rotation: DuoCLIResponse.RotationReceipt?

    struct Hinge: Decodable {
        let outcome: String
        let requestedDegrees: Double
        let wasAlreadyWithinTolerance: Bool
        let matchingSamples: [DuoCLIResponse.HingeSample]
    }
}
