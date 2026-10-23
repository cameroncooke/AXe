import AppKit
import Foundation
import FBSimulatorControl

/// Only scalar values from one failed native read; no app text or native handles.
struct SliderValueNativeReadDiagnostic: Codable, Sendable {
    let readOrdinal: Int
    let readName: String
    let readError: String
    let targetCallbacks: Int
    let overwrittenRecords: Int
    let latest: [[String: String]]
}

/// Bounded observation through the existing admission callbacks. The original guard still decides admission.
final class SliderValueReadDiagnostics: FBSimulatorSliderAdmissionGuard, @unchecked Sendable {
    private let admissionGuard: (any FBSimulatorSliderAdmissionGuard)?
    private let lock = NSLock()
    private var readOrdinal = 0
    private var readName = "unlabelled"
    private var targetCallbacks = 0
    private var overwrittenRecords = 0
    private var latest: [[String: String]] = []
    private var failedRead: SliderValueNativeReadDiagnostic?

    init(admissionGuard: (any FBSimulatorSliderAdmissionGuard)?) {
        self.admissionGuard = admissionGuard
    }

    func beginRead(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        readOrdinal += 1
        readName = String(name.prefix(96))
        targetCallbacks = 0
        overwrittenRecords = 0
        latest.removeAll(keepingCapacity: true)
    }

    func endRead(error: Error? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let error, failedRead == nil else { return }
        let code: String
        if case FBSimulatorSliderError.invalidDomain = error { code = "invalidDomain" }
        else if case FBSimulatorSliderError.unsupportedValueDomain = error { code = "unsupportedValueDomain" }
        else if error is CancellationError { code = "cancelled" }
        else { code = "readFailed" }
        failedRead = SliderValueNativeReadDiagnostic(readOrdinal: readOrdinal, readName: readName,
            readError: code, targetCallbacks: targetCallbacks, overwrittenRecords: overwrittenRecords,
            latest: latest)
    }

    func failureSnapshot() -> SliderValueNativeReadDiagnostic? {
        lock.lock(); defer { lock.unlock() }
        return failedRead
    }

    func validateScreen(_ roots: [FBSimulatorAXNode], observation: FBSimulatorHIDSessionObservation,
        allowingValueChange: Bool) throws {
        try admissionGuard?.validateScreen(roots, observation: observation,
            allowingValueChange: allowingValueChange)
    }

    func validateTarget(_ capabilities: FBSimulatorSliderCapabilities, allowingValueChange: Bool) throws {
        recordTarget(capabilities, allowingValueChange: allowingValueChange)
        try admissionGuard?.validateTarget(capabilities, allowingValueChange: allowingValueChange)
    }

    private func recordTarget(_ capabilities: FBSimulatorSliderCapabilities, allowingValueChange: Bool) {
        lock.lock(); defer { lock.unlock() }
        targetCallbacks += 1
        var record = ["callbackInRead": String(targetCallbacks),
            "uptime": String(ProcessInfo.processInfo.systemUptime),
            "snapshotID": capabilities.snapshotID.uuidString,
            "allowingValueChange": String(allowingValueChange),
            "pid": capabilities.node.pid.map { String($0) } ?? "missing",
            "boot": String(capabilities.observation.bootIdentity.prefix(96)),
            "screenID": String(capabilities.observation.screenID),
            "screenUUID": String(capabilities.observation.screenUniqueID.prefix(96)),
            "rotation": String(capabilities.observation.rotation),
            "poseRevision": String(capabilities.observation.poseRevision.prefix(256))]
        if let frame = capabilities.node.frame {
            record["frameX"] = String(Double(frame.minX)); record["frameY"] = String(Double(frame.minY))
            record["frameWidth"] = String(Double(frame.width)); record["frameHeight"] = String(Double(frame.height))
        }
        recordScalar(capabilities.node.value, prefix: "nodeValue", into: &record)
        for (prefix, key) in [("minimum", NSAccessibility.Attribute.minValue),
            ("maximum", NSAccessibility.Attribute.maxValue), ("rawValue", NSAccessibility.Attribute.value)] {
            let attribute = capabilities.raw.attributes[key.rawValue]
            record[prefix + "State"] = attribute?.state.rawValue ?? "missing"
            recordScalar(attribute?.value, prefix: prefix, into: &record)
        }
        if latest.count == 2 { latest.removeFirst(); overwrittenRecords += 1 }
        latest.append(record)
    }

    private func recordScalar(_ value: FBSimulatorAXValue?, prefix: String, into record: inout [String: String]) {
        switch value {
        case nil: record[prefix + "Kind"] = "missing"
        case .some(.null): record[prefix + "Kind"] = "null"
        case .some(.boolean): record[prefix + "Kind"] = "boolean"
        case .some(.string): record[prefix + "Kind"] = "string"
        case .some(.array): record[prefix + "Kind"] = "array"
        case .some(.object): record[prefix + "Kind"] = "object"
        case .some(.number(let number)):
            record[prefix + "Kind"] = "number"
            record[prefix + "Number"] = String(number)
            record[prefix + "Finite"] = String(number.isFinite)
        }
    }
}
