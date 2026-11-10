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
                    let code: String
                    let message: String
                    if let failure = error as? CLIOutputFailure {
                        code = failure.code
                        message = failure.message
                    } else if let invalid = error as? ValidationError {
                        code = "invalidArguments"
                        message = invalid.description
                    } else {
                        code = "deviceBatchStepFailed"
                        message = (error as? UserFacingError)?.userFacingDescription ?? error.localizedDescription
                    }
                    throw CLIOutputFailure(code: code, message: "Step \(index + 1) (\(stepName)) failed. \(message)")
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
        let args = ["--udid", udid] + arguments
        switch kind {
        case .tap:
            try await parse(Tap.self, args).physicalTap(on: input)
        case .swipe:
            try await parse(Swipe.self, args).runOnDevice(input)
        case .gesture:
            let command = try parse(Gesture.self, args)
            guard case .preset = command.gesture else {
                throw AutomationTarget.unsupportedOnDevice("Physical batch gesture steps require a preset.")
            }
            try await command.runOnDevice(input)
        case .draw:
            try await parse(Draw.self, args).runOnDevice(input)
        case .touch:
            try await parse(Touch.self, args).runOnDevice(input, allowPartial: true)
        case .type:
            try await parse(Type.self, args).physicalType(on: input)
        case .button:
            try await parse(Button.self, args).physicalButton(on: input)
        case .key:
            try await parse(Key.self, args).physicalKeys(on: input)
        case .keySequence:
            try await parse(KeySequence.self, args).physicalKeys(on: input)
        case .keyCombo:
            try await parse(KeyCombo.self, args).physicalKeys(on: input)
        case .sleep:
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
    }

    private static func parse<C: AsyncParsableCommand>(_ type: C.Type, _ arguments: [String]) throws -> C {
        do {
            return try type.parse(arguments)
        } catch {
            throw ValidationError(type.message(for: error))
        }
    }
}
