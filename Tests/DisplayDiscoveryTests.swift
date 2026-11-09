import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Display discovery")
struct DisplayDiscoveryTests {
    private let simulatorID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let outerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let innerID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private func panelJSON(displayID: UInt32, uniqueID: UUID, active: Bool, primary: Bool,
                           width: Double, height: Double, orientation: String = "rot0",
                           backlight: String? = nil) -> String {
        let backlightField = backlight.map { ",\"backlightState\":\"\($0)\"" } ?? ""
        return """
        {"identity":{"displayID":\(displayID),"uniqueID":"\(uniqueID.uuidString)"},
        "active":\(active),"primary":\(primary),"currentOrientation":"\(orientation)","nativeOrientation":"rot0",
        "nativePixelWidth":\(width),"nativePixelHeight":\(height),"boundsOriginX":0,"boundsOriginY":0,
        "boundsWidth":\(width),"boundsHeight":\(height),"pointScale":3\(backlightField)}
        """
    }

    private func snapshot(innerOrientation: String = "rot0") throws -> ActivePanelSnapshot {
        let outer = panelJSON(displayID: 1, uniqueID: outerID, active: false, primary: true, width: 1398, height: 2034,
            orientation: "rot0", backlight: "off")
        let inner = panelJSON(displayID: 3, uniqueID: innerID, active: true, primary: false, width: 2007, height: 2853,
            orientation: innerOrientation, backlight: "activeOn")
        let json = """
        {"requestedSimulatorUDID":"\(simulatorID.uuidString)","sourceCommandType":"devicectl.device.info.displays",
        "sourceJSONVersion":5,"sourceVersion":"651.28","activePanel":\(inner),
        "selectionBasis":"explicitActiveFlag","panels":[\(outer),\(inner)]}
        """
        return try JSONDecoder().decode(ActivePanelSnapshot.self, from: Data(json.utf8))
    }

    private func singlePanelSnapshot() throws -> ActivePanelSnapshot {
        let panel = panelJSON(displayID: 1, uniqueID: outerID, active: true, primary: true, width: 1206, height: 2622,
            backlight: "inactiveOn")
        let json = """
        {"requestedSimulatorUDID":"\(simulatorID.uuidString)","sourceCommandType":"com.apple.coredevice.action.displayinfo",
        "sourceJSONVersion":0,"sourceVersion":"689.2","activePanel":\(panel),
        "selectionBasis":"verifiedSingleIntegratedPanel","panels":[\(panel)]}
        """
        return try JSONDecoder().decode(ActivePanelSnapshot.self, from: Data(json.utf8))
    }

    @Test func displaysCommandRequiresOneSimulator() throws {
        let parsed = try Displays.parse(["--udid", simulatorID.uuidString])
        #expect(parsed.simulatorUDID == simulatorID.uuidString && !parsed.verbose)
        #expect(try Displays.parse(["--udid", simulatorID.uuidString, "--verbose"]).verbose)
        for args in [[], ["--udid", "invalid"]] {
            #expect(throws: (any Error).self) { _ = try Displays.parse(args) }
        }
        _ = try ListSimulators.parse([])
        for args in [["--displays"], ["--displays", "--udid", simulatorID.uuidString], ["--udid", simulatorID.uuidString]] {
            #expect(throws: (any Error).self) { _ = try ListSimulators.parse(args) }
        }
    }

    @Test func activeScreenUsesOrientedPointsAndRoles() throws {
        let screens = try DeviceState.screens(from: snapshot(innerOrientation: "rot90"))
        #expect(screens.active.id == 3 && screens.active.role == "inner")
        #expect(screens.active.width == 951 && screens.active.height == 669)
        #expect(screens.active.rotation == 90 && screens.active.orientation == "landscape")
        #expect(screens.active.state == .on && screens.active.scale == 3)
        #expect(screens.others.count == 1)
        let outer = try #require(screens.others.first)
        #expect(outer.id == 1 && outer.role == "outer" && outer.state == .off)
        #expect(outer.width == 466 && outer.height == 678)
        #expect(outer.rotation == nil && outer.orientation == nil)

        let portrait = try DeviceState.screens(from: snapshot(innerOrientation: "rot0")).active
        #expect(portrait.width == 669 && portrait.height == 951 && portrait.orientation == "portrait")
    }

    @Test func singleScreenIsMainAndLockedStateIsReported() throws {
        let screens = try DeviceState.screens(from: singlePanelSnapshot())
        #expect(screens.active.role == "main" && screens.others.isEmpty)
        #expect(screens.active.width == 402 && screens.active.height == 874)
        #expect(screens.active.state == .locked)
    }

