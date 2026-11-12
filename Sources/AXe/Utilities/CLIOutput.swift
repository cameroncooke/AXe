import Foundation

enum CLIOutputFormat: String, Sendable {
    case text
    case json
}

struct CLIOutputFailure: Error, Sendable, LocalizedError, CustomStringConvertible {
    let code: String
    let message: String
    var errorDescription: String? { message }
    /// Broker replies carry `String(describing:)` of an error; keep that the message.
    var description: String { message }
}

struct CLIOutputContent: Sendable {
    let values: [CLIOutputValue]
    let messages: [String]
}

/// The invocation owns this buffer. The lock protects synchronous output from child tasks.
final class CLIOutputContext: @unchecked Sendable {
    let format: CLIOutputFormat
    let agent: Bool
    private let lock = NSLock()
    private var commandName: String
    private var values: [CLIOutputValue] = []
    private var messages: [String] = []
    private var view: AgentOutputView = .reading

    /// The invocation's first command word until parsing names the full command path.
    var command: String {
        get { lock.lock(); defer { lock.unlock() }; return commandName }
        set { lock.lock(); defer { lock.unlock() }; commandName = newValue }
    }

    init(format: CLIOutputFormat, command: String, agent: Bool) {
        self.format = format
        self.commandName = command
        self.agent = agent
    }

    func append(_ value: CLIOutputValue) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func append(message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    func content() -> CLIOutputContent {
        lock.lock()
        defer { lock.unlock() }
        return CLIOutputContent(values: values, messages: messages)
    }

    func setAgentView(_ value: AgentOutputView) {
        lock.lock()
        defer { lock.unlock() }
        view = value
    }

    var agentView: AgentOutputView {
        lock.lock()
        defer { lock.unlock() }
        return view
    }
}

enum CLIOutput {
    @TaskLocal static var context: CLIOutputContext?

    static var isFormatted: Bool { context != nil }
    static var format: CLIOutputFormat? { context?.format }

    static func setAgentView(_ view: AgentOutputView) {
        context?.setAgentView(view)
    }

    static func message(_ text: String, terminator: String = "\n") {
        guard let context else {
            Swift.print(text, terminator: terminator)
            return
        }
        context.append(message: text)
    }

    static func writeJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeJSONData(encoder.encode(value))
    }

    static func writeJSONData(_ data: Data) throws {
        guard let context else {
            Swift.print(String(decoding: data, as: UTF8.self))
            return
        }
        context.append(try CLIOutputValue.decodingJSON(data))
    }

    static func writeJSONText(_ text: String) throws {
        try writeJSONData(Data(text.utf8))
    }

    static func rendered(_ context: CLIOutputContext, failure: CLIOutputFailure? = nil,
                         cleanMessage: String? = nil) throws -> Data {
        let content = context.content()
        let value: CLIOutputValue
        if context.agent {
            if let existing = content.values.last,
               existing["schema"]?.stringValue == "axe.output.agent-result" {
                value = existing
            } else if let failure {
                let result = AgentModeResult(error: AgentModeFailure(failure.code, failure.message),
                    cache: AgentModeCacheState(status: "unobserved", reason: failure.code, requiresRefresh: true),
                    nextSteps: ["Check the command arguments and simulator state before retrying. Input was not replayed."])
                value = try JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(result))
            } else {
                value = commandResult(context, content: content, failure: nil, cleanMessage: cleanMessage)
            }
        } else {
            value = commandResult(context, content: content, failure: failure, cleanMessage: cleanMessage)
        }
        let output: CLIOutputValue
        if context.agent { output = try AgentOutputProjection.project(value, view: context.agentView) }
        else { output = value }
        if context.format == .text {
            return Data((CLIOutputText.render(output) + "\n").utf8)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(output)
        data.append(0x0a)
        return data
    }

    private static func commandResult(_ context: CLIOutputContext, content: CLIOutputContent,
                                      failure: CLIOutputFailure?, cleanMessage: String?) -> CLIOutputValue {
        var data: [String: CLIOutputValue] = [:]
        if content.values.count == 1 { data["result"] = content.values[0] }
        else if !content.values.isEmpty { data["results"] = .array(content.values) }
        var messages = content.messages
        if let cleanMessage, !cleanMessage.isEmpty { messages.append(cleanMessage) }
        if !messages.isEmpty { data["messages"] = .array(messages.map(CLIOutputValue.string)) }
        var result: [String: CLIOutputValue] = [
            "schema": .string("axe.output.command-result"),
            "schemaVersion": .string("1"),
            "command": .string(context.command),
            "didError": .bool(failure != nil),
            "data": .object(data),
            "nextSteps": .array([])
        ]
        if let failure {
            let message = failure.message.isEmpty
                ? content.values.last?["message"]?.stringValue ?? "Command failed."
                : failure.message
            result["error"] = .object(["code": .string(failure.code), "message": .string(message)])
        }
        return .object(result)
    }
}
