import Foundation
import FBControlCore
import FBSimulatorControl

/// Keep the legacy CLI surface while using the measured input owner on the verified Duo.
enum LegacyDuoInput {
    static let duoDeviceTypeIdentifier = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"

    /// The measured context for the shared input owner, and whether it belongs to the Duo.
    struct Route {
        let context: SelectedHIDContext
        let isDuo: Bool
    }

    @MainActor
    static func isDuo(_ simulator: FBSimulator) -> Bool {
        simulator.device.deviceType?.identifier == duoDeviceTypeIdentifier
    }

    /// Refuses a Duo profile whose hinge capability is not the verified one.
    @MainActor
    static func requireVerifiedDuo(_ simulator: FBSimulator) throws {
        let capability = try FBSimulatorNativeContextReader.capability(for: simulator)
        guard capability.hinge == .supported else { throw SelectedHIDFailure.invalid(capability.reason) }
    }

    /// Missing rigid-profile metadata cannot establish support for the measured route.
    @MainActor
    private static func hasProfileMetadata(_ simulator: FBSimulator) -> Bool {
        guard let type = simulator.device.deviceType, let bundle = type.bundle,
              type.identifier != nil, type.modelIdentifier != nil,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") is String,
              bundle.url(forResource: "capabilities", withExtension: "plist") != nil else { return false }
        return true
    }

    /// Nil keeps the caller's existing route. Verified DTUHID rigid devices join the Duo only
    /// when the caller asks: their own guest connection costs about 0.6 s to open and 0.4 s to
    /// drain per command, which the broker's retained connection avoids.
    @MainActor
    static func captureRoute(
        simulatorUDID: String,
        preDelay: Double?,
        logger: AxeLogger,
        forKeyboard: Bool = false,
        includeVerifiedRigid: Bool = false
    ) async throws -> Route? {
        let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
        if forKeyboard || includeVerifiedRigid {
            // Duo and verified DTUHID profiles share the broker's retained connection.
            guard try usesSharedKeyboardOwner(for: simulator) else { return nil }
        } else {
            // Older rigid-device input keeps its existing route.
            guard isDuo(simulator) else { return nil }
            try requireVerifiedDuo(simulator)
        }
        try await wait(preDelay)
        let discovery = try await ActivePanelReader.discoverWithMetadata(for: simulator)
        let panel = discovery.readback.snapshot.activePanel.identity
        let reader = FBSimulatorNativeContextReader(
            simulator: simulator, screenID: panel.displayID,
            screenUniqueID: panel.uniqueID
        )
        let observation = try await reader.observation()
        guard observation.bootIdentity == discovery.bootIdentity else {
            throw SelectedHIDFailure.invalid("Simulator boot changed during input preparation")
        }
        return Route(context: SelectedHIDContext(observation), isDuo: isDuo(simulator))
    }

    /// One policy shared by caller capture and broker admission. Rigid Indigo and unknown
    /// profiles keep their existing route; a measured read failure never changes routes.
    @MainActor
    static func usesSharedKeyboardOwner(for simulator: FBSimulator) throws -> Bool {
        if isDuo(simulator) {
            try requireVerifiedDuo(simulator)
            return true
        }
        let boot = try HIDBroker.currentBootIdentity(simulatorUDID: simulator.udid)
        let dtuhidPID = FBProcessFetcher().subprocess(of: boot.processIdentifier, withName: "dtuhidd")
        guard dtuhidPID > 0, hasProfileMetadata(simulator) else { return false }
        return try FBSimulatorNativeContextReader.capability(for: simulator).hinge == .unsupported
    }

    /// Choose the Slider route before input. Older profiles keep their existing raw path.
    /// This discovery returns only a display pair; the broker performs full live admission.
    @MainActor
    static func captureSliderDisplay(
        simulatorUDID: String,
        hasStableIdentifier: Bool,
        logger: AxeLogger
    ) async throws -> ActivePanelIdentity? {
        let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
        let duo = isDuo(simulator)
        guard hasProfileMetadata(simulator) else {
            guard !duo else { throw SelectedHIDFailure.invalid("Duo device type metadata is unavailable") }
            return nil
        }
        let capability = try FBSimulatorNativeContextReader.capability(for: simulator)
        if duo {
            // Preserve the existing refusal for an unverified Duo profile.
            guard capability.hinge == .supported else { throw SelectedHIDFailure.invalid(capability.reason) }
        } else {
            // Raw label lookup can select one actionable control beside a matching text label.
            // Keep that rigid-device path until an exact native ID can bind the resolved control.
            guard capability.hinge == .unsupported, hasStableIdentifier else { return nil }
        }
        let discovery = try await ActivePanelReader.discoverWithMetadata(for: simulator)
        return discovery.readback.snapshot.activePanel.identity
    }

