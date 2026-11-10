import Foundation
import Testing
@testable import AXe

@Suite("Raw broker wire")
struct HIDBrokerWireTests {
    private let udid = "00000000-0000-0000-0000-000000000001"

    @Test("The raw broker uses the v5 endpoint")
    func wireVersion() throws {
        #expect(HIDBroker.protocolVersion == 5)
        let endpoint = try HIDBroker.endpointPath(simulatorUDID: udid,
            developerDirectory: "/Applications/Proof-Xcode.app/Contents/Developer")
        #expect(endpoint.hasSuffix("-v5.sock"))
    }

    /// Keys use the direct route without a shared owner. A keyboard-only request from an older
    /// build decodes with no touches and is refused instead of reporting success.
    @Test("A request without touches is refused before input")
    func emptyRequestIsRefused() throws {
        #expect(throws: CLIError.self) { try HIDBroker.validate([]) }
        try HIDBroker.validate([.touch(.down, x: 1, y: 2), .delay(0.1), .touch(.up, x: 1, y: 2)])
    }
}
