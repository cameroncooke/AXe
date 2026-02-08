import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Touch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform precise touch down/up events at specific coordinates.",
        discussion: """
        Perform low-level touch events for advanced gesture control.
        You can either perform a single touch down, touch up, or both.
        
        Examples:
          axe touch --x 100 --y 200 --down --udid SIMULATOR_UDID        # Touch down at (100, 200)
          axe touch --x 100 --y 200 --up --udid SIMULATOR_UDID          # Touch up at (100, 200)
          axe touch --x 100 --y 200 --down --up --udid SIMULATOR_UDID   # Touch down then up (like tap)
          axe touch --x 100 --y 200 --down --up --delay 1.0 --udid SIMULATOR_UDID # Long press (hold for 1s)
        """
    )
    
    @Option(name: .customShort("x"), help: "The X coordinate of the touch point.")
    var pointX: Double
    
    @Option(name: .customShort("y"), help: "The Y coordinate of the touch point.")
    var pointY: Double
    
    @Flag(name: .customLong("down"), help: "Perform touch down event.")
    var touchDown: Bool = false
    
    @Flag(name: .customLong("up"), help: "Perform touch up event.")
    var touchUp: Bool = false
    
    @Option(name: .customLong("delay"), help: "Delay between touch down and up events in seconds (if both are specified).")
    var delay: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    func validate() throws {
        // Validate coordinates are non-negative
        guard pointX >= 0, pointY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        
        // Validate that at least one action is specified
        guard touchDown || touchUp else {
            throw ValidationError("At least one of --down or --up must be specified.")
        }
        
        // Validate delay if provided
        if let delay = delay {
            guard delay >= 0 else {
                throw ValidationError("Delay must be non-negative.")
            }
            guard delay <= 10.0 else {
                throw ValidationError("Delay must not exceed 10 seconds.")
            }
            
            // Delay only makes sense if both down and up are specified
            guard touchDown && touchUp else {
                throw ValidationError("Delay can only be used when both --down and --up are specified.")
            }
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        
        try await performGlobalSetup(logger: logger)

        logger.info().log("Performing touch events at (\(pointX), \(pointY))")

        if touchDown && touchUp {
            // Send down and up as separate HID submissions so iOS recognizers
            // observe a real hold duration for long-press gestures.
            let touchDelay = delay ?? 0.1

            logger.info().log("Touch down")
            try await HIDInteractor
                .performHIDEvent(
                    FBSimulatorHIDEvent.touchDownAt(x: pointX, y: pointY),
                    for: simulatorUDID,
                    logger: logger
                )

            if touchDelay > 0 {
                logger.info().log("Delay: \(touchDelay) seconds")
                let delayNanoseconds = UInt64(touchDelay * 1_000_000_000)
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }

            logger.info().log("Touch up")
            try await HIDInteractor
                .performHIDEvent(
                    FBSimulatorHIDEvent.touchUpAt(x: pointX, y: pointY),
                    for: simulatorUDID,
                    logger: logger
                )
        } else if touchDown {
            logger.info().log("Touch down")
            try await HIDInteractor
                .performHIDEvent(
                    FBSimulatorHIDEvent.touchDownAt(x: pointX, y: pointY),
                    for: simulatorUDID,
                    logger: logger
                )
        } else {
            logger.info().log("Touch up")
            try await HIDInteractor
                .performHIDEvent(
                    FBSimulatorHIDEvent.touchUpAt(x: pointX, y: pointY),
                    for: simulatorUDID,
                    logger: logger
                )
        }
        
        logger.info().log("Touch events completed successfully")
    }
} 
