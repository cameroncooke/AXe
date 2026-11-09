import Foundation
import Testing
@testable import AXe

@Suite("Selected readiness wire isolation")
struct SelectedReadinessWireVersionTests {
    @Test("The readiness candidate cannot use the previous selected broker")
    func previousWireUsesAnotherEndpointAndIsRejected() throws {
        #expect(SelectedHIDRequest.version == 85)
        let simulator = "wire-isolation-only"
        let developer = "/Applications/Xcode.app/Contents/Developer"
        let previous = try HIDBroker.endpointPath(simulatorUDID: simulator,
            developerDirectory: developer, version: 72)
        let current = try HIDBroker.endpointPath(simulatorUDID: simulator,
            developerDirectory: developer, version: SelectedHIDRequest.version)
        #expect(previous != current)
        #expect(previous.hasSuffix("-v72.sock"))
        #expect(current.hasSuffix("-v85.sock"))
        let beforeWhitespace = try HIDBroker.endpointPath(simulatorUDID: simulator,
            developerDirectory: developer, version: 77)
        #expect(beforeWhitespace != current && beforeWhitespace.hasSuffix("-v77.sock"))
        let screen = UUID(), token = UUID()
        let clean = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: 1, screenUUID: screen, operation: .close, token: token, primitives: [])
        try clean.validate()
        let old = SelectedHIDRequest(version: 72, requestID: clean.requestID,
            screenID: 1, screenUUID: screen, operation: .close, token: token, primitives: [])
        #expect(throws: (any Error).self) { try old.validate() }
        let preWhitespace = SelectedHIDRequest(version: 77, requestID: clean.requestID,
            screenID: 1, screenUUID: screen, operation: .close, token: token, primitives: [])
        #expect(throws: (any Error).self) { try preWhitespace.validate() }
        let priorKeyboardEvidence = SelectedHIDRequest(version: 78, requestID: clean.requestID,
            screenID: 1, screenUUID: screen, operation: .close, token: token, primitives: [])
        #expect(throws: (any Error).self) { try priorKeyboardEvidence.validate() }
        let prePublication = SelectedHIDRequest(version: 79, requestID: clean.requestID,
            screenID: 1, screenUUID: screen, operation: .close, token: token, primitives: [])
        #expect(throws: (any Error).self) { try prePublication.validate() }
        let focusIDWire = SelectedHIDRequest(version: 84, requestID: clean.requestID,
            screenID: 1, screenUUID: screen, operation: .close, token: token, primitives: [])
        #expect(throws: (any Error).self) { try focusIDWire.validate() }
        let root35 = SelectedHIDRequest(version: 61, requestID: clean.requestID,
            screenID: 1, screenUUID: screen, operation: .close, token: token, primitives: [])
        #expect(throws: (any Error).self) { try root35.validate() }
    }
}
