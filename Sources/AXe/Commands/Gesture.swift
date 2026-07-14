import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

enum GesturePreset: String, CaseIterable, ExpressibleByArgument {
    case scrollUp = "scroll-up"
    case scrollDown = "scroll-down" 
    case scrollLeft = "scroll-left"
    case scrollRight = "scroll-right"
    case swipeFromLeftEdge = "swipe-from-left-edge"
    case swipeFromRightEdge = "swipe-from-right-edge"
    case swipeFromTopEdge = "swipe-from-top-edge"
    case swipeFromBottomEdge = "swipe-from-bottom-edge"
    
    var description: String {
        switch self {
        case .scrollUp:
            return "Scroll up in the center of screen"
        case .scrollDown:
            return "Scroll down in the center of screen"
        case .scrollLeft:
            return "Scroll left in the center of screen"
        case .scrollRight:
            return "Scroll right in the center of screen"
        case .swipeFromLeftEdge:
            return "Swipe from left edge to center (back navigation)"
        case .swipeFromRightEdge:
            return "Swipe from right edge to center (forward navigation)"
        case .swipeFromTopEdge:
            return "Swipe from top edge downward"
        case .swipeFromBottomEdge:
            return "Swipe from bottom edge upward"
        }
    }
    
    func coordinates(screenWidth: Double = 390, screenHeight: Double = 844) -> (startX: Double, startY: Double, endX: Double, endY: Double) {
        let centerX = screenWidth / 2
        let centerY = screenHeight / 2
        let edgeMargin = 20.0
        let scrollDistance = 200.0
        
        switch self {
        case .scrollUp:
            return (centerX, centerY + scrollDistance/2, centerX, centerY - scrollDistance/2)
        case .scrollDown:
            return (centerX, centerY - scrollDistance/2, centerX, centerY + scrollDistance/2)
        case .scrollLeft:
            return (centerX + scrollDistance/2, centerY, centerX - scrollDistance/2, centerY)
        case .scrollRight:
            return (centerX - scrollDistance/2, centerY, centerX + scrollDistance/2, centerY)
        case .swipeFromLeftEdge:
            return (edgeMargin, centerY, screenWidth - edgeMargin, centerY)
        case .swipeFromRightEdge:
            return (screenWidth - edgeMargin, centerY, edgeMargin, centerY)
        case .swipeFromTopEdge:
            return (centerX, edgeMargin, centerX, screenHeight - edgeMargin)
        case .swipeFromBottomEdge:
            return (centerX, screenHeight - edgeMargin, centerX, edgeMargin)
        }
    }
    
    var defaultDuration: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 0.5
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge:
            return 0.3
        }
    }
    
    var defaultDelta: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 25.0
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge:
            return 50.0
        }
    }
}

struct Gesture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform preset gesture patterns on the simulator.",
        discussion: """
        Execute common gesture patterns without specifying coordinates.
        
        Available presets:
          scroll-up, scroll-down, scroll-left, scroll-right
          swipe-from-left-edge, swipe-from-right-edge
          swipe-from-top-edge, swipe-from-bottom-edge
        
        Examples:
          axe gesture scroll-up --udid SIMULATOR_UDID
          axe gesture scroll-down --duration 1.5 --udid SIMULATOR_UDID
          axe gesture swipe-from-left-edge --screen-width 430 --screen-height 932 --udid SIMULATOR_UDID
        """
    )
    
    @Argument(help: "The gesture preset to perform.")
    var preset: GesturePreset
    
    @Option(name: .customLong("screen-width"), help: "Screen width in points (default: 390 for iPhone 15).")
    var screenWidth: Double?
    
    @Option(name: .customLong("screen-height"), help: "Screen height in points (default: 844 for iPhone 15).")
    var screenHeight: Double?
    
    @Option(name: .customLong("duration"), help: "Duration of the gesture in seconds (uses preset default if not specified).")
    var duration: Double?
    
    @Option(name: .customLong("delta"), help: "Distance between touch points in pixels (uses preset default if not specified).")
    var delta: Double?
    
    @Option(name: .customLong("pre-delay"), help: "Delay before starting the gesture in seconds.")
    var preDelay: Double?
    
    @Option(name: .customLong("post-delay"), help: "Delay after completing the gesture in seconds.")
    var postDelay: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    func validate() throws {
        // Validate screen dimensions if provided
        if let screenWidth = screenWidth {
            guard screenWidth > 0 && screenWidth <= 2000 else {
                throw ValidationError("Screen width must be between 1 and 2000 points.")
            }
        }
        
        if let screenHeight = screenHeight {
            guard screenHeight > 0 && screenHeight <= 3000 else {
                throw ValidationError("Screen height must be between 1 and 3000 points.")
            }
        }
        
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 && duration <= 10.0 else {
                throw ValidationError("Duration must be between 0 and 10 seconds.")
            }
        }
        
        // Validate delta if provided
        if let delta = delta {
            guard delta > 0 && delta <= 200 else {
                throw ValidationError("Delta must be between 1 and 200 pixels.")
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

        // Use provided dimensions or defaults
        let width = screenWidth ?? 390.0
        let height = screenHeight ?? 844.0
        
        // Get gesture coordinates
        let coords = preset.coordinates(screenWidth: width, screenHeight: height)
        
        // Use provided values or preset defaults
        let gestureDuration = duration ?? preset.defaultDuration
        let gestureDelta = delta ?? preset.defaultDelta
        
        logger.info().log("Performing \(preset.description)")
        logger.info().log("Screen size: \(width)x\(height)")
        logger.info().log("Coordinates: (\(coords.startX), \(coords.startY)) to (\(coords.endX), \(coords.endY))")
        logger.info().log("Duration: \(gestureDuration)s, Delta: \(gestureDelta)px")
        
        // Create gesture events with timing controls
        var events: [FBSimulatorHIDEvent] = []
        
        // Add pre-delay if specified
        if let preDelay = preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            events.append(FBSimulatorHIDEvent.delay(preDelay))
        }
        
        // Add the main gesture
        let gestureEvent = FBSimulatorHIDEvent.swipe(
            coords.startX,
            yStart: coords.startY,
            xEnd: coords.endX,
            yEnd: coords.endY,
            delta: gestureDelta,
            duration: gestureDuration
        )
        events.append(gestureEvent)
        
        // Add post-delay if specified
        if let postDelay = postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            events.append(FBSimulatorHIDEvent.delay(postDelay))
        }
        
        // Execute the gesture sequence
        let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent.composite(events)
        
        try await HIDInteractor
            .performHIDEvent(
                finalEvent,
                for: simulatorUDID,
                logger: logger
            )
        
        logger.info().log("Gesture completed successfully")
    }
} 
