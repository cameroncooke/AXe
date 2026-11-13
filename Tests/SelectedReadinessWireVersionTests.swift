import Foundation
import Testing
@testable import AXe

@Suite("Selected readiness wire isolation")
struct SelectedReadinessWireVersionTests {
    @Test("The readiness candidate cannot use the previous selected broker")
    func previousWireUsesAnotherEndpointAndIsRejected() throws {
        #expect(SelectedHIDRequest.version == 91)
        // The one literal check above; everything else follows the current version.
        let previousVersion = SelectedHIDRequest.version - 1
        let simulator = "wire-isolation-only"
        let developer = "/Applications/Xcode.app/Contents/Developer"
        let previous = try HIDBroker.endpointPath(simulatorUDID: simulator,
            developerDirectory: developer, version: previousVersion)
        let current = try HIDBroker.endpointPath(simulatorUDID: simulator,
            developerDirectory: developer, version: SelectedHIDRequest.version)
        #expect(previous != current)
        #expect(previous.hasSuffix("-v\(previousVersion).sock"))
        #expect(current.hasSuffix("-v\(SelectedHIDRequest.version).sock"))
        let screen = UUID(), token = UUID()
        let clean = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: 1, screenUUID: screen, operation: .close, token: token, payload: .contact([]))
        try clean.validate()
        let old = SelectedHIDRequest(version: previousVersion, requestID: clean.requestID,
            screenID: 1, screenUUID: screen, operation: .close, token: token, payload: .contact([]))
        #expect(throws: (any Error).self) { try old.validate() }
    }

    @Test("A request carries exactly one payload, on the wire too")
    func aMixedOrEmptyWirePayloadDoesNotDecode() throws {
        let clean = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 1,
            screenUUID: UUID(), operation: .complete, token: nil,
            payload: .button(SelectedButtonRequest(kind: .home, duration: nil, expectedBoot: nil)))
        try clean.validate()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clean)) as? [String: Any])
        var payload = try #require(object["payload"] as? [String: Any])
        #expect(Array(payload.keys) == ["button"])
        _ = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONSerialization.data(withJSONObject: object))

        // A second kind beside the first: the old type let a request carry both and refused it later.
        payload["contact"] = ["_0": [[String: Any]]()]
        object["payload"] = payload
        let mixed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(SelectedHIDRequest.self, from: mixed) }

        object["payload"] = [String: Any]()
        let empty = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(SelectedHIDRequest.self, from: empty) }
    }
}
