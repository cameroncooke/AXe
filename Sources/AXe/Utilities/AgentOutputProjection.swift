import Foundation

/// The public adaptive view changes presentation, never the broker's reference table.
enum AgentOutputView: String, CaseIterable, Sendable {
    case navigation
    case reading
    case full
}

enum AgentOutputProjection {
    static let maximumCellScalars = 160
    static let maximumErrorMessageScalars = 1024
    /// Leave room for action, error, batch and recovery evidence in the envelope.
    static let maximumCaptureBytes = 16 * 1024
    static let maximumRows = 64
    static let maximumAreaPreviewRows = 4

    /// Bound preview cells before the broker serializes them, using the same public row rules.
    static func scrollPreview(rows: [String], hasMore: Bool) -> AgentModeScrollPreview {
        let preview = rows.prefix(maximumAreaPreviewRows).map(Row.init)
        let fields = preview.flatMap(\.clippedFields)
        return AgentModeScrollPreview(rows: preview.map(\.text), hasMore: hasMore || rows.count > maximumAreaPreviewRows,
            truncatedFields: fields.isEmpty ? nil : fields)
    }

    static func project(_ result: CLIOutputValue, view: AgentOutputView) throws -> CLIOutputValue {
        guard result["schema"]?.stringValue == "axe.output.agent-result" else { return result }
        guard view != .full else { return removingScrollPreview(result) }
        guard case var .object(envelope) = result,
              let sourceData = envelope["data"],
              case var .object(data) = sourceData else { return result }
        envelope["schemaVersion"] = .string("2")
        if let error = envelope["error"] { envelope["error"] = compactError(error) }
        let failed = result["didError"]?.boolValue == true
        let refreshedBatchCapture = result["didError"]?.boolValue == false
            && isAbsentOrNull(result["error"]) && isAbsentOrNull(data["quarantine"])
            && hasRefreshedBatchCapture(data)
        if let capture = data["capture"] {
            data["capture"] = try compactCapture(capture, view: view)
            // The selected display is represented once in the adaptive capture.
            data.removeValue(forKey: "context")
        } else if !failed, let context = data["context"] {
            data["screen"] = screen(context)
            data.removeValue(forKey: "context")
        }
        if let batch = data["batch"] {
            data["batch"] = compactBatch(batch, removeSharedContext: !failed,
                refreshedFinalCapture: refreshedBatchCapture)
        }
        envelope["data"] = .object(data)
        return .object(envelope)
    }

