import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Key: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a single key by keycode on the simulator.",
        discussion: """
        Press individual keys using their HID keycode values.
        
        Common keycodes:
          40 - Return/Enter
          42 - Backspace
          43 - Tab
          44 - Space
          58-67 - F1-F10
          224-231 - Modifier keys (Ctrl, Shift, Alt, etc.)
        
        Examples:
          axe key 40 --udid SIMULATOR_UDID                    # Press Enter
          axe key 44 --udid SIMULATOR_UDID                    # Press Space
          axe key 42 --duration 1.0 --udid SIMULATOR_UDID    # Hold Backspace for 1 second
        """
    )
    
    @Argument(help: "The HID keycode to press (0-255).")
    var keycode: Int
    
    @Option(name: .customLong("duration"), help: "Duration to hold the key in seconds (optional).")
    var duration: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    func validate() throws {
        // Validate keycode range
        guard keycode >= 0 && keycode <= 255 else {
            throw ValidationError("Keycode must be between 0 and 255.")
        }
        
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            guard duration <= 10.0 else {
                throw ValidationError("Duration must not exceed 10 seconds.")
            }
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        
        try await performGlobalSetup(logger: logger)

        logger.info().log("Pressing key with keycode: \(keycode)")
        if let duration = duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        // Create key HID event
        let keyEvent: FBSimulatorHIDEvent
        
        if let duration = duration {
            // For duration-based presses, we need to create separate down/up events with delay
            let keyDownEvent = FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: UInt32(keycode))
            let delayEvent = FBSimulatorHIDEvent.delay(duration)
            let keyUpEvent = FBSimulatorHIDEvent.keyboard(direction: .up, keyCode: UInt32(keycode))

            keyEvent = FBSimulatorHIDEvent.composite([
                keyDownEvent,
                delayEvent,
                keyUpEvent
            ])
        } else {
            // Simple short key press
            keyEvent = FBSimulatorHIDEvent.shortKeyPress(UInt32(keycode))
        }
        
        // Perform the key event
        try await HIDInteractor
            .performHIDEvent(
                keyEvent,
                for: simulatorUDID,
                logger: logger
            )
        
        logger.info().log("Key press completed successfully")
    }
} 
