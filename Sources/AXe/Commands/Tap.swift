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
        
        // Validate delays if provided
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
            let element: AccessibilityElement = try locateElement(in: roots)
            
            guard let frame = element.frame else {
                print("Warning: Matched element has no frame. No tap performed.", to: &standardError)
                throw CLIError(errorDescription: "Matched element has no frame.")
            }
            guard frame.width > 0, frame.height > 0 else {
                print("Warning: Matched element has an invalid frame size (\(frame.width)x\(frame.height)). No tap performed.", to: &standardError)
                throw CLIError(errorDescription: "Matched element has an invalid frame size.")
            }
            
            let centerX = frame.x + (frame.width / 2.0)
            let centerY = frame.y + (frame.height / 2.0)
            resolvedPoint = (x: centerX, y: centerY)
            resolvedDescription = "center of matched element at (\(centerX), \(centerY))"
        }
        
        logger.info().log("Tapping at \(resolvedDescription)")
        
        // Create tap events with timing controls
        var events: [FBSimulatorHIDEvent] = []
        
        // Add pre-delay if specified
        if let preDelay = preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            events.append(FBSimulatorHIDEvent.delay(preDelay))
        }
        
        // Add the main tap event
        let tapEvent = FBSimulatorHIDEvent.tapAt(x: resolvedPoint.x, y: resolvedPoint.y)
        events.append(tapEvent)
        
        // Add post-delay if specified
        if let postDelay = postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            events.append(FBSimulatorHIDEvent.delay(postDelay))
        }
        
        // Execute the tap sequence
        let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent(events: events)
        
        // Perform the tap event
        try await HIDInteractor
            .performHIDEvent(
                finalEvent,
                for: simulatorUDID,
                logger: logger
            )
        
        logger.info().log("Tap completed successfully")
        
        // Output success message to stdout
        print("✓ Tap at (\(resolvedPoint.x), \(resolvedPoint.y)) completed successfully")
    }
    
    private func locateElement(in roots: [AccessibilityElement]) throws -> AccessibilityElement {
        let allElements = roots.flatMap { $0.flattened() }
        
        if let elementID {
            let query = elementID.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedUniqueId == query }
            return try selectUniqueMatch(matches, kind: "--id", value: elementID)
        }
        
        if let elementLabel {
            let query = elementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedLabel == query }
            return try selectUniqueMatch(matches, kind: "--label", value: elementLabel)
        }
        
        throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
    }
    
    private func selectUniqueMatch(_ matches: [AccessibilityElement], kind: String, value: String) throws -> AccessibilityElement {
        guard !matches.isEmpty else {
            print("Warning: No accessibility element matched \(kind) '\(value)'. No tap performed.", to: &standardError)
            throw CLIError(errorDescription: "No accessibility element matched \(kind) '\(value)'.")
        }
        guard matches.count == 1 else {
            print("Warning: Multiple (\(matches.count)) accessibility elements matched \(kind) '\(value)'. No tap performed.", to: &standardError)
            throw CLIError(errorDescription: "Multiple accessibility elements matched \(kind) '\(value)'.")
        }
        return matches[0]
    }
}
