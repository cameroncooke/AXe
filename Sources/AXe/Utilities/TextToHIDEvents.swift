import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Text to HID Events Converter
struct TextToHIDEvents {
    
    // MARK: - Error Types
    enum TextConversionError: Error, LocalizedError {
        case unsupportedCharacter(Character)
        
        var errorDescription: String? {
            switch self {
            case .unsupportedCharacter(let char):
                return "No keycode found for character: '\(char)'"
            }
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
