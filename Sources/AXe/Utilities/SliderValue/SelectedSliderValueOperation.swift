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

/// One retained contact and a bounded native-value feedback loop. The enclosing broker owns
/// the common input lease and retains this object if either child or input cleanup is uncertain.
@MainActor
final class SelectedSliderValueOperation {
    private let simulator: FBSimulator
    private let observation: FBSimulatorHIDSessionObservation
    private let live: FBSimulatorHIDNativeFreshnessProvider
    private let helperURL: URL
    private let selectorKind: SelectedAXRequest.SelectorKind
    private let selectorValue: String
    private let expectedPID: Int32
    private let elementType: String?
    private let preparation: FBSimulatorAXPreparation
    private let admissionGuard: (any FBSimulatorSliderAdmissionGuard)?
    private let operationID = UUID()
    private var backend: FBSimulatorSliderBackend?
    private var session: FBSimulatorHIDSession?
    private var pickupHelper: SliderPickupHelper?
    private var deadline = 0.0
    private var started = 0.0
    private var consumed = false
    private var currentPoint = CGPoint.zero
    private var moveCount = 0
    private var initialValue: Double?
    private var finalValue: Double?
    private var nativeTarget: Double?
    private var domain: FBSimulatorSliderDomain?
    private(set) var requiresExternalRecovery = false

    init(simulator: FBSimulator, observation: FBSimulatorHIDSessionObservation,
         live: FBSimulatorHIDNativeFreshnessProvider, helperURL: URL,
         selectorKind: SelectedAXRequest.SelectorKind, selectorValue: String, expectedPID: Int32,
         elementType: String?, preparation: FBSimulatorAXPreparation,
         admissionGuard: (any FBSimulatorSliderAdmissionGuard)?) {
        self.simulator = simulator; self.observation = observation; self.live = live
        self.helperURL = helperURL; self.selectorKind = selectorKind; self.selectorValue = selectorValue
        self.expectedPID = expectedPID; self.elementType = elementType; self.preparation = preparation
        self.admissionGuard = admissionGuard
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
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
        return SelectedSliderValueExecution(receipt: receipt,
            outcome: executionOutcome,
            error: receipt.reason, enqueuedEventCount: finished.count, cleanup: finished.cleanup)
    }

