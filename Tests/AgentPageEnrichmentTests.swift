import Foundation
import Testing
@testable import AXe

@Suite("Bounded same-record page fill")
struct AgentPageEnrichmentTests {
    @Test("One stored page fills the compact row budget and keeps a canonical continuation")
    func fillsAfterRedundantRows() throws {
        let source = rows(81)
        let original = result(source, offset: 0, redundant: ["e1", "e2", "e3", "e4"])
        #expect(try AgentPageEnrichment.continuationOffset(original) == 64)
        let continuation = try #require(result(source, offset: 64)["data"]?["capture"])
        let enriched = AgentPageEnrichment.enrich(original, continuation: continuation)
        let capture = try #require(AgentOutputProjection.project(enriched, view: .reading)["data"]?["capture"])
        #expect(capture["rows"]?.arrayValue?.count == 64)
        #expect(capture["rows"]?.arrayValue?.last?.stringValue?.hasPrefix("e68|") == true)
        #expect(capture["page"]?["nextOffset"]?.scalarText == "68")
        #expect(capture["page"]?["total"]?.scalarText == "81")
        #expect(capture["page"]?["extraReads"]?.scalarText == "0")
        #expect(capture["page"]?["incomplete"] == nil)
        #expect(try same(enriched["data"]?["action"], original["data"]?["action"]))
        #expect(try same(enriched["data"]?["batch"], original["data"]?["batch"]))
        // The cursor addresses the original table, not the 64 displayed rows.
        let tail = try AgentOutputProjection.project(result(source, offset: 68), view: .reading)
        #expect(tail["data"]?["capture"]?["rows"]?.arrayValue?.count == 13)
    }

    @Test("An exhausted second page ends without a cursor")
    func completesShortPage() throws {
        let source = rows(66)
        let original = result(source, offset: 0, redundant: ["e1", "e2", "e3", "e4"])
        let continuation = try #require(result(source, offset: 64)["data"]?["capture"])
        let enriched = AgentPageEnrichment.enrich(original, continuation: continuation)
        let capture = try #require(AgentOutputProjection.project(enriched, view: .reading)["data"]?["capture"])
        #expect(capture["rows"]?.arrayValue?.count == 62)
        #expect(capture["page"]?["nextOffset"] == nil)
    }

    @Test("Only one stored page is appended even when many rows are redundant")
    func neverLoops() throws {
        let source = rows(200)
        let redundant = (1...128).map { "e\($0)" }
        let original = result(source, offset: 0, redundant: redundant)
        let continuation = try #require(result(source, offset: 64, redundant: redundant)["data"]?["capture"])
        #expect(try AgentPageEnrichment.continuationOffset(original) == 64)
        let enriched = AgentPageEnrichment.enrich(original, continuation: continuation)
        let capture = try #require(AgentOutputProjection.project(enriched, view: .reading)["data"]?["capture"])
        #expect(capture["rows"]?.arrayValue?.isEmpty == true)
        #expect(capture["page"]?["nextOffset"]?.scalarText == "128")
    }

    @Test("An explicit nonzero page retains its original offset and exact continuation")
    func preservesExplicitOffset() throws {
        let source = rows(175)
        let redundant = ["e67", "e68", "e69", "e70"]
        let original = result(source, offset: 64, redundant: redundant)
        let continuation = try #require(result(source, offset: 128)["data"]?["capture"])
        #expect(try AgentPageEnrichment.continuationOffset(original) == 128)
        let enriched = AgentPageEnrichment.enrich(original, continuation: continuation)
        let capture = try #require(AgentOutputProjection.project(enriched, view: .reading)["data"]?["capture"])
        #expect(capture["page"]?["offset"]?.scalarText == "64")
        #expect(capture["page"]?["nextOffset"]?.scalarText == "132")
        #expect(capture["snapshotID"]?.stringValue == snapshotID)
        #expect(capture["rows"]?.arrayValue?.first?.stringValue?.hasPrefix("e65|") == true)
        #expect(capture["rows"]?.arrayValue?.last?.stringValue?.hasPrefix("e132|") == true)
    }

    @Test("Different table, owner, pose or hash cannot contribute rows")
    func rejectsChangedCapture() throws {
        let source = rows(81)
        let original = result(source, offset: 0, redundant: ["e1"])
        for (path, changed) in [
            (["snapshotID"], CLIOutputValue.string("BE0DAD83-4ED0-4109-BB86-D699453FFB68")),
            (["applicationPID"], .integer(999)),
            (["screenHash"], .string("changed")),
            (["context", "rotationDegrees"], .integer(180)),
            (["context", "poseRevision"], .string("changed")),
            (["rowOffset"], .integer(65))
        ] {
            let next = try replace(result(source, offset: 64), path: ["data", "capture"] + path, value: changed)
            let continuation = try #require(next["data"]?["capture"])
            let enriched = AgentPageEnrichment.enrich(original, continuation: continuation)
            #expect(try same(enriched, original))
        }
    }

