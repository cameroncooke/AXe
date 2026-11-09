import ArgumentParser
import Foundation

// Device-wide settings through `xcrun devicectl`, which addresses simulators and physical devices alike.

enum SettingSwitch: String, CaseIterable, ExpressibleByArgument, Sendable {
    case on, off
    var enabled: Bool { self == .on }
}

enum SettingAppearance: String, CaseIterable, Encodable, ExpressibleByArgument, Sendable { case light, dark }

enum LiquidGlassStyle: String, CaseIterable, Encodable, ExpressibleByArgument, Sendable { case clear, tinted }

enum ColorFilterChoice: String, CaseIterable, Encodable, ExpressibleByArgument, Sendable {
    case off, grayscale, protanopia, deuteranopia, tritanopia
}

/// The devicectl spelling, which `settings show` also prints, so a shown value can be passed back.
enum SettingTextSize: String, CaseIterable, Encodable, ExpressibleByArgument, Sendable {
    case extraSmall = "extra-small", small, medium, large, extraLarge = "extra-large"
    case extraExtraLarge = "extra-extra-large", extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibilityMedium = "accessibility-medium", accessibilityLarge = "accessibility-large"
    case accessibilityExtraLarge = "accessibility-extra-large"
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"

    var isAccessibility: Bool { rawValue.hasPrefix("accessibility-") }

    /// devicectl reports sizes as words, for example `Accessibility Large`.
    init?(reported: String) {
        self.init(rawValue: reported.lowercased().split(separator: " ").joined(separator: "-"))
    }
}

/// The options of one `settings set`. Appearance options go in one devicectl call, VoiceOver in another.
struct SettingsChange: Equatable, Sendable {
    var appearance: SettingAppearance?
    var textSize: SettingTextSize?
    var increaseContrast: SettingSwitch?
    var reduceMotion: SettingSwitch?
    var reduceTransparency: SettingSwitch?
    var showBorders: SettingSwitch?
    var liquidGlass: LiquidGlassStyle?
    var liquidGlassOpacity: Double?
    var colorFilter: ColorFilterChoice?
    var colorFilterIntensity: Double?
    var voiceOver: SettingSwitch?

    func validate() throws {
        if self == SettingsChange() {
            throw ValidationError("Pass at least one setting to change.")
        }
        if let liquidGlassOpacity, !(0...1).contains(liquidGlassOpacity) {
            throw ValidationError("--liquid-glass-opacity must be from 0 to 1.")
        }
        if let colorFilterIntensity {
            guard (0.25...1).contains(colorFilterIntensity) else {
                throw ValidationError("--color-filter-intensity must be from 0.25 to 1.")
            }
            if colorFilter == .off || colorFilter == .grayscale {
                throw ValidationError("--color-filter-intensity does not apply to --color-filter \(colorFilter!.rawValue).")
            }
        }
    }

    /// nil when no appearance option is set. An accessibility text size turns on Larger Accessibility
    /// Sizes in the same call, because devicectl refuses one without the other.
    func appearanceArguments(device: String) -> [String]? {
        var options: [String] = []
        if let appearance { options += ["--mode", appearance.rawValue] }
        if let liquidGlass { options += ["--look-and-feel", liquidGlass.rawValue] }
        if let textSize {
            if textSize.isAccessibility { options += ["--larger-accessibility-sizes", "on"] }
            options += ["--text-size", textSize.rawValue]
        }
        if let increaseContrast { options += ["--increase-contrast", increaseContrast.rawValue] }
        if let reduceMotion { options += ["--reduce-motion", reduceMotion.rawValue] }
        if let reduceTransparency { options += ["--reduce-transparency", reduceTransparency.rawValue] }
        if let showBorders { options += ["--show-borders", showBorders.rawValue] }
        if let liquidGlassOpacity { options += ["--liquid-glass-opacity", String(liquidGlassOpacity)] }
        switch colorFilter {
        case .off?: options += ["--color-filter", "off"]
        case let type?: options += ["--color-filter", "on", "--color-filter-type", type.rawValue]
        case nil: break
        }
        if let colorFilterIntensity {
            options += ["--color-filter-intensity", String(colorFilterIntensity)]
        }
        guard !options.isEmpty else { return nil }
        return ["device", "settings", "appearance", "--device", device] + options
    }

    func voiceOverArguments(device: String) -> [String]? {
        voiceOver.map { ["device", "settings", "voiceover", "--device", device, $0 == .on ? "--enable" : "--disable"] }
    }
}

/// The `info appearance` result. Every field is optional: a device leaves out what it does not support.
struct ReportedAppearance: Decodable, Sendable {
    struct Toggle: Decodable, Sendable { let enabled: Bool? }
    struct ColorFilter: Decodable, Sendable {
        struct FilterType: Decodable, Sendable { let name: String? }
        let enabled: Bool?
        let filterType: FilterType?
        let intensity: Double?
    }

