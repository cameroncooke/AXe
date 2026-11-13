import Foundation
import FBControlCore
import FBSimulatorControl

/// The keyboard layout text is typed on: the fixed US table, or a layout the simulator's runtime
/// ships. A request to the input broker carries it, so both ends plan the same key presses.
struct TypingLayout: Codable, Equatable, Sendable {
    /// A layout in a runtime's `USBKeyboardLayouts.bundle`.
    struct Runtime: Codable, Equatable, Sendable {
        let name: String
        let root: String
    }

    /// Nil types with the fixed US table.
    let runtime: Runtime?
    /// Set when the layout was detected, not named: text the layout cannot type but the US table
    /// can is sent as US key positions, as AXe always did. iOS itself types US positions in a
    /// field that takes only ASCII (an email, URL or password field) while a keyboard without
    /// Latin letters, such as Russian, is active.
    var fallsBackToUS: Bool? = nil

    static let us = TypingLayout(runtime: nil)

    /// The `--layout` value that reads the simulator's keyboard settings.
    static let automatic = "auto"
    /// The `--layout` value for the fixed US table, whatever the simulator is set to.
    static let fixedUS = "us"

    var name: String { runtime?.name ?? "US" }

    // MARK: - Resolving --layout

    /// The layout for a `--layout` value on one simulator.
    ///
    /// `auto` reads the simulator's keyboard settings and falls back to the US table, telling
    /// `note` why, when they name no layout. `us` is the US table. Any other value names a layout
    /// of the simulator's runtime and throws when the runtime has none by that name.
    static func resolve(_ choice: String, simulatorUDID: String, note: (String) -> Void = { _ in }) throws -> TypingLayout {
        if choice == fixedUS { return .us }
        guard let files = SimulatorFiles.booted(udid: simulatorUDID) else {
            guard choice == automatic else {
                throw CLIError(errorDescription: "The runtime of simulator \(simulatorUDID) could not be located, so the '\(choice)' keyboard layout is unavailable. Check that it is booted.", code: .notBooted)
            }
            note("Typing on the US keyboard layout: the simulator's runtime could not be located")
            return .us
        }
        guard choice == automatic else {
            // Loaded here so that a name the runtime lacks, or data it cannot read, fails now.
            let layout = try RuntimeKeyboardLayout(name: choice, runtimeRoot: files.runtimeRoot)
            return TypingLayout(runtime: Runtime(name: layout.name, root: files.runtimeRoot.path))
        }
        guard var reading = SimulatorKeyboardSettings.activeHardwareLayout(dataPath: files.dataPath, runtimeRoot: files.runtimeRoot) else {
            note("Typing on the US keyboard layout: the simulator's keyboard settings name no single hardware layout")
            return .us
        }
        if RuntimeKeyboardLayout.find(reading.layout, runtimeRoot: files.runtimeRoot) == nil {
            // iOS types on its language's default keyboard when it cannot use the one that is set.
            guard let fallback = SimulatorKeyboardSettings.activeHardwareLayout(dataPath: files.dataPath, runtimeRoot: files.runtimeRoot, ignoringKeyboards: true),
                  RuntimeKeyboardLayout.find(fallback.layout, runtimeRoot: files.runtimeRoot) != nil else {
                note("Typing on the US keyboard layout: the runtime has no '\(reading.layout)' layout (\(reading.reason))")
                return .us
            }
            reading = .init(layout: fallback.layout, reason: "the runtime has no '\(reading.layout)' layout, so the language's default applies: \(fallback.reason)")
        }
        note("Typing on the \(reading.layout) keyboard layout (\(reading.reason))")
        return TypingLayout(runtime: Runtime(name: reading.layout, root: files.runtimeRoot.path), fallsBackToUS: true)
    }

    // MARK: - Planning key presses

    /// The key strokes that type `text`. Throws, planning nothing, for a character the layout cannot type.
    func keyStrokes(for text: String) throws -> [KeyStroke] {
        guard let runtime else { return try Self.fixedStrokes(for: text) }
        // On US the fixed table keeps the key presses AXe has always sent; the runtime's layout
        // adds the characters that table lacks, such as é.
        if runtime.name == "US", let strokes = try? Self.fixedStrokes(for: text) { return strokes }
        do {
            return try RuntimeKeyboardLayout(name: runtime.name, runtimeRoot: URL(fileURLWithPath: runtime.root)).keyStrokes(for: text)
        } catch let error as TextToHIDEvents.TextConversionError {
            // Only a missing key means the text belongs to another layout. Keys that combine
            // would combine in US positions too, so that text is refused.
            guard fallsBackToUS == true, case .notOnLayout = error, let strokes = try? Self.fixedStrokes(for: text) else { throw error }
            return strokes
        }
    }

    func events(for text: String) throws -> [FBSimulatorHIDEvent] {
        TextToHIDEvents.events(for: try keyStrokes(for: text))
    }

    private static func fixedStrokes(for text: String) throws -> [KeyStroke] {
        try text.map { character in
            let event = KeyEvent.keyCodeForString(String(character))
            guard event.keyCode != 0 else { throw TextToHIDEvents.TextConversionError.unsupportedCharacter(character) }
            return KeyStroke(usage: event.keyCode, shift: event.shift)
        }
    }
}

