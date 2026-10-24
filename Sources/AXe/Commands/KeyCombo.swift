import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct KeyCombo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a key while holding one or more modifier keys on the simulator.",
        discussion: """
        Hold modifier keys and press another key as one complete sequence.
        Agent mode requires a current focused TextField snapshot/ref and --expected-pid.
        It checks focus before each key down; OS recipient control is not atomic.
        Modifier keys are held down, the target key is pressed and released,
        then modifier keys are released in reverse order (LIFO).

        Common modifier keycodes:
          224 - Left Control
          225 - Left Shift
          226 - Left Alt/Option
          227 - Left Command (GUI)
          228 - Right Control
          229 - Right Shift
          230 - Right Alt/Option
          231 - Right Command (GUI)

        Examples:
          axe key-combo --modifiers 227 --key 4 --udid SIMULATOR_UDID          # Cmd+A (Select All)
          axe key-combo --modifiers 227 --key 6 --udid SIMULATOR_UDID          # Cmd+C (Copy)
          axe key-combo --modifiers 227 --key 25 --udid SIMULATOR_UDID         # Cmd+V (Paste)
          axe key-combo --modifiers 227,225 --key 4 --udid SIMULATOR_UDID      # Cmd+Shift+A
        """
    )

    @Option(name: .customLong("modifiers"), help: "Comma-separated list of modifier keycodes to hold (0-255).")
    var modifiersString: String

    @Option(name: .customLong("key"), help: "The HID keycode to press while modifiers are held (0-255).")
    var key: Int

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
                throw ValidationError("Agent key-combo requires --snapshot-id and --ref for an already focused TextField, with no --focus-id.")
            }
        } else {
            try selectedKeyboard.validate(input: selectedInput)
        }
        let parsedModifiers = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")

        guard !parsedModifiers.isEmpty else {
            throw ValidationError("At least one modifier keycode must be provided.")
        }

        guard parsedModifiers.count <= 8 else {
            throw ValidationError("At most 8 modifier keycodes may be provided.")
        }

        for keycode in parsedModifiers {
            guard keycode >= 0 && keycode <= 255 else {
                throw ValidationError("All modifier keycodes must be between 0 and 255. Invalid keycode: \(keycode)")
            }
        }

        guard key >= 0 && key <= 255 else {
            throw ValidationError("Key must be between 0 and 255.")
        }
    }

    func agentRequest() throws -> SelectedHIDRequest {
        let events = try SelectedKeyboardRequest.primitives(from: selectedKeyboardEvent())
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .keyCombo,
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

        let parsedModifiers = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")

        logger.info().log("Pressing key combo: modifiers=\(parsedModifiers), key=\(key)")

        // Build composite event:
        //   modifierDown1, modifierDown2, ..., shortKeyPress(key), ..., modifierUp2, modifierUp1
        var events: [FBSimulatorHIDEvent] = []

        // Press modifiers down in order
        for modifier in parsedModifiers {
            events.append(FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: UInt32(modifier)))
        }

        // Press and release the target key
        events.append(FBSimulatorHIDEvent.shortKeyPress(UInt32(key)))

        // Release modifiers in reverse order
        for modifier in parsedModifiers.reversed() {
            events.append(FBSimulatorHIDEvent.keyboard(direction: .up, keyCode: UInt32(modifier)))
        }

        let comboEvent = FBSimulatorHIDEvent.composite(events)

        try await LegacyDuoInput.performKeyboard(
            comboEvent, simulatorUDID: simulatorUDID, logger: logger
        )

        logger.info().log("Key combo completed successfully")
    }

    func selectedKeyboardEvent() throws -> FBSimulatorHIDEvent {
        try validate()
        let codes = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")
        guard codes.allSatisfy({ (224...231).contains($0) }) else {
            throw ValidationError("Selected key-combo modifiers must be HID modifier keys 224...231.")
        }
        return .composite(codes.map { .keyboard(direction: .down, keyCode: UInt32($0)) }
            + [.shortKeyPress(UInt32(key))]
            + codes.reversed().map { .keyboard(direction: .up, keyCode: UInt32($0)) })
    }
}
