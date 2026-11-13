import CoreServices
import Foundation

/// One key press, as a USB HID usage, with the modifiers held for it.
struct KeyStroke: Equatable, Sendable {
    let usage: Int
    var shift = false
    var option = false
}

/// A hardware keyboard layout read from the simulator runtime's own layout data
/// (`USBKeyboardLayouts.bundle`), which is what the simulator decodes key presses with.
/// A key press carries a key position, so the same character needs a different key per layout.
struct RuntimeKeyboardLayout: Sendable {
    let name: String
    private let uchr: Data
    private let strokes: [Character: [KeyStroke]]

    /// The runtime's own spelling of a layout name and the file that holds it, or nil when the
    /// runtime has no such layout. Reads only the bundle's index.
    static func find(_ name: String, runtimeRoot: URL) -> (name: String, file: URL)? {
        let bundle = runtimeRoot.appendingPathComponent("System/Library/KeyboardLayouts/USBKeyboardLayouts.bundle")
        let index = propertyList(at: bundle.appendingPathComponent("USBKeyboardLayouts.plist")) as? [String: [String: Any]] ?? [:]
        let known = index[name] != nil ? name : index.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        guard let known, let file = index[known]?["KeyLayoutFileName"] as? String, !file.contains("/") else { return nil }
        return (known, bundle.appendingPathComponent("uchrs").appendingPathComponent(file))
    }

    /// The names of the layouts a runtime ships that start like `name`, for an error message.
    static func names(like name: String, runtimeRoot: URL) -> [String] {
        let bundle = runtimeRoot.appendingPathComponent("System/Library/KeyboardLayouts/USBKeyboardLayouts.bundle")
        let index = propertyList(at: bundle.appendingPathComponent("USBKeyboardLayouts.plist")) as? [String: Any] ?? [:]
        return Array(index.keys.filter { $0.lowercased().hasPrefix(name.lowercased().prefix(2)) }.sorted().prefix(8))
    }

    /// Loads the layout called `name` (`German`, `French`, `British`, ...) from a runtime root.
    init(name: String, runtimeRoot: URL) throws {
        guard let found = Self.find(name, runtimeRoot: runtimeRoot) else {
            let near = Self.names(like: name, runtimeRoot: runtimeRoot)
            let hint = near.isEmpty ? "" : " Similar names: \(near.joined(separator: ", "))."
            throw CLIError(errorDescription: "iOS has no hardware keyboard layout named '\(name)'.\(hint)", code: .invalidArguments)
        }
        guard let data = try? Data(contentsOf: found.file), let layout = RuntimeKeyboardLayout(name: found.name, uchr: data) else {
            throw CLIError(errorDescription: "The simulator runtime's '\(found.name)' hardware keyboard layout could not be read.")
        }
        self = layout
    }

    /// Inverts `uchr` layout data into the key strokes that type each character, including
    /// characters composed with one dead key. Nil when the data is not well-formed layout data.
    init?(name: String, uchr: Data) {
        guard Self.isWellFormed(uchr) else { return nil }
        let keys = [(false, false), (true, false), (false, true), (true, true)].flatMap { shift, option in
            Self.printingKeys.map { KeyStroke(usage: $0, shift: shift, option: option) }
        }
        // What every key types, and the state it leaves, with no dead key pending.
        let alone = keys.map { Self.translate($0, uchr: uchr, deadKeyState: 0) }
        // Whether a state left behind changes what the next key types. Most finished compositions
        // leave a state that changes nothing. One that does, as after a Vietnamese vowel, makes the
        // key unusable here: its character would depend on the key after it.
        var disturbing: [UInt32: Bool] = [0: false]
        func disturbs(_ state: UInt32) -> Bool {
            if let known = disturbing[state] { return known }
            let result = zip(keys, alone).contains { Self.translate($0, uchr: uchr, deadKeyState: state).text != $1.text }
            disturbing[state] = result
            return result
        }
        var direct: [Character: KeyStroke] = [:]
        var deadKeys: [(stroke: KeyStroke, state: UInt32)] = []
        // `keys` runs from no modifiers to Shift and Option, so a character keeps the simplest key that types it.
        for (stroke, (text, state)) in zip(keys, alone) {
            if text.count == 1, let character = text.first {
                if direct[character] == nil, !disturbs(state) { direct[character] = stroke }
            } else if text.isEmpty, state != 0 {
                deadKeys.append((stroke, state))
            }
        }
        var strokes = direct.mapValues { [$0] }
        // A dead key, then an unmodified or shifted key: a letter it composes with, space for the
        // accent alone, or on some layouts the dead key again.
        for dead in deadKeys {
            for second in keys where !second.option {
                let (text, state) = Self.translate(second, uchr: uchr, deadKeyState: dead.state)
                guard text.count == 1, let character = text.first, strokes[character] == nil, !disturbs(state) else { continue }
                strokes[character] = [dead.stroke, second]
            }
        }
        // Return types a carriage return in the layout data; text carries a line feed.
        strokes["\n"] = [KeyStroke(usage: Self.returnKey)]
        strokes["\t"] = [KeyStroke(usage: 0x2B)]
        self.name = name
        self.uchr = uchr
        self.strokes = strokes
    }

