import Foundation
import FBSimulatorControl

struct SelectedHingeRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case read, set }
    let kind: Kind
    let expectedBootIdentity: String?
    let degrees: Double?
    let toleranceDegrees: Double?
    let timeoutSeconds: Double?
    var readiness: FBSimulatorHingeReadinessRequest? = nil

    func validate() throws {
        if let boot = expectedBootIdentity {
            let parts = boot.split(separator: ":", omittingEmptySubsequences: false)
            guard boot.utf8.count <= 128, parts.count == 3,
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else {
                throw SelectedHIDFailure.invalid("Expected boot must be the observed PID:SECONDS:MICROSECONDS tuple")
            }
        }
        switch kind {
        case .read:
            guard degrees == nil, toleranceDegrees == nil, timeoutSeconds == nil, readiness == nil else {
                throw SelectedHIDFailure.invalid("Hinge read cannot carry write options")
            }
        case .set:
            _ = try nativeRequest()
            if let readiness {
                _ = try FBSimulatorHingeReadinessRequest(screenID: readiness.screenID, screenUUID: readiness.screenUUID,
                    timeoutSeconds: readiness.timeoutSeconds)
            }
        }
    }

    func nativeRequest() throws -> FBSimulatorHingeRequest {
        guard kind == .set, let degrees, let expectedBootIdentity,
              let toleranceDegrees, let timeoutSeconds else {
            throw SelectedHIDFailure.invalid("Hinge set requires angle, expected boot, tolerance and timeout")
        }
        return try FBSimulatorHingeRequest(degrees: degrees, expectedBootIdentity: expectedBootIdentity,
            toleranceDegrees: toleranceDegrees, timeoutSeconds: timeoutSeconds)
    }

    func brokerRequest() throws -> SelectedHIDRequest {
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [], hinge: self)
        try request.validate()
        return request
    }
}

struct SelectedHingeFailure: Codable, Sendable {
    let reason: FBSimulatorHingeFailureReason
    let detail: String
    let detailTruncated: Bool
    let delivery: FBSimulatorHingeDelivery
    let requestedDegrees: Double?
    let latestSample: FBSimulatorHingeSample?
    let latestSampleOmitted: Bool

    init(_ error: Error) {
        let native = error as? FBSimulatorHingeFailure
        if let native { reason = native.reason }
        else if error is CancellationError { reason = .cancelled }
        else if let selected = error as? SelectedHIDFailure, case .busy = selected { reason = .busy }
        else { reason = .unavailable }
        let text = native?.detail ?? String(describing: error)
        detail = String(text.prefix(1024)); detailTruncated = text.count > 1024
        delivery = native?.delivery ?? .notDispatched
        requestedDegrees = native?.requestedDegrees
        let sample = native?.latestSample
        let finite = sample.map { [$0.mechanicalDegrees, $0.sensedDegrees, $0.velocityDegreesPerSecond,
            $0.minimumDegrees, $0.maximumDegrees, $0.timestampUptime, $0.receivedUptime].allSatisfy { $0.isFinite } } ?? true
        latestSample = finite ? sample : nil
        latestSampleOmitted = !finite
    }
}

struct SelectedHingeResult: Codable, Sendable {
    enum DisplayCompletion: String, Codable, Sendable { case notChecked, coherentObserved, incomplete }
    let kind: SelectedHingeRequest.Kind
    let expectedBootIdentity: String?
    var readback: FBSimulatorHingeReadback?
    var receipt: FBSimulatorHingeReceipt?
    var failure: SelectedHingeFailure?
    var activeDisplayCompletion: DisplayCompletion
    var readiness: FBSimulatorHingeReadinessReceipt? = nil
    var readinessPreflightFailure: FBSimulatorHingeReadinessError? = nil

    init(_ request: SelectedHingeRequest) {
        kind = request.kind; expectedBootIdentity = request.expectedBootIdentity
        readback = nil; receipt = nil; failure = nil; activeDisplayCompletion = .notChecked
    }
}

/// A hinge write changes the device, not one selected display.
struct SelectedHingeQuarantineContext: Codable {
    let expectedBootIdentity: String
    let requestedDegrees: Double
    let before: FBSimulatorHingeReadback?
    let latestSample: FBSimulatorHingeSample?
}

/// Observer cleanup uncertainty is separate from the already completed mechanical write.
struct SelectedHingeObservationQuarantineContext: Codable {
    let expectedBootIdentity: String
    let mechanicalReceipt: FBSimulatorHingeReceipt
    let readinessReceipt: FBSimulatorHingeReadinessReceipt
}

/// Reserve bounded final mechanical fields and, when requested, compact readiness records.
enum SelectedHingeBounds {
    static func reserveBeforeWrite(_ response: SelectedHIDResponse, includesReadiness: Bool = false) throws {
        // At most 16 attempts with 256-byte errors and three compact, <=32-panel observations.
        // No child stdout, raw JSON, arbitrary arrays or unbounded strings enter readiness replies.
        let reserve = includesReadiness ? 48 * 1024 : 16 * 1024
        guard let result = response.hinge, let readback = result.readback,
              readback.bootIdentity.utf8.count <= 128,
              readback.capability.integratedDigitizerIDs.count <= 32,
              try JSONEncoder().encode(readback).count <= 8192,
              try JSONEncoder().encode(response).count + reserve <= HIDBroker.maximumMessageBytes else {
            throw SelectedHIDFailure.invalid("Hinge reply capacity is unavailable; no write")
        }
    }
}
