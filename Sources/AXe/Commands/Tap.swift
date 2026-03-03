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

    @Option(name: .customLong("pre-delay"), help: "Delay before tapping in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after tapping in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    func validate() throws {
        if pointX != nil || pointY != nil {
            guard let pointX, let pointY else {
                throw ValidationError("Both -x and -y must be provided together.")
            }
            guard pointX >= 0, pointY >= 0 else {
                throw ValidationError("Coordinates must be non-negative values.")
            }
        } else {
            if elementID == nil && elementLabel == nil {
                throw ValidationError("Either provide both -x/-y, or use --id/--label to tap an element.")
            }
            if elementID != nil && elementLabel != nil {
                throw ValidationError("Use only one of --id or --label.")
            }
            if let elementID, elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--id must not be empty.")
            }
            if let elementLabel, elementLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--label must not be empty.")
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
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)

        try await performGlobalSetup(logger: logger)

        let resolvedPoint: (x: Double, y: Double)
        let resolvedDescription: String

        if let pointX, let pointY {
            resolvedPoint = (x: pointX, y: pointY)
            resolvedDescription = "(\(pointX), \(pointY))"
        } else {
            let roots = try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            do {
                resolvedPoint = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: query)
            } catch let error as CLIError {
                print("Warning: \(error.errorDescription) No tap performed.", to: &standardError)
                throw error
            }

            resolvedDescription = "center of matched element at (\(resolvedPoint.x), \(resolvedPoint.y))"
        }

        logger.info().log("Tapping at \(resolvedDescription)")

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
