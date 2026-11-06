import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Selected slider type filter")
struct FBSimulatorSliderTypeTests {
  private struct Node: Encodable {
    var type: String? = "Slider"
    var AXUniqueId = "target"
    var pid: Int32 = 42
    var frame = Frame()
  }
  private struct Frame: Encodable {
    var x = 10.0
    var y = 20.0
    var width = 100.0
    var height = 30.0
  }
  private func node(_ value: Node = Node()) throws -> FBSimulatorAXNode {
    try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(value))
  }
  private func resolve(_ roots: [FBSimulatorAXNode], type: String?) throws -> FBSimulatorAXNode {
    try FBSimulatorSliderTargetSelection.resolve(roots: roots, identifier: "target",
      expectedPID: 42, elementType: type)
  }

  @Test(arguments: [nil, "Slider"] as [String?])
  func matchingAndOmittedFilterKeepTheUniqueNativeSlider(type: String?) throws {
    let expected = try node()
    let actual = try resolve([expected], type: type)
    #expect(actual.identifier == expected.identifier && actual.pid == 42 && actual.type == "Slider")
    #expect(actual.frame == expected.frame)
  }

  @Test(arguments: ["slider", "SLIDER", " Slider", "Slider ", "Button", "", " "])
  func filterIsExactAndCannotExpandNativeRole(type: String) throws {
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([node()], type: type) }
  }

  @Test(arguments: [nil, "Slider"] as [String?])
  func duplicateExactIDsRejectBeforeTypeFiltering(type: String?) throws {
    let slider = try node()
    let other = try node(Node(type: "Button"))
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([slider, other], type: type) }
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([slider, slider], type: type) }
  }

  @Test(arguments: [nil, "Button", "slider"] as [String?])
  func freshOwnedHandleRoleChangeRejects(type: String?) throws {
    _ = try resolve([node()], type: "Slider")
    // Both initial tree and immediate pre-action handle reads use this production gate.
    // The second read must fail; this check does not perform a native action.
    let fresh = try node(Node(type: type))
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([fresh], type: "Slider") }
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([fresh], type: nil) }
  }

  @Test(arguments: ["pid", "zeroWidth", "negativeWidth", "negativeHeight", "wrongID"])
  func existingPIDFrameAndIDRulesRemainRequired(change: String) throws {
    var value = Node()
    switch change {
    case "pid": value.pid = 43
    case "zeroWidth": value.frame.width = 0
    case "negativeWidth": value.frame.width = -1
    case "negativeHeight": value.frame.height = -1
    default: value.AXUniqueId = "other"
    }
    let changed = try node(value)
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([changed], type: "Slider") }
  }

  @Test func exactIDDoesNotGainSelectorWhitespaceNormalization() throws {
    let padded = try node(Node(AXUniqueId: " target "))
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([padded], type: "Slider") }
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([], type: "Slider") }
  }
}
