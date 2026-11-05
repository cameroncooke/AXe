import AppKit
import CoreFoundation
import Darwin
import Foundation
@preconcurrency import AccessibilityPlatformTranslation
@preconcurrency import CoreSimulator
@preconcurrency import FBSimulatorControl

private final class SliderPickupRawReply: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AXPTranslatorResponse?
    func store(_ value: AXPTranslatorResponse?) { lock.lock(); self.value = value; lock.unlock() }
    func read() -> AXPTranslatorResponse? { lock.lock(); defer { lock.unlock() }; return value }
}

/// A capability-checked read route. It never opens an automation session or sends input.
@MainActor
enum SliderPickupRawAttributes {
    private typealias Mapper = @convention(c) (NSString) -> Unmanaged<NSObject>?
    private static func runtimeID(_ symbol: String) throws -> UInt64 {
        let scope = UnsafeMutableRawPointer(bitPattern: -2)
        guard let address = dlsym(scope, symbol), let function = dlsym(scope, "AXAttributeForXCAttribute") else {
            throw SliderPickupReadError.rejected("Named native Slider read exports unavailable")
        }
        for pointer in [address, function] {
            var info = Dl_info()
            guard dladdr(pointer, &info) != 0, let file = info.dli_fname,
                  String(cString: file).hasPrefix("/System/Library/PrivateFrameworks/AXRuntime.framework/") else {
                throw SliderPickupReadError.rejected("Slider read export belongs to an unsupported image")
            }
        }
        guard let name = address.assumingMemoryBound(to: NSString?.self).pointee,
              name.length > 0, name.length <= 256,
              let number = unsafeBitCast(function, to: Mapper.self)(name)?.takeUnretainedValue() as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              "cCsSiIlLqQ".contains(String(cString: number.objCType)),
              String(cString: number.objCType).count == 1 else {
            throw SliderPickupReadError.rejected("Native Slider attribute ID has an unsupported type")
        }
        let value = number.uint64Value
        guard value > 0, value <= UInt64(Int64.max), number.compare(NSNumber(value: value)) == .orderedSame else {
            throw SliderPickupReadError.rejected("Native Slider attribute ID is not an exact positive integer")
        }
        return value
    }

