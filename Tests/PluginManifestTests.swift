import Foundation
import Testing

@Suite("Plugin manifests")
struct PluginManifestTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Claude Code and Codex cache an installed plugin by its manifest version, so a version that
    /// is not raised at release keeps users on the skill they first installed.
    @Test("Plugin versions match the latest released version")
    func versionsMatchLatestRelease() throws {
        let changelog = try String(contentsOf: repository.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let released = try #require(changelog.split(separator: "\n").lazy
            .compactMap { line -> String? in
                guard line.hasPrefix("## [v"), let end = line.firstIndex(of: "]") else { return nil }
                return String(line[line.index(line.startIndex, offsetBy: 5)..<end])
            }.first, "CHANGELOG.md has no released version heading")

        for path in ["agent-plugin/.claude-plugin/plugin.json", "agent-plugin/.codex-plugin/plugin.json"] {
            let data = try Data(contentsOf: repository.appendingPathComponent(path))
            let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(manifest["version"] as? String == released,
                    "\(path) version must be \(released), the latest release in CHANGELOG.md, so installed plugins update.")
        }
    }

    @Test("Plugin manifests point at the shipped skill")
    func skillPaths() throws {
        for (path, skills) in [("agent-plugin/.claude-plugin/plugin.json", "./skills/"), ("agent-plugin/.codex-plugin/plugin.json", "./skills/axe")] {
            let data = try Data(contentsOf: repository.appendingPathComponent(path))
            let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(manifest["skills"] as? String == skills)
        }
        #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent("agent-plugin/skills/axe/SKILL.md").path))
    }
}
