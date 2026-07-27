import Darwin
import Foundation
import Testing

@Suite("Init Command Tests")
struct InitTests {
    private func runWithFakeClient(
        _ command: String,
        executable: String
    ) async throws -> (output: String, invocations: [String]) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binDirectory = tempRoot.appendingPathComponent("bin", isDirectory: true)
        let executableURL = binDirectory.appendingPathComponent(executable, isDirectory: false)
        let logURL = tempRoot.appendingPathComponent("invocations.log", isDirectory: false)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$AXE_INIT_TEST_LOG"
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        guard chmod(executableURL.path, 0o755) == 0 else {
            throw TestError.unexpectedState("Failed to make fake \(executable) executable")
        }

        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let result = try await TestHelpers.runAxeCommand(
            command,
            environment: [
                "AXE_INIT_TEST_LOG": logURL.path,
                "HOME": tempRoot.path,
                "PATH": "\(binDirectory.path):\(existingPath)"
            ]
        )
        let log = try String(contentsOf: logURL, encoding: .utf8)
        let invocations = log.split(whereSeparator: { $0.isNewline }).map(String.init)
        return (result.output, invocations)
    }

    @Test("print outputs skill content")
    func printOutputsSkill() async throws {
        let result = try await TestHelpers.runAxeCommand("init --print")
        #expect(result.output.contains("name: axe"))
        #expect(result.output.contains("Provides agent-ready AXe CLI usage guidance"))
    }

    @Test("installs skill to custom destination")
    func installsToCustomDestination() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        _ = try await TestHelpers.runAxeCommand("init --dest \(skillsDir.path)")

        let installedFile = skillsDir.appendingPathComponent("axe/SKILL.md").path
        #expect(FileManager.default.fileExists(atPath: installedFile))
    }

    @Test("agents client installs to agents skills directory")
    func agentsClientInstallsToAgentsSkillsDirectory() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let environment = ["HOME": tempRoot.path]
        _ = try await TestHelpers.runAxeCommand("init --client agents", environment: environment)

        let installedDirectory = tempRoot.appendingPathComponent(".agents/skills/axe", isDirectory: true)
        let installedFile = installedDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: installedFile.path))

        _ = try await TestHelpers.runAxeCommand(
            "init --client agents --uninstall",
            environment: environment
        )
        #expect(!FileManager.default.fileExists(atPath: installedDirectory.path))
    }

    @Test("installs Claude plugin through marketplace")
    func installsClaudeMarketplacePlugin() async throws {
        let result = try await runWithFakeClient("init --client claude", executable: "claude")

        #expect(result.invocations == [
            "plugin marketplace add cameroncooke/AXe",
            "plugin install axe@axe"
        ])
        #expect(result.output.contains("Installed AXe marketplace plugin -> Claude Code"))
    }

    @Test("installs Codex plugin through marketplace")
    func installsCodexMarketplacePlugin() async throws {
        let result = try await runWithFakeClient("init --client codex", executable: "codex")

        #expect(result.invocations == [
            "plugin marketplace add cameroncooke/AXe",
            "plugin add axe@axe"
        ])
        #expect(result.output.contains("Installed AXe marketplace plugin -> Codex"))
    }

    @Test("force reinstalls marketplace plugin")
    func forceReinstallsMarketplacePlugin() async throws {
        let result = try await runWithFakeClient("init --client codex --force", executable: "codex")

        #expect(result.invocations == [
            "plugin remove axe@axe",
            "plugin marketplace add cameroncooke/AXe",
            "plugin add axe@axe"
        ])
    }

    @Test("uninstall removes marketplace plugin")
    func uninstallRemovesMarketplacePlugin() async throws {
        let result = try await runWithFakeClient("init --client claude --uninstall", executable: "claude")

        #expect(result.invocations == ["plugin uninstall axe@axe"])
        #expect(result.output.contains("Uninstalled AXe marketplace plugin -> Claude Code"))
    }

    @Test("existing skill requires force")
    func existingSkillRequiresForce() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        let installedDir = skillsDir.appendingPathComponent("axe", isDirectory: true)
        let installedFile = installedDir.appendingPathComponent("SKILL.md", isDirectory: false)

        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try "old-content".write(to: installedFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let failedResult = try await TestHelpers.runAxeCommandAllowFailure("init --dest \(skillsDir.path)")
        #expect(failedResult.exitCode != 0)
        #expect(failedResult.output.contains("Skill already installed at \(installedFile.path). Re-run with --force to overwrite."))
        #expect(!failedResult.output.contains("CLIError(errorDescription:"))

        _ = try await TestHelpers.runAxeCommand("init --dest \(skillsDir.path) --force")
        let newContent = try String(contentsOf: installedFile, encoding: .utf8)
        #expect(newContent.contains("name: axe"))
    }

    @Test("uninstall removes installed directory")
    func uninstallRemovesInstalledDirectory() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        _ = try await TestHelpers.runAxeCommand("init --dest \(skillsDir.path)")
        _ = try await TestHelpers.runAxeCommand("init --dest \(skillsDir.path) --uninstall")

        let installedDirectory = skillsDir.appendingPathComponent("axe", isDirectory: true).path
        #expect(!FileManager.default.fileExists(atPath: installedDirectory))
    }

    @Test("non-interactive mode requires explicit target")
    func nonInteractiveModeRequiresExplicitTarget() async throws {
        let result = try await TestHelpers.runAxeCommandAllowFailure("init")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("Non-interactive mode requires --client or --dest"))
    }

    @Test("refuses root destination")
    func refusesRootDestination() async throws {
        let result = try await TestHelpers.runAxeCommandAllowFailure("init --dest /")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("filesystem root"))
    }
}
