import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Swipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform a swipe gesture from one point to another on the screen."
    )
    
    @Option(name: .customLong("start-x"), help: "The X coordinate of the starting point.")
    var startX: Double
    
    @Option(name: .customLong("start-y"), help: "The Y coordinate of the starting point.")
    var startY: Double
    
    @Option(name: .customLong("end-x"), help: "The X coordinate of the ending point.")
    var endX: Double
    
    @Option(name: .customLong("end-y"), help: "The Y coordinate of the ending point.")
    var endY: Double
    
    @Option(name: .customLong("duration"), help: "Duration of the swipe in seconds.")
    var duration: Double?
    
    @Option(name: .customLong("delta"), help: "Distance between touch points in pixels.")
    var delta: Double?
    
    @Option(name: .customLong("pre-delay"), help: "Delay before starting the swipe in seconds.")
    var preDelay: Double?
    
    @Option(name: .customLong("post-delay"), help: "Delay after completing the swipe in seconds.")
    var postDelay: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Flag(name: .customLong("landscape-flipped"), help: "Treat coordinates as logical landscape-flipped (home button left / 90° CCW). Use when the device is rotated counter-clockwise and the default landscape detection is incorrect.")
    var landscapeFlipped: Bool = false

    func validate() throws {
        // Validate coordinates are non-negative
        guard startX >= 0, startY >= 0, endX >= 0, endY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
        }
        
        // Validate delta if provided
        if let delta = delta {
            guard delta > 0 else {
                throw ValidationError("Delta must be greater than 0.")
            }
        }
        
        // Validate that start and end points are different
        guard startX != endX || startY != endY else {
            throw ValidationError("Start and end points must be different.")
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

        // Use default values if not provided
        let swipeDuration = duration ?? 1.0  // Default 1 second
        let swipeDelta = delta ?? 50.0       // Default 50 pixels
        
        logger.info().log("Performing swipe from (\(startX), \(startY)) to (\(endX), \(endY))")
        logger.info().log("Duration: \(swipeDuration)s, Delta: \(swipeDelta)px")

        let orientationOverride: SimulatorOrientation? = landscapeFlipped ? .landscapeFlipped : nil
        let physicalPoints = try await OrientationAwareCoordinates.translateBatch(
            points: [(x: startX, y: startY), (x: endX, y: endY)],
            for: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )
        let physicalStart = physicalPoints[0]
        let physicalEnd = physicalPoints[1]

        // Broadcast swipe notification for external listeners
        NotificationCenter.default.post(
            name: .hidSwipePerformed,
            object: nil,
            userInfo: [
                "startX": startX,
                "startY": startY,
                "endX": endX,
                "endY": endY,
                "duration": swipeDuration,
                "delta": swipeDelta
            ]
        )

        // Create swipe events with timing controls
        var events: [FBSimulatorHIDEvent] = []
        
        // Add pre-delay if specified
        if let preDelay = preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            events.append(FBSimulatorHIDEvent.delay(preDelay))
        }
        
        // Create main swipe HID event
        let swipeEvent = FBSimulatorHIDEvent.swipe(
            physicalStart.x,
            yStart: physicalStart.y,
            xEnd: physicalEnd.x,
            yEnd: physicalEnd.y,
            delta: swipeDelta,
            duration: swipeDuration
        )
        events.append(swipeEvent)
        
        // Add post-delay if specified
        if let postDelay = postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            events.append(FBSimulatorHIDEvent.delay(postDelay))
        }
        
        // Execute the swipe sequence
        let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent(events: events)
        
        // Perform the swipe event
        try await HIDInteractor
            .performHIDEvent(
                finalEvent,
                for: simulatorUDID,
                logger: logger
            )
        
        logger.info().log("Swipe gesture completed successfully")
    }
}

// MARK: - Notification Extension
extension Notification.Name {
    static let hidSwipePerformed = Notification.Name("hidSwipePerformed")
} 
