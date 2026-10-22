import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Key: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a single key by keycode on the simulator.",
        discussion: """
        Press individual keys using their HID keycode values.
        Agent mode sends one default down/up to a current focused TextField reference.
        It requires --snapshot-id, --ref and --expected-pid; duration and batch use reject.
        
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
    
    @Option(name: .customLong("duration"), help: "Duration to hold the key in seconds (optional; unavailable with --agent).")
    var duration: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedKeyboard: SelectedKeyboardOptions
    @OptionGroup var agentMode: AgentModeOptions

    func validate() throws {
        try agentMode.validate()
        if agentMode.enabled {
            try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: selectedKeyboard.expectedPID)
            guard agentMode.elementRef != nil, selectedKeyboard.focusID == nil, duration == nil else {
                throw ValidationError("Agent key requires --snapshot-id and --ref for an already focused TextField, with no --focus-id or --duration.")
            }
        } else {
            try selectedKeyboard.validate(input: selectedInput)
        }
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

    func agentRequest() throws -> SelectedHIDRequest {
        let events = try SelectedKeyboardRequest.primitives(from: selectedKeyboardEvent())
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .keyPress,
            expectedPID: selectedKeyboard.expectedPID, snapshotID: agentMode.snapshotID,
            ref: agentMode.elementRef, keyEvents: events), input: selectedInput)
    }

    func run() async throws {
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            try selectedKeyboard.send(input: selectedInput, event: selectedKeyboardEvent(), simulatorUDID: simulatorUDID)
            return
        }
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

    func selectedKeyboardEvent() throws -> FBSimulatorHIDEvent {
        try validate()
        if let duration {
            return .composite([.keyboard(direction: .down, keyCode: UInt32(keycode)),
                .delay(duration), .keyboard(direction: .up, keyCode: UInt32(keycode))])
        }
        return .shortKeyPress(UInt32(keycode))
    }
} 