    private static func compactCapture(_ source: CLIOutputValue, view: AgentOutputView) throws -> CLIOutputValue {
        var capture: [String: CLIOutputValue] = [:]
        for key in ["snapshotID", "seq"] { capture[key] = source[key] }
        if let expiry = source["expiresInSeconds"]?.scalarText.flatMap(Double.init), expiry.isFinite,
           let seconds = Int64(exactly: max(0, expiry.rounded(.down))) {
            capture["expiresInSeconds"] = .integer(seconds)
        }
        if source["type"]?.stringValue == "runtime-snapshot-unchanged" {
            // The UUID can change even when another caller observed the same hash.
            capture["unchanged"] = .bool(true)
            return .object(capture)
        }
        capture["screenHash"] = source["screenHash"]
        capture["pid"] = source["applicationPID"]
        capture["screen"] = source["context"].map(screen)
        capture["keyboard"] = source["keyboard"]?["state"]
        capture["view"] = .string(view.rawValue)

        let targets = source["targets"]?.arrayValue ?? []
        let scroll = source["scroll"]?.arrayValue ?? []
        let text = source["text"]?.arrayValue ?? []
        let sourceRows = targets + scroll + text
        let inputRefs = Set((targets + scroll).compactMap { $0.stringValue }.map { String($0.prefix { $0 != "|" }) })
        if case let .object(reasons)? = source["unavailableReferences"] {
            let allowed = reasons.filter { inputRefs.contains($0.key) && $0.value.stringValue == "nativeIdentityIncomplete" }
            if !allowed.isEmpty { capture["unavailableReferences"] = .object(allowed) }
        }
        for key in ["customActions", "truncatedCustomActionRefs", "pageEnrichment"] { capture[key] = source[key] }
        let textStart = targets.count + scroll.count
        let redundant = Set(source["redundantTextRefs"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let offset = integer(source["rowOffset"])
        let total = source["totalRows"] ?? .integer(Int64(
            integer(source["targetCount"]) + integer(source["scrollCount"]) + integer(source["textCount"])))
        var rows: [Row] = []
        var indices: [String: Int] = [:]
        var processed = 0
        var next = source["nextRowOffset"]
        // A later row can force a cursor onto an otherwise complete canonical page.
        let budgetCursor = next ?? .integer(Int64(offset + sourceRows.count))

        for (index, raw) in sourceRows.enumerated() {
            guard let raw = raw.stringValue else { continue }
            let row = Row(raw)
            if index >= textStart, view == .navigation || redundant.contains(row.ref) {
                processed = index + 1
                continue
            }
            var trial = rows
            if let existing = indices[row.ref], trial[existing].hasSameContent(as: row) {
                trial[existing].merge(row.actions)
            } else {
                trial.append(row)
            }
            if trial.count > maximumRows {
                next = .integer(Int64(offset + processed))
                break
            }
            let proposed = try withRows(capture, rows: trial, offset: offset, total: total, next: budgetCursor)
            if try encodedSize(proposed) > maximumCaptureBytes, !rows.isEmpty {
                next = .integer(Int64(offset + processed))
                break
            }
            if trial.count > rows.count { indices[row.ref] = trial.count - 1 }
            rows = trial
            processed = index + 1
        }
        // Canonical offsets include static text, which navigation deliberately omits.
        // Keep a budget cursor while controls remain; do not advertise text-only tails.
        if view == .navigation,
           case let .integer(targetCount)? = source["targetCount"],
           case let .integer(scrollCount)? = source["scrollCount"],
           case let .integer(textCount)? = source["textCount"],
           case let .integer(totalRows)? = source["totalRows"],
           case let .integer(nextOffset)? = next,
           targetCount >= 0, scrollCount >= 0, textCount >= 0,
           targetCount <= totalRows, scrollCount <= totalRows - targetCount,
           textCount == totalRows - targetCount - scrollCount,
           nextOffset > Int64(offset), nextOffset <= totalRows,
           nextOffset >= targetCount + scrollCount {
            next = nil
        }
        let canonical = try withRows(capture, rows: rows, offset: offset, total: total, next: next)
        return try addingScrollPreview(source["scrollPreview"], to: canonical)
    }

    /// The base schema keeps its exact fields; preview metadata is broker-internal.
    private static func removingScrollPreview(_ result: CLIOutputValue) -> CLIOutputValue {
        guard case var .object(envelope) = result,
              case var .object(data)? = envelope["data"],
              case var .object(capture)? = data["capture"],
              capture.removeValue(forKey: "scrollPreview") != nil else { return result }
        data["capture"] = .object(capture)
        envelope["data"] = .object(data)
        return .object(envelope)
    }

    /// Add only what fits after the canonical rows/cursor are final. No extra read.
    private static func addingScrollPreview(_ source: CLIOutputValue?,
                                            to original: CLIOutputValue) throws -> CLIOutputValue {
        guard case let .object(preview)? = source,
              let rawRows = preview["rows"]?.arrayValue, !rawRows.isEmpty,
              rawRows.count <= maximumAreaPreviewRows, rawRows.allSatisfy({ $0.stringValue != nil }),
              let hasMore = preview["hasMore"]?.boolValue,
              case let .object(capture) = original else { return original }
        let canonicalSwipeRefs = Set((capture["rows"]?.arrayValue ?? []).compactMap { value -> String? in
            guard let text = value.stringValue else { return nil }
            let row = Row(text)
            return row.actions.contains { $0.split(separator: ",").contains("swipe") } ? row.ref : nil
        })
        var seen: Set<String> = []
        let candidates = rawRows.compactMap(\.stringValue).map(Row.init).filter {
            !$0.ref.isEmpty && !canonicalSwipeRefs.contains($0.ref) && seen.insert($0.ref).inserted
        }
        var result = original
        var rows: [Row] = []
        for (index, row) in candidates.enumerated() {
            let trial = rows + [row]
            var value = capture
            value["areas"] = .object(["preview": .bool(true),
                "hasMore": .bool(hasMore || index + 1 < candidates.count),
                "rows": .array(trial.map { .string($0.text) })])
            var fields = capture["truncatedFields"]?.arrayValue ?? []
            var fieldKeys = Set(fields.map { ($0["ref"]?.stringValue ?? "") + ":" + ($0["field"]?.stringValue ?? "") })
            let trialRefs = Set(trial.map(\.ref))
            let priorFields = (preview["truncatedFields"]?.arrayValue ?? []).filter {
                $0["ref"]?.stringValue.map(trialRefs.contains) == true
            }
            for field in priorFields + trial.flatMap(\.clippedFields) {
                let key = (field["ref"]?.stringValue ?? "") + ":" + (field["field"]?.stringValue ?? "")
                if fieldKeys.insert(key).inserted { fields.append(field) }
            }
            if !fields.isEmpty { value["truncatedFields"] = .array(fields) }
            let proposed = CLIOutputValue.object(value)
            guard try encodedSize(proposed) <= maximumCaptureBytes else { break }
            rows = trial
            result = proposed
        }
        return result
    }

    private static func withRows(_ capture: [String: CLIOutputValue], rows: [Row], offset: Int,
                                 total: CLIOutputValue, next: CLIOutputValue?) throws -> CLIOutputValue {
        var value = capture
        value.removeValue(forKey: "pageEnrichment")
        if case let .object(reasons)? = value["unavailableReferences"] {
            let emitted = Set(rows.map(\.ref))
            let shown = reasons.filter { emitted.contains($0.key) }
            if shown.isEmpty { value.removeValue(forKey: "unavailableReferences") }
            else { value["unavailableReferences"] = .object(shown) }
        }
        let emitted = Set(rows.map(\.ref))
        if let names = value.removeValue(forKey: "customActions") {
            let groups = try customActionGroups(names, refs: rows.map(\.ref))
            if !groups.isEmpty { value["customActionGroups"] = .array(groups) }
        }
        if let refs = value["truncatedCustomActionRefs"]?.arrayValue {
            let shown = refs.filter { $0.stringValue.map(emitted.contains) == true }
            if shown.isEmpty { value.removeValue(forKey: "truncatedCustomActionRefs") }
            else { value["truncatedCustomActionRefs"] = .array(shown) }
        }
        value["rows"] = .array(rows.map { .string($0.text) })
        var page: [String: CLIOutputValue] = [:]
        if let next {
            page["offset"] = .integer(Int64(offset))
            page["total"] = total
            page["nextOffset"] = next
        } else if offset > 0 {
            // Correlate an explicit terminal-page request without implying more rows.
            page["offset"] = .integer(Int64(offset))
        }
        if case let .object(enrichment)? = capture["pageEnrichment"] {
            for key in ["extraReads", "incomplete", "reason", "requiresRefresh"] { page[key] = enrichment[key] }
        }
        if !page.isEmpty { value["page"] = .object(page) }
        let clipped = rows.flatMap(\.clippedFields)
        if !clipped.isEmpty { value["truncatedFields"] = .array(clipped) }
        return .object(value)
    }

    /// Preview equality is exact UTF-8 equality, not Swift's canonical Unicode equivalence.
    /// Group only emitted refs before each trial/final byte-budget check.
    private static func customActionGroups(_ source: CLIOutputValue, refs: [String]) throws -> [CLIOutputValue] {
        guard case let .object(namesByRef) = source else {
            throw AgentModeFailure("invalidCustomActionMetadata", "Custom-action previews must be keyed by reference.")
        }
        var groups: [(refs: [String], names: [String])] = []
        var indices: [[Data]: Int] = [:]
        var seen: Set<String> = []
        for ref in refs where seen.insert(ref).inserted {
            guard let value = namesByRef[ref] else { continue }
            guard let values = value.arrayValue else {
                throw AgentModeFailure("invalidCustomActionMetadata", "A custom-action preview must be a name array.")
            }
            let names = try values.map { value -> String in
                guard let name = value.stringValue else {
                    throw AgentModeFailure("invalidCustomActionMetadata", "A custom-action name must be text.")
                }
                return name
            }
            let key = names.map { Data($0.utf8) }
            if let index = indices[key] { groups[index].refs.append(ref) }
            else { indices[key] = groups.count; groups.append((refs: [ref], names: names)) }
        }
        return groups.map { group in
            .object(["refs": .array(group.refs.map { .string($0) }),
                     "names": .array(group.names.map { .string($0) })])
        }
    }

    private static func screen(_ context: CLIOutputValue) -> CLIOutputValue {
        .array(["screenID", "logicalWidth", "logicalHeight", "rotationDegrees"].map { context[$0] ?? .null })
    }

    private static func compactBatch(_ source: CLIOutputValue, removeSharedContext: Bool,
                                     refreshedFinalCapture: Bool) -> CLIOutputValue {
        guard case var .object(batch) = source, let steps = batch["steps"]?.arrayValue else { return source }
        let compactCompletedBatch = refreshedFinalCapture && completedBatch(batch, steps: steps)
        if compactCompletedBatch {
            // Completed count and ordered receipts already state the successful batch size.
            batch.removeValue(forKey: "totalSteps")
            batch.removeValue(forKey: "rolledBack")
        }
        // A successful batch has already proved that all steps share its baseline.
        batch["steps"] = .array(steps.map { step in
            guard case var .object(fields) = step else { return step }
            if removeSharedContext { fields.removeValue(forKey: "context") }
            if compactCompletedBatch, let cacheValue = fields["cache"],
               case let .object(cache) = cacheValue, cache.count == 3,
               cache["status"]?.stringValue == "invalidated",
               cache["reason"]?.stringValue == "batchInProgress",
               cache["requiresRefresh"]?.boolValue == true {
                // The final refreshed capture supersedes this exact intermediate state.
                fields.removeValue(forKey: "cache")
            }
            if compactCompletedBatch, let receiptValue = fields["receipt"],
               case var .object(receipt) = receiptValue {
                // The full view retains diagnostic IDs; the adaptive view keeps input evidence.
                fields.removeValue(forKey: "requestID")
                if receipt["kind"]?.stringValue == fields["action"]?.stringValue {
                    receipt.removeValue(forKey: "kind")
                }
                receipt.removeValue(forKey: "replayed")
                fields["receipt"] = .object(receipt)
            }
            if let error = fields["error"] { fields["error"] = compactError(error) }
            return .object(fields)
        })
        return .object(batch)
    }

    private static func hasRefreshedBatchCapture(_ data: [String: CLIOutputValue]) -> Bool {
        guard let capture = data["capture"], capture["type"]?.stringValue == "runtime-snapshot",
              let id = capture["snapshotID"]?.stringValue, UUID(uuidString: id) != nil,
              capture["targets"]?.arrayValue != nil, capture["scroll"]?.arrayValue != nil,
              capture["text"]?.arrayValue != nil,
              data["cache"]?["status"]?.stringValue == "refreshed",
              data["cache"]?["requiresRefresh"]?.boolValue == false else { return false }
        return true
    }

    private static func completedBatch(_ batch: [String: CLIOutputValue], steps: [CLIOutputValue]) -> Bool {
        guard (1...8).contains(steps.count), batchInteger(batch["totalSteps"]) == steps.count,
              batchInteger(batch["completedSteps"]) == steps.count, isAbsentOrNull(batch["stoppedAt"]),
              batch["replayed"]?.boolValue == false, batch["rolledBack"]?.boolValue == false else { return false }
        return steps.enumerated().allSatisfy { offset, step in
            guard batchInteger(step["index"]) == offset + 1, step["status"]?.stringValue == "completed",
                  isAbsentOrNull(step["error"]), let requestID = step["requestID"]?.stringValue,
                  UUID(uuidString: requestID) != nil, let action = step["action"]?.stringValue,
                  action == "tap" || action == "type", let receipt = step["receipt"],
                  receipt["kind"]?.stringValue == (action == "tap" ? "tap" : "typeText"),
                  receipt["outcome"]?.stringValue == "enqueuedAndDrained",
                  receipt["cleanup"]?.stringValue == "notNeeded", receipt["replayed"]?.boolValue == false,
                  let count = batchInteger(receipt["enqueuedEventCount"]), count >= 0,
                  isAbsentOrNull(receipt["quarantine"]) else { return false }
            return true
        }
    }

    private static func batchInteger(_ value: CLIOutputValue?) -> Int? {
        guard let value, case let .integer(number) = value else { return nil }
        return Int(exactly: number)
    }

    private static func isAbsentOrNull(_ value: CLIOutputValue?) -> Bool {
        guard let value else { return true }
        if case .null = value { return true }
        return false
    }

    private static func compactError(_ source: CLIOutputValue) -> CLIOutputValue {
        guard case var .object(error) = source, let message = error["message"]?.stringValue else { return source }
        let scalars = message.unicodeScalars
        let limit = maximumErrorMessageScalars
        guard scalars.prefix(limit + 1).count > limit else { return source }
        let separator = "\n…\n"
        let retained = limit - separator.unicodeScalars.count
        let prefixLength = retained / 2
        let suffixLength = retained - prefixLength
        let prefix = String(String.UnicodeScalarView(scalars.prefix(prefixLength)))
        let suffix = String(String.UnicodeScalarView(scalars.suffix(suffixLength)))
        error["message"] = .string(prefix + separator + suffix)
        error["messageTruncated"] = .bool(true)
        error["originalScalarLength"] = .integer(Int64(scalars.count))
        return .object(error)
    }

    private static func integer(_ value: CLIOutputValue?) -> Int {
        value?.scalarText.flatMap(Int.init) ?? 0
    }

    private static func encodedSize(_ value: CLIOutputValue) throws -> Int {
        try JSONEncoder().encode(value).count
    }

    private struct Row {
        let ref: String
        var actions: [String]
        let role: String
        let label: String
        let value: String
        let labelField: String
        private let displayLabel: String
        private let displayValue: String
        let clippedFields: [CLIOutputValue]

        init(_ raw: String) {
            var cells = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            while cells.count < 6 { cells.append("") }
            ref = cells[0]
            actions = [cells[1]]
            role = cells[2]
            labelField = cells[3].isEmpty ? "id" : "label"
            label = cells[3].isEmpty ? cells[5] : cells[3]
            value = cells[4]
            let labelClip = Self.clip(label, ref: ref, field: labelField)
            let valueClip = Self.clip(value, ref: ref, field: "value")
            displayLabel = labelClip.text
            displayValue = valueClip.text
            clippedFields = [labelClip.evidence, valueClip.evidence].compactMap { $0 }
        }

        func hasSameContent(as other: Row) -> Bool {
            role == other.role && label == other.label && value == other.value && labelField == other.labelField
        }

        mutating func merge(_ extra: [String]) {
            for action in extra where !actions.contains(action) { actions.append(action) }
        }

        var text: String {
            [ref, actions.joined(separator: ","), role, displayLabel, displayValue].joined(separator: "|")
        }

        private static func clip(_ text: String, ref: String, field: String)
            -> (text: String, evidence: CLIOutputValue?) {
            let limit = AgentOutputProjection.maximumCellScalars
            let scalars = text.unicodeScalars
            let prefix = scalars.prefix(limit + 1)
            guard prefix.count > limit else { return (text, nil) }
            let evidence = CLIOutputValue.object([
                "ref": .string(ref), "field": .string(field), "displayScalarLength": .integer(Int64(scalars.count))
            ])
            return (String(String.UnicodeScalarView(prefix.prefix(limit - 1))) + "…", evidence)
        }
    }
}
