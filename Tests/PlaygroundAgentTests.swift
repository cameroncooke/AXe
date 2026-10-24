import Foundation
import Testing

/// Run this suite alone; each case owns the simulator's foreground app.
@Suite("Playground Optional Agent E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentTests {
    @Test("Fresh capture has compact RS/1 rows and raw describe-ui stays raw")
    func compactCaptureAndRawCompatibility() async throws {
        let app = try AgentPlaygroundSession()
        let pid = try await app.open("slider-value-test", readyID: "slider-value-button")
        let result = try await app.capture(pid: pid)
        let capture = try #require(result.data.capture)

        #expect(result.schema == "axe.output.agent-result")
        #expect(result.schemaVersion == "1")
        #expect(!result.didError)
        #expect(result.data.action == nil)
        #expect(!result.data.cache.requiresRefresh)
        #expect(capture.type == "runtime-snapshot")
        #expect(capture.rs == "1")
        #expect(capture.applicationPID == pid)
        #expect(UUID(uuidString: capture.udid) == UUID(uuidString: app.udid))
        #expect(capture.count > 0 && capture.seq > 0)
        #expect(!capture.screenHash.isEmpty)
        #expect(capture.expiresInSeconds > 0 && capture.expiresInSeconds <= 60)
        #expect(capture.targets.count <= 64 && capture.scroll.count <= 64 && capture.text.count <= 64)
        for row in capture.targets + capture.scroll + capture.text {
            _ = try AgentPlaygroundRow(row)
        }
        let button = try capture.target(id: "slider-value-button")
        #expect(button.action == "tap")
        #expect(button.label == "Slider Value Button")

        let raw = try await app.run(["describe-ui"])
        #expect(raw.exitCode == 0)
        #expect(!raw.output.contains("axe.output.agent-result"))
        let roots = try UIStateParser.parseDescribeUIRoots(raw.output)
        let application = try #require(roots.first { $0.type == "Application" && $0.label == "AxePlayground" })
        #expect(UIStateParser.findElement(in: application, withIdentifier: "slider-value-button") != nil)
        let stateIDs = [
            "slider-value-state", "slider-exact-value-state", "slider-percent-state", "slider-value-slider",
        ]
        let beforeValues = try stateIDs.map { identifier in
            try #require(UIStateParser.findElement(in: application, withIdentifier: identifier)?.value)
        }

        let reused = try await app.capture(pid: pid, sinceScreenHash: capture.screenHash)
        let reusedCapture = try #require(reused.data.capture)
        try #require(reused.data.action == nil)
        try #require(reused.data.cache.status == "reused")
        try #require(!reused.data.cache.requiresRefresh)
        try #require(reusedCapture.snapshotID == capture.snapshotID)
        try #require(reusedCapture.screenHash == capture.screenHash)
        try #require(reusedCapture.applicationPID == pid)
        try #require(reusedCapture.type == "runtime-snapshot-unchanged")
        try #require(reusedCapture.rs == capture.rs)
        try #require(reusedCapture.seq > capture.seq)
        try #require(reusedCapture.count == capture.count)
        try #require(reusedCapture.udid == capture.udid)
        try #require(reusedCapture.rowOffset == capture.rowOffset && reusedCapture.rowLimit == capture.rowLimit)
        try #require(reusedCapture.targetCount == capture.targetCount)
        try #require(reusedCapture.scrollCount == capture.scrollCount && reusedCapture.textCount == capture.textCount)
        try #require(reusedCapture.truncated == capture.truncated)
        try #require(reusedCapture.targets.isEmpty && reusedCapture.scroll.isEmpty && reusedCapture.text.isEmpty)

        let afterRaw = try await app.run(["describe-ui"])
        #expect(afterRaw.exitCode == 0)
        let afterRoots = try UIStateParser.parseDescribeUIRoots(afterRaw.output)
        let afterApplication = try #require(afterRoots.first { $0.type == "Application" && $0.label == "AxePlayground" })
        let afterValues = try stateIDs.map { identifier in
            try #require(UIStateParser.findElement(in: afterApplication, withIdentifier: identifier)?.value)
        }
        try #require(afterValues == beforeValues)

        let tapped = try await app.tap(button.ref, snapshot: capture.snapshotID, pid: pid)
        let action = try #require(tapped.data.action)
        #expect(action.kind == "tap" && action.outcome == "enqueuedAndDrained")
        #expect(action.enqueuedEventCount > 0 && action.cleanup != "uncertain" && !action.replayed)
        try await app.waitForValue("slider-value-state", equals: "Tapped")
    }

    @Test("A saved snapshot reference taps the actual button")
    func savedReferenceTap() async throws {
        let app = try AgentPlaygroundSession()
        let pid = try await app.open("slider-value-test", readyID: "slider-value-button")
        try await app.waitForValue("slider-value-state", equals: "Initial")
        let capture = try #require(try await app.capture(pid: pid).data.capture)
        let button = try capture.target(id: "slider-value-button")

        let result = try await app.tap(button.ref, snapshot: capture.snapshotID, pid: pid)
        #expect(!result.didError)
        let action = try #require(result.data.action)
        #expect(action.kind == "tap")
        #expect(action.outcome == "enqueuedAndDrained")
        #expect(action.enqueuedEventCount > 0)
        #expect(action.cleanup != "uncertain")
        #expect(!action.replayed)
        try await app.waitForValue("slider-value-state", equals: "Tapped")
    }

    @Test("Relaunch rejects the old snapshot without tapping the new app")
    func relaunchInvalidatesReference() async throws {
        let app = try AgentPlaygroundSession()
        let oldPID = try await app.open("slider-value-test", readyID: "slider-value-button")
        let old = try await app.timedCapture(pid: oldPID)
        let oldButton = try old.capture.target(id: "slider-value-button")
        let newPID = try await app.open("slider-value-test", readyID: "slider-value-button")
        try #require(newPID != oldPID, "The app did not receive a new PID after relaunch.")

        try await app.requireRefusal(oldButton.ref, capture: old, pid: newPID)
        try await app.waitForValue("slider-value-state", equals: "Initial")
        let fresh = try await app.timedCapture(pid: newPID)
        #expect(fresh.capture.snapshotID != old.capture.snapshotID)
        let button = try fresh.capture.target(id: "slider-value-button")
        try old.requireUnexpired("before fresh reference input after relaunch")
        try fresh.requireUnexpired("before fresh reference input after relaunch")
        _ = try await app.tap(button.ref, snapshot: fresh.capture.snapshotID, pid: newPID)
        try await app.waitForValue("slider-value-state", equals: "Tapped")
        try old.requireUnexpired("after app recovery from relaunch")
        try fresh.requireUnexpired("after app recovery from relaunch")
    }

    @Test("A changed layout rejects saved input and a fresh reference works")
    func changedLayoutInvalidatesReference() async throws {
        let app = try AgentPlaygroundSession()
        let pid = try await app.open("batch-test", readyID: "batch-delayed-trigger")
        let old = try await app.timedCapture(pid: pid)
        let oldButton = try old.capture.target(id: "batch-delayed-trigger")

        _ = try await app.run(["tap", "--id", "batch-state-change-trigger"])
        try await app.waitForValue("batch-current-state", equals: "State changed")
        _ = try await app.waitFor("new State Target button") {
            UIStateParser.findElement(in: $0, withIdentifier: "batch-state-target") != nil
        }
        try await app.requireRefusal(oldButton.ref, capture: old, pid: pid)
        try await app.waitForValue("batch-current-state", equals: "State changed")

        let fresh = try await app.timedCapture(pid: pid)
        #expect(fresh.capture.snapshotID != old.capture.snapshotID)
        let button = try fresh.capture.target(id: "batch-state-target")
        try old.requireUnexpired("before fresh reference input after layout change")
        try fresh.requireUnexpired("before fresh reference input after layout change")
        _ = try await app.tap(button.ref, snapshot: fresh.capture.snapshotID, pid: pid)
        try await app.waitForValue("batch-current-state", equals: "State target tapped")
        try old.requireUnexpired("after app recovery from layout change")
        try fresh.requireUnexpired("after app recovery from layout change")
    }
}

