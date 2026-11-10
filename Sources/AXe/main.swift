import ArgumentParser
import Foundation
import AppKit
import Darwin // For Darwin.exit()

// MARK: - Main Entry Point
@main
struct Axe: AsyncParsableCommand {
    static let _ensureSharedApp = NSApplication.shared

    static let configuration = CommandConfiguration(
        abstract: "Automate iOS simulators or connected iPhones and iPads.",
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
            Settings.self,
            ListDevices.self,
            Doctor.self,
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
            Draw.self,
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
            HIDBrokerCommand.self,
            PhysicalDeviceBrokerCommand.self
        ]
    )

    static func main() async {
        await main(Array(CommandLine.arguments.dropFirst()))
    }

    static func main(_ arguments: [String]?) async {
        UncaughtExceptionGuard.install()
        let invocation = CLIOutputInvocation(arguments: arguments ?? Array(CommandLine.arguments.dropFirst()))
        guard let format = invocation.format else {
            var command: ParsableCommand
            do {
                command = try parseAsRoot(invocation.arguments)
            } catch {
                exit(withError: error)
            }
            do {
                try await run(&command)
            } catch {
                if let status = CLIErrorMapping.interruptionExitCode(for: error) { Darwin.exit(status) }
                exit(withError: CLIErrorMapping.isArgumentParserError(error) ? error : CLIErrorMapping.failure(for: error))
            }
            return
        }

        // A command line that fails to parse still names the subcommands it spells out.
        let output = CLIOutputContext(format: format, command: commandPath(spelledBy: invocation.arguments)
            ?? invocation.command, agent: invocation.agent)
        let completion = await CLIOutput.$context.withValue(output) {
            var parsed = false
            do {
                if let message = invocation.selectionError {
                    throw CLIOutputFailure(code: "invalidArguments", message: message)
                }
                var command = try parseAsRoot(invocation.arguments)
                parsed = true
                output.command = commandPath(of: command)
                if command is StreamVideo || command is HIDBrokerCommand || command is SliderReadWorkerCommand || command is PhysicalDeviceBrokerCommand {
                    throw CLIOutputFailure(code: "unsupportedOutput",
                        message: "--output text|json is not supported for binary streaming or internal worker commands.")
                }
                try await run(&command)
                if !invocation.agent, inputCommands.contains(where: { $0 == type(of: command) }),
                   output.content().values.isEmpty {
                    // Ordinary and physical input report what the selected route reports, minus
                    // the bound screen, PID and contact token it adds.
                    output.append(.object(["outcome": .string("completed")]))
                }
                return OutputCompletion(exitCode: EXIT_SUCCESS, failure: nil, cleanMessage: nil)
            } catch {
                let code = CLIErrorMapping.interruptionExitCode(for: error) ?? exitCode(for: error).rawValue
                if code == EXIT_SUCCESS {
                    return OutputCompletion(exitCode: code, failure: nil, cleanMessage: fullMessage(for: error))
                }
                let failure: CLIOutputFailure
                if (!parsed || CLIErrorMapping.isArgumentParserError(error)) && !(error is CLIOutputFailure) {
                    failure = CLIOutputFailure(code: "invalidArguments", message: message(for: error))
                } else if error is ValidationError {
                    failure = CLIOutputFailure(code: "invalidArguments", message: message(for: error))
                } else {
                    failure = CLIErrorMapping.failure(for: error)
                }
                return OutputCompletion(exitCode: code, failure: failure, cleanMessage: nil)
            }
        }

        let bytes: Data
        do {
            bytes = try CLIOutput.rendered(output, failure: completion.failure, cleanMessage: completion.cleanMessage)
        } catch {
            // Encoding occurs before the first write. This failure cannot append a second result.
            let fallback = CLIOutputContext(format: format, command: output.command, agent: invocation.agent)
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

    /// Commands whose JSON success result is `SelectedInputSummary`'s shape on every route.
    static let inputCommands: [ParsableCommand.Type] = [
        Tap.self, Slider.self, Type.self, Swipe.self, Drag.self, Draw.self, Button.self, Key.self,
        KeySequence.self, KeyCombo.self, Touch.self, Gesture.self,
    ]

    private static func run(_ command: inout ParsableCommand) async throws {
        if var asynchronous = command as? AsyncParsableCommand {
            try await asynchronous.run()
            command = asynchronous
        } else {
            try command.run()
        }
    }

    /// The leading command words that name known subcommands, for example `hinge set` in
    /// `hinge set 200 --udid …`; nil when the first word is not a command.
    static func commandPath(spelledBy arguments: [String]) -> String? {
        var parent: ParsableCommand.Type = Axe.self
        var path: [String] = []
        for word in arguments {
            guard let child = parent.configuration.subcommands.first(where: { $0._commandName == word }) else { break }
            path.append(word)
            parent = child
        }
        return path.isEmpty ? nil : path.joined(separator: " ")
    }

    /// The full command path without the root, for example `hinge set` or `settings status-bar show`.
    static func commandPath(of command: ParsableCommand) -> String {
        let target = ObjectIdentifier(type(of: command))
        func path(below parent: ParsableCommand.Type) -> [String]? {
            for child in parent.configuration.subcommands {
                if ObjectIdentifier(child) == target { return [child._commandName] }
                if let rest = path(below: child) { return [child._commandName] + rest }
            }
            return nil
        }
        return path(below: Axe.self)?.joined(separator: " ") ?? "axe"
    }

    private struct OutputCompletion: Sendable {
        let exitCode: Int32
        let failure: CLIOutputFailure?
        let cleanMessage: String?
    }
}