    static func read(simulator: FBSimulator, target: AXPMacPlatformElement, frame: CGRect,
                     deadline: Double, check: () throws -> Void) throws -> [SliderPickupReadAttribute] {
        guard let identity = target.translation, identity.pid > 0, identity.objectID > 0 else {
            throw SliderPickupReadError.rejected("Raw Slider read has no owned target identity")
        }
        let pid = identity.pid, objectID = identity.objectID, data = identity.rawElementData
        let frameID = try runtimeID("kAXXCAttributeFrame")
        let absoluteID = try runtimeID("kAXXCAttributeAbsoluteValue")
        let minimumID = try runtimeID("kAXXCAttributeMinScrubberPosition")
        let maximumID = try runtimeID("kAXXCAttributeMaxScrubberPosition")
        guard Set([frameID, absoluteID, minimumID, maximumID]).count == 4 else {
            throw SliderPickupReadError.rejected("Native Slider attribute IDs conflict")
        }
        func current() throws {
            try check()
            guard let current = target.translation, current.pid == pid, current.objectID == objectID,
                  current.rawElementData == data, target.accessibilityRole()?.rawValue == NSAccessibility.Role.slider.rawValue,
                  target.isAccessibilityEnabled(), !target.isAccessibilityHidden(), target.accessibilityFrame() == frame else {
                throw SliderPickupReadError.rejected("Raw Slider target or frame changed")
            }
        }
        func number(_ attribute: NSAccessibility.Attribute) throws -> NSNumber {
            try current()
            guard let value = try SliderPickupReadNative.generic(target, attribute.rawValue) as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
                throw SliderPickupReadError.rejected("Native Slider numeric value/domain unavailable")
            }
            return value
        }
        let initial = try number(.value), low = try number(.minValue), high = try number(.maxValue)
        guard low.compare(NSNumber(value: 0)) == .orderedSame, high.compare(NSNumber(value: 1)) == .orderedSame,
              initial.compare(low) != .orderedAscending, initial.compare(high) != .orderedDescending else {
            throw SliderPickupReadError.rejected("Raw Slider read currently requires a native numeric unit range0...1")
        }
        let queue = DispatchQueue(label: "axe.slider.raw-read.reply")
        var admitted = Set([frameID, absoluteID])
        func raw(_ attribute: UInt64) throws -> NSObject {
            try current()
            guard admitted.contains(attribute), ProcessInfo.processInfo.systemUptime < deadline,
                  let request = AXPTranslatorRequest.request(withTranslation: identity) as? AXPTranslatorRequest else {
                throw SliderPickupReadError.rejected("Raw Slider attribute lacks current admission")
            }
            // Verified read-only AXP protocol: underlying AXRuntime ID in the parameter slot.
            // Fresh Frame/value comparisons below prove support; no OS UUID or address is pinned.
            request.requestType = 2; request.attributeType = 0x3f; request.actionType = 0; request.clientType = 2
            request.parameters = ["parameter": NSNumber(value: attribute)]
            let response = SliderPickupRawReply(), signal = DispatchSemaphore(value: 0)
            simulator.device.sendAccessibilityRequestAsync(request, completionQueue: queue) { reply in
                response.store(reply); signal.signal()
            }
            let budget = min(5, max(0, deadline - ProcessInfo.processInfo.systemUptime))
            guard signal.wait(timeout: .now() + budget) == .success else {
                throw SliderPickupReadError.rejected("Raw Slider attribute deadline expired")
            }
            try current()
            guard let reply = response.read(), reply.error == 0, reply.attribute == 0x3f,
                  let value = reply.resultData as? NSObject else {
                throw SliderPickupReadError.rejected("Raw Slider attribute unsupported or failed: " + String(attribute)
                    + " error=" + String(response.read()?.error ?? UInt64.max))
            }
            return value
        }
        func rect(_ value: NSObject) throws -> CGRect {
            guard let value = value as? NSValue,
                  String(cString: value.objCType) == String(cString: NSValue(rect: .zero).objCType) else {
                throw SliderPickupReadError.rejected("Raw Slider Frame has an unsupported type")
            }
            return value.rectValue
        }
        guard try rect(raw(frameID)) == frame, let absolute = try raw(absoluteID) as? NSNumber,
              CFGetTypeID(absolute) != CFBooleanGetTypeID(), absolute.doubleValue.isFinite,
              absolute.compare(initial) == .orderedSame,
              try number(.value).compare(initial) == .orderedSame,
              try number(.minValue).compare(low) == .orderedSame,
              try number(.maxValue).compare(high) == .orderedSame else {
            throw SliderPickupReadError.rejected("Raw Slider Frame/value capability check differs from native getters")
        }
        admitted.formUnion([minimumID, maximumID])
        func point(_ value: NSObject) throws -> CGPoint {
            guard let native = value as? NSValue,
                  String(cString: native.objCType) == String(cString: NSValue(point: .zero).objCType) else {
                throw SliderPickupReadError.rejected("Raw scrubber point has an unsupported type")
            }
            let point = native.pointValue
            guard point.x.isFinite, point.y.isFinite else { throw SliderPickupReadError.rejected("Raw scrubber point is not finite") }
            return point
        }
        let minimumRaw = try raw(minimumID), maximumRaw = try raw(maximumID)
        let minimum = try point(minimumRaw), maximum = try point(maximumRaw)
        guard try point(raw(minimumID)) == minimum, try point(raw(maximumID)) == maximum,
              let finalAbsolute = try raw(absoluteID) as? NSNumber,
              CFGetTypeID(finalAbsolute) != CFBooleanGetTypeID(), finalAbsolute.doubleValue.isFinite,
              finalAbsolute.compare(absolute) == .orderedSame,
              try number(.value).compare(initial) == .orderedSame,
              try number(.minValue).compare(low) == .orderedSame,
              try number(.maxValue).compare(high) == .orderedSame else {
            throw SliderPickupReadError.rejected("Raw Slider metadata changed during read")
        }
        func captured(_ symbol: String, value: NSObject, point: CGPoint? = nil) throws -> SliderPickupReadAttribute {
            let encoded: NSObject
            if let point { encoded = ["X": NSNumber(value: Double(point.x)), "Y": NSNumber(value: Double(point.y))] as NSDictionary }
            else { encoded = value }
            let bytes = try JSONSerialization.data(withJSONObject: ["value": encoded], options: .sortedKeys)
            guard bytes.count <= 4096 else { throw SliderPickupReadError.rejected("Raw Slider metadata exceeds its bound") }
            return SliderPickupReadAttribute(source: "AXRuntime named attribute via AXP read-only63", name: symbol, symbol: symbol,
                state: "returned", objectType: String(describing: type(of: value)), rawJSON: String(decoding: bytes, as: UTF8.self),
                error: nil, objectiveCType: (value as? NSValue).map { String(cString: $0.objCType) }, rawDescription: nil)
        }
        return try [captured("kAXXCAttributeAbsoluteValue", value: absolute),
            captured("kAXXCAttributeMinScrubberPosition", value: minimumRaw, point: minimum),
            captured("kAXXCAttributeMaxScrubberPosition", value: maximumRaw, point: maximum)]
    }
}