    let userInterfaceStyle: String?
    let textSize: String?
    let increaseContrast: Bool?
    let reduceMotion: Toggle?
    let reduceTransparency: Toggle?
    let showBorders: Toggle?
    let lookAndFeel: String?
    let supportedLooksAndFeels: [String]?
    let liquidGlassOpacity: Double?
    let colorFilter: ColorFilter?
}

struct ReportedVoiceOver: Decodable, Sendable { let enabled: Bool? }

/// What `settings show` and `settings set` print. Fields the device does not report are omitted.
struct DeviceSettingsOutput: Encodable, Equatable, Sendable {
    struct LiquidGlass: Encodable, Equatable, Sendable {
        let style: LiquidGlassStyle?
        let opacity: Double?
    }
    struct ColorFilter: Encodable, Equatable, Sendable {
        let enabled: Bool
        let type: ColorFilterChoice?
        let intensity: Double?
    }

    let udid: String
    let appearance: SettingAppearance?
    let textSize: SettingTextSize?
    let increaseContrast: Bool?
    let reduceMotion: Bool?
    let reduceTransparency: Bool?
    let showBorders: Bool?
    let liquidGlass: LiquidGlass?
    let colorFilter: ColorFilter?
    let voiceOver: Bool?

    init(udid: String, appearance reported: ReportedAppearance, voiceOver: ReportedVoiceOver?) {
        self.udid = udid
        appearance = reported.userInterfaceStyle.flatMap { SettingAppearance(rawValue: $0.lowercased()) }
        textSize = reported.textSize.flatMap(SettingTextSize.init(reported:))
        increaseContrast = reported.increaseContrast
        reduceMotion = reported.reduceMotion?.enabled
        reduceTransparency = reported.reduceTransparency?.enabled
        showBorders = reported.showBorders?.enabled
        // A device without a style choice reports its look and feel as `Liquid Glass`.
        let style = reported.lookAndFeel.flatMap { LiquidGlassStyle(rawValue: $0.lowercased()) }
        let opacity = reported.liquidGlassOpacity.map { (($0 * 100).rounded()) / 100 }
        liquidGlass = style == nil && opacity == nil ? nil : LiquidGlass(style: style, opacity: opacity)
        colorFilter = reported.colorFilter?.enabled.map { enabled in
            ColorFilter(enabled: enabled,
                type: reported.colorFilter?.filterType?.name.flatMap { ColorFilterChoice(rawValue: $0.lowercased()) },
                intensity: reported.colorFilter?.intensity.map { (($0 * 100).rounded()) / 100 })
        }
        self.voiceOver = voiceOver?.enabled
    }

    var textLines: [String] {
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        var rows: [(String, String)] = []
        if let appearance { rows.append(("Appearance", appearance.rawValue)) }
        if let textSize { rows.append(("Text size", textSize.rawValue)) }
        if let increaseContrast { rows.append(("Increase Contrast", onOff(increaseContrast))) }
        if let reduceMotion { rows.append(("Reduce Motion", onOff(reduceMotion))) }
        if let reduceTransparency { rows.append(("Reduce Transparency", onOff(reduceTransparency))) }
        if let showBorders { rows.append(("Show Borders", onOff(showBorders))) }
        if let liquidGlass {
            rows.append(("Liquid Glass", [liquidGlass.style?.rawValue,
                liquidGlass.opacity.map { "opacity " + DeviceSettings.number($0) }].compactMap { $0 }.joined(separator: ", ")))
        }
        if let colorFilter {
            var parts = [colorFilter.enabled ? (colorFilter.type?.rawValue ?? "on") : "off"]
            if colorFilter.enabled, let intensity = colorFilter.intensity {
                parts.append("intensity " + DeviceSettings.number(intensity))
            }
            rows.append(("Colour filter", parts.joined(separator: ", ")))
        }
        if let voiceOver { rows.append(("VoiceOver", onOff(voiceOver))) }
        return DeviceSettings.aligned(rows)
    }
}

enum StatusBarPreset: String, CaseIterable, ExpressibleByArgument, Sendable {
    case screenshot, lowBattery = "low-battery", noService = "no-service", charging
}

enum StatusBarBatteryState: String, CaseIterable, ExpressibleByArgument, Sendable { case draining, charging, charged }

/// The devicectl spellings; `--data-network` accepts them in any case.
enum StatusBarDataNetwork: String, CaseIterable, ExpressibleByArgument, Sendable {
    case hide, wifi, hotspot, oneX = "1x", gprs = "GPRS", edge = "Edge", umts = "UMTS", fourG = "4G"
    case lte = "LTE", lteA = "LTEA", ltePlus = "LTEPlus", fiveG = "5G", fiveGPlus = "5GPlus"
    case fiveGUWB = "5GUWB", fiveGUC = "5GUC"