struct AgentPlaygroundSession {
    let udid: String
    private let axePath: String

    init() throws {
        udid = try TestHelpers.requireSimulatorUDID()
        axePath = try TestHelpers.getAxePath()
    }

    func run(_ arguments: [String], allowFailure: Bool = false) async throws -> CommandOutput {
        let command = ([axePath] + arguments + ["--udid", udid]).map(Self.quote).joined(separator: " ")
        let result = try await CommandRunner.run(command, allowFailure: allowFailure, timeout: 30)
        return CommandOutput(output: result.output, exitCode: result.exitCode)
    }

    func open(_ screen: String, readyID: String) async throws -> Int32 {
        let arguments = [
            "xcrun", "simctl", "launch", "--terminate-running-process", udid,
            "com.cameroncooke.AxePlayground", "--launch-arg", "screen=\(screen)",
        ]
        let launch = try await CommandRunner.run(arguments.map(Self.quote).joined(separator: " "), timeout: 30)
        let line = launch.output.split(separator: "\n").first { $0.hasPrefix("com.cameroncooke.AxePlayground:") }
        guard let pidText = line?.split(separator: ":").last,
              let pid = Int32(pidText.trimmingCharacters(in: .whitespaces)), pid > 0 else {
            throw TestError.unexpectedState("simctl launch returned no app PID.\n\(launch.output)")
        }
        _ = try await waitFor("screen \(screen), identifier \(readyID)") {
            UIStateParser.findElement(in: $0, withIdentifier: readyID) != nil
        }
        if try await DuoPlaygroundLaunchTarget.prepareIfNeeded() {
            _ = try await waitFor("screen \(screen), identifier \(readyID) after Duo orientation") {
                UIStateParser.findElement(in: $0, withIdentifier: readyID) != nil
            }
        }
        return pid
    }

