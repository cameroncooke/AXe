import ArgumentParser
import Foundation
import Testing
@testable import AXe

@Suite("Agent adaptive output")
struct AgentOutputProjectionTests {
    @Test("Cached area previews keep canonical rows, cursor and full/base bytes unchanged")
    func areaPreviewDoesNotReplaceCanonicalRows() throws {
        let targets = ["e70|pinchWithin|scroll-view|List||list"]
            + (1...63).map { "e\($0)|tap|button|Control \($0)||control.\($0)" }
        let original = try replacing(result(targets: targets, total: 96),
            path: ["data", "capture", "nextRowOffset"], with: .integer(64))
        let enriched = try replacing(original, path: ["data", "capture", "scrollPreview"], with: .object([
            "rows": .array([.string("e70|swipe|scroll-view|List||list"),
                            .string("e71|swipe|scroll-view|Inner||inner")]),
            "hasMore": .bool(false)]))
        for view in [AgentOutputView.reading, .navigation] {
            let baseline = try #require(AgentOutputProjection.project(original, view: view)["data"]?["capture"])
            let capture = try #require(AgentOutputProjection.project(enriched, view: view)["data"]?["capture"])
            let actualRows = try #require(capture["rows"])
            let expectedRows = try #require(baseline["rows"])
            let actualPage = try #require(capture["page"])
            let expectedPage = try #require(baseline["page"])
            #expect(try encoded(actualRows) == encoded(expectedRows))
            #expect(try encoded(actualPage) == encoded(expectedPage))
            #expect(capture["scrollPreview"] == nil)
            #expect(capture["areas"]?["preview"]?.boolValue == true)
            #expect(capture["areas"]?["hasMore"]?.boolValue == false)
            #expect(capture["areas"]?["rows"]?.arrayValue?.count == 2)
            #expect(capture["areas"]?["rows"]?.arrayValue?.first?.stringValue == "e70|swipe|scroll-view|List|")
            #expect(capture["rows"]?.arrayValue?.first?.stringValue == "e70|pinchWithin|scroll-view|List|")
        }
        #expect(try encoded(AgentOutputProjection.project(enriched, view: .full)) == encoded(original))
    }

    @Test("Area previews respect the existing capture budget without moving its cursor")
    func areaPreviewFitsOnlyUnusedByteBudget() throws {
        let heavy = String(repeating: "\"", count: 320)
        let targets = (1...64).map { "e\($0)|tap|button|\(heavy)|\(heavy)|id.\($0)" }
        let original = result(targets: targets, total: 80)
        let preview = CLIOutputValue.object(["rows": .array((1...4).map {
            .string("e\($0 + 70)|swipe|scroll-view|\(heavy)|\(heavy)|list.\($0)")
        }), "hasMore": .bool(true)])
        let enriched = try replacing(original, path: ["data", "capture", "scrollPreview"], with: preview)
        for view in [AgentOutputView.reading, .navigation] {
            let baseline = try #require(AgentOutputProjection.project(original, view: view)["data"]?["capture"])
            let capture = try #require(AgentOutputProjection.project(enriched, view: view)["data"]?["capture"])
            let actualRows = try #require(capture["rows"])
            let expectedRows = try #require(baseline["rows"])
            let actualPage = try #require(capture["page"])
            let expectedPage = try #require(baseline["page"])
            #expect(try encoded(actualRows) == encoded(expectedRows))
            #expect(try encoded(actualPage) == encoded(expectedPage))
            #expect(try JSONEncoder().encode(capture).count <= AgentOutputProjection.maximumCaptureBytes)
            if let areas = capture["areas"] {
                #expect(areas["hasMore"]?.boolValue == true)
                let rows = try #require(areas["rows"]?.arrayValue)
                #expect(!rows.isEmpty && rows.count <= 4)
            }
        }
    }

    @Test("Area name previews are bounded and retain exact-field readback evidence")
    func areaPreviewKeepsClippingEvidence() throws {
        let longLabel = String(repeating: "😀", count: 200)
        let original = result(targets: ["e1|tap|button|First||first"])
        let enriched = try replacing(original, path: ["data", "capture", "scrollPreview"], with: .object([
            "rows": .array([.string("e70|swipe|scroll-view|\(longLabel)||list")]),
            "hasMore": .bool(true)]))
        let capture = try #require(AgentOutputProjection.project(enriched, view: .reading)["data"]?["capture"])
        let row = try #require(capture["areas"]?["rows"]?.arrayValue?.first?.stringValue)
        let cells = row.split(separator: "|", omittingEmptySubsequences: false)
        #expect(cells[3].unicodeScalars.count <= AgentOutputProjection.maximumCellScalars)
        #expect(cells[3].hasSuffix("…"))
        let evidence = try #require(capture["truncatedFields"]?.arrayValue?.first)
        #expect(evidence["ref"]?.stringValue == "e70" && evidence["field"]?.stringValue == "label")
        #expect(evidence["displayScalarLength"]?.scalarText == "200")
        #expect(capture["areas"]?["preview"]?.boolValue == true)
        #expect(capture["areas"]?["hasMore"]?.boolValue == true)
    }

    @Test("Full projection does not alter a foreign response schema")
    func fullProjectionPreservesForeignSchema() throws {
        let foreign = CLIOutputValue.object(["schema": .string("foreign.result"),
            "data": .object(["capture": .object(["scrollPreview": .string("keep exact")])])])
        #expect(try encoded(AgentOutputProjection.project(foreign, view: .full)) == encoded(foreign))
    }

