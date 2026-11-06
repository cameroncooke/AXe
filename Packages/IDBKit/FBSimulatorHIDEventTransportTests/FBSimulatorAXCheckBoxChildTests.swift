import Foundation
import CoreGraphics
import Testing
@testable import FBSimulatorControl

@Suite("Named CheckBox row with unnamed native child")
struct FBSimulatorAXCheckBoxChildTests {
  @Test("Recorded Weather geometry selects the real child and keeps the parent identity")
  func weatherGeometry() throws {
    let roots = try roots([row()])
    let parent = roots[0].children[0]
    let candidate = try select(roots)
    let selection = try #require(candidate)
    let childFrame = try #require(selection.child.frame)
    let parentFrame = try #require(parent.frame)
    #expect(childFrame.maxX > parentFrame.maxX)
    #expect(parentFrame.contains(selection.point))
    #expect(selection.point == CGPoint(x: childFrame.midX, y: childFrame.midY))
    #expect(abs(selection.point.x - 331.1069651741293) < 0.000001)
    #expect(selection.point.x != parentFrame.midX)
    let verified = try selection.validate(in: roots, hitRoots: [selection.child],
      selector: selector, expectedPID: 2934, hitPID: 2934, context: context())
    #expect(verified.label == "Atmospheric animations")
    #expect(verified.frame == parentFrame)
    #expect(verified.children.count == 2)
  }

  @Test("The exact owned parent hit must reproduce its unique child at the selected point")
  func nativeParentPointHit() throws {
    let native = try roots([row()])
    let candidate = try select(native)
    let selection = try #require(candidate)
    let parent = native[0].children[0]
    let verified = try selection.validate(in: native, hitRoots: [parent],
      selector: selector, expectedPID: 2934, hitPID: 2934, context: context())
    #expect(verified.label == "Atmospheric animations")
    #expect(verified.frame == parent.frame)
    #expect(selection.matchKind(initialHit: parent, confirmedHit: parent) == "uniqueCheckBoxChildParentHit")
    #expect(selection.matchKind(initialHit: selection.child, confirmedHit: parent) == "uniqueCheckBoxChildMixedHit")
    #expect(selection.matchKind(initialHit: selection.child, confirmedHit: selection.child) == "uniqueCheckBoxChild")
  }

  @Test("The saved read-only Weather point result admits only its owned parent and child")
  func recordedSevereWeatherPointHit() throws {
    let pointRoots = try JSONDecoder().decode([FBSimulatorAXNode].self, from: Data(recordedPointRoots.utf8))
    let wrapped = try JSONEncoder().encode([NativeRoot(children: pointRoots)])
    let native = try JSONDecoder().decode([FBSimulatorAXNode].self, from: wrapped)
    let selector = FBSimulatorAXSelector.labelWithType("Severe weather alerts", elementType: "CheckBox")
    let candidate = try FBAXCheckBoxChildSelection.select(in: native, parent: pointRoots[0],
      selector: selector, expectedPID: 2934, context: context())
    let selection = try #require(candidate)
    let childFrame = try #require(selection.child.frame)
    #expect(childFrame.contains(CGPoint(x: 331, y: 849)))
    let verified = try selection.validate(in: native, hitRoots: pointRoots,
      selector: selector, expectedPID: 2934, hitPID: 2934, context: context())
    #expect(verified.label == "Severe weather alerts" && verified.value == .string("0"))
    #expect(selection.matchKind(initialHit: pointRoots[0], confirmedHit: pointRoots[0]) == "uniqueCheckBoxChildParentHit")
  }

