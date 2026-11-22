import Foundation
import Testing
@testable import AXe

/// What a viewer is offered when the host lets it choose a simulator: read from simctl's list.
@Suite("Mirror simulator list")
struct MirrorSimulatorControlTests {
    private let phone = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
    private let tablet = "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A20-Pro"
    private let watch = "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-3"
    private let ios272 = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
    private let ios265 = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    private let ios2610 = "com.apple.CoreSimulator.SimRuntime.iOS-26-10"
    private let tvos = "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"
    private let gone = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"

    private func type(_ identifier: String, _ name: String, _ family: String) -> [String: Any] {
        ["identifier": identifier, "name": name, "productFamily": family]
    }

    private func runtime(_ identifier: String, _ name: String, _ version: String, platform: String = "iOS",
                         available: Bool = true, types: [[String: Any]]) -> [String: Any] {
        ["identifier": identifier, "name": name, "version": version, "platform": platform, "isAvailable": available,
         "supportedDeviceTypes": types]
    }

    private func device(_ udid: String, _ name: String, state: String = "Shutdown", type: String, available: Bool = true,
                        lastUsed: String? = nil) -> [String: Any] {
        var device: [String: Any] = ["udid": udid, "name": name, "state": state, "deviceTypeIdentifier": type, "isAvailable": available]
        if let lastUsed { device["lastUsedAt"] = lastUsed }
        return device
    }

    private func listing() throws -> Data {
        let types = [type(phone, "iPhone 18 Pro", "iPhone"), type(tablet, "iPad mini (A20 Pro)", "iPad"), type(watch, "Apple Watch Ultra 3", "Apple Watch")]
        let object: [String: Any] = [
            "devicetypes": types,
            "runtimes": [
                runtime(ios265, "iOS 26.5", "26.5", types: [types[0]]),
                runtime(ios272, "iOS 27.2", "27.2", types: types),
                runtime(ios272, "iOS 27.2", "27.2", types: types),          // simctl lists a runtime installed twice, twice
                runtime(ios2610, "iOS 26.10", "26.10", types: [types[1]]),
                runtime(tvos, "tvOS 27.0", "27.0", platform: "tvOS", types: []),
                runtime(gone, "iOS 18.0", "18.0", available: false, types: [types[0]]),
            ],
            "devices": [
                ios272: [
                    device("00000000-0000-0000-0000-000000000002", "iPhone 18 Pro", type: phone, lastUsed: "2026-11-19T13:30:24Z"),
                    device("00000000-0000-0000-0000-000000000001", "Work phone", state: "Booted", type: phone),
                    device("00000000-0000-0000-0000-000000000005", "Broken", type: phone, available: false),
                ],
                ios265: [device("00000000-0000-0000-0000-000000000003", "iPad 10", state: "Booted", type: tablet),
                         device("00000000-0000-0000-0000-000000000006", "iPad 9", type: tablet)],
                tvos: [device("00000000-0000-0000-0000-000000000004", "Apple TV", type: "tv")],
                gone: [device("00000000-0000-0000-0000-000000000007", "Old phone", type: phone)],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("iOS runtimes that can be used are offered, newest first and each once")
    func runtimes() throws {
        let list = try MirrorSimulatorControl.list(fromSimctl: listing())
        #expect(list.runtimes.map(\.name) == ["iOS 27.2", "iOS 26.10", "iOS 26.5"])
    }

    @Test("A runtime offers its iPhones and iPads in simctl's order, and nothing else")
    func deviceTypes() throws {
        let list = try MirrorSimulatorControl.list(fromSimctl: listing())
        #expect(list.runtimes[0].deviceTypes.map(\.name) == ["iPhone 18 Pro", "iPad mini (A20 Pro)"])
        #expect(list.runtimes[0].deviceTypes.map(\.family) == ["iPhone", "iPad"])
    }

    @Test("Simulators are running ones first, then by name as a person sorts names")
    func simulators() throws {
        let list = try MirrorSimulatorControl.list(fromSimctl: listing())
        #expect(list.simulators.map(\.name) == ["iPad 10", "Work phone", "iPad 9", "iPhone 18 Pro"])
        #expect(list.simulators.map(\.booted) == [true, true, false, false])
        let work = try #require(list.simulators.first { $0.name == "Work phone" })
        #expect(work.model == "iPhone 18 Pro")
        #expect(work.os == "iOS 27.2")
        #expect(work.udid == "00000000-0000-0000-0000-000000000001")
    }

    @Test("A simulator says when it was last used, and one that never ran says nothing")
    func lastUsed() throws {
        let list = try MirrorSimulatorControl.list(fromSimctl: listing())
        #expect(list.simulators.first { $0.name == "iPhone 18 Pro" }?.lastUsed == "2026-11-19T13:30:24Z")
        #expect(list.simulators.first { $0.name == "iPad 9" }?.lastUsed == nil)
    }

    @Test("Simulators that cannot be used, or are not iOS, are left out")
    func unusable() throws {
        let names = try MirrorSimulatorControl.list(fromSimctl: listing()).simulators.map(\.name)
        for name in ["Broken", "Apple TV", "Old phone"] { #expect(!names.contains(name)) }
    }

    @Test("Output that is not simctl's list is an error, not an empty list")
    func badOutput() {
        #expect(throws: CLIError.self) { try MirrorSimulatorControl.list(fromSimctl: Data("not json".utf8)) }
    }

    @Test("The list survives the trip to the viewer")
    func roundTrip() throws {
        let list = try MirrorSimulatorControl.list(fromSimctl: listing())
        let decoded = try JSONDecoder().decode(MirrorSimulatorList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
    }

    @Test("A new simulator's name is trimmed, and refused when simctl could misread it")
    func names() {
        #expect(MirrorSimulatorChoice.usableName("  Demo phone ") == "Demo phone")
        #expect(MirrorSimulatorChoice.usableName("") == "")
        #expect(MirrorSimulatorChoice.usableName("--help") == nil)
        #expect(MirrorSimulatorChoice.usableName("two\nlines") == nil)
        #expect(MirrorSimulatorChoice.usableName(String(repeating: "a", count: MirrorSimulatorChoice.nameLimit)) != nil)
        #expect(MirrorSimulatorChoice.usableName(String(repeating: "a", count: MirrorSimulatorChoice.nameLimit + 1)) == nil)
    }

    @Test("The host runs without --udid, and a demo still needs one")
    func parsing() throws {
        let chooser = try #require(try Axe.parseAsRoot(["mirror"]) as? MirrorStartCommand)
        #expect(chooser.simulatorUDID == nil)
        let hosted = try #require(try Axe.parseAsRoot(["mirror", "--udid", "ABC"]) as? MirrorStartCommand)
        #expect(hosted.simulatorUDID == "ABC")
        #expect(throws: (any Error).self) { try Axe.parseAsRoot(["mirror", "--demo"]) }
    }
}
