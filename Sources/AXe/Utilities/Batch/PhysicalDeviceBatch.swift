import ArgumentParser
import Foundation

@MainActor
enum PhysicalDeviceBatch {
    static func run(_ lines: [String], on device: CoreDevice, udid: String) async throws {
        try await PhysicalDeviceInput.withSession(for: device) { input in
            for (index, line) in lines.enumerated() {
                try Task.checkCancellation()
                var stepName = "unparsed step"
                do {
                    let tokens = try ShellTokenizer.tokenize(line)
                    guard let name = tokens.first, let kind = BatchStepKind(rawValue: name) else {
                        throw ValidationError("Unsupported physical batch step.")
                    }
                    stepName = kind.rawValue
                    try await runStep(kind, arguments: Array(tokens.dropFirst()), udid: udid, input: input)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let failure = CLIErrorMapping.failure(for: error)
                    throw CLIOutputFailure(code: failure.code,
                        message: "Step \(index + 1) (\(stepName)) failed. \(failure.message)")
                }
            }
        }
    }

    private static func runStep(_ kind: BatchStepKind, arguments: [String], udid: String,
                                input: PhysicalDeviceInput) async throws {
        let options = arguments.prefix { $0 != "--" }
        guard !options.contains(where: { $0 == "--udid" || $0.hasPrefix("--udid=") }) else {
            throw ValidationError("Use the batch-level --udid for every step.")
        }
        guard !options.contains("--agent") else {
            throw AutomationTarget.unsupportedOnDevice("Physical batch steps do not support agent mode.")
        }
        guard let type = commandType(for: kind) else {
            return try await sleep(arguments, keepingAlive: input)
        }
        let command = try parse(type, ["--udid", udid] + arguments)
        try command.validateOnDevice(inBatch: true)
        _ = try await command.runOnDevice(input)
    }

    private static func sleep(_ arguments: [String], keepingAlive input: PhysicalDeviceInput) async throws {
        guard arguments.count == 1, let seconds = Double(arguments[0]), seconds.isFinite, seconds >= 0 else {
            throw ValidationError("Use sleep <seconds> with a finite, non-negative duration.")
        }
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            let remaining = seconds - (ProcessInfo.processInfo.systemUptime - start)
            guard remaining > 0 else { return }
            try await Task.sleep(for: .seconds(min(25, remaining)))
            if remaining > 25 { try await input.keepAlive() }
        }
    }

    /// The command each step runs, through the same checks and input as the standalone command;
    /// nil for `sleep`.
    static func commandType(for kind: BatchStepKind) -> (any PhysicalDeviceCommand.Type)? {
        switch kind {
        case .tap: Tap.self
        case .swipe: Swipe.self
        case .gesture: Gesture.self
        case .draw: Draw.self
        case .touch: Touch.self
        case .type: Type.self
        case .button: Button.self
        case .key: Key.self
        case .keySequence: KeySequence.self
        case .keyCombo: KeyCombo.self
        case .sleep: nil
        }
    }

    private static func parse<C: AsyncParsableCommand>(_ type: C.Type, _ arguments: [String]) throws -> C {
        do {
            return try type.parse(arguments)
        } catch {
            throw ValidationError(type.message(for: error))
        }
    }
}
