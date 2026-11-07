import AXeCore
import CryptoKit
import Foundation
import FBSimulatorControl

/// One bounded native read, with the complete reference table kept inside the broker.
struct AgentModeSnapshot: Sendable {
    static let maximumElements = 4096
    static let maximumDepth = 64
    let nodes: [FBSimulatorAXNode]
    let elements: [RuntimeSnapshotElement]
    let semanticElements: [RuntimeSnapshotElement]
    private let projectionHash: String
    private let opaqueActionCount: Int
    let hash: String
    let nativeFingerprint: String
    /// Admission compares what can affect the agent's action. Hidden nodes, nodes wholly outside
    /// the display and empty inert leaf groups contribute nothing; their descendants are still
    /// inspected. Focus is excluded: typing checks its own field before every key.
    let visibleFingerprint: String
    private let identityIndex: NativeIdentityIndex
    private let referenceIndices: [String: Int]
    let nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata?
    private let selectedTargets: [SelectedNativeTarget?]
    private let nativeOccurrences: [FBSimulatorAXNativeIdentity: [Int]]
    private let aliasTapIndex: FBSimulatorAXNativeObjectIndex?
    private let aliasTapKeys: Set<FBSimulatorAXNativeIdentity>
    private let nativePID: Int32?
    private let keyboardButtons: [AgentModeKeyboardDetector.Button]
    private let redundantTextParents: [String: String]

