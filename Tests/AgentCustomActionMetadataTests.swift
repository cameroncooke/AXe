import ArgumentParser
import AXeCore
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Agent read-only custom-action metadata")
struct AgentCustomActionMetadataTests {
    @Test("Exact names survive core encoding, old documents and snapshot projection without new tap authority")
    func metadataRoundTripDoesNotGrantInput() throws {
        let names = [" Delete ", "A|B", "e\u{301} 👩🏽‍💻", "Delete", "Delete"]
        let plain = RuntimeSnapshotNode(type: "GenericElement", label: "Item", frame: frame)
        let observed = RuntimeSnapshotNode(type: "GenericElement", label: "Item", frame: frame,
            customActionNames: names)
        let before = try #require(RuntimeSnapshotBuilder.elements(from: [plain]).first)
        let after = try #require(RuntimeSnapshotBuilder.elements(from: [observed]).first)
        #expect(after.actions == before.actions && !after.actions.contains(.tap))
        #expect(after.customActionNames == names)
        let roundTrip = try JSONDecoder().decode(RuntimeSnapshotElement.self, from: JSONEncoder().encode(after))
        #expect(roundTrip == after)
        let value = try JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(before))
        guard case var .object(old) = value else { throw AgentModeFailure("fixture", "Expected an object.") }
        old.removeValue(forKey: "customActionNames")
        let oldDecoded = try JSONDecoder().decode(RuntimeSnapshotElement.self,
            from: JSONEncoder().encode(CLIOutputValue.object(old)))
        #expect(oldDecoded.customActionNames.isEmpty && oldDecoded.actions == before.actions)
        // Keep the original core customActions input contract separate and unchanged.
        let legacy = RuntimeSnapshotBuilder.elements(from: [RuntimeSnapshotNode(type: "Other",
            label: "Item", frame: frame, customActions: ["Delete"])])
        #expect(legacy.first?.actions.contains(.tap) == true)
        let (snapshot, _) = try makeSnapshot([Fixture(type: "GenericElement", customActionNames: names)])
        #expect(snapshot.elements[1].customActionNames == names)
        #expect(snapshot.semanticElements[1].customActionNames == names)
        #expect(!snapshot.elements[1].actions.contains(.tap))
        #expect(throws: AgentModeFailure.self) { _ = try snapshot.node(ref: "e2", requiredAction: .tap) }
    }

    @Test("A name-only change invalidates normalized and exact native freshness checks")
    func changedNamesInvalidateFreshness() throws {
        let (before, context) = try makeSnapshot([Fixture(customActionNames: ["Delete"])])
        let (after, _) = try makeSnapshot([Fixture(customActionNames: ["Archive"])])
        #expect(before.hash != after.hash && before.nativeFingerprint != after.nativeFingerprint)
        let admission = AgentModeAdmission(context: context, expectedPID: 1234,
            screenHash: before.hash, nativeFingerprint: before.nativeFingerprint, visibleFingerprint: before.visibleFingerprint, target: nil)
        try admission.validateScreen(before)
        do {
            try admission.validateScreen(after)
            Issue.record("Changed names retained stale input authority.")
        } catch let error as AgentModeFailure { #expect(error.code == "screenChanged") }
        let summary = AgentModeSnapshotDifference.summary(previous: before.nodes, current: after.nodes)
        #expect(summary.contains("customActionNames=1"))
        #expect(!summary.contains("Delete") && !summary.contains("Archive"))
        #expect(before.elements[1].actions == after.elements[1].actions)
    }

    @Test("Reference batches reject changed names even when values and ordinary text may change")
    func batchNamesStayBound() throws {
        let table = UUID()
        let (before, context) = try makeSnapshot([Fixture(customActionNames: ["Delete"])])
        let (after, _) = try makeSnapshot([Fixture(customActionNames: ["Archive"])])
        let document = try JSONDecoder().decode(AgentBatchDocument.self, from: Data("""
            {"snapshotID":"\(table.uuidString)","steps":[{"action":"tap","ref":"e2"}]}
            """.utf8))
        let request = AgentBatchRequest(expectedPID: nil, snapshotID: document.snapshotID, steps: document.steps)
        let plan = try AgentBatchReferencePlan(request: request, snapshotID: table,
            snapshot: before, context: context, pid: 1234)
        _ = try plan.resolve(index: 0, snapshot: before, context: context, pid: 1234)
        do {
            _ = try plan.resolve(index: 0, snapshot: after, context: context, pid: 1234)
            Issue.record("A changed custom-action list retained a reference batch.")
        } catch let error as AgentModeFailure { #expect(error.code == "batchLayoutChanged") }
    }

    @Test("Both views keep bounded previews and complete JSON names can be read in exact scalar chunks")
    func boundedPreviewAndCompleteRead() throws {
        let names = [String(repeating: "👩🏽‍💻", count: 100), "A|B", "\"quoted\"\n", "Delete", "Delete", " last "]
        let (snapshot, context) = try makeSnapshot([Fixture(customActionNames: names)])
        let capture = snapshot.capture(id: UUID(), sequence: 1, udid: "fixture", request: .init(kind: .describe),
            applicationPID: 1234, context: context, unchanged: false, expiresIn: 60)
        let unchanged = snapshot.capture(id: UUID(), sequence: 1, udid: "fixture", request: .init(kind: .describe),
            applicationPID: 1234, context: context, unchanged: true, expiresIn: 60)
        #expect(unchanged.customActions == nil && unchanged.truncatedCustomActionRefs == nil)
        let preview = try #require(capture.customActions?["e2"])
        #expect(preview.count == 4 && preview.allSatisfy { $0.unicodeScalars.count <= 96 })
        #expect(capture.truncatedCustomActionRefs == ["e2"])
        for view in [AgentOutputView.full, .reading, .navigation] {
            let projected = try AgentOutputProjection.project(result(capture), view: view)
            let output = try #require(projected["data"]?["capture"])
            if view == .full {
                #expect(output["customActions"]?["e2"]?.arrayValue?.count == 4)
                #expect(output["customActionGroups"] == nil)
            } else {
                #expect(output["customActions"] == nil)
                let group = try #require(output["customActionGroups"]?.arrayValue?.first)
                #expect(group["refs"]?.arrayValue?.first?.stringValue == "e2")
                #expect(group["names"]?.arrayValue?.count == 4)
            }
            #expect(output["truncatedCustomActionRefs"]?.arrayValue?.first?.stringValue == "e2")
            if view != .full {
                let row = try #require(output["rows"]?.arrayValue?.first?.stringValue)
                #expect(row.split(separator: "|", omittingEmptySubsequences: false).count == 5)
            }
        }
        var offset = 0
        var full = ""
        while true {
            let detail = try snapshot.detail(ref: "e2", query: .init(field: .customActions, offset: offset, limit: 7))
            #expect(detail.text.unicodeScalars.count <= 7 && detail.actions == snapshot.elements[1].actions)
            full += detail.text
            guard let next = detail.nextOffset else { break }
            #expect(next > offset)
            offset = next
        }
        #expect(try JSONDecoder().decode([String].self, from: Data(full.utf8)) == names)
        #expect(full.unicodeScalars.count > 96)
        let empty = try snapshot.detail(ref: "e1", query: .init(field: .customActions, offset: 0, limit: 1024))
        #expect(empty.text == "[]" && empty.nextOffset == nil)
    }

    @Test("Metadata bytes participate in adaptive paging without leaking later refs")
    func previewBytesUseExistingPageBudget() throws {
        let names = (1...6).map { String(repeating: "\"", count: 120) + String($0) }
        let (snapshot, context) = try makeSnapshot((1...64).map {
            Fixture(id: "item.\($0)", label: "Item \($0)", customActionNames: names)
        })
        var offset = 0
        var recovered = Set<String>()
        var pages = 0
        while true {
            let capture = snapshot.capture(id: UUID(), sequence: 1, udid: "fixture",
                request: .init(kind: .describe, rowOffset: offset, rowLimit: 64),
                applicationPID: 1234, context: context, unchanged: false, expiresIn: 60)
            let projected = try AgentOutputProjection.project(result(capture), view: .reading)
            let output = try #require(projected["data"]?["capture"])
            #expect(try JSONEncoder().encode(output).count <= AgentOutputProjection.maximumCaptureBytes)
            let rows = try #require(output["rows"]?.arrayValue)
            let refs = Set(rows.compactMap(\.stringValue).map { String($0.prefix { $0 != "|" }) })
            let groups = try #require(output["customActionGroups"]?.arrayValue)
            let metadataRefs = groups.flatMap { $0["refs"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
            #expect(output["customActions"] == nil)
            #expect(Set(metadataRefs) == refs && metadataRefs.count == refs.count && recovered.isDisjoint(with: refs))
            recovered.formUnion(refs)
            pages += 1
            guard let next = output["page"]?["nextOffset"]?.scalarText.flatMap(Int.init) else { break }
            #expect(next > offset && pages < 64)
            offset = next
        }
        #expect(recovered.count == 64 && pages == 1)
    }

    @Test("Custom-action readback is an agent-only read request, not an execution verb")
    func cliReadContract() throws {
        let command = try DescribeUI.parse(["--agent", "--udid", "fixture",
            "--snapshot-id", UUID().uuidString, "--read-ref", "e2", "--text-field", "custom-actions"])
        try command.validate()
        let request = try command.agentRequest()
        #expect(request.agent?.kind == .read && request.agent?.textQuery?.field == .customActions)
        #expect(SelectedHIDRequest.version == 83)
    }

    private var frame: AgentFrame { AgentFrame(x: 10, y: 100, width: 300, height: 44) }

    private func result(_ capture: AgentModeCapture) throws -> CLIOutputValue {
        let value = try JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(capture))
        return .object(["schema": .string("axe.output.agent-result"), "schemaVersion": .string("1"),
            "didError": .bool(false), "data": .object(["capture": value])])
    }

    private func makeSnapshot(_ children: [Fixture]) throws -> (AgentModeSnapshot, SelectedHIDContext) {
        let context = try JSONDecoder().decode(SelectedHIDContext.self, from: Data(
            #"{"bootIdentity":"1:2:3","screenID":3,"screenUUID":"DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0","logicalWidth":951,"logicalHeight":669,"rotationDegrees":90,"nativePixelWidth":2007,"nativePixelHeight":2853,"scale":3,"poseRevision":"mechanicalDegrees=90.0"}"#.utf8))
        let root = Fixture(type: "Application", id: "fixture", label: "Fixture", children: children)
        let nodes = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode([root]))
        return (try AgentModeSnapshot(roots: nodes, context: context), context)
    }

    private struct Fixture: Encodable {
        struct Frame: Encodable {
            let x = 10.0, y = 100.0, width = 300.0, height = 44.0
        }
        var type = "Button"
        var id = "item"
        var label = "Item"
        var customActionNames: [String] = []
        var children: [Fixture] = []
        let frame = Frame()
        let pid: Int32 = 1234
        let enabled = true, hidden = false, focused = true
        private enum CodingKeys: String, CodingKey {
            case type, id = "AXUniqueId", label = "AXLabel", customActionNames = "custom_actions"
            case children, frame, pid, enabled, hidden, focused
        }
    }
}