    func capture(pid: Int32, sinceScreenHash: String? = nil) async throws -> AgentPlaygroundResult {
        var arguments = ["describe-ui", "--agent", "--expected-pid", String(pid)]
        if let sinceScreenHash {
            arguments += ["--since-screen-hash", sinceScreenHash]
        }
        let output = try await run(arguments)
        let result = try decode(output.output)
        try #require(!result.didError, "Agent capture failed: \(output.output)")
        return result
    }

    func timedCapture(pid: Int32) async throws -> AgentPlaygroundTimedCapture {
        let startedUptime = ProcessInfo.processInfo.systemUptime
        let result = try await capture(pid: pid)
        let capture = try #require(result.data.capture)
        let timed = try AgentPlaygroundTimedCapture(capture: capture, requestStartedUptime: startedUptime)
        try timed.requireUnexpired("after capture readback")
        return timed
    }

    func tap(_ ref: String, snapshot: UUID, pid: Int32) async throws -> AgentPlaygroundResult {
        let output = try await run(tapArguments(ref, snapshot: snapshot, pid: pid))
        let result = try decode(output.output)
        try #require(!result.didError, "Agent tap failed: \(output.output)")
        return result
    }

    func requireRefusal(_ ref: String, capture: AgentPlaygroundTimedCapture, pid: Int32) async throws {
        try capture.requireUnexpired("before stale reference refusal")
        let output = try await run(tapArguments(ref, snapshot: capture.capture.snapshotID, pid: pid), allowFailure: true)
        try capture.requireUnexpired("after stale reference refusal")
        let result = try decode(output.output)
        #expect(output.exitCode != 0, "Stale input succeeded: \(output.output)")
        #expect(result.didError)
        let failure = try #require(result.error, "Refusal has no typed reason: \(output.output)")
        #expect(["snapshotMissing", "contextChanged", "screenChanged"].contains(failure.code), "\(output.output)")
        #expect(result.data.action == nil, "Stale input reached a native action: \(output.output)")
        #expect(result.data.cache.requiresRefresh)
        #expect(result.data.capture == nil)
    }

    func waitForValue(_ identifier: String, equals expected: String) async throws {
        _ = try await waitFor("\(identifier)=\(expected)") {
            UIStateParser.findElement(in: $0, withIdentifier: identifier)?.value == expected
        }
    }