    init(roots: [FBSimulatorAXNode], nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata? = nil,
         context: SelectedHIDContext) throws {
        guard context.logicalWidth.isFinite, context.logicalHeight.isFinite,
              context.logicalWidth > 0, context.logicalHeight > 0 else {
            throw AgentModeFailure("missingContext", "The selected display has no valid logical viewport.")
        }
        var nodes: [FBSimulatorAXNode] = []
        var inheritedHidden: [Bool] = []
        var keyboardButtons: [AgentModeKeyboardDetector.Button] = []
        var parents: [Int?] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let display = CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight)
        func collect(_ node: FBSimulatorAXNode, depth: Int, parentHidden: Bool, parent: Int?) throws -> (native: String, visible: [String]) {
            guard depth <= Self.maximumDepth, nodes.count < Self.maximumElements else {
                throw AgentModeFailure("hierarchyTooLarge", "The accessibility hierarchy exceeds the agent query bound.")
            }
            let hidden = parentHidden || node.hidden == true
            let index = nodes.count
            nodes.append(node)
            parents.append(parent)
            inheritedHidden.append(hidden)
            if let button = AgentModeKeyboardDetector.Button(node, inheritedHidden: hidden) {
                keyboardButtons.append(button)
            }
            let children = try node.children.map { try collect($0, depth: depth + 1, parentHidden: hidden, parent: index) }
            let native = Self.digest(try encoder.encode(NativeFingerprintNode(node, children: children.map(\.native).sorted())))
            let visibleChildren = children.flatMap(\.visible).sorted()
            guard Self.affectsAdmission(node, hidden: hidden, display: display) else { return (native, visibleChildren) }
            return (native, [Self.digest(try encoder.encode(VisibleFingerprintNode(node, children: visibleChildren)))])
        }
        let rootFingerprints = try roots.map { try collect($0, depth: 0, parentHidden: false, parent: nil) }
        nativeFingerprint = Self.digest(try encoder.encode(rootFingerprints.map(\.native).sorted()))
        visibleFingerprint = Self.digest(try encoder.encode(rootFingerprints.flatMap(\.visible).sorted()))
        self.nodes = nodes
        self.keyboardButtons = keyboardButtons
        let identities = NativeIdentityIndex(nodes: nodes, roots: roots)
        identityIndex = identities
        // Count every occurrence before type, PID, visibility or focus filtering.
        var nativeOccurrences: [FBSimulatorAXNativeIdentity: [Int]] = [:]
        for (index, node) in nodes.enumerated() {
            if let identity = node.nativeIdentity { nativeOccurrences[identity, default: []].append(index) }
        }
        self.nativeOccurrences = nativeOccurrences
        let allIdentitiesPresent = nodes.allSatisfy { node in
            guard let identity = node.nativeIdentity else { return false }
            do { try identity.validate(); return true }
            catch { return false }
        }
        let effectiveMetadata = nativeIdentityMetadata?.complete == true && !allIdentitiesPresent
            ? FBSimulatorAXNativeIdentityMetadata(complete: false, reason: "missingNativeIdentity")
            : nativeIdentityMetadata
        self.nativeIdentityMetadata = effectiveMetadata
        let rootPIDs = Set(roots.compactMap(\.pid).filter { $0 > 0 })
        let nativePID = rootPIDs.count == 1 ? rootPIDs.first : nil
        self.nativePID = nativePID
        let viewport = AgentFrame(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight)
        let baseElements = RuntimeSnapshotBuilder.elements(from: roots.map { Self.runtimeNode($0) }, viewport: viewport)
        // Optional alias evidence cannot remove existing semantic or singleton controls.
        // Keep every occurrence/path. This index grants only the existing tap capability.
        let aliasIndex: FBSimulatorAXNativeObjectIndex?
        if effectiveMetadata?.complete == true, nativeOccurrences.values.contains(where: { $0.count > 1 }) {
            aliasIndex = try? FBSimulatorAXNativeObjectIndex(roots: roots, metadata: effectiveMetadata)
        } else { aliasIndex = nil }
        self.aliasTapIndex = aliasIndex
        var aliasTapKeys = Set<FBSimulatorAXNativeIdentity>()
        if let aliasIndex, let nativePID {
            for (identity, occurrences) in nativeOccurrences where occurrences.count > 1 {
                guard let index = occurrences.first, let type = nodes[index].type, type != "Slider",
                      occurrences.allSatisfy({ baseElements[$0].actions.contains(.tap) }),
                      nodes[index].focused != nil, nodes[index].role?.isEmpty == false,
                      let frame = nodes[index].frame,
                      [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite),
                      frame.size.width > 0, frame.size.height > 0,
                      CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight).contains(frame),
                      (try? aliasIndex.resolve(identity: identity, elementType: type, expectedPID: nativePID)) != nil
                else { continue }
                aliasTapKeys.insert(identity)
            }
        }
        self.aliasTapKeys = aliasTapKeys
        let selectedTargets: [SelectedNativeTarget?] = nodes.enumerated().map { index, node in
            let semantic = identities.selector(for: node, nodes: nodes).map {
                SelectedNativeTarget.semantic(kind: $0.kind, value: $0.value, elementType: node.type)
            }
            let native: SelectedNativeTarget?
            if effectiveMetadata?.complete == true,
               Self.isOpaqueInputCandidate(node, element: baseElements[index]), let identity = node.nativeIdentity,
               identity.pid == nativePID, identity.pid == node.pid,
               node.enabled == true, node.hidden == false,
               let frame = node.frame, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
               frame.width > 0, frame.height > 0,
               (nativeOccurrences[identity]?.count == 1 || aliasTapKeys.contains(identity)),
               let type = node.type, !type.isEmpty, type.utf8.count <= 256,
               type == type.trimmingCharacters(in: .whitespacesAndNewlines), type != "Slider" {
                native = .nativeObject(identity: identity, elementType: type)
            } else { native = nil }
            // Anonymous keyboard fields need native authority even if their label is unique.
            // A present duplicated/malformed ID keeps the existing typing refusal.
            if node.type == "TextField", node.identifier == nil || node.identifier == "", let native {
                return native
            }
            return semantic ?? native
        }
        self.selectedTargets = selectedTargets
        // The shared semantic hash/layout stays independent of optional object metadata.
        semanticElements = baseElements.enumerated().map { index, element in
            let node = nodes[index]
            let hidden = inheritedHidden[index]
            let canType = node.type == "TextField" && node.focused == true && node.enabled == true
                && node.hidden == false && identities.hasUniqueTextFieldID(for: node)
            return RuntimeSnapshotElement(ref: element.ref, role: element.role,
                label: element.label, value: element.value, identifier: element.identifier, frame: element.frame,
                state: RuntimeElementState(enabled: element.state.enabled, visible: element.state.visible && !hidden),
                actions: hidden ? [] : element.actions.filter { canType || $0 != .typeText }, path: element.path,
                activationPointOverride: element.activationPointOverride, swipeFrame: element.swipeFrame,
                customActionNames: element.customActionNames)
        }
        let projected = baseElements.enumerated().map { index, element in
            let node = nodes[index]
            let hidden = inheritedHidden[index]
            let canType = node.type == "TextField" && node.focused == true && node.enabled == true
                && node.hidden == false
                && (identities.hasUniqueTextFieldID(for: node)
                    || (selectedTargets[index]?.nativeIdentity != nil
                        && node.nativeIdentity.map { !aliasTapKeys.contains($0) } == true
                        && (node.identifier == nil || node.identifier == "")))
            let state = RuntimeElementState(enabled: element.state.enabled, visible: element.state.visible && !hidden)
            let aliasTapOnly = selectedTargets[index]?.nativeIdentity.map { aliasTapKeys.contains($0) } == true
            let actions = hidden ? [] : element.actions.filter {
                (!aliasTapOnly || $0 == .tap) && (canType || $0 != .typeText)
            }
            return RuntimeSnapshotElement(ref: element.ref, role: element.role,
                label: element.label, value: element.value, identifier: element.identifier, frame: element.frame,
                state: state, actions: actions, path: element.path,
                activationPointOverride: element.activationPointOverride, swipeFrame: element.swipeFrame,
                customActionNames: element.customActionNames)
        }
        elements = projected
        projectionHash = RuntimeSnapshotBuilder.screenHash(of: projected)
        opaqueActionCount = projected.indices.filter {
            selectedTargets[$0]?.nativeIdentity != nil && !projected[$0].actions.isEmpty
        }.count
        redundantTextParents = Dictionary(uniqueKeysWithValues: projected.indices.compactMap { index -> (String, String)? in
            let child = projected[index]
            guard let parent = parents[index], child.role == .text,
                  child.identifier?.isEmpty != false, child.value?.isEmpty != false,
                  let label = child.label, !label.isEmpty,
                  projected[parent].label == label, !projected[parent].actions.isEmpty else { return nil }
            return (child.ref, projected[parent].ref)
        })
        referenceIndices = Dictionary(uniqueKeysWithValues: projected.enumerated().map { ($0.element.ref, $0.offset) })
        hash = RuntimeSnapshotBuilder.screenHash(of: semanticElements)
    }

    /// Uses the single positive root owner established by this snapshot's one native read.
    /// This does not infer ownership from the selected field or expose mutable PID state.
    func hasNativeOwner(_ expectedPID: Int32) -> Bool {
        expectedPID > 0 && nativePID == expectedPID
    }

    func node(ref: String, requiredAction: RuntimeElementAction) throws -> FBSimulatorAXNode {
        guard let index = referenceIndices[ref],
              elements[index].state.visible, elements[index].state.enabled,
              elements[index].actions.contains(requiredAction) else {
            throw AgentModeFailure("unsupportedReference", "The reference is missing, hidden, disabled, or does not support this action.")
        }
        guard selectedTargets[index] != nil else {
            throw AgentModeFailure("unsupportedIdentity", "The target has no unique native ID or label. Cached coordinates cannot authorize this action.")
        }
        return nodes[index]
    }

    func reference(id: String, action: RuntimeElementAction) throws -> String {
        let type: String? = action == .typeText ? "TextField" : nil
        guard let entry = identityIndex.entry(kind: .id, value: id, type: type), entry.count == 1,
              nodes[entry.index].identifier == id else {
            throw AgentModeFailure("batchTargetMissing", "The batch ID does not identify one exact current native target.")
        }
        let ref = elements[entry.index].ref
        _ = try node(ref: ref, requiredAction: action)
        return ref
    }

    func dragNode(ref: String) throws -> FBSimulatorAXNode {
        let target = try node(ref: ref, requiredAction: .touch)
        let targets = RuntimeSnapshotCompactor.targets(in: elements, limit: Self.maximumElements)
        let scroll = RuntimeSnapshotCompactor.scrollAreas(in: elements, limit: Self.maximumElements)
        guard targets.contains(where: { $0.element.ref == ref }) || scroll.contains(where: { $0.element.ref == ref }) else {
            throw AgentModeFailure("unsupportedDragReference", "Drag requires a target or scroll reference from the agent capture.")
        }
        return target
    }

    func pinchNode(ref: String) throws -> FBSimulatorAXNode {
        guard let index = referenceIndices[ref], isPinchArea(at: index) else {
            throw AgentModeFailure("unsupportedPinchReference", "Pinch requires a visible, enabled area reference with a unique native ID or label.")
        }
        return nodes[index]
    }

    func pinchNode(kind: SelectedAXRequest.SelectorKind, value: String, type: String?) throws -> FBSimulatorAXNode {
        guard let entry = identityIndex.entry(kind: kind, value: value, type: type), entry.count == 1 else {
            throw AgentModeFailure("unsupportedPinchReference", "The native selector no longer identifies one pinch area.")
        }
        return try pinchNode(ref: elements[entry.index].ref)
    }

    private func isPinchArea(at index: Int) -> Bool {
        let node = nodes[index]
        let element = elements[index]
        guard element.role == .other || element.role == .scrollView || element.role == .list,
              element.state.visible, element.state.enabled,
              node.enabled == true, node.hidden == false, selectedTargets[index] != nil,
              selectedTargets[index]?.nativeIdentity == nil,
              let frame = node.frame else { return false }
        return [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }

    func sliderNode(ref: String) throws -> FBSimulatorAXNode {
        guard let index = referenceIndices[ref], isSliderTarget(at: index) else {
            throw AgentModeFailure("unsupportedSliderReference", "A slider endpoint requires a visible, enabled Slider reference with a unique native ID or label.")
        }
        return nodes[index]
    }

    func sliderNode(kind: SelectedAXRequest.SelectorKind, value: String) throws -> FBSimulatorAXNode {
        guard let entry = identityIndex.entry(kind: kind, value: value, type: "Slider"), entry.count == 1 else {
            throw AgentModeFailure("unsupportedSliderReference", "The native slider selector no longer identifies one Slider.")
        }
        return try sliderNode(ref: elements[entry.index].ref)
    }

    private func isSliderTarget(at index: Int) -> Bool {
        let node = nodes[index]
        guard node.type == "Slider", node.enabled == true, node.hidden == false,
              elements[index].state.visible, selectedTargets[index] != nil,
              selectedTargets[index]?.nativeIdentity == nil, let frame = node.frame else { return false }
        return [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }

    private func targetRows() -> [RuntimeSnapshotRow] {
        let targets = RuntimeSnapshotCompactor.targets(in: elements, limit: Self.maximumElements)
        let targetRefs = Set(targets.map { $0.element.ref })
        let sliders = elements.indices.compactMap { index -> RuntimeSnapshotRow? in
            guard isSliderTarget(at: index), !targetRefs.contains(elements[index].ref) else { return nil }
            return RuntimeSnapshotCompactor.row(elements[index], action: "sliderEndpoint")
        }
        // Preserve every existing row/action. Only add areas that lack a target row.
        let existingRefs = Set((targets + sliders).map { $0.element.ref })
        let areas = elements.indices.compactMap { index -> RuntimeSnapshotRow? in
            guard isPinchArea(at: index), !existingRefs.contains(elements[index].ref) else { return nil }
            return RuntimeSnapshotCompactor.row(elements[index], action: "pinchWithin")
        }
        return targets + sliders + areas
    }

    func target(ref: String) throws -> SelectedNativeTarget {
        guard let index = referenceIndices[ref] else {
            throw AgentModeFailure("referenceMissing", "The reference does not belong to this snapshot.")
        }
        guard let target = selectedTargets[index] else {
            let code = nativeIdentityMetadata?.complete == true ? "unsupportedIdentity" : "nativeIdentityIncomplete"
            throw AgentModeFailure(code, "The target has no usable semantic identity or complete unique native-object evidence.")
        }
        try target.validate()
        return target
    }

    /// The reference keeps its semantic meaning. Only this one physical Button
    /// execution gains the same fresh node's native authority, before input starts.
    func physicalButtonExecutionTarget(reference: SelectedNativeTarget, node: FBSimulatorAXNode,
                                       context: SelectedHIDContext) throws -> SelectedNativeTarget {
        let current = try match(target: reference)
        try AgentModeTarget(node, nativeTarget: reference).validate(current)
        guard case let .semantic(kind, value, type) = reference, node.type == "Button" else { return reference }
        // A qualified nested Button chain needs its existing semantic/native-chain proof.
        guard identityIndex.entry(kind: kind, value: value, type: type)?.buttonLeaf != true else { return reference }
        guard let identity = node.nativeIdentity else { return reference }
        try identity.validate()
        guard identity.pid == nativePID, identity.pid == node.pid else {
            throw AgentModeFailure("targetChanged", "The Button native identity has another process owner.")
        }
        guard let occurrences = nativeOccurrences[identity], occurrences.count == 1, let index = occurrences.first else {
            throw AgentModeFailure("targetAmbiguous", "The Button native identity is not unique in the complete tree.")
        }
        guard nativeIdentityMetadata?.complete == true, node.enabled == true, node.hidden == false,
              node.focused != nil, node.role?.isEmpty == false,
              let frame = node.frame,
              [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite),
              frame.size.width > 0, frame.size.height > 0,
              CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight).contains(frame)
        else { return reference }
        _ = try self.node(ref: elements[index].ref, requiredAction: .tap)
        let execution = SelectedNativeTarget.nativeObject(identity: identity, elementType: "Button")
        try AgentModeTarget(node, nativeTarget: execution).validate(try match(target: execution))
        return execution
    }

    func match(target: SelectedNativeTarget) throws -> FBSimulatorAXNode {
        try target.validate()
        switch target {
        case let .semantic(kind, value, type):
            return try match(kind: kind, value: value, type: type)
        case let .nativeObject(identity, type):
            guard nativeIdentityMetadata?.complete == true else {
                throw AgentModeFailure("nativeIdentityIncomplete", "The current native tree cannot prove opaque target uniqueness.")
            }
            guard let matches = nativeOccurrences[identity], let index = matches.first else {
                throw AgentModeFailure("targetMissing", "The exact native object is absent from the complete current tree.")
            }
            if matches.count > 1 {
                guard aliasTapKeys.contains(identity), let aliasTapIndex else {
                    throw AgentModeFailure("targetAmbiguous", "The native aliases have no complete consistent tap evidence.")
                }
                return try aliasTapIndex.resolve(identity: identity, elementType: type, expectedPID: identity.pid).node
            }
            let node = nodes[index]
            guard identity.pid == nativePID, node.pid == identity.pid, node.type == type,
                  node.nativeIdentity == identity else {
                throw AgentModeFailure("targetChanged", "The native object process or exact type changed.")
            }
            return node
        }
    }

    /// Resolve the current ordinal only after the chosen identity matched this complete tree.
    func reference(target: SelectedNativeTarget) throws -> String {
        let node = try match(target: target)
        let index: Int
        switch target {
        case let .nativeObject(identity, type):
            if let unique = nativeOccurrences[identity], unique.count == 1, let current = unique.first {
                index = current
            } else if aliasTapKeys.contains(identity), let aliasTapIndex {
                index = try aliasTapIndex.resolve(identity: identity, elementType: type,
                    expectedPID: identity.pid).canonicalIndex
            } else {
                throw AgentModeFailure("targetAmbiguous", "The current native object has no consistent tap evidence.")
            }
        case let .semantic(kind, value, type):
            guard let entry = identityIndex.entry(kind: kind, value: value, type: type), entry.count == 1 else {
                throw AgentModeFailure("targetMissing", "The current semantic target is not unique.")
            }
            index = entry.index
        }
        guard nodes[index].type == node.type else {
            throw AgentModeFailure("targetChanged", "The current target alignment changed.")
        }
        return elements[index].ref
    }

    func validateProtectedReference(_ ref: String, in fresh: AgentModeSnapshot) throws {
        guard let index = referenceIndices[ref] else {
            throw AgentModeFailure("referenceMissing", "The reference does not belong to this snapshot.")
        }
        guard let chosen = selectedTargets[index], chosen.nativeIdentity != nil else { return }
        let node = try fresh.match(target: chosen)
        try AgentModeTarget(nodes[index], nativeTarget: chosen).validate(node)
    }

    func validateProtectedTargets(in fresh: AgentModeSnapshot) throws {
        for index in selectedTargets.indices where selectedTargets[index]?.nativeIdentity != nil
            && !elements[index].actions.isEmpty {
            try validateProtectedReference(elements[index].ref, in: fresh)
        }
    }

    func protectedTargetsMatch(_ fresh: AgentModeSnapshot) -> Bool {
        guard projectionHash == fresh.projectionHash, opaqueActionCount == fresh.opaqueActionCount else { return false }
        do { try validateProtectedTargets(in: fresh); return true }
        catch { return false }
    }

    func resolve(_ original: FBSimulatorAXNode) throws -> FBSimulatorAXNode {
        let selector = try uniqueSelector(for: original)
        return try match(kind: selector.kind, value: selector.value, type: original.type)
    }

    func match(kind: SelectedAXRequest.SelectorKind, value: String, type: String?) throws -> FBSimulatorAXNode {
        let entry = identityIndex.entry(kind: kind, value: value, type: type)
        guard let entry, entry.count == 1 else {
            throw AgentModeFailure(entry == nil ? "targetMissing" : "targetAmbiguous",
                                   "The exact native selector did not identify one target. Refresh the snapshot or use a unique ID.")
        }
        return nodes[entry.index]
    }

    func match(_ selector: AgentModeTapSelector, type: String?, context: SelectedHIDContext) throws -> FBSimulatorAXNode {
        let rectangle = try selector.frame?.rectangle(in: context)
        var matcher = try AgentModeTapMatcher(selector: selector)
        var matched: FBSimulatorAXNode?
        for (index, node) in nodes.enumerated() {
            try matcher.checkBudget()
            switch selector.kind {
            case .value: break
            default: if identityIndex.isButtonChainAncestor(at: index) { continue }
            }
            if let type, node.type != type { continue }
            if let rectangle {
                guard let frame = node.frame,
                      frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                      frame.width > 0, frame.height > 0, rectangle.contains(frame) else { continue }
            }
            let raw: String?
            switch selector.kind {
            case .id: raw = node.identifier
            case .label, .labelContains, .labelRegex: raw = node.label
            case .value: raw = Self.text(node.value)
            }
            guard let raw, try matcher.matches(raw) else { continue }
            guard matched == nil else {
                throw AgentModeFailure("targetAmbiguous", "The agent selector matches more than one native target. Narrow the type or frame filter.")
            }
            matched = node
        }
        try matcher.checkBudget()
        guard let matched else {
            throw AgentModeFailure("targetMissing", "The agent selector matches no native target. Refresh the UI or change the query.")
        }
        // A frame/pattern never becomes coordinate authority. Native input still needs a unique selector.
        _ = try uniqueSelector(for: matched)
        return matched
    }

    func uniqueSelector(for node: FBSimulatorAXNode) throws -> (kind: SelectedAXRequest.SelectorKind, value: String) {
        guard let selector = identityIndex.selector(for: node, nodes: nodes) else {
            throw AgentModeFailure("unsupportedIdentity", "The target has no unique native ID or label. Cached coordinates cannot authorize this action.")
        }
        return (selector.kind, selector.value)
    }

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
                      [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                      frame.width > 0, frame.height > 0,
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
            throw AgentModeFailure("referenceMissing", "The reference does not belong to this snapshot.")
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

    /// Identity adds authority to an existing input capability, never scroll inference to a Group.
    private static func isOpaqueInputCandidate(_ node: FBSimulatorAXNode, element: RuntimeSnapshotElement) -> Bool {
        if element.actions.contains(.tap) || element.actions.contains(.typeText) { return true }
        guard element.actions.contains(.swipeWithin) else { return false }
        let role = [node.type, node.role, node.subrole, node.roleDescription]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        return ["scroll", "list", "table", "outline", "collection"].contains { role.contains($0) }
    }

    static func hasPotentialTapAction(_ node: FBSimulatorAXNode) -> Bool {
        RuntimeSnapshotBuilder.hasPotentialTapAction(runtimeNode(node, includingChildren: false))
    }

    static func hasPotentialScrollContainerAction(_ node: FBSimulatorAXNode) -> Bool {
        RuntimeSnapshotBuilder.hasPotentialScrollContainerAction(runtimeNode(node, includingChildren: false))
    }

    private static func runtimeNode(_ node: FBSimulatorAXNode, includingChildren: Bool = true) -> RuntimeSnapshotNode {
        RuntimeSnapshotNode(type: node.type, role: node.role, subrole: node.subrole,
            roleDescription: node.roleDescription, label: node.label, value: text(node.value),
            identifier: node.identifier, frame: node.frame.map {
                AgentFrame(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
            }, enabled: node.enabled != false && node.hidden != true,
            customActionNames: node.customActionNames,
            children: includingChildren ? node.children.map { runtimeNode($0) } : [])
    }

    private static func text(_ value: FBSimulatorAXValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text): return text
        case .number(let number): return String(number)
        case .boolean(let boolean): return String(boolean)
        case .null, .array, .object: return nil
        }
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Each node encodes only its own exact fields and fixed-size child digests.
    /// Sorting child digests preserves sibling reorder while retaining ancestry.
    private struct NativeFingerprintNode: Encodable {
        let type: String?
        let role: String?
        let subrole: String?
        let roleDescription: String?
        let identifier: String?
        let label: String?
        let value: FBSimulatorAXValue?
        let customActionNames: [String]
        let frame: AgentFrame?
        let pid: Int32?
        let focused: Bool?
        let enabled: Bool?
        let hidden: Bool?
        let children: [String]

        init(_ node: FBSimulatorAXNode, children: [String]) {
            type = node.type; role = node.role; subrole = node.subrole; roleDescription = node.roleDescription
            identifier = node.identifier; label = node.label; value = node.value; pid = node.pid
            focused = node.focused; enabled = node.enabled; hidden = node.hidden
            customActionNames = node.customActionNames
            frame = node.frame.map { AgentFrame(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height) }
            self.children = children
        }
    }

    /// Missing or invalid geometry is kept: it does not prove that a node is off-screen.
    static func affectsAdmission(_ node: FBSimulatorAXNode, hidden: Bool, display: CGRect) -> Bool {
        if hidden { return false }
        if let frame = node.frame, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
           frame.width > 0, frame.height > 0, !frame.intersects(display) { return false }
        let empty: (String?) -> Bool = { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
        let inertGroup = node.type == "Group" && node.children.isEmpty && node.customActionNames.isEmpty
            && node.focused != true && empty(node.identifier) && empty(node.label) && empty(text(node.value))
        return !inertGroup
    }

    private struct VisibleFingerprintNode: Encodable {
        let type: String?
        let role: String?
        let subrole: String?
        let roleDescription: String?
        let identifier: String?
        let label: String?
        let value: FBSimulatorAXValue?
        let customActionNames: [String]
        let frame: AgentFrame?
        let pid: Int32?
        let enabled: Bool?
        let children: [String]

        init(_ node: FBSimulatorAXNode, children: [String]) {
            type = node.type; role = node.role; subrole = node.subrole; roleDescription = node.roleDescription
            identifier = node.identifier; label = node.label; value = node.value; pid = node.pid
            enabled = node.enabled; customActionNames = node.customActionNames
            frame = node.frame.map { AgentFrame(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height) }
            self.children = children
        }
    }

    private struct NativeSelector: Sendable {
        let kind: SelectedAXRequest.SelectorKind
        let value: String
    }

    /// Native selector matching trims only its ends. It does not use the RS/1 text projection.
    private struct NativeIdentityIndex: Sendable {
        struct Entry: Sendable {
            var count: Int
            let index: Int
            var buttonLeaf = false
        }
        private struct Key: Hashable, Sendable {
            let kind: String
            let value: String
            let type: String?
        }
        private var entries: [Key: Entry] = [:]
        private var buttonChainAncestors: Set<Int> = []

        init(nodes: [FBSimulatorAXNode], roots: [FBSimulatorAXNode]) {
            for (index, node) in nodes.enumerated() {
                for (kind, raw) in [(SelectedAXRequest.SelectorKind.id, node.identifier), (.label, node.label), (.value, AgentModeSnapshot.text(node.value))] {
                    guard let raw else { continue }
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    let types: [String?] = node.type.map { [nil, $0] } ?? [nil]
                    for type in types {
                        let key = Key(kind: kind.rawValue, value: value, type: type)
                        if var entry = entries[key] { entry.count += 1; entries[key] = entry }
                        else { entries[key] = Entry(count: 1, index: index) }
                    }
                }
            }
            let duplicateEntries = entries.filter { $0.value.count > 1 }
            for (key, entry) in duplicateEntries {
                guard key.type == nil || key.type == "Button" else { continue }
                let selector: FBSimulatorAXSelector
                if key.kind == SelectedAXRequest.SelectorKind.id.rawValue {
                    selector = key.type == nil ? .identifier(key.value) : .identifierWithType(key.value, elementType: "Button")
                } else if key.kind == SelectedAXRequest.SelectorKind.label.rawValue {
                    selector = key.type == nil ? .label(key.value) : .labelWithType(key.value, elementType: "Button")
                } else { continue }
                guard let leaf = FBSimulatorAXButtonLeafSelection.resolve(in: roots, selector: selector),
                      leaf.matchingIndices.count == entry.count else { continue }
                entries[key] = Entry(count: 1, index: leaf.index, buttonLeaf: true)
                buttonChainAncestors.formUnion(leaf.matchingIndices.dropLast())
            }
        }

        func isButtonChainAncestor(at index: Int) -> Bool { buttonChainAncestors.contains(index) }

        func entry(kind: SelectedAXRequest.SelectorKind, value: String, type: String?) -> Entry? {
            entries[Key(kind: kind.rawValue, value: value.trimmingCharacters(in: .whitespacesAndNewlines), type: type)]
        }

        func selector(for node: FBSimulatorAXNode, nodes: [FBSimulatorAXNode]) -> NativeSelector? {
            guard let frame = node.frame else { return nil }
            for (kind, raw) in [(SelectedAXRequest.SelectorKind.id, node.identifier), (.label, node.label)] {
                guard let raw else { continue }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.utf8.count <= 4096,
                      let entry = entry(kind: kind, value: value, type: node.type), entry.count == 1,
                      nodes[entry.index].frame == frame,
                      !entry.buttonLeaf || node.children.isEmpty else { continue }
                return NativeSelector(kind: kind, value: value)
            }
            return nil
        }

        func hasUniqueTextFieldID(for node: FBSimulatorAXNode) -> Bool {
            guard node.type == "TextField", let identifier = node.identifier,
                  !identifier.isEmpty, identifier.utf8.count <= 4096,
                  identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                  let entry = entry(kind: .id, value: identifier, type: "TextField") else { return false }
            return entry.count == 1
        }
    }
}