    @Test("Errors, invalidated cache, unchanged, complete and full-sized pages do not offer a continuation")
    func skipsUnneededPages() throws {
        let source = rows(81)
        let partial = result(source, offset: 0, redundant: ["e1"])
        let failed = try replace(partial, path: ["didError"], value: .bool(true))
        let invalidated = try replace(partial, path: ["data", "cache", "requiresRefresh"], value: .bool(true))
        let unchanged = try replace(partial, path: ["data", "capture", "type"], value: .string("runtime-snapshot-unchanged"))
        for original in [failed, invalidated, unchanged, result(rows(20), offset: 0), result(source, offset: 0)] {
            #expect(try AgentPageEnrichment.continuationOffset(original) == nil)
        }
    }

    @Test("Byte-budget truncation keeps its original cursor and does not add a page")
    func doesNotReadPastByteLimit() throws {
        let label = String(repeating: "\"", count: 160)
        let source = (1...81).map { "e\($0)|text|text|\(label)|\(label)|" }
        let original = result(source, offset: 0)
        #expect(try AgentPageEnrichment.continuationOffset(original) == nil)
        let capture = try #require(AgentOutputProjection.project(original, view: .reading)["data"]?["capture"])
        #expect(try JSONEncoder().encode(capture).count <= AgentOutputProjection.maximumCaptureBytes)
        #expect(capture["page"]?["nextOffset"]?.scalarText != "64")
    }

    @Test("Cross-section duplicate actions and metadata survive the stored page merge")
    func mergesActionsAndKeepsMetadata() throws {
        let all = ["e1|tap|button|Control||"] + (2...80).map { "e\($0)|text|text|Text \($0)||" }
        var first = result(all, offset: 0)
        var second = result(all, offset: 64)
        for path in [["data", "capture", "targetCount"]] {
            first = try replace(first, path: path, value: .integer(1))
            second = try replace(second, path: path, value: .integer(1))
        }
        for path in [["data", "capture", "textCount"]] {
            first = try replace(first, path: path, value: .integer(79))
            second = try replace(second, path: path, value: .integer(79))
        }
        first = try replace(first, path: ["data", "capture", "targets"], value: .array([.string(all[0])]))
        first = try replace(first, path: ["data", "capture", "text"], value: .array(all[1..<64].map(CLIOutputValue.string)))
        // The duplicate is a text row for the same canonical control. Its content is identical.
        first = try replace(first, path: ["data", "capture", "redundantTextRefs"], value: .array([.string("e2")]))
        var tail = Array(all[64...])
        tail[0] = "e1|text|button|Control||"
        second = try replace(second, path: ["data", "capture", "text"], value: .array(tail.map(CLIOutputValue.string)))
        second = try replace(second, path: ["data", "capture", "customActions"],
            value: .object(["e66": .array([.string("Action")])]))
        #expect(try AgentPageEnrichment.continuationOffset(first) == 64)
        let continuation = try #require(second["data"]?["capture"])
        let enriched = AgentPageEnrichment.enrich(first, continuation: continuation)
        let capture = try #require(AgentOutputProjection.project(enriched, view: .reading)["data"]?["capture"])
        #expect(capture["rows"]?.arrayValue?.count == 64)
        #expect(capture["rows"]?.arrayValue?.first?.stringValue == "e1|tap,text|button|Control|")
        #expect(capture["page"]?["nextOffset"]?.scalarText == "66")
        let groups = try #require(capture["customActionGroups"]?.arrayValue)
        #expect(groups.first?["refs"]?.arrayValue?.first?.stringValue == "e66")
        #expect(groups.first?["names"]?.arrayValue?.first?.stringValue == "Action")
    }

    @Test("Invalid row counts or conflicting metadata cannot change the first page")
    func rejectsMalformedPage() throws {
        let source = rows(81)
        let original = result(source, offset: 0, redundant: ["e1"])
        let invalid = try replace(result(source, offset: 64), path: ["data", "capture", "textCount"], value: .integer(82))
        let continuation = try #require(invalid["data"]?["capture"])
        let enriched = AgentPageEnrichment.enrich(original, continuation: continuation)
        #expect(try same(enriched, original))
    }

