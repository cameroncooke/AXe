import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Text to HID Events Converter
struct TextToHIDEvents {
    
    // MARK: - Error Types
    enum TextConversionError: Error, LocalizedError, UserFacingError {
        case unsupportedCharacter(Character)
        
        var errorDescription: String? {
            switch self {
            case .unsupportedCharacter(let char):
                return "No keycode found for character: '\(char)'"
            }
        }

        var userFacingDescription: String {
            errorDescription ?? "AXe could not convert the requested text into simulator keyboard input."
        }
    }
    
    // MARK: - Character to HID Event Mapping

    /// Converts a single character to its HID events, holding Shift/Option as the layout requires
    private static func eventsForCharacter(_ character: Character, layout: KeyboardLayout) throws -> [FBSimulatorHIDEvent] {
        let keyEvent = layout.keyEvent(for: String(character))
        guard keyEvent.keyCode != 0 else {
            throw TextConversionError.unsupportedCharacter(character)
        }

        let modifiers: [UInt32] = (keyEvent.shift ? [225] : []) + (keyEvent.option ? [226] : [])
        let keyCode = UInt32(keyEvent.keyCode)
        return modifiers.map { .keyboard(direction: .down, keyCode: $0) }
            + [.keyboard(direction: .down, keyCode: keyCode), .keyboard(direction: .up, keyCode: keyCode)]
            + modifiers.reversed().map { .keyboard(direction: .up, keyCode: $0) }
    }

    // MARK: - Public API
    
    /// Validates that a text string can be converted to HID events
    /// - Parameter text: The text string to validate
    /// - Returns: true if all characters are supported, false otherwise
    static func validateText(_ text: String, layout: KeyboardLayout = .us) -> Bool {
        for character in text {
            let keyEvent = layout.keyEvent(for: String(character))
            if keyEvent.keyCode == 0 {
                return false
            }
        }
        return true
    }
    
    /// Converts a text string to a sequence of HID events
    /// - Parameter text: The text string to convert
    /// - Returns: An array of FBSimulatorHIDEvent objects representing the key presses
    /// - Throws: TextConversionError.unsupportedCharacter if any character is not supported
    static func convertTextToHIDEvents(_ text: String, layout: KeyboardLayout = .us) throws -> [FBSimulatorHIDEvent] {
        var events: [FBSimulatorHIDEvent] = []
        
        for character in text {
            let characterEvents = try eventsForCharacter(character, layout: layout)
            events.append(contentsOf: characterEvents)
        }
        
        return events
    }
}
