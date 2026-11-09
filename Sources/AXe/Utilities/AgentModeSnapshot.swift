import AXeCore
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
    let referenceIndices: [String: Int]
    let nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata?
    let selectedTargets: [SelectedNativeTarget?]
    let nativeOccurrences: [FBSimulatorAXNativeIdentity: [Int]]
    private let aliasTapIndex: FBSimulatorAXNativeObjectIndex?
    private let aliasTapKeys: Set<FBSimulatorAXNativeIdentity>
    let nativePID: Int32?
    let keyboardButtons: [AgentModeKeyboardDetector.Button]
    let redundantTextParents: [String: String]

    init(roots: [FBSimulatorAXNode], nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata? = nil,
         context: SelectedHIDContext) throws {
        guard context.logicalWidth.isFinite, context.logicalHeight.isFinite,
              context.logicalWidth > 0, context.logicalHeight > 0 else {
            throw AgentModeFailure.missingContext
        }
        var nodes: [FBSimulatorAXNode] = []
        var inheritedHidden: [Bool] = []
        var keyboardButtons: [AgentModeKeyboardDetector.Button] = []
        var parents: [Int?] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let display = CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight)
        func collect(_ node: FBSimulatorAXNode, depth: Int, parentHidden: Bool, parent: Int?) throws -> String {
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
            return Self.digest(try encoder.encode(NativeFingerprintNode(node, children: children.sorted())))
        }
        let rootFingerprints = try roots.map { try collect($0, depth: 0, parentHidden: false, parent: nil) }
        nativeFingerprint = Self.digest(try encoder.encode(rootFingerprints.sorted()))
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
        // The second pre-order walk sees each node's actions, so ordinary text (a leaf StaticText
        // outside any control, as a reference batch's layout defines it) can be told apart.
        var visibleIndex = 0
        func visible(_ node: FBSimulatorAXNode, controlAncestor: Bool) throws -> [String] {
            let index = visibleIndex
            visibleIndex += 1
            let actions = baseElements[index].actions
            let control = actions.contains(.tap) || actions.contains(.typeText)
            let children = try node.children.flatMap {
                try visible($0, controlAncestor: controlAncestor || control)
            }.sorted()
            guard Self.affectsAdmission(node, hidden: inheritedHidden[index], display: display) else { return children }
            let ordinaryText = !controlAncestor && node.type == "StaticText" && node.children.isEmpty
                && !actions.contains { $0 == .tap || $0 == .typeText || $0 == .swipeWithin }
            return [Self.digest(try encoder.encode(VisibleFingerprintNode(node, ordinaryText: ordinaryText,
                children: children)))]
        }
        visibleFingerprint = Self.digest(try encoder.encode(
            try roots.flatMap { try visible($0, controlAncestor: false) }.sorted()))
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
                      frame.isUsableAgentFrame,
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
               let frame = node.frame, frame.isUsableAgentFrame,
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
            throw AgentModeFailure("unsupportedReference", "That ref is not on the current screen, is hidden or disabled, or does not offer this action; use only the actions listed in its row. Nothing was sent. Choose a ref from your latest capture.")
        }
        guard selectedTargets[index] != nil else {
            throw AgentModeFailure("unsupportedIdentity", "AXe cannot identify this control uniquely (it has no unique ID or label), so nothing was sent. Use its ref from a current capture, or tap it by position with -x and -y.")
        }
        return nodes[index]
    }

    func reference(id: String, action: RuntimeElementAction) throws -> String {
        let type: String? = action == .typeText ? "TextField" : nil
        let entry = identityIndex.entry(kind: .id, value: id, type: type)
        guard let entry, entry.count == 1, nodes[entry.index].identifier == id else {
            let ambiguous = (entry?.count ?? 0) > 1
            throw AgentModeFailure(ambiguous ? "targetAmbiguous" : "targetMissing", ambiguous
                ? "More than one current control has this exact ID, so nothing was sent. Use a ref from a current capture."
                : "No current control has this exact ID, so nothing was sent. Check the ID in a current capture.")
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
        return frame.isUsableAgentFrame
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
        return frame.isUsableAgentFrame
    }

    func targetRows() -> [RuntimeSnapshotRow] {
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
            throw AgentModeFailure("referenceMissing", "That ref is not in this snapshot, so nothing was sent. Use a ref from the same capture as the snapshot ID.")
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
            throw AgentModeFailure("targetChanged", "That control now belongs to another app, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        guard let occurrences = nativeOccurrences[identity], occurrences.count == 1, let index = occurrences.first else {
            throw AgentModeFailure("targetAmbiguous", "AXe could not tell this control apart from another one on screen, so nothing was sent. Use its ref from the capture in this reply; if that is refused too, tap it by position.")
        }
        guard nativeIdentityMetadata?.complete == true, node.enabled == true, node.hidden == false,
              node.focused != nil, node.role?.isEmpty == false,
              let frame = node.frame,
              frame.isUsableAgentFrame,
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
                    throw AgentModeFailure("targetAmbiguous", "AXe could not tell this control apart from another one on screen, so nothing was sent. Use its ref from the capture in this reply; if that is refused too, tap it by position.")
                }
                return try aliasTapIndex.resolve(identity: identity, elementType: type, expectedPID: identity.pid).node
            }
            let node = nodes[index]
            guard identity.pid == nativePID, node.pid == identity.pid, node.type == type,
                  node.nativeIdentity == identity else {
                throw AgentModeFailure("targetChanged", "Your target changed type or app after this snapshot was taken, so nothing was sent. \(AgentModeFailure.actFromCapture)")
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
                throw AgentModeFailure("targetAmbiguous", "AXe could not tell this control apart from another one on screen, so nothing was sent. Use its ref from the capture in this reply; if that is refused too, tap it by position.")
            }
        case let .semantic(kind, value, type):
            guard let entry = identityIndex.entry(kind: kind, value: value, type: type), entry.count == 1 else {
                throw AgentModeFailure("targetMissing", "The current semantic target is not unique.")
            }
            index = entry.index
        }
        guard nodes[index].type == node.type else {
            throw AgentModeFailure("targetChanged", "Your target changed or moved after this snapshot was taken, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        return elements[index].ref
    }

    func validateProtectedReference(_ ref: String, in fresh: AgentModeSnapshot) throws {
        guard let index = referenceIndices[ref] else {
            throw AgentModeFailure("referenceMissing", "That ref is not in this snapshot, so nothing was sent. Use a ref from the same capture as the snapshot ID.")
        }
        guard let chosen = selectedTargets[index], chosen.nativeIdentity != nil else { return }
        let node = try fresh.match(target: chosen)
        try AgentModeTarget(nodes[index], nativeTarget: chosen).validate(node)
    }

    /// The readable fields of one ref are the same on both tables.
    func hasSameFields(_ ref: String, in fresh: AgentModeSnapshot) -> Bool {
        guard let index = referenceIndices[ref], let current = fresh.referenceIndices[ref] else { return false }
        let old = nodes[index], new = fresh.nodes[current]
        return old.type == new.type && old.label == new.label && old.value == new.value
            && old.identifier == new.identifier && old.customActionNames == new.customActionNames
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

    func match(kind: SelectedAXRequest.SelectorKind, value: String, type: String?) throws -> FBSimulatorAXNode {
        let entry = identityIndex.entry(kind: kind, value: value, type: type)
        guard let entry, entry.count == 1 else {
            throw AgentModeFailure(entry == nil ? "targetMissing" : "targetAmbiguous",
                                   "No control, or more than one, matches this selector, so nothing was sent. Narrow it (an exact --id, --label with --element-type, or --frame), or tap by ref from a current capture.")
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
                throw AgentModeFailure("targetAmbiguous", "The selector matches more than one control, so nothing was sent. Narrow it with --element-type or --frame, or use a ref from the capture in this reply.")
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
            throw AgentModeFailure("unsupportedIdentity", "AXe cannot identify this control uniquely (it has no unique ID or label), so nothing was sent. Use its ref from a current capture, or tap it by position with -x and -y.")
        }
        return (selector.kind, selector.value)
    }

    /// Identity adds authority to an existing input capability, never scroll inference to a Group.
    static func isOpaqueInputCandidate(_ node: FBSimulatorAXNode, element: RuntimeSnapshotElement) -> Bool {
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

    static func text(_ value: FBSimulatorAXValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text): return text
        case .number(let number): return String(number)
        case .boolean(let boolean): return String(boolean)
        case .null, .array, .object: return nil
        }
    }

}
