import Foundation

struct UIElement: Decodable {
    let type: String
    let frame: Frame?
    let children: [UIElement]?
    let role: String?
    let enabled: Bool?
    let title: String?
    let subrole: String?
    let contentRequired: Bool?
    let roleDescription: String?
    let helpText: String?
    let AXFrame: String?
    let customActions: [String]?
    let AXLabel: String?
    let AXValue: String?
    let AXUniqueId: String?
    let AXIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case type
        case frame
        case children
        case role
        case enabled
        case title
        case subrole
        case contentRequired = "content_required"
        case roleDescription = "role_description"
        case helpText = "help"
        case AXFrame
        case customActions = "custom_actions"
        case AXLabel
        case AXValue
        case AXUniqueId
        case AXIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        type = try container.decode(String.self, forKey: .type)
        frame = try container.decodeIfPresent(Frame.self, forKey: .frame)
        children = try container.decodeIfPresent([UIElement].self, forKey: .children)
        role = try Self.decodeOptionalScalarString(from: container, forKey: .role)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        title = try Self.decodeOptionalScalarString(from: container, forKey: .title)
        subrole = try Self.decodeOptionalScalarString(from: container, forKey: .subrole)
        contentRequired = try container.decodeIfPresent(Bool.self, forKey: .contentRequired)
        roleDescription = try Self.decodeOptionalScalarString(from: container, forKey: .roleDescription)
        helpText = try Self.decodeOptionalScalarString(from: container, forKey: .helpText)
        AXFrame = try Self.decodeOptionalScalarString(from: container, forKey: .AXFrame)
        customActions = try container.decodeIfPresent([String].self, forKey: .customActions)
        AXLabel = try Self.decodeOptionalScalarString(from: container, forKey: .AXLabel)
        AXValue = try Self.decodeOptionalScalarString(from: container, forKey: .AXValue)
        AXUniqueId = try Self.decodeOptionalScalarString(from: container, forKey: .AXUniqueId)
        AXIdentifier = try Self.decodeOptionalScalarString(from: container, forKey: .AXIdentifier)
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

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    var label: String? {
        AXLabel
    }

    var value: String? {
        AXValue
    }

    var identifier: String? {
        AXUniqueId ?? AXIdentifier
    }
}

struct UIStateParser {
    static func parseDescribeUIRoots(_ jsonString: String) throws -> [UIElement] {
        var jsonContent = jsonString

        if let jsonStart = jsonString.firstIndex(where: { $0 == "[" || $0 == "{" }) {
            jsonContent = String(jsonString[jsonStart...])
        }

        guard let data = jsonContent.data(using: .utf8) else {
            throw TestError.invalidJSON("Could not convert string to data")
        }

        let decoder = JSONDecoder()
        if let elements = try? decoder.decode([UIElement].self, from: data) {
            return elements
        }

        let element = try decoder.decode(UIElement.self, from: data)
        return [element]
    }

    static func parseDescribeUIOutput(_ jsonString: String) throws -> UIElement {
        let elements = try parseDescribeUIRoots(jsonString)
        guard let firstElement = elements.first else {
            throw TestError.invalidJSON("No UI elements found")
        }
        return firstElement
    }

    static func findElement(in root: UIElement, matching predicate: (UIElement) -> Bool) -> UIElement? {
        if predicate(root) {
            return root
        }

        if let children = root.children {
            for child in children {
                if let found = findElement(in: child, matching: predicate) {
                    return found
                }
            }
        }

        return nil
    }

    static func findElement(in root: UIElement, withIdentifier identifier: String) -> UIElement? {
        findElement(in: root) { element in
            element.identifier == identifier
        }
    }

    static func findElementByLabel(in root: UIElement, label: String) -> UIElement? {
        findElement(in: root) { element in
            element.label == label
        }
    }

    static func findElementContainingLabel(in root: UIElement, containing: String) -> UIElement? {
        findElement(in: root) { element in
            element.label?.contains(containing) == true
        }
    }

    static func findElement(in roots: [UIElement], matching predicate: (UIElement) -> Bool) -> UIElement? {
        for root in roots {
            if let element = findElement(in: root, matching: predicate) {
                return element
            }
        }

        return nil
    }

    static func findElement(in roots: [UIElement], withIdentifier identifier: String) -> UIElement? {
        findElement(in: roots) { element in
            element.identifier == identifier
        }
    }
}
