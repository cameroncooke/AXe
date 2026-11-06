import CoreGraphics
import Foundation
import FBControlCore
import Testing
@testable import FBSimulatorControl

@Suite("Selected AX role metadata")
struct FBSimulatorAXRoleMetadataTests {
  private func node(_ json: String) throws -> FBSimulatorAXNode {
    try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(json.utf8))
  }
  private func target(description: String) throws -> FBSimulatorAXNode {
    try node("""
      {"type":"Button","AXUniqueId":"target","AXLabel":"Tap","pid":42,
       "role":"AXButton","role_description":"\(description)","subrole":null,
       "frame":{"x":10,"y":10,"width":100,"height":40},
       "children":[{"type":"StaticText","AXLabel":"Tap","pid":42,
         "role":"AXStaticText","frame":{"x":40,"y":20,"width":40,"height":20}}]}
      """)
  }

  @Test func roleMetadataRoundTripKeepsValuesAndChildren() throws {
    let original = try node(#"{"type":"CheckBox","role":"AXSwitch","subrole":"AXSwitch","role_description":" Toggle \n","children":[{"role":"AXButton","subrole":"child","role_description":"button"}]}"#)
    let decoded = try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(original))
    #expect(decoded.type == "CheckBox" && decoded.role == "AXSwitch" && decoded.subrole == "AXSwitch")
    #expect(decoded.roleDescription == " Toggle \n")
    let child = try #require(decoded.children.first)
    #expect(child.role == "AXButton" && child.subrole == "child" && child.roleDescription == "button")
  }

  @Test(arguments: [#"{}"#, #"{"role":null,"subrole":null,"role_description":null}"#])
  func oldOrAbsentMetadataStaysNil(json: String) throws {
    let original = try node(json)
    #expect(original.role == nil && original.subrole == nil && original.roleDescription == nil)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(FBSimulatorAXNode.self, from: data)
    #expect(decoded.role == nil && decoded.subrole == nil && decoded.roleDescription == nil)
    #expect(!String(decoding: data, as: UTF8.self).contains("role"))
  }

  @Test(arguments: ["role", "subrole", "role_description"])
  func malformedTypedMetadataRejectsInsteadOfGuessing(key: String) throws {
    #expect(throws: (any Error).self) { _ = try node("{\"\(key)\":[]}") }
  }

  @Test func sharedWorkerRequestsOnlyExistingTypedKeys() {
    let expected: Set<FBAXKeys> = [.label, .value, .uniqueID, .type, .frameDict, .pid, .isRemote,
      .focused, .enabled, .hidden, .role, .roleDescription, .subrole, .customActions]
    #expect(FBSimulatorAXWorker.snapshotKeys == expected)
  }

  @Test func directPredicateReturnsFreshMetadataWithoutChangingIdentityRules() throws {
    let original = try target(description: "button")
    let fresh = try target(description: "toggle")
    let hit = try FBAXTargetValidationRules.hit([fresh], expected: original,
      selector: .identifierWithType("target", elementType: "Button"), expectedPID: 42, hitPID: 42,
      point: CGPoint(x: 60, y: 30))
    #expect(hit.roleDescription == "toggle" && original.roleDescription == "button")
    #expect(hit.identifier == original.identifier && hit.type == original.type && hit.frame == original.frame)
    // validateTarget now assigns this validated direct hit to verifiedTarget. The
    // CLI admission compares its role choice before the session enqueues input.
  }

  @Test func descendantPredicateReturnsFreshSelectedButtonNotChildMetadata() throws {
    let original = try target(description: "button")
    let fresh = try target(description: "toggle")
    let child = try #require(fresh.children.first)
    let verified = try FBAXTargetValidationRules.descendantHit([child], freshRoots: [fresh], expected: original,
      selector: .labelWithType("Tap", elementType: "Button"), expectedPID: 42, hitPID: 42,
      point: CGPoint(x: 60, y: 30))
    #expect(verified.roleDescription == "toggle" && verified.type == "Button")
    #expect(child.type == "StaticText" && child.role == "AXStaticText")
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.descendantHit([child], freshRoots: [fresh, fresh], expected: original,
        selector: .labelWithType("Tap", elementType: "Button"), expectedPID: 42, hitPID: 42,
        point: CGPoint(x: 60, y: 30))
    }
  }

  @Test func directRoleMetadataDoesNotBypassExistingPIDFrameOrSelectorChecks() throws {
    let original = try target(description: "button")
    let fresh = try target(description: "toggle")
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.hit([fresh], expected: original, selector: .identifier("other"),
        expectedPID: 42, hitPID: 42, point: CGPoint(x: 60, y: 30))
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.hit([fresh], expected: original, selector: .identifier("target"),
        expectedPID: 42, hitPID: 43, point: CGPoint(x: 60, y: 30))
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.hit([fresh], expected: original, selector: .identifier("target"),
        expectedPID: 42, hitPID: 42, point: CGPoint(x: 1, y: 1))
    }
  }
}
