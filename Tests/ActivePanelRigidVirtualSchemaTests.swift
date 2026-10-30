import CryptoKit
import Foundation
import FBSimulatorControl
import Testing

enum RigidVirtualRefusal: String, CaseIterable, Sendable {
    case virtualActive, virtualNullActive, virtualPrimary, virtualIDAliasesHost, virtualUUIDAliasesHost
    case integratedNotPrimary, integratedExplicitActive, virtualBacklightOn, virtualBacklightMissing
    case unknownVersion, wrongJSONVersion, explicitPolicy, unmeasuredIPadPolicy
    case wrongExpectedUUID, wrongExpectedGeometry, wrongExpectedScale, extraExpectedPanel
}

@Suite("Measured rigid virtual display schema")
struct ActivePanelRigidVirtualSchemaTests {
    private let simulatorID = UUID(uuidString: "419D3218-79E5-46DE-80C0-E58126A88252")!
    private let integratedID = UUID(uuidString: "C9C67EB7-DEE7-4389-A69E-9A95C4D96AB6")!
    private let virtualID = UUID(uuidString: "CFEDE4CA-5DE9-479B-A28E-CBDD342D19C4")!
    private var arguments: [String] {
        ["devicectl", "device", "info", "displays", "--device", simulatorID.uuidString,
         "--timeout", "5", "--json-output", "/private/tmp/axe-ordinary-displays-20261028-control-v1.json"]
    }
    private var host: [ActivePanelCatalogEntry] {
        [ActivePanelCatalogEntry(identity: .init(displayID: 1, uniqueID: integratedID),
            nativePixelWidth: 1206, nativePixelHeight: 2622, scale: 3)]
    }

