import AXeCore
import Foundation
import FBSimulatorControl

extension AgentModeSnapshot {
    func capture(id: UUID, sequence: Int, udid: String, request: AgentModeRequest,
                 applicationPID: Int32, context: SelectedHIDContext,
                 unchanged: Bool, expiresIn: Double) -> AgentModeCapture {
        let targets = targetRows()
        let scroll = RuntimeSnapshotCompactor.scrollAreas(in: elements, limit: Self.maximumElements)
        let text = RuntimeSnapshotCompactor.text(in: elements, limit: Self.maximumElements)
        let emittedParents = Set((targets + scroll).map { $0.element.ref })
        let redundantTextRefs = redundantTextParents.filter { emittedParents.contains($0.value) }.keys.sorted()
        let total = targets.count + scroll.count + text.count
        let start = request.rowOffset
        let end = min(total, start + request.rowLimit)
        func presented(_ row: RuntimeSnapshotRow, requiresSelector: Bool) -> String {
            guard requiresSelector, let index = referenceIndices[row.element.ref], selectedTargets[index] == nil else {
                return row.text
            }
            return RuntimeSnapshotCompactor.row(row.element, action: "unavailable").text
        }
        func page(_ rows: [RuntimeSnapshotRow], base: Int, requiresSelector: Bool) -> [String] {
            guard !unchanged else { return [] }
            return rows.enumerated().filter { start <= base + $0.offset && base + $0.offset < end }
                .map { presented($0.element, requiresSelector: requiresSelector) }
        }
        let remaining = end < total
        let targetPage = page(targets, base: 0, requiresSelector: true)
        let scrollPage = page(scroll, base: targets.count, requiresSelector: true)
        let textPage = page(text, base: targets.count + scroll.count, requiresSelector: false)
        let scrollPreview: AgentModeScrollPreview?
        if start == 0, !unchanged, scrollPage.isEmpty, !scroll.isEmpty {
            var seen: Set<String> = []
            let unique = scroll.filter { seen.insert($0.element.ref).inserted }
            scrollPreview = AgentOutputProjection.scrollPreview(
                rows: unique.prefix(AgentOutputProjection.maximumAreaPreviewRows).map { presented($0, requiresSelector: true) },
                hasMore: unique.count > AgentOutputProjection.maximumAreaPreviewRows)
        } else { scrollPreview = nil }
        var unavailable: [String: String] = [:]
        if nativeIdentityMetadata?.complete != true {
            for row in targetPage + scrollPage {
                let ref = String(row.prefix { $0 != "|" })
                guard let index = referenceIndices[ref], selectedTargets[index] == nil,
                      elements[index].state.visible, elements[index].state.enabled,
                      Self.isOpaqueInputCandidate(nodes[index], element: semanticElements[index]),
                      nodes[index].enabled == true, nodes[index].hidden == false,
                      nodes[index].pid == nativePID,
                      let frame = nodes[index].frame,
                      frame.isUsableAgentFrame,
                      let type = nodes[index].type, !type.isEmpty, type.utf8.count <= 256,
                      type == type.trimmingCharacters(in: .whitespacesAndNewlines), type != "Slider" else { continue }
                if let identity = nodes[index].nativeIdentity {
                    guard identity.pid == nativePID, nativeOccurrences[identity]?.count == 1 else { continue }
                }
                unavailable[ref] = "nativeIdentityIncomplete"
            }
        }
        let publishedRefs = Set((targetPage + scrollPage + textPage).map { String($0.prefix { $0 != "|" }) })
        var customActions: [String: [String]] = [:]
        var truncatedCustomActionRefs: [String] = []
        for element in elements where publishedRefs.contains(element.ref) && !element.customActionNames.isEmpty {
            let preview = AgentModeCustomActions.preview(element.customActionNames)
            customActions[element.ref] = preview.names
            if preview.truncated { truncatedCustomActionRefs.append(element.ref) }
        }
        return AgentModeCapture(type: unchanged ? "runtime-snapshot-unchanged" : "runtime-snapshot", rs: "1",
            snapshotID: id, screenHash: hash, seq: sequence, count: elements.count,
            targets: targetPage, scroll: scrollPage, text: textPage, udid: udid,
            applicationPID: applicationPID, context: context,
            rowOffset: request.rowOffset, rowLimit: request.rowLimit, targetCount: targets.count,
            scrollCount: scroll.count, textCount: text.count, truncated: remaining, expiresInSeconds: expiresIn,
            keyboard: AgentModeKeyboardDetector.observe(keyboardButtons,
                logicalWidth: context.logicalWidth, logicalHeight: context.logicalHeight,
                numericKeyCount: AgentModeKeyboardDetector.numericKeyCount(in: self, expectedPID: applicationPID,
                    logicalSize: CGSize(width: context.logicalWidth, height: context.logicalHeight))),
            totalRows: total, nextRowOffset: remaining ? end : nil,
            redundantTextRefs: redundantTextRefs.isEmpty ? nil : redundantTextRefs,
            unavailableReferences: unavailable.isEmpty ? nil : unavailable,
            customActions: customActions.isEmpty ? nil : customActions,
            truncatedCustomActionRefs: truncatedCustomActionRefs.isEmpty ? nil : truncatedCustomActionRefs,
            scrollPreview: scrollPreview)
    }

    func detail(ref: String, query: AgentModeTextQuery) throws -> AgentModeTextDetail {
        try query.validate()
        guard let index = referenceIndices[ref] else {
            throw AgentModeFailure("referenceMissing", "That ref is not in this snapshot, so nothing was sent. Use a ref from the same capture as the snapshot ID.")
        }
        let node = nodes[index]
        let value: String
        switch query.field {
        case .label: value = node.label ?? ""
        case .value: value = Self.text(node.value) ?? ""
        case .id: value = node.identifier ?? ""
        case .customActions: value = try AgentModeCustomActions.jsonText(node.customActionNames)
        }
        let scalars = value.unicodeScalars
        let total = scalars.count
        guard query.offset <= total else {
            throw AgentModeFailure("invalidTextRange", "The text offset exceeds the field length.")
        }
        let start = scalars.index(scalars.startIndex, offsetBy: query.offset)
        let count = min(query.limit, total - query.offset)
        let end = scalars.index(start, offsetBy: count)
        let next = query.offset + count
        return AgentModeTextDetail(ref: ref, field: query.field, offset: query.offset,
            nextOffset: next < total ? next : nil, totalLength: total,
            text: String(scalars[start..<end]), frame: elements[index].frame,
            actions: elements[index].actions)
    }
}
