import Foundation
import Testing

@Suite("Init Command Tests")
struct InitTests {
    @Test("print outputs skill content")
    func printOutputsSkill() async throws {
        let result = try await TestHelpers.runAxeCommand("init --print")
        #expect(result.output.contains("name: axe"))
        #expect(result.output.contains("Drives iOS Simulator apps through the AXe CLI's agent mode"))
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

    @Test("install includes the reference files SKILL.md links to")
    func installIncludesReferences() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try await TestHelpers.runAxeCommand("init --dest \(skillsDir.path)")

        let installed = skillsDir.appendingPathComponent("axe", isDirectory: true)
        let skill = try String(contentsOf: installed.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"\]\((references/[A-Za-z0-9-]+\.md)"#)
        let matches = pattern.matches(in: skill, range: NSRange(skill.startIndex..., in: skill))
        let linked = Set(matches.compactMap { Range($0.range(at: 1), in: skill).map { String(skill[$0]) } })
        #expect(linked.contains("references/batch-reference.md"))
        for path in linked {
            #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent(path).path), "\(path)")
        }
    }

    @Test("forced install replaces the whole skill directory")
    func forcedInstallReplacesDirectory() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        let installedDir = skillsDir.appendingPathComponent("axe", isDirectory: true)
        let stale = installedDir.appendingPathComponent("references/stale-reference.md")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(
            at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old-content".write(to: installedDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "stale".write(to: stale, atomically: true, encoding: .utf8)

        _ = try await TestHelpers.runAxeCommand("init --dest \(skillsDir.path) --force")

        let skill = try String(contentsOf: installedDir.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(skill.contains("name: axe"))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(
            atPath: installedDir.appendingPathComponent("references/agent-reference.md").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: skillsDir.path)
        #expect(leftovers == ["axe"])
    }

    @Test("existing skill directory without SKILL.md requires force")
    func existingDirectoryRequiresForce() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        let installedDir = skillsDir.appendingPathComponent("axe", isDirectory: true)
        let userFile = installedDir.appendingPathComponent("notes.md")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try "keep".write(to: userFile, atomically: true, encoding: .utf8)

        let result = try await TestHelpers.runAxeCommandAllowFailure("init --dest \(skillsDir.path)")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("Skill directory already exists at \(installedDir.path). Re-run with --force to overwrite."))
        #expect(FileManager.default.fileExists(atPath: userFile.path))
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
