import Foundation

/// A normal app document must identify the process and the page instance that wrote it.
protocol PlaygroundObservedDocument: Decodable {
    var pid: Int32 { get }
    var generation: UUID { get }
}

/// Read-only observations from the normal Playground's Documents directory.
struct PlaygroundDocumentReader<Value: PlaygroundObservedDocument> {
    let url: URL
    private let expectedPID: Int32
    private let expectedGeneration: UUID

    init(udid: String, pid: Int32, fileName: String) async throws {
        guard pid > 0, !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
            throw TestError.unexpectedState("Invalid Playground document target.")
        }
        let command = ["xcrun", "simctl", "get_app_container", udid, "com.cameroncooke.AxePlayground", "data"]
            .map(Self.quote).joined(separator: " ")
        let result = try await CommandRunner.run(command, timeout: 30)
        let container = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard container.hasPrefix("/"), !container.contains("\n") else {
            throw TestError.unexpectedState("No normal Playground data container: \(result.output)")
        }
        let documentURL = URL(fileURLWithPath: container).appendingPathComponent("Documents")
            .appendingPathComponent(fileName)
        let initial = try await Self.initialValue(at: documentURL, pid: pid)
        url = documentURL
        expectedPID = pid
        expectedGeneration = initial.generation
    }

    func read() throws -> Value {
        let value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        guard value.pid == expectedPID, value.generation == expectedGeneration else {
            throw TestError.unexpectedState("Playground document changed process or page generation: \(url.path)")
        }
        return value
    }

    func waitFor(_ description: String, timeout: TimeInterval = 10,
                 matches: (Value) throws -> Bool) async throws -> Value {
        guard timeout.isFinite, timeout > 0 else {
            throw TestError.unexpectedState("Invalid app observation timeout.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let value = try read()
            if try matches(value) { return value }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("Timed out waiting for \(description) in \(url.path).")
    }

    private static func initialValue(at url: URL, pid: Int32) async throws -> Value {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var lastError = "No current app document was observed."
        repeat {
            do {
                let value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
                if value.pid == pid { return value }
                lastError = "Observed PID \(value.pid), expected \(pid)."
            } catch {
                lastError = String(describing: error)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("No document for the current Playground process: \(url.path). \(lastError)")
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension CorePlaygroundSession {
    /// Use the same public CLI boundary when a test must inspect a refusal or JSON receipt.
    func command(_ arguments: [String], allowFailure: Bool = false,
                 timeout: TimeInterval = 30) async throws -> CommandOutput {
        let udid = try TestHelpers.requireSimulatorUDID()
        let executable = try TestHelpers.getAxePath()
        let command = ([executable] + arguments + ["--udid", udid]).map { argument in
            "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        let result = try await CommandRunner.run(command, allowFailure: allowFailure, timeout: timeout)
        return CommandOutput(output: result.output, exitCode: result.exitCode)
    }
}