    init?(argument: String) {
        guard let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(argument) == .orderedSame }) else {
            return nil
        }
        self = match
    }
}

struct StatusBarChange: Equatable, Sendable {
    var time: String?
    var dataNetwork: StatusBarDataNetwork?
    var wifiBars: Int?
    var cellularBars: Int?
    var batteryLevel: Int?
    var batteryState: StatusBarBatteryState?

    func validate() throws {
        if self == StatusBarChange() { throw ValidationError("Pass at least one status bar value to set.") }
        if let time, time.isEmpty || time.hasPrefix("-") { throw ValidationError("--time must be a time such as 9:41.") }
        if let wifiBars, !(0...3).contains(wifiBars) { throw ValidationError("--wifi-bars must be from 0 to 3.") }
        if let cellularBars, !(0...5).contains(cellularBars) { throw ValidationError("--cellular-bars must be from 0 to 5.") }
        if let batteryLevel, !(0...100).contains(batteryLevel) { throw ValidationError("--battery-level must be from 0 to 100.") }
    }

    /// Zero bars shows a failed connection; devicectl's signal strengths start at one bar.
    func arguments(device: String) -> [String] {
        var options: [String] = []
        if let time { options += ["--time", time] }
        if let dataNetwork { options += ["--data-network", dataNetwork.rawValue] }
        if let wifiBars {
            options += wifiBars == 0 ? ["--wifi-mode", "failed"] : ["--wifi-mode", "active", "--wifi-strength", String(wifiBars)]
        }
        if let cellularBars {
            options += cellularBars == 0 ? ["--cellular-mode", "failed"]
                : ["--cellular-mode", "active", "--cellular-strength", String(cellularBars)]
        }
        if let batteryLevel { options += ["--battery-level", String(batteryLevel)] }
        if let batteryState { options += ["--battery-state", batteryState.rawValue] }
        return ["device", "simulate", "statusBar", "override", "--device", device] + options
    }
}

/// The `statusBar show` result. devicectl leaves out every field when nothing is overridden.
struct ReportedStatusBar: Decodable, Sendable {
    let time: String?
    let dataNetworkType: String?
    let wifiMode: String?
    let wifiStrength: Int?
    let cellularMode: String?
    let cellularStrength: Int?
    let batteryLevel: Int?
    let batteryState: String?
}

struct StatusBarOutput: Encodable, Equatable, Sendable {
    let udid: String
    let overridden: Bool
    let time: String?
    let dataNetwork: String?
    let wifiBars: Int?
    let cellularBars: Int?
    let batteryLevel: Int?
    let batteryState: String?

    init(udid: String, reported: ReportedStatusBar) {
        self.udid = udid
        func bars(_ mode: String?, _ strength: Int?) -> Int? {
            guard let mode else { return nil }
            return mode == "active" ? strength : 0
        }
        time = reported.time
        // devicectl 689.2 wraps some network names in backticks, for example "`5G`".
        dataNetwork = reported.dataNetworkType?.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        wifiBars = bars(reported.wifiMode, reported.wifiStrength)
        cellularBars = bars(reported.cellularMode, reported.cellularStrength)
        batteryLevel = reported.batteryLevel
        batteryState = reported.batteryState
        overridden = time != nil || dataNetwork != nil || wifiBars != nil || cellularBars != nil
            || batteryLevel != nil || batteryState != nil
    }

    var textLines: [String] {
        guard overridden else { return ["Status bar not overridden"] }
        var rows: [(String, String)] = []
        if let time { rows.append(("Time", time)) }
        if let dataNetwork { rows.append(("Data network", dataNetwork)) }
        if let wifiBars { rows.append(("Wi-Fi bars", String(wifiBars))) }
        if let cellularBars { rows.append(("Cellular bars", String(cellularBars))) }
        if batteryLevel != nil || batteryState != nil {
            rows.append(("Battery", [batteryLevel.map { "\($0)%" }, batteryState].compactMap { $0 }.joined(separator: ", ")))
        }
        return DeviceSettings.aligned(rows)
    }
}

struct LocationOutput: Encodable, Equatable, Sendable {
    let udid: String
    var latitude: Double?
    var longitude: Double?
    var scenario: String?
    var cleared: Bool?
    var scenarios: [String]?

    var textLines: [String] {
        if let scenarios { return scenarios }
        if let latitude, let longitude { return ["Location  \(DeviceSettings.number(latitude)), \(DeviceSettings.number(longitude))"] }
        if let scenario { return ["Location scenario  \(scenario)"] }
        return ["Location cleared"]
    }
}