    /// The key strokes that type `text`. Throws, planning nothing, for a character the layout
    /// cannot type, and when replaying the plan through the layout would not reproduce the text.
    func keyStrokes(for text: String) throws -> [KeyStroke] {
        var plan: [KeyStroke] = []
        for character in text {
            if let known = strokes[character] {
                plan += known
                continue
            }
            // A character of several scalars with no key of its own is typed scalar by scalar.
            let parts = character.unicodeScalars.map { strokes[Character($0)] }
            guard parts.count > 1, !parts.contains(where: { $0 == nil }) else {
                throw TextToHIDEvents.TextConversionError.notOnLayout(character, layout: name)
            }
            plan += parts.flatMap { $0 ?? [] }
        }
        // Compared as text, not scalar by scalar: "é" may arrive as "e" and a combining accent.
        guard typed(by: plan) == text else {
            let mismatch = zip(typed(by: plan), text).first { $0 != $1 }?.1 ?? text.last ?? " "
            throw TextToHIDEvents.TextConversionError.combinesOnLayout(mismatch, layout: name)
        }
        return plan
    }

    /// What `strokes` type when pressed in order, each meeting the dead-key state left before it.
    func typed(by strokes: [KeyStroke]) -> String {
        var state: UInt32 = 0
        var result = ""
        for stroke in strokes {
            let (text, next) = Self.translate(stroke, uchr: uchr, deadKeyState: state)
            result += stroke.usage == Self.returnKey && text == "\r" ? "\n" : text
            state = next
        }
        return result
    }

    private static let returnKey = 0x28

    /// Letters and digits, space to slash, and the ISO key beside left shift. Usage 0x32 is left
    /// out: the runtime's layouts put the ISO key beside Return at 0x31.
    private static let printingKeys: [Int] = Array(0x04...0x27) + Array(0x2C...0x31) + Array(0x33...0x38) + [0x64]

