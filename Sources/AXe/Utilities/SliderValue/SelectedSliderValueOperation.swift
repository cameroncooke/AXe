import AppKit
import Foundation
import FBSimulatorControl

/// The same native revision and action deadline guard every input observation.
/// Cleanup identity remains available after the action deadline.
private final class SliderValueDeadlineFeed: FBSimulatorHIDLiveFreshnessProvider, FBSimulatorHIDCleanupIdentityProvider {
    let base: FBSimulatorHIDNativeFreshnessProvider
    let deadline: Double
    init(base: FBSimulatorHIDNativeFreshnessProvider, deadline: Double) {
        self.base = base; self.deadline = deadline
    }
    private func check() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw SliderValueFailure.rejected("Slider value action deadline expired before input")
        }
    }
    func observation() async throws -> FBSimulatorHIDSessionObservation {
        try check(); let value = try await base.observation(); try check(); return value
    }
    func validateCurrentRevision(expected: FBSimulatorHIDSessionObservation) throws {
        try check(); try base.validateCurrentRevision(expected: expected); try check()
    }
    func cleanupIdentity() async throws -> FBSimulatorHIDCleanupIdentity { try await base.cleanupIdentity() }
    func close() { base.close() }
}

/// Fixed path pacing and correction planning. Native calls still use the original action deadline.
enum SliderValuePathPlan {
    static let steps = 12
    static let pauseNanoseconds: UInt64 = 25_000_000
    static let minimumSettleSeconds = 0.200

    static func canBegin(remainingSeconds: Double, releaseReserveSeconds: Double) -> Bool {
        let pacingSeconds = Double(steps - 1) * Double(pauseNanoseconds) / 1_000_000_000
        let requiredSeconds = pacingSeconds + minimumSettleSeconds + releaseReserveSeconds
        return remainingSeconds.isFinite && releaseReserveSeconds.isFinite
            && releaseReserveSeconds >= 0 && remainingSeconds > requiredSeconds
    }

    static func correctionGain(iteration: Int) -> Double {
        // The first interval can include thumb take-up. Later intervals measure actual movement.
        iteration == 1 ? 0.5 : 1.0
    }
}

/// One retained contact and a bounded native-value feedback loop. The enclosing broker owns
/// the common input lease and retains this object if either child or input cleanup is uncertain.
@MainActor
final class SelectedSliderValueOperation {
    private let simulator: FBSimulator
    private let observation: FBSimulatorHIDSessionObservation
    private let live: FBSimulatorHIDNativeFreshnessProvider
    private let transportOwner: FBSimulatorHIDTransportOwner?
    private let selectorKind: SelectedAXRequest.SelectorKind
    private let selectorValue: String
    private let expectedPID: Int32
    private let elementType: String?
    private let readDiagnostics: SliderValueReadDiagnostics
    private let operationID = UUID()
    private var backend: FBSimulatorSliderBackend?
    private var session: FBSimulatorHIDSession?
    private var pickupHelper: SliderPickupHelper?
    private var deadline = 0.0
    private var started = 0.0
    private let releaseReserveSeconds = 1.5
    private var consumed = false
    private var currentPoint = CGPoint.zero
    private var moveCount = 0
    private var initialValue: Double?
    private var finalValue: Double?
    private var nativeTarget: Double?
    private var domain: FBSimulatorSliderDomain?
    private(set) var requiresExternalRecovery = false

    init(simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
         live: FBSimulatorHIDNativeFreshnessProvider,
         selectorKind: SelectedAXRequest.SelectorKind, selectorValue: String, expectedPID: Int32,
         elementType: String?,
         admissionGuard: (any FBSimulatorSliderAdmissionGuard)?,
         transportOwner: FBSimulatorHIDTransportOwner? = nil) {
        self.simulator = simulator; self.observation = observation; self.live = live
        self.selectorKind = selectorKind; self.selectorValue = selectorValue
        self.expectedPID = expectedPID; self.elementType = elementType; self.transportOwner = transportOwner
        readDiagnostics = SliderValueReadDiagnostics(admissionGuard: admissionGuard)
    }

