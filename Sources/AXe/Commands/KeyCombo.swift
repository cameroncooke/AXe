import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct KeyCombo: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a key while holding one or more modifier keys on a simulator or physical device.",
        discussion: """
        Hold modifier keys and press another key as one complete sequence.
        Agent mode requires a current focused TextField snapshot/ref; --expected-pid is optional.
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
        let events = try KeyboardPrimitives.from(selectedKeyboardEvent())
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .keyCombo,
            expectedPID: selectedKeyboard.expectedPID, snapshotID: agentMode.snapshotID,
            ref: agentMode.elementRef, keyEvents: events), input: selectedInput)
    }

    func validateOnDevice(inBatch: Bool) throws {
        try selectedInput.refuseOnDevice(agent: agentMode.enabled,
            "Physical key combinations do not support agent or selected display options.")
        _ = try physicalModifiers()
    }

    private func physicalModifiers() throws -> [UInt64] {
        let codes = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")
        guard codes.allSatisfy({ (224...231).contains($0) }), Set(codes).count == codes.count, !codes.contains(key) else {
            throw ValidationError("Use distinct HID modifiers in 224...231 and a different target key.")
        }
        return codes.map(UInt64.init)
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        let modifiers = try physicalModifiers()
        let steps = modifiers.map { PhysicalKeyStep(code: $0, pressed: true) }
            + [PhysicalKeyStep(code: UInt64(key), pressed: true), PhysicalKeyStep(code: UInt64(key), pressed: false)]
            + modifiers.reversed().map { PhysicalKeyStep(code: $0, pressed: false) }
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

        logger.info().log("Pressing key combo: modifiers=\(modifiersString), key=\(key)")

        try await LegacyDuoInput.performKeyboard(
            try hidEvent(), simulatorUDID: simulatorUDID, logger: logger, persistentOrdinaryKeyboard: true,
            verbose: selectedOutput.verbose
        )

        logger.info().log("Key combo completed successfully")
    }

    /// Modifiers down in order, the key pressed and released, then modifiers up in reverse order.
    func hidEvent() throws -> FBSimulatorHIDEvent {
        let codes = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")
        return .composite(codes.map { .keyboard(direction: .down, keyCode: UInt32($0)) }
            + [.shortKeyPress(UInt32(key))]
            + codes.reversed().map { .keyboard(direction: .up, keyCode: UInt32($0)) })
    }

    func selectedKeyboardEvent() throws -> FBSimulatorHIDEvent {
        try validate()
        let codes = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")
        guard codes.allSatisfy({ (224...231).contains($0) }) else {
            throw ValidationError("Selected key-combo modifiers must be HID modifier keys 224...231.")
        }
        return try hidEvent()
    }
}
