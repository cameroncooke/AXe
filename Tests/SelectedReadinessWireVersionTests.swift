import Foundation
import Testing
@testable import AXe

@Suite("Selected readiness wire isolation")
struct SelectedReadinessWireVersionTests {
    @Test("The readiness candidate cannot use the previous selected broker")
    func previousWireUsesAnotherEndpointAndIsRejected() throws {
        #expect(SelectedHIDRequest.version == 88)
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
            screenID: 1, screenUUID: screen, operation: .close, token: token, primitives: [])
        try clean.validate()
        let old = SelectedHIDRequest(version: previousVersion, requestID: clean.requestID,
            screenID: 1, screenUUID: screen, operation: .close, token: token, primitives: [])
        #expect(throws: (any Error).self) { try old.validate() }
    }
}