    private static func translate(_ stroke: KeyStroke, uchr: Data, deadKeyState: UInt32) -> (text: String, state: UInt32) {
        // Carbon's shiftKey and optionKey event modifiers, shifted down a byte.
        let modifiers: UInt32 = (stroke.shift ? 0x02 : 0) | (stroke.option ? 0x08 : 0)
        var state = deadKeyState
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = uchr.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            // A runtime's layout data is indexed by HID usage; macOS's own is by virtual key code.
            return UCKeyTranslate(layout, UInt16(stroke.usage), UInt16(kUCKeyActionDown), modifiers, 0, 0,
                                  &state, characters.count, &length, &characters)
        }
        guard status == noErr else { return ("", 0) }
        return (String(utf16CodeUnits: characters, count: min(length, characters.count)), state)
    }

    /// Whether `uchr` has the layout header and every table its keyboard types point at lies
    /// inside the data. UCKeyTranslate takes no length and follows the offsets it finds, so
    /// truncated or corrupt data would otherwise be read out of bounds.
    static func isWellFormed(_ uchr: Data) -> Bool {
        let bytes = [UInt8](uchr)
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
            return low | high << 16
        }
        func holds(_ offset: Int, _ count: Int) -> Bool {
            offset >= 0 && count >= 0 && offset + count <= bytes.count
        }
        // UCKeyboardLayout: format, version, feature info offset, keyboard type count, type headers.
        guard u16(0) == Int(kUCKeyLayoutHeaderFormat), let featureInfo = u32(4), let typeCount = u32(8),
              (1...64).contains(typeCount), featureInfo == 0 || holds(featureInfo, 8) else { return false }
        for type in 0..<typeCount {
            // UCKeyboardTypeHeader: first and last type, then five table offsets, the last three optional.
            let header = 12 + type * 28
            guard let modifiers = u32(header + 8), let tables = u32(header + 12), let records = u32(header + 16),
                  let terminators = u32(header + 20), let sequences = u32(header + 24) else { return false }
            // UCKeyModifiersToTableNum: format, default table, count, then a table number per modifier state.
            guard u16(modifiers) == Int(kUCKeyModifiersToTableNumFormat), let modifierCount = u32(modifiers + 4),
                  holds(modifiers + 8, modifierCount) else { return false }
            // UCKeyToCharTableIndex: format, table size, count, then an offset per table.
            guard u16(tables) == Int(kUCKeyToCharTableIndexFormat), let tableSize = u16(tables + 2),
                  let tableCount = u32(tables + 4), tableCount <= 4096, holds(tables + 8, tableCount * 4) else { return false }
            for table in 0..<tableCount {
                guard let offset = u32(tables + 8 + table * 4), holds(offset, tableSize * 2) else { return false }
            }
            if records != 0 {
                // UCKeyStateRecordsIndex: format, count, then an offset per record of four 16-bit
                // fields followed by entries of four or eight bytes.
                guard u16(records) == Int(kUCKeyStateRecordsIndexFormat), let recordCount = u16(records + 2),
                      holds(records + 4, recordCount * 4) else { return false }
                for record in 0..<recordCount {
                    guard let offset = u32(records + 4 + record * 4), let entryCount = u16(offset + 4),
                          let format = u16(offset + 6),
                          holds(offset + 8, entryCount * (format == Int(kUCKeyStateEntryTerminalFormat) ? 4 : 8)) else { return false }
                }
            }
            if terminators != 0 {
                guard u16(terminators) == Int(kUCKeyStateTerminatorsFormat), let count = u16(terminators + 2),
                      holds(terminators + 4, count * 2) else { return false }
            }
            if sequences != 0 {
                // UCKeySequenceDataIndex: format, count, then count + 1 rising offsets from its start.
                guard u16(sequences) == Int(kUCKeySequenceDataIndexFormat), let count = u16(sequences + 2) else { return false }
                var previous = 4 + (count + 1) * 2
                for index in 0...count {
                    guard let offset = u16(sequences + 4 + index * 2), offset >= previous, holds(sequences, offset) else { return false }
                    previous = offset
                }
            }
        }
        return true
    }

    static func propertyList(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}

/// Works out which hardware layout a simulator types with, from its keyboard settings on disk.
/// The rules were measured on an iOS 27.2 simulator by typing fixed key positions under each setting.
enum SimulatorKeyboardSettings {
    struct Reading: Equatable {
        let layout: String
        /// How the layout was found, for the log.
        let reason: String
    }

    /// What the runtime lists for one language's keyboards, by keyboard name such as `fr_FR`.
    struct InputModes {
        var hardwareLayouts: [String: [String]] = [:]
        var softwareLayouts: [String: [String]] = [:]
        /// The default keyboards of a language or locale, such as `en_GB`.
        var defaults: [String: [String]] = [:]
    }

    /// The hardware layout a newly launched app types with. An app keeps the layout it was
    /// launched with, so this describes apps launched since the keyboards last changed.
    /// Nil when the settings and the runtime name no single layout.
    static func activeHardwareLayout(dataPath: URL, runtimeRoot: URL, ignoringKeyboards: Bool = false) -> Reading? {
        let preferences = dataPath.appendingPathComponent("Library/Preferences")
        let global = RuntimeKeyboardLayout.propertyList(at: preferences.appendingPathComponent(".GlobalPreferences.plist")) as? [String: Any] ?? [:]
        let keyboard = RuntimeKeyboardLayout.propertyList(at: preferences.appendingPathComponent("com.apple.keyboard.preferences.plist")) as? [String: Any] ?? [:]
        return activeHardwareLayout(
            keyboards: ignoringKeyboards ? [] : global["AppleKeyboards"] as? [String] ?? [],
            expanded: global["AppleKeyboardsExpanded"] as? Bool ?? false,
            languages: global["AppleLanguages"] as? [String] ?? [],
            lastUsed: ignoringKeyboards ? nil : keyboard["KeyboardLastUsed"] as? String,
            inputModes: { inputModes(language: $0, runtimeRoot: runtimeRoot) })
    }

