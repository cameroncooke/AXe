import AppKit
import Foundation
import FBSimulatorControl

/// Bounded timings and scalar values from native reads; no app text or native handles.
struct SliderValueNativeReadTiming: Codable, Sendable {
    let readOrdinal: Int
    let readName: String
    let startedUptime: Double
    let finishedUptime: Double
    let deadlineUptime: Double
    let remainingSecondsAtStart: Double
    let outcome: String
    let lastStage: String
}

/// At most four measured paths. Strict feedback can end input; full admission precedes correction.
struct SliderValueFeedbackPath: Codable, Sendable {
    let iteration: Int
    let moves: Int
    let startX: Double
    let startY: Double
    let currentX: Double
    let currentY: Double
    let previousX: Double
    let previousValue: Double
    let coherentSampleValue: Double
    let requestedValue: Double
    let direction: Double
    let nativeTrackSpan: Double
    let pickupHitWidth: Double
    let sampleSnapshotID: String
    let fullAdmissionRead: SliderValueNativeReadTiming?
    var decision: String
    var slope: Double?
    var gain: Double?
    var proposedDistance: Double?
    var proposedNextX: Double?
    var proposedNextY: Double?
}

struct SliderValueNativeReadDiagnostic: Codable, Sendable {
    let readOrdinal: Int
    let readName: String
    let readError: String
    let targetCallbacks: Int
    let overwrittenRecords: Int
    let latest: [[String: String]]
    let recentReads: [SliderValueNativeReadTiming]?
    let feedbackPaths: [SliderValueFeedbackPath]?
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
    private var latestRecoverableRead: SliderValueNativeReadDiagnostic?
    private var startedUptime = 0.0
    private var deadlineUptime = 0.0
    private var lastStage = "unlabelled"
    private var recentReads: [SliderValueNativeReadTiming] = []
    private var feedbackPaths: [SliderValueFeedbackPath] = []

    init(admissionGuard: (any FBSimulatorSliderAdmissionGuard)?) {
        self.admissionGuard = admissionGuard
    }

    func beginRead(_ name: String, deadline: Double) {
        lock.lock(); defer { lock.unlock() }
        readOrdinal += 1
        readName = String(name.prefix(96))
        startedUptime = ProcessInfo.processInfo.systemUptime
        deadlineUptime = deadline
        lastStage = "backendCall"
        targetCallbacks = 0
        overwrittenRecords = 0
        latest.removeAll(keepingCapacity: true)
    }

    func endRead(error: Error? = nil, recoverable: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let code: String
        if let error {
            if case FBSimulatorSliderError.deadline = error { code = "deadline" }
            else if case FBSimulatorSliderError.invalidDomain = error { code = "invalidDomain" }
            else if case FBSimulatorSliderError.unsupportedValueDomain = error { code = "unsupportedValueDomain" }
            else if case FBSimulatorSliderError.inconsistentReadValue = error { code = "inconsistentReadValue" }
            else if error is CancellationError { code = "cancelled" }
            else { code = "readFailed" }
        } else { code = "returned" }
        let finished = ProcessInfo.processInfo.systemUptime
        if recentReads.count == 8 { recentReads.removeFirst() }
        recentReads.append(SliderValueNativeReadTiming(readOrdinal: readOrdinal, readName: readName,
            startedUptime: startedUptime, finishedUptime: finished, deadlineUptime: deadlineUptime,
            remainingSecondsAtStart: max(0, deadlineUptime - startedUptime), outcome: code, lastStage: lastStage))
        guard error != nil else { return }
        let record = SliderValueNativeReadDiagnostic(readOrdinal: readOrdinal, readName: readName,
            readError: code, targetCallbacks: targetCallbacks, overwrittenRecords: overwrittenRecords,
            latest: latest, recentReads: recentReads, feedbackPaths: nil)
        if recoverable { latestRecoverableRead = record }
        else if failedRead == nil { failedRead = record }
    }

    func recordFeedbackPath(iteration: Int, moves: Int, start: CGPoint, current: CGPoint,
        previousX: CGFloat, previousValue: Double, coherentSampleValue: Double,
        requestedValue: Double, direction: Double, nativeTrackSpan: Double,
        pickupHitWidth: Double, snapshotID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard feedbackPaths.count < 4 else { return }
        feedbackPaths.append(SliderValueFeedbackPath(iteration: iteration, moves: moves,
            startX: Double(start.x), startY: Double(start.y),
            currentX: Double(current.x), currentY: Double(current.y),
            previousX: Double(previousX), previousValue: previousValue,
            coherentSampleValue: coherentSampleValue, requestedValue: requestedValue,
            direction: direction, nativeTrackSpan: nativeTrackSpan, pickupHitWidth: pickupHitWidth,
            sampleSnapshotID: snapshotID.uuidString, fullAdmissionRead: recentReads.last.flatMap {
                $0.readName == "heldAdmission" ? $0 : nil
            },
            decision: "progressCheck"))
    }

    func recordFeedbackDecision(_ decision: String, slope: Double? = nil, gain: Double? = nil,
        proposedDistance: Double? = nil, proposedNext: CGPoint? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let index = feedbackPaths.indices.last else { return }
        feedbackPaths[index].decision = decision
        feedbackPaths[index].slope = slope.flatMap { $0.isFinite ? $0 : nil }
        feedbackPaths[index].gain = gain.flatMap { $0.isFinite ? $0 : nil }
        feedbackPaths[index].proposedDistance = proposedDistance.flatMap { $0.isFinite ? $0 : nil }
        feedbackPaths[index].proposedNextX = proposedNext.flatMap { $0.x.isFinite ? Double($0.x) : nil }
        feedbackPaths[index].proposedNextY = proposedNext.flatMap { $0.y.isFinite ? Double($0.y) : nil }
    }

    private func stage(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        lastStage = value
    }

    func failureSnapshot() -> SliderValueNativeReadDiagnostic? {
        lock.lock(); defer { lock.unlock() }
        guard readOrdinal > 0 else { return nil }
        let original = failedRead ?? latestRecoverableRead
        return SliderValueNativeReadDiagnostic(readOrdinal: original?.readOrdinal ?? readOrdinal,
            readName: original?.readName ?? readName, readError: original?.readError ?? "noNativeReadFailure",
            targetCallbacks: original?.targetCallbacks ?? targetCallbacks,
            overwrittenRecords: original?.overwrittenRecords ?? overwrittenRecords,
            latest: original?.latest ?? latest, recentReads: recentReads, feedbackPaths: feedbackPaths)
    }

    func validateScreen(_ roots: [FBSimulatorAXNode], observation: FBSimulatorHIDSessionObservation,
        allowingValueChange: Bool) throws {
        stage("screenValidation")
        try admissionGuard?.validateScreen(roots, observation: observation,
            allowingValueChange: allowingValueChange)
        stage("screenValidated")
    }

    func validateTarget(_ capabilities: FBSimulatorSliderCapabilities, allowingValueChange: Bool) throws {
        recordTarget(capabilities, allowingValueChange: allowingValueChange)
        stage("targetValidation")
        try admissionGuard?.validateTarget(capabilities, allowingValueChange: allowingValueChange)
        stage("targetValidated")
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
        case .some: record[prefix + "Kind"] = "unknown"
        }
    }
}
