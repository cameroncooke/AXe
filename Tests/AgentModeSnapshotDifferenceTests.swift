import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

@Suite("Agent native snapshot refusal diagnostics")
struct AgentModeSnapshotDifferenceTests {
    @Test("Reports changed native fields without exposing node content")
    func reportsFieldsWithoutContent() throws {
        let before = try nodes([fixture(label: "private-before", value: "secret-before")])
        let after = try nodes([fixture(label: "private-after", value: "secret-after", x: 11)])
        let summary = AgentModeSnapshotDifference.summary(previous: before, current: after)
        #expect(summary.contains("pairedChanges=1"))
        #expect(summary.contains("frame=1") && summary.contains("label=1") && summary.contains("value=1"))
        #expect(summary.contains("node[0]@0:"))
        #expect(!summary.contains("private") && !summary.contains("secret"))
    }

    @Test("Logs at most eight node samples while retaining complete change counts")
    func boundsSamples() throws {
        let before = try nodes((0..<100).map { fixture(label: "before\($0)") })
        let after = try nodes((0..<100).map { fixture(label: "after\($0)") })
        let summary = AgentModeSnapshotDifference.summary(previous: before, current: after)
        #expect(summary.contains("pairedChanges=100") && summary.contains("label=100"))
        #expect(summary.components(separatedBy: "node[").count - 1 == 8)
        #expect(summary.utf8.count < 4096)
    }

    @Test("Shows node-count and hierarchy changes separately from native fields")
    func reportsHierarchyChanges() throws {
        let child = fixture(label: "child")
        let before = try nodes([fixture(children: [child])])
        let after = try nodes([fixture(), child, fixture()])
        let summary = AgentModeSnapshotDifference.summary(previous: before, current: after)
        #expect(summary.contains("nodes=2->3"))
        #expect(summary.contains("children=1") && summary.contains("path=1"))
        #expect(summary.contains("node[1]@0.0:path"))
    }

    private func nodes(_ roots: [AXNodeFixture]) throws -> [FBSimulatorAXNode] {
        func flatten(_ node: FBSimulatorAXNode) -> [FBSimulatorAXNode] {
            [node] + node.children.flatMap(flatten)
        }
        return try AXNodeFixture.decode(roots).flatMap(flatten)
    }

    private func fixture(label: String = "label", value: String? = nil, x: Double = 10,
                         children: [AXNodeFixture] = []) -> AXNodeFixture {
        AXNodeFixture(type: "StaticText", label: label, value: value.map { .string($0) },
            frame: .init(x: x, y: 100, width: 100, height: 44), pid: 1234, enabled: true, hidden: false,
            children: children)
    }
}
