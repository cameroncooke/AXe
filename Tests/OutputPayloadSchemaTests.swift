import Foundation
import Testing
@testable import AXe

/// Every command's JSON success payload, built from its real output type with representative
/// values, must match its `$defs` entry in the published payload schema and declare every field.
@Suite("Published command payload schema")
struct OutputPayloadSchemaTests {
    private static let udid = "8775B9A0-A491-4182-88CD-43600178780F"
    private static let screenUUID = "DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0"

    /// One or more representative payloads for each command path the schema describes.
    private func payloads() throws -> [(String, [CLIOutputValue])] {
        let active = ScreenStateOutput(id: 3, uuid: Self.screenUUID, role: "inner", width: 951, height: 669,
            scale: 3, rotation: 90, orientation: "landscape", state: .on)
        let other = ScreenStateOutput(id: 1, uuid: "85D7C4CD-0F9F-422B-94DA-658B4164694D", role: "outer",
            width: 466, height: 678, scale: 3, rotation: nil, orientation: nil, state: .off)
        let hinge = HingeStateOutput(sensed: 113.8, mechanical: 120)
        let displays = DisplaysOutput(udid: Self.udid, name: "iPhone Duo", hinge: hinge,
            activeScreen: active, otherScreens: [other])
        let main = DisplaysOutput(udid: Self.udid, name: "iPhone 18 Pro", hinge: nil, activeScreen: ScreenStateOutput(
            id: 1, uuid: Self.screenUUID, role: "main", width: 402, height: 874, scale: 3, rotation: 0,
            orientation: "portrait", state: .locked), otherScreens: [])

        let context = try JSONDecoder().decode(SelectedHIDContext.self, from: Data(
            #"{"bootIdentity":"1:2:3","screenID":3,"screenUUID":"DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0","logicalWidth":402,"logicalHeight":874,"rotationDegrees":0,"nativePixelWidth":1206,"nativePixelHeight":2622,"scale":3,"poseRevision":"static"}"#.utf8))
        var touch = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: UUID(),
            outcome: "retained", token: UUID(), enqueuedEventCount: 1, cleanup: "notNeeded", error: nil, context: context)
        touch.ax = SelectedAXResult(kind: .tap, expectedPID: 4321)
        let selected = SelectedInputSummary(touch)
        let completed = CLIOutputValue.object(["outcome": .string("completed")])

        let settings = DeviceSettingsOutput(udid: Self.udid, appearance: try devicectl(#"""
            {"colorFilter":{"enabled":true,"filterType":{"name":"Grayscale"},"intensity":0.8},"increaseContrast":false,
             "liquidGlassOpacity":0.5,"lookAndFeel":"Clear","reduceMotion":{"enabled":true},"reduceTransparency":{"enabled":false},
             "showBorders":{"enabled":false},"textSize":"Accessibility Large","userInterfaceStyle":"dark"}
            """#), voiceOver: try devicectl(#"{"enabled":false}"#))
        let statusBar = StatusBarOutput(udid: Self.udid, reported: try devicectl(#"""
            {"batteryLevel":42,"batteryState":"charging","cellularMode":"active","cellularStrength":3,
             "dataNetworkType":"`5G`","time":"9:41","wifiMode":"active","wifiStrength":2}
            """#))
        let cleared = StatusBarOutput(udid: Self.udid, reported: try devicectl("{}"))

        let readiness = TargetReadiness(target: "device", udid: "00008140-001A2B3C4D5E", name: "iPhone",
            checks: [ReadinessCheck("notPaired", observed: true, fix: "Pair the device."),
                     ReadinessCheck("deviceLocked", observed: false, fix: "Unlock the device.")])
        let device = CoreDevice(identifier: "6A0E7F31-1B54-4C4E-9E25-0D8B2F1C9A77", udid: "00008140-001A2B3C4D5E",
            name: "iPhone", model: "iPhone 17 Pro", osVersion: "26.1", tunnelAddress: "fd00::1", tunnelConnected: true,
            transport: "wired", paired: true, developerModeEnabled: true, developerDiskImageMounted: false,
            coreDeviceVersion: "689.2")
        let devices = try encode(ListDevices.Inventory(devices: [ListDevices.DeviceSummary(device)]))

        return [
            ("describe-ui", [try value(Data(#"[{"type":"Application","AXLabel":"Fixture","children":[]}]"#.utf8))]),
            ("list-simulators", [try encode(SimulatorInventoryOutput(simulators: [SimulatorSummaryOutput(
                udid: Self.udid, name: "iPhone 18 Pro", state: "Booted", model: "iPhone 18 Pro", osVersion: "iOS 27.2")]))]),
            ("list-devices", [devices]),
            ("doctor", [try encode(readiness)]),
            ("displays", [try encode(displays), try encode(main)]),
            ("settings show", [try encode(settings)]),
            ("settings set", [try encode(settings)]),
            ("settings location set", [try encode(LocationOutput(udid: Self.udid, latitude: 37.77, longitude: -122.42))]),
            ("settings location clear", [try encode(LocationOutput(udid: Self.udid, cleared: true))]),
            ("settings location scenarios", [try encode(LocationOutput(udid: Self.udid, scenarios: ["City Run"]))]),
            ("settings location scenario", [try encode(LocationOutput(udid: Self.udid, scenario: "City Run"))]),
            ("settings status-bar show", [try encode(statusBar), try encode(cleared)]),
            ("settings status-bar clear", [try encode(cleared)]),
            ("settings status-bar preset", [try encode(statusBar)]),
            ("settings status-bar set", [try encode(statusBar)]),
            ("shutdown", [try encode(ShutdownOutput(udid: Self.udid, initialState: "Booted", outcome: "shutDown"))]),
            ("clipboard copy", [try encode(ClipboardCopyOutput(udid: Self.udid, bytes: 10,
                sha256: String(repeating: "ab", count: 32)))]),
            ("init", [try encode(InitOutput(installed: [InitOutput.Entry(client: "Codex", path: "/tmp/axe/SKILL.md")])),
                      try encode(InitOutput(removed: [])), try encode(InitOutput(content: "# AXe"))]),
            ("tap", [completed, try encode(selected),
                     try encode(SemanticPressOutput(identifier: "switch", before: false, after: true))]),
            ("slider", [completed]), ("type", [completed]), ("swipe", [completed]), ("drag", [completed]), ("draw", [completed]),
            ("button", [completed]), ("key", [completed]), ("key-sequence", [completed]), ("key-combo", [completed]),
            ("touch", [try encode(selected)]), ("gesture", [completed]),
            ("hinge read", [try encode(HingeReadOutput(udid: Self.udid, hinge: hinge))]),
            ("hinge set", [try encode(HingeSetOutput(udid: Self.udid, previousDegrees: 0, hinge: hinge, activeScreen: active)),
                           try encode(HingeSetOutput(udid: Self.udid, previousDegrees: 0, hinge: hinge, activeScreen: nil))]),
            ("rotate", [try encode(RotateOutput(udid: Self.udid, direction: "left", previousRotation: 0, activeScreen: active)),
                        try encode(RotateOutput(udid: "00008140-001A2B3C4D5E", direction: "right", previousRotation: nil, activeScreen: nil))]),
            ("screenshot", [try encode(MediaOutput(path: "/tmp/screen.png", pixelWidth: 1206, pixelHeight: 2622))]),
            ("record-video", [try encode(MediaOutput(path: "/tmp/video.mp4", pixelWidth: 602, pixelHeight: 1310, frames: 20))]),
            ("batch", [try encode(SelectedBatchSummary(steps: 3, outcome: "completed"))]),
        ]
    }

    @Test("Every command's success payload matches its definition, field for field")
    func payloadsMatch() throws {
        let cases = try payloads()
        for (command, values) in cases {
            for payload in values {
                let context = CLIOutputContext(format: .json, command: command, agent: false)
                context.append(payload)
                let rendered = try OutputSchemaJSON(json: CLIOutput.rendered(context))
                try OutputSchemas.validate(rendered)
                let result = try #require(rendered["data"]?["result"])
                #expect(try OutputSchemas.validatePayload(command: command, result: result).isEmpty, "\(command)")
            }
        }
        // The schema describes exactly these commands, plus shared parts that are not command paths.
        let shared: Set<String> = ["hinge", "screen", "readinessCheck", "input", "media", "settings", "statusBar"]
        let described = try Set(OutputSchemas.payloadDefinitions().keys).subtracting(shared)
        #expect(described == Set(cases.map(\.0)))
    }

    @Test("A payload field the schema does not declare fails")
    func undeclaredPayloadFieldFails() throws {
        let output = ShutdownOutput(udid: Self.udid, initialState: "Booted", outcome: "shutDown")
        guard case var .object(fields) = try OutputSchemaJSON(json: JSONEncoder().encode(output)) else {
            Issue.record("Shutdown output is not an object"); return
        }
        #expect(try OutputSchemas.validatePayload(command: "shutdown", result: .object(fields)).isEmpty)
        fields["source"] = .string("simctl")
        #expect(try OutputSchemas.validatePayload(command: "shutdown", result: .object(fields))
            == ["$: field source is not declared in the schema."])
        fields["source"] = nil
        fields["outcome"] = .string("shutdownCompleted")
        #expect(try !OutputSchemas.validatePayload(command: "shutdown", result: .object(fields)).isEmpty)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> CLIOutputValue {
        try JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(value))
    }

    private func value(_ data: Data) throws -> CLIOutputValue {
        try JSONDecoder().decode(CLIOutputValue.self, from: data)
    }

    private func devicectl<Result: Decodable>(_ result: String) throws -> Result {
        let envelope = #"{"info":{"commandType":"test","environment":{},"jsonVersion":6,"outcome":"success","version":"689.2"},"result":"#
            + result + "}"
        return try CoreDeviceInventory.result(fromJSON: Data(envelope.utf8), succeeded: true, operation: "test")
    }
}
