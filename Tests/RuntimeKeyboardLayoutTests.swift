import FBSimulatorControl
import Foundation
import Testing
@testable import AXe

@Suite("Runtime Keyboard Layout Tests")
struct RuntimeKeyboardLayoutTests {
    /// An installed iOS simulator runtime, if this machine has one.
    static let runtimeRoot: URL? = {
        let volumes = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: volumes.path)) ?? []
        for name in names.sorted().reversed() where name.hasPrefix("iOS") {
            let runtimes = volumes.appendingPathComponent(name).appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes")
            for runtime in (try? FileManager.default.contentsOfDirectory(atPath: runtimes.path)) ?? [] {
                let root = runtimes.appendingPathComponent(runtime).appendingPathComponent("Contents/Resources/RuntimeRoot")
                let bundle = root.appendingPathComponent("System/Library/KeyboardLayouts/USBKeyboardLayouts.bundle")
                if FileManager.default.fileExists(atPath: bundle.path) { return root }
            }
        }
        return nil
    }()

    private static func modes(_ language: String) -> SimulatorKeyboardSettings.InputModes? {
        switch language {
        case "en":
            return .init(hardwareLayouts: ["en_GB": ["British", "Group-Latin"], "en_US": ["US", "Group-Latin"]],
                         softwareLayouts: ["en_GB": ["QWERTY"], "en_US": ["QWERTY"]],
                         defaults: ["en": ["en_US"], "en_GB": ["en_GB"]])
        case "fr":
            return .init(hardwareLayouts: ["fr_FR": ["French", "Group-Latin"]], softwareLayouts: ["fr_FR": ["AZERTY-French"]],
                         defaults: ["fr": ["fr_FR"]])
        case "de":
            return .init(hardwareLayouts: ["de_DE": ["German", "Group-Latin"]], softwareLayouts: ["de_DE": ["QWERTZ-German"]],
                         defaults: ["de": ["de_DE"]])
        case "xx":
            return .init(hardwareLayouts: ["xx_XX": ["Group-Latin"]], defaults: ["xx": ["xx_XX"]])
        default:
            return nil
        }
    }

    private func layout(keyboards: [String] = [], expanded: Bool = false, languages: [String] = [], lastUsed: String? = nil) -> String? {
        SimulatorKeyboardSettings.activeHardwareLayout(keyboards: keyboards, expanded: expanded, languages: languages,
            lastUsed: lastUsed, inputModes: Self.modes)?.layout
    }

    private let german = "de_DE@sw=QWERTZ-German;hw=German"
    private let french = "fr_FR@sw=AZERTY-French;hw=French"

    @Test("A simulator with no keyboard settings types on its language's default layout")
    func freshSimulatorUsesLanguageDefault() {
        #expect(layout(languages: ["en-GB"]) == "British")
        #expect(layout(languages: ["en-AU"]) == "US")
        #expect(layout(languages: ["zz", "fr-CA"]) == "French")
        #expect(layout() == nil)
    }

    // Each case below was measured on an iOS 27.2 simulator by typing fixed key positions.
    @Test("The keyboard last used is active only when it is listed exactly")
    func keyboardsAndLastUsed() {
        #expect(layout(keyboards: [german, french], expanded: true, lastUsed: german) == "German")
        #expect(layout(keyboards: [german, french], expanded: true, lastUsed: french) == "French")
        #expect(layout(keyboards: [german, french], expanded: true) == "German")
        #expect(layout(keyboards: [german, french], expanded: true, lastUsed: "emoji@sw=Emoji") == "German")
        // The same keyboard written with another hardware layout is a different keyboard.
        #expect(layout(keyboards: [german, french], expanded: true, lastUsed: "fr_FR@sw=AZERTY-French;hw=Automatic") == "German")
        #expect(layout(keyboards: [german, french], expanded: true, lastUsed: "es_ES@sw=QWERTY-Spanish;hw=Automatic") == "German")
        // Options in another order, or left out where they are the defaults, are the same keyboard.
        #expect(layout(keyboards: [german, "fr_FR@hw=Automatic;sw=AZERTY-French"], expanded: true, lastUsed: "fr_FR") == "French")
    }

    @Test("Before the keyboards are set up, the list is ignored for the language's default")
    func unexpandedKeyboardsAreIgnored() {
        #expect(layout(keyboards: [german], expanded: false, languages: ["en-GB"]) == "British")
        #expect(layout(languages: ["en-GB"], lastUsed: german) == "British")
        #expect(layout(keyboards: [german], expanded: true, languages: ["en-GB"]) == "German")
    }

    @Test("A multilingual keyboard types with the first keyboard of its group")
    func multilingualGroup() {
        let us = "en_US@sw=QWERTY;hw=Automatic;ml=1", de = "de_DE@sw=QWERTZ-German;hw=Automatic;ml=1"
        #expect(layout(keyboards: [us, de], expanded: true, lastUsed: de) == "US")
        #expect(layout(keyboards: [de, us], expanded: true, lastUsed: us) == "German")
        #expect(layout(keyboards: [french, us, de], expanded: true, lastUsed: de) == "US")
    }

    @Test("An automatic layout that names only a group is not resolved")
    func groupLayoutIsUnresolved() {
        #expect(layout(keyboards: ["xx_XX@sw=QWERTY;hw=Automatic"], expanded: true) == nil)
    }

    @Test("Keyboard settings are read from the simulator's preference files", .enabled(if: runtimeRoot != nil))
    func settingsOnDisk() throws {
        let root = try #require(Self.runtimeRoot)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("axe-keyboard-\(UUID().uuidString)")
        let preferences = data.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        func write(_ name: String, _ values: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
                .write(to: preferences.appendingPathComponent(name))
        }
        func layout(ignoringKeyboards: Bool = false) -> String? {
            SimulatorKeyboardSettings.activeHardwareLayout(dataPath: data, runtimeRoot: root, ignoringKeyboards: ignoringKeyboards)?.layout
        }
        // No files at all: nothing names a layout.
        #expect(layout() == nil)
        // A fresh simulator has only its language.
        try write(".GlobalPreferences.plist", ["AppleLanguages": ["en-GB"]])
        #expect(layout() == "British")
        // Keyboards set up, with French last used through its automatic layout.
        try write(".GlobalPreferences.plist", ["AppleLanguages": ["en-GB"], "AppleKeyboardsExpanded": true,
            "AppleKeyboards": ["de_DE@sw=QWERTZ-German;hw=German", "fr_FR@sw=AZERTY-French;hw=Automatic"]])
        #expect(layout() == "German")
        try write("com.apple.keyboard.preferences.plist", ["KeyboardLastUsed": "fr_FR@sw=AZERTY-French;hw=Automatic"])
        #expect(layout() == "French")
        // What iOS uses when it cannot use the keyboard that is set.
        #expect(layout(ignoringKeyboards: true) == "British")
    }

    @Test("Key strokes become presses with Shift and Option held around the key")
    func strokesToEvents() {
        let events = TextToHIDEvents.events(for: [KeyStroke(usage: 36, shift: true, option: true), KeyStroke(usage: 4)])
        #expect(events == [
            .keyboard(direction: .down, keyCode: 225), .keyboard(direction: .down, keyCode: 226),
            .keyboard(direction: .down, keyCode: 36), .keyboard(direction: .up, keyCode: 36),
            .keyboard(direction: .up, keyCode: 226), .keyboard(direction: .up, keyCode: 225),
            .keyboard(direction: .down, keyCode: 4), .keyboard(direction: .up, keyCode: 4),
        ])
    }

    @Test("Layout data without the uchr header is refused")
    func malformedDataIsRefused() {
        #expect(RuntimeKeyboardLayout(name: "Junk", uchr: Data(repeating: 0xFF, count: 64)) == nil)
        #expect(RuntimeKeyboardLayout(name: "Short", uchr: Data([0x02, 0x10])) == nil)
        #expect(RuntimeKeyboardLayout(name: "Empty", uchr: Data()) == nil)
    }

    @Test("Truncated or corrupted layout data is refused or read without crashing", .enabled(if: runtimeRoot != nil))
    func damagedDataIsSafe() throws {
        let root = try #require(Self.runtimeRoot)
        let file = root.appendingPathComponent("System/Library/KeyboardLayouts/USBKeyboardLayouts.bundle/uchrs/German.uchr")
        let data = try Data(contentsOf: file)
        #expect(RuntimeKeyboardLayout(name: "German", uchr: data) != nil)
        // Every truncation cuts a table the header points at.
        for length in stride(from: 0, to: data.count - 1, by: max(1, data.count / 97)) {
            #expect(RuntimeKeyboardLayout(name: "German", uchr: data.prefix(length)) == nil)
        }
        // Offsets pointing past the end are refused; whatever else survives must read safely.
        for offset in stride(from: 4, to: min(data.count, 400), by: 4) {
            var damaged = data
            damaged.replaceSubrange(offset..<offset + 4, with: [0xF0, 0xFF, 0xFF, 0x7F])
            _ = RuntimeKeyboardLayout(name: "German", uchr: damaged).map { try? $0.keyStrokes(for: "aé@") }
        }
    }

    @Test("German keys match the installed runtime's layout", .enabled(if: runtimeRoot != nil))
    func germanFromRuntime() throws {
        let german = try RuntimeKeyboardLayout(name: "German", runtimeRoot: try #require(Self.runtimeRoot))
        #expect(try german.keyStrokes(for: "yZ@\\ß<") == [
            KeyStroke(usage: 29), KeyStroke(usage: 28, shift: true), KeyStroke(usage: 15, option: true),
            KeyStroke(usage: 36, shift: true, option: true), KeyStroke(usage: 45), KeyStroke(usage: 53),
        ])
        // A dead key and the letter it composes with.
        #expect(try german.keyStrokes(for: "é").count == 2)
        // The same text decomposed, as macOS passes arguments from some programs.
        #expect(try german.keyStrokes(for: "Gru\u{308}\u{DF}e e\u{301}\u{20AC}") == german.keyStrokes(for: "Grüße é€"))
        #expect(german.typed(by: try german.keyStrokes(for: "Grüße, café ñ ^ ~ €\n")) == "Grüße, café ñ ^ ~ €\n")
        #expect(throws: TextToHIDEvents.TextConversionError.self) { try german.keyStrokes(for: "abc日") }
    }

    @Test("Every printable ASCII character has a key on the runtime's US layout", .enabled(if: runtimeRoot != nil))
    func usFromRuntimeMatchesStaticTable() throws {
        let us = try RuntimeKeyboardLayout(name: "US", runtimeRoot: try #require(Self.runtimeRoot))
        for scalar in (0x20...0x7E).compactMap(UnicodeScalar.init) {
            let character = String(Character(scalar))
            let table = KeyEvent.keyCodeForString(character)
            #expect(try us.keyStrokes(for: character) == [KeyStroke(usage: table.keyCode, shift: table.shift)])
        }
    }

    @Test("An unknown layout name is refused", .enabled(if: runtimeRoot != nil))
    func unknownLayout() throws {
        let root = try #require(Self.runtimeRoot)
        #expect(throws: CLIError.self) { try RuntimeKeyboardLayout(name: "Bogus", runtimeRoot: root) }
        #expect(try RuntimeKeyboardLayout(name: "german", runtimeRoot: root).name == "German")
    }

    @Test("Physical devices send US positions unless a layout is named, and refuse auto")
    func physicalDeviceLayouts() throws {
        let udid = "00000001-0000000000000001"
        try Type.parse(["Hello", "--udid", udid]).validateOnDevice(inBatch: false)
        try Type.parse(["Hello", "--udid", udid, "--layout", "us"]).validateOnDevice(inBatch: false)
        try Type.parse(["Grüße", "--udid", udid, "--layout", "German"]).validateOnDevice(inBatch: false)
        // Before the lease: auto has nothing to read on a device, and the US table cannot type é.
        let automatic = try Type.parse(["Hello", "--udid", udid, "--layout", "auto"])
        #expect(throws: CLIError.self) { try automatic.validateOnDevice(inBatch: false) }
        let unsupported = try Type.parse(["caf\u{E9}", "--udid", udid])
        #expect(throws: TextToHIDEvents.TextConversionError.self) { try unsupported.validateOnDevice(inBatch: false) }

        #expect(try TypingLayout.resolve(nil, deviceVersion: "27.2") == .us)
        #expect(try TypingLayout.resolve("us", deviceVersion: "27.2") == .us)
        #expect(throws: CLIError.self) { try TypingLayout.resolve("auto", deviceVersion: "27.2") }
        #expect(throws: CLIError.self) { try TypingLayout.resolve("German", deviceVersion: "27.2", runtimes: []) }
    }

    @Test("A named device layout comes from the closest runtime and plans Option and dead keys", .enabled(if: runtimeRoot != nil))
    func namedDeviceLayout() throws {
        let root = try #require(Self.runtimeRoot)
        let runtimes = [SimulatorRuntimeRoot(root: root, version: "27.2", build: "test")]
        let german = try TypingLayout.resolve("german", deviceVersion: "27.2", runtimes: runtimes)
        #expect(german.runtime?.name == "German")
        let steps = try Type.physicalKeySteps(for: "@é", layout: german)
        // Option down, L down and up, Option up; then the dead key and E.
        #expect(steps.map(\.code) == [226, 15, 15, 226, 46, 46, 8, 8])
        #expect(steps.map(\.pressed) == [true, true, false, false, true, false, true, false])
        // The US table: a, then Shift and B.
        #expect(try Type.physicalKeySteps(for: "aB").map(\.code) == [4, 4, 225, 5, 5, 225])
    }

    @Test("The closest runtime: the same version, else the nearest, newer on a tie")
    func closestRuntime() {
        let root = URL(fileURLWithPath: "/x")
        let runtimes = ["26.5", "27.0", "27.2", "27.3"].map { SimulatorRuntimeRoot(root: root, version: $0, build: $0) }
        #expect(SimulatorRuntimeRoot.closest(to: "27.2", in: runtimes)?.version == "27.2")
        #expect(SimulatorRuntimeRoot.closest(to: "27.1", in: runtimes)?.version == "27.2")
        #expect(SimulatorRuntimeRoot.closest(to: "26.0", in: runtimes)?.version == "26.5")
        #expect(SimulatorRuntimeRoot.closest(to: "28.0", in: runtimes)?.version == "27.3")
        #expect(SimulatorRuntimeRoot.closest(to: nil, in: runtimes)?.version == "27.3")
        #expect(SimulatorRuntimeRoot.closest(to: "27.2", in: []) == nil)
    }

    @Test("At least one iOS simulator runtime is found on this Mac", .enabled(if: runtimeRoot != nil))
    func installedRuntimesAreFound() {
        let installed = SimulatorRuntimeRoot.installed()
        #expect(!installed.isEmpty)
        #expect(installed.allSatisfy { FileManager.default.fileExists(atPath: $0.root.appendingPathComponent("System/Library/KeyboardLayouts/USBKeyboardLayouts.bundle").path) })
    }

    @Test("auto is the default, and falls back to the US table when the simulator cannot be found")
    func automaticFallsBackToUS() throws {
        let command = try Type.parse(["Hello", "--udid", "00000000-0000-0000-0000-000000000001"])
        #expect(command.layout == nil)
        var notes: [String] = []
        let layout = try command.typingLayout { notes.append($0) }
        #expect(layout == .us)
        #expect(notes.count == 1)
        #expect(try layout.events(for: "aB") == TextToHIDEvents.convertTextToHIDEvents("aB"))
        // A named layout cannot fall back: the caller asked for those keys.
        let named = try Type.parse(["Hello", "--udid", "00000000-0000-0000-0000-000000000001", "--layout", "German"])
        #expect(throws: CLIError.self) { try named.typingLayout() }
        #expect(try Type.parse(["Hello", "--udid", "x", "--layout", "us"]).typingLayout() == .us)
    }

    @Test("A layout travels with selected, agent and agent batch requests", .enabled(if: runtimeRoot != nil))
    func layoutTravelsWithRequests() throws {
        let root = try #require(Self.runtimeRoot)
        let german = TypingLayout(runtime: .init(name: "German", root: root.path))
        let expected = try KeyboardPrimitives.from(.composite(TextToHIDEvents.events(for: [KeyStroke(usage: 15, option: true)])))
        #expect(try KeyboardPrimitives.from(SelectedKeyboardRequest.textEvent("@", layout: german)).map(\.event) == expected.map(\.event))

        var agent = AgentModeRequest(kind: .typeText, text: "@")
        agent.layout = german
        let decoded = try JSONDecoder().decode(AgentModeRequest.self, from: JSONEncoder().encode(agent))
        #expect(decoded.layout == german)
        // A request from a build without layouts decodes to the US table.
        let legacy = try JSONDecoder().decode(AgentModeRequest.self, from: Data(#"{"kind":"typeText","text":"@","distance":1,"duration":1,"preDelay":0,"postDelay":0,"rowOffset":0,"rowLimit":64}"#.utf8))
        #expect(legacy.layout == nil)

        // ü has no key on the US table, so this batch is valid only with its layout.
        let steps = Data(#"{"steps":[{"action":"type","id":"field","text":"Grüße"}]}"#.utf8)
        #expect(throws: (any Error).self) { try AgentBatchCommandAdapter.request(data: steps, expectedPID: 1) }
        let request = try AgentBatchCommandAdapter.request(data: steps, expectedPID: 1, layout: german)
        #expect(request.agentBatch?.layout == german)
    }

    @Test("A detected layout without Latin letters sends US positions for text only the US table can type", .enabled(if: runtimeRoot != nil))
    func detectedLayoutFallsBackToUS() throws {
        let root = try #require(Self.runtimeRoot).path
        let detected = TypingLayout(runtime: .init(name: "Russian", root: root), fallsBackToUS: true)
        let named = TypingLayout(runtime: .init(name: "Russian", root: root))
        #expect(try detected.events(for: "user@mail.ru") == TextToHIDEvents.convertTextToHIDEvents("user@mail.ru"))
        #expect(try detected.keyStrokes(for: "привет").count == 6)
        // Mixed text has no single layout, and a named layout is strict.
        #expect(throws: TextToHIDEvents.TextConversionError.self) { try detected.keyStrokes(for: "привет world") }
        #expect(throws: TextToHIDEvents.TextConversionError.self) { try named.keyStrokes(for: "user@mail.ru") }
        // The flag travels with the request.
        #expect(try JSONDecoder().decode(TypingLayout.self, from: JSONEncoder().encode(detected)) == detected)
    }

    @Test("A key whose character depends on the next key is not used", .enabled(if: runtimeRoot != nil))
    func keysThatHoldTheirCharacterAreRefused() throws {
        let root = try #require(Self.runtimeRoot)
        // A Vietnamese vowel is held until the next key, which may turn it into another letter.
        if let vietnamese = try? RuntimeKeyboardLayout(name: "Vietnamese", runtimeRoot: root) {
            #expect(throws: TextToHIDEvents.TextConversionError.self) { try vietnamese.keyStrokes(for: "a") }
            #expect(try vietnamese.keyStrokes(for: "b").count == 1)
            // Detected, the text goes out as US key positions, as it always did.
            let detected = TypingLayout(runtime: .init(name: "Vietnamese", root: root.path), fallsBackToUS: true)
            #expect(try detected.events(for: "ban") == TextToHIDEvents.convertTextToHIDEvents("ban"))
        }
        // An accent on its own, after its dead key, and text after a finished composition.
        let german = try RuntimeKeyboardLayout(name: "German", runtimeRoot: root)
        #expect(german.typed(by: try german.keyStrokes(for: "^ ´ ` ~ éa ñn")) == "^ ´ ` ~ éa ñn")
    }

    @Test("A layout the runtime lacks, or a missing runtime, refuses the text before input")
    func brokenLayoutReferenceIsRefused() {
        let missing = TypingLayout(runtime: .init(name: "German", root: "/nonexistent/RuntimeRoot"))
        #expect(throws: (any Error).self) { try missing.events(for: "a") }
        #expect(throws: (any Error).self) { try SelectedKeyboardRequest.textEvent("a", layout: missing) }
    }

    @Test("On US the fixed table is kept and the runtime adds the characters it lacks", .enabled(if: runtimeRoot != nil))
    func usKeepsFixedTable() throws {
        let us = TypingLayout(runtime: .init(name: "US", root: try #require(Self.runtimeRoot).path))
        #expect(try us.events(for: "Hello, World! #@") == TextToHIDEvents.convertTextToHIDEvents("Hello, World! #@"))
        #expect(try us.keyStrokes(for: "é").count == 2)
        #expect(throws: TextToHIDEvents.TextConversionError.self) { try TypingLayout.us.keyStrokes(for: "é") }
    }
}
