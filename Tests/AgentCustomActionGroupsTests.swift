import Foundation
import Testing
@testable import AXe

@Suite("Agent adaptive custom-action groups")
struct AgentCustomActionGroupsTests {
    @Test("Exact ordered arrays group by first published ref, preserving duplicates and Unicode bytes")
    func exactOrderedPreviewGroups() throws {
        let repeated = ["Delete", "Archive", "Delete"]
        let names = ["e9": repeated, "e2": repeated, "e8": repeated,
            "e5": ["Archive", "Delete", "Delete"], "e6": ["é"], "e7": ["e\u{301}"],
            "e99": ["Unpublished"]]
        let rows = ["e9", "e6", "e2", "e7", "e5", "e8"].map { row($0) }
        let original = result(targets: rows, names: names)
        let projected = try AgentOutputProjection.project(original, view: .reading)
        let capture = try #require(projected["data"]?["capture"])
        #expect(capture["customActions"] == nil)
        let groups = try #require(capture["customActionGroups"]?.arrayValue)
        #expect(groups.count == 4)
        #expect(strings(groups[0]["refs"]) == ["e9", "e2", "e8"])
        #expect(strings(groups[0]["names"]) == repeated)
        #expect(strings(groups[1]["refs"]) == ["e6"])
        #expect(strings(groups[2]["refs"]) == ["e7"])
        #expect(strings(groups[3]["refs"]) == ["e5"])
        #expect(strings(groups[3]["names"]) == names["e5"])
        let composed = try #require(strings(groups[1]["names"]).first)
        let decomposed = try #require(strings(groups[2]["names"]).first)
        #expect(Data(composed.utf8) == Data("é".utf8))
        #expect(Data(decomposed.utf8) == Data("e\u{301}".utf8))
        #expect(Data(composed.utf8) != Data(decomposed.utf8))
        #expect(!groups.flatMap { strings($0["refs"]) }.contains("e99"))
    }

