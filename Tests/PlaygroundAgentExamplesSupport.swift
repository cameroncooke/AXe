import Foundation
import Testing

struct PlaygroundAgentExamplesDocument: PlaygroundObservedDocument, Equatable {
    let generation: UUID
    let pid: Int32
    let taps: Int
    let textChanges: Int
    let text: String
    let focused: Bool
    let status: String
    let longVisible: Bool
    let longLength: Int
    let outerOffset: Double
    let listOffset: Double
    let photosStatus: Int
    let activeWindowTouches: Int
    let windowTraceDropped: Int
    let windowTouchTrace: [PlaygroundAgentExampleContact]
}

struct PlaygroundAgentExampleContact: Decodable, Equatable {
    let contactID: Int
    let phase: String
    let x: Double
    let y: Double
    let timestamp: Double
    let activeTouches: Int
    let hitView: String
}

struct PlaygroundAgentExamplesSession {
    let app: AgentPlaygroundSession
    let core: CorePlaygroundSession
    let pid: Int32
    let document: PlaygroundDocumentReader<PlaygroundAgentExamplesDocument>
    let artifacts: URL

    static func open(position: DuoControlsPosition = .outer0) async throws -> Self {
        let app = try AgentPlaygroundSession()
        let core = try CorePlaygroundSession()
        let root = try #require(ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"])
        let artifacts = URL(fileURLWithPath: root).appendingPathComponent("agent-examples-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let pid = try await openAgentPlaygroundScreen(app, screen: "agent-examples", readyID: "agent-examples.tap", position: position)
        let document = try await PlaygroundDocumentReader<PlaygroundAgentExamplesDocument>(
            udid: app.udid, pid: pid, fileName: "agent-examples.json")
        return Self(app: app, core: core, pid: pid, document: document, artifacts: artifacts)
    }

    func run(_ arguments: [String], allowFailure: Bool = false, timeout: TimeInterval = 30) async throws -> CommandOutput {
        let arguments = canonicalAgentArguments(arguments)
        let identifier = UUID().uuidString
        try Data(contentsOf: document.url).write(to: artifacts.appendingPathComponent(identifier + "-before.json"))
        let output = try await core.command(arguments, allowFailure: allowFailure, timeout: timeout)
        try JSONEncoder().encode(arguments).write(to: artifacts.appendingPathComponent(identifier + "-arguments.json"))
        try Data(output.output.utf8).write(to: artifacts.appendingPathComponent(identifier + "-output.txt"))
        try Data(contentsOf: document.url).write(to: artifacts.appendingPathComponent(identifier + "-after.json"))
        return output
    }
    func decode(_ output: String) throws -> AgentPlaygroundResult {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(AgentPlaygroundResult.self, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No agent envelope: \(output)")
    }
    func capture(pid expected: Int32? = nil) async throws -> AgentPlaygroundTimedCapture {
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await run(["describe-ui", "--agent", "--expected-pid", String(expected ?? pid)])
        let value = try decode(result.output)
        try #require(!value.didError)
        return try AgentPlaygroundTimedCapture(capture: #require(value.data.capture), requestStartedUptime: started)
    }
    /// Reads until the Playground is frontmost again. A system prompt reports its result to the app
    /// while SpringBoard is still animating it away, so the app's first read can see SpringBoard.
    func captureWhenFrontmost(timeout: TimeInterval = 15) async throws -> AgentPlaygroundTimedCapture {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try Task.checkCancellation()
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await run(["describe-ui", "--agent", "--expected-pid", String(pid)], allowFailure: true)
            if result.exitCode == 0, let value = try? decode(result.output), !value.didError,
               let capture = value.data.capture, capture.applicationPID == pid {
                return try AgentPlaygroundTimedCapture(capture: capture, requestStartedUptime: started)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("The Playground did not return to the front after the system prompt closed")
    }
    func reference(_ id: String, in capture: AgentPlaygroundTimedCapture) throws -> String {
        let rows = try (capture.capture.targets + capture.capture.scroll + capture.capture.text).map(AgentPlaygroundRow.init)
        let refs = Set(rows.filter { $0.identifier == id }.map(\.ref))
        try #require(refs.count == 1)
        return try #require(refs.first)
    }
    func arguments(_ capture: AgentPlaygroundTimedCapture, id: String) throws -> [String] {
        try capture.requireUnexpired("before example action")
        return ["--agent", "--expected-pid", String(pid), "--snapshot-id", capture.capture.snapshotID.uuidString,
            "--ref", try reference(id, in: capture)]
    }
    func tap(_ id: String) async throws {
        let result = try await run(["tap", "--agent", "--expected-pid", String(pid), "--id", id])
        let envelope = try decode(result.output)
        let action = try #require(envelope.data.action)
        try #require(!envelope.didError && action.kind == "tap" && action.outcome == "enqueuedAndDrained"
            && action.enqueuedEventCount == 2 && action.cleanup != "uncertain" && !action.replayed)
    }
}