    func run(percent: Double) async -> SelectedSliderValueExecution {
        started = ProcessInfo.processInfo.systemUptime
        deadline = started + 15
        var failure: String?
        var valueOutcome = "failed"
        do {
            guard !consumed else { throw SliderValueFailure.rejected("Slider value operation cannot be repeated") }
            consumed = true
            valueOutcome = try await perform(percent: percent)
        } catch { failure = String(describing: error) }
        // An unstructured task can release owned input even if the action was cancelled.
        let finished = await Task { @MainActor in await self.cleanup() }.value
        if finished.cleanup == "uncertain" {
            failure = "Slider value cleanup is uncertain. Do not repeat input."
        }
        let accepted = failure == nil && finished.cleanup != "uncertain"
        let delivery: String
        if finished.cleanup == "uncertain" { delivery = "uncertain" }
        else if finished.count == 0 { delivery = "notStarted" }
        else { delivery = accepted ? "enqueuedAndDrained" : "sent" }
        let executionOutcome: String
        if accepted { executionOutcome = valueOutcome }
        else if finished.count == 0 && finished.cleanup == "notNeeded" { executionOutcome = "failedBeforeInput" }
        else { executionOutcome = "failedNoReplay" }
        let receipt = SelectedSliderValueResult(outcome: accepted ? valueOutcome : "failed",
            reason: failure.map { String($0.prefix(1024)) },
            delivery: delivery,
            requestedPercent: percent, initialValue: initialValue, finalValue: finalValue, nativeTarget: nativeTarget,
            domainMinimum: domain?.minimum, domainMaximum: domain?.maximum, tolerance: domain?.tolerance,
            moves: moveCount, pickupReadPhases: pickupHelper?.readPhases ?? 0,
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
            nativeReadDiagnostic: failure == nil ? nil : readDiagnostics.failureSnapshot())
        return SelectedSliderValueExecution(receipt: receipt,
            outcome: executionOutcome,
            error: receipt.reason, enqueuedEventCount: finished.count, cleanup: finished.cleanup)
    }

