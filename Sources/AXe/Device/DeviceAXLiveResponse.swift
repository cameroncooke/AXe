import Foundation

struct DeviceAXRequestIdentity: Sendable, Equatable {
    let requestType: UInt64
    let attribute: UInt64
    let pid: Int32
    let objectID: UInt64
}

/// Reads only the association fields. The native dispatcher decodes result data separately.
@objc(AXeDeviceAXLiveResponse)
final class DeviceAXLiveResponse: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true

    let requestType: UInt64
    private let attribute: UInt64
    private let target: DeviceAXLiveResponseTarget?

    var identity: DeviceAXRequestIdentity? {
        guard let target else { return nil }
        return DeviceAXRequestIdentity(requestType: requestType, attribute: attribute,
            pid: target.pid, objectID: target.objectID)
    }

    func matches(_ request: DeviceAXRequestIdentity, pinnedToFreshTree: Bool) -> Bool {
        if request.requestType == 7 {
            // The phone's AXPress reply carries no target. The sole pending request owns
            // the channel and the exact outbound ID must also receive its DTX ACK.
            return pinnedToFreshTree && request.attribute == 0 && requestType == 7
                && attribute == 0 && target == nil
        }
        return identity == request
    }

    static func decode(_ data: Data) throws -> DeviceAXLiveResponse {
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.requiresSecureCoding = true
        decoder.decodingFailurePolicy = .setErrorAndReturn
        decoder.setClass(DeviceAXLiveResponse.self, forClassName: "AXPTranslatorResponse")
        decoder.setClass(DeviceAXLiveResponseTarget.self, forClassName: "AXPTranslationObject")
        let response = decoder.decodeObject(of: DeviceAXLiveResponse.self, forKey: NSKeyedArchiveRootObjectKey)
        decoder.finishDecoding()
        guard decoder.error == nil, let response else {
            throw DeviceServiceError.invalidProtocol("DTX: could not decode live accessibility response metadata")
        }
        return response
    }

    required init?(coder: NSCoder) {
        requestType = UInt64(bitPattern: coder.decodeInt64(forKey: "associatedRequestType"))
        attribute = UInt64(bitPattern: coder.decodeInt64(forKey: "attribute"))
        target = coder.decodeObject(of: DeviceAXLiveResponseTarget.self, forKey: "associatedTranslationObject")
    }

    func encode(with coder: NSCoder) {}
}

@objc(AXeDeviceAXLiveResponseTarget)
private final class DeviceAXLiveResponseTarget: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let pid: Int32
    let objectID: UInt64

    init?(coder: NSCoder) {
        let pid = coder.decodeInt32(forKey: "pid")
        guard pid > 0, let number = coder.decodeObject(of: NSNumber.self, forKey: "objectID"),
              let objectID = UInt64(number.stringValue) ?? Int64(number.stringValue).map(UInt64.init(bitPattern:)),
              objectID != 0 else {
            coder.failWithError(CocoaError(.coderReadCorrupt))
            return nil
        }
        self.pid = pid
        self.objectID = objectID
    }

    func encode(with coder: NSCoder) {}
}
