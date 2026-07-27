import ArgumentParser
import Darwin
import Foundation

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Install the AXe skill directly or through the Claude Code or Codex marketplace."
    )

    private static let marketplaceSource = "cameroncooke/AXe"
    private static let pluginIdentifier = "axe@axe"

    enum Client: String, ExpressibleByArgument, CaseIterable {
        case auto
        case agents
        case claude
        case codex
    }

    @Option(help: "Target client: auto, agents, claude, or codex. Defaults to auto-detect.")
    var client: Client = .auto

    @Option(help: "Custom destination skills directory instead of a marketplace.")
    var dest: String?

    @Flag(help: "Reinstall the marketplace plugin or overwrite a custom destination.")
    var force: Bool = false

    @Flag(help: "Uninstall the marketplace plugin or custom skill.")
    var uninstall: Bool = false

    @Flag(name: .customLong("print"), help: "Print bundled skill content to stdout.")
    var printSkill: Bool = false

    func validate() throws {
        if printSkill, uninstall {
            throw ValidationError("--print cannot be used with --uninstall")
        }

        if printSkill, force {
            throw ValidationError("--print cannot be used with --force")
        }

        if printSkill, dest != nil {
            throw ValidationError("--print cannot be used with --dest")
        }

        if printSkill, client != .auto {
            throw ValidationError("--print cannot be used with --client")
        }
    }

    func run() async throws {
        if !printSkill, !isInteractiveTTY(), dest == nil, client == .auto {
            throw CLIError(
                errorDescription: "Non-interactive mode requires --client or --dest for init. Use --print to output the skill content."
            )
        }

        if printSkill {
            Swift.print(try Self.loadSkillMarkdown(), terminator: "")
            return
        }

        if let destination = dest {
            let resolvedDestination = try Self.resolveDestinationURL(from: destination)
            if uninstall {
                try uninstallSkill(from: resolvedDestination)
            } else {
                try installSkill(to: resolvedDestination)
            }
            return
        }

        if client == .agents {
            let agentsDestination = Self.agentsSkillsDirectory()
            if uninstall {
                try uninstallSkill(from: agentsDestination)
            } else {
                try installSkill(to: agentsDestination)
            }
            return
        }

        let targets = try resolveMarketplaceClients(for: uninstall ? .uninstall : .install)
        if uninstall {
            try uninstallMarketplacePlugin(from: targets)
        } else {
            try installMarketplacePlugin(for: targets)
        }
    }

    private enum Operation: Equatable {
        case install
        case uninstall
    }

    private struct MarketplaceClient {
        let name: String
        let executable: String
        let installArguments: [String]
        let uninstallArguments: [String]
    }

    private static func loadSkillMarkdown() throws -> String {
        guard let sourceURL = Bundle.module.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "skills/axe"
        ) else {
            throw CLIError(errorDescription: "Bundled AXe skill source was not found.")
        }

        do {
            return try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            throw CLIError(errorDescription: "Failed to read bundled AXe skill source: \(error.localizedDescription)")
        }
    }

    private func installMarketplacePlugin(for targets: [MarketplaceClient]) throws {
        guard !targets.isEmpty else {
            throw CLIError(errorDescription: "No marketplace clients resolved.")
        }

        for target in targets {
            if force {
                _ = try? runMarketplaceCommand(
                    executable: target.executable,
                    arguments: target.uninstallArguments,
                    for: target.name
                )
            }

            _ = try runMarketplaceCommand(
                executable: target.executable,
                arguments: ["plugin", "marketplace", "add", Self.marketplaceSource],
                for: target.name
            )
            _ = try runMarketplaceCommand(
                executable: target.executable,
                arguments: target.installArguments,
                for: target.name
            )
            fputs("Installed AXe marketplace plugin -> \(target.name)\n", stdout)
        }
    }

    private func uninstallMarketplacePlugin(from targets: [MarketplaceClient]) throws {
        guard !targets.isEmpty else {
            fputs("No supported marketplace clients were detected.\n", stdout)
            return
        }

        for target in targets {
            _ = try runMarketplaceCommand(
                executable: target.executable,
                arguments: target.uninstallArguments,
                for: target.name
            )
            fputs("Uninstalled AXe marketplace plugin -> \(target.name)\n", stdout)
        }
    }

    private func runMarketplaceCommand(
        executable: String,
        arguments: [String],
        for clientName: String
    ) throws -> String {
        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
        } catch {
            throw CLIError(
                errorDescription: "Failed to launch \(executable) for \(clientName): \(error.localizedDescription)"
            )
        }

        process.waitUntilExit()

        let standardOutput = String(
            data: standardOutputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let standardError = String(
            data: standardErrorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let output = [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            let command = ([executable] + arguments).joined(separator: " ")
            let details = output.isEmpty ? "exit status \(process.terminationStatus)" : output
            throw CLIError(
                errorDescription: "Marketplace command failed for \(clientName): \(command)\n\(details)"
            )
        }

        return output
    }

    private func installSkill(to skillsDirectory: URL) throws {
        let skillMarkdown = try Self.loadSkillMarkdown()
        let targetDirectory = skillsDirectory.appendingPathComponent("axe", isDirectory: true)
        let targetFile = targetDirectory.appendingPathComponent("SKILL.md", isDirectory: false)

        if FileManager.default.fileExists(atPath: targetFile.path), !force {
            throw CLIError(
                errorDescription: "Skill already installed at \(targetFile.path). Re-run with --force to overwrite."
            )
        }

        do {
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            try skillMarkdown.write(to: targetFile, atomically: true, encoding: .utf8)
            fputs("Installed AXe skill -> Custom: \(targetFile.path)\n", stdout)
        } catch {
            throw CLIError(
                errorDescription: "Failed to install AXe skill at custom destination: \(error.localizedDescription)"
            )
        }
    }

    private func uninstallSkill(from skillsDirectory: URL) throws {
        let targetDirectory = skillsDirectory.appendingPathComponent("axe", isDirectory: true)
        guard FileManager.default.fileExists(atPath: targetDirectory.path) else {
            fputs("No installed AXe skill directory was found.\n", stdout)
            return
        }

        do {
            try FileManager.default.removeItem(at: targetDirectory)
            fputs("Removed AXe skill -> Custom: \(targetDirectory.path)\n", stdout)
        } catch {
            throw CLIError(
                errorDescription: "Failed to uninstall AXe skill from custom destination: \(error.localizedDescription)"
            )
        }
    }

    private func resolveMarketplaceClients(for operation: Operation) throws -> [MarketplaceClient] {
        if client != .auto {
            let resolvedClient = try Self.marketplaceClient(for: client)
            guard Self.isExecutableAvailable(resolvedClient.executable) else {
                throw CLIError(
                    errorDescription: "\(resolvedClient.name) executable '\(resolvedClient.executable)' was not found in PATH."
                )
            }
            return [resolvedClient]
        }

        let detected = Self.detectMarketplaceClients()
        if detected.isEmpty, operation == .install {
            throw CLIError(
                errorDescription: "No supported AI clients detected. Install Claude Code or Codex, or use --dest or --print."
            )
        }

        return detected
    }

    private static func detectMarketplaceClients() -> [MarketplaceClient] {
        [Client.claude, Client.codex]
            .compactMap { client in
                guard let info = try? marketplaceClient(for: client), isExecutableAvailable(info.executable) else {
                    return nil
                }
                return info
            }
    }

    private static func marketplaceClient(for client: Client) throws -> MarketplaceClient {
        switch client {
        case .claude:
            return MarketplaceClient(
                name: "Claude Code",
                executable: "claude",
                installArguments: ["plugin", "install", pluginIdentifier],
                uninstallArguments: ["plugin", "uninstall", pluginIdentifier]
            )
        case .codex:
            return MarketplaceClient(
                name: "Codex",
                executable: "codex",
                installArguments: ["plugin", "add", pluginIdentifier],
                uninstallArguments: ["plugin", "remove", pluginIdentifier]
            )
        case .auto, .agents:
            throw CLIError(errorDescription: "The selected client is not a marketplace target.")
        }
    }

    private static func isExecutableAvailable(_ executable: String) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else {
            return false
        }

        return path
            .split(separator: ":")
            .map(String.init)
            .contains { directory in
                let candidate = URL(fileURLWithPath: directory)
                    .appendingPathComponent(executable, isDirectory: false)
                    .path
                return FileManager.default.isExecutableFile(atPath: candidate)
            }
    }

    private static func homeDirectoryPath() -> String {
        ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func agentsSkillsDirectory() -> URL {
        URL(fileURLWithPath: homeDirectoryPath())
            .appendingPathComponent(".agents/skills", isDirectory: true)
    }

    private func isInteractiveTTY() -> Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    private static func resolveDestinationURL(from rawValue: String) throws -> URL {
        let expandedPath = expandHomePrefix(rawValue)
        let standardizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path

        guard standardizedPath != "/" else {
            throw CLIError(errorDescription: "Refusing to use filesystem root as skills destination.")
        }

        return URL(fileURLWithPath: standardizedPath, isDirectory: true)
    }

    private static func expandHomePrefix(_ path: String) -> String {
        if path == "~" {
            return homeDirectoryPath()
        }

        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return URL(fileURLWithPath: homeDirectoryPath()).appendingPathComponent(suffix).path
        }

        return path
    }
}