    @MainActor
    static func performKeyboard(
        _ event: FBSimulatorHIDEvent,
        simulatorUDID: String,
        logger: AxeLogger,
        persistentOrdinaryKeyboard: Bool = false,
        verbose: Bool = false
    ) async throws {
        guard let context = try await captureRoute(
            simulatorUDID: simulatorUDID, preDelay: nil, logger: logger, forKeyboard: true
        )?.context else {
            if persistentOrdinaryKeyboard {
                try HIDBroker.sendKeyboardEvent(event, simulatorUDID: simulatorUDID)
            } else {
                try await HIDInteractor.performHIDEvent(event, for: simulatorUDID, logger: logger)
            }
            return
        }
        guard let uuid = UUID(uuidString: context.screenUUID) else {
            throw SelectedHIDFailure.invalid("Invalid measured display identity")
        }
        let endpoint = try SelectedHIDBroker.endpoint(simulatorUDID: simulatorUDID)
        let requestID = UUID()
        let keyboard = try LegacyDuoKeyboard.prepare(event, requestID: requestID, endpoint: endpoint)
        defer { try? keyboard.removeIfOwned(endpoint: endpoint) }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: requestID,
            screenID: context.screenID, screenUUID: uuid, operation: .complete, token: nil,
            primitives: [], expectedContext: context, legacyKeyboard: keyboard)
        try await SignalScope.cancellingOnSignal {
            try await send(request, simulatorUDID: simulatorUDID, postDelay: nil, verbose: verbose)
        }
    }

    static func perform(
        at point: (x: Double, y: Double),
        style: TapStyle,
        context: SelectedHIDContext,
        simulatorUDID: String,
        postDelay: Double?,
        logger: AxeLogger,
        verbose: Bool = false
    ) async throws {
        let selectedStyle: SelectedTapStyle
        switch style {
        case .physical: selectedStyle = .physical
        case .simulator: selectedStyle = .simulator
        case .automatic: throw SelectedHIDFailure.invalid("Ordinary tap requires a resolved style")
        }
        guard let uuid = UUID(uuidString: context.screenUUID) else {
            throw SelectedHIDFailure.invalid("Invalid measured display identity")
        }
        let request = SelectedHIDRequest(
            version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: context.screenID, screenUUID: uuid, operation: .complete, token: nil,
            primitives: try selectedStyle.primitives(x: point.x, y: point.y),
            expectedContext: context
        )
        logger.info().log("Tap uses screen \(context.screenID), rotation \(context.rotationDegrees), logical point (\(point.x), \(point.y))")
        try await send(request, simulatorUDID: simulatorUDID, postDelay: postDelay, verbose: verbose)
    }

    static func perform(
        path: LegacyDuoPath,
        context: SelectedHIDContext,
        simulatorUDID: String,
        postDelay: Double?,
        logger: AxeLogger,
        verbose: Bool = false
    ) async throws {
        guard let uuid = UUID(uuidString: context.screenUUID) else {
            throw SelectedHIDFailure.invalid("Invalid measured display identity")
        }
        let request = SelectedHIDRequest(
            version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: context.screenID, screenUUID: uuid, operation: .complete, token: nil,
            primitives: [], expectedContext: context, legacyPath: path
        )
        logger.info().log("\(path.kind.rawValue.capitalized) uses screen \(context.screenID), rotation \(context.rotationDegrees), logical endpoints")
        try await send(request, simulatorUDID: simulatorUDID, postDelay: postDelay, verbose: verbose)
    }

    static func perform(
        touch: LegacyDuoTouch,
        context: SelectedHIDContext,
        simulatorUDID: String,
        logger: AxeLogger,
        verbose: Bool = false
    ) async throws {
        try touch.validate()
        guard let uuid = UUID(uuidString: context.screenUUID) else {
            throw SelectedHIDFailure.invalid("Invalid measured display identity")
        }
        let request = SelectedHIDRequest(
            version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: context.screenID, screenUUID: uuid, operation: .complete, token: nil,
            primitives: [], expectedContext: context, legacyTouch: touch
        )
        if touch.down { logger.info().log("Touch down") }
        if touch.down && touch.up {
            let hold = touch.delay ?? TapTiming.defaultHoldDuration
            if hold > 0 { logger.info().log("Delay: \(hold) seconds") }
        }
        if touch.up { logger.info().log("Touch up") }
        try await send(request, simulatorUDID: simulatorUDID, postDelay: nil, verbose: verbose)
    }

    /// `verbose` prints the broker receipt before the result; the failure and its code are the same.
    private static func send(
        _ request: SelectedHIDRequest,
        simulatorUDID: String,
        postDelay: Double?,
        verbose: Bool
    ) async throws {
        let response: SelectedHIDResponse
        if request.legacyKeyboard != nil {
            response = try await SelectedHIDBroker.sendLegacyKeyboard(request, simulatorUDID: simulatorUDID)
        } else {
            response = try SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID)
        }
        if verbose { try SelectedHIDBroker.writeReceipt(response) }
        guard response.error == nil, response.cleanup != "uncertain", response.quarantine == nil else {
            throw SelectedInputOutput.failure(response)
        }
        try await wait(postDelay)
    }

    private static func wait(_ seconds: Double?) async throws {
        guard let seconds, seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
