import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - HID Interactor


// Xcode 27 Beta 3 (27A5218g) Device Hub requires Resize Mode to be disabled for UI automation.
// With Resize Mode enabled, both DTUHID and legacy Indigo reported successful sends without
// delivering touches; with it disabled, the ui-interactions pass through this IDB path.
@MainActor
struct HIDInteractor {

    struct Session {
        let simulatorUDID: String
        let simulator: FBSimulator
        let hid: FBSimulatorHID
    }

    // Cache for HID connections per simulator
    private static var hidConnections: [String: FBSimulatorHID] = [:]
    /// Configurable stabilization delay to ensure HID events are fully processed
    /// Can be set via AXE_HID_STABILIZATION_MS environment variable
    private static var stabilizationDelayMs: UInt64 {
        if let envValue = ProcessInfo.processInfo.environment["AXE_HID_STABILIZATION_MS"],
           let milliseconds = UInt64(envValue) {
            return min(milliseconds, 1000)
        }
        return 25
    }

    static func makeSession(for simulatorUDID: String, logger: AxeLogger) async throws -> Session {
        logger.info().log("Loading private frameworks for HID operations...")
        let frameworkLoader = FBSimulatorControlFrameworkLoader.xcodeFrameworks
        do {
            try frameworkLoader.loadPrivateFrameworks(logger)
            logger.info().log("Private frameworks loaded successfully.")
        } catch {
            logger.error().log("Failed to load private frameworks: \(error)")
            throw CLIError(
                errorDescription: "AXe could not initialize simulator input using the selected Xcode installation. Confirm Xcode 26 or later is selected and try again."
            )
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        logger.info().log("FBSimulatorSet obtained.")

        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError.simulatorNotFound(udid: simulatorUDID)
        }

        logger.info().log("Target (FBSimulator) obtained: \(simulator.udid)")
        logger.info().log("Simulator name: \(simulator.name)")

        guard simulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(simulator.state)
            throw CLIError(
                errorDescription: "Simulator \(simulatorUDID) is not booted. Current state: \(stateDescription)."
            )
        }
        logger.info().log("Simulator state verified: booted")