    private func fixture() throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "scripts/fixtures/iphone18pro-65128-virtual-omitted-active.json"))
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(actual == "d8cca5f8a5dad79a6d63e44959293d2cc66934b05e7a5ad75c1ae9d7af98c8e9")
        return data
    }

    private func discover(_ data: Data, expected: [ActivePanelCatalogEntry]? = nil,
                          policy: ActivePanelSchemaPolicy = .verifiedIPhone18ProProfile405) throws -> ActivePanelSnapshot {
        try ActivePanelDecoder.decodeDiscovery(data, simulatorUDID: simulatorID,
            expectedCatalog: expected ?? host, exactArguments: arguments, schemaPolicy: policy)
    }

    private func replace(_ text: String, _ before: String, _ after: String) throws -> String {
        try #require(text.components(separatedBy: before).count == 2, "Fixture mutation must match one field.")
        return text.replacingOccurrences(of: before, with: after)
    }

    private func requireIntegrated(_ snapshot: ActivePanelSnapshot) {
        #expect(snapshot.panels.count == 1 && snapshot.activePanel.identity == host[0].identity)
        #expect(snapshot.activePanel.primary && snapshot.activePanel.active == nil)
        #expect(snapshot.activePanel.nativePixelWidth == 1206 && snapshot.activePanel.nativePixelHeight == 2622)
        #expect(snapshot.activePanel.boundsOriginX == 0 && snapshot.activePanel.boundsOriginY == 0)
        #expect(snapshot.activePanel.boundsWidth == 1206 && snapshot.activePanel.boundsHeight == 2622)
        #expect(snapshot.activePanel.pointScale == 3 && snapshot.activePanel.currentOrientation == .rot0)
        #expect(snapshot.selectionBasis == .verifiedSingleIntegratedPanel)
        #expect(!snapshot.panels.contains { $0.identity.displayID == 4 || $0.identity.uniqueID == virtualID })
    }

    @Test("The exact measured report selects the independently expected integrated screen")
    func actualReportRetainsIntegratedIdentityAndGeometry() throws {
        let snapshot = try discover(fixture())
        requireIntegrated(snapshot)
        let copy = try JSONDecoder().decode(ActivePanelSnapshot.self, from: JSONEncoder().encode(snapshot))
        requireIntegrated(copy)
    }

    @Test("Selected admission retains the same measured integrated screen and rotation")
    func selectedReadRetainsExpectedScreen() throws {
        let snapshot = try ActivePanelDecoder.decode(fixture(), simulatorUDID: simulatorID,
            expectedPanels: host.map(\.identity),
            selected: .init(identity: host[0].identity, nativePixelWidth: 1206,
                nativePixelHeight: 2622, scale: 3, rotation: .rot0),
            exactArguments: arguments, schemaPolicy: .verifiedIPhone18ProProfile405)
        requireIntegrated(snapshot)
    }

    @Test("An explicit inactive virtual row still follows the existing active-flag path")
    func explicitInactiveVirtualPathIsUnchanged() throws {
        var text = String(decoding: try fixture(), as: UTF8.self)
        text = try replace(text, "\"backlightState\" : \"activeOn\",\n        \"bounds\"",
            "\"active\" : true,\n        \"backlightState\" : \"activeOn\",\n        \"bounds\"")
        text = try replace(text, "\"backlightState\" : \"off\"", "\"active\" : false,\n        \"backlightState\" : \"off\"")
        let snapshot = try discover(Data(text.utf8), policy: .explicitActiveFlag)
        #expect(snapshot.panels.count == 1 && snapshot.activePanel.identity == host[0].identity)
        #expect(snapshot.activePanel.primary && snapshot.activePanel.active == true)
        #expect(snapshot.selectionBasis == .explicitActiveFlag)
    }

    @Test("Unmeasured or ambiguous virtual rows and host catalogues remain rejected", arguments: RigidVirtualRefusal.allCases)
    func unsafeReportsAreRejected(_ variant: RigidVirtualRefusal) throws {
        var text = String(decoding: try fixture(), as: UTF8.self)
        var expected = host
        var policy = ActivePanelSchemaPolicy.verifiedIPhone18ProProfile405
        var failure = ActivePanelValidationError.catalogMismatch
        switch variant {
        case .virtualActive:
            text = try replace(text, "\"backlightState\" : \"off\"", "\"active\" : true,\n        \"backlightState\" : \"off\"")
        case .virtualNullActive:
            text = try replace(text, "\"backlightState\" : \"off\"", "\"active\" : null,\n        \"backlightState\" : \"off\"")
        case .virtualPrimary:
            text = try replace(text, "\"primary\" : false", "\"primary\" : true")
        case .virtualIDAliasesHost:
            text = try replace(text, "\"displayId\" : 4", "\"displayId\" : 1")
            failure = .duplicateIdentity
        case .virtualUUIDAliasesHost:
            text = try replace(text, virtualID.uuidString, integratedID.uuidString)
            failure = .duplicateIdentity
        case .integratedNotPrimary:
            text = try replace(text, "\"primary\" : true", "\"primary\" : false")
        case .integratedExplicitActive:
            text = try replace(text, "\"backlightState\" : \"activeOn\",\n        \"bounds\"",
                "\"active\" : true,\n        \"backlightState\" : \"activeOn\",\n        \"bounds\"")
        case .virtualBacklightOn:
            text = try replace(text, "\"backlightState\" : \"off\"", "\"backlightState\" : \"activeOn\"")
        case .virtualBacklightMissing:
            text = try replace(text, "\"backlightState\" : \"off\",", "")
        case .unknownVersion:
            text = try replace(text, "\"version\" : \"651.28\"", "\"version\" : \"651.29\"")
        case .wrongJSONVersion:
            text = try replace(text, "\"jsonVersion\" : 5", "\"jsonVersion\" : 6")
            failure = .wrongCommandOrSchema
        case .explicitPolicy:
            policy = .explicitActiveFlag
        case .unmeasuredIPadPolicy:
            policy = .verifiedIPadMiniA17ProProfile405
        case .wrongExpectedUUID:
            expected = [.init(identity: .init(displayID: 1, uniqueID: virtualID),
                nativePixelWidth: 1206, nativePixelHeight: 2622, scale: 3)]
        case .wrongExpectedGeometry:
            expected = [.init(identity: host[0].identity, nativePixelWidth: 1207, nativePixelHeight: 2622, scale: 3)]
            failure = .catalogGeometryMismatch(1)
        case .wrongExpectedScale:
            expected = [.init(identity: host[0].identity, nativePixelWidth: 1206, nativePixelHeight: 2622, scale: 2)]
            failure = .catalogGeometryMismatch(1)
        case .extraExpectedPanel:
            expected.append(.init(identity: .init(displayID: 4, uniqueID: virtualID),
                nativePixelWidth: 7680, nativePixelHeight: 4320, scale: 3))
        }
        let data = Data(text.utf8)
        if variant == .virtualNullActive {
            do {
                _ = try discover(data, expected: expected, policy: policy)
                Issue.record("Explicit null active was accepted.")
            } catch ActivePanelValidationError.malformedJSON(_) {}
        } else {
            #expect(throws: failure) { _ = try discover(data, expected: expected, policy: policy) }
        }
    }
}