    private func check(deadline: Double) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw SliderValueFailure.rejected("Slider value deadline expired")
        }
        try live.validateCurrentRevision(expected: observation)
    }

    private func perform(percent: Double) async throws -> String {
        // Numeric endpoints are dispatched to the semantic endpoint route before this owner exists.
        guard percent.isFinite, percent > 0, percent < 100, expectedPID > 0 else {
            throw SliderValueFailure.rejected("Interior Slider values require a finite percentage above 0 and below 100, and a current app PID")
        }
        try check(deadline: deadline)
        let bounded = SliderValueDeadlineFeed(base: live, deadline: deadline)
        let reader: FBSimulatorSliderBackend
        switch selectorKind {
        case .id:
            reader = FBSimulatorSliderBackend(simulator: simulator, observation: observation,
                freshnessProvider: live, identifier: selectorValue, expectedPID: expectedPID,
                elementType: elementType, admissionGuard: readDiagnostics)
        case .label:
            reader = FBSimulatorSliderBackend(simulator: simulator, observation: observation,
                freshnessProvider: live, label: selectorValue, expectedPID: expectedPID,
                elementType: elementType, admissionGuard: readDiagnostics)
        default: throw SliderValueFailure.rejected("Slider value requires an exact ID or label")
        }
        backend = reader
        try await reader.prepare(operationID: operationID, deadline: deadline)
        let initial = try await readNative(reader, phase: "initial", deadline: deadline)
        let domain = try initial.requireDomain()
        self.domain = domain
        let initialValue = try initial.requireValue()
        self.initialValue = initialValue
        let requested = try domain.nativeValue(percent: percent)
        nativeTarget = requested
        guard initial.node.enabled == true, initial.node.hidden == false,
              let frame = initial.node.frame, frame.width > frame.height else {
            throw SliderValueFailure.rejected("Slider value requires an enabled visible horizontal Slider")
        }
        if abs(initialValue - requested) <= domain.tolerance {
            let final = try await readNative(reader, phase: "alreadyAtValueFinal", deadline: deadline, final: true)
            try final.requireSameTarget(as: initial, includeValue: true)
            finalValue = try final.requireValue()
            return "alreadyAtValue"
        }
        let helper = SliderPickupHelper(observation: observation, live: live,
            selectorKind: selectorKind, selectorValue: selectorValue, expectedPID: expectedPID, deadline: deadline)
        pickupHelper = helper
        let admitted = try await helper.prepare(before: initial)
        let pickup = admitted.pickup
        // Keep the exact admitted DOWN; feedback starts at its effective native pixel.
        currentPoint = try canonicalPoint(pickup)
        guard frame.contains(currentPoint), admitted.hitFrame.contains(currentPoint) else {
            throw SliderValueFailure.rejected("Effective Slider pickup is outside the admitted hit frame")
        }
        let confirmed = try await readNative(reader, phase: "beforePickup", deadline: deadline)
        try confirmed.requireSameTarget(as: initial, includeValue: true)
        try check(deadline: deadline)
        guard deadline - ProcessInfo.processInfo.systemUptime > 3 else {
            throw SliderValueFailure.rejected("Slider value has no release/readback reserve")
        }
        let hid: FBSimulatorHIDSession
        if let transportOwner {
            hid = try await FBSimulatorHIDSession.open(for: simulator, observation: observation,
                liveFreshnessProvider: bounded, transportOwner: transportOwner)
        } else {
            hid = try await FBSimulatorHIDSession.open(for: simulator, observation: observation,
                liveFreshnessProvider: bounded)
        }
        session = hid
        let guardOwner = SliderPickupAdmissionGuard(observation: observation, pickup: pickup) {
            try await helper.confirm(backend: reader)
        }
        let down = try await hid.begin(at: pickup, admissionGuard: guardOwner)
        guard down.outcome == .retained, down.enqueuedEventCount == 1,
              down.cleanup == .notNeeded, let token = down.token else {
            throw SliderValueFailure.rejected("Slider pickup did not return one retained contact")
        }
        // This explicit native phase is the sole permission for this contact's value changes.
        try await reader.beginPhysicalValueFeedback(operationID: operationID,
            session: hid, beginReceipt: down, deadline: deadline)
        try await Task.sleep(nanoseconds: 150_000_000)
        let direction = requested > initialValue ? 1.0 : -1.0
        let initialDistance = 0.5 * Double(admitted.maximum.x - admitted.minimum.x)
            * (requested - initialValue) / (domain.maximum - domain.minimum)
        guard initialDistance.isFinite, initialDistance * direction > 0 else {
            throw SliderValueFailure.rejected("Initial local displacement is invalid")
        }
        var next = try canonicalPoint(CGPoint(x: currentPoint.x + CGFloat(initialDistance), y: currentPoint.y))
        let firstDistance = Double(next.x - currentPoint.x)
        guard firstDistance.isFinite, firstDistance * direction > 0, frame.contains(next) else {
            throw SliderValueFailure.rejected("Initial Slider path has no contained pixel progress")
        }
        var previous: (x: CGFloat, value: Double) = (currentPoint.x, initialValue)
        var previousPathLength = abs(firstDistance)
        var reached = false
        var requiresCleanSlope = false
        for iteration in 1...4 {
            // A full current-screen admission precedes each corrective path.
            // Strict fast feedback can end owned input, but cannot admit another path.
            let pathStart = currentPoint
            try await movePath(to: next, token: token, frame: frame)
            let sample = try await settledValue(initial: initial, released: false, deadline: deadline,
                target: (requested, domain.tolerance))
            let value = try sample.requireValue()
            readDiagnostics.recordFeedbackPath(iteration: iteration, moves: moveCount, start: pathStart,
                current: currentPoint, previousX: previous.x, previousValue: previous.value,
                coherentSampleValue: value, requestedValue: requested, direction: direction,
                nativeTrackSpan: Double(admitted.maximum.x - admitted.minimum.x),
                pickupHitWidth: Double(admitted.hitFrame.width), snapshotID: sample.snapshotID)
            // One measured take-up path is permitted only after an exact first-path plateau.
            if iteration == 1, value == initialValue {
                let hitWidth = Double(admitted.hitFrame.width)
                let distance = direction * min(previousPathLength, hitWidth / 2)
                let point = try canonicalPoint(CGPoint(x: currentPoint.x + CGFloat(distance), y: currentPoint.y))
                let effectiveDistance = Double(point.x - currentPoint.x)
                guard hitWidth.isFinite, hitWidth > 0, distance.isFinite, distance * direction > 0,
                      effectiveDistance * direction > 0, abs(effectiveDistance) <= previousPathLength,
                      abs(effectiveDistance) <= hitWidth / 2, frame.contains(point) else {
                    throw SliderValueFailure.rejected("Measured take-up path is unavailable or outside the Slider")
                }
                previous = (currentPoint.x, value)
                previousPathLength = abs(effectiveDistance)
                next = point
                requiresCleanSlope = true
                readDiagnostics.recordFeedbackDecision("takeUp", proposedDistance: distance, proposedNext: next)
                continue
            }
            guard (value - previous.value) * direction > 0,
                  (value - initialValue) * direction >= -domain.tolerance,
                  (value - requested) * direction <= domain.tolerance else {
                readDiagnostics.recordFeedbackDecision("rejectedProgressCheck")
                throw SliderValueFailure.rejected("Slider value stalled, reversed or passed the target; no replay")
            }
            if abs(value - requested) <= domain.tolerance {
                readDiagnostics.recordFeedbackDecision("reached")
                reached = true; break
            }
            if requiresCleanSlope {
                // The take-up interval can include a flat value. Measure one clean interval before using its slope.
                let proposed = Double(admitted.maximum.x - admitted.minimum.x)
                    * (requested - value) / (domain.maximum - domain.minimum)
                let distance = direction * min(abs(proposed), previousPathLength)
                let point = try canonicalPoint(CGPoint(x: currentPoint.x + CGFloat(distance), y: currentPoint.y))
                let effectiveDistance = Double(point.x - currentPoint.x)
                guard iteration == 2, proposed.isFinite, proposed * direction > 0,
                      distance.isFinite, distance * direction > 0, effectiveDistance * direction > 0,
                      abs(effectiveDistance) <= previousPathLength, frame.contains(point) else {
                    throw SliderValueFailure.rejected("Clean local slope probe is unavailable or outside the Slider")
                }
                previous = (currentPoint.x, value)
                previousPathLength = abs(effectiveDistance)
                next = point
                requiresCleanSlope = false
                readDiagnostics.recordFeedbackDecision("cleanSlopeProbe", proposedDistance: proposed, proposedNext: next)
                continue
            }
            let deltaX = Double(currentPoint.x - previous.x)
            let slope = (value - previous.value) / deltaX
            guard deltaX.isFinite, deltaX * direction > 0, slope.isFinite, slope > 0 else {
                throw SliderValueFailure.rejected("Measured local Slider slope is invalid")
            }
            let gain = SliderValuePathPlan.correctionGain(iteration: iteration)
            let proposed = gain * (requested - value) / slope
            guard proposed.isFinite, proposed * direction > 0 else {
                throw SliderValueFailure.rejected("Local Slider correction cannot make progress")
            }
            let distance = direction * min(abs(proposed), previousPathLength)
            let point = try canonicalPoint(CGPoint(x: currentPoint.x + CGFloat(distance), y: currentPoint.y))
            let effectiveDistance = Double(point.x - currentPoint.x)
            guard effectiveDistance * direction > 0, abs(effectiveDistance) <= previousPathLength,
                  frame.contains(point) else {
                throw SliderValueFailure.rejected("Pixel correction exceeds the preceding path or current frame")
            }
            previous = (currentPoint.x, value); previousPathLength = abs(effectiveDistance)
            next = point
            readDiagnostics.recordFeedbackDecision("localSlopeCorrection", slope: slope, gain: gain,
                proposedDistance: proposed, proposedNext: next)
        }
        guard reached else { throw SliderValueFailure.rejected("Slider target was not reached within four feedback paths") }
        let up = try await hid.end(token)
        guard up.outcome == .endedAndDrained, !(await hid.status().hasRetainedContact) else {
            throw SliderValueFailure.rejected("Slider contact did not end and drain")
        }
        // Input has ended. One fixed deadline now covers read-only verification.
        let verificationDeadline = ProcessInfo.processInfo.systemUptime + 2
        let stable = try await settledValue(initial: initial, released: true, deadline: verificationDeadline)
        let final = try await readNative(reader, phase: "final", deadline: verificationDeadline, final: true)
        try final.requireSameTarget(as: stable, includeValue: false)
        finalValue = try final.requireValue()
        guard abs(try stable.requireValue() - requested) <= domain.tolerance,
              abs(try final.requireValue() - requested) <= domain.tolerance else {
            throw SliderValueFailure.rejected("Released Slider value differs from the requested value")
        }
        guard !(await hid.status().hasRetainedContact) else {
            throw SliderValueFailure.rejected("Slider contact changed during final verification")
        }
        try check(deadline: verificationDeadline)
        return "reached"
    }

    private func readNative(_ backend: FBSimulatorSliderBackend, phase: String, deadline: Double,
        final: Bool = false, feedback: Bool = false,
        physicalAdmission: FBSimulatorSliderCapabilities? = nil,
        recoverValueMismatch: Bool = false) async throws -> FBSimulatorSliderCapabilities {
        readDiagnostics.beginRead(phase, deadline: deadline)
        do {
            let value: FBSimulatorSliderCapabilities
            if final { value = try await backend.readFinal(deadline: deadline) }
            else if let physicalAdmission {
                value = try await backend.readPhysicalAdmission(expected: physicalAdmission, deadline: deadline)
            }
            else if feedback { value = try await backend.readFeedback(deadline: deadline) }
            else { value = try await backend.read(deadline: deadline) }
            readDiagnostics.endRead()
            return value
        } catch {
            let recoverable: Bool
            if case FBSimulatorSliderError.inconsistentReadValue = error { recoverable = recoverValueMismatch }
            else { recoverable = false }
            readDiagnostics.endRead(error: error, recoverable: recoverable)
            throw error
        }
    }

    private func settledValue(initial: FBSimulatorSliderCapabilities, released: Bool,
        deadline: Double, target: (value: Double, tolerance: Double)? = nil) async throws -> FBSimulatorSliderCapabilities {
        guard let backend, let session else { throw SliderValueFailure.rejected("Slider feedback ownership is unavailable") }
        let readDeadline = released ? deadline : deadline - releaseReserveSeconds
        var until = min(readDeadline, ProcessInfo.processInfo.systemUptime + 2)
        var previous: Double?
        var stableSince = 0.0
        var fullAdmissionNext = false
        for _ in 1...128 {
            try check(deadline: readDeadline)
            let fullAdmission = !released && fullAdmissionNext
            guard fullAdmission || ProcessInfo.processInfo.systemUptime < until else { break }
            guard await session.status().hasRetainedContact == !released else {
                throw SliderValueFailure.rejected("Slider contact changed before native feedback")
            }
            let sample: FBSimulatorSliderCapabilities
            do {
                sample = try await readNative(backend,
                    phase: released ? "releasedSettle" : (fullAdmission ? "heldAdmission" : "heldSettle"),
                    deadline: fullAdmission ? readDeadline : until, feedback: !released && !fullAdmission,
                    physicalAdmission: fullAdmission ? initial : nil, recoverValueMismatch: !released)
            } catch FBSimulatorSliderError.inconsistentReadValue where !released {
                // Only a failed full read can have closed its selected handle. A fast read
                // retains that handle, so retry it read-only inside the same fixed window.
                previous = nil; stableSince = 0; fullAdmissionNext = fullAdmission
                try check(deadline: readDeadline)
                guard await session.status().hasRetainedContact else {
                    throw SliderValueFailure.rejected("Slider contact changed during native feedback")
                }
                try await Task.sleep(nanoseconds: 25_000_000)
                continue
            }
            let returned = ProcessInfo.processInfo.systemUptime
            try check(deadline: readDeadline)
            guard fullAdmission || returned < until else { break }
            guard await session.status().hasRetainedContact == !released else {
                throw SliderValueFailure.rejected("Slider contact changed during native feedback")
            }
            try sample.requireSameTarget(as: initial, includeValue: false)
            guard sample.node.enabled == true, sample.node.hidden == false else {
                throw SliderValueFailure.rejected("Slider is no longer enabled and visible")
            }
            let value = try sample.requireValue()
            if value != previous { previous = value; stableSince = returned }
            if returned - stableSince >= SliderValuePathPlan.minimumSettleSeconds {
                if released || fullAdmission { return sample }
                if let target, abs(value - target.value) <= target.tolerance {
                    // This sample permits only owned UP, followed by full final verification.
                    return sample
                }
                // Stability uses the fixed two-second fast-read phase. A fresh full screen read
                // then uses only the remaining original action budget, keeping the release reserve.
                fullAdmissionNext = true
            } else {
                if fullAdmission {
                    // The admitted value changed, or a typed mismatch invalidated the old sample.
                    // Settle again read-only, then admit the whole screen again before correction.
                    // The original action deadline, release reserve and 128-read bound do not reset.
                    until = min(readDeadline, returned + 2)
                }
                fullAdmissionNext = false
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw SliderValueFailure.rejected(released
            ? "Native Slider value did not settle within two seconds"
            : "Slider value settling or fresh screen admission did not finish within its read limits")
    }

    /// Snap in panel-native pixels so quarter-turn ties follow the actual digitizer axes.
    private func canonicalPoint(_ point: CGPoint) throws -> CGPoint {
        let context = observation.displayContext
        let normalized = try context.normalizedPoint(from: point)
        let size = context.nativePixelSize
        let pixels = CGPoint(x: (normalized.x * size.width).rounded(.toNearestOrAwayFromZero),
            y: (normalized.y * size.height).rounded(.toNearestOrAwayFromZero))
        let result: CGPoint
        switch context.rotation {
        case .rot0:
            result = CGPoint(x: pixels.x / context.scale, y: pixels.y / context.scale)
        case .rot90:
            result = CGPoint(x: (size.height - pixels.y) / context.scale, y: pixels.x / context.scale)
        case .rot180:
            result = CGPoint(x: (size.width - pixels.x) / context.scale,
                y: (size.height - pixels.y) / context.scale)
        case .rot270:
            result = CGPoint(x: pixels.y / context.scale, y: (size.width - pixels.x) / context.scale)
        @unknown default:
            throw SliderValueFailure.rejected("Display rotation is unsupported")
        }
        _ = try context.normalizedPoint(from: result)
        return result
    }

    private func movePath(to destination: CGPoint, token: FBSimulatorHIDContactToken, frame: CGRect) async throws {
        guard let session, moveCount + SliderValuePathPlan.steps <= 48, frame.contains(destination),
              SliderValuePathPlan.canBegin(remainingSeconds: deadline - ProcessInfo.processInfo.systemUptime,
                  releaseReserveSeconds: releaseReserveSeconds) else {
            throw SliderValueFailure.rejected("Slider path limit, frame or release reserve reached")
        }
        let start = currentPoint
        for step in 1...SliderValuePathPlan.steps {
            try check(deadline: deadline)
            let fraction = Double(step) / Double(SliderValuePathPlan.steps)
            let point = try canonicalPoint(CGPoint(x: start.x + (destination.x - start.x) * CGFloat(fraction),
                y: start.y + (destination.y - start.y) * CGFloat(fraction)))
            guard frame.contains(point), moveCount < 48 else { throw SliderValueFailure.rejected("Slider path left the selected frame") }
            let receipt = try await session.move(token, to: point)
            guard receipt.outcome == .moved, receipt.enqueuedEventCount == 1 else {
                throw SliderValueFailure.rejected("Slider MOVE failed; no second gesture or replay")
            }
            currentPoint = point; moveCount += 1
            if step < SliderValuePathPlan.steps { try await Task.sleep(nanoseconds: SliderValuePathPlan.pauseNanoseconds) }
        }
    }

    private func cleanup() async -> (cleanup: String, count: Int) {
        guard !requiresExternalRecovery else { return ("uncertain", await session?.status().enqueuedEventCount ?? 0) }
        let childClean = await pickupHelper?.close() ?? true
        var cleanup = "notNeeded"
        if let session {
            do { cleanup = try await session.close().cleanup.rawValue }
            catch { cleanup = "uncertain" }
        }
        if let backend { await backend.finish(operationID: operationID) }
        await live.closeAndWait()
        if !childClean || cleanup == "uncertain" { requiresExternalRecovery = true; cleanup = "uncertain" }
        return (cleanup, await session?.status().enqueuedEventCount ?? 0)
    }
}
