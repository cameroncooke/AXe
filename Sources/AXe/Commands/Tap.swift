import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tap on a specific point on the screen, or locate an element by accessibility and tap its center."
    )

    @Option(name: .customShort("x"), help: "The X coordinate of the point to tap.")
    var pointX: Double?

    @Option(name: .customShort("y"), help: "The Y coordinate of the point to tap.")
    var pointY: Double?

    @Option(name: [.customLong("id")], help: "Tap the center of the element matching AXUniqueId (accessibilityIdentifier). Ignored if -x and -y are provided.")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "Tap the center of the element matching AXLabel (accessibilityLabel). Ignored if -x and -y are provided.")
    var elementLabel: String?

    @Option(name: [.customLong("value")], help: "Tap the center of the element matching AXValue (the current value of a control). Ignored if -x and -y are provided.")
    var elementValue: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to elements of this accessibility type (e.g. Button, TextField, Switch). Narrows --id/--label/--value results when multiple elements match.")
    var elementType: String?

    @Option(name: .customLong("pre-delay"), help: "Delay before tapping in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after tapping in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the element before failing (0 = no waiting, default). Only applies to --id/--label/--value targeting.")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    var pollInterval: Double = 0.25

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Flag(name: .customLong("landscape-flipped"), help: "Treat coordinates as logical landscape-flipped (home button left / 90° CCW). Use when the device is rotated counter-clockwise and the default landscape detection is incorrect.")
    var landscapeFlipped: Bool = false

    func validate() throws {
        if pointX != nil || pointY != nil {
            guard let pointX, let pointY else {
                throw ValidationError("Both -x and -y must be provided together.")
            }
            guard pointX >= 0, pointY >= 0 else {
                throw ValidationError("Coordinates must be non-negative values.")
            }
        } else {
            let selectorCount = [elementID != nil, elementLabel != nil, elementValue != nil].filter { $0 }.count
            if selectorCount == 0 {
                throw ValidationError("Either provide both -x/-y, or use --id/--label/--value to tap an element.")
            }
            if selectorCount > 1 {
                throw ValidationError("Use only one of --id, --label, or --value.")
            }
            if let elementID, elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--id must not be empty.")
            }
            if let elementLabel, elementLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--label must not be empty.")
            }
            if let elementValue, elementValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--value must not be empty.")
            }
        }

        if let preDelay = preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }

        if let postDelay = postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("Post-delay must be between 0 and 10 seconds.")
            }
        }

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)

        try await performGlobalSetup(logger: logger)

        let logicalPoint: (x: Double, y: Double)
        let resolvedDescription: String

        if let pointX, let pointY {
            logicalPoint = (x: pointX, y: pointY)
            resolvedDescription = "(\(pointX), \(pointY))"
        } else {
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else if let elementValue {
                query = .value(elementValue)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            do {
                logicalPoint = try await AccessibilityPoller.resolveWithPolling(
                    query: query,
                    simulatorUDID: simulatorUDID,
                    waitTimeout: waitTimeout,
                    pollInterval: pollInterval,
                    elementType: elementType,
                    logger: logger
                )
            } catch let error as ElementResolutionError {
                print("Warning: \(error.localizedDescription) No tap performed.", to: &standardError)
                throw error
            }

            resolvedDescription = "center of matched element at (\(logicalPoint.x), \(logicalPoint.y))"
        }

        logger.info().log("Tapping at \(resolvedDescription)")

        let orientationOverride: SimulatorOrientation? = landscapeFlipped ? .landscapeFlipped : nil
        let resolvedPoint = try await OrientationAwareCoordinates.translate(
            point: logicalPoint,
            for: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )

        var events: [FBSimulatorHIDEvent] = []
        if let preDelay = preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            events.append(.delay(preDelay))
        }

        events.append(.tapAt(x: resolvedPoint.x, y: resolvedPoint.y))

        if let postDelay = postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            events.append(.delay(postDelay))
        }

        let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent(events: events)

        try await HIDInteractor.performHIDEvent(finalEvent, for: simulatorUDID, logger: logger)

        logger.info().log("Tap completed successfully")
        print("✓ Tap at (\(resolvedPoint.x), \(resolvedPoint.y)) completed successfully")
    }
}
