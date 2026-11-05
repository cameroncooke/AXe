import Foundation

/// A reading view can fill unused space from one more page of the same captured table.
enum AgentPageEnrichment {
    private static let localFillMetadata: CLIOutputValue = .object(["extraReads": .integer(0)])

    static func continuationOffset(_ original: CLIOutputValue) throws -> Int? {
        guard original["didError"]?.boolValue == false,
              original["data"]?["cache"]?["requiresRefresh"]?.boolValue == false,
              let source = original["data"]?["capture"],
              let page = Page(source), let next = page.next else { return nil }
        let projected = try AgentOutputProjection.project(original, view: .reading)
        guard let capture = projected["data"]?["capture"],
              let rows = capture["rows"]?.arrayValue, rows.count < AgentOutputProjection.maximumRows,
              integer(capture["page"]?["nextOffset"]) == next,
              case var .object(reserved) = source else { return nil }

        // Budget for the largest cursor from the optional page and the local-fill marker.
        // Adding the page must not displace an already visible row from this reply.
        let lastOffset = min(page.total, next + AgentOutputProjection.maximumRows)
        reserved["nextRowOffset"] = .integer(Int64(lastOffset))
        reserved["pageEnrichment"] = localFillMetadata
        let preview = try AgentOutputProjection.project(
            replacingCapture(original, with: .object(reserved)), view: .reading)
        guard let projectedPage = preview["data"]?["capture"],
              projectedPage["rows"]?.arrayValue?.count == rows.count,
              integer(projectedPage["page"]?["nextOffset"]) == lastOffset else { return nil }
        return next
    }

    static func enrich(_ original: CLIOutputValue, continuation: CLIOutputValue) -> CLIOutputValue {
        guard original["didError"]?.boolValue == false,
              original["data"]?["cache"]?["requiresRefresh"]?.boolValue == false,
              let first = original["data"]?["capture"], let page = Page(first),
              let next = page.next, let second = Page(continuation), second.offset == next,
              (try? matches(first, continuation)) == true,
              let merged = try? merge(first, continuation, second: second) else { return original }
        return replacingCapture(original, with: merged)
    }

    private static func matches(_ first: CLIOutputValue, _ second: CLIOutputValue) throws -> Bool {
        for key in ["type", "rs", "snapshotID", "screenHash", "seq", "count", "udid",
                    "applicationPID", "context", "targetCount", "scrollCount", "textCount",
                    "totalRows", "keyboard"] {
            guard try same(first[key], second[key]) else { return false }
        }
        return true
    }

    private static func merge(_ first: CLIOutputValue, _ second: CLIOutputValue,
                              second page: Page) throws -> CLIOutputValue {
        guard case var .object(merged) = first else { throw InvalidPage.metadata }
        for key in ["targets", "scroll", "text"] {
            merged[key] = .array((first[key]?.arrayValue ?? []) + (second[key]?.arrayValue ?? []))
        }
        for key in ["customActions", "unavailableReferences"] {
            var entries: [String: CLIOutputValue] = [:]
            for source in [first, second] {
                guard let value = source[key] else { continue }
                guard case let .object(fields) = value else { throw InvalidPage.metadata }
                for (ref, content) in fields {
                    if let prior = entries[ref], !(try same(prior, content)) { throw InvalidPage.metadata }
                    entries[ref] = content
                }
            }
            if !entries.isEmpty { merged[key] = .object(entries) }
        }
        for key in ["redundantTextRefs", "truncatedCustomActionRefs"] {
            var seen: Set<String> = []
            var values: [CLIOutputValue] = []
            for source in [first, second] {
                guard let value = source[key] else { continue }
                guard let refs = value.arrayValue else { throw InvalidPage.metadata }
                for ref in refs {
                    guard let text = ref.stringValue else { throw InvalidPage.metadata }
                    if seen.insert(text).inserted { values.append(.string(text)) }
                }
            }
            if !values.isEmpty { merged[key] = .array(values) }
        }
        merged["nextRowOffset"] = page.next.map { .integer(Int64($0)) }
        merged["truncated"] = .bool(page.next != nil)
        guard let firstExpiry = first["expiresInSeconds"]?.scalarText.flatMap(Double.init),
              let secondExpiry = second["expiresInSeconds"]?.scalarText.flatMap(Double.init) else {
            throw InvalidPage.metadata
        }
        merged["expiresInSeconds"] = .floatingPoint(min(firstExpiry, secondExpiry))
        merged["pageEnrichment"] = localFillMetadata
        return .object(merged)
    }

    private static func replacingCapture(_ original: CLIOutputValue, with capture: CLIOutputValue) -> CLIOutputValue {
        guard case var .object(result) = original,
              case var .object(data)? = result["data"] else { return original }
        data["capture"] = capture
        result["data"] = .object(data)
        return .object(result)
    }

    private static func same(_ first: CLIOutputValue?, _ second: CLIOutputValue?) throws -> Bool {
        guard let first else { return second == nil }
        guard let second else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(first) == encoder.encode(second)
    }

    private static func integer(_ value: CLIOutputValue?) -> Int? {
        guard case let .integer(number)? = value else { return nil }
        return Int(exactly: number)
    }

    private enum InvalidPage: Error { case metadata }

    private struct Page {
        let total: Int
        let offset: Int
        let next: Int?

        init?(_ source: CLIOutputValue) {
            guard source["type"]?.stringValue == "runtime-snapshot",
                  let idText = source["snapshotID"]?.stringValue, UUID(uuidString: idText) != nil,
                  let pidValue = integer(source["applicationPID"]), let pid = Int32(exactly: pidValue), pid > 0,
                  let screenValue = integer(source["context"]?["screenID"]), UInt32(exactly: screenValue) != nil,
                  let screenText = source["context"]?["screenUUID"]?.stringValue,
                  UUID(uuidString: screenText) != nil,
                  let offset = integer(source["rowOffset"]), offset >= 0,
                  let limit = integer(source["rowLimit"]), limit == 64,
                  let total = integer(source["totalRows"]), total > offset, total <= AgentModeRequest.maximumRows,
                  let expiry = source["expiresInSeconds"]?.scalarText.flatMap(Double.init), expiry.isFinite, expiry > 0 else { return nil }
            let end = min(total, offset + limit)
            var base = 0
            for (rowsKey, countKey) in [("targets", "targetCount"), ("scroll", "scrollCount"), ("text", "textCount")] {
                guard let count = integer(source[countKey]), count >= 0, count <= total,
                      let rows = source[rowsKey]?.arrayValue,
                      rows.count == max(0, min(end, base + count) - max(offset, base)),
                      rows.allSatisfy({ $0.stringValue != nil }) else { return nil }
                base += count
            }
            guard base == total else { return nil }
            let next = integer(source["nextRowOffset"])
            guard end < total ? next == end : (source["nextRowOffset"] == nil || source["nextRowOffset"]?.scalarText == "null") else { return nil }
            self.total = total; self.offset = offset; self.next = next
        }
    }
}
