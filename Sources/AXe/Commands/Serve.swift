import ArgumentParser
import Darwin
import Foundation

/// One long-lived process per simulator. Each standard input line is an AXe command, run in this
/// process as the one-off command runs; each reply is the line `axe --output json <command>` prints.
/// The process keeps what a one-off command rebuilds every time: the loaded frameworks, the
/// simulator set and the warm accessibility connection. Taps still go to the shared HID broker,
/// and no input connection is kept between commands.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run AXe commands from standard input against one simulator, one per line.",
        discussion: """
        Write one command per line as you would type it after `axe`, without --udid. Each command gets one JSON line on standard output, in order: what `axe --output json <command>` prints. Setup happens once, so later commands skip process startup and the simulator lookup. serve prints a ready line first and exits when standard input closes; logs go to standard error.

        Commands: describe-ui, displays, screenshot, tap, swipe, drag, draw, type, button, key, key-sequence, key-combo, touch, gesture, slider, rotate and hinge. `ping` answers without touching the simulator.

        Examples:
          axe serve --udid <UDID>
          printf 'describe-ui\\ntap --label General\\n' | axe serve --udid <UDID>
        """
    )

    @Option(name: .customLong("udid"), help: "UDID of the booted simulator.")
    var simulatorUDID: String

    func validate() throws {
        guard !simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--udid must not be empty.")
        }
        guard !AutomationTarget.isPhysicalInputUDID(simulatorUDID) else {
            throw ValidationError("axe serve runs against simulators only.")
        }
    }

    @MainActor
    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        // Loads the simulator set once and refuses a simulator that is not booted.
        _ = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
        try Self.write(ServeProtocol.ready(simulatorUDID: simulatorUDID))

        // The broker shuts down after 30 s without a request, and the next tap then waits about 0.6 s
        // for a new one. Every tick keeps a running broker alive, whatever lines arrive in between:
        // reads and pings never reach the broker, so they cannot stand in for a keep-alive.
        for await event in ServeInput.events(tick: ServeInput.keepAliveInterval) {
            let line: String
            switch event {
            case .tick:
                SelectedHIDBroker.keepAliveIfRunning(simulatorUDID: simulatorUDID)
                continue
            case .line(let text):
                line = text
            }
            let reply: Data
            switch ServeProtocol.parse(line, simulatorUDID: simulatorUDID) {
            case .skip:
                continue
            case .ping:
                reply = ServeProtocol.pong()
            case .refused(let command, let message):
                reply = ServeProtocol.refusal(command: command, message: message)
            case .command(let arguments):
                let result = await Axe.formattedOutput(for: CLIOutputInvocation(arguments: arguments), format: .json)
                // A one-off command closes its direct input connection when it exits. Close it here
                // too, so no connection outlives its command or a simulator reboot.
                HIDInteractor.discardConnection(for: simulatorUDID)
                try Self.write(result.bytes)
                // An interrupted command ends serve, as it ends a one-off command.
                if result.exitCode > 128 { Darwin.exit(result.exitCode) }
                continue
            }
            try Self.write(reply)
        }
    }

    private static func write(_ bytes: Data) throws {
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}

/// The serve line protocol, kept free of simulator access so it can be tested directly.
enum ServeProtocol {
    enum Line: Equatable {
        case skip
        case ping
        /// The full argument list for the command, with `--output json` and `--udid` added.
        case command([String])
        case refused(command: String, message: String)
    }

    /// Commands that read or drive one simulator and end on their own. Streaming, recording,
    /// batch (which reads standard input), device management and serve itself are left out.
    static let commands: [String] = [
        "describe-ui", "displays", "screenshot", "tap", "swipe", "drag", "draw", "type", "button",
        "key", "key-sequence", "key-combo", "touch", "gesture", "slider", "rotate", "hinge",
    ]

    static func parse(_ line: String, simulatorUDID: String) -> Line {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return .skip }
        let tokens: [String]
        do { tokens = try ShellTokenizer.tokenize(trimmed) }
        catch { return .refused(command: "serve", message: CLIErrorMapping.failure(for: error).message) }
        guard let name = tokens.first else { return .skip }
        if tokens == ["ping"] { return .ping }
        guard commands.contains(name) else {
            return .refused(command: name, message: "serve runs \(commands.joined(separator: ", ")) and ping; `\(name)` is not one of them.")
        }
        // Words after `--` are positional text, for example `type -- --udid`, so only options before it count.
        let terminator = tokens.firstIndex(of: "--") ?? tokens.endIndex
        let options = tokens[..<terminator]
        if options.contains(where: { $0 == "--udid" || $0.hasPrefix("--udid=") }) {
            return .refused(command: name, message: "Leave out --udid: serve already targets \(simulatorUDID).")
        }
        if options.contains("--stdin") {
            return .refused(command: name, message: "--stdin would read serve's own input. Pass the text as an argument or with --file.")
        }
        var arguments = tokens
        arguments.insert(contentsOf: ["--udid", simulatorUDID], at: terminator)
        return .command(["--output", "json"] + arguments)
    }

    static func ready(simulatorUDID: String) -> Data {
        render(command: "serve", result: .object(["ready": .bool(true), "udid": .string(simulatorUDID)]))
    }

    static func pong() -> Data {
        render(command: "ping", result: .object(["pong": .bool(true)]))
    }

    static func refusal(command: String, message: String) -> Data {
        render(command: command, result: nil, failure: CLIOutputFailure(code: "invalidArguments", message: message))
    }

    private static func render(command: String, result: CLIOutputValue?, failure: CLIOutputFailure? = nil) -> Data {
        let context = CLIOutputContext(format: .json, command: command, agent: false)
        if let result { context.append(result) }
        // Encoding these small fixed values cannot fail; the fallback keeps one line per request.
        return (try? CLIOutput.rendered(context, failure: failure))
            ?? Data("{\"didError\":true,\"error\":{\"code\":\"outputEncodingFailed\"}}\n".utf8)
    }
}

/// Standard input lines and idle ticks in one ordered stream, so a keep-alive never overlaps a
/// command. Lines are read on their own thread, which leaves the main actor free between commands.
enum ServeInput {
    enum Event: Sendable { case line(String), tick }

    /// Well inside the broker's 30 s idle limit, even when a command delays a tick.
    static let keepAliveInterval: Duration = .seconds(10)

    static func events(tick: Duration) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let interval = DispatchTimeInterval.milliseconds(Int(tick.components.seconds * 1000))
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { continuation.yield(.tick) }
            timer.resume()
            let reader = Thread {
                while let line = readLine(strippingNewline: true) { continuation.yield(.line(line)) }
                timer.cancel()
                continuation.finish()
            }
            reader.name = "axe-serve-stdin"
            reader.start()
        }
    }
}