    @Test("Singletons use the same adaptive shape while full and unchanged replies retain their contracts")
    func fullAndSmallMetadataKeepClearShapes() throws {
        let original = result(targets: [row("e2")], names: ["e2": ["Action"]])
        let full = try AgentOutputProjection.project(original, view: .full)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(full) == encoder.encode(original))
        #expect(full["data"]?["capture"]?["customActions"]?["e2"]?.arrayValue?.count == 1)
        #expect(full["data"]?["capture"]?["customActionGroups"] == nil)
        for view in [AgentOutputView.reading, .navigation] {
            let value = try AgentOutputProjection.project(original, view: view)
            #expect(value["schemaVersion"]?.stringValue == "2")
            #expect(value["data"]?["capture"]?["customActions"] == nil)
            let groups = try #require(value["data"]?["capture"]?["customActionGroups"]?.arrayValue)
            #expect(groups.count == 1 && strings(groups[0]["refs"]) == ["e2"])
            #expect(strings(groups[0]["names"]) == ["Action"])
        }
        let unchanged = result(targets: [], names: ["e2": ["Action"]], unchanged: true)
        let value = try AgentOutputProjection.project(unchanged, view: .reading)
        #expect(value["data"]?["capture"]?["unchanged"]?.boolValue == true)
        #expect(value["data"]?["capture"]?["customActions"] == nil)
        #expect(value["data"]?["capture"]?["customActionGroups"] == nil)
    }

    @Test("Navigation filtering and merged control rows never leak or duplicate metadata refs")
    func groupsRemainScopedToFilteredRows() throws {
        let original = result(targets: ["e2|pinchWithin|other|Area||area"],
            scroll: ["e2|swipe|other|Area||area"], text: ["e3|text|text|Note||"],
            names: ["e2": ["Action"], "e3": ["Other"], "e99": ["Hidden"]])
        let reading = try AgentOutputProjection.project(original, view: .reading)
        let navigation = try AgentOutputProjection.project(original, view: .navigation)
        let readGroups = try #require(reading["data"]?["capture"]?["customActionGroups"]?.arrayValue)
        let navGroups = try #require(navigation["data"]?["capture"]?["customActionGroups"]?.arrayValue)
        #expect(readGroups.flatMap { strings($0["refs"]) } == ["e2", "e3"])
        #expect(navGroups.flatMap { strings($0["refs"]) } == ["e2"])
        let rows = try #require(navigation["data"]?["capture"]?["rows"]?.arrayValue)
        #expect(rows.count == 1 && rows[0].stringValue == "e2|pinchWithin,swipe|other|Area|")
    }

    @Test("Distinct heavy previews retain every ref across byte-limited pages and preserve truncation markers")
    func uniquePreviewsKeepBoundedPages() throws {
        let refs = (1...64).map { "e\($0)" }
        let rows = refs.map { row($0, label: String(repeating: "\"", count: 160)) }
        let names = Dictionary(uniqueKeysWithValues: refs.map { ref in
            (ref, (1...4).map { String(repeating: "\"", count: 80) + "\(ref)-\($0)" })
        })
        var offset = 0
        var pages = 0
        var recovered: [String] = []
        while true {
            let original = result(targets: Array(rows.dropFirst(offset)), names: names,
                truncated: refs, offset: offset, total: rows.count)
            let value = try AgentOutputProjection.project(original, view: .reading)
            let capture = try #require(value["data"]?["capture"])
            #expect(try JSONEncoder().encode(capture).count <= AgentOutputProjection.maximumCaptureBytes)
            let shownRows = try #require(capture["rows"]?.arrayValue)
            let shown = shownRows.compactMap(\.stringValue).map { String($0.prefix { $0 != "|" }) }
            let groups = try #require(capture["customActionGroups"]?.arrayValue)
            let metadataRefs = groups.flatMap { strings($0["refs"]) }
            #expect(metadataRefs == shown && Set(metadataRefs).count == shown.count)
            #expect(Set(strings(capture["truncatedCustomActionRefs"])) == Set(shown))
            for group in groups {
                let ref = try #require(strings(group["refs"]).first)
                #expect(strings(group["names"]) == names[ref])
            }
            recovered += shown
            pages += 1
            guard let next = capture["page"]?["nextOffset"]?.scalarText.flatMap(Int.init) else { break }
            #expect(next > offset && pages < 64)
            offset = next
        }
        #expect(recovered == refs && pages > 1)
    }

    private func strings(_ value: CLIOutputValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func row(_ ref: String, label: String = "Item") -> String {
        "\(ref)|tap|button|\(label)||id.\(ref)"
    }

    private func result(targets: [String], scroll: [String] = [], text: [String] = [],
                        names: [String: [String]], truncated: [String] = [],
                        offset: Int = 0, total: Int? = nil, unchanged: Bool = false) -> CLIOutputValue {
        var capture: [String: CLIOutputValue] = [
            "type": .string(unchanged ? "runtime-snapshot-unchanged" : "runtime-snapshot"),
            "snapshotID": .string("3FF70D78-26DA-4314-B37B-4CB57D2A1A85"), "seq": .integer(1),
            "screenHash": .string("fixture"), "expiresInSeconds": .integer(60), "applicationPID": .integer(1234),
            "targets": .array(targets.map { .string($0) }), "scroll": .array(scroll.map { .string($0) }),
            "text": .array(text.map { .string($0) }), "rowOffset": .integer(Int64(offset)),
            "totalRows": .integer(Int64(total ?? (targets.count + scroll.count + text.count))),
            "customActions": .object(names.mapValues { .array($0.map { .string($0) }) })
        ]
        if !truncated.isEmpty { capture["truncatedCustomActionRefs"] = .array(truncated.map { .string($0) }) }
        return .object(["schema": .string("axe.output.agent-result"), "schemaVersion": .string("1"),
            "didError": .bool(false), "data": .object(["capture": .object(capture)])])
    }
}
