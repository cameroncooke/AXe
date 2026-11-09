import AXeCore
import CryptoKit
import Foundation
import FBSimulatorControl

extension AgentModeSnapshot {
    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Each node encodes only its own exact fields and fixed-size child digests.
    /// Sorting child digests preserves sibling reorder while retaining ancestry.
    struct NativeFingerprintNode: Encodable {
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
        if let frame = node.frame, frame.isUsableAgentFrame, !frame.intersects(display) { return false }
        let empty: (String?) -> Bool = { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
        let inertGroup = node.type == "Group" && node.children.isEmpty && node.customActionNames.isEmpty
            && node.focused != true && empty(node.identifier) && empty(node.label) && empty(text(node.value))
        return !inertGroup
    }

    struct VisibleFingerprintNode: Encodable {
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

        /// Ordinary text keeps its place, type and identity but not its text or glyph bounds, so a
        /// ticking clock or progress label does not refuse every action on its screen. Controls, text
        /// inside controls, and every frame that can place a touch stay bound.
        init(_ node: FBSimulatorAXNode, ordinaryText: Bool, children: [String]) {
            type = node.type; role = node.role; subrole = node.subrole; roleDescription = node.roleDescription
            identifier = node.identifier; pid = node.pid
            label = ordinaryText ? nil : node.label
            value = ordinaryText ? nil : node.value
            enabled = node.enabled; customActionNames = node.customActionNames
            frame = ordinaryText ? nil : node.frame.map {
                AgentFrame(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
            }
            self.children = children
        }
    }
}