  @Test("Existing Button and named UIKit switch paths retain their selection")
  func existingPaths() throws {
    var button = row(); button.type = "Button"; button.role = "AXButton"
    let buttonRoots = try roots([button])
    #expect(try FBAXCheckBoxChildSelection.select(in: buttonRoots,
      parent: buttonRoots[0].children[0], selector: .labelWithType("Atmospheric animations", elementType: "Button"),
      expectedPID: 2934, context: context()) == nil)
    var namedSwitch = row()
    namedSwitch.id = "feature.switch"
    namedSwitch.children = [Fixture(type: "Group", role: "AXGroup", label: nil)]
    #expect(try select(roots([namedSwitch])) == nil)
  }

  @Test(arguments: ["duplicate-parent", "duplicate-child", "hidden-global-duplicate", "disabled-parent",
    "hidden-parent", "disabled-child", "hidden-child", "foreign-child", "value-mismatch",
    "nonbinary-value", "nonleaf-child", "outside-parent", "outside-viewport", "missing-role",
    "missing-enabled", "missing-hidden", "negative-parent-width", "negative-parent-height",
    "negative-child-width", "negative-child-height"])
  func invalidInitialRelationship(variant: String) throws {
    var parent = row()
    var siblings: [Fixture] = []
    switch variant {
    case "duplicate-parent": siblings.append(parent)
    case "duplicate-child": parent.children.append(parent.children[1])
    case "hidden-global-duplicate":
      var duplicate = parent.children[1]; duplicate.hidden = true; siblings.append(duplicate)
    case "disabled-parent": parent.enabled = false
    case "hidden-parent": parent.hidden = true
    case "disabled-child": parent.children[1].enabled = false
    case "hidden-child": parent.children[1].hidden = true
    case "foreign-child": parent.children[1].pid = 99
    case "value-mismatch": parent.children[1].value = "0"
    case "nonbinary-value": parent.value = "mixed"; parent.children[1].value = "mixed"
    case "nonleaf-child": parent.children[1].children = [Fixture(type: "Group", role: "AXGroup")]
    case "outside-parent": parent.children[1].frame.x = 370
    case "outside-viewport": parent.frame.y = 900; parent.children[1].frame.y = 900
    case "missing-enabled": parent.children[1].enabled = nil
    case "missing-hidden": parent.children[1].hidden = nil
    case "negative-parent-width":
      parent.frame.x += parent.frame.width; parent.frame.width *= -1
    case "negative-parent-height":
      parent.frame.y += parent.frame.height; parent.frame.height *= -1
    case "negative-child-width":
      parent.children[1].frame.x += parent.children[1].frame.width; parent.children[1].frame.width *= -1
    case "negative-child-height":
      parent.children[1].frame.y += parent.children[1].frame.height; parent.children[1].frame.height *= -1
    default: parent.children[1].role = nil
    }
    #expect(throws: (any Error).self) { try select(roots([parent] + siblings)) }
  }

  @Test("A hidden ancestor cannot authorize the otherwise valid row")
  func hiddenAncestor() throws {
    var group = Fixture(type: "Group", role: "AXGroup", children: [row()])
    group.hidden = true
    let native = try roots([group])
    #expect(throws: (any Error).self) {
      try FBAXCheckBoxChildSelection.select(in: native,
        parent: native[0].children[0].children[0], selector: selector,
        expectedPID: 2934, context: context())
    }
  }

  @Test(arguments: ["moved-child", "moved-parent", "changed-values", "disabled-child", "hidden-parent",
    "reparent-child", "reparent-row", "new-child", "duplicate-parent"])
  func freshRelationshipMustStillMatch(variant: String) throws {
    let native = try roots([row()])
    let candidate = try select(native)
    let selection = try #require(candidate)
    var parent = row()
    var siblings: [Fixture] = []
    switch variant {
    case "moved-child": parent.children[1].frame.x += 1
    case "moved-parent": parent.frame.x += 1
    case "changed-values": parent.value = "0"; parent.children[1].value = "0"
    case "disabled-child": parent.children[1].enabled = false
    case "hidden-parent": parent.hidden = true
    case "reparent-child":
      let child = parent.children.removeLast()
      siblings.append(Fixture(type: "Group", role: "AXGroup", children: [child]))
    case "reparent-row":
      let fresh = try roots([Fixture(type: "Group", role: "AXGroup", children: [parent])])
      #expect(throws: (any Error).self) {
        try selection.validate(in: fresh, hitRoots: [selection.child], selector: selector,
          expectedPID: 2934, hitPID: 2934, context: context())
      }
      return
    case "new-child": parent.children[1].label = "Other"
    default: siblings.append(parent)
    }
    let fresh = try roots([parent] + siblings)
    #expect(throws: (any Error).self) {
      try selection.validate(in: fresh, hitRoots: [selection.child], selector: selector,
        expectedPID: 2934, hitPID: 2934, context: context())
    }
  }

  @Test(arguments: ["wrong-parent", "moved-hit", "wrong-value", "disabled-hit", "foreign-hit", "multiple-hits", "group-hit"])
  func onlyOwnedCheckBoxPointHitAdmits(variant: String) throws {
    let native = try roots([row()])
    let candidate = try select(native)
    let selection = try #require(candidate)
    var child = row().children[1]
    var hitPID: Int32 = 2934
    var hits: [FBSimulatorAXNode]
    switch variant {
    case "wrong-parent":
      var other = row(); other.label = "Severe weather alerts"; hits = try decode([other])
    case "moved-hit": child.frame.x += 1; hits = try decode([child])
    case "wrong-value": child.value = "0"; hits = try decode([child])
    case "disabled-hit": child.enabled = false; hits = try decode([child])
    case "foreign-hit": child.pid = 99; hitPID = 99; hits = try decode([child])
    case "group-hit": child.type = "Group"; child.role = "AXGroup"; hits = try decode([child])
    default: hits = [selection.child, selection.child]
    }
    #expect(throws: (any Error).self) {
      try selection.validate(in: native, hitRoots: hits, selector: selector,
        expectedPID: 2934, hitPID: hitPID, context: context())
    }
  }

  @Test(arguments: ["moved-child", "changed-child-value", "hidden-child", "duplicate-child",
    "missing-child", "foreign-child", "named-child", "group-parent"])
  func parentPointSubtreeMustKeepExactChild(variant: String) throws {
    let native = try roots([row()])
    let candidate = try select(native)
    let selection = try #require(candidate)
    var parentHit = row()
    switch variant {
    case "moved-child": parentHit.children[1].frame.x += 1
    case "changed-child-value": parentHit.children[1].value = "0"
    case "hidden-child": parentHit.children[1].hidden = true
    case "duplicate-child": parentHit.children.append(parentHit.children[1])
    case "missing-child": parentHit.children.removeLast()
    case "foreign-child": parentHit.children[1].pid = 99
    case "named-child": parentHit.children[1].label = "Another control"
    default: parentHit.type = "Group"; parentHit.role = "AXGroup"
    }
    let hits = try decode([parentHit])
    #expect(throws: (any Error).self) {
      try selection.validate(in: native, hitRoots: hits, selector: selector,
        expectedPID: 2934, hitPID: 2934, context: context())
    }
  }

  private var selector: FBSimulatorAXSelector {
    .labelWithType("Atmospheric animations", elementType: "CheckBox")
  }

  private func context() throws -> FBSimulatorHIDDisplayContext {
    try .init(hidTarget: 1, nativePixelSize: CGSize(width: 1206, height: 2622), scale: 3, rotation: .rot0)
  }

  private func select(_ roots: [FBSimulatorAXNode]) throws -> FBAXCheckBoxChildSelection? {
    try FBAXCheckBoxChildSelection.select(in: roots, parent: roots[0].children[0],
      selector: selector, expectedPID: 2934, context: context())
  }

  private func roots(_ children: [Fixture]) throws -> [FBSimulatorAXNode] {
    try decode([Fixture(type: "Application", role: "AXApplication", label: "Weather",
      frame: .init(x: 0, y: 0, width: 402, height: 874), children: children)])
  }

  private func decode(_ values: [Fixture]) throws -> [FBSimulatorAXNode] {
    try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode(values))
  }

  private func row() -> Fixture {
    Fixture(type: "CheckBox", role: "AXCheckBox", label: "Atmospheric animations",
      frame: .init(x: 42.56716537475586, y: 782.1426391601562,
        width: 316.86566162109375, height: 26.88555908203125), children: [
          Fixture(type: "StaticText", role: "AXStaticText", label: "Atmospheric animations", value: nil),
          Fixture(type: "CheckBox", role: "AXCheckBox", frame: .init(x: 300.8606965174129,
            y: 782.1426202321725, width: 60.49253731343282, height: 26.885572139303463))])
  }

  private struct Fixture: Encodable {
    struct Frame: Encodable {
      var x = 0.0
      var y = 0.0
      var width = 20.0
      var height = 20.0
    }
    var type: String
    var role: String?
    var label: String? = nil
    var value: String? = "1"
    var id: String? = nil
    var frame = Frame()
    var children: [Fixture] = []
    var pid: Int32 = 2934
    var enabled: Bool? = true
    var hidden: Bool? = false
    private enum CodingKeys: String, CodingKey {
      case type, role, label = "AXLabel", value = "AXValue", id = "AXUniqueId", frame, children, pid, enabled, hidden
    }
  }

  private struct NativeRoot: Encodable {
    let type = "Application"
    let role = "AXApplication"
    let pid: Int32 = 2934
    let children: [FBSimulatorAXNode]
  }

  // Exact ax.roots payload from weather-switch-child-point-v4/stdout on 2026-11-02.
  // The public read at (331, 849) sent zero input events.
  private var recordedPointRoots: String {
    #"""
    [{
      "AXLabel":"Severe weather alerts","AXValue":"0",
      "children":[
        {"AXLabel":"Severe weather alerts","children":[],"enabled":true,"focused":false,
         "frame":{"height":17.283582089552283,"width":142.74958540630183,"x":42.56716417910448,"y":840.714759535655},
         "hidden":false,"is_remote":"recursive","pid":2934,"role":"AXStaticText","role_description":"text","type":"StaticText"},
        {"AXValue":"0","children":[],"enabled":true,"focused":false,
         "frame":{"height":26.885572139303463,"width":60.49253731343282,"x":300.8606965174129,"y":835.9137645107794},
         "hidden":false,"is_remote":"recursive","pid":2934,"role":"AXCheckBox","role_description":"switch","subrole":"AXSwitch","type":"CheckBox"}
      ],
      "enabled":true,"focused":false,
      "frame":{"height":26.88555908203125,"width":316.86566162109375,"x":42.56716537475586,"y":835.9137573242188},
      "hidden":false,"is_remote":"recursive","pid":2934,"role":"AXCheckBox","role_description":"switch","subrole":"AXSwitch","type":"CheckBox"
    }]
    """#
  }
}
