import ArgumentParser
import Foundation
import Testing
@testable import AXe

/// Fixtures are `devicectl` 689.2 JSON captured from an iOS 27.2 simulator and an iPhone, with the
/// `info.arguments` field removed.
@Suite("Settings")
struct SettingsTests {
    private let simulator = "B2BEE33F-7E61-4771-8A87-740676AF1D41"

    private static let appearance = #"""
    {"info":{"commandType":"devicectl.device.info.appearance","environment":{},"jsonVersion":6,"outcome":"success","version":"689.2"},"result":{"colorFilter":{"enabled":false},"deviceIdentifier":"B2BEE33F-7E61-4771-8A87-740676AF1D41","increaseContrast":false,"largerAccessibilitySizesEnabled":false,"liquidGlassOpacity":0.5,"lookAndFeel":"Liquid Glass","reduceMotion":{"enabled":false},"reduceTransparency":{"enabled":false},"showBorders":{"enabled":false},"supportedLooksAndFeels":["Liquid Glass"],"textSize":"Large","userInterfaceStyle":"light"}}
    """#

    private static let modifiedAppearance = #"""
    {"info":{"commandType":"devicectl.device.info.appearance","environment":{},"jsonVersion":6,"outcome":"success","version":"689.2"},"result":{"colorFilter":{"enabled":true,"filterType":{"name":"Protanopia"},"intensity":0.6},"deviceIdentifier":"B2BEE33F-7E61-4771-8A87-740676AF1D41","increaseContrast":false,"largerAccessibilitySizesEnabled":true,"liquidGlassOpacity":0.5,"lookAndFeel":"Liquid Glass","reduceMotion":{"enabled":false},"reduceTransparency":{"enabled":false},"showBorders":{"enabled":false},"supportedLooksAndFeels":["Liquid Glass"],"textSize":"Accessibility Large","userInterfaceStyle":"dark"}}
    """#

    private static let voiceOver = #"""
    {"info":{"commandType":"devicectl.device.info.voiceover","environment":{},"jsonVersion":6,"outcome":"success","version":"689.2"},"result":{"deviceIdentifier":"B2BEE33F-7E61-4771-8A87-740676AF1D41","enabled":false,"operation":"query"}}
    """#

    private static let accessibilitySizeError = #"""
    {"error":{"code":21031,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"NSLocalizedDescription":{"string":"Failed to set the device's appearance on device B2BEE33F-7E61-4771-8A87-740676AF1D41."},"NSUnderlyingError":{"error":{"code":21063,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"NSLocalizedDescription":{"string":"Enable Larger Accessibility Sizes on the device before setting an accessibility text size."}}}}}},"errorSignature":"(com.apple.dt.CoreDeviceError 21031 (com.apple.dt.CoreDeviceError 21063))","info":{"commandType":"devicectl.device.settings.appearance","environment":{},"jsonVersion":6,"outcome":"failed","version":"689.2"}}
    """#

    private static let notBootedError = #"""
    {"error":{"code":1001,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"CapabilityFeatureIdentifier":{"string":"com.apple.coredevice.feature.customizeuistyle"},"CapabilityName":{"string":"Customize User Interface Style"},"DeviceIdentifier":{"string":"004D6D62-331B-4758-B73C-1F438CA3085F"},"NSLocalizedDescription":{"string":"The simulator must be booted to use this capability."},"NSUnderlyingError":{"error":{"code":1001,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"NSLocalizedDescription":{"string":"The simulator must be booted to use this capability."}}}}}},"errorSignature":"(com.apple.dt.CoreDeviceError 1001 (com.apple.dt.CoreDeviceError 1001))","info":{"commandType":"devicectl.device.info.appearance","environment":{},"jsonVersion":6,"outcome":"failed","version":"689.2"}}
    """#

    private static let notFoundError = #"""
    {"error":{"code":1000,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"DeviceName":{"string":"11111111-2222-3333-4444-555555555555"},"NSLocalizedDescription":{"string":"The specified device was not found. (Name: 11111111-2222-3333-4444-555555555555)"}}},"errorSignature":"(com.apple.dt.CoreDeviceError 1000)","info":{"commandType":"devicectl.device.info.appearance","environment":{},"jsonVersion":6,"outcome":"failed","version":"689.2"}}
    """#

    private static let deviceStatusBarError = #"""
    {"error":{"code":1001,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"CapabilityFeatureIdentifier":{"string":"com.apple.coredevice.feature.simulateStatusBar"},"CapabilityName":{"string":"Simulate Status Bar"},"DeviceIdentifier":{"string":"EB6F8203-52C1-56E7-A426-8A35A437E075"},"NSLocalizedDescription":{"string":"The capability “Simulate Status Bar” is not supported by this device."}}},"errorSignature":"(com.apple.dt.CoreDeviceError 1001)","info":{"commandType":"devicectl.device.simulate.statusBar.show","environment":{},"jsonVersion":6,"outcome":"failed","version":"689.2"}}
    """#

    private static let statusBar = #"""
    {"info":{"commandType":"devicectl.device.simulate.statusBar.show","environment":{},"jsonVersion":6,"outcome":"success","version":"689.2"},"result":{"batteryFailingToCharge":false,"batteryLevel":42,"batteryState":"charging","cellularMode":"active","cellularStrength":3,"dataNetworkType":"`5G`","deviceIdentifier":"B2BEE33F-7E61-4771-8A87-740676AF1D41","time":"10:10","wifiMode":"active","wifiStrength":2}}
    """#

    private static let emptyStatusBar = #"""
    {"info":{"commandType":"devicectl.device.simulate.statusBar.show","environment":{},"jsonVersion":6,"outcome":"success","version":"689.2"},"result":{"deviceIdentifier":"B2BEE33F-7E61-4771-8A87-740676AF1D41"}}
    """#

    private static let locationList = #"""
    {"info":{"commandType":"devicectl.device.simulate.location.list","environment":{},"jsonVersion":6,"outcome":"success","version":"689.2"},"result":{"availableScenarios":[{"localizedName":"City Run","name":"City Run"},{"localizedName":"City Bicycle Ride","name":"City Bicycle Ride"},{"localizedName":"Freeway Drive","name":"Freeway Drive"},{"localizedName":"Apple","name":"Apple"}],"deviceIdentifier":"B2BEE33F-7E61-4771-8A87-740676AF1D41"}}
    """#

    private func decode<Result: Decodable>(_ json: String, succeeded: Bool = true) throws -> Result {
        try CoreDeviceInventory.result(fromJSON: Data(json.utf8), succeeded: succeeded, operation: "test")
    }

    private func failure(_ json: String) -> CoreDeviceFailure? {
        do {
            let _: ReportedNothing = try decode(json, succeeded: false)
            return nil
        } catch {
            return error as? CoreDeviceFailure
        }
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] ?? [:]
    }

    // MARK: Arguments

    @Test func setRequiresAValidOption() throws {
        let base = ["--udid", simulator]
        for args in [base, base + ["--liquid-glass-opacity", "1.5"], base + ["--liquid-glass-opacity", "-0.1"],
                     base + ["--color-filter-intensity", "0.2"], base + ["--color-filter-intensity", "1.1"],
                     base + ["--color-filter", "grayscale", "--color-filter-intensity", "0.5"],
                     base + ["--color-filter", "off", "--color-filter-intensity", "0.5"],
                     base + ["--appearance", "purple"], base + ["--text-size", "huge"], base + ["--voiceover", "yes"],
                     ["--udid", "not-a-udid", "--appearance", "dark"], ["--appearance", "dark"]] {
            #expect(throws: (any Error).self, "\(args)") { _ = try SettingsSet.parse(args) }
        }
        _ = try SettingsSet.parse(base + ["--color-filter-intensity", "0.25"])
        _ = try SettingsSet.parse(["--udid", "00008140-000415942291401C", "--liquid-glass-opacity", "0"])
    }

    @Test func noOptionMessageIsPlain() {
        #expect(throws: ValidationError.self) { try SettingsChange().validate() }
        do { try SettingsChange().validate() } catch {
            #expect((error as? ValidationError)?.message == "Pass at least one setting to change.")
        }
    }

    @Test func appearanceOptionsMakeOneCall() throws {
        let command = try SettingsSet.parse(["--udid", simulator, "--appearance", "dark", "--text-size", "accessibility-large",
            "--increase-contrast", "on", "--reduce-motion", "off", "--reduce-transparency", "on", "--show-borders", "off",
            "--liquid-glass-opacity", "0.75", "--color-filter", "protanopia", "--color-filter-intensity", "0.5"])
        #expect(command.change.appearanceArguments(device: "D") == [
            "device", "settings", "appearance", "--device", "D", "--mode", "dark",
            "--larger-accessibility-sizes", "on", "--text-size", "accessibility-large",
            "--increase-contrast", "on", "--reduce-motion", "off", "--reduce-transparency", "on", "--show-borders", "off",
            "--liquid-glass-opacity", "0.75", "--color-filter", "on", "--color-filter-type", "protanopia",
            "--color-filter-intensity", "0.5"])
        #expect(command.change.voiceOverArguments(device: "D") == nil)
    }

    @Test func standardTextSizeTurnsLargerSizesOff() {
        let change = SettingsChange(textSize: .extraLarge, colorFilter: .off)
        #expect(change.appearanceArguments(device: "D") == [
            "device", "settings", "appearance", "--device", "D", "--larger-accessibility-sizes", "off",
            "--text-size", "extra-large", "--color-filter", "off"])
        for size in SettingTextSize.allCases {
            let arguments = SettingsChange(textSize: size).appearanceArguments(device: "D") ?? []
            let index = try? #require(arguments.firstIndex(of: "--larger-accessibility-sizes"))
            #expect(index.map { arguments[$0 + 1] } == (size.isAccessibility ? "on" : "off"), "\(size)")
        }
        #expect(SettingsChange(appearance: .dark).appearanceArguments(device: "D")?
            .contains("--larger-accessibility-sizes") == false)
    }

    @Test func voiceOverAloneMakesOnlyTheVoiceOverCall() {
        let on = SettingsChange(voiceOver: .on)
        #expect(on.appearanceArguments(device: "D") == nil)
        #expect(on.voiceOverArguments(device: "D") == ["device", "settings", "voiceover", "--device", "D", "--enable"])
        #expect(SettingsChange(voiceOver: .off).voiceOverArguments(device: "D")?.last == "--disable")
    }

    @Test func locationAndStatusBarArguments() throws {
        let location = try SettingsLocation.Set.parse(["--udid", simulator, "--latitude", "-33.86", "--longitude", "151.2"])
        #expect(location.latitude == -33.86 && location.longitude == 151.2)
        for args in [["--latitude", "91", "--longitude", "0"], ["--latitude", "0", "--longitude", "-181"]] {
            #expect(throws: (any Error).self) { _ = try SettingsLocation.Set.parse(["--udid", simulator] + args) }
        }
        #expect(throws: (any Error).self) { _ = try SettingsStatusBar.Set.parse(["--udid", simulator]) }
        for args in [["--wifi-bars", "4"], ["--cellular-bars", "6"], ["--battery-level", "101"], ["--data-network", "6G"]] {
            #expect(throws: (any Error).self) { _ = try SettingsStatusBar.Set.parse(["--udid", simulator] + args) }
        }
        let statusBar = try SettingsStatusBar.Set.parse(["--udid", simulator, "--time", "9:41", "--data-network", "lte",
            "--wifi-bars", "0", "--cellular-bars", "4", "--battery-level", "80", "--battery-state", "charged"])
        #expect(statusBar.change.arguments(device: "D") == [
            "device", "simulate", "statusBar", "override", "--device", "D", "--time", "9:41", "--data-network", "LTE",
            "--wifi-mode", "failed", "--cellular-mode", "active", "--cellular-strength", "4",
            "--battery-level", "80", "--battery-state", "charged"])
        #expect(throws: (any Error).self) { _ = try SettingsStatusBar.Preset.parse(["bogus", "--udid", simulator]) }
        #expect(try SettingsStatusBar.Preset.parse(["low-battery", "--udid", simulator]).name == .lowBattery)
    }

    // MARK: Parsing devicectl JSON

    @Test func readsDefaultSettings() throws {
        let output = DeviceSettingsOutput(udid: simulator, appearance: try decode(Self.appearance),
            voiceOver: try decode(Self.voiceOver))
        #expect(output.textLines == [
            "Appearance            light",
            "Text size             large",
            "Increase Contrast     off",
            "Reduce Motion         off",
            "Reduce Transparency   off",
            "Show Borders          off",
            "Liquid Glass          opacity 0.5",
            "Colour filter         off",
            "VoiceOver             off",
        ])
        let json = try encoded(output)
        #expect(Set(json.keys) == ["udid", "appearance", "textSize", "increaseContrast", "reduceMotion",
            "reduceTransparency", "showBorders", "liquidGlass", "colorFilter", "voiceOver"])
        #expect(json["appearance"] as? String == "light")
        #expect(json["textSize"] as? String == "large")
        #expect(json["voiceOver"] as? Bool == false)
        #expect((json["liquidGlass"] as? [String: Any])?.keys.sorted() == ["opacity"])
        #expect((json["colorFilter"] as? [String: Any])?.keys.sorted() == ["enabled"])
    }

    @Test func readsChangedSettingsInTheirInputSpelling() throws {
        let output = DeviceSettingsOutput(udid: simulator, appearance: try decode(Self.modifiedAppearance), voiceOver: nil)
        #expect(output.appearance == .dark && output.textSize == .accessibilityLarge)
        #expect(output.colorFilter == .init(enabled: true, type: .protanopia, intensity: 0.6))
        #expect(output.voiceOver == nil)
        #expect(output.textLines.contains("Text size             accessibility-large"))
        #expect(output.textLines.contains("Colour filter         protanopia, intensity 0.6"))
        #expect(!output.textLines.contains { $0.hasPrefix("VoiceOver") })
        let json = try encoded(output)
        #expect(json["voiceOver"] == nil)
        #expect(json["colorFilter"] as? [String: AnyHashable] == ["enabled": true, "type": "protanopia", "intensity": 0.6])
        for size in SettingTextSize.allCases {
            let words = size.rawValue.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
            #expect(SettingTextSize(reported: words) == size)
        }
    }

    @Test func unsupportedFieldsAreOmitted() throws {
        let output = DeviceSettingsOutput(udid: simulator, appearance: try JSONDecoder().decode(ReportedAppearance.self,
            from: Data(#"{"userInterfaceStyle":"dark","lookAndFeel":"Tinted"}"#.utf8)), voiceOver: nil)
        #expect(output.textLines == ["Appearance     dark", "Liquid Glass   tinted"])
        #expect(try encoded(output).keys.sorted() == ["appearance", "liquidGlass", "udid"])
    }

    @Test func failuresCarryTheInnermostDescription() throws {
        let size = try #require(failure(Self.accessibilitySizeError))
        #expect(size.codes == [21031, 21063])
        #expect(size.message == "Enable Larger Accessibility Sizes on the device before setting an accessibility text size.")
        let mapped = DeviceSettings.failure(size, udid: simulator)
        #expect(mapped.code == "settingFailed" && mapped.message == size.message)

        let booted = DeviceSettings.failure(try #require(failure(Self.notBootedError)), udid: "004D6D62-331B-4758-B73C-1F438CA3085F")
        #expect(booted.code == "notBooted" && booted.message.contains("xcrun simctl boot 004D6D62"))

        #expect(DeviceSettings.failure(try #require(failure(Self.notFoundError)), udid: "X").code == "targetNotFound")

        let statusBar = DeviceSettings.failure(try #require(failure(Self.deviceStatusBarError)), udid: "X")
        #expect(statusBar.code == "settingUnsupported")
        #expect(statusBar.message == "The capability \u{201C}Simulate Status Bar\u{201D} is not supported by this device.")
        // A failed exit status is a failure even when devicectl also wrote a result.
        #expect(failure(Self.voiceOver) == CoreDeviceFailure(codes: [], message: "devicectl test failed."))
    }

    @Test func statusBarAndLocationOutput() throws {
        let output = StatusBarOutput(udid: simulator, reported: try decode(Self.statusBar))
        #expect(output.dataNetwork == "5G" && output.wifiBars == 2 && output.cellularBars == 3 && output.overridden)
        #expect(output.textLines == [
            "Time            10:10",
            "Data network    5G",
            "Wi-Fi bars      2",
            "Cellular bars   3",
            "Battery         42%, charging",
        ])
        #expect(try encoded(output).keys.sorted() == ["batteryLevel", "batteryState", "cellularBars", "dataNetwork",
            "overridden", "time", "udid", "wifiBars"])
        let empty = StatusBarOutput(udid: simulator, reported: try decode(Self.emptyStatusBar))
        #expect(!empty.overridden && empty.textLines == ["Status bar not overridden"])

        let list: ReportedLocationScenarios = try decode(Self.locationList)
        let scenarios = LocationOutput(udid: simulator, scenarios: list.availableScenarios.map(\.name))
        #expect(scenarios.textLines == ["City Run", "City Bicycle Ride", "Freeway Drive", "Apple"])
        #expect(LocationOutput(udid: simulator, latitude: 51.5, longitude: -0.12).textLines == ["Location  51.5, -0.12"])
        #expect(try encoded(LocationOutput(udid: simulator, cleared: true)).keys.sorted() == ["cleared", "udid"])
    }
}