    @Test("An already advertised swipe removes only its duplicate area preview")
    func areaPreviewKeepsOnlyMissingSwipeCapabilities() throws {
        let original = result(targets: ["e70|pinchWithin,swipe|scroll-view|List||list"])
        let enriched = try replacing(original, path: ["data", "capture", "scrollPreview"], with: .object([
            "rows": .array([.string("e70|swipe|scroll-view|List||list"),
                            .string("e71|swipe|scroll-view|Inner||inner")]),
            "hasMore": .bool(false)]))
        for view in [AgentOutputView.reading, .navigation] {
            let capture = try #require(AgentOutputProjection.project(enriched, view: view)["data"]?["capture"])
            let rows = try #require(capture["areas"]?["rows"]?.arrayValue)
            #expect(rows.count == 1 && rows.first?.stringValue == "e71|swipe|scroll-view|Inner|")
            #expect(capture["areas"]?["hasMore"]?.boolValue == false)
            #expect(capture["rows"]?.arrayValue?.first?.stringValue == "e70|pinchWithin,swipe|scroll-view|List|")
            let single = try replacing(original, path: ["data", "capture", "scrollPreview"], with: .object([
                "rows": .array([.string("e70|swipe|scroll-view|List||list")]), "hasMore": .bool(false)]))
            let unchanged = try AgentOutputProjection.project(single, view: view)
            #expect(try encoded(unchanged) == encoded(AgentOutputProjection.project(original, view: view)))
        }
    }

    @Test("The CLI defaults to reading while full keeps the canonical base schema")
    func outputBoundaryKeepsFullContract() throws {
        let original = result(targets: ["e2|tap|button|Target||target"])
        let compact = CLIOutputContext(format: .json, command: "describe-ui", agent: true)
        compact.append(original)
        let projected = try JSONDecoder().decode(CLIOutputValue.self, from: CLIOutput.rendered(compact))
        #expect(projected["schemaVersion"]?.stringValue == "2")
        #expect(projected["data"]?["capture"]?["rows"]?.arrayValue?.count == 1)
        #expect(projected["data"]?["context"] == nil)

        let full = CLIOutputContext(format: .json, command: "describe-ui", agent: true)
        full.setAgentView(.full)
        full.append(original)
        let recovered = try JSONDecoder().decode(CLIOutputValue.self, from: CLIOutput.rendered(full))
        #expect(try encoded(recovered) == encoded(original))
    }

    @Test("Agent batch accepts the full view and raw batch rejects agent-only views")
    func batchViewSelectionUsesTheAgentBoundary() throws {
        let output = CLIOutputContext(format: .json, command: "batch", agent: true)
        try CLIOutput.$context.withValue(output) {
            let batch = try Batch.parse(["--udid", "fixture", "--agent", "--view", "full",
                "--file", "/unused/parse-only.json"])
            try batch.validate()
            #expect(batch.agentMode && batch.agentView == .full)
        }
        #expect(output.agentView == .full)
        do {
            let raw = try Batch.parse(["--udid", "fixture", "--view", "full",
                "--file", "/unused/parse-only.json"])
            try raw.validate()
            Issue.record("A raw batch accepted an agent-only view.")
        } catch {
            #expect(String(describing: error).contains("--agent"))
        }
    }

