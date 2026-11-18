import AXeCore
import Foundation
import FBSimulatorControl

/// The controls of hosted web pages (WKWebView, Safari, SFSafariViewController and
/// ASWebAuthenticationSession) in one agent snapshot, published as `w` refs after the app's own
/// rows. Only controls a tap would reach now are listed: the page text is left to screenshots.
struct AgentWebControls: Sendable {
    static let referencePrefix: Character = "w"
    let nodes: [FBSimulatorAXNode]
    let elements: [RuntimeSnapshotElement]
    /// Why the web read returned no list, such as `unsupportedRotation`.
    let failure: String?
    /// Keys found where a keyboard sits, in any process but a page's.
    let keyboardKeyCount: Int
    /// The top of the highest of those keys.
    let keyboardTop: CGFloat?
    /// Order-sensitive digest of what the rows show, for snapshot reuse.
    let digest: String

    init(nodes: [FBSimulatorAXNode], failure: String? = nil, keyboard: [FBSimulatorAXNode] = []) {
        self.nodes = nodes
        self.failure = failure
        // A page can draw letter buttons of its own (a word game); its process is not a keyboard.
        let pagePIDs = Set(nodes.filter { $0.discoveryMethod == FBAXWebControlPolicy.pageDiscovery }.map(\.pid))
        let keys = keyboard.filter { Self.isKeyboardKey($0) && !pagePIDs.contains($0.pid) }
        keyboardKeyCount = keys.count
        keyboardTop = keys.compactMap { $0.frame?.minY }.min()
        elements = nodes.enumerated().map { index, node in Self.element(node, ref: "w\(index + 1)") }
        digest = elements.map { row in
            [row.ref, row.role?.rawValue ?? "", row.label ?? "", row.value ?? "",
             "\(row.frame.x),\(row.frame.y),\(row.frame.width),\(row.frame.height)",
             row.actions.map(\.rawValue).joined(separator: ",")].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}") + "|" + (failure ?? "") + "|\(keyboardKeyCount)"
    }

    /// Two keys where a keyboard sits: one drawn by any process, the app's own included.
    var keyboardVisible: Bool { keyboardKeyCount >= 2 }

    private static let keyboardChromeLabels: Set<String> = [
        "shift", "delete", "return", "space", "numbers", "more", "Emoji", "Dictation", "Next Keyboard",
    ]

    static func isKeyboardKey(_ node: FBSimulatorAXNode) -> Bool {
        guard node.type == "Button", let label = node.label?.trimmingCharacters(in: .whitespaces) else { return false }
        return keyboardChromeLabels.contains(label) || (label.count == 1 && label.first?.isLetter == true)
    }

    /// Points on the letter rows of a portrait keyboard: three rows above the bottom row.
    static func keyboardProbePoints(_ size: CGSize) -> [CGPoint] {
        guard size.width > 0, size.height > 300 else { return [] }
        return [size.height - 250, size.height - 195, size.height - 140].flatMap { y in
            [0.2, 0.5, 0.8].map { CGPoint(x: size.width * $0, y: y) }
        }
    }

    static func isReference(_ ref: String) -> Bool { ref.first == referencePrefix }

    /// A node from a web read: a page control, or a Safari sheet's own control.
    static func isWebDiscovery(_ node: FBSimulatorAXNode) -> Bool {
        node.discoveryMethod == FBAXWebControlPolicy.pageDiscovery || node.discoveryMethod == FBAXWebControlPolicy.chromeDiscovery
    }

    static func isControl(_ node: FBSimulatorAXNode) -> Bool {
        node.role.map { FBAXWebControlPolicy.controlRoles.contains($0) } == true
    }

    static func role(_ node: FBSimulatorAXNode) -> RuntimeElementRole {
        switch node.role {
        case "AXLink": return .link
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox": return .textField
        case "AXCheckBox", "AXSwitch": return .switch
        case "AXSlider", "AXIncrementor": return .slider
        default:
            return node.subrole == "AXTabButton" ? .tab : .button
        }
    }

    /// WebKit names an ARIA option twice ("Ada, Ada"); the row shows it once.
    static func label(_ node: FBSimulatorAXNode) -> String? {
        guard let label = node.label, node.role == FBAXWebControlPolicy.textRole else { return node.label }
        let parts = label.components(separatedBy: ", ")
        guard parts.count.isMultiple(of: 2), parts.count >= 2 else { return label }
        let half = parts.count / 2
        return Array(parts[..<half]) == Array(parts[half...]) ? parts[..<half].joined(separator: ", ") : label
    }

