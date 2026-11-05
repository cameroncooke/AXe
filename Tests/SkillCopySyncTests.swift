import Foundation
import Testing

@Suite("Skill copy sync")
struct SkillCopySyncTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test
    func bundledSkillMatchesSource() throws {
        let source = repository.appendingPathComponent("Skills/CLI/axe")
        let bundled = repository.appendingPathComponent("Sources/AXe/Resources/skills/axe")
        let sourceFiles = try files(under: source)
        let bundledFiles = try files(under: bundled)

        var problems: [String] = []
        for path in sourceFiles.keys.sorted() {
            guard let copy = bundledFiles[path] else {
                problems.append("missing from bundled copy: \(path)")
                continue
            }
            if copy != sourceFiles[path] {
                problems.append("differs: \(path)")
            }
        }
        for path in bundledFiles.keys.sorted() where sourceFiles[path] == nil {
            problems.append("only in bundled copy: \(path)")
        }

        #expect(
            problems.isEmpty,
            """
            Sources/AXe/Resources/skills/axe (installed by `axe init`) must be byte-identical to Skills/CLI/axe.
            Edit Skills/CLI/axe, then copy it over: rsync -a --delete Skills/CLI/axe/ Sources/AXe/Resources/skills/axe/
            \(problems.joined(separator: "\n"))
            """
        )
    }

    private func files(under root: URL) throws -> [String: Data] {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            Issue.record("cannot read \(rootPath)")
            return [:]
        }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            result[path] = try Data(contentsOf: url)
        }
        return result
    }
}
