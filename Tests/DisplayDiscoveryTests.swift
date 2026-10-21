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
    private var arguments: [String] {
        ["devicectl", "device", "info", "displays", "--device", simulatorID.uuidString,
         "--timeout", "5", "--json-output", "/unused/displays.json"]
    }
    private var catalog: [ActivePanelCatalogEntry] {
        [ActivePanelCatalogEntry(identity: .init(displayID: 1, uniqueID: outerID),
            nativePixelWidth: 1398, nativePixelHeight: 2034, scale: 3),
         ActivePanelCatalogEntry(identity: .init(displayID: 3, uniqueID: innerID),
            nativePixelWidth: 2007, nativePixelHeight: 2853, scale: 3)]
    }
    private struct Integrated: Encodable {}
    private struct Kind: Encodable { let integrated = Integrated() }
    private struct Row: Encodable {
        var displayId: UInt32
        var uniqueId: UUID
        var active: Bool?
        var primary: Bool
        var currentOrientation: ActivePanelRotation = .rot0
        var nativeOrientation: ActivePanelRotation = .rot0
        var nativeSize: [Double]
        var bounds: [[Double]]
        var pointScale = 3
        let type = Kind()
    }
    private struct Envelope: Encodable {
        struct Info: Encodable {
            var arguments: [String]
            var commandType = "devicectl.device.info.displays"
            var jsonVersion = 5
            var outcome = "success"
            var version = "651.28"
        }
        struct Result: Encodable { var displays: [Row] }
        var info: Info
        var result: Result
    }
    private func envelope() -> Envelope {
        Envelope(info: .init(arguments: arguments), result: .init(displays: [
            Row(displayId: 1, uniqueId: outerID, active: false, primary: true,
                nativeSize: [1398, 2034], bounds: [[0, 0], [1398, 2034]]),
            Row(displayId: 3, uniqueId: innerID, active: true, primary: false,
                nativeSize: [2007, 2853], bounds: [[0, 0], [2007, 2853]])]))
    }
    private func discover(_ value: Envelope, expected: [ActivePanelCatalogEntry]? = nil) throws -> ActivePanelSnapshot {
        try ActivePanelDecoder.decodeDiscovery(JSONEncoder().encode(value), simulatorUDID: simulatorID,
            expectedCatalog: expected ?? catalog, exactArguments: arguments)
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

    @Test(arguments: [ActivePanelRotation.rot0, .rot90, .rot180, .rot270])
    func discoveryReportsMeasuredRotationAndIgnoresPrimary(rotation: ActivePanelRotation) throws {
        var value = envelope()
        value.result.displays[1].currentOrientation = rotation
        let actual = try discover(value)
        #expect(actual.activePanel.identity == catalog[1].identity)
        #expect(!actual.activePanel.primary && actual.activePanel.active == true)
        #expect(actual.activePanel.currentOrientation == rotation)
        #expect(actual.activePanel.nativePixelWidth == 2007 && actual.activePanel.nativePixelHeight == 2853)
        #expect(actual.activePanel.pointScale == 3 && actual.selectionBasis == .explicitActiveFlag)
        #expect(actual.panels.count == 2 && actual.panels[0].active == false)
        let decoded = try JSONDecoder().decode(ActivePanelSnapshot.self, from: JSONEncoder().encode(actual))
        #expect(decoded.activePanel == actual.activePanel && decoded.panels == actual.panels)
    }

    @Test func explicitActiveStateIsRequiredAndUnique() throws {
        var value = envelope()
        value.result.displays[1].active = false
        #expect(throws: ActivePanelValidationError.activeStateUnavailable(0)) { _ = try discover(value) }
        value = envelope(); value.result.displays[0].active = true
        #expect(throws: ActivePanelValidationError.activeStateUnavailable(2)) { _ = try discover(value) }
        value = envelope(); value.result.displays[0].active = nil
        #expect(throws: ActivePanelValidationError.missingActiveFlag) { _ = try discover(value) }
        let nullJSON = String(decoding: try JSONEncoder().encode(envelope()), as: UTF8.self)
            .replacingOccurrences(of: "\"active\":false", with: "\"active\":null")
        #expect(throws: (any Error).self) {
            _ = try ActivePanelDecoder.decodeDiscovery(Data(nullJSON.utf8), simulatorUDID: simulatorID,
                expectedCatalog: catalog, exactArguments: arguments)
        }
    }

    @Test func everyIdentityAndGeometryMustMatchIncludingInactivePanel() throws {
        var value = envelope(); value.result.displays[0].uniqueId = UUID()
        #expect(throws: ActivePanelValidationError.catalogMismatch) { _ = try discover(value) }
        value = envelope(); value.result.displays[1].displayId = 1
        #expect(throws: ActivePanelValidationError.duplicateIdentity) { _ = try discover(value) }
        value = envelope(); value.result.displays[0].pointScale = 2
        #expect(throws: ActivePanelValidationError.catalogGeometryMismatch(1)) { _ = try discover(value) }
        value = envelope(); value.result.displays[0].bounds[0][0] = 1
        #expect(throws: ActivePanelValidationError.catalogGeometryMismatch(1)) { _ = try discover(value) }
        value = envelope(); value.result.displays[0].nativeSize[0] = 1400
        #expect(throws: ActivePanelValidationError.catalogGeometryMismatch(1)) { _ = try discover(value) }
        value = envelope(); value.result.displays[0].bounds = []
        #expect(throws: ActivePanelValidationError.invalidGeometry(1)) { _ = try discover(value) }
        #expect(throws: ActivePanelValidationError.catalogMismatch) { _ = try discover(envelope(), expected: [catalog[1]]) }
    }

    @Test func invalidHostCatalogFailsWithoutAnActiveGuess() throws {
        for invalid in [[], [catalog[0], catalog[0]],
            [ActivePanelCatalogEntry(identity: catalog[0].identity, nativePixelWidth: .nan, nativePixelHeight: 2034, scale: 3)],
            [ActivePanelCatalogEntry(identity: catalog[0].identity, nativePixelWidth: 1398, nativePixelHeight: 2034, scale: 0)]] {
            #expect(throws: ActivePanelValidationError.invalidExpectedCatalog) { _ = try discover(envelope(), expected: invalid) }
        }
    }

    @Test func commandDeviceAndSchemaAreValidated() throws {
        var value = envelope(); value.info.arguments[5] = UUID().uuidString
        #expect(throws: ActivePanelValidationError.wrongArguments) { _ = try discover(value) }
        value = envelope(); value.info.jsonVersion = 4
        #expect(throws: ActivePanelValidationError.wrongCommandOrSchema) { _ = try discover(value) }
        value = envelope(); value.info.commandType = "devicectl.device.info.details"
        #expect(throws: ActivePanelValidationError.wrongCommandOrSchema) { _ = try discover(value) }
        value = envelope(); value.info.outcome = "failure"
        #expect(throws: ActivePanelValidationError.unsuccessfulOutcome("failure")) { _ = try discover(value) }
        #expect(throws: ActivePanelValidationError.oversizedJSON) {
            _ = try ActivePanelDecoder.decodeDiscovery(Data(repeating: 32, count: ActivePanelDecoder.maximumJSONBytes + 1),
                simulatorUDID: simulatorID, expectedCatalog: catalog, exactArguments: arguments)
        }
    }

    @Test func selectedReadStillRejectsWrongPanelAndRotation() throws {
        let data = try JSONEncoder().encode(envelope())
        let inactive = ActivePanelExpectation(identity: catalog[0].identity, nativePixelWidth: 1398,
            nativePixelHeight: 2034, scale: 3, rotation: .rot0)
        #expect(throws: ActivePanelValidationError.inactiveSelection(requested: catalog[0].identity, observed: catalog[1].identity)) {
            _ = try ActivePanelDecoder.decode(data, simulatorUDID: simulatorID, expectedPanels: catalog.map(\.identity),
                selected: inactive, exactArguments: arguments)
        }
        let rotated = ActivePanelExpectation(identity: catalog[1].identity, nativePixelWidth: 2007,
            nativePixelHeight: 2853, scale: 3, rotation: .rot90)
        #expect(throws: ActivePanelValidationError.selectedRotationMismatch) {
            _ = try ActivePanelDecoder.decode(data, simulatorUDID: simulatorID, expectedPanels: catalog.map(\.identity),
                selected: rotated, exactArguments: arguments)
        }
    }

    @Test func rigidProfileRemainsExplicitAndDoesNotInventAnActiveFlag() throws {
        var value = envelope(); value.result.displays = [value.result.displays[0]]
        value.result.displays[0].active = nil
        #expect(throws: ActivePanelValidationError.missingActiveFlag) { _ = try discover(value, expected: [catalog[0]]) }
        let data = try JSONEncoder().encode(value)
        let snapshot = try ActivePanelDecoder.decodeDiscovery(data, simulatorUDID: simulatorID,
            expectedCatalog: [catalog[0]], exactArguments: arguments, schemaPolicy: .verifiedIPhone18ProProfile405)
        #expect(snapshot.selectionBasis == .verifiedSingleIntegratedPanel && snapshot.activePanel.active == nil)
        value.info.version = "unknown"
        #expect(throws: ActivePanelValidationError.unsupportedRigidSchema) {
            _ = try ActivePanelDecoder.decodeDiscovery(JSONEncoder().encode(value), simulatorUDID: simulatorID,
                expectedCatalog: [catalog[0]], exactArguments: arguments, schemaPolicy: .verifiedIPhone18ProProfile405)
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
        let snapshot = try discover(envelope())
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
        let snapshot = try discover(envelope())
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