    private func check() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw SliderValueFailure.rejected("Slider value action exceeded its 15-second budget")
        }
        try live.validateCurrentRevision(expected: observation)
    }

    private func perform(percent: Double) async throws -> String {
        // Numeric endpoints are dispatched to the semantic endpoint route before this owner exists.
        guard percent.isFinite, percent > 0, percent < 100, expectedPID > 0 else {
            throw SliderValueFailure.rejected("Interior Slider values require a finite percentage above 0 and below 100, and a current app PID")
        }
        try check()
        let bounded = SliderValueDeadlineFeed(base: live, deadline: deadline)
        let reader: FBSimulatorSliderBackend
        switch selectorKind {
        case .id:
            reader = FBSimulatorSliderBackend(simulator: simulator, observation: observation,
                freshnessProvider: bounded, identifier: selectorValue, expectedPID: expectedPID,
                elementType: elementType, preparation: preparation, admissionGuard: admissionGuard)
        case .label:
            reader = FBSimulatorSliderBackend(simulator: simulator, observation: observation,
                freshnessProvider: bounded, label: selectorValue, expectedPID: expectedPID,
                elementType: elementType, preparation: preparation, admissionGuard: admissionGuard)
        default: throw SliderValueFailure.rejected("Slider value requires an exact ID or label")
        }
        backend = reader
        try await reader.prepare(operationID: operationID, deadline: deadline)
        let initial = try await reader.read(deadline: deadline)
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
            let final = try await reader.readFinal(deadline: deadline)
            try final.requireSameTarget(as: initial, includeValue: true)
            finalValue = try final.requireValue()
            return "alreadyAtValue"
        }
        let helper = SliderPickupHelper(observation: observation, live: live, helperURL: helperURL,
            selectorKind: selectorKind, selectorValue: selectorValue, expectedPID: expectedPID, deadline: deadline)
        pickupHelper = helper
        let admitted = try await helper.prepare(before: initial)
        let pickup = admitted.pickup
        currentPoint = pickup
        let confirmed = try await reader.read(deadline: deadline)
        try confirmed.requireSameTarget(as: initial, includeValue: true)
        try check()
        guard deadline - ProcessInfo.processInfo.systemUptime > 3 else {
            throw SliderValueFailure.rejected("Slider value has no release/readback reserve")
        }
        let hid = try await FBSimulatorHIDSession.open(for: simulator, observation: observation,
            liveFreshnessProvider: bounded)
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
        var next = CGPoint(x: pickup.x + CGFloat(initialDistance), y: pickup.y)
        var previous: (x: CGFloat, value: Double) = (pickup.x, initialValue)
        var previousPathLength = abs(initialDistance)
        var reached = false
        var requiresCleanSlope = false
        for iteration in 1...4 {
            try await movePath(to: next, token: token, frame: frame)
            let sample = try await settledValue(initial: initial, released: false)
            let value = try sample.requireValue()
            // One measured take-up path is permitted only after an exact first-path plateau.
            if iteration == 1, value == initialValue {
                let hitWidth = Double(admitted.hitFrame.width)
                let distance = direction * min(previousPathLength, hitWidth / 2)
                let x = currentPoint.x + CGFloat(distance)
                guard hitWidth.isFinite, hitWidth > 0, distance.isFinite, distance * direction > 0,
                      x.isFinite, x != currentPoint.x, frame.contains(CGPoint(x: x, y: pickup.y)) else {
                    throw SliderValueFailure.rejected("Measured take-up path is unavailable or outside the Slider")
                }
                previous = (currentPoint.x, value)
                previousPathLength = abs(distance)
                next = CGPoint(x: x, y: pickup.y)
                requiresCleanSlope = true
                continue
            }
            guard (value - previous.value) * direction > 0,
                  (value - initialValue) * direction >= -domain.tolerance,
                  (value - requested) * direction <= domain.tolerance else {
                throw SliderValueFailure.rejected("Slider value stalled, reversed or passed the target; no replay")
            }
            if abs(value - requested) <= domain.tolerance { reached = true; break }
            if requiresCleanSlope {
                // The take-up interval can include a flat value. Measure one clean interval before using its slope.
                let proposed = Double(admitted.maximum.x - admitted.minimum.x)
                    * (requested - value) / (domain.maximum - domain.minimum)
                let distance = direction * min(abs(proposed), previousPathLength)
                let x = currentPoint.x + CGFloat(distance)
                guard iteration == 2, proposed.isFinite, proposed * direction > 0,
                      distance.isFinite, distance * direction > 0, x.isFinite,
                      x != currentPoint.x, frame.contains(CGPoint(x: x, y: pickup.y)) else {
                    throw SliderValueFailure.rejected("Clean local slope probe is unavailable or outside the Slider")
                }
                previous = (currentPoint.x, value)
                previousPathLength = abs(distance)
                next = CGPoint(x: x, y: pickup.y)
                requiresCleanSlope = false
                continue
            }
            let deltaX = Double(currentPoint.x - previous.x)
            let slope = (value - previous.value) / deltaX
            guard deltaX.isFinite, deltaX * direction > 0, slope.isFinite, slope > 0 else {
                throw SliderValueFailure.rejected("Measured local Slider slope is invalid")
            }
            let proposed = (iteration == 3 ? 1.0 : 0.85) * (requested - value) / slope
            guard proposed.isFinite, proposed * direction > 0 else {
                throw SliderValueFailure.rejected("Local Slider correction cannot make progress")
            }
            let distance = direction * min(abs(proposed), previousPathLength)
            var x = currentPoint.x + CGFloat(distance)
            var nextPathLength = abs(distance)
            if iteration == 3 {
                let scale = Double(observation.displayContext.scale)
                guard scale.isFinite, scale > 0 else { throw SliderValueFailure.rejected("Display pixel scale is invalid") }
                x = CGFloat((Double(x) * scale).rounded(direction > 0 ? .up : .down) / scale)
                let roundedDistance = Double(x - currentPoint.x)
                guard roundedDistance * direction > 0, abs(roundedDistance) <= previousPathLength else {
                    throw SliderValueFailure.rejected("Pixel correction exceeds the preceding path length")
                }
                nextPathLength = abs(roundedDistance)
            }
            guard x.isFinite, x != currentPoint.x, frame.contains(CGPoint(x: x, y: pickup.y)) else {
                throw SliderValueFailure.rejected("Slider correction is outside the current frame")
            }
            previous = (currentPoint.x, value); previousPathLength = nextPathLength
            next = CGPoint(x: x, y: pickup.y)
        }
        guard reached else { throw SliderValueFailure.rejected("Slider target was not reached within four feedback paths") }
        let up = try await hid.end(token)
        guard up.outcome == .endedAndDrained, !(await hid.status().hasRetainedContact) else {
            throw SliderValueFailure.rejected("Slider contact did not end and drain")
        }
        let stable = try await settledValue(initial: initial, released: true)
        let final = try await reader.readFinal(deadline: deadline)
        try final.requireSameTarget(as: stable, includeValue: false)
        finalValue = try final.requireValue()
        guard abs(try stable.requireValue() - requested) <= domain.tolerance,
              abs(try final.requireValue() - requested) <= domain.tolerance else {
            throw SliderValueFailure.rejected("Released Slider value differs from the requested value")
        }
        try check()
        return "reached"
    }

    private func settledValue(initial: FBSimulatorSliderCapabilities, released: Bool) async throws -> FBSimulatorSliderCapabilities {
        guard let backend, let session else { throw SliderValueFailure.rejected("Slider feedback ownership is unavailable") }
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 2)
        var previous: Double?
        var stableSince = 0.0
        for _ in 1...128 {
            try check()
            guard ProcessInfo.processInfo.systemUptime < until else { break }
            guard await session.status().hasRetainedContact == !released else {
                throw SliderValueFailure.rejected("Slider contact changed before native feedback")
            }
            let sample = try await backend.read(deadline: until)
            let returned = ProcessInfo.processInfo.systemUptime
            try check()
            guard returned < until else { break }
            guard await session.status().hasRetainedContact == !released else {
                throw SliderValueFailure.rejected("Slider contact changed during native feedback")
            }
            try sample.requireSameTarget(as: initial, includeValue: false)
            guard sample.node.enabled == true, sample.node.hidden == false else {
                throw SliderValueFailure.rejected("Slider is no longer enabled and visible")
            }
            let value = try sample.requireValue()
            if value != previous { previous = value; stableSince = returned }
            if returned - stableSince >= 0.200 { return sample }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw SliderValueFailure.rejected("Native Slider value did not settle within two seconds")
    }

    private func movePath(to destination: CGPoint, token: FBSimulatorHIDContactToken, frame: CGRect) async throws {
        guard let session, moveCount + 12 <= 48, frame.contains(destination),
              deadline - ProcessInfo.processInfo.systemUptime > 1.5 else {
            throw SliderValueFailure.rejected("Slider path limit, frame or release reserve reached")
        }
        let start = currentPoint
        for step in 1...12 {
            try check()
            let fraction = Double(step) / 12
            let point = CGPoint(x: start.x + (destination.x - start.x) * CGFloat(fraction),
                y: start.y + (destination.y - start.y) * CGFloat(fraction))
            guard frame.contains(point), moveCount < 48 else { throw SliderValueFailure.rejected("Slider path left the selected frame") }
            let receipt = try await session.move(token, to: point)
            guard receipt.outcome == .moved, receipt.enqueuedEventCount == 1 else {
                throw SliderValueFailure.rejected("Slider MOVE failed; no second gesture or replay")
            }
            currentPoint = point; moveCount += 1
            if step < 12 { try await Task.sleep(nanoseconds: 25_000_000) }
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
