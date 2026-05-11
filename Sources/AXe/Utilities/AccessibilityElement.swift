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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        type = try Self.decodeOptionalScalarString(from: container, forKey: .type)
        frame = try container.decodeIfPresent(Frame.self, forKey: .frame)
        children = try container.decodeIfPresent([AccessibilityElement].self, forKey: .children)
        role = try Self.decodeOptionalScalarString(from: container, forKey: .role)
        roleDescription = try Self.decodeOptionalScalarString(from: container, forKey: .roleDescription)
        subrole = try Self.decodeOptionalScalarString(from: container, forKey: .subrole)
        AXLabel = try Self.decodeOptionalScalarString(from: container, forKey: .AXLabel)
        AXUniqueId = try Self.decodeOptionalScalarString(from: container, forKey: .AXUniqueId)
        AXIdentifier = try Self.decodeOptionalScalarString(from: container, forKey: .AXIdentifier)
        AXValue = try Self.decodeOptionalScalarString(from: container, forKey: .AXValue)
    }

    private static func decodeOptionalScalarString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        if !container.contains(key) {
            return nil
        }
        if try container.decodeNil(forKey: key) {
            return nil
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Bool.self, forKey: key) {
            return String(value)
        }
        return nil
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
