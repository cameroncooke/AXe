import ArgumentParser
import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

@Suite("Ordinary broker keyboard wire compatibility")
struct HIDBrokerKeyboardRequestTests {
    private let udid = "00000000-0000-0000-0000-000000000001"

    @Test("A complete key survives encoding and decoding without event changes")
    func keyRoundTrip() throws {
        let input = FBSimulatorHIDEvent.shortKeyPress(42)
        let request = try HIDBrokerKeyboardRequest(event: input)
        let decoded = try JSONDecoder().decode(HIDBrokerKeyboardRequest.self,
            from: JSONEncoder().encode(request))
        try decoded.validate()
        #expect(decoded.event == input)
    }

    @Test("Eight arbitrary repeated modifiers and a repeated target remain valid")
    func rawComboCompatibility() throws {
        let codes: [UInt32] = [4, 4, 255, 0, 224, 1, 225, 225]
        let command = try KeyCombo.parse(["--modifiers", "4,4,255,0,224,1,225,225",
            "--key", "225", "--udid", udid])
        #expect(command.key == 225)
        let flat = codes.map { FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: $0) }
            + [.keyboard(direction: .down, keyCode: 225), .keyboard(direction: .up, keyCode: 225)]
            + codes.reversed().map { .keyboard(direction: .up, keyCode: $0) }
        let request = try HIDBrokerKeyboardRequest(event: .composite(flat))
        #expect(request.events.count == 18)
        let decoded = try JSONDecoder().decode(HIDBrokerKeyboardRequest.self,
            from: JSONEncoder().encode(request))
        try decoded.validate()
        #expect(decoded.event == .composite(flat))
    }

    @Test("A ten-second ordinary key remains valid and retains its duration")
    func durationUpperBound() throws {
        let command = try Key.parse(["42", "--duration", "10", "--udid", udid])
        let request = try HIDBrokerKeyboardRequest(event: command.selectedKeyboardEvent())
        #expect(request.event == .composite([.keyboard(direction: .down, keyCode: 42),
            .delay(10), .keyboard(direction: .up, keyCode: 42)]))
        #expect(throws: (any Error).self) {
            _ = try Key.parse(["42", "--duration", "10.01", "--udid", udid])
        }
    }

    @Test("Decoded requests reject missing releases, bad codes and excess bounds")
    func invalidWireRequests() throws {
        let invalid: [[SelectedKeyboardPrimitive]] = [
            [.down(4), .down(5)],
            [.up(4), .down(4)],
            [.down(256), .up(256)],
            [.down(4), .delay(10.01), .up(4)],
            [.down(4), .delay(6), .delay(5), .up(4)],
            Array(repeating: [SelectedKeyboardPrimitive.down(4), .up(4)], count: 10).flatMap { $0 },
        ]
        for events in invalid {
            let bytes = try JSONEncoder().encode(WirePayload(events: events))
            let request = try JSONDecoder().decode(HIDBrokerKeyboardRequest.self, from: bytes)
            #expect(throws: (any Error).self) { try request.validate() }
        }
        #expect(throws: (any Error).self) {
            _ = try HIDBrokerKeyboardRequest(event: .composite([
                .keyboard(direction: .down, keyCode: 4), .delay(.nan),
                .keyboard(direction: .up, keyCode: 4)]))
        }
    }

    @Test("Malformed or non-keyboard wire input cannot become a keyboard request")
    func malformedInput() {
        for json in [#"{}"#, #"{"events":[{"unknown":{"_0":4}}]}"#] {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(HIDBrokerKeyboardRequest.self, from: Data(json.utf8))
            }
        }
        #expect(throws: (any Error).self) {
            _ = try HIDBrokerKeyboardRequest(event: .tapAt(x: 1, y: 2))
        }
    }

    @Test("The ordinary keyboard extension uses the v5 endpoint")
    func wireVersion() throws {
        #expect(HIDBroker.protocolVersion == 5)
        let endpoint = try HIDBroker.endpointPath(simulatorUDID: udid,
            developerDirectory: "/Applications/Proof-Xcode.app/Contents/Developer")
        #expect(endpoint.hasSuffix("-v5.sock"))
    }

    private struct WirePayload: Encodable {
        let events: [SelectedKeyboardPrimitive]
    }
}
