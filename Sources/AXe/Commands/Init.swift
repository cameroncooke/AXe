import ArgumentParser
import Darwin
import Foundation

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Install AXe skill files for detected AI clients."
    )

    enum Client: String, ExpressibleByArgument, CaseIterable {
        case auto
        case claude
        case agents
    }

    @Option(help: "Target client: auto, claude, or agents. Defaults to auto-detect.")
    var client: Client = .auto

    @Option(help: "Custom destination skills directory (overrides --client).")
    var dest: String?

    @Flag(help: "Overwrite an existing installed skill.")
    var force: Bool = false

    @Flag(help: "Remove installed AXe skill from target directories.")
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
                errorDescription: "Non-interactive mode requires --client or --dest for init. Use --print to output the skill content.", code: .invalidArguments
            )
        }

        if printSkill {
            let content = try Self.loadSkillMarkdown()
            if CLIOutput.isFormatted { try CLIOutput.writeJSON(InitOutput(content: content)) }
            else { CLIOutput.message(content, terminator: "") }
            return
        }

        let targets = try resolveTargets(for: uninstall ? .uninstall : .install)

        if uninstall {
            try uninstallSkill(from: targets)
            return
        }

        try installSkill(to: targets)
    }

    private enum Operation {
        case install
        case uninstall
    }

    private struct ClientInfo {
        let id: Client
        let name: String
        let skillsDirectory: URL
    }

    private static func bundledSkillFile() throws -> URL {
        guard let sourceURL = Bundle.module.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "skills/axe"
        ) else {
            throw CLIError(errorDescription: "Bundled AXe skill source was not found.", code: .readFailed)
        }
        return sourceURL
    }

    private static func loadSkillMarkdown() throws -> String {
        let sourceURL = try bundledSkillFile()
        do {
            return try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            throw CLIError(errorDescription: "Failed to read bundled AXe skill source: \(error.localizedDescription)", code: .readFailed)
        }
    }

    private func installSkill(to targets: [ClientInfo]) throws {
        // SKILL.md links to files in references/, so install the whole bundled skill directory.
        let sourceDirectory = try Self.bundledSkillFile().deletingLastPathComponent()
        let fileManager = FileManager.default
        var installed: [InitOutput.Entry] = []

        for target in targets {
            let targetDirectory = target.skillsDirectory.appendingPathComponent("axe", isDirectory: true)
            let targetFile = targetDirectory.appendingPathComponent("SKILL.md", isDirectory: false)

            if fileManager.fileExists(atPath: targetFile.path), !force {
                throw CLIError(
                    errorDescription: "Skill already installed at \(targetFile.path). Re-run with --force to overwrite.", code: .outputFailed
                )
            }
            if fileManager.fileExists(atPath: targetDirectory.path), !force {
                throw CLIError(
                    errorDescription: "Skill directory already exists at \(targetDirectory.path). Re-run with --force to overwrite.", code: .outputFailed
                )
            }

            // Copy beside the target first, so a failed copy leaves an existing install in place.
            let stagingDirectory = target.skillsDirectory.appendingPathComponent(
                ".axe-install-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: target.skillsDirectory, withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceDirectory, to: stagingDirectory)
                if fileManager.fileExists(atPath: targetDirectory.path) {
                    _ = try fileManager.replaceItemAt(targetDirectory, withItemAt: stagingDirectory)
                } else {
                    try fileManager.moveItem(at: stagingDirectory, to: targetDirectory)
                }
                installed.append(InitOutput.Entry(client: target.name, path: targetFile.path))
            } catch {
                try? fileManager.removeItem(at: stagingDirectory)
                throw CLIError(
                    errorDescription: "Failed to install AXe skill for \(target.name): \(error.localizedDescription)", code: .outputFailed
                )
            }
        }

        if installed.isEmpty {
            throw CLIError(errorDescription: "No install targets resolved.", code: .invalidArguments)
        }

        try DeviceState.emit(InitOutput(installed: installed),
            text: installed.map { "Installed AXe skill -> \($0.client): \($0.path)" })
    }

    private func uninstallSkill(from targets: [ClientInfo]) throws {
        var removed: [InitOutput.Entry] = []

        for target in targets {
            let targetDirectory = target.skillsDirectory.appendingPathComponent("axe", isDirectory: true)
            guard FileManager.default.fileExists(atPath: targetDirectory.path) else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: targetDirectory)
                removed.append(InitOutput.Entry(client: target.name, path: targetDirectory.path))
            } catch {
                throw CLIError(
                    errorDescription: "Failed to uninstall AXe skill for \(target.name): \(error.localizedDescription)", code: .outputFailed
                )
            }
        }

        let text = removed.isEmpty ? ["No installed AXe skill directories were found."]
            : removed.map { "Removed AXe skill -> \($0.client): \($0.path)" }
        try DeviceState.emit(InitOutput(removed: removed), text: text)
    }

    private func resolveTargets(for operation: Operation) throws -> [ClientInfo] {
        if let destination = dest {
            let resolvedDestination = try Self.resolveDestinationURL(from: destination)
            return [ClientInfo(id: .auto, name: "Custom", skillsDirectory: resolvedDestination)]
        }

        if client != .auto {
            return [try Self.clientInfo(for: client)]
        }

        let detected = Self.detectClients()
        if detected.isEmpty {
            if operation == .uninstall {
                return []
            }

            throw CLIError(
                errorDescription: "No supported AI clients detected. Use --client, --dest, or --print.", code: .outputFailed
            )
        }

        return detected
    }

    private static func detectClients() -> [ClientInfo] {
        Client.allCases
            .filter { $0 != .auto }
            .compactMap { try? clientInfoIfDetected(for: $0) }
    }

    private static func clientInfoIfDetected(for client: Client) throws -> ClientInfo? {
        let homeDirectory = homeDirectoryPath()
        let clientRootPath: String

        switch client {
        case .claude:
            clientRootPath = homeDirectory + "/.claude"
        case .agents:
            clientRootPath = homeDirectory + "/.agents"
        case .auto:
            return nil
        }

        guard FileManager.default.fileExists(atPath: clientRootPath) else {
            return nil
        }

        return try clientInfo(for: client)
    }

    private static func clientInfo(for client: Client) throws -> ClientInfo {
        let homeDirectory = homeDirectoryPath()

        switch client {
        case .claude:
            return ClientInfo(
                id: .claude,
                name: "Claude Code",
                skillsDirectory: URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude/skills", isDirectory: true)
            )
        case .agents:
            return ClientInfo(
                id: .agents,
                name: "Agents Skills",
                skillsDirectory: URL(fileURLWithPath: homeDirectory).appendingPathComponent(".agents/skills", isDirectory: true)
            )
        case .auto:
            throw CLIError(errorDescription: "Auto is not a concrete client target.", code: .invalidArguments)
        }
    }

    private static func homeDirectoryPath() -> String {
        ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func isInteractiveTTY() -> Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    private static func resolveDestinationURL(from rawValue: String) throws -> URL {
        let expandedPath = expandHomePrefix(rawValue)
        let standardizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path

        guard standardizedPath != "/" else {
            throw CLIError(errorDescription: "Refusing to use filesystem root as skills destination.", code: .outputFailed)
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

/// One of `installed`, `removed` (possibly empty) or `content` (`--print`).
struct InitOutput: Encodable {
    struct Entry: Encodable {
        let client: String
        let path: String
    }
    var installed: [Entry]? = nil
    var removed: [Entry]? = nil
    var content: String? = nil
}