    private static func element(_ node: FBSimulatorAXNode, ref: String) -> RuntimeSnapshotElement {
        let frame = node.frame ?? .zero
        let role = role(node)
        let enabled = node.enabled != false && node.hidden != true
        var actions: [RuntimeElementAction] = enabled ? [.tap] : []
        if enabled, role == .textField { actions.append(.typeText) }
        return RuntimeSnapshotElement(ref: ref, role: role, label: label(node),
            value: AgentModeSnapshot.text(node.value), identifier: nil,
            frame: AgentFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            state: RuntimeElementState(enabled: enabled, visible: true), actions: actions)
    }

    /// Target rows: typing rows say `typeText`, the rest `tap`.
    func rows() -> [RuntimeSnapshotRow] {
        elements.filter { !$0.actions.isEmpty }.map {
            RuntimeSnapshotCompactor.row($0, action: $0.actions.contains(.typeText) ? "typeText" : "tap")
        }
    }

    func node(ref: String, requiredAction: RuntimeElementAction) throws -> FBSimulatorAXNode {
        guard let index = elements.firstIndex(where: { $0.ref == ref }) else {
            throw AgentModeFailure("referenceMissing", "That ref is not in this snapshot, so nothing was sent. Use a ref from the same capture as the snapshot ID.")
        }
        guard elements[index].actions.contains(requiredAction) else {
            throw AgentModeFailure("unsupportedReference", "That web control does not offer this action; use only the actions listed in its row. Nothing was sent. Choose a ref from your latest capture.")
        }
        return nodes[index]
    }

    /// The chosen control on a newer read: the same native element, or failing that the one
    /// control of the same page with the same role and label (a page can rebuild an element).
    /// The label must also have named only that control in `original`, the read it was chosen
    /// from, so one of several "Delete" buttons is never swapped for another.
    func match(_ chosen: FBSimulatorAXNode, original: AgentWebControls? = nil) -> (node: FBSimulatorAXNode, ref: String)? {
        if let identity = chosen.nativeIdentity,
           let index = nodes.firstIndex(where: { $0.nativeIdentity == identity }),
           nodes[index].role == chosen.role, nodes[index].label == chosen.label {
            return (nodes[index], elements[index].ref)
        }
        guard let label = chosen.label, !label.isEmpty,
              original.map({ $0.sameLabel(as: chosen).count == 1 }) != false else { return nil }
        let same = sameLabel(as: chosen)
        guard same.count == 1, let index = same.first else { return nil }
        return (nodes[index], elements[index].ref)
    }

    private func sameLabel(as chosen: FBSimulatorAXNode) -> [Int] {
        nodes.indices.filter {
            nodes[$0].pid == chosen.pid && nodes[$0].role == chosen.role && nodes[$0].label == chosen.label
        }
    }

    /// Where a web control is tapped: the centre of its part on the display. The web read
    /// proved this point reaches the control.
    static func tapPoint(_ node: FBSimulatorAXNode, context: SelectedHIDContext) -> SelectedAXPoint? {
        guard let frame = node.frame,
              let point = FBAXWebControlPolicy.tapPoint(frame: frame,
                screen: CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight)) else { return nil }
        return SelectedAXPoint(x: point.x, y: point.y)
    }

    /// Where a web field is tapped to type: near the right end of its visible part, so the caret
    /// lands after any text already there instead of in the middle of it, but left of any other
    /// control drawn over the field there (a search field's Clear button).
    static func typingPoint(_ node: FBSimulatorAXNode, context: SelectedHIDContext,
                            others: [FBSimulatorAXNode] = []) -> SelectedAXPoint? {
        guard let centre = tapPoint(node, context: context), let frame = node.frame else { return nil }
        let visible = frame.intersection(CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight))
        let inset = min(8, visible.width / 4)
        let covers = others.compactMap { other -> CGRect? in
            guard other.nativeIdentity != node.nativeIdentity, let rect = other.frame,
                  rect.minY <= centre.y, centre.y <= rect.maxY, rect.intersects(visible) else { return nil }
            return rect
        }
        var x = visible.maxX - inset
        // Step left past covering controls, never past the field's centre.
        while let cover = covers.first(where: { $0.minX <= x && x <= $0.maxX }), cover.minX - inset > centre.x {
            x = cover.minX - inset
        }
        if covers.contains(where: { $0.minX <= x && x <= $0.maxX }) { x = centre.x }
        return SelectedAXPoint(x: x, y: centre.y)
    }

    /// A field whose value is not shown as typed (a password field).
    static func hidesValue(_ node: FBSimulatorAXNode) -> Bool {
        node.subrole == "AXSecureTextField" || node.roleDescription == "secure text field"
    }
}