    @Test func postureUsesSensedAngleAndTolerance() {
        #expect(HingePosture(degrees: 0) == .closed)
        #expect(HingePosture(degrees: 0.5) == .closed)
        #expect(HingePosture(degrees: 0.6) == .partiallyOpen)
        #expect(HingePosture(degrees: 179.4) == .partiallyOpen)
        #expect(HingePosture(degrees: 179.5) == .open)
        let hinge = HingeStateOutput(sensed: 118.460205078125, mechanical: 120)
        #expect(hinge.degrees == 118.5 && hinge.mechanicalDegrees == 120 && hinge.posture == .partiallyOpen)
        #expect(hinge.text == "118.5°, partially open")
        #expect(HingeStateOutput(sensed: 180, mechanical: 180).text == "180°, open")
    }

    @Test func displaysTextShowsActiveScreenFirst() throws {
        let screens = try DeviceState.screens(from: snapshot(innerOrientation: "rot90"))
        let output = DisplaysOutput(udid: simulatorID.uuidString, name: "iPhone Duo",
            hinge: HingeStateOutput(sensed: 113.8, mechanical: 120),
            activeScreen: screens.active, otherScreens: screens.others)
        #expect(output.textLines == [
            "iPhone Duo  \(simulatorID.uuidString)",
            "Hinge   113.8°, partially open",
            "",
            "Active  inner  951×669 pt @3x  landscape",
            "        id 3   \(innerID.uuidString)",
            "Off     outer  466×678 pt @3x",
            "        id 1   \(outerID.uuidString)",
        ])
    }

    @Test func compactJSONOmitsMeasurementsAndBootIdentity() throws {
        let screens = try DeviceState.screens(from: snapshot(innerOrientation: "rot90"))
        let output = DisplaysOutput(udid: simulatorID.uuidString, name: "iPhone Duo",
            hinge: HingeStateOutput(sensed: 113.8, mechanical: 120),
            activeScreen: screens.active, otherScreens: screens.others)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        #expect(Set(object.keys) == ["udid", "name", "hinge", "activeScreen", "otherScreens"])
        let hinge = try #require(object["hinge"] as? [String: Any])
        #expect(Set(hinge.keys) == ["degrees", "mechanicalDegrees", "posture"])
        #expect(hinge["posture"] as? String == "partiallyOpen")
        let read = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            HingeReadOutput(udid: "U", hinge: HingeStateOutput(sensed: 0, mechanical: 0)))) as? [String: Any])
        #expect(Set(read.keys) == ["udid", "degrees", "mechanicalDegrees", "posture"])
    }

    @Test func selectedFailuresSayWhetherInputWasSent() {
        func response(outcome: String, events: Int, cleanup: String = "notNeeded", error: String?) -> SelectedHIDResponse {
            SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: UUID(),
                outcome: outcome, token: nil, enqueuedEventCount: events, cleanup: cleanup, error: error, context: nil)
        }
        let before = SelectedInputOutput.failure(response(outcome: "failedBeforeInput", events: 0, error: "Target moved"))
        #expect(before.code == "rejectedBeforeInput" && before.message == "Target moved No input was sent.")
        let partial = SelectedInputOutput.failure(response(outcome: "failedNoReplay", events: 2, error: "Context changed"))
        #expect(partial.code == "inputFailed" && partial.message.hasSuffix("it was not repeated; read the screen before trying again."))
        let busy = SelectedInputOutput.failure(response(outcome: "rejectedBeforeInput", events: 0,
            error: SelectedHIDFailure.busy.errorDescription))
        #expect(busy.code == "busy")
    }

    private struct ReadMetadata: Decodable {
        struct Interval: Decodable {
            let startedUptime: Double
            let finishedUptime: Double
        }
        let bootIdentity: String
        let readInterval: Interval
    }

    @Test func verboseOutputAddsExactMetadataWithoutChangingSnapshotFields() throws {
        let snapshot = try snapshot()
        let output = DisplayDiscoveryOutput(snapshot: snapshot, bootIdentity: "101:202:303",
            startedUptime: 12.5, finishedUptime: 14.75)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        let metadata = try JSONDecoder().decode(ReadMetadata.self, from: data)
        #expect(metadata.bootIdentity == "101:202:303")
        #expect(metadata.readInterval.startedUptime == 12.5)
        #expect(metadata.readInterval.finishedUptime == 14.75)
        let decodedSnapshot = try JSONDecoder().decode(ActivePanelSnapshot.self, from: data)
        #expect(try encoder.encode(decodedSnapshot) == encoder.encode(snapshot))
    }

    @Test func readTimesStayOutsidePureDecoderSnapshot() throws {
        let snapshot = try snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(snapshot)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ReadMetadata.self, from: original)
        }
        let first = try encoder.encode(DisplayDiscoveryOutput(snapshot: snapshot,
            bootIdentity: "101:202:303", startedUptime: 12.5, finishedUptime: 14.75))
        let second = try encoder.encode(DisplayDiscoveryOutput(snapshot: snapshot,
            bootIdentity: "101:202:303", startedUptime: 20, finishedUptime: 22))
        #expect(first != second)
        for data in [first, second] {
            let decodedSnapshot = try JSONDecoder().decode(ActivePanelSnapshot.self, from: data)
            #expect(try encoder.encode(decodedSnapshot) == original)
        }
    }
}
