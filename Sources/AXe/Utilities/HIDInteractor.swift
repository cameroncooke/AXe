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
        let inputLease: HIDInputLease
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
        let inputLease = try HIDInputLease.acquire(simulatorUDID: simulatorUDID)
        logger.info().log("Loading private frameworks for HID operations...")
        let frameworkLoader = FBSimulatorControlFrameworkLoader.xcodeFrameworks
        do {
            try frameworkLoader.loadPrivateFrameworks(logger)
            logger.info().log("Private frameworks loaded successfully.")
        } catch {
            logger.error().log("Failed to load private frameworks: \(error)")
            throw CLIError(
                errorDescription: "AXe could not initialize simulator input using the selected Xcode installation. Confirm Xcode 26 or later is selected and try again.", code: .xcodeUnavailable
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
            let stateDescription = FBiOSTargetStateStringFromState(simulator.state).rawValue
            throw CLIError(
                errorDescription: "Simulator \(simulatorUDID) is not booted. Current state: \(stateDescription).", code: .notBooted
            )
        }
        logger.info().log("Simulator state verified: booted")

        let bootIdentity = try HIDBroker.currentBootIdentity(simulatorUDID: simulatorUDID)
        let dtuhidProcessIdentifier = FBProcessFetcher().subprocess(
            of: bootIdentity.processIdentifier,
            withName: "dtuhidd"
        )
        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: bootIdentity,
            isDTUHIDSelected: dtuhidProcessIdentifier > 0,
            now: Date.init,
            sleep: { delay in try await Task.sleep(for: .seconds(delay)) }
        )
        let hid = try await getOrCreateHIDConnection(for: simulator, logger: logger)
        let connectedBootIdentity = try HIDBroker.currentBootIdentity(simulatorUDID: simulatorUDID)
        guard bootIdentity == connectedBootIdentity else {
            hidConnections.removeValue(forKey: simulatorUDID)
            throw CLIOutputFailure(code: "bootChanged", message: "Simulator \(simulatorUDID) restarted while AXe was connecting. Try the command again.")
        }
        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: connectedBootIdentity,
            isDTUHIDSelected: hid.transportType == .dtuhid,
            now: Date.init,
            sleep: { delay in try await Task.sleep(for: .seconds(delay)) }
        )
        return Session(simulatorUDID: simulatorUDID, simulator: simulator, hid: hid, inputLease: inputLease)
    }

    static func performHIDEvent(_ event: FBSimulatorHIDEvent, in session: Session, logger: AxeLogger) async throws {
        defer { withExtendedLifetime(session.inputLease) {} }
        logger.info().log("Performing HID event...")
        try await session.hid.send(event: event, logger: logger)
        logger.info().log("HID event performed successfully.")
        try await waitForStabilization(logger: logger)
    }

    static func waitForStabilization(logger: AxeLogger) async throws {
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
            throw CLIError(errorDescription: "Drag duration must be non-negative.", code: .invalidArguments)
        }
        guard steps > 0 else {
            throw CLIError(errorDescription: "Drag steps must be greater than 0.", code: .invalidArguments)
        }
        guard initialHold >= 0, finalHold >= 0 else {
            throw CLIError(errorDescription: "Drag hold durations must be non-negative.", code: .invalidArguments)
        }

        // A drag is the two-point stroke.
        return .composite(TouchStroke.primitives(
            through: [CGPoint(x: start.x, y: start.y), CGPoint(x: end.x, y: end.y)],
            duration: duration, moves: steps, initialHold: initialHold, finalHold: finalHold
        ).map(\.event))
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

        try await sendPhysicalTap(at: point) { event in
            try await performHIDEvent(event, in: session, logger: logger)
        }

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            try await Task.sleep(for: .seconds(postDelay))
        }
    }

    /// The direct route keeps its released 250 ms contact, where a 100 ms composite regressed real
    /// control actions. Broker routes hold TapTiming.defaultHoldDuration (0.1 s).
    /// Drain after UP; draining between DOWN and UP extends the contact.
    static func sendPhysicalTap(
        at point: (x: Double, y: Double),
        perform: (FBSimulatorHIDEvent) async throws -> Void
    ) async throws {
        let event = FBSimulatorHIDEvent.tapAt(x: point.x, y: point.y,
            duration: 0.25)
        do {
            try await perform(event)
        } catch {
            // A failed send can leave DOWN delivered. Release only; never replay the tap.
            try? await perform(.touch(direction: .up, x: point.x, y: point.y))
            throw error
        }
    }

    /// `axe serve` runs many commands in one process. It drops the cached connection after each, as a
    /// one-off command's exit does, so none is reused across commands or a simulator reboot.
    static func discardConnection(for simulatorUDID: String) {
        hidConnections.removeValue(forKey: simulatorUDID)
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
}