        let bootIdentity = try HIDBroker.currentBootIdentity(simulatorUDID: simulatorUDID)
        let isDTUHIDSelected = FBXcodeConfiguration.xcodeVersion.majorVersion >= 27 ||
            FBProcessFetcher().subprocess(
                of: bootIdentity.processIdentifier,
                withName: "dtuhidd"
            ) > 0
        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: bootIdentity,
            isDTUHIDSelected: isDTUHIDSelected,
            now: Date.init,
            sleep: { delay in try await Task.sleep(for: .seconds(delay)) }
        )
        let hid = try await getOrCreateHIDConnection(for: simulator, logger: logger)
        let connectedBootIdentity = try HIDBroker.currentBootIdentity(simulatorUDID: simulatorUDID)
        guard HIDBroker.shouldReuseSession(
            sessionBootIdentity: bootIdentity,
            currentBootIdentity: connectedBootIdentity
        ) else {
            hidConnections.removeValue(forKey: simulatorUDID)
            throw CLIError(
                errorDescription: "Simulator \(simulatorUDID) restarted while AXe was connecting. Try the command again."
            )
        }
        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: connectedBootIdentity,
            isDTUHIDSelected: hid.transportType == .dtuhid,
            now: Date.init,
            sleep: { delay in try await Task.sleep(for: .seconds(delay)) }
        )
        return Session(simulatorUDID: simulatorUDID, simulator: simulator, hid: hid)
    }

    static func performHIDEvent(_ event: FBSimulatorHIDEvent, in session: Session, logger: AxeLogger) async throws {
        logger.info().log("Performing HID event...")
        try await session.hid.send(event: event, logger: logger)
        logger.info().log("HID event performed successfully.")

        if stabilizationDelayMs > 0 {
            logger.info().log("Applying stabilization delay of \(stabilizationDelayMs)ms...")
            try await Task.sleep(nanoseconds: stabilizationDelayMs * 1_000_000)
        }
    }

    static func performHIDEvent(_ event: FBSimulatorHIDEvent, for simulatorUDID: String, logger: AxeLogger) async throws {
        let session = try await makeSession(for: simulatorUDID, logger: logger)
        try await performHIDEvent(event, in: session, logger: logger)
    }

    static func makeCompositeDragEvent(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        duration: TimeInterval,
        steps: Int,
        initialHold: TimeInterval,
        finalHold: TimeInterval
    ) throws -> FBSimulatorHIDEvent {
        guard duration >= 0 else {
            throw CLIError(errorDescription: "Drag duration must be non-negative.")
        }
        guard steps > 0 else {
            throw CLIError(errorDescription: "Drag steps must be greater than 0.")
        }
        guard initialHold >= 0, finalHold >= 0 else {
            throw CLIError(errorDescription: "Drag hold durations must be non-negative.")
        }

        let movePoints = try compositeDragMovePoints(from: start, to: end, steps: steps)
        let stepDelay = duration / Double(steps)
        var events: [FBSimulatorHIDEvent] = [
            .touch(direction: .down, x: start.x, y: start.y),
            .delay(initialHold)
        ]

        for point in movePoints {
            events.append(.delay(stepDelay))
            events.append(.touch(direction: .down, x: point.x, y: point.y))
        }

        events.append(.delay(finalHold))
        events.append(.touch(direction: .up, x: end.x, y: end.y))

        return .composite(events)
    }

    static func compositeDragMovePoints(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        steps: Int
    ) throws -> [(x: Double, y: Double)] {
        guard steps > 0 else {
            throw CLIError(errorDescription: "Drag steps must be greater than 0.")
        }

        return (1...steps).map { step in
            let progress = Double(step) / Double(steps)
            return (
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
        }
    }

    static func performCompositeDrag(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        duration: TimeInterval,
        steps: Int,
        initialHold: TimeInterval,
        finalHold: TimeInterval,
        for simulatorUDID: String,
        logger: AxeLogger
    ) async throws {
        let event = try makeCompositeDragEvent(
            from: start,
            to: end,
            duration: duration,
            steps: steps,
            initialHold: initialHold,
            finalHold: finalHold
        )
        try await performHIDEvent(event, for: simulatorUDID, logger: logger)
    }

    static func performPhysicalTap(
        at point: (x: Double, y: Double),
        preDelay: Double?,
        postDelay: Double?,
        for simulatorUDID: String,
        logger: AxeLogger
    ) async throws {
        let session = try await makeSession(for: simulatorUDID, logger: logger)
        try await performPhysicalTap(at: point, preDelay: preDelay, postDelay: postDelay, in: session, logger: logger)
    }

    static func performPhysicalTap(
        at point: (x: Double, y: Double),
        preDelay: Double?,
        postDelay: Double?,
        in session: Session,
        logger: AxeLogger
    ) async throws {
        if let preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            try await Task.sleep(for: .seconds(preDelay))
        }

        let touchDownEvent = FBSimulatorHIDEvent.touch(direction: .down, x: point.x, y: point.y)
        let touchUpEvent = FBSimulatorHIDEvent.touch(direction: .up, x: point.x, y: point.y)
        var didTouchDown = false

        do {
            try await performHIDEvent(touchDownEvent, in: session, logger: logger)
            didTouchDown = true
            try await Task.sleep(for: .seconds(TapTiming.defaultHoldDuration))
            try await performHIDEvent(touchUpEvent, in: session, logger: logger)
            didTouchDown = false
        } catch {
            if didTouchDown {
                try? await performHIDEvent(touchUpEvent, in: session, logger: logger)
            }
            throw error
        }

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            try await Task.sleep(for: .seconds(postDelay))
        }
    }

    // Get or create a cached HID connection (matching CompanionLib's connectToHID behavior)
    private static func getOrCreateHIDConnection(for simulator: FBSimulator, logger: AxeLogger) async throws -> FBSimulatorHID {
        if let existingHID = hidConnections[simulator.udid] {
            logger.info().log("Using existing HID connection for simulator \(simulator.udid)")
            return existingHID
        }

        logger.info().log("Creating new HID connection for simulator \(simulator.udid)...")
        let hid = try await simulator.connectToHID()

        hidConnections[simulator.udid] = hid
        logger.info().log("HID connection created and cached for simulator \(simulator.udid)")

        return hid
    }

    static func clearHIDConnections() {
        hidConnections.removeAll()
    }
}