    func waitFor(_ description: String, matches: (UIElement) -> Bool) async throws -> UIElement {
        let deadline = Date().addingTimeInterval(10)
        var lastObserved = "No raw app state was read."
        repeat {
            do {
                let output = try await run(["describe-ui"])
                lastObserved = output.output
                let roots = try UIStateParser.parseDescribeUIRoots(output.output)
                if let app = roots.first(where: { $0.type == "Application" && $0.label == "AxePlayground" }), matches(app) {
                    return app
                }
            } catch {
                lastObserved = String(describing: error)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw TestError.unexpectedState("Timed out waiting for \(description).\n\(lastObserved)")
    }

    private func tapArguments(_ ref: String, snapshot: UUID, pid: Int32) -> [String] {
        ["tap", "--agent", "--expected-pid", String(pid), "--snapshot-id", snapshot.uuidString, "--ref", ref]
    }

    private func decode(_ output: String) throws -> AgentPlaygroundResult {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let result = try? JSONDecoder().decode(AgentPlaygroundResult.self, from: Data(line.utf8)) {
                return result
            }
        }
        throw TestError.invalidJSON("No axe.output.agent-result envelope.\n\(output)")
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct AgentPlaygroundResult: Decodable {
    struct Payload: Decodable {
        let capture: AgentPlaygroundCapture?
        let action: Action?
        let cache: Cache
    }
    struct Action: Decodable {
        let kind: String
        let outcome: String
        let enqueuedEventCount: Int
        let cleanup: String
        let replayed: Bool
    }
    struct Cache: Decodable {
        let status: String
        let requiresRefresh: Bool
    }
    struct Failure: Decodable {
        let code: String
    }
    let schema: String
    let schemaVersion: String
    let didError: Bool
    let error: Failure?
    let data: Payload
}

struct AgentPlaygroundCapture: Decodable {
    let type: String
    let rs: String
    let snapshotID: UUID
    let screenHash: String
    let seq: Int
    let count: Int
    let targets: [String]
    let scroll: [String]
    let text: [String]
    let udid: String
    let applicationPID: Int32
    let expiresInSeconds: Double
    let rowOffset: Int
    let rowLimit: Int
    let targetCount: Int
    let scrollCount: Int
    let textCount: Int
    let truncated: Bool

    func target(id: String) throws -> AgentPlaygroundRow {
        let rows = try targets.map(AgentPlaygroundRow.init)
        let matches = rows.filter { $0.identifier == id }
        guard matches.count == 1, let target = matches.first else {
            throw TestError.elementNotFound("Expected one compact target for \(id).\n\(targets.joined(separator: "\n"))")
        }
        return target
    }
}

struct AgentPlaygroundTimedCapture {
    let capture: AgentPlaygroundCapture
    private let requestStartedUptime: Double

    init(capture: AgentPlaygroundCapture, requestStartedUptime: Double) throws {
        guard requestStartedUptime.isFinite, capture.expiresInSeconds.isFinite,
              capture.expiresInSeconds > 0, capture.expiresInSeconds <= 60 else {
            throw TestError.unexpectedState("Snapshot \(capture.snapshotID) has no valid public lifetime: \(capture.expiresInSeconds)s.")
        }
        self.capture = capture
        self.requestStartedUptime = requestStartedUptime
    }

    func requireUnexpired(_ stage: String) throws {
        let elapsed = ProcessInfo.processInfo.systemUptime - requestStartedUptime
        // The public remaining lifetime is measured after this request began.
        // Counting from request start gives an earlier deadline and cannot hide expiry.
        guard elapsed.isFinite, elapsed >= 0, elapsed < capture.expiresInSeconds else {
            let age = String(format: "%.3f", elapsed)
            let budget = String(format: "%.3f", capture.expiresInSeconds)
            throw TestError.unexpectedState(
                "Snapshot \(capture.snapshotID) exceeded its conservative lifetime \(stage): "
                    + "elapsedSinceRequest=\(age)s, publicRemainingLifetime=\(budget)s. "
                    + "Transition invalidation coverage is inconclusive; input is not replayed."
            )
        }
    }
}

struct AgentPlaygroundRow {
    let ref: String
    let action: String
    let label: String
    let identifier: String

    init(_ row: String) throws {
        let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6, fields[0].first == "e", let number = Int(fields[0].dropFirst()), number > 0 else {
            throw TestError.invalidJSON("Invalid compact RS/1 row: \(row)")
        }
        ref = fields[0]
        action = fields[1]
        label = fields[3]
        identifier = fields[5]
    }
}
