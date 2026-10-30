import Darwin
import Foundation
import Testing

/// Run alone against a warm simulator. AXE_BIN_PATH must identify the actual CLI binary.
@Suite("Playground Agent Broker Restart E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentBrokerRestartTests {
    @Test("Broker exit loses old references safely and a fresh reference taps the button")
    func brokerRestartInvalidatesReferences() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "lifecycle-broker-restart",
            position: isDuoPlaygroundE2EEnabled ? .inner90 : .outer0)
        let initial = try await session.capture()
        let before = try session.document.read()
        try before.requireClear()
        let binary = URL(fileURLWithPath: try TestHelpers.getAxePath()).resolvingSymlinksInPath().path
        let owned = try await broker(binary: binary, udid: session.agent.udid)

        // Confirm this broker still owns the capture and has no native action in flight.
        let validated = try await session.command(["describe-ui", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", initial.capture.snapshotID.uuidString])
        let current = try session.decodeAgent(validated.output)
        try #require(!current.didError && current.data.action == nil && current.data.capture?.snapshotID == initial.capture.snapshotID)
        try #require(try session.document.read().inputState == before.inputState)
        let checked = try await broker(binary: binary, udid: session.agent.udid, pid: owned.pid)
        try #require(checked == owned, "The broker process identity changed before termination.")
        try save(owned, in: session, name: "broker-before-signal")
        try initial.requireUnexpired("before owned broker termination")

        // Recheck the kernel identity immediately before signalling this one idle worker.
        try #require(try session.document.read().inputState == before.inputState)
        let immediate = try #require(identity(owned.pid))
        try #require(immediate == owned && immediate.uid == getuid() && immediate.realUID == getuid())
        try #require(Darwin.kill(owned.pid, SIGTERM) == 0, "Cannot stop the identified idle broker.")
        try await waitForExit(owned)
        try initial.requireUnexpired("after owned broker exit")
        try #require(try session.document.read().inputState == before.inputState)

        let ref = try session.reference("feature.tap", in: initial.capture)
        let stale = try await session.command(["tap", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", initial.capture.snapshotID.uuidString, "--ref", ref, "--tap-style", "physical"], allowFailure: true)
        let refusal = try session.decodeAgent(stale.output)
        try #require(stale.exitCode != 0 && refusal.didError && refusal.error?.code == "snapshotMissing")
        try #require(refusal.data.action == nil && refusal.data.capture == nil && refusal.data.cache.requiresRefresh)
        try #require(try session.document.read().inputState == before.inputState,
            "An old broker reference changed app state or touch history.")
        let replacement = try await broker(binary: binary, udid: session.agent.udid)
        try #require(replacement != owned, "The request did not use a replacement broker process.")
        try save(replacement, in: session, name: "broker-replacement")

        let fresh = try await session.capture()
        try #require(fresh.capture.snapshotID != initial.capture.snapshotID)
        let tapped = try await session.command(["tap"] + (try session.contextArguments(fresh, identifier: "feature.tap"))
            + ["--tap-style", "physical"])
        try session.requireHIDSuccess(tapped, kind: "tap", events: 2)
        try await session.requireButtonTap(after: before)
    }

    private func broker(binary: String, udid: String, pid: pid_t? = nil) async throws -> BrokerIdentity {
        let command = pid.map { "/bin/ps -ww -p \($0) -o pid=,uid=,args=" }
            ?? "/bin/ps -ww -axo pid=,uid=,args="
        let output = try await CommandRunner.run(command, timeout: 5)
        let expectedCommand = binary + " hid-broker --selected --udid " + udid
        let rows = output.output.split(separator: "\n").compactMap { line -> pid_t? in
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let candidate = pid_t(fields[0]), candidate > 1,
                  let uid = uid_t(fields[1]), uid == getuid(), String(fields[2]) == expectedCommand else { return nil }
            return candidate
        }
        try #require(rows.count == 1, "Cannot identify exactly one broker for this binary and simulator; no signal was sent.")
        let candidate = try #require(rows.first)
        let observed = try #require(identity(candidate), "Cannot read the selected broker kernel identity.")
        try #require(observed.uid == getuid() && observed.realUID == getuid() && observed.binary == binary,
            "The selected broker does not have the expected user and executable; no signal was sent.")
        return observed
    }

    private func identity(_ pid: pid_t) -> BrokerIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let bytes = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard bytes > 0 else { return nil }
        let executable = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let binary = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        return BrokerIdentity(pid: pid, uid: info.pbi_uid, realUID: info.pbi_ruid,
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, binary: binary)
    }

    private func waitForExit(_ owned: BrokerIdentity) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(owned.pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                if info.pbi_start_tvsec != owned.startSeconds || info.pbi_start_tvusec != owned.startMicroseconds { return }
            } else if Darwin.kill(owned.pid, 0) == -1 && errno == ESRCH {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("The identified broker did not exit after SIGTERM; no further signal was sent.")
    }

    private func save(_ identity: BrokerIdentity, in session: PlaygroundAgentFeatureSession, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(identity).write(to: session.artifacts.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
    }
}

private struct BrokerIdentity: Codable, Equatable {
    let pid: pid_t
    let uid: uid_t
    let realUID: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let binary: String
}
