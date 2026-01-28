import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct KeyCombo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a key while holding one or more modifier keys on the simulator.",
        discussion: """
        Hold modifier keys and press another key as a single atomic operation.
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

    private var modifiers: [Int] {
        return modifiersString.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    func validate() throws {
        let parsedModifiers = modifiers

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

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)

        try await performGlobalSetup(logger: logger)

        let parsedModifiers = modifiers

        logger.info().log("Pressing key combo: modifiers=\(parsedModifiers), key=\(key)")

        // Build composite event:
        //   modifierDown1, modifierDown2, ..., shortKeyPress(key), ..., modifierUp2, modifierUp1
        var events: [FBSimulatorHIDEvent] = []

        // Press modifiers down in order
        for modifier in parsedModifiers {
            events.append(FBSimulatorHIDEvent.keyDown(UInt32(modifier)))
        }

        // Press and release the target key
        events.append(FBSimulatorHIDEvent.shortKeyPress(UInt32(key)))

        // Release modifiers in reverse order
        for modifier in parsedModifiers.reversed() {
            events.append(FBSimulatorHIDEvent.keyUp(UInt32(modifier)))
        }

        let comboEvent = FBSimulatorHIDEvent(events: events)

        try await HIDInteractor
            .performHIDEvent(
                comboEvent,
                for: simulatorUDID,
                logger: logger
            )

        logger.info().log("Key combo completed successfully")
    }
}
