import Darwin
import Foundation
import Testing

/// Owns one CLI process with a file at EOF, or an empty pipe deliberately left open.
final class PlaygroundStdinProcess {
    private let process = Process()
    private let input: FileHandle
    private let writer: FileHandle?
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let stdoutURL: URL
    private let stderrURL: URL
    private var started = false
    private(set) var inputClosed = false
    var isRunning: Bool { process.isRunning }
    var exitCode: Int32 { process.terminationStatus }

    init(executable: String, arguments: [String], data: Data?, directory: URL, name: String) throws {
        stdoutURL = directory.appendingPathComponent(name + ".stdout")
        stderrURL = directory.appendingPathComponent(name + ".stderr")
        try Data().write(to: stdoutURL, options: .withoutOverwriting)
        try Data().write(to: stderrURL, options: .withoutOverwriting)
        stdout = try FileHandle(forWritingTo: stdoutURL)
        stderr = try FileHandle(forWritingTo: stderrURL)
        if let data {
            let source = directory.appendingPathComponent(name + "-stdin.bin")
            try data.write(to: source, options: .withoutOverwriting)
            input = try FileHandle(forReadingFrom: source)
            writer = nil
        } else {
            let pipe = Pipe()
            input = pipe.fileHandleForReading
            writer = pipe.fileHandleForWriting
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        try JSONEncoder().encode([executable] + arguments).write(to: directory.appendingPathComponent(name + "-argv.json"))
    }
    deinit { closeHandles() }
    func start() throws { try process.run(); started = true }
    func signal(_ number: Int32) throws {
        try #require(started && isRunning && kill(process.processIdentifier, number) == 0)
    }
    func wait(timeout: TimeInterval = 40) async throws -> CommandOutput {
        try #require(started)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while isRunning && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        guard !isRunning else { throw TestError.unexpectedState("The owned stdin command did not finish within \(timeout)s.") }
        return CommandOutput(output: try output(), exitCode: exitCode)
    }
    func output() throws -> String {
        try String(contentsOf: stdoutURL, encoding: .utf8) + "\n" + String(contentsOf: stderrURL, encoding: .utf8)
    }
    func stdoutBytes() throws -> Data { try Data(contentsOf: stdoutURL) }
    func finish() async {
        if started && isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while isRunning && ProcessInfo.processInfo.systemUptime < deadline { await Self.cleanupPause() }
            if isRunning { kill(process.processIdentifier, SIGKILL) }
            let final = ProcessInfo.processInfo.systemUptime + 2
            while isRunning && ProcessInfo.processInfo.systemUptime < final { await Self.cleanupPause() }
            if isRunning { Issue.record("The owned stdin CLI did not stop.") }
        }
        closeHandles()
    }
    private static func cleanupPause() async {
        await Task.detached { try? await Task.sleep(nanoseconds: 30_000_000) }.value
    }

    private func closeHandles() {
        try? writer?.close()
        try? input.close()
        try? stdout.close()
        try? stderr.close()
        inputClosed = true
    }
}
