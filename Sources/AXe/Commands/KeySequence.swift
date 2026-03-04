import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct KeySequence: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a sequence of keys by their keycodes on the simulator.",
        discussion: """
        Press multiple keys in sequence using their HID keycode values.
        Each key will be pressed and released before the next key is pressed.
        
        Examples:
          axe key-sequence 11,8,15,15,18 --udid SIMULATOR_UDID    # Type "hello" (h=11, e=8, l=15, l=15, o=18)
          axe key-sequence 40,40,40 --udid SIMULATOR_UDID          # Press Enter 3 times
          axe key-sequence 224,4,225 --udid SIMULATOR_UDID        # Ctrl+A (Ctrl=224, A=4, release Ctrl=225)
        """
    )
    
    @Option(name: .customLong("keycodes"), help: "Comma-separated list of HID keycodes to press in sequence.")
    var keycodesString: String
    
    @Option(name: .customLong("delay"), help: "Delay between key presses in seconds (default: 0.1).")
    var delay: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String
    
    func validate() throws {
        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        
        // Validate that we have at least one keycode
        guard !parsedKeycodes.isEmpty else {
            throw ValidationError("At least one keycode must be provided.")
        }
        
        // Validate that all keycodes are in valid range
        for keycode in parsedKeycodes {
            guard keycode >= 0 && keycode <= 255 else {
                throw ValidationError("All keycodes must be between 0 and 255. Invalid keycode: \(keycode)")
            }
        }
        
        // Validate delay if provided
        if let delay = delay {
            guard delay >= 0 else {
                throw ValidationError("Delay must be non-negative.")
            }
            guard delay <= 5.0 else {
                throw ValidationError("Delay must not exceed 5 seconds.")
            }
        }
        
        // Validate sequence length
        guard parsedKeycodes.count <= 100 else {
            throw ValidationError("Key sequence must not exceed 100 keys.")
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        
        try await performGlobalSetup(logger: logger)

        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        let keyDelay = delay ?? 0.1  // Default 100ms delay between keys
        
        logger.info().log("Pressing key sequence: \(parsedKeycodes)")
        logger.info().log("Delay between keys: \(keyDelay) seconds")

        // Create sequence of key events
        var events: [FBSimulatorHIDEvent] = []
        
        for (index, keycode) in parsedKeycodes.enumerated() {
            // Add key press event
            let keyEvent = FBSimulatorHIDEvent.shortKeyPress(UInt32(keycode))
            events.append(keyEvent)
            
            // Add delay between keys (except after the last key)
            if index < parsedKeycodes.count - 1 && keyDelay > 0 {
                let delayEvent = FBSimulatorHIDEvent.delay(keyDelay)
                events.append(delayEvent)
            }
        }
        
        // Create composite event
        let sequenceEvent = FBSimulatorHIDEvent(events: events)
        
        // Perform the key sequence event
        try await HIDInteractor
            .performHIDEvent(
                sequenceEvent,
                for: simulatorUDID,
                logger: logger
            )
        
        logger.info().log("Key sequence completed successfully")
    }
} 
