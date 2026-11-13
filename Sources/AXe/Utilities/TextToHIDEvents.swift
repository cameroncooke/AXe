import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Text to HID Events Converter
struct TextToHIDEvents {
    
    // MARK: - Error Types
    enum TextConversionError: Error, LocalizedError, UserFacingError {
        case unsupportedCharacter(Character)
        /// The simulator's keyboard layout, read from its runtime, has no key for the character.
        case notOnLayout(Character, layout: String)
        /// Each character has a key, but pressed in this order the layout combines them into
        /// other characters, as a Vietnamese keyboard turns "oo" into "ô".
        case combinesOnLayout(Character, layout: String)
        
        var errorDescription: String? {
            switch self {
            case .unsupportedCharacter(let char):
                return "No keycode found for character: '\(char)'"
            case let .notOnLayout(char, layout):
                return "The \(layout) keyboard layout has no key for the character '\(char)'."
            case let .combinesOnLayout(char, layout):
                return "The \(layout) keyboard layout combines the keys for this text into other characters at '\(char)', so it cannot be typed as written."
            }
        }

        var userFacingDescription: String {
            errorDescription ?? "AXe could not convert the requested text into simulator keyboard input."
        }
    }
    
    // MARK: - Simple Key Event Creation
    
    /// Creates key events for a character that doesn't require shift
    private static func simpleKeyEvent(keyCode: Int) -> [FBSimulatorHIDEvent] {
        return [
            .keyboard(direction: .down, keyCode: UInt32(keyCode)),
            .keyboard(direction: .up, keyCode: UInt32(keyCode))
        ]
    }
    
    /// Creates key events for a character that requires shift
    private static func shiftedKeyEvent(keyCode: Int) -> [FBSimulatorHIDEvent] {
        return [
            .keyboard(direction: .down, keyCode: 225),
            .keyboard(direction: .down, keyCode: UInt32(keyCode)),
            .keyboard(direction: .up, keyCode: UInt32(keyCode)),
            .keyboard(direction: .up, keyCode: 225)
        ]
    }
    
    // MARK: - Character to HID Event Mapping
    
    /// Converts a single character to its corresponding HID events
    private static func eventsForCharacter(_ character: Character) throws -> [FBSimulatorHIDEvent] {
        let charString = String(character)
        let keyEvent = KeyEvent.keyCodeForString(charString)
        
        // Check if character is supported
        guard keyEvent.keyCode != 0 else {
            throw TextConversionError.unsupportedCharacter(character)
        }
        
        if keyEvent.shift {
            return shiftedKeyEvent(keyCode: keyEvent.keyCode)
        } else {
            return simpleKeyEvent(keyCode: keyEvent.keyCode)
        }
    }
    
    // MARK: - Key Strokes

    /// The key presses for planned key strokes, holding Shift and Option around each key that needs them.
    static func events(for strokes: [KeyStroke]) -> [FBSimulatorHIDEvent] {
        strokes.flatMap { stroke -> [FBSimulatorHIDEvent] in
            let modifiers: [UInt32] = (stroke.shift ? [225] : []) + (stroke.option ? [226] : [])
            let key = UInt32(stroke.usage)
            return modifiers.map { .keyboard(direction: .down, keyCode: $0) }
                + [.keyboard(direction: .down, keyCode: key), .keyboard(direction: .up, keyCode: key)]
                + modifiers.reversed().map { .keyboard(direction: .up, keyCode: $0) }
        }
    }

    // MARK: - Public API
    
    /// Validates that a text string can be converted to HID events
    /// - Parameter text: The text string to validate
    /// - Returns: true if all characters are supported, false otherwise
    static func validateText(_ text: String) -> Bool {
        for character in text {
            let charString = String(character)
            let keyEvent = KeyEvent.keyCodeForString(charString)
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
    static func convertTextToHIDEvents(_ text: String) throws -> [FBSimulatorHIDEvent] {
        var events: [FBSimulatorHIDEvent] = []
        
        for character in text {
            let characterEvents = try eventsForCharacter(character)
            events.append(contentsOf: characterEvents)
        }
        
        return events
    }
}
