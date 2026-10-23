import ArgumentParser
import Foundation
import Testing
@testable import AXe

@Suite("Explicit selected semantic press")
struct SelectedAXSemanticPressTests {
    private let selected = ["--udid", "TEST", "--input-mode", "selected", "--screen-id", "3",
        "--screen-uuid", "769ED878-389B-4346-9C56-CB0703AB3E58", "--expected-pid", "42"]

    @Test func explicitSemanticPressProducesOnlyAXPayload() throws {
        let command = try Tap.parse(selected + ["--id", "feature.switch", "--semantic-press"])
        let request = try command.selectedAX.request(input: command.selectedInput,
            kind: .semanticPress, selectorKind: .id, selectorValue: command.elementID)
        try request.validate()
        #expect(request.ax?.kind == .semanticPress)
        #expect(request.primitives.isEmpty && request.path == nil && request.pinch == nil)
        #expect(request.operation == .complete && request.token == nil)
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(request))
        try decoded.validate()
        #expect(decoded.ax?.kind == .semanticPress && decoded.ax?.selectorValue == "feature.switch")
    }

    @Test func legacyAndCoordinatePressAreRejected() {
        for args in [["--udid", "TEST", "--id", "feature.switch", "--semantic-press"],
            selected + ["-x", "20", "-y", "30", "--semantic-press"],
            selected + ["--label", "Switch", "--semantic-press"],
            selected + ["--id", "feature.switch", "--semantic-press", "--post-delay", "0"]] {
            #expect(throws: (any Error).self) { _ = try Tap.parse(args) }
        }
    }

    @Test func normalSelectedTapKeepsHIDTargetRoute() throws {
        let command = try Tap.parse(selected + ["--id", "feature.switch"])
        #expect(!command.semanticPress)
        let request = try command.selectedAX.request(input: command.selectedInput,
            kind: .tap, selectorKind: .id, selectorValue: command.elementID)
        #expect(request.ax?.kind == .tap)
    }

    @Test func wireSemanticPressRejectsWrongSelectorAndDelay() {
        for value in [SelectedAXRequest(kind: .semanticPress, expectedPID: 42,
            endpoint: nil, selectorKind: .label, selectorValue: "Switch", preDelay: 0, postDelay: 0),
            SelectedAXRequest(kind: .semanticPress, expectedPID: 42,
            endpoint: nil, selectorKind: .id, selectorValue: "feature.switch", preDelay: 0, postDelay: 1)] {
            #expect(throws: (any Error).self) { try value.validate() }
        }
    }
}
