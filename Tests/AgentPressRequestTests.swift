import Foundation
import Testing
@testable import AXe

@Suite("Agent accessibility press")
struct AgentPressRequestTests {
    private let udid = "33E4EEF5-58EC-4844-911E-8F0AE1DD31C0"
    private let snapshot = "AFAF9D1C-6A8F-40F8-B650-FDD447B29D0C"

    @Test("A press takes one ref with its snapshot, or one exact ID")
    func accepted() throws {
        let byRef = try Tap.parse(["--agent", "--semantic-press", "--snapshot-id", snapshot, "--ref", "e12", "--udid", udid])
        #expect(try byRef.agentRequest().agent?.kind == .press)
        #expect(try byRef.agentRequest().agent?.ref == "e12")
        let byID = try Tap.parse(["--agent", "--semantic-press", "--id", "row", "--udid", udid])
        #expect(try byID.agentRequest().agent?.selectorValue == "row")
        // Without the flag the same target is an ordinary touch.
        #expect(try Tap.parse(["--agent", "--id", "row", "--udid", udid]).agentRequest().agent?.kind == .tap)
    }

    @Test("A press refuses coordinates, labels, both targets, delays and a ref with no snapshot",
          arguments: [
            ["-x", "10", "-y", "20"], ["--label", "Call"], ["--id", "row", "--ref", "e12", "--snapshot-id", "AFAF9D1C-6A8F-40F8-B650-FDD447B29D0C"],
            ["--id", "row", "--pre-delay", "0.1"], ["--ref", "e12"], [],
          ])
    func refused(target: [String]) {
        #expect(throws: (any Error).self) {
            _ = try Tap.parse(["--agent", "--semantic-press", "--udid", "33E4EEF5-58EC-4844-911E-8F0AE1DD31C0"] + target)
        }
    }

    @Test("The request itself refuses a point or text")
    func requestValidation() throws {
        try AgentModeRequest(kind: .press, selectorKind: .id, selectorValue: "row").validate()
        #expect(throws: (any Error).self) {
            try AgentModeRequest(kind: .press, point: SelectedAXPoint(x: 1, y: 2), selectorKind: .id, selectorValue: "row").validate()
        }
        #expect(throws: (any Error).self) {
            try AgentModeRequest(kind: .press, selectorKind: .id, selectorValue: "row", text: "a").validate()
        }
        #expect(throws: (any Error).self) { try AgentModeRequest(kind: .press).validate() }
    }
}
