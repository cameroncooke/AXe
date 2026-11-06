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
                           width: Double, height: Double) -> String {
        """
        {"identity":{"displayID":\(displayID),"uniqueID":"\(uniqueID.uuidString)"},
        "active":\(active),"primary":\(primary),"currentOrientation":"rot0","nativeOrientation":"rot0",
        "nativePixelWidth":\(width),"nativePixelHeight":\(height),"boundsOriginX":0,"boundsOriginY":0,
        "boundsWidth":\(width),"boundsHeight":\(height),"pointScale":3}
        """
    }

    private func snapshot() throws -> ActivePanelSnapshot {
        let outer = panelJSON(displayID: 1, uniqueID: outerID, active: false, primary: true, width: 1398, height: 2034)
        let inner = panelJSON(displayID: 3, uniqueID: innerID, active: true, primary: false, width: 2007, height: 2853)
        let json = """
        {"requestedSimulatorUDID":"\(simulatorID.uuidString)","sourceCommandType":"devicectl.device.info.displays",
        "sourceJSONVersion":5,"sourceVersion":"651.28","activePanel":\(inner),
        "selectionBasis":"explicitActiveFlag","panels":[\(outer),\(inner)]}
        """
        return try JSONDecoder().decode(ActivePanelSnapshot.self, from: Data(json.utf8))
    }

    @Test func displayOptionRequiresOneExplicitDeviceAndPreservesDefault() throws {
        let legacy = try ListSimulators.parse([])
        #expect(!legacy.displays && legacy.simulatorUDID == nil)
        let selected = try ListSimulators.parse(["--displays", "--udid", simulatorID.uuidString])
        #expect(selected.displays && selected.simulatorUDID == simulatorID.uuidString)
        for args in [["--displays"], ["--displays", "--udid", "invalid"], ["--udid", simulatorID.uuidString]] {
            #expect(throws: (any Error).self) { _ = try ListSimulators.parse(args) }
        }
    }

    private struct ReadMetadata: Decodable {
        struct Interval: Decodable {
            let startedUptime: Double
            let finishedUptime: Double
        }
        let bootIdentity: String
        let readInterval: Interval
    }

    @Test func discoveryOutputAddsExactMetadataWithoutChangingSnapshotFields() throws {
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
