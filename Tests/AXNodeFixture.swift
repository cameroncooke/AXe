import Foundation
import FBSimulatorControl
@testable import AXe

/// One accessibility node as the native reader encodes it. Every field is optional and a nil
/// field is omitted from the JSON, so each test states exactly the keys its nodes carry.
struct AXNodeFixture: Encodable {
    struct Frame: Encodable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    var type: String?
    var identifier: String?
    var label: String?
    var value: FBSimulatorAXValue?
    var role: String?
    var frame: Frame?
    var pid: Int32?
    var focused: Bool?
    var enabled: Bool?
    var hidden: Bool?
    var nativeIdentity: FBSimulatorAXNativeIdentity?
    /// When `nativeIdentity` is nil, encodes `nativeIdentity` from this object ID and the node's
    /// `pid` at encode time, so a later `pid` change also changes the encoded owner.
    var nativeObjectID: UInt64?
    var customActionNames: [String]?
    var children: [AXNodeFixture]?

    private enum CodingKeys: String, CodingKey {
        case type, identifier = "AXUniqueId", label = "AXLabel", value = "AXValue", role, frame, pid
        case focused, enabled, hidden, nativeIdentity, customActionNames = "custom_actions", children
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(type, forKey: .type)
        try values.encodeIfPresent(identifier, forKey: .identifier)
        try values.encodeIfPresent(label, forKey: .label)
        try values.encodeIfPresent(value, forKey: .value)
        try values.encodeIfPresent(role, forKey: .role)
        try values.encodeIfPresent(frame, forKey: .frame)
        try values.encodeIfPresent(pid, forKey: .pid)
        try values.encodeIfPresent(focused, forKey: .focused)
        try values.encodeIfPresent(enabled, forKey: .enabled)
        try values.encodeIfPresent(hidden, forKey: .hidden)
        var identity = nativeIdentity
        if identity == nil, let nativeObjectID {
            guard let pid else {
                throw EncodingError.invalidValue(nativeObjectID, .init(codingPath: encoder.codingPath,
                    debugDescription: "A fixture nativeObjectID needs a pid."))
            }
            identity = FBSimulatorAXNativeIdentity(pid: pid, objectID: nativeObjectID)
        }
        try values.encodeIfPresent(identity, forKey: .nativeIdentity)
        try values.encodeIfPresent(customActionNames, forKey: .customActionNames)
        try values.encodeIfPresent(children, forKey: .children)
    }

    /// Decodes fixture roots through the same JSON path as a native accessibility read.
    static func decode(_ roots: [AXNodeFixture]) throws -> [FBSimulatorAXNode] {
        try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode(roots))
    }

    func decoded() throws -> FBSimulatorAXNode { try Self.decode([self])[0] }
}

extension SelectedHIDContext {
    /// A selected display context decoded from its wire JSON. The defaults are the rotated
    /// 951x669 panel that several agent tests share.
    static func fixture(boot: String = "1:2:3", screenID: Int = 3,
                        screenUUID: String = "DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0",
                        width: Int = 951, height: Int = 669, rotation: Int = 90,
                        pixelWidth: Int = 2007, pixelHeight: Int = 2853,
                        pose: String = "mechanicalDegrees=90.0") throws -> SelectedHIDContext {
        try JSONDecoder().decode(SelectedHIDContext.self, from: Data("""
            {"bootIdentity":"\(boot)","screenID":\(screenID),"screenUUID":"\(screenUUID)",\
            "logicalWidth":\(width),"logicalHeight":\(height),"rotationDegrees":\(rotation),\
            "nativePixelWidth":\(pixelWidth),"nativePixelHeight":\(pixelHeight),"scale":3,"poseRevision":"\(pose)"}
            """.utf8))
    }
}