    /// With the keyboards set up (`expanded`), the active keyboard is the one last used if it is
    /// listed exactly, otherwise the first; before that the list is ignored for the default
    /// keyboards of the simulator's language. A keyboard in a multilingual group (`ml=`) types
    /// with the first keyboard of that group. `hw=Automatic`, or no `hw=`, means the first
    /// hardware layout the runtime lists for the keyboard.
    static func activeHardwareLayout(
        keyboards: [String], expanded: Bool, languages: [String], lastUsed: String?,
        inputModes: (String) -> InputModes?
    ) -> Reading? {
        var candidates: [String] = expanded ? keyboards : []
        let listed = !candidates.isEmpty
        if !listed {
            // The most specific default the runtime lists for the first language that has one: en_GB, then en.
            search: for language in languages {
                let parts = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
                guard let base = parts.first, let defaults = inputModes(base)?.defaults else { continue }
                for count in (1...parts.count).reversed() {
                    if let modes = defaults[parts.prefix(count).joined(separator: "_")] {
                        candidates = modes
                        break search
                    }
                }
            }
        }
        let modes = candidates.map { Mode($0) }
        func full(_ mode: Mode) -> Mode {
            var mode = mode
            mode.software = mode.software ?? inputModes(mode.language)?.softwareLayouts[mode.name]?.first
            mode.hardware = mode.hardware ?? "Automatic"
            return mode
        }
        let last = lastUsed.map { full(Mode($0)) }
        var active = modes.firstIndex { full($0) == last } ?? 0
        guard modes.indices.contains(active) else { return nil }
        if listed, let group = modes[active].group {
            active = modes.firstIndex { $0.group == group } ?? active
        }
        let mode = modes[active]
        if let hardware = mode.hardware, hardware != "Automatic" {
            return Reading(layout: hardware, reason: "keyboard \(candidates[active])")
        }
        // A "Group-" entry names several layouts, not one the simulator types with.
        guard let automatic = inputModes(mode.language)?.hardwareLayouts[mode.name]?.first, !automatic.hasPrefix("Group-") else { return nil }
        return Reading(layout: automatic, reason: "keyboard \(candidates[active]), whose automatic layout is \(automatic)")
    }

    /// A keyboard identifier such as `fr_FR@sw=AZERTY-French;hw=French;ml=1`, taken apart.
    private struct Mode: Equatable {
        let name: String
        var software: String?
        var hardware: String?
        var group: String?

        var language: String { String(name.prefix { $0 != "_" && $0 != "-" }) }

        init(_ identifier: String) {
            let parts = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            name = String(parts[0])
            for option in parts.dropFirst().joined().split(separator: ";") {
                let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "sw": software = pair[1]
                case "hw": hardware = pair[1]
                case "ml": group = pair[1]
                default: break
                }
            }
        }
    }

    private static func inputModes(language: String, runtimeRoot: URL) -> InputModes? {
        // The language comes from the simulator's preferences and goes into a path.
        guard !language.isEmpty, language.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        // A language with few keyboards has no bundle of its own and is described in the `mul` one.
        for bundle in [language, "mul"] {
            let url = runtimeRoot.appendingPathComponent("System/Library/TextInput/TextInput_\(bundle).bundle/InputMode_\(language).plist")
            guard let plist = RuntimeKeyboardLayout.propertyList(at: url) as? [String: Any] else { continue }
            var modes = InputModes()
            for (name, mode) in plist["UIKeyboardSupportedInputModes"] as? [String: [String: Any]] ?? [:] {
                modes.hardwareLayouts[name] = mode["HWLayouts"] as? [String]
                modes.softwareLayouts[name] = mode["SWLayouts"] as? [String]
            }
            modes.defaults = plist["UIKeyboardDefaultLanguageInputModes"] as? [String: [String]] ?? [:]
            return modes
        }
        return nil
    }
}
