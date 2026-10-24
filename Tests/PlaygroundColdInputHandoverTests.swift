import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Playground Cold Raw Broker E2E", .serialized, .enabled(if: isE2EEnabled && !isDuoPlaygroundE2EEnabled))
struct PlaygroundColdInputHandoverTests {
    @Test("A cold raw broker refuses input while a selected contact is held")
    func coldSelectedRetainedContactBlocksRaw() async throws {
        let setupDeadline = ProcessInfo.processInfo.systemUptime + 75
        let root = try #require(ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"])
        let preparation = URL(fileURLWithPath: root).appendingPathComponent("cold-preparation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: preparation, withIntermediateDirectories: true)
        try await Self.prepareColdBroker(deadline: setupDeadline, directory: preparation, name: "before-ui")
        try Self.requireSetupTime(setupDeadline)
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "cold-raw-handover", position: .outer0)
        try Self.requireSetupTime(setupDeadline)
        try await session.show("feature.showPad")
        try Self.requireSetupTime(setupDeadline)
        try await Self.prepareColdBroker(deadline: setupDeadline, directory: preparation, name: "before-down")
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element("feature.pad", in: state))
        let point = (x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        let coordinates = ["-x", String(point.x), "-y", String(point.y)]
        let initial = try session.document.read()
        try initial.requireClear()
        try Self.requireSetupTime(setupDeadline)
        var token: UUID?
        var upAttempted = false
        var raw: PlaygroundTestProcess?
        do {
            let down = try await session.command(["touch", "--down"] + coordinates + session.selectedFlags, allowFailure: true)
            let receipt = try session.rawReceipt(down.output)
            token = receipt.token
            try #require(down.exitCode == 0 && receipt.outcome == "retained" && receipt.enqueuedEventCount == 1
                && receipt.cleanup == "notNeeded" && receipt.error == nil && receipt.quarantine == nil)
            let owned = try #require(token)
            let held = try await session.document.waitFor("selected contact before the first raw broker request") {
                $0.activeWindowTouches == 1 && $0.windowTouchTrace.count > initial.windowTouchTrace.count
            }
            let began = Array(held.windowTouchTrace.dropFirst(initial.windowTouchTrace.count))
            try #require(began.count == 1 && began[0].phase == "windowTouchBegan" && began[0].hitView == "feature.pad")
            let name = "cold-raw-refusal-" + UUID().uuidString
            let argv = ["touch", "--down", "--up"] + coordinates + ["--udid", session.agent.udid]
            try JSONEncoder().encode(argv).write(to: session.artifacts.appendingPathComponent(name + "-argv.json"))
            try Data(contentsOf: session.document.url).write(to: session.artifacts.appendingPathComponent(name + "-before.json"))
            let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: argv,
                directory: session.artifacts, name: name)
            raw = process
            try process.start()
            do {
                try await process.wait(timeout: 8)
            } catch {
                // Bound only this client. Do not let a startup wait reach the retained idle release.
                await Self.stopOwnedClient(process)
                let elapsed = ProcessInfo.processInfo.systemUptime - process.startedUptime
                let exitCode: Int32? = process.isRunning ? nil : process.exitCode
                try? JSONEncoder().encode(ColdRawRefusalRecord(exitCode: exitCode, elapsedSeconds: elapsed, timedOut: true))
                    .write(to: session.artifacts.appendingPathComponent(name + "-result.json"))
                try? Data(contentsOf: session.document.url).write(to: session.artifacts.appendingPathComponent(name + "-after-stop.json"))
                throw error
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - process.startedUptime
            let stdout = try process.output()
            let diagnostics = try process.diagnostics()
            try JSONEncoder().encode(ColdRawRefusalRecord(exitCode: process.exitCode, elapsedSeconds: elapsed, timedOut: false))
                .write(to: session.artifacts.appendingPathComponent(name + "-result.json"))
            try Data(contentsOf: session.document.url).write(to: session.artifacts.appendingPathComponent(name + "-after.json"))
            try #require(elapsed < 10 && process.exitCode != 0 && stdout.isEmpty
                && !diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            await process.finish()
            let stillHeld = try session.document.read()
            try #require(stillHeld.activeWindowTouches == 1 && stillHeld.windowTouchTrace == held.windowTouchTrace)
            try #require(stillHeld.pid == initial.pid && stillHeld.generation == initial.generation)

            upAttempted = true
            let up = try await session.command(["touch", "--up", "--contact-token", owned.uuidString]
                + coordinates + session.selectedFlags)
            let ended = try session.rawReceipt(up.output)
            try #require(up.exitCode == 0 && ended.outcome == "endedAndDrained" && ended.enqueuedEventCount == 2
                && ended.cleanup == "notNeeded" && ended.error == nil && ended.quarantine == nil)
            let released = try await session.document.waitFor("matching selected UP after cold raw refusal") { $0.activeWindowTouches == 0 }
            let groups = try controlsContactGroups(released, before: initial, expected: 1)
            let rows = try #require(groups.first)
            try #require(rows.first?.contactID == began[0].contactID && rows.last?.contactID == began[0].contactID)
            let current = try await session.core.state()
            let button = try session.core.frame(of: session.core.element("feature.tap", in: current))
            let beforeTap = try session.document.read()
            _ = try await session.rawCommand(["touch", "--down", "--up", "-x", String(button.x + button.width / 2),
                "-y", String(button.y + button.height / 2)])
            try await session.requireButtonTap(after: beforeTap)
        } catch {
            if let raw { await Self.stopOwnedClient(raw) }
            if let token, !upAttempted {
                do {
                    _ = try await session.command(["touch", "--up", "--contact-token", token.uuidString]
                        + coordinates + session.selectedFlags)
                    _ = try await session.document.waitFor("matching selected UP during cold-proof cleanup") { $0.activeWindowTouches == 0 }
                } catch { Issue.record("Cold-proof matching UP cleanup failed: \(error)") }
            } else if upAttempted {
                do { _ = try await session.document.waitFor("release after the one selected UP attempt") { $0.activeWindowTouches == 0 } }
                catch { Issue.record("The selected UP attempt did not prove release: \(error)") }
            } else {
                Issue.record("Selected DOWN supplied no usable token; matching UP is unavailable.")
            }
            throw error
        }
    }

    private static func stopOwnedClient(_ process: PlaygroundTestProcess) async {
        if process.isRunning {
            do { try process.signal(SIGTERM); try await process.wait(timeout: 2) }
            catch {
                if process.isRunning {
                    do { try process.signal(SIGKILL); try await process.wait(timeout: 2) }
                    catch { Issue.record("The bounded cold-proof CLI did not stop: \(error)") }
                }
            }
        }
        await process.finish()
    }

    private static func requireSetupTime(_ deadline: TimeInterval) throws {
        try #require(ProcessInfo.processInfo.systemUptime < deadline, "Cold-test setup exceeded its shared 75-second allowance before DOWN.")
    }

    private static func prepareColdBroker(deadline: TimeInterval, directory: URL, name: String) async throws {
        try requireSetupTime(deadline)
        let driver = try #require(ProcessInfo.processInfo.environment["AXE_COLD_BROKER_PREFLIGHT_PATH"])
        let developer = try #require(ProcessInfo.processInfo.environment["DEVELOPER_DIR"])
        let receipt = directory.appendingPathComponent(name + ".json")
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        let process = try PlaygroundTestProcess(executable: "/usr/bin/python3", arguments: [driver,
            "--cli", try TestHelpers.getAxePath(), "--udid", try TestHelpers.requireSimulatorUDID(),
            "--developer-directory", developer, "--wait-seconds", String(remaining), "--out", receipt.path],
            directory: directory, name: name)
        try process.start()
        do {
            try await process.wait(timeout: remaining + 1)
            let output = try process.output()
            try #require(process.exitCode == 0, "Read-only cold preflight failed: \(output)")
            await process.finish()
        } catch {
            await process.finish()
            throw error
        }
        try requireSetupTime(deadline)
        try requireColdPreflight(file: receipt.path)
    }

    private static func requireColdPreflight(file: String) throws {
        let receipt = try JSONDecoder().decode(ColdBrokerPreflight.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let cli = URL(fileURLWithPath: try TestHelpers.getAxePath()).resolvingSymlinksInPath().path
        let actualHash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: cli))).map { String(format: "%02x", $0) }.joined()
        let developer = try #require(ProcessInfo.processInfo.environment["DEVELOPER_DIR"])
        let currentDeveloper = URL(fileURLWithPath: developer).resolvingSymlinksInPath().path
        let currentTempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("axe-hid-" + String(getuid())).path
        let recordedTempRoot = URL(fileURLWithPath: receipt.tempRoot).resolvingSymlinksInPath().path
        let age = Date().timeIntervalSince1970 - receipt.checkedUnixSeconds
        try #require(receipt.schemaVersion == 1, "Cold preflight schema differs: \(receipt.schemaVersion).")
        try #require(receipt.status == "COLD_BROKER_ABSENT" && !receipt.brokerAlive,
            "Cold preflight did not prove broker absence: \(receipt.status).")
        try #require(!receipt.legacyBrokerAlive && !receipt.commonLeaseHeld, "Cold preflight input ownership is not clear.")
        try #require(receipt.protocolVersion == 3, "Cold broker protocol differs: \(receipt.protocolVersion).")
        try #require(receipt.cliPath == cli, "Cold CLI path differs: recorded=\(receipt.cliPath), current=\(cli).")
        try #require(receipt.cliSHA256 == actualHash,
            "Cold CLI hash differs: recorded=\(receipt.cliSHA256), current=\(actualHash).")
        try #require(receipt.developerDirectory == currentDeveloper,
            "Cold developer directory differs: recorded=\(receipt.developerDirectory), current=\(currentDeveloper).")
        try #require(recordedTempRoot == currentTempRoot,
            "Cold temp root differs: recorded=\(receipt.tempRoot), normalized=\(recordedTempRoot), current=\(currentTempRoot).")
        let currentUDID = try TestHelpers.requireSimulatorUDID()
        try #require(receipt.udid == currentUDID, "Cold simulator differs: recorded=\(receipt.udid), current=\(currentUDID).")
        try #require(age >= 0 && age < 30, "Cold preflight age is outside 0..<30 seconds: \(age).")
        try #require(!receipt.inputSent && !receipt.brokerConnected && !receipt.processStopped,
            "Cold preflight changed a process or connected to input.")
    }
}

private struct ColdBrokerPreflight: Decodable {
    let schemaVersion: Int
    let status: String
    let cliPath: String
    let cliSHA256: String
    let udid: String
    let developerDirectory: String
    let tempRoot: String
    let protocolVersion: Int
    let brokerAlive: Bool
    let legacyBrokerAlive: Bool
    let commonLeaseHeld: Bool
    let checkedUnixSeconds: Double
    let inputSent: Bool
    let brokerConnected: Bool
    let processStopped: Bool
}

private struct ColdRawRefusalRecord: Encodable {
    let exitCode: Int32?
    let elapsedSeconds: Double
    let timedOut: Bool
}
