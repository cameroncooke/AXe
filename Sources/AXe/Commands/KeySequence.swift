import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct KeySequence: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a sequence of keys by their keycodes on a simulator or physical device.",
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
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator or physical device.")
    var simulatorUDID: String
    
    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions
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
        let events = try KeyboardPrimitives.from(selectedKeyboardEvent())
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .keySequence,
            expectedPID: selectedKeyboard.expectedPID, snapshotID: agentMode.snapshotID,
            ref: agentMode.elementRef, keyEvents: events), input: selectedInput)
    }

    func validateOnDevice(inBatch: Bool) throws {
        try selectedInput.refuseOnDevice(agent: agentMode.enabled,
            "Physical key sequences do not support agent or selected display options.")
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        let codes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        let steps = codes.enumerated().flatMap { index, code in
            let interval = index + 1 < codes.count ? delay ?? 0.1 : 0
            return [PhysicalKeyStep(code: UInt64(code), pressed: true),
                    PhysicalKeyStep(code: UInt64(code), pressed: false, delayAfter: interval)]
        }
        try await input.keys(steps)
    }

    func run() async throws {
        if try await runOnDeviceIfTargeted() { return }
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            try selectedKeyboard.send(input: selectedInput, event: selectedKeyboardEvent(), simulatorUDID: simulatorUDID,
                verbose: selectedOutput.verbose)
            return
        }
        let logger = AxeLogger()
        try await setup(logger: logger)
        
        try await performGlobalSetup(logger: logger)

        logger.info().log("Pressing key sequence: \(keycodesString)")
        logger.info().log("Delay between keys: \(delay ?? 0.1) seconds")

        try await OrdinaryBrokerInput.performKeyboard(
            try hidEvent(), simulatorUDID: simulatorUDID, logger: logger, verbose: selectedOutput.verbose
        )
        
        logger.info().log("Key sequence completed successfully")
    }

    /// Each key pressed and released, with the delay (default 0.1 s) between keys.
    func hidEvent() throws -> FBSimulatorHIDEvent {
        let codes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        let keyDelay = delay ?? 0.1
        var events: [FBSimulatorHIDEvent] = []
        for (index, code) in codes.enumerated() {
            events.append(.shortKeyPress(UInt32(code)))
            if index < codes.count - 1, keyDelay > 0 { events.append(.delay(keyDelay)) }
        }
        return .composite(events)
    }

    func selectedKeyboardEvent() throws -> FBSimulatorHIDEvent {
        try validate()
        return try hidEvent()
    }
} 