    @Test("Compact rows keep every control capability and independent text")
    func capabilitiesAndIndependentTextRemain() throws {
        let original = result(targets: ["e2|tap|button|Target||target",
            "e5|pinchWithin|scroll-view|List||list"], scroll: ["e5|swipe|scroll-view|List||list"],
            text: ["e3|text|text|Target||", "e4|text|text|Ready||status"], redundant: ["e3"])
        let projected = try AgentOutputProjection.project(original, view: .reading)
        let capture = try #require(projected["data"]?["capture"])
        let lineValues = try #require(capture["rows"]?.arrayValue)
        let lines = lineValues.compactMap(\.stringValue)
        let list = try #require(lines.first { $0.hasPrefix("e5|") })
        #expect(Set(list.split(separator: "|", omittingEmptySubsequences: false)[1].split(separator: ",").map(String.init))
            == Set(["pinchWithin", "swipe"]))
        #expect(lines.contains("e2|tap|button|Target|"))
        #expect(lines.contains("e4|text|text|Ready|"))
        #expect(!lines.contains { $0.hasPrefix("e3|") })
        #expect(lines.count == 3)
        let navigation = try AgentOutputProjection.project(original, view: .navigation)
        #expect(navigation["data"]?["capture"]?["rows"]?.arrayValue?.count == 2)
    }

    @Test("Unavailable controls remain visible and unlabeled controls keep a usable name")
    func controlDiscoveryDoesNotHideIdentityLimits() throws {
        let projected = try AgentOutputProjection.project(result(targets: [
            "e2|unavailable|button|Same||", "e3|tap|button|||exact.id"
        ]), view: .navigation)
        let rowValues = try #require(projected["data"]?["capture"]?["rows"]?.arrayValue)
        let rows = rowValues.compactMap(\.stringValue)
        #expect(rows.contains("e2|unavailable|button|Same|"))
        #expect(rows.contains("e3|tap|button|exact.id|"))
    }

    @Test("Unicode display cells are bounded and declare how to recover the original field")
    func oversizedDisplayFieldsRemainRecoverable() throws {
        let originalLabel = String(repeating: "👩🏽‍💻", count: 80)
        let original = result(targets: ["e2|tap|button|\(originalLabel)||target"])
        let projected = try AgentOutputProjection.project(original, view: .reading)
        let capture = try #require(projected["data"]?["capture"])
        let row = try #require(capture["rows"]?.arrayValue?.first?.stringValue)
        let label = row.split(separator: "|", omittingEmptySubsequences: false)[3]
        #expect(label.unicodeScalars.count <= AgentOutputProjection.maximumCellScalars)
        #expect(label.hasSuffix("…"))
        let truncation = try #require(capture["truncatedFields"]?.arrayValue?.first)
        #expect(truncation["ref"]?.stringValue == "e2")
        #expect(truncation["field"]?.stringValue == "label")
        #expect(truncation["displayScalarLength"]?.scalarText == String(originalLabel.unicodeScalars.count))
        let full = try AgentOutputProjection.project(original, view: .full)
        #expect(full["data"]?["capture"]?["targets"]?.arrayValue?.first?.stringValue?.contains(originalLabel) == true)
    }

    @Test("A byte-limited page has a forward cursor that recovers every control")
    func boundedPagesDoNotLoseControls() throws {
        let heavy = String(repeating: "\"", count: 320)
        let source = (1...64).map { "e\($0)|tap|button|\(heavy)|\(heavy)|id.\($0)" }
        var offset = 0
        var collected: [String] = []
        for _ in 0..<10 {
            let input = result(targets: Array(source.dropFirst(offset)), offset: offset, total: source.count)
            let projected = try AgentOutputProjection.project(input, view: .reading)
            let capture = try #require(projected["data"]?["capture"])
            #expect(try encoded(capture).count <= AgentOutputProjection.maximumCaptureBytes)
            let rowValues = try #require(capture["rows"]?.arrayValue)
            let rows = rowValues.compactMap(\.stringValue)
            #expect(!rows.isEmpty)
            collected += rows.map { String($0.prefix { $0 != "|" }) }
            guard let nextText = capture["page"]?["nextOffset"]?.scalarText else { break }
            let next = try #require(Int(nextText))
            #expect(next > offset)
            offset = next
        }
        #expect(collected == (1...64).map { "e\($0)" })
    }

    @Test("A continuation cursor fits when a complete canonical page reaches the byte boundary")
    func continuationCursorIsIncludedInTheByteLimit() throws {
        for (rowCount, labelQuoteCount) in [(32, 91), (48, 10), (64, 10)] {
            let label = String(repeating: "\"", count: labelQuoteCount)
            let value = String(repeating: "\"", count: 160)
            let source = (1...rowCount).map { "e\($0)|tap|button|\(label)|\(value)|id.\($0)" }
            var offset = 0
            var collected: [String] = []
            for _ in 0..<10 {
                let input = result(targets: Array(source.dropFirst(offset)), offset: offset, total: source.count)
                let projected = try AgentOutputProjection.project(input, view: .reading)
                let capture = try #require(projected["data"]?["capture"])
                #expect(try encoded(capture).count <= AgentOutputProjection.maximumCaptureBytes)
                let values = try #require(capture["rows"]?.arrayValue)
                let rows = values.compactMap(\.stringValue)
                #expect(!rows.isEmpty)
                collected += rows.map { String($0.prefix { $0 != "|" }) }
                guard let nextText = capture["page"]?["nextOffset"]?.scalarText else { break }
                let next = try #require(Int(nextText))
                #expect(next > offset)
                offset = next
            }
            #expect(collected == (1...rowCount).map { "e\($0)" })
        }
    }

    @Test("A complete filtered first page keeps every control without a raw-row total")
    func completeFilteredPageDoesNotSuggestAnotherRead() throws {
        let targets = ["e1|tap|button|First||first", "e2|tap|button|Second||second"]
        let scroll = ["e3|swipe|scroll-view|List||list"]
        let text = (4...69).map { "e\($0)|text|text|Text \($0)||" }
        let original = result(targets: targets, scroll: scroll, text: text,
            redundant: (4...8).map { "e\($0)" }, total: 69)
        for view in [AgentOutputView.reading, .navigation] {
            let projected = try AgentOutputProjection.project(original, view: view)
            let capture = try #require(projected["data"]?["capture"])
            let values = try #require(capture["rows"]?.arrayValue)
            let rows = values.compactMap(\.stringValue)
            #expect(rows.count == (view == .reading ? 64 : 3))
            #expect(rows.contains("e1|tap|button|First|"))
            #expect(rows.contains("e2|tap|button|Second|"))
            #expect(rows.contains("e3|swipe|scroll-view|List|"))
            #expect(capture["page"] == nil)
            #expect(capture["snapshotID"]?.stringValue == snapshotID)
        }
        let full = try AgentOutputProjection.project(original, view: .full)
        #expect(try encoded(full) == encoded(original))
        #expect(full["data"]?["capture"]?["rowOffset"]?.scalarText == "0")
        #expect(full["data"]?["capture"]?["totalRows"]?.scalarText == "69")
    }

    @Test("Navigation stops before a text-only canonical continuation; reading and full keep it")
    func navigationDoesNotAdvertiseTextOnlyTail() throws {
        let targets = (1...16).map { "e\($0)|tap|button|Control \($0)||" }
        let scroll = (17...19).map { "e\($0)|swipe|scroll-view|Area \($0)||" }
        let text = (20...64).map { "e\($0)|text|text|Text \($0)||" }
        var original = result(targets: targets, scroll: scroll, text: text, total: 69)
        for (key, count) in [("targetCount", 16), ("scrollCount", 3), ("textCount", 50), ("nextRowOffset", 64)] {
            original = try replacing(original, path: ["data", "capture", key], with: .integer(Int64(count)))
        }
        let navigation = try #require(AgentOutputProjection.project(original, view: .navigation)["data"]?["capture"])
        #expect(navigation["rows"]?.arrayValue?.count == 19)
        #expect(navigation["page"] == nil)
        let reading = try #require(AgentOutputProjection.project(original, view: .reading)["data"]?["capture"])
        #expect(reading["rows"]?.arrayValue?.count == 64)
        #expect(reading["page"]?["nextOffset"]?.scalarText == "64")
        #expect(reading["page"]?["total"]?.scalarText == "69")
        #expect(try encoded(AgentOutputProjection.project(original, view: .full)) == encoded(original))

        var terminal = result(text: (65...69).map { "e\($0)|text|text|Text \($0)||" }, offset: 64, total: 69)
        for (key, count) in [("targetCount", 16), ("scrollCount", 3), ("textCount", 50)] {
            terminal = try replacing(terminal, path: ["data", "capture", key], with: .integer(Int64(count)))
        }
        let empty = try #require(AgentOutputProjection.project(terminal, view: .navigation)["data"]?["capture"])
        #expect(empty["rows"]?.arrayValue?.isEmpty == true)
        #expect(empty["page"]?["offset"]?.scalarText == "64")
        #expect(empty["page"]?["nextOffset"] == nil)
    }

    @Test("Navigation retains continuation for controls and for missing or inconsistent counts")
    func navigationRetainsControlContinuation() throws {
        var original = result(targets: (1...64).map { "e\($0)|tap|button|Control \($0)||" }, total: 69)
        for (key, count) in [("targetCount", 65), ("scrollCount", 0), ("textCount", 4), ("nextRowOffset", 64)] {
            original = try replacing(original, path: ["data", "capture", key], with: .integer(Int64(count)))
        }
        let next = try #require(AgentOutputProjection.project(original, view: .navigation)["data"]?["capture"])
        #expect(next["rows"]?.arrayValue?.count == 64)
        #expect(next["page"]?["nextOffset"]?.scalarText == "64")
        #expect(next["page"]?["total"]?.scalarText == "69")
        var textOnlyTail = result(targets: (1...16).map { "e\($0)|tap|button|Control \($0)||" },
            scroll: (17...19).map { "e\($0)|swipe|scroll-view|Area \($0)||" },
            text: (20...64).map { "e\($0)|text|text|Text \($0)||" }, total: 69)
        for (key, count) in [("targetCount", 16), ("scrollCount", 3), ("textCount", 50), ("nextRowOffset", 64)] {
            textOnlyTail = try replacing(textOnlyTail, path: ["data", "capture", key], with: .integer(Int64(count)))
        }
        for count in [CLIOutputValue.integer(0), .integer(-1)] {
            let invalid = try replacing(textOnlyTail, path: ["data", "capture", "textCount"], with: count)
            #expect(try AgentOutputProjection.project(invalid, view: .navigation)["data"]?["capture"]?["page"]?["nextOffset"]?.scalarText == "64")
        }
        let missing = try replacing(textOnlyTail, path: ["data", "capture", "textCount"], with: nil)
        #expect(try AgentOutputProjection.project(missing, view: .navigation)["data"]?["capture"]?["page"]?["nextOffset"]?.scalarText == "64")
    }

    @Test("Navigation byte-budget cursors recover all controls before the text-only tail")
    func navigationBudgetCursorStillRecoversControls() throws {
        let heavy = String(repeating: "\"", count: 320)
        let targets = (1...64).map { "e\($0)|tap|button|\(heavy)|\(heavy)|control.\($0)" }
        var offset = 0
        var collected: [String] = []
        for _ in 0..<16 {
            var input = result(targets: Array(targets.dropFirst(offset)), offset: offset, total: 69)
            for (key, count) in [("targetCount", 64), ("scrollCount", 0), ("textCount", 5), ("nextRowOffset", 64)] {
                input = try replacing(input, path: ["data", "capture", key], with: .integer(Int64(count)))
            }
            let capture = try #require(AgentOutputProjection.project(input, view: .navigation)["data"]?["capture"])
            #expect(try encoded(capture).count <= AgentOutputProjection.maximumCaptureBytes)
            let rows = try #require(capture["rows"]?.arrayValue).compactMap(\.stringValue)
            #expect(!rows.isEmpty)
            collected += rows.map { String($0.prefix { $0 != "|" }) }
            guard let nextText = capture["page"]?["nextOffset"]?.scalarText else { break }
            let next = try #require(Int(nextText))
            #expect(next > offset && next < 64)
            offset = next
        }
        #expect(collected == (1...64).map { "e\($0)" })
    }

    @Test("A real continuation keeps its canonical cursor, offset and total")
    func continuationRetainsCanonicalPageCoordinates() throws {
        let rows = (1...64).map { "e\($0)|tap|button|Control \($0)||control.\($0)" }
        let original = try replacing(result(targets: rows, total: 130),
            path: ["data", "capture", "nextRowOffset"], with: .integer(64))
        for view in [AgentOutputView.reading, .navigation] {
            let capture = try #require(AgentOutputProjection.project(original, view: view)["data"]?["capture"])
            #expect(capture["rows"]?.arrayValue?.count == 64)
            #expect(capture["page"]?["offset"]?.scalarText == "0")
            #expect(capture["page"]?["total"]?.scalarText == "130")
            #expect(capture["page"]?["nextOffset"]?.scalarText == "64")
        }
    }

    @Test("A terminal paged reply retains the requested nonzero offset, not a raw-row total")
    func terminalPageRetainsRequestCorrelation() throws {
        let original = result(targets: (65...69).map { "e\($0)|tap|button|Control \($0)||" },
            offset: 64, total: 69)
        for view in [AgentOutputView.reading, .navigation] {
            let capture = try #require(AgentOutputProjection.project(original, view: view)["data"]?["capture"])
            #expect(capture["rows"]?.arrayValue?.count == 5)
            #expect(capture["page"]?["offset"]?.scalarText == "64")
            #expect(capture["page"]?["total"] == nil)
            #expect(capture["page"]?["nextOffset"] == nil)
        }
        let full = try AgentOutputProjection.project(original, view: .full)
        #expect(try encoded(full) == encoded(original))
        #expect(full["data"]?["capture"]?["rowOffset"]?.scalarText == "64")
        #expect(full["data"]?["capture"]?["totalRows"]?.scalarText == "69")
    }

    @Test("A successful action reply carries only what an agent acts on")
    func successfulActionIsMinimal() throws {
        var original = result(targets: ["e2|tap|button|Target||target"])
        original = try replacing(original, path: ["data", "action"], with: .object([
            "kind": .string("tap"), "outcome": .string("enqueuedAndDrained"), "enqueuedEventCount": .integer(2),
            "cleanup": .string("notNeeded"), "replayed": .bool(false)]))
        for view in [AgentOutputView.reading, .navigation] {
            let projected = try AgentOutputProjection.project(original, view: view)
            guard case let .object(top) = projected, case let .object(data)? = projected["data"],
                  case let .object(capture)? = data["capture"], case let .object(action)? = data["action"] else {
                throw FixtureError.invalidPath
            }
            #expect(Set(top.keys) == ["schema", "schemaVersion", "didError", "data"])
            #expect(Set(data.keys) == ["capture", "action"])
            #expect(Set(action.keys) == ["outcome", "enqueuedEventCount"])
            #expect(Set(capture.keys) == ["snapshotID", "expiresInSeconds", "screenHash", "pid", "screen", "rows"])
        }
    }

    @Test("Compact pages carry only the cursor fields an agent passes back")
    func compactPageHasOnlyCursorFields() throws {
        let original = try replacing(result(targets: (1...64).map { "e\($0)|tap|button|Control \($0)||" }, total: 70),
            path: ["data", "capture", "nextRowOffset"], with: .integer(64))
        for view in [AgentOutputView.reading, .navigation] {
            let page = try #require(AgentOutputProjection.project(original, view: view)["data"]?["capture"]?["page"])
            guard case let .object(fields) = page else { throw FixtureError.invalidPath }
            #expect(Set(fields.keys) == ["offset", "total", "nextOffset"])
        }
    }

    @Test("An unchanged acknowledgement retains its table and original remaining lifetime")
    func unchangedReplyDoesNotResendRows() throws {
        let original = result(type: "runtime-snapshot-unchanged", seq: 3)
        let projected = try AgentOutputProjection.project(original, view: .reading)
        let capture = try #require(projected["data"]?["capture"])
        #expect(capture["snapshotID"]?.stringValue == snapshotID)
        #expect(capture["seq"] == nil)
        #expect(capture["expiresInSeconds"]?.scalarText == "59")
        #expect(capture["unchanged"]?.boolValue == true)
        #expect(capture["rows"] == nil && capture["context"] == nil && capture["screen"] == nil)
        #expect(projected["data"]?["context"] == nil)
    }

    @Test("Failure cleanup, quarantine and recovery evidence is preserved")
    func failureEvidenceIsNotCompressedAway() throws {
        let evidence = CLIOutputValue.object([
            "context": context,
            "action": .object(["cleanup": .string("uncertain"), "replayed": .bool(false),
                               "enqueuedEventCount": .integer(1)]),
            "quarantine": .object(["reason": .string("releaseUncertain")]),
            "cache": .object(["status": .string("quarantined"), "requiresRefresh": .bool(true)])
        ])
        let error = CLIOutputValue.object(["code": .string("nativeActionFailed"), "message": .string("Inspect cleanup.")])
        let original = CLIOutputValue.object(["schema": .string("axe.output.agent-result"), "schemaVersion": .string("1"),
            "didError": .bool(true), "data": evidence, "error": error,
            "nextSteps": .array([.string("Do not replay input.")])])
        let projected = try AgentOutputProjection.project(original, view: .reading)
        #expect(projected["didError"]?.boolValue == true)
        let returnedData = try #require(projected["data"])
        let returnedError = try #require(projected["error"])
        // Uncertain cleanup, sent events, quarantine and the required refresh stay. The display is
        // the compact screen; the constant replay flag is the full view's.
        let compact = CLIOutputValue.object([
            "screen": .array([.integer(3), .integer(951), .integer(669), .integer(90)]),
            "action": .object(["cleanup": .string("uncertain"), "enqueuedEventCount": .integer(1)]),
            "quarantine": .object(["reason": .string("releaseUncertain")]),
            "cache": .object(["status": .string("quarantined"), "requiresRefresh": .bool(true)])
        ])
        #expect(try encoded(returnedData) == encoded(compact))
        #expect(try encoded(returnedError) == encoded(error))
        #expect(projected["nextSteps"]?.arrayValue?.first?.stringValue == "Do not replay input.")
    }

    @Test("Large native errors retain both ends and safety evidence without copying hierarchy dumps")
    func oversizedErrorMessagesKeepCauseAndCleanup() throws {
        let prefix = "Native failure start " + String(repeating: "\u{1}", count: 64)
        let suffix = String(repeating: "\u{2}", count: 64) + " FBAXAcquisitionStop.deadlineExceeded"
        let message = prefix + String(repeating: "\"\u{301}", count: 50_000) + suffix
        let error = CLIOutputValue.object(["code": .string("nativeActionFailed"), "message": .string(message)])
        let receipt = CLIOutputValue.object(["cleanup": .string("uncertain"), "replayed": .bool(false),
            "enqueuedEventCount": .integer(1)])
        let quarantine = CLIOutputValue.object(["reason": .string("releaseUncertain")])
        let cache = CLIOutputValue.object(["status": .string("quarantined"), "requiresRefresh": .bool(true)])
        let step = CLIOutputValue.object(["index": .integer(1), "context": context, "error": error, "receipt": receipt])
        let original = CLIOutputValue.object(["schema": .string("axe.output.agent-result"), "schemaVersion": .string("1"),
            "didError": .bool(true), "error": error, "nextSteps": .array([.string("Do not replay input.")]),
            "data": .object(["context": context, "action": receipt, "quarantine": quarantine, "cache": cache,
                "batch": .object(["steps": .array([step]), "stoppedAt": .integer(1)])])])
        for view in [AgentOutputView.reading, .navigation] {
            let projected = try AgentOutputProjection.project(original, view: view)
            let shownError = try #require(projected["error"])
            let shownMessage = try #require(shownError["message"]?.stringValue)
            #expect(shownMessage.unicodeScalars.count <= AgentOutputProjection.maximumErrorMessageScalars)
            #expect(shownMessage.hasPrefix(prefix) && shownMessage.hasSuffix(suffix))
            #expect(shownError["code"]?.stringValue == "nativeActionFailed")
            #expect(shownError["messageTruncated"]?.boolValue == true)
            #expect(shownError["originalScalarLength"]?.scalarText == String(message.unicodeScalars.count))
            #expect(projected["didError"]?.boolValue == true)
            #expect(projected["nextSteps"]?.arrayValue?.first?.stringValue == "Do not replay input.")
            let data = try #require(projected["data"])
            let compactReceipt = CLIOutputValue.object(["cleanup": .string("uncertain"), "enqueuedEventCount": .integer(1)])
            for (key, expected) in [("action", compactReceipt), ("quarantine", quarantine), ("cache", cache)] {
                let actual = try #require(data[key])
                #expect(try encoded(actual) == encoded(expected))
            }
            #expect(data["context"] == nil && data["screen"] != nil)
            let batchStep = try #require(data["batch"]?["steps"]?.arrayValue?.first)
            let keptReceipt = try #require(batchStep["receipt"])
            let nestedError = try #require(batchStep["error"])
            #expect(batchStep["context"] == nil)
            #expect(try encoded(keptReceipt) == encoded(compactReceipt))
            #expect(try encoded(nestedError) == encoded(shownError))
            #expect(try encoded(projected).count < 20 * 1024)
        }
        let full = try AgentOutputProjection.project(original, view: .full)
        #expect(try encoded(full) == encoded(original))
    }

    @Test("Native detail chunks preserve literal whitespace and JSON characters")
    func nativeDetailChunksAreNotProjectedAsDisplayRows() throws {
        let exact = "A|B\n \"quoted\" \\ 😀e\u{301}"
        let detail = CLIOutputValue.object(["ref": .string("e2"), "field": .string("value"),
            "offset": .integer(0), "totalLength": .integer(Int64(exact.unicodeScalars.count)), "text": .string(exact)])
        let original = CLIOutputValue.object(["schema": .string("axe.output.agent-result"), "schemaVersion": .string("1"),
            "didError": .bool(false), "data": .object(["detail": detail]), "nextSteps": .array([])])
        let output = CLIOutputContext(format: .json, command: "describe-ui", agent: true)
        output.append(original)
        let decoded = try JSONDecoder().decode(CLIOutputValue.self, from: CLIOutput.rendered(output))
        #expect(decoded["data"]?["detail"]?["text"]?.stringValue == exact)
        let returnedDetail = try #require(decoded["data"]?["detail"])
        // The ref, field and offset repeat the request.
        #expect(try encoded(returnedDetail) == encoded(.object(["totalLength": .integer(Int64(exact.unicodeScalars.count)),
            "text": .string(exact)])))
    }

    @Test("A complete adaptive batch keeps input evidence and omits duplicate success fields")
    func successfulBatchKeepsInputEvidence() throws {
        let original = try completedBatchResult()
        let oldSteps = try #require(original["data"]?["batch"]?["steps"]?.arrayValue)
        for view in [AgentOutputView.reading, .navigation] {
            let projected = try AgentOutputProjection.project(original, view: view)
            let steps = try #require(projected["data"]?["batch"]?["steps"]?.arrayValue)
            #expect(steps.count == 2)
            #expect(projected["data"]?["batch"]?["completedSteps"]?.scalarText == "2")
            #expect(projected["data"]?["batch"]?["replayed"] == nil)
            #expect(projected["data"]?["batch"]?["totalSteps"] == nil)
            #expect(projected["data"]?["batch"]?["rolledBack"] == nil)
            for (old, step) in zip(oldSteps, steps) {
                #expect(step["cache"] == nil)
                #expect(step["requestID"] == nil)
                #expect(step["receipt"]?["kind"] == nil)
                #expect(step["receipt"]?["replayed"] == nil)
                for key in ["index", "action", "status"] {
                    let expected = try #require(old[key])
                    let actual = try #require(step[key])
                    #expect(try encoded(actual) == encoded(expected))
                }
                for key in ["outcome", "enqueuedEventCount"] {
                    let expected = try #require(old["receipt"]?[key])
                    let actual = try #require(step["receipt"]?[key])
                    #expect(try encoded(actual) == encoded(expected))
                }
                #expect(step["receipt"]?["cleanup"] == nil)
            }
            let capture = try #require(projected["data"]?["capture"])
            #expect(capture["snapshotID"]?.stringValue == snapshotID)
            // A current capture needs no cache state.
            #expect(projected["data"]?["cache"] == nil)
        }
        let full = try AgentOutputProjection.project(original, view: .full)
        #expect(try encoded(full) == encoded(original))
    }

    @Test("A type receipt retains its distinct native kind and additional evidence")
    func typedBatchKeepsDistinctReceiptEvidence() throws {
        var original = try completedBatchResult()
        original = try replacing(original, path: ["data", "batch", "steps", "1", "action"], with: .string("type"))
        original = try replacing(original, path: ["data", "batch", "steps", "1", "receipt", "kind"], with: .string("typeText"))
        original = try replacing(original, path: ["data", "batch", "steps", "1", "receipt", "enqueuedEventCount"], with: .integer(14))
        original = try replacing(original, path: ["data", "batch", "steps", "1", "receipt", "nativeEvidence"], with: .string("keep"))
        let projected = try AgentOutputProjection.project(original, view: .reading)
        let steps = try #require(projected["data"]?["batch"]?["steps"]?.arrayValue)
        #expect(steps[1]["action"]?.stringValue == "type")
        #expect(steps[1]["receipt"]?["kind"]?.stringValue == "typeText")
        #expect(steps[1]["receipt"]?["enqueuedEventCount"]?.scalarText == "14")
        #expect(steps[1]["receipt"]?["nativeEvidence"]?.stringValue == "keep")
        #expect(steps[1]["requestID"] == nil && steps[1]["receipt"]?["replayed"] == nil)
        let full = try AgentOutputProjection.project(original, view: .full)
        #expect(try encoded(full) == encoded(original))
    }

    @Test("A failed batch keeps every step's status, input evidence and the batch size")
    func finalCaptureFailureKeepsStepEvidence() throws {
        var original = try completedBatchResult()
        original = try replacing(original, path: ["didError"], with: .bool(true))
        original = try replacing(original, path: ["error"], with: .object([
            "code": .string("batchRefreshFailed"), "message": .string("Completed input has no fresh capture.")]))
        original = try replacing(original, path: ["data", "capture"], with: nil)
        original = try replacing(original, path: ["data", "cache"], with: .object([
            "status": .string("invalidated"), "requiresRefresh": .bool(true)]))
        let projected = try AgentOutputProjection.project(original, view: .reading)
        let batch = try #require(projected["data"]?["batch"])
        #expect(batch["totalSteps"]?.scalarText == "2" && batch["completedSteps"]?.scalarText == "2")
        let steps = try #require(batch["steps"]?.arrayValue)
        for step in steps {
            guard case let .object(fields) = step else { throw FixtureError.invalidPath }
            #expect(Set(fields.keys) == ["index", "action", "status", "receipt"])
            #expect(step["receipt"]?["outcome"]?.stringValue == "enqueuedAndDrained")
            #expect(step["receipt"]?["enqueuedEventCount"]?.scalarText == "2")
        }
        #expect(projected["data"]?["cache"]?["requiresRefresh"]?.boolValue == true)
        #expect(try encoded(AgentOutputProjection.project(original, view: .full)) == encoded(original))
    }

    @Test("A partial or malformed success keeps the batch size; only a verified success omits it")
    func incompleteBatchKeepsTotal() throws {
        let valid = try completedBatchResult()
        let variants = [
            try replacing(valid, path: ["data", "batch", "completedSteps"], with: .integer(1)),
            try replacing(valid, path: ["data", "batch", "stoppedAt"], with: .integer(2)),
            try replacing(valid, path: ["data", "batch", "replayed"], with: .bool(true)),
            try replacing(valid, path: ["data", "batch", "rolledBack"], with: .bool(true)),
            try replacing(valid, path: ["data", "batch", "steps", "1", "receipt"], with: nil),
            try replacing(valid, path: ["data", "batch", "steps", "1", "receipt", "cleanup"], with: .string("uncertain")),
            try replacing(valid, path: ["data", "batch", "steps", "1", "receipt", "replayed"], with: .bool(true)),
            try replacing(valid, path: ["data", "batch", "steps", "1", "receipt", "kind"], with: .string("typeText")),
            try replacing(valid, path: ["data", "batch", "steps", "1", "status"], with: .string("failed")),
            try replacing(valid, path: ["data", "batch", "steps", "1", "requestID"], with: .string("invalid")),
            try replacing(valid, path: ["data", "capture"], with: nil),
            try replacing(valid, path: ["data", "capture", "snapshotID"], with: .string("invalid")),
            try replacing(valid, path: ["data", "cache", "requiresRefresh"], with: .bool(true)),
        ]
        for original in variants {
            let projected = try AgentOutputProjection.project(original, view: .reading)
            #expect(projected["data"]?["batch"]?["totalSteps"]?.scalarText == "2")
        }
        let uncertain = try AgentOutputProjection.project(variants[5], view: .reading)
        #expect(uncertain["data"]?["batch"]?["steps"]?.arrayValue?[1]["receipt"]?["cleanup"]?.stringValue == "uncertain")
        let completed = try AgentOutputProjection.project(valid, view: .reading)
        #expect(completed["data"]?["batch"]?["totalSteps"] == nil)
    }

    @Test("A completed batch with a focus step also omits its batch size")
    func focusStepBatchIsCompact() throws {
        var original = try completedBatchResult()
        original = try replacing(original, path: ["data", "batch", "steps", "1", "action"], with: .string("type"))
        original = try replacing(original, path: ["data", "batch", "steps", "1", "receipt", "kind"], with: .string("focusAndType"))
        let projected = try AgentOutputProjection.project(original, view: .reading)
        #expect(projected["data"]?["batch"]?["totalSteps"] == nil)
        #expect(projected["data"]?["batch"]?["steps"]?.arrayValue?[1]["receipt"]?["kind"]?.stringValue == "focusAndType")
    }

    private func completedBatchResult() throws -> CLIOutputValue {
        let canonicalCapture = try #require(result(targets: ["e2|tap|button|Target||target"])["data"]?["capture"])
        let receipt = CLIOutputValue.object(["kind": .string("tap"), "outcome": .string("enqueuedAndDrained"),
            "enqueuedEventCount": .integer(2), "cleanup": .string("notNeeded"), "replayed": .bool(false)])
        let cache = CLIOutputValue.object(["status": .string("invalidated"), "reason": .string("batchInProgress"),
            "requiresRefresh": .bool(true)])
        let steps: [CLIOutputValue] = [1, 2].map { index in .object([
            "index": .integer(Int64(index)), "action": .string("tap"), "status": .string("completed"),
            "requestID": .string(index == 1 ? "A1F5E846-8027-49D2-8463-3D80D191A349" : "D776003F-875B-4FB4-BEB4-49712BC14B09"),
            "receipt": receipt, "cache": cache]) }
        return .object(["schema": .string("axe.output.agent-result"), "schemaVersion": .string("1"),
            "didError": .bool(false), "nextSteps": .array([]), "data": .object([
                "capture": canonicalCapture,
                "cache": .object(["status": .string("refreshed"), "requiresRefresh": .bool(false)]),
                "batch": .object(["totalSteps": .integer(2), "completedSteps": .integer(2),
                    "replayed": .bool(false), "rolledBack": .bool(false), "steps": .array(steps)])])])
    }

    private enum FixtureError: Error { case invalidPath }
    private func replacing(_ original: CLIOutputValue, path: [String], with replacement: CLIOutputValue?) throws -> CLIOutputValue {
        guard let first = path.first else { throw FixtureError.invalidPath }
        switch original {
        case var .object(fields):
            if path.count == 1 { fields[first] = replacement }
            else {
                guard let child = fields[first] else { throw FixtureError.invalidPath }
                fields[first] = try replacing(child, path: Array(path.dropFirst()), with: replacement)
            }
            return .object(fields)
        case var .array(values):
            guard let index = Int(first), values.indices.contains(index), path.count > 1 else { throw FixtureError.invalidPath }
            values[index] = try replacing(values[index], path: Array(path.dropFirst()), with: replacement)
            return .array(values)
        default: throw FixtureError.invalidPath
        }
    }

    private let snapshotID = "A1F5E846-8027-49D2-8463-3D80D191A349"

    private var context: CLIOutputValue {
        .object(["screenID": .integer(3), "logicalWidth": .integer(951), "logicalHeight": .integer(669),
                 "rotationDegrees": .integer(90), "screenUUID": .string("D776003F-875B-4FB4-BEB4-49712BC14B09"),
                 "bootIdentity": .string("101:123:456"), "poseRevision": .string("mechanicalDegrees=90.0")])
    }

    private func result(targets: [String] = [], scroll: [String] = [], text: [String] = [],
                        redundant: [String] = [], type: String = "runtime-snapshot", seq: Int64 = 1,
                        offset: Int = 0, total: Int? = nil) -> CLIOutputValue {
        let capture = CLIOutputValue.object(["snapshotID": .string(snapshotID), "screenHash": .string("0123456789abcdef"),
            "type": .string(type), "seq": .integer(seq), "expiresInSeconds": .floatingPoint(59.99999),
            "applicationPID": .integer(1234), "context": context, "keyboard": .object(["state": .string("unknown")]),
            "rowOffset": .integer(Int64(offset)), "rowLimit": .integer(64),
            "totalRows": .integer(Int64(total ?? targets.count + scroll.count + text.count)),
            "targets": .array(targets.map(CLIOutputValue.string)), "scroll": .array(scroll.map(CLIOutputValue.string)),
            "text": .array(text.map(CLIOutputValue.string)),
            "redundantTextRefs": .array(redundant.map(CLIOutputValue.string))])
        return .object(["schema": .string("axe.output.agent-result"), "schemaVersion": .string("1"),
            "didError": .bool(false), "nextSteps": .array([]), "data": .object([
                "capture": capture, "context": context,
                "cache": .object(["status": .string("refreshed"), "requiresRefresh": .bool(false)])])])
    }

    @Test("Adaptive output keeps field and static-label whitespace", arguments: [
        " leading", "trailing ", "two  spaces", "line one\nline two\t", "path\\with/slash",
    ])
    func exactWhitespaceSurvivesProjection(_ raw: String) throws {
        let original = result(targets: ["e1|typeText|text-field|Title|\(raw)|field"],
            text: ["e2|text|text|\(raw)||"])
        for view in [AgentOutputView.reading, .navigation, .full] {
            let projected = try AgentOutputProjection.project(original, view: view)
            let roundTrip = try JSONDecoder().decode(CLIOutputValue.self, from: encoded(projected))
            let capture = try #require(roundTrip["data"]?["capture"])
            let fields = (capture["rows"] ?? capture["targets"])?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(fields.contains { $0.split(separator: "|", omittingEmptySubsequences: false)[4] == Substring(raw) })
            if view != .navigation {
                let text = (capture["rows"] ?? capture["text"])?.arrayValue?.compactMap(\.stringValue) ?? []
                #expect(text.contains { $0.split(separator: "|", omittingEmptySubsequences: false)[3] == Substring(raw) })
            }
        }
    }

    private func encoded(_ value: CLIOutputValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
