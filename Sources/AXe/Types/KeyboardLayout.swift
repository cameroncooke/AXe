import ArgumentParser
import Foundation

/// Hardware keyboard layout active in the simulator. HID events carry key positions,
/// so the same character needs a different key per layout.
enum KeyboardLayout: String, CaseIterable {
    case us
    case de

    func keyEvent(for string: String) -> KeyEvent {
        switch self {
        case .us: return KeyEvent.keyCodeForString(string)
        case .de: return KeyEvent.germanKeyCodeForString(string)
        }
    }

    /// Maps an iOS keyboard identifier such as `de_DE@sw=QWERTZ-German;hw=German`
    /// by its `hw=` part; nil when the hardware layout is not supported.
    init?(keyboardIdentifier: String) {
        let hardware = keyboardIdentifier
            .split(separator: "@", maxSplits: 1).last?
            .split(separator: ";")
            .first { $0.hasPrefix("hw=") }?
            .dropFirst(3)
        switch hardware {
        case "ABC", "US", "U.S.": self = .us
        case "German": self = .de
        default: return nil
        }
    }
}

/// `--layout` value: a fixed layout, or `auto` to read the simulator's active keyboard.
enum KeyboardLayoutChoice: String, CaseIterable, ExpressibleByArgument {
    case us
    case de
    case auto

    func resolve(simulatorUDID: String) throws -> KeyboardLayout {
        switch self {
        case .us: return .us
        case .de: return .de
        case .auto:
            let identifier = try Self.activeKeyboardIdentifier(simulatorUDID: simulatorUDID)
            guard let layout = KeyboardLayout(keyboardIdentifier: identifier) else {
                throw CLIError(errorDescription: "Unsupported simulator keyboard '\(identifier)'. Pass --layout us or --layout de explicitly.")
            }
            return layout
        }
    }

    /// Reads the keyboard iOS last switched to, e.g. `en_US@sw=QWERTY;hw=ABC`.
    private static func activeKeyboardIdentifier(simulatorUDID: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", simulatorUDID, "defaults", "read", "com.apple.keyboard.preferences", "KeyboardLastUsed"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let identifier = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !identifier.isEmpty else {
            throw CLIError(errorDescription: "Could not read the active keyboard of simulator \(simulatorUDID). Pass --layout us or --layout de explicitly.")
        }
        return identifier
    }
}

extension KeyEvent {
    /// Apple German (QWERTZ) layout. Dead keys (´ ` ^ ~) are not supported.
    static func germanKeyCodeForString(_ string: String) -> KeyEvent {
        guard let character = string.first, string.count == 1 else { return KeyEvent(keyCode: 0, shift: false) }

        switch character {
            case "y": return KeyEvent(keyCode: 29, shift: false)
            case "z": return KeyEvent(keyCode: 28, shift: false)
            case "Y": return KeyEvent(keyCode: 29, shift: true)
            case "Z": return KeyEvent(keyCode: 28, shift: true)
            case "a"..."z", "A"..."Z", "0"..."9", " ", "\n":
                return keyCodeForString(string)
            case "!": return KeyEvent(keyCode: 30, shift: true)
            case "\"": return KeyEvent(keyCode: 31, shift: true)
            case "§": return KeyEvent(keyCode: 32, shift: true)
            case "$": return KeyEvent(keyCode: 33, shift: true)
            case "%": return KeyEvent(keyCode: 34, shift: true)
            case "&": return KeyEvent(keyCode: 35, shift: true)
            case "/": return KeyEvent(keyCode: 36, shift: true)
            case "(": return KeyEvent(keyCode: 37, shift: true)
            case ")": return KeyEvent(keyCode: 38, shift: true)
            case "=": return KeyEvent(keyCode: 39, shift: true)
            case "ß": return KeyEvent(keyCode: 45, shift: false)
            case "?": return KeyEvent(keyCode: 45, shift: true)
            case "ü": return KeyEvent(keyCode: 47, shift: false)
            case "Ü": return KeyEvent(keyCode: 47, shift: true)
            case "+": return KeyEvent(keyCode: 48, shift: false)
            case "*": return KeyEvent(keyCode: 48, shift: true)
            case "#": return KeyEvent(keyCode: 49, shift: false)
            case "'": return KeyEvent(keyCode: 49, shift: true)
            case "ö": return KeyEvent(keyCode: 51, shift: false)
            case "Ö": return KeyEvent(keyCode: 51, shift: true)
            case "ä": return KeyEvent(keyCode: 52, shift: false)
            case "Ä": return KeyEvent(keyCode: 52, shift: true)
            case ",": return KeyEvent(keyCode: 54, shift: false)
            case ";": return KeyEvent(keyCode: 54, shift: true)
            case ".": return KeyEvent(keyCode: 55, shift: false)
            case ":": return KeyEvent(keyCode: 55, shift: true)
            case "-": return KeyEvent(keyCode: 56, shift: false)
            case "_": return KeyEvent(keyCode: 56, shift: true)
            case "<": return KeyEvent(keyCode: 53, shift: false)
            case ">": return KeyEvent(keyCode: 53, shift: true)
            case "@": return KeyEvent(keyCode: 15, shift: false, option: true)
            case "€": return KeyEvent(keyCode: 8, shift: false, option: true)
            case "[": return KeyEvent(keyCode: 34, shift: false, option: true)
            case "]": return KeyEvent(keyCode: 35, shift: false, option: true)
            case "|": return KeyEvent(keyCode: 36, shift: false, option: true)
            case "{": return KeyEvent(keyCode: 37, shift: false, option: true)
            case "}": return KeyEvent(keyCode: 38, shift: false, option: true)
            case "\\": return KeyEvent(keyCode: 36, shift: true, option: true)
            default: return KeyEvent(keyCode: 0, shift: false)
        }
    }
}
