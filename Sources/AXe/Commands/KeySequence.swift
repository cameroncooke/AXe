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
        Agent mode requires a current focused TextField snapshot/ref; --expected-pid is optional.
        It checks focus before each key down; input is never replayed automatically.
        
        Examples:
          axe key-sequence --keycodes 11,8,15,15,18 --udid SIMULATOR_UDID    # Type "hello"
          axe key-sequence --keycodes 40,40,40 --udid SIMULATOR_UDID        # Press Enter 3 times
          axe key-sequence --keycodes 42,42 --agent --snapshot-id SNAPSHOT_ID --ref e1 --udid SIMULATOR_UDID
        """
    )
    
    @Option(name: .customLong("keycodes"), help: "Comma-separated list of HID keycodes to press in sequence.")
    var keycodesString: String
    
    @Option(name: .customLong("delay"), help: "Delay between key presses in seconds (default: 0.1).")
    var delay: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String
    
    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedKeyboard: SelectedKeyboardOptions
    @OptionGroup var agentMode: AgentModeOptions

    func validate() throws {
        try agentMode.validate()
        if agentMode.enabled {
            try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: selectedKeyboard.expectedPID)
            guard agentMode.elementRef != nil, selectedKeyboard.focusID == nil else {
                throw ValidationError("Agent key-sequence requires --snapshot-id and --ref for an already focused TextField, with no --focus-id.")
            }
        } else {
            try selectedKeyboard.validate(input: selectedInput)
        }
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
        if agentMode.enabled {
            let keyDelay = delay ?? 0.1
            guard keyDelay.isFinite, keyDelay * Double(parsedKeycodes.count - 1) <= 20 else {
                throw ValidationError("Agent key-sequence requires finite delays with at most 20 seconds in total.")
            }
        }
    }

    func agentRequest() throws -> SelectedHIDRequest {
        let events = try SelectedKeyboardRequest.primitives(from: selectedKeyboardEvent())
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .keySequence,
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
        let sequenceEvent = FBSimulatorHIDEvent.composite(events)
        
        // Perform the key sequence event
        try await LegacyDuoInput.performKeyboard(
            sequenceEvent, simulatorUDID: simulatorUDID, logger: logger
        )
        
        logger.info().log("Key sequence completed successfully")
    }

    func selectedKeyboardEvent() throws -> FBSimulatorHIDEvent {
        try validate()
        let codes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        var events: [FBSimulatorHIDEvent] = []
        for (index, code) in codes.enumerated() {
            events.append(.shortKeyPress(UInt32(code)))
            if index < codes.count - 1, (delay ?? 0.1) > 0 { events.append(.delay(delay ?? 0.1)) }
        }
        return .composite(events)
    }
} 
