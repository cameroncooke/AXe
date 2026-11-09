import ArgumentParser
import Foundation
import AppKit
import FBControlCore // Ensure FBControlCore is imported for AxeLogger if it's defined there
import Darwin // For Darwin.exit()

// MARK: - Main Entry Point
@main
struct Axe: AsyncParsableCommand {
    static let _ensureSharedApp = NSApplication.shared
    static let axeLogger = AxeLogger() // Corrected initializer

    static let configuration = CommandConfiguration(
        abstract: "A utility to interact with iOS Simulators and extract accessibility information.",
        discussion: """
        Output: --output text|json selects one command result. Put it before the command for all
        commands. Non-media commands also accept it after the command. Screenshot and record-video
        keep their file-path --output option after the command. Agent mode defaults to JSON; commands
        without --agent or --output keep their released output. Binary streaming cannot use this option.
        """,
        version: VERSION,
        subcommands: [
            DescribeUI.self,
            ListSimulators.self,
            Displays.self,
            Shutdown.self,
            Clipboard.self,
            Init.self,
            AgentCommand.self,
            Tap.self,
            Slider.self,
            Hinge.self,
            Rotate.self,
            Type.self,
            Swipe.self,
            Drag.self,
            Button.self,
            Key.self,
            KeySequence.self,
            KeyCombo.self,
            Touch.self,
            Gesture.self,
            StreamVideo.self,
            RecordVideo.self,
            Screenshot.self,
            Batch.self,
            SliderReadWorkerCommand.self,
            HIDBrokerCommand.self
        ]
    )

    static func main() async {
        await main(Array(CommandLine.arguments.dropFirst()))
    }

    static func main(_ arguments: [String]?) async {
        UncaughtExceptionGuard.install()
        let invocation = CLIOutputInvocation(arguments: arguments ?? Array(CommandLine.arguments.dropFirst()))
        guard let format = invocation.format else {
            do {
                try await runCommand(arguments: invocation.arguments)
            } catch {
                exit(withError: error)
            }
            return
        }

        let output = CLIOutputContext(format: format, command: invocation.command, agent: invocation.agent)
        let completion = await CLIOutput.$context.withValue(output) {
            var parsed = false
            do {
                if let message = invocation.selectionError {
                    throw CLIOutputFailure(code: "invalidArguments", message: message)
                }
                var command = try parseAsRoot(invocation.arguments)
                parsed = true
                if command is StreamVideo || command is HIDBrokerCommand || command is SliderReadWorkerCommand {
                    throw CLIOutputFailure(code: "unsupportedOutput",
                        message: "--output text|json is not supported for binary streaming or internal worker commands.")
                }
                if var asynchronous = command as? AsyncParsableCommand {
                    try await asynchronous.run()
                } else {
                    try command.run()
                }
                return OutputCompletion(exitCode: EXIT_SUCCESS, failure: nil, cleanMessage: nil)
            } catch {
                let code = exitCode(for: error).rawValue
                if code == EXIT_SUCCESS {
                    return OutputCompletion(exitCode: code, failure: nil, cleanMessage: fullMessage(for: error))
                }
                let failure: CLIOutputFailure
                if let known = error as? CLIOutputFailure {
                    failure = known
                } else if let known = error as? AgentModeFailure {
                    failure = CLIOutputFailure(code: known.code, message: known.message)
                } else if error is ValidationError {
                    failure = CLIOutputFailure(code: "invalidArguments", message: message(for: error))
                } else {
                    failure = CLIOutputFailure(code: parsed ? "commandFailed" : "invalidArguments",
                        message: message(for: error))
                }
                return OutputCompletion(exitCode: code, failure: failure, cleanMessage: nil)
            }
        }

        let bytes: Data
        do {
            bytes = try CLIOutput.rendered(output, failure: completion.failure, cleanMessage: completion.cleanMessage)
        } catch {
            // Encoding occurs before the first write. This failure cannot append a second result.
            let fallback = CLIOutputContext(format: format, command: invocation.command, agent: invocation.agent)
            let failure = CLIOutputFailure(code: "outputEncodingFailed", message: "Could not encode the command result.")
            guard let rendered = try? CLIOutput.rendered(fallback, failure: failure) else {
                Darwin.exit(EXIT_FAILURE)
            }
            do { try FileHandle.standardOutput.write(contentsOf: rendered) }
            catch { Darwin.exit(EXIT_FAILURE) }
            Darwin.exit(EXIT_FAILURE)
        }
        do { try FileHandle.standardOutput.write(contentsOf: bytes) }
        catch { Darwin.exit(EXIT_FAILURE) }
        Darwin.exit(completion.exitCode)
    }

    private static func runCommand(arguments: [String]) async throws {
        var command = try parseAsRoot(arguments)
        if var asynchronous = command as? AsyncParsableCommand {
            try await asynchronous.run()
        } else {
            try command.run()
        }
    }

    private struct OutputCompletion: Sendable {
        let exitCode: Int32
        let failure: CLIOutputFailure?
        let cleanMessage: String?
    }
}
