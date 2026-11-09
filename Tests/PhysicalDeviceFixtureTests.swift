import Foundation
import Testing
@testable import AXe

// Fixtures follow the field shapes of CoreDevice 689.2 `devicectl` JSON (jsonVersion 6) and the
// RemoteXPC and display-info replies recorded from an iPhone 16 Pro Max and an iPad Pro 11-inch
// (3rd generation) on iOS 27.2. Identifiers, names and addresses are invented.

// MARK: - CoreDevice JSON

@Suite("CoreDevice inventory JSON")
struct CoreDeviceInventoryJSONTests {
    /// Current shape: `properties` plus the deprecated `connectionProperties`/`deviceProperties` copies.
    static let currentList = #"""
    {
      "info": {"jsonVersion": 6, "outcome": "success", "version": "689.2"},
      "result": {"devices": [
        {
          "identifier": "11111111-1111-4111-8111-111111111111",
          "visibilityClass": "default",
          "properties": {
            "hardware": {"udid": "00000001-0000000000000001", "marketingName": "iPhone 16 Pro Max",
                         "productType": "iPhone17,2", "productFamily": "iPhone", "fidelity": "physical"},
            "connection": {"pairingState": "paired", "state": "connected", "transportType": "wired",
                           "tunnelIPAddressString": "fd00:1::1"},
            "software": {"osVersionNumber": {"stringValue": "27.2"}},
            "state": {"name": "Test iPhone", "developerModeStatus": {"enabled": {"mode": 1}},
                      "areDeveloperDiskImageServicesAvailable": true}
          },
          "hardwareProperties": {"udid": "00000001-0000000000000001", "reality": "physical", "deviceType": "iPhone"},
          "connectionProperties": {"pairingState": "paired", "tunnelState": "connected",
                                   "tunnelIPAddress": "fd00:1::1", "transportType": "wired"},
          "deviceProperties": {"name": "Test iPhone", "osVersionNumber": "27.2",
                               "developerModeStatus": "enabled", "ddiServicesAvailable": true}
        },
        {
          "identifier": "22222222-2222-4222-8222-222222222222",
          "visibilityClass": "default",
          "properties": {
            "hardware": {"udid": "00000002-0000000000000002", "marketingName": "iPad Pro (11-inch) (3rd generation)",
                         "productType": "iPad13,4", "productFamily": "iPad", "fidelity": "physical"},
            "connection": {"pairingState": "paired", "state": "disconnected", "transportType": "localNetwork"},
            "state": {"name": "Idle iPad", "developerModeStatus": {"enabled": {"mode": 1}}}
          }
        },
        {
          "identifier": "33333333-3333-4333-8333-333333333333",
          "properties": {
            "hardware": {"udid": "00000003-0000000000000003", "productType": "iPhone18,1", "fidelity": "physical"},
            "connection": {"pairingState": "unpaired", "state": "disconnected", "transportType": "wired"},
            "state": {"name": "Unpaired iPhone"}
          }
        },
        {
          "identifier": "44444444-4444-4444-8444-444444444444",
          "properties": {
            "hardware": {"udid": "00000004-0000000000000004", "productType": "iPad16,2", "productFamily": "iPad",
                         "fidelity": "physical"},
            "connection": {"pairingState": "paired", "state": "connected", "transportType": "wired",
                           "tunnelIPAddressString": "fd00:4::1"},
            "state": {"name": "Locked-down iPad", "developerModeStatus": {"disabled": {}},
                      "areDeveloperDiskImageServicesAvailable": false}
          }
        },
        {
          "identifier": "55555555-5555-4555-8555-555555555555",
          "visibilityClass": "simulators",
          "properties": {"hardware": {"productType": "iPhone19,2", "productFamily": "iPhone", "fidelity": "simulated"},
                         "connection": {"transportType": "sameMachine", "pairingState": "paired"}},
          "connectionProperties": {"transportType": "sameMachine"}
        }
      ]}
    }
    """#

    /// Older shape: only `connectionProperties`, `deviceProperties` and `hardwareProperties`.
    static let legacyList = #"""
    {
      "info": {"version": "600.1"},
      "result": {"devices": [{
        "identifier": "66666666-6666-4666-8666-666666666666",
        "hardwareProperties": {"udid": "00000006-0000000000000006", "marketingName": "iPhone 15",
                               "productType": "iPhone15,4", "deviceType": "iPhone", "reality": "physical"},
        "connectionProperties": {"pairingState": "paired", "tunnelState": "connected",
                                 "tunnelIPAddress": "fd00:6::1", "transportType": "localNetwork"},
        "deviceProperties": {"name": "Legacy iPhone", "osVersionNumber": "26.5",
                             "developerModeStatus": "enabled", "ddiServicesAvailable": true}
      }]}
    }
    """#

    static let details = #"""
    {
      "info": {"version": "689.2"},
      "result": {
        "identifier": "11111111-1111-4111-8111-111111111111",
        "properties": {
          "hardware": {"udid": "00000001-0000000000000001", "productType": "iPhone17,2", "fidelity": "physical"},
          "connection": {"pairingState": "paired", "state": "connected", "transportType": "localNetwork",
                         "tunnelIPAddressString": "fd00:1::1"},
          "state": {"name": "Test iPhone", "developerModeStatus": {"enabled": {"mode": 1}},
                    "areDeveloperDiskImageServicesAvailable": true}
        }
      }
    }
    """#

    static let failure = #"""
    {"info": {"version": "689.2", "outcome": "failed"}, "result": null,
     "error": {"userInfo": {"NSLocalizedDescription": {"string": "The device is not connected."}}}}
    """#

    private func devices(_ json: String) throws -> [CoreDevice] {
        try CoreDeviceInventory.devices(fromListJSON: Data(json.utf8))
    }

    private func status(_ id: String, in checks: [ReadinessCheck]) -> ReadinessCheck.Status? {
        checks.first { $0.id == id }?.status
    }

    @Test("Current shape decodes physical devices and drops simulators")
    func currentShape() throws {
        let list = try devices(Self.currentList)
        #expect(list.map(\.identifier) == [
            "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
            "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444",
        ])
        let phone = try #require(list.first)
        #expect(phone.udid == "00000001-0000000000000001")
        #expect(phone.name == "Test iPhone")
        #expect(phone.model == "iPhone 16 Pro Max")
        #expect(phone.osVersion == "27.2")
        #expect(phone.tunnelAddress == "fd00:1::1")
        #expect(phone.tunnelConnected == true)
        #expect(phone.transport == "wired")
        #expect(phone.paired == true)
        #expect(phone.developerModeEnabled == true)
        #expect(phone.developerDiskImageMounted == true)
        #expect(phone.coreDeviceVersion == "689.2")
        #expect(phone.matches("00000001-0000000000000001"))
        #expect(phone.matches("11111111-1111-4111-8111-111111111111".lowercased()))
    }

    @Test("Older shape decodes from the deprecated fields alone")
    func legacyShape() throws {
        let device = try #require(try devices(Self.legacyList).first)
        #expect(device.udid == "00000006-0000000000000006")
        #expect(device.name == "Legacy iPhone")
        #expect(device.osVersion == "26.5")
        #expect(device.tunnelAddress == "fd00:6::1")
        #expect(device.tunnelConnected == true)
        #expect(device.paired == true)
        #expect(device.developerModeEnabled == true)
        #expect(device.developerDiskImageMounted == true)
        #expect(device.coreDeviceVersion == "600.1")
        #expect(DeviceInspection.inventoryChecks(for: device).allSatisfy { $0.status == .ready })
    }

    @Test("Details decode the same device record")
    func details() throws {
        let device = try CoreDeviceInventory.device(fromDetailsJSON: Data(Self.details.utf8))
        #expect(device.identifier == "11111111-1111-4111-8111-111111111111")
        #expect(device.tunnelConnected == true)
        #expect(device.developerDiskImageMounted == true)
    }

    @Test("A failed devicectl envelope reports its description")
    func failureEnvelope() {
        do {
            _ = try devices(Self.failure)
            Issue.record("Expected a failure")
        } catch let error as CLIError {
            #expect(error.errorDescription == "devicectl list devices: The device is not connected.")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("Unrecognized JSON is rejected")
    func malformed() {
        #expect(throws: (any Error).self) { try devices("{\"result\": {\"devices\": 3}}") }
    }

    @Test("Readiness checks name each blocker")
    func readiness() throws {
        let list = try devices(Self.currentList)
        let ready = DeviceInspection.inventoryChecks(for: list[0])
        #expect(ready.allSatisfy { $0.status == .ready })

        let unpaired = DeviceInspection.inventoryChecks(for: list[2])
        #expect(status("notPaired", in: unpaired) == .blocked)
        #expect(status("deviceNotConnected", in: unpaired) == .blocked)

        let developerMode = DeviceInspection.inventoryChecks(for: list[3])
        #expect(status("developerModeDisabled", in: developerMode) == .blocked)
        #expect(status("developerDiskImageUnavailable", in: developerMode) == .blocked)
        #expect(status("deviceNotConnected", in: developerMode) == .ready)
    }

    @Test("list-devices reports an idle paired tunnel as unchecked, not blocked")
    func idleTunnel() throws {
        let list = try devices(Self.currentList)
        let idle = DeviceInspection.listChecks(for: list[1])
        #expect(status("deviceNotConnected", in: idle) == .unchecked)
        #expect(status("developerDiskImageUnavailable", in: idle) == .unchecked)
        #expect(idle.first { $0.id == "deviceNotConnected" }?.message?.contains("axe doctor") == true)

        // An unpaired device stays blocked: doctor cannot reconnect it.
        let unpaired = DeviceInspection.listChecks(for: list[2])
        #expect(status("deviceNotConnected", in: unpaired) == .blocked)
        #expect(status("deviceLocked", in: unpaired) == .unchecked)
    }
}

// MARK: - RemoteXPC wire

@Suite("RemoteXPC wire codec")
struct RemoteXPCWireTests {
    @Test("An empty dictionary message has the documented bytes")
    func emptyDictionary() throws {
        let bytes = try RemoteXPCMessage(flags: 0x1, messageID: 0, body: .dictionary([:])).encode()
        let expected: [UInt8] = [
            0x92, 0x0B, 0xB0, 0x29,                         // wrapper magic
            0x01, 0x00, 0x00, 0x00,                         // flags
            0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // body length 20
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // message ID
            0x42, 0x37, 0x13, 0x42, 0x05, 0x00, 0x00, 0x00, // payload magic and version
            0x00, 0xF0, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // empty dictionary
        ]
        #expect(Array(bytes) == expected)
    }

    @Test("A message without a body has only the header")
    func noBody() throws {
        let bytes = try RemoteXPCMessage(flags: 0x201, messageID: 0, body: nil).encode()
        #expect(bytes.count == 24)
        let decoded = try #require(try RemoteXPCMessage.decodePrefix(bytes))
        #expect(decoded.message.body == nil)
        #expect(decoded.message.flags == 0x201)
    }

    @Test("Strings include the terminator and pad to four bytes")
    func stringPadding() throws {
        let bytes = try RemoteXPCMessage(flags: 0x1, messageID: 1, body: .string("ab")).encode()
        let object = Array(bytes.suffix(from: 32))
        #expect(object == [0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x61, 0x62, 0x00, 0x00])
    }

    @Test("Every value type round-trips")
    func roundTrip() throws {
        let body: RemoteXPCValue = .dictionary([
            "null": .null, "bool": .bool(true), "int": .int64(-42), "uint": .uint64(UInt64.max),
            "double": .double(1.5), "date": .date(815_933_640_000_000_000), "data": .data(Data([1, 2, 3])),
            "string": .string("CoreDevice.featureIdentifier"),
            "uuid": .uuid(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!),
            "array": .array([.uint64(1), .string("x"), .dictionary([:])]),
            "nested": .dictionary(["currentMode": .dictionary(["size": .array([.double(2778), .double(1940)])])]),
        ])
        let message = RemoteXPCMessage(flags: 0x10101, messageID: 7, body: body)
        let bytes = try message.encode()
        let decoded = try #require(try RemoteXPCMessage.decodePrefix(bytes))
        #expect(decoded.message == message)
        #expect(decoded.bytesConsumed == bytes.count)
    }

    @Test("A partial frame waits and two frames decode one at a time")
    func framing() throws {
        let first = try RemoteXPCMessage(flags: 0x20101, messageID: 1, body: .string("one")).encode()
        let second = try RemoteXPCMessage(flags: 0x20101, messageID: 2, body: .string("two")).encode()
        #expect(try RemoteXPCMessage.decodePrefix(first.prefix(first.count - 1)) == nil)
        let joined = first + second
        let decoded = try #require(try RemoteXPCMessage.decodePrefix(joined))
        #expect(decoded.message.messageID == 1)
        #expect(decoded.bytesConsumed == first.count)
        let next = try #require(try RemoteXPCMessage.decodePrefix(joined.suffix(from: decoded.bytesConsumed)))
        #expect(next.message.messageID == 2)
    }

    @Test("A wrong wrapper magic is rejected")
    func badMagic() throws {
        var bytes = try RemoteXPCMessage(flags: 0x1, messageID: 0, body: .dictionary([:])).encode()
        bytes[bytes.startIndex] = 0x00
        #expect(throws: (any Error).self) { try RemoteXPCMessage.decodePrefix(bytes) }
    }
}

// MARK: - Display orientation

@Suite("Physical display orientation")
struct PhysicalDeviceDisplayTests {
    private static func response(native: String, current: String, mode: (Double, Double), scale: Double,
                                 sensor: String?) -> [String: RemoteXPCValue] {
        let primary: RemoteXPCValue = .dictionary([
            "primary": .bool(true), "external": .bool(false), "displayId": .uint64(1),
            "nativeOrientation": .string(native), "currentOrientation": .string(current),
            "currentMode": .dictionary([
                "size": .array([.double(mode.0), .double(mode.1)]), "preferredUIScale": .uint64(UInt64(scale)),
            ]),
        ])
        let wireless: RemoteXPCValue = .dictionary([
            "primary": .bool(false), "external": .bool(true), "displayId": .uint64(7),
            "nativeOrientation": .string("rot0"), "currentOrientation": .string("rot0"),
            "currentMode": .dictionary(["size": .array([.double(0), .double(0)]), "preferredUIScale": .uint64(1)]),
        ])
        var output: [String: RemoteXPCValue] = ["current": .bool(true), "displays": .array([primary, wireless])]
        if let sensor {
            output["orientation"] = .dictionary([
                "currentDeviceOrientation": .string(sensor), "currentDeviceNonFlatOrientation": .string(sensor),
                "currentDeviceOrientationLocked": .bool(false),
            ])
        }
        return ["CoreDevice.output": .dictionary(output)]
    }

    private static func iPad(_ current: String, _ sensor: String) throws -> PhysicalDeviceDisplay {
        try PhysicalDeviceDisplay(response: response(native: "rot270", current: current,
            mode: (2778, 1940), scale: 2, sensor: sensor))
    }

    private static func iPhone(_ current: String, _ sensor: String) throws -> PhysicalDeviceDisplay {
        try PhysicalDeviceDisplay(response: response(native: "rot0", current: current,
            mode: (1320, 2868), scale: 3, sensor: sensor))
    }

    private static func point(_ value: RemoteXPCValue) -> (Double, Double)? {
        guard case let .dictionary(values) = value, case let .double(x)? = values["x"],
              case let .double(y)? = values["y"] else { return nil }
        return (x, y)
    }

    private static func failureCode(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let failure as CLIOutputFailure { return failure.code } catch { return "other" }
    }

    /// Physical rotation of the iPad, Tap Test readback of raw taps at normalized (0.2, 0.3) and (0.7, 0.6).
    @Test("iPad measurements map back to the digitizer points", arguments: [
        ("rot90", "portrait", 970.0, 1389.0, [(194.0, 416.0), (679.0, 833.0)]),
        ("rot180", "landscapeRight", 1389.0, 970.0, [(972.0, 194.0), (555.0, 679.0)]),
        ("rot270", "portraitUpsideDown", 970.0, 1389.0, [(776.0, 972.0), (291.0, 555.0)]),
        ("rot0", "landscapeLeft", 1389.0, 970.0, [(416.0, 776.0), (833.0, 291.0)]),
    ])
    func iPadMeasurements(current: String, sensor: String, width: Double, height: Double,
                          taps: [(Double, Double)]) throws {
        let display = try Self.iPad(current, sensor)
        #expect(try display.width == width)
        #expect(try display.height == height)
        #expect(display.matches(deviceOrientation: sensor))
        for (tap, expected) in zip(taps, [(0.2, 0.3), (0.7, 0.6)]) {
            let normalized = try #require(Self.point(try display.normalized(CGPoint(x: tap.0, y: tap.1))))
            // The app reports whole points.
            #expect(abs(normalized.0 - expected.0) < 0.002)
            #expect(abs(normalized.1 - expected.1) < 0.002)
        }
    }

    @Test("iPhone portrait and landscape keep the rot0 mapping")
    func iPhone() throws {
        let portrait = try Self.iPhone("rot0", "portrait")
        #expect(try portrait.width == 440)
        #expect(try portrait.height == 956)
        let centre = try #require(Self.point(try portrait.normalized(CGPoint(x: 220, y: 478))))
        #expect(centre == (0.5, 0.5))

        let landscape = try Self.iPhone("rot90", "landscapeRight")
        #expect(try landscape.width == 956)
        #expect(landscape.matches(deviceOrientation: "landscapeRight"))
        #expect(try Self.iPhone("rot270", "landscapeLeft").matches(deviceOrientation: "landscapeLeft"))
    }

    @Test("A lagging iPad display refuses touches before any input")
    func iPadMismatch() throws {
        // Observed after a simulated rotation: interface and sensor at landscapeLeft, display still upside down.
        let stale = try Self.iPad("rot270", "landscapeLeft")
        #expect(!stale.matches(deviceOrientation: "landscapeLeft"))
        #expect(Self.failureCode { _ = try stale.normalized(CGPoint(x: 10, y: 10)) } == "displayOrientationMismatch")
        #expect(Self.failureCode { _ = try stale.width } == "displayOrientationMismatch")
        #expect(Self.failureCode { try stale.requireResolvedOrientation() } == "displayOrientationMismatch")
    }

    @Test("An iPad reply without its orientation field refuses; a reported unknown does not")
    func iPadMissingOrientation() throws {
        let missing = try PhysicalDeviceDisplay(response: Self.response(native: "rot270", current: "rot0",
            mode: (2778, 1940), scale: 2, sensor: nil))
        #expect(Self.failureCode { _ = try missing.normalized(CGPoint(x: 10, y: 10)) } == "displayOrientationMismatch")
        let flat = try Self.iPad("rot0", "unknown")
        #expect(Self.failureCode { try flat.requireResolvedOrientation() } == nil)
        // An iPhone reply without the field is unaffected.
        let phone = try PhysicalDeviceDisplay(response: Self.response(native: "rot0", current: "rot0",
            mode: (1320, 2868), scale: 3, sensor: nil))
        #expect(Self.failureCode { try phone.requireResolvedOrientation() } == nil)
    }

    @Test("An iPhone that will not turn upside down is not treated as a mismatch")
    func iPhoneUpsideDown() throws {
        let display = try Self.iPhone("rot270", "portraitUpsideDown")
        #expect(Self.failureCode { try display.requireResolvedOrientation() } == nil)
        #expect(!display.matches(deviceOrientation: "portraitUpsideDown"))
        #expect(try display.width == 956)
    }

    @Test("A native rot90 panel swaps the mode axes")
    func nativeRot90() throws {
        let display = try PhysicalDeviceDisplay(response: Self.response(native: "rot90", current: "rot0",
            mode: (2778, 1940), scale: 2, sensor: "landscapeRight"))
        #expect(try display.width == 1389)
        #expect(try display.height == 970)
    }

    @Test("Points outside the display are refused")
    func outside() throws {
        let display = try Self.iPad("rot90", "portrait")
        #expect(Self.failureCode { _ = try display.normalized(CGPoint(x: 970, y: 10)) } == "pointOutsideDisplay")
    }

    @Test("Unknown orientations and missing displays are protocol errors")
    func invalid() {
        #expect(throws: (any Error).self) {
            try PhysicalDeviceDisplay(response: Self.response(native: "rot45", current: "rot0",
                mode: (1320, 2868), scale: 3, sensor: "portrait"))
        }
        #expect(throws: (any Error).self) { try PhysicalDeviceDisplay(response: [:]) }
    }

    @Test("Equality tracks the iPad sensor but ignores it on the iPhone")
    func equality() throws {
        #expect(try Self.iPad("rot0", "landscapeLeft") == Self.iPad("rot0", "landscapeLeft"))
        #expect(try Self.iPad("rot0", "landscapeLeft") != Self.iPad("rot0", "portrait"))
        #expect(try Self.iPhone("rot0", "portrait") == Self.iPhone("rot0", "faceUp"))
    }
}

// MARK: - Lock recheck

@Suite("Physical lock recheck")
struct PhysicalLockRecheckTests {
    @Test("Input within the quiet gap needs no lock check; input after it does")
    func quietGap() {
        let start = ContinuousClock.now
        var policy = PhysicalLockRecheck()
        policy.leaseStarted(at: start)
        var checks = 0
        // A batch of steps a few seconds apart: no device call at all.
        for second in stride(from: 2, through: 60, by: 4) {
            let now = start.advanced(by: .seconds(second))
            if policy.needsCheck(at: now) { checks += 1 }
            policy.inputSent(at: now, lockButton: false)
        }
        #expect(checks == 0)
        // Then a 30-second sleep before the next step.
        let late = start.advanced(by: .seconds(90))
        #expect(policy.needsCheck(at: late))
        policy.inputSent(at: late, lockButton: false)
        #expect(!policy.needsCheck(at: late.advanced(by: .seconds(1))))
    }

    @Test("The lock button refuses later input until the next lease")
    func lockButton() {
        let start = ContinuousClock.now
        var policy = PhysicalLockRecheck()
        policy.leaseStarted(at: start)
        #expect(!policy.lockedByButton)
        policy.inputSent(at: start.advanced(by: .seconds(1)), lockButton: true)
        #expect(policy.lockedByButton)
        policy.leaseStarted(at: start.advanced(by: .seconds(5)))
        #expect(!policy.lockedByButton)
    }
}
