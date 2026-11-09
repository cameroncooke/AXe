import ArgumentParser
import Foundation

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read and change device-wide settings on a simulator or physical device.",
        subcommands: [SettingsShow.self, SettingsSet.self, SettingsLocation.self, SettingsStatusBar.self])
}

/// The target option shared by every settings command.
struct SettingsTarget: ParsableArguments {
    @Option(name: .customLong("udid"), help: "The simulator or device UDID.")
    var udid: String

    func validate() throws {
        let udid = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AutomationTarget.isPhysicalInputUDID(udid) || UUID(uuidString: udid) != nil else {
            throw ValidationError("--udid must be a simulator or device UDID.")
        }
    }

    var trimmed: String { udid.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct SettingsShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show",
        abstract: "Show appearance, text size, accessibility display settings and VoiceOver.")

    @OptionGroup var target: SettingsTarget

    func run() async throws {
        let device = try await DeviceSettings.prepare(udid: target.trimmed)
        let output = try await DeviceSettings.read(device: device, udid: target.trimmed)
        try DeviceState.emit(output, text: output.textLines)
    }
}

struct SettingsSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set",
        abstract: "Change one or more settings, then show the result.")

    @OptionGroup var target: SettingsTarget
    @Option(help: "Interface style.") var appearance: SettingAppearance?
    @Option(help: "Text size. An accessibility size also turns on Larger Accessibility Sizes.")
    var textSize: SettingTextSize?
    @Option(help: "Increase Contrast.") var increaseContrast: SettingSwitch?
    @Option(help: "Reduce Motion.") var reduceMotion: SettingSwitch?
    @Option(help: "Reduce Transparency.") var reduceTransparency: SettingSwitch?
    @Option(help: "Button Shapes (Show Borders).") var showBorders: SettingSwitch?
    @Option(help: "Liquid Glass style, where the device offers one.") var liquidGlass: LiquidGlassStyle?
    @Option(help: "0 (translucent) to 1 (opaque).") var liquidGlassOpacity: Double?
    @Option(help: "Colour filter; off disables it.") var colorFilter: ColorFilterChoice?
    @Option(help: "0.25 to 1; not for grayscale.") var colorFilterIntensity: Double?
    @Option(help: "VoiceOver.") var voiceover: SettingSwitch?

    var change: SettingsChange {
        SettingsChange(appearance: appearance, textSize: textSize, increaseContrast: increaseContrast,
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, showBorders: showBorders,
            liquidGlass: liquidGlass, liquidGlassOpacity: liquidGlassOpacity, colorFilter: colorFilter,
            colorFilterIntensity: colorFilterIntensity, voiceOver: voiceover)
    }

    func validate() throws { try change.validate() }

    func run() async throws {
        let udid = target.trimmed
        let device = try await DeviceSettings.prepare(udid: udid)
        if let liquidGlass { try await DeviceSettings.requireLiquidGlassStyle(liquidGlass, device: device, udid: udid) }
        if let arguments = change.appearanceArguments(device: device) {
            let _: ReportedNothing = try await DeviceSettings.perform(arguments, udid: udid)
        }
        if let arguments = change.voiceOverArguments(device: device) {
            let _: ReportedNothing = try await DeviceSettings.perform(arguments, udid: udid)
        }
        let output = try await DeviceSettings.read(device: device, udid: udid)
        try DeviceState.emit(output, text: output.textLines)
    }
}

