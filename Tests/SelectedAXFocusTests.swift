import Foundation
import FBSimulatorControl
import Testing

@Suite("Selected AX focus values")
struct SelectedAXFocusTests {
    @Test(arguments: [
        #"{"type":"TextField","AXUniqueId":"feature.text","children":[]}"#,
        #"{"type":"TextField","focused":null,"enabled":null,"hidden":null,"children":[]}"#
    ])
    func missingValuesRemainUnknown(json: String) throws {
        let node = try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(json.utf8))
        #expect(node.focused == nil)
        #expect(node.enabled == nil)
        #expect(node.hidden == nil)
        let encoded = try JSONEncoder().encode(node)
        let values = try JSONDecoder().decode([String: FBSimulatorAXValue].self, from: encoded)
        #expect(values["focused"] == nil)
        #expect(values["enabled"] == nil)
        #expect(values["hidden"] == nil)
    }

    @Test(arguments: [true, false])
    func booleanValuesSurviveRoundTrip(value: Bool) throws {
        let json = "{\"focused\":\(value),\"enabled\":\(value),\"hidden\":\(value),\"children\":[]}"
        let node = try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(json.utf8))
        let decoded = try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(node))
        #expect(decoded.focused == value)
        #expect(decoded.enabled == value)
        #expect(decoded.hidden == value)
    }

    @Test(arguments: [
        #"{"focused":1,"children":[]}"#,
        #"{"enabled":"true","children":[]}"#,
        #"{"hidden":{},"children":[]}"#
    ])
    func malformedValuesDoNotBecomeBooleans(json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(json.utf8))
        }
    }

    @Test func focusValuesRetainTheirNodeIdentity() throws {
        let json = #"{"type":"TextField","AXUniqueId":"feature.text","pid":42,"frame":{"x":1,"y":2,"width":30,"height":40},"focused":true,"enabled":true,"hidden":false,"children":[{"type":"Button","AXUniqueId":"other","focused":false,"enabled":false,"hidden":true,"children":[]}]}"#
        let node = try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(json.utf8))
        let decoded = try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(node))
        #expect(decoded.identifier == "feature.text" && decoded.pid == 42)
        #expect(decoded.frame == CGRect(x: 1, y: 2, width: 30, height: 40))
        #expect(decoded.focused == true && decoded.enabled == true && decoded.hidden == false)
        let child = try #require(decoded.children.first)
        #expect(child.identifier == "other")
        #expect(child.focused == false && child.enabled == false && child.hidden == true)
    }
}
