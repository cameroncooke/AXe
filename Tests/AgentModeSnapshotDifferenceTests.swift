import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

@Suite("Agent native snapshot refusal diagnostics")
struct AgentModeSnapshotDifferenceTests {
    @Test("Reports changed native fields without exposing node content")
    func reportsFieldsWithoutContent() throws {
        let before = try nodes([Fixture(label: "private-before", value: "secret-before")])
        let after = try nodes([Fixture(label: "private-after", value: "secret-after", frame: .init(x: 11))])
        let summary = AgentModeSnapshotDifference.summary(previous: before, current: after)
        #expect(summary.contains("pairedChanges=1"))
        #expect(summary.contains("frame=1") && summary.contains("label=1") && summary.contains("value=1"))
        #expect(summary.contains("node[0]@0:"))
        #expect(!summary.contains("private") && !summary.contains("secret"))
    }

    @Test("Logs at most eight node samples while retaining complete change counts")
    func boundsSamples() throws {
        let before = try nodes((0..<100).map { Fixture(label: "before\($0)") })
        let after = try nodes((0..<100).map { Fixture(label: "after\($0)") })
        let summary = AgentModeSnapshotDifference.summary(previous: before, current: after)
        #expect(summary.contains("pairedChanges=100") && summary.contains("label=100"))
        #expect(summary.components(separatedBy: "node[").count - 1 == 8)
        #expect(summary.utf8.count < 4096)
    }

    @Test("Shows node-count and hierarchy changes separately from native fields")
    func reportsHierarchyChanges() throws {
        let child = Fixture(label: "child")
        let before = try nodes([Fixture(children: [child])])
        let after = try nodes([Fixture(), child, Fixture()])
        let summary = AgentModeSnapshotDifference.summary(previous: before, current: after)
        #expect(summary.contains("nodes=2->3"))
        #expect(summary.contains("children=1") && summary.contains("path=1"))
        #expect(summary.contains("node[1]@0.0:path"))
    }

    private func nodes(_ roots: [Fixture]) throws -> [FBSimulatorAXNode] {
        let decoded = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode(roots))
        func flatten(_ node: FBSimulatorAXNode) -> [FBSimulatorAXNode] {
            [node] + node.children.flatMap(flatten)
        }
        return decoded.flatMap(flatten)
    }

    private struct Fixture: Encodable {
        struct Frame: Encodable {
            var x = 10.0
            let y = 100.0
            let width = 100.0
            let height = 44.0
        }
        let type = "StaticText"
        var label = "label"
        var value: String? = nil
        var frame = Frame()
        var children: [Fixture] = []
        let pid: Int32 = 1234
        let enabled = true
        let hidden = false
        private enum CodingKeys: String, CodingKey {
            case type, label = "AXLabel", value = "AXValue", frame, children, pid, enabled, hidden
        }
    }
}
