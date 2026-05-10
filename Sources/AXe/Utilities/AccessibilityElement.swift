import Foundation

struct AccessibilityElement: Decodable {
    private static let actionableTypes: Set<String> = [
        "Button",
        "Cell",
        "CheckBox",
        "Link",
        "MenuItem",
        "PopUpButton",
        "RadioButton",
        "SecureTextField",
        "SegmentedControl",
        "Switch",
        "Tab",
        "TabBarButton",
        "TextField",
        "Toggle"
    ]

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let type: String?
    let frame: Frame?
    let children: [AccessibilityElement]?
    let role: String?
    let roleDescription: String?
    let subrole: String?

    let AXLabel: String?
    let AXUniqueId: String?
    let AXIdentifier: String?
    let AXValue: String?

    enum CodingKeys: String, CodingKey {
        case type
        case frame
        case children
        case role
        case roleDescription = "role_description"
        case subrole
        case AXLabel
        case AXUniqueId
        case AXIdentifier
        case AXValue
    }

    var normalizedLabel: String? {
        trimmed(AXLabel)
    }

    var normalizedUniqueId: String? {
        normalizedStableUniqueId ?? trimmed(AXIdentifier)
    }

    var normalizedStableUniqueId: String? {
        trimmed(AXUniqueId)
    }

    var normalizedValue: String? {
        trimmed(AXValue)
    }

    var isActionable: Bool {
        isSwitchLikeControl || type.map(Self.actionableTypes.contains) == true
    }

    var isSwitchLikeControl: Bool {
        if type == "Switch" || type == "Toggle" {
            return true
        }
        if role == "AXSwitch" || subrole == "AXSwitch" {
            return true
        }
        if let roleDescription = trimmed(roleDescription)?.lowercased(),
           roleDescription.contains("switch") || roleDescription.contains("toggle") {
            return true
        }
        return false
    }

    func flattened() -> [AccessibilityElement] {
        var result: [AccessibilityElement] = [self]
        if let children {
            result.append(contentsOf: children.flatMap { $0.flattened() })
        }
        return result
    }

    func switchLikeDescendantsIncludingSelf() -> [AccessibilityElement] {
        flattened().filter(\.isSwitchLikeControl)
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