    @Test("Optional continuation overflow keeps the original response and input receipt")
    func wireOverflowKeepsOriginalResponse() throws {
        let source = rows(81)
        let page = try #require(result(source, offset: 64)["data"]?["capture"])
        let continuation = try JSONDecoder().decode(AgentModeCapture.self, from: JSONEncoder().encode(page))
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(),
            brokerID: UUID(), outcome: "enqueuedAndDrained", token: nil, enqueuedEventCount: 2,
            cleanup: "notNeeded", error: nil, context: nil)
        response.agent = AgentModeResult(capture: continuation,
            action: .init(kind: .tap, outcome: "enqueuedAndDrained", enqueuedEventCount: 2,
                cleanup: "notNeeded", replayed: false, quarantine: nil),
            cache: .init(status: "refreshed", reason: nil, requiresRefresh: false))
        let original = try SelectedAXWire.encodeResponse(response, maximumBytes: SelectedAXBounds.responseBytes)
        response.readingContinuation = continuation
        let delivered = try SelectedAXWire.boundedResponse(response, maximumBytes: original.count - 1)
        let value = try JSONDecoder().decode(SelectedHIDResponse.self, from: delivered)
        #expect(value.requestID == response.requestID)
        #expect(value.readingContinuation == nil)
        #expect(value.agent?.didError == false)
        #expect(value.agent?.data.capture?.snapshotID == continuation.snapshotID)
        #expect(value.agent?.data.action?.enqueuedEventCount == 2)
        #expect(value.agent?.data.action?.replayed == false)
    }

    private enum ProbeError: Error { case path }
    private let snapshotID = "A1F5E846-8027-49D2-8463-3D80D191A349"
    private let screenID = "D776003F-875B-4FB4-BEB4-49712BC14B09"

    private func rows(_ count: Int) -> [String] { (1...count).map { "e\($0)|text|text|Text \($0)||" } }

    private func result(_ all: [String], offset: Int, redundant: [String] = []) -> CLIOutputValue {
        let end = min(all.count, offset + 64)
        var capture: [String: CLIOutputValue] = [
            "type": .string("runtime-snapshot"), "rs": .string("1"), "snapshotID": .string(snapshotID),
            "screenHash": .string("0123456789abcdef"), "seq": .integer(1), "count": .integer(Int64(all.count)),
            "udid": .string("00000000-0000-0000-0000-000000000001"), "applicationPID": .integer(1234),
            "context": .object(["bootIdentity": .string("boot"), "screenID": .integer(3), "screenUUID": .string(screenID),
                "logicalWidth": .integer(951), "logicalHeight": .integer(669), "rotationDegrees": .integer(90),
                "nativePixelWidth": .integer(2853), "nativePixelHeight": .integer(2007), "scale": .integer(3),
                "poseRevision": .string("mechanicalDegrees=90.0")]),
            "truncated": .bool(end < all.count),
            "rowOffset": .integer(Int64(offset)), "rowLimit": .integer(64),
            "targetCount": .integer(0), "scrollCount": .integer(0), "textCount": .integer(Int64(all.count)),
            "totalRows": .integer(Int64(all.count)), "targets": .array([]), "scroll": .array([]),
            "text": .array(all[offset..<end].map(CLIOutputValue.string)),
            "redundantTextRefs": .array(redundant.map(CLIOutputValue.string)), "expiresInSeconds": .integer(59)]
        if end < all.count { capture["nextRowOffset"] = .integer(Int64(end)) }
        return .object(["schema": .string("axe.output.agent-result"), "schemaVersion": .string("1"),
            "didError": .bool(false), "data": .object(["capture": .object(capture),
                "cache": .object(["status": .string("refreshed"), "requiresRefresh": .bool(false)]),
                "action": .object(["kind": .string("tap"), "enqueuedEventCount": .integer(2),
                    "cleanup": .string("notNeeded"), "replayed": .bool(false)]),
                "batch": .object(["completedSteps": .integer(1), "rolledBack": .bool(false),
                    "replayed": .bool(false), "requestID": .string(snapshotID),
                    "steps": .array([.object(["status": .string("completed"), "events": .integer(2)])])])]),
            "nextSteps": .array([])])
    }

    private func same(_ first: CLIOutputValue?, _ second: CLIOutputValue?) throws -> Bool {
        guard let first else { return second == nil }
        guard let second else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(first) == encoder.encode(second)
    }

    private func replace(_ original: CLIOutputValue, path: [String], value: CLIOutputValue) throws -> CLIOutputValue {
        guard let first = path.first, case var .object(fields) = original else { throw ProbeError.path }
        if path.count == 1 { fields[first] = value }
        else {
            guard let child = fields[first] else { throw ProbeError.path }
            fields[first] = try replace(child, path: Array(path.dropFirst()), value: value)
        }
        return .object(fields)
    }
}