struct SettingsLocation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "location",
        abstract: "Simulate the device location.",
        subcommands: [Set.self, Clear.self, Scenarios.self, Scenario.self])

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Simulate a fixed coordinate until cleared.")

        @OptionGroup var target: SettingsTarget
        @Option(parsing: .unconditional, help: "Degrees, -90 to 90.") var latitude: Double
        @Option(parsing: .unconditional, help: "Degrees, -180 to 180.") var longitude: Double

        func validate() throws {
            guard (-90...90).contains(latitude) else { throw ValidationError("--latitude must be from -90 to 90.") }
            guard (-180...180).contains(longitude) else { throw ValidationError("--longitude must be from -180 to 180.") }
        }

        func run() async throws {
            let udid = target.trimmed
            let device = try await DeviceSettings.prepare(udid: udid)
            let _: ReportedNothing = try await DeviceSettings.perform(["device", "simulate", "location", "coordinate",
                "--device", device, "--latitude=\(latitude)", "--longitude=\(longitude)"], udid: udid)
            let output = LocationOutput(udid: udid, latitude: latitude, longitude: longitude)
            try DeviceState.emit(output, text: output.textLines)
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop location simulation.")

        @OptionGroup var target: SettingsTarget

        func run() async throws {
            let udid = target.trimmed
            let device = try await DeviceSettings.prepare(udid: udid)
            let _: ReportedNothing = try await DeviceSettings.perform(
                ["device", "simulate", "location", "clear", "--device", device], udid: udid)
            let output = LocationOutput(udid: udid, cleared: true)
            try DeviceState.emit(output, text: output.textLines)
        }
    }

    struct Scenarios: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the location scenario names.")

        @OptionGroup var target: SettingsTarget

        func run() async throws {
            let udid = target.trimmed
            let device = try await DeviceSettings.prepare(udid: udid)
            let list: ReportedLocationScenarios = try await DeviceSettings.perform(
                ["device", "simulate", "location", "list", "--device", device], udid: udid)
            let output = LocationOutput(udid: udid, scenarios: list.availableScenarios.map(\.name))
            try DeviceState.emit(output, text: output.textLines)
        }
    }

    struct Scenario: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Play a named location scenario until cleared.")

        @Argument(help: "A name from `axe settings location scenarios`.") var name: String
        @OptionGroup var target: SettingsTarget

        func validate() throws {
            guard !name.isEmpty, !name.hasPrefix("-") else { throw ValidationError("Pass a scenario name.") }
        }

        func run() async throws {
            let udid = target.trimmed
            let device = try await DeviceSettings.prepare(udid: udid)
            let _: ReportedNothing = try await DeviceSettings.perform(
                ["device", "simulate", "location", "scenario", "--device", device, name], udid: udid)
            let output = LocationOutput(udid: udid, scenario: name)
            try DeviceState.emit(output, text: output.textLines)
        }
    }
}

struct SettingsStatusBar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status-bar",
        abstract: "Override what the status bar shows.",
        subcommands: [Show.self, Clear.self, Preset.self, Set.self])

    /// Runs one change, then reads the status bar back.
    static func apply(_ arguments: [String]?, target: SettingsTarget) async throws {
        let udid = target.trimmed
        let device = try await DeviceSettings.prepare(udid: udid)
        if let arguments {
            let _: ReportedNothing = try await DeviceSettings.perform(
                ["device", "simulate", "statusBar"] + arguments + ["--device", device], udid: udid)
        }
        let output = try await DeviceSettings.readStatusBar(device: device, udid: udid)
        try DeviceState.emit(output, text: output.textLines)
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the active status bar overrides.")
        @OptionGroup var target: SettingsTarget
        func run() async throws { try await SettingsStatusBar.apply(nil, target: target) }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove every status bar override.")
        @OptionGroup var target: SettingsTarget
        func run() async throws { try await SettingsStatusBar.apply(["clear"], target: target) }
    }

    struct Preset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Apply a status bar preset.")
        @Argument(help: "Preset name.") var name: StatusBarPreset
        @OptionGroup var target: SettingsTarget
        func run() async throws { try await SettingsStatusBar.apply(["preset", name.rawValue], target: target) }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Override individual status bar values.")

        @OptionGroup var target: SettingsTarget
        @Option(help: "Text to show as the time, such as 9:41.") var time: String?
        @Option(help: "Data network type.")
        var dataNetwork: StatusBarDataNetwork?
        @Option(help: "0 to 3; 0 shows no connection.") var wifiBars: Int?
        @Option(help: "0 to 5; 0 shows no connection.") var cellularBars: Int?
        @Option(help: "0 to 100.") var batteryLevel: Int?
        @Option(help: "Battery state.") var batteryState: StatusBarBatteryState?

        var change: StatusBarChange {
            StatusBarChange(time: time, dataNetwork: dataNetwork, wifiBars: wifiBars, cellularBars: cellularBars,
                batteryLevel: batteryLevel, batteryState: batteryState)
        }

        func validate() throws { try change.validate() }

        func run() async throws {
            let udid = target.trimmed
            let device = try await DeviceSettings.prepare(udid: udid)
            let _: ReportedNothing = try await DeviceSettings.perform(change.arguments(device: device), udid: udid)
            let output = try await DeviceSettings.readStatusBar(device: device, udid: udid)
            try DeviceState.emit(output, text: output.textLines)
        }
    }
}