struct ReportedLocationScenarios: Decodable, Sendable {
    struct Scenario: Decodable, Sendable { let name: String }
    let availableScenarios: [Scenario]
}

/// Empty decodable result for commands whose reply AXe does not use.
struct ReportedNothing: Decodable, Sendable {}

enum DeviceSettings {
    static let unsupportedXcode = "Select Xcode 27 or later with xcode-select or DEVELOPER_DIR."

    /// Checks the target and returns the identifier to pass to devicectl. A simulator's readiness is
    /// checked by devicectl itself; a physical device goes through the inventory readiness checks.
    static func prepare(udid: String) async throws -> String {
        let udid = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AutomationTarget.isPhysicalInputUDID(udid) else { return udid }
        guard let listed = try await AutomationTarget.physicalDeviceRecord(udid: udid) else { return udid }
        let device = try await CoreDeviceInventory.details(for: listed)
        if let check = DeviceInspection.inventoryChecks(for: device).first(where: { $0.status != .ready }) {
            throw CLIOutputFailure(code: check.id, message: check.message ?? "The device is not ready.")
        }
        return device.identifier
    }

    static func read(device: String, udid: String) async throws -> DeviceSettingsOutput {
        async let appearance: ReportedAppearance = perform(["device", "info", "appearance", "--device", device], udid: udid)
        async let voiceOver: ReportedVoiceOver? = optional(["device", "info", "voiceover", "--device", device], udid: udid)
        return DeviceSettingsOutput(udid: udid, appearance: try await appearance, voiceOver: try await voiceOver)
    }

    /// iOS 27 reports one look and feel, `Liquid Glass`, and devicectl accepts a style there without
    /// applying it, so the style is checked before anything changes.
    static func requireLiquidGlassStyle(_ style: LiquidGlassStyle, device: String, udid: String) async throws {
        let reported: ReportedAppearance = try await perform(["device", "info", "appearance", "--device", device], udid: udid)
        guard reported.supportedLooksAndFeels?.contains(where: { $0.caseInsensitiveCompare(style.rawValue) == .orderedSame }) == true else {
            throw CLIOutputFailure(code: "settingUnsupported",
                message: "This device does not offer the \(style.rawValue) Liquid Glass style. Nothing was changed.")
        }
    }

    /// VoiceOver is read separately; a device or Xcode without it still shows its appearance.
    private static func optional<Result: Decodable>(_ arguments: [String], udid: String) async throws -> Result? {
        do { return try await perform(arguments, udid: udid) }
        catch let failure as CLIOutputFailure where failure.code == "settingUnsupported" { return nil }
    }

    static func readStatusBar(device: String, udid: String) async throws -> StatusBarOutput {
        StatusBarOutput(udid: udid, reported: try await perform(
            ["device", "simulate", "statusBar", "show", "--device", device], udid: udid))
    }

    /// Runs one devicectl command and maps its failure to one AXe error code.
    @discardableResult
    static func perform<Result: Decodable>(_ arguments: [String], udid: String) async throws -> Result {
        let operation = arguments.prefix(3).joined(separator: " ")
        let run = try await CoreDeviceInventory.run(arguments)
        guard let json = run.json else {
            // devicectl writes no JSON for a usage error, which is how an older Xcode refuses a subcommand.
            throw CLIOutputFailure(code: "settingUnsupported",
                message: "This Xcode's devicectl does not support `devicectl \(operation)`. \(unsupportedXcode)")
        }
        do {
            return try CoreDeviceInventory.result(fromJSON: json.contents, succeeded: json.succeeded, operation: operation)
        } catch let failure as CoreDeviceFailure {
            throw self.failure(failure, udid: udid)
        }
    }

    /// CoreDevice error 1000 is an unknown device; 1001 is a capability the device cannot provide now,
    /// which on a simulator means it is not booted.
    static func failure(_ failure: CoreDeviceFailure, udid: String) -> CLIOutputFailure {
        if failure.codes.first == 1000 {
            return CLIOutputFailure(code: "targetNotFound",
                message: "No simulator or physical device matches UDID \(udid). Run axe list-simulators or axe list-devices.")
        }
        if failure.codes.first == 1001 {
            if failure.message.localizedCaseInsensitiveContains("booted") {
                return CLIOutputFailure(code: "notBooted",
                    message: "Simulator \(udid) is not booted. Boot it first, for example with xcrun simctl boot \(udid).")
            }
            return CLIOutputFailure(code: "settingUnsupported", message: failure.message)
        }
        return CLIOutputFailure(code: "settingFailed", message: failure.message)
    }

    static func number(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func aligned(_ rows: [(String, String)]) -> [String] {
        let width = (rows.map(\.0.count).max() ?? 0) + 3
        return rows.map { $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + $0.1 }
    }
}
