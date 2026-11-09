import Darwin
import Foundation
import Testing

struct PlaygroundContactEvent: Codable, Equatable {
    let contactID: Int
    let phase: String
    let timestamp: TimeInterval
    let x: Double
    let y: Double
}

struct PlaygroundContactSnapshot: Codable {
    let generation: UUID
    let processIdentifier: Int32
    let sequence: Int
    let activeContacts: [Int]
    let events: [PlaygroundContactEvent]
    let buttonTapCount: Int
}

struct PlaygroundTouchMonitor {
    let logURL: URL
    let pid: Int32

    init(udid: String, pid: Int32) async throws {
        let arguments = ["xcrun", "simctl", "get_app_container", udid, "com.cameroncooke.AxePlayground", "data"]
        let result = try await CommandRunner.run(arguments.map(Self.quote).joined(separator: " "), timeout: 10)
        let directory = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.hasPrefix("/"), !directory.contains("\n") else {
            throw TestError.unexpectedState("No unique absolute Playground data directory: \(result.output)")
        }
        logURL = URL(fileURLWithPath: directory).appendingPathComponent("Documents/touch-monitor.json")
        self.pid = pid
    }

    func read() throws -> PlaygroundContactSnapshot {
        let snapshot = try JSONDecoder().decode(PlaygroundContactSnapshot.self, from: Data(contentsOf: logURL))
        try #require(snapshot.processIdentifier == pid, "The touch log belongs to another app process.")
        return snapshot
    }

    func waitFor(
        _ description: String, timeout: TimeInterval = 12,
        while process: PlaygroundTestProcess? = nil,
        matches: (PlaygroundContactSnapshot) throws -> Bool
    ) async throws -> PlaygroundContactSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var lastSequence: Int?
        repeat {
            try Task.checkCancellation()
            if let process, !process.isRunning {
                throw TestError.unexpectedState("Input finished before \(description).\n\(try process.output())")
            }
            let snapshot = try read()
            lastSequence = snapshot.sequence
            if try matches(snapshot) { return snapshot }
            try await Task.sleep(nanoseconds: 30_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("Touch monitor did not reach \(description); sequence=\(lastSequence.map(String.init) ?? "none").")
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Owned subprocesses write to files, so a held-input log cannot block on a full pipe.
final class PlaygroundTestProcess {
    private let process = Process()
    private let stdoutURL: URL
    private let stderrURL: URL
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var didStart = false
    private(set) var startedUptime: TimeInterval = 0
    var isRunning: Bool { process.isRunning }
    var exitCode: Int32 { process.terminationStatus }
    var processIdentifier: Int32 { process.processIdentifier }

    func signal(_ number: Int32) throws {
        guard didStart, process.isRunning, kill(process.processIdentifier, number) == 0 else {
            throw TestError.unexpectedState("Cannot signal the owned running subprocess.")
        }
    }

    init(executable: String, arguments: [String], directory: URL, name: String) throws {
        stdoutURL = directory.appendingPathComponent(name + ".stdout")
        stderrURL = directory.appendingPathComponent(name + ".stderr")
        try Data().write(to: stdoutURL, options: .withoutOverwriting)
        try Data().write(to: stderrURL, options: .withoutOverwriting)
        stdout = try FileHandle(forWritingTo: stdoutURL)
        stderr = try FileHandle(forWritingTo: stderrURL)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
    }

    deinit {
        try? stdout.close()
        try? stderr.close()
    }

    func start() throws {
        startedUptime = ProcessInfo.processInfo.systemUptime
        try process.run()
        didStart = true
    }

    func wait(timeout: TimeInterval) async throws {
        guard didStart else { throw TestError.unexpectedState("The owned subprocess was not started.") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard !process.isRunning else {
            throw TestError.unexpectedState("Owned subprocess exceeded \(timeout) seconds.")
        }
        // Foundation has observed termination. A synchronous wait can block the cooperative executor.
    }

    /// Let the library finish its release before terminating only this owned CLI client.
    func finish() async {
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        guard didStart else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            await Self.cleanupPause()
        }
        if process.isRunning {
            process.terminate()
            let stop = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < stop {
                await Self.cleanupPause()
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let stop = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < stop {
                await Self.cleanupPause()
            }
        }
        if process.isRunning {
            Issue.record("The owned subprocess did not stop after termination.")
        }
    }

    private static func cleanupPause() async {
        await Task.detached { try? await Task.sleep(nanoseconds: 50_000_000) }.value
    }

    func output() throws -> String {
        let text = try String(contentsOf: stdoutURL, encoding: .utf8)
        // Every AXe JSON result an e2e test sees must match its published schema.
        try OutputSchemas.validate(output: text)
        return text
    }

    func diagnostics() throws -> String {
        try output() + "\n" + String(contentsOf: stderrURL, encoding: .utf8)
    }

    func receipt<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let line = try output().split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        return try JSONDecoder().decode(type, from: Data(line.utf8))
    }
}