extension TypingLayout {
    /// The layout for `--layout` on a physical device. A device does not report the keyboard in
    /// use, so it types US key positions unless a layout is named. A named layout's data comes
    /// from the installed simulator runtime closest to the device's system version.
    static func resolve(_ choice: String?, deviceVersion: String?,
                        runtimes: [SimulatorRuntimeRoot] = SimulatorRuntimeRoot.installed(),
                        note: (String) -> Void = { _ in }) throws -> TypingLayout {
        guard let choice, choice != fixedUS else { return .us }
        guard choice != automatic else { throw deviceAutomatic }
        guard let runtime = SimulatorRuntimeRoot.closest(to: deviceVersion, in: runtimes) else {
            throw CLIError(errorDescription: "No iOS simulator runtime is installed, so AXe has no data for the '\(choice)' keyboard layout. Install one in Xcode, or pass --layout us.", code: .invalidArguments)
        }
        let layout = try RuntimeKeyboardLayout(name: choice, runtimeRoot: runtime.root)
        note("Typing on the \(layout.name) keyboard layout, with layout data from the iOS \(runtime.version) simulator runtime")
        return TypingLayout(runtime: Runtime(name: layout.name, root: runtime.root.path))
    }

    static let deviceAutomatic = CLIError(
        errorDescription: "--layout auto works on simulators only: a physical device does not report the keyboard in use. Name the device's keyboard layout, such as --layout German, or leave --layout out to send US key positions.",
        code: .invalidArguments)
}

/// An installed iOS simulator runtime's root, with the system it runs. A physical device has no
/// layout data on this Mac; the runtimes carry the same `USBKeyboardLayouts.bundle` iOS ships.
struct SimulatorRuntimeRoot: Equatable, Sendable {
    let root: URL
    let version: String
    let build: String

    /// The iOS simulator runtimes on this Mac, read from their system version files.
    static func installed() -> [SimulatorRuntimeRoot] {
        let fileManager = FileManager.default
        let containers = ["/Library/Developer/CoreSimulator/Volumes", "/private/var/run/com.apple.security.cryptexd/mnt"]
            .flatMap { base in ((try? fileManager.contentsOfDirectory(atPath: base)) ?? []).map { "\(base)/\($0)" } }
        let profileDirectories = containers.map { "\($0)/Library/Developer/CoreSimulator/Profiles/Runtimes" }
            + ["/Library/Developer/CoreSimulator/Profiles/Runtimes"]
        var found: [SimulatorRuntimeRoot] = []
        for directory in profileDirectories {
            for name in (try? fileManager.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".simruntime") {
                let root = URL(fileURLWithPath: "\(directory)/\(name)/Contents/Resources/RuntimeRoot")
                let versionFile = root.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
                guard let system = RuntimeKeyboardLayout.propertyList(at: versionFile) as? [String: Any],
                      ["iPhone OS", "iOS"].contains(system["ProductName"] as? String ?? ""),
                      let version = system["ProductVersion"] as? String, let build = system["ProductBuildVersion"] as? String
                else { continue }
                found.append(SimulatorRuntimeRoot(root: root, version: version, build: build))
            }
        }
        return found
    }

    /// The runtime with the device's version, else the nearest one. Nil when none is installed.
    static func closest(to deviceVersion: String?, in runtimes: [SimulatorRuntimeRoot]) -> SimulatorRuntimeRoot? {
        func value(_ version: String) -> Int {
            let parts = numbers(version)
            return (parts.first ?? 0) * 10_000 + (parts.dropFirst().first ?? 0) * 100 + (parts.dropFirst(2).first ?? 0)
        }
        guard let deviceVersion else { return runtimes.max { value($0.version) < value($1.version) } }
        let target = value(deviceVersion)
        // Ties go to the newer runtime, whose layouts are a superset in every pair measured.
        return runtimes.min { (abs(value($0.version) - target), -value($0.version)) < (abs(value($1.version) - target), -value($1.version)) }
    }

    private static func numbers(_ version: String) -> [Int] {
        var parts = version.split(separator: ".").compactMap { Int($0) }
        while parts.count > 2, parts.last == 0 { parts.removeLast() }
        return parts
    }
}

/// Where a booted simulator keeps its runtime and its data, read from its launch process so
/// that no simulator set has to be loaded.
struct SimulatorFiles {
    let runtimeRoot: URL
    let dataPath: URL

    static func booted(udid: String) -> SimulatorFiles? {
        var processes = FBProcessFetcher().processes(withProcessName: "launchd_sim").filter {
            $0.environment["SIMULATOR_UDID"]?.caseInsensitiveCompare(udid) == .orderedSame
        }
        // A reboot can leave the old launch process for a moment; the broker's rule picks the live one.
        if processes.count > 1, let boot = try? HIDBroker.currentBootIdentity(simulatorUDID: udid) {
            processes = processes.filter { $0.processIdentifier == boot.processIdentifier }
        }
        guard let process = processes.first,
              let root = process.environment["SIMULATOR_ROOT"], let home = process.environment["HOME"],
              root.hasPrefix("/"), home.hasPrefix("/") else { return nil }
        return SimulatorFiles(runtimeRoot: URL(fileURLWithPath: root), dataPath: URL(fileURLWithPath: home))
    }
}
