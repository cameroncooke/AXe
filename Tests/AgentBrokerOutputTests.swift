import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

@Suite("Agent broker output boundaries")
struct AgentBrokerOutputTests {
    @Test("One row limit spans targets, scrolling and text without losing later controls")
    func mixedSectionsShareOneForwardPage() throws {
        let buttons = (1...42).map { Fixture(type: "Button", id: "button.\($0)", label: "Button \($0)") }
        let scrolls = (1...2).map { group in
            Fixture(type: "ScrollView", id: "scroll.\(group)", label: "List \(group)", children:
                (1...20).map { Fixture(type: "StaticText", id: "note.\(group).\($0)", label: "Note \(group).\($0)") })
        }
        let (snapshot, context) = try makeSnapshot(buttons + scrolls)
        let id = UUID()
        var offset = 0
        var allRows: [String] = []
        var sectionCounts = [0, 0, 0]
        var declaredTotal: Int?
        for _ in 0..<32 {
            let query = AgentModeRequest(kind: .describe, rowOffset: offset, rowLimit: 7)
            let page = snapshot.capture(id: id, sequence: 1, udid: "fixture", request: query,
                applicationPID: 1234, context: context, unchanged: false, expiresIn: 60)
            let rows = page.targets + page.scroll + page.text
            #expect(rows.count <= 7 && !rows.isEmpty)
            #expect(page.snapshotID == id && page.rowOffset == offset)
            let total = try #require(page.totalRows)
            #expect(total == page.targetCount + page.scrollCount + page.textCount)
            if let declaredTotal { #expect(total == declaredTotal) }
            declaredTotal = total
            sectionCounts[0] += page.targets.count
            sectionCounts[1] += page.scroll.count
            sectionCounts[2] += page.text.count
            allRows += rows
            guard let next = page.nextRowOffset else {
                #expect(!page.truncated)
                break
            }
            #expect(page.truncated && next == offset + rows.count && next > offset)
            offset = next
        }
        let expectedTotal = try #require(declaredTotal)
        #expect(allRows.count == expectedTotal)
        #expect(Set(allRows).count == allRows.count)
        #expect(sectionCounts.allSatisfy { $0 > 0 })
        let identifiers = allRows.map { String($0.split(separator: "|", omittingEmptySubsequences: false)[5]) }
        for number in 1...42 { #expect(identifiers.filter { $0 == "button.\(number)" }.count == 1) }
        for group in 1...2 {
            #expect(identifiers.contains("scroll.\(group)"))
            for number in 1...20 { #expect(identifiers.filter { $0 == "note.\(group).\(number)" }.count == 1) }
        }
    }

    @Test("Native text chunks preserve whitespace, pipes, quotes and complete scalar order")
    func nativeFieldsReassembleExactly() throws {
        let exact = " \nA|B \"quoted\" \\ 😀e\u{301} 👩🏽‍💻\t "
        let identifier = "native|field"
        let (snapshot, _) = try makeSnapshot([Fixture(type: "TextField", id: identifier,
            label: exact, value: exact)])
        for field in [AgentModeTextQuery.Field.label, .value, .id] {
            let expected = field == .id ? identifier : exact
            var offset = 0
            var reassembled = ""
            for _ in 0..<128 {
                let detail = try snapshot.detail(ref: "e2", query: .init(field: field, offset: offset, limit: 3))
                #expect(detail.ref == "e2" && detail.field == field)
                #expect(detail.offset == offset && detail.totalLength == expected.unicodeScalars.count)
                #expect(detail.text.unicodeScalars.count <= 3)
                reassembled += detail.text
                guard let next = detail.nextOffset else { break }
                #expect(next == offset + detail.text.unicodeScalars.count && next > offset)
                offset = next
            }
            #expect(Array(reassembled.unicodeScalars) == Array(expected.unicodeScalars))
        }
    }

    @Test("Offsets use Unicode scalars and the exact end returns an empty terminal chunk")
    func scalarOffsetsAndEmptyTerminalChunk() throws {
        let exact = "😀e\u{301}Z"
        let (snapshot, _) = try makeSnapshot([Fixture(type: "StaticText", id: "text", label: exact)])
        let combining = try snapshot.detail(ref: "e2", query: .init(field: .label, offset: 2, limit: 1))
        #expect(combining.text == "\u{301}" && combining.nextOffset == 3 && combining.totalLength == 4)
        let end = try snapshot.detail(ref: "e2", query: .init(field: .label, offset: 4, limit: 1))
        #expect(end.text.isEmpty && end.nextOffset == nil && end.totalLength == 4)
        let absent = try snapshot.detail(ref: "e2", query: .init(field: .value, offset: 0, limit: 1))
        #expect(absent.text.isEmpty && absent.nextOffset == nil && absent.totalLength == 0)
    }

    @Test("Invalid ranges and unknown references are refused without returning another field")
    func rejectsInvalidRangesAndReferences() throws {
        let (snapshot, _) = try makeSnapshot([Fixture(type: "StaticText", id: "text", label: "value")])
        for query in [AgentModeTextQuery(field: .label, offset: -1, limit: 1),
                      .init(field: .label, offset: 0, limit: 0),
                      .init(field: .label, offset: 0, limit: 4097),
                      .init(field: .label, offset: 6, limit: 1)] {
            do {
                _ = try snapshot.detail(ref: "e2", query: query)
                Issue.record("An invalid text range succeeded.")
            } catch let error as AgentModeFailure { #expect(error.code == "invalidTextRange") }
        }
        do {
            _ = try snapshot.detail(ref: "e999", query: .init(field: .label, offset: 0, limit: 1))
            Issue.record("An unknown reference returned a field.")
        } catch let error as AgentModeFailure { #expect(error.code == "referenceMissing") }
    }

    @Test("A generic unaddressable parent cannot hide its child's text")
    func textDedupRequiresAnEmittedParentControl() throws {
        let section = Fixture(type: "Other", id: "", label: "Section", children: [
            Fixture(type: "StaticText", id: "", label: "Section")])
        let button = Fixture(type: "Button", id: "button.primary", label: "Press", children: [
            Fixture(type: "StaticText", id: "", label: "Press")])
        let (snapshot, context) = try makeSnapshot([section, section, button])
        let capture = snapshot.capture(id: UUID(), sequence: 1, udid: "fixture",
            request: AgentModeRequest(kind: .describe), applicationPID: 1234,
            context: context, unchanged: false, expiresIn: 60)
        let textRows = capture.text.map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        let sections = Set(textRows.filter { $0[3] == "Section" }.map { $0[0] })
        let buttonText = Set(textRows.filter { $0[3] == "Press" }.map { $0[0] })
        #expect(sections.count == 2 && buttonText.count == 1)
        let redundant = Set(capture.redundantTextRefs ?? [])
        #expect(redundant.isDisjoint(with: sections))
        #expect(buttonText.isSubset(of: redundant))

        let canonical = try JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(capture))
        let result = CLIOutputValue.object(["schema": .string("axe.output.agent-result"),
            "schemaVersion": .string("1"), "didError": .bool(false),
            "data": .object(["capture": canonical])])
        let projected = try AgentOutputProjection.project(result, view: .reading)
        let rowValues = try #require(projected["data"]?["capture"]?["rows"]?.arrayValue)
        let rows = rowValues.compactMap(\.stringValue)
        let refs = Set(rows.map { String($0.prefix { $0 != "|" }) })
        #expect(sections.isSubset(of: refs))
        #expect(buttonText.isDisjoint(with: refs))
    }

    @Test("The first page previews at most four cached scroll refs without changing its rows")
    func cachedScrollPreviewKeepsCanonicalPages() throws {
        let buttons = (1...70).map { Fixture(type: "Button", id: "button.\($0)", label: "Button \($0)") }
        let scrolls = (1...6).map { Fixture(type: "ScrollView", id: "scroll.\($0)", label: "List \($0)") }
        let (snapshot, context) = try makeSnapshot(buttons + scrolls)
        let id = UUID()
        let first = snapshot.capture(id: id, sequence: 1, udid: "fixture",
            request: .init(kind: .describe), applicationPID: 1234,
            context: context, unchanged: false, expiresIn: 60)
        #expect(first.targets.count == 64 && first.scroll.isEmpty)
        #expect(first.nextRowOffset == 64)
        let preview = try #require(first.scrollPreview)
        #expect(preview.rows.count == 4 && preview.hasMore)
        let refs = preview.rows.map { String($0.prefix { $0 != "|" }) }
        #expect(Set(refs).count == 4)
        for ref in refs {
            let detail = try snapshot.detail(ref: ref, query: .init(field: .id, offset: 0, limit: 4096))
            #expect(detail.text.hasPrefix("scroll."))
            #expect(detail.actions.contains(.swipeWithin))
        }
        let later = snapshot.capture(id: id, sequence: 1, udid: "fixture",
            request: .init(kind: .describe, rowOffset: 64), applicationPID: 1234,
            context: context, unchanged: false, expiresIn: 60)
        #expect(later.scrollPreview == nil)
        let unchanged = snapshot.capture(id: id, sequence: 1, udid: "fixture",
            request: .init(kind: .describe), applicationPID: 1234,
            context: context, unchanged: true, expiresIn: 60)
        #expect(unchanged.scrollPreview == nil)

        // The wire preview is bounded before transport, not only at final rendering.
        let longScroll = Fixture(type: "ScrollView", id: "scroll.long", label: String(repeating: "😀", count: 20_000))
        let (longSnapshot, longContext) = try makeSnapshot(buttons + [longScroll])
        let longCapture = longSnapshot.capture(id: id, sequence: 1, udid: "fixture",
            request: .init(kind: .describe), applicationPID: 1234,
            context: longContext, unchanged: false, expiresIn: 60)
        let bounded = try #require(longCapture.scrollPreview)
        #expect(try JSONEncoder().encode(bounded).count < AgentOutputProjection.maximumCaptureBytes)
        #expect(bounded.truncatedFields?.first?["field"]?.stringValue == "label")
        #expect(bounded.truncatedFields?.first?["displayScalarLength"]?.scalarText == "20000")
    }

    private func makeSnapshot(_ children: [Fixture]) throws -> (AgentModeSnapshot, SelectedHIDContext) {
        let context = try JSONDecoder().decode(SelectedHIDContext.self, from: Data(
            #"{"bootIdentity":"1:2:3","screenID":3,"screenUUID":"DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0","logicalWidth":951,"logicalHeight":669,"rotationDegrees":90,"nativePixelWidth":2007,"nativePixelHeight":2853,"scale":3,"poseRevision":"mechanicalDegrees=90.0"}"#.utf8))
        let roots = [Fixture(type: "Application", id: "fixture", label: "Fixture", children: children)]
        let nodes = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode(roots))
        return (try AgentModeSnapshot(roots: nodes, context: context), context)
    }

    private struct Fixture: Encodable {
        struct Frame: Encodable {
            let x = 10.0
            let y = 100.0
            let width = 300.0
            let height = 44.0
        }
        let type: String
        let id: String
        let label: String
        var value: String? = nil
        var children: [Fixture] = []
        let frame = Frame()
        let pid: Int32 = 1234
        let enabled = true
        let hidden = false
        let focused = true
        private enum CodingKeys: String, CodingKey {
            case type, id = "AXUniqueId", label = "AXLabel", value = "AXValue", children, frame, pid, enabled, hidden, focused
        }
    }
}
