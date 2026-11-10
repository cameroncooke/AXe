import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Native object alias classes")
struct FBSimulatorAXNativeObjectIndexTests {
  @Test func singletonKeepsItsOccurrence() throws {
    let fixture = AliasFixture()
    let index = try make([fixture])
    let result = try index.resolve(identity: fixture.key, elementType: "Button", expectedPID: 42)
    #expect(!result.isAlias)
    #expect(result.canonicalIndex == 0)
    #expect(result.occurrences.map(\.path) == [[0]])
  }

  @Test func equalAliasesKeepBothDifferentOwnershipPaths() throws {
    var button = AliasFixture()
    var text = button; text.nativeIdentity = .init(pid: 42, objectID: 200)
    text.type = "StaticText"; text.role = "AXStaticText"
    button.children = [text]
    var scroll = button; scroll.nativeIdentity = .init(pid: 42, objectID: 300)
    scroll.type = "ScrollArea"; scroll.role = "AXScrollArea"; scroll.children = [button]
    var root = scroll; root.nativeIdentity = .init(pid: 42, objectID: 400)
    root.type = "Group"; root.role = "AXGroup"; root.children = [scroll, button]
    let index = try make([root])
    let result = try index.resolve(identity: button.key, elementType: "Button", expectedPID: 42)
    #expect(result.occurrences.map(\.path) == [[0, 0, 0], [0, 1]])
    #expect(index.nodes.count == 6)
  }

  @Test(arguments: ["pid", "type", "role", "subrole", "description", "identifier", "label", "value",
    "focus", "enabled", "hidden", "unknown-enabled", "unknown-hidden", "negative-width", "negative-height",
    "frame", "actions", "child-key", "child-order", "missing-key"])
  func anyConflictingAppearanceRefusesTheWholeClass(change: String) throws {
    var original = AliasFixture()
    var child = original; child.nativeIdentity = .init(pid: 42, objectID: 200)
    var second = child; second.nativeIdentity = .init(pid: 42, objectID: 201)
    original.children = [child, second]
    var changed = original
    switch change {
    case "pid": changed.pid = 43
    case "type": changed.type = "Group"
    case "role": changed.role = "AXGroup"
    case "subrole": changed.subrole = "other"
    case "description": changed.role_description = "other"
    case "identifier": changed.AXUniqueId = "other"
    case "label": changed.AXLabel = "other"
    case "value": changed.AXValue = .string("other")
    case "focus": changed.focused = true
    case "enabled": changed.enabled = false
    case "hidden": changed.hidden = true
    case "unknown-enabled": changed.enabled = nil
    case "unknown-hidden": changed.hidden = nil
    case "negative-width": changed.frame.width = -100
    case "negative-height": changed.frame.height = -30
    case "frame": changed.frame.x += 1
    case "actions": changed.custom_actions = ["Other action"]
    case "child-key": changed.children[0].nativeIdentity = .init(pid: 42, objectID: 202)
    case "child-order": changed.children.reverse()
    default: changed.children[0].nativeIdentity = nil
    }
    #expect(throws: (any Error).self) {
      let index = try make([original, changed])
      _ = try index.resolve(identity: original.key, elementType: "Button", expectedPID: 42)
    }
  }

  @Test func childConflictOutsideMatchingParentsCannotBeHidden() throws {
    var parent = AliasFixture()
    var child = parent; child.nativeIdentity = .init(pid: 42, objectID: 200)
    parent.children = [child]
    var conflict = child; conflict.AXValue = .string("different")
    let index = try make([parent, parent, conflict])
    #expect(throws: FBSimulatorAXNativeObjectIndex.Failure.conflictingAliases) {
      _ = try index.resolve(identity: parent.key, elementType: "Button", expectedPID: 42)
    }
  }

  @Test func unsafeAncestorCannotBeFilteredOut() throws {
    let button = AliasFixture()
    for change in ["hidden", "disabled", "owner"] {
      var parent = button; parent.nativeIdentity = .init(pid: 42, objectID: 300)
      parent.type = "Group"; parent.role = "AXGroup"; parent.children = [button]
      if change == "hidden" { parent.hidden = true }
      else if change == "disabled" { parent.enabled = false }
      else { parent.pid = 43; parent.nativeIdentity = .init(pid: 43, objectID: 300) }
      let index = try make([button, parent])
      let expected: FBSimulatorAXNativeObjectIndex.Failure = change == "owner" ? .wrongOwnerOrType : .unavailableOccurrence
      #expect(throws: expected) {
        _ = try index.resolve(identity: button.key, elementType: "Button", expectedPID: 42)
      }
    }
  }

  @Test func equalAppearanceNeverMergesDifferentKeys() throws {
    let first = AliasFixture()
    var second = first; second.nativeIdentity = .init(pid: 42, objectID: UInt64.max)
    let index = try make([first, second])
    #expect(try index.resolve(identity: first.key, elementType: "Button", expectedPID: 42).occurrences.count == 1)
    #expect(try index.resolve(identity: second.key, elementType: "Button", expectedPID: 42).node.nativeIdentity?.objectID == UInt64.max)
    #expect(throws: FBSimulatorAXNativeObjectIndex.Failure.wrongOwnerOrType) {
      _ = try index.resolve(identity: first.key, elementType: "Button", expectedPID: 99)
    }
  }

  @Test(arguments: ["0", "1", "-1", "0.25", "1.00000000000000001", "1e-100", "9007199254740993",
    "[1]", #"{"n":1}"#, #"["text",{"n":[1.00000000000000001]}]"#])
  func anyNumericValueCannotSupplyConsistencyProof(rawValue: String) throws {
    let node = try rawNode(rawValue: rawValue)
    let index = try FBSimulatorAXNativeObjectIndex(roots: [node, node], metadata: .init(complete: true))
    #expect(index.subtreeDigest(for: .init(pid: 42, objectID: 100)) == nil)
    #expect(throws: FBSimulatorAXNativeObjectIndex.Failure.unprovableValue) {
      _ = try index.resolve(identity: .init(pid: 42, objectID: 100), elementType: "Button", expectedPID: 42)
    }
    // Even a singleton must not receive a stronger numeric claim from this resolver.
    let singleton = try FBSimulatorAXNativeObjectIndex(roots: [node], metadata: .init(complete: true))
    #expect(throws: FBSimulatorAXNativeObjectIndex.Failure.unprovableValue) {
      _ = try singleton.resolve(identity: .init(pid: 42, objectID: 100), elementType: "Button", expectedPID: 42)
    }
  }

  @Test func roundedDecimalCollisionDoesNotBecomeAConsistentAlias() throws {
    let first = try rawNode(rawValue: "1")
    let second = try rawNode(rawValue: "1.00000000000000001")
    #expect(first.value == second.value)
    let index = try FBSimulatorAXNativeObjectIndex(roots: [first, second], metadata: .init(complete: true))
    #expect(index.subtreeDigest(for: .init(pid: 42, objectID: 100)) == nil)
    #expect(throws: FBSimulatorAXNativeObjectIndex.Failure.unprovableValue) {
      _ = try index.resolve(identity: .init(pid: 42, objectID: 100), elementType: "Button", expectedPID: 42)
    }
  }

  @Test(arguments: ["null", "true", "false", #""1""#, "[]", "{}", #"[true,"1",null]"#,
    #"{"state":"1","flags":[true,false,null]}"#])
  func nonNumericValuesAndContainersKeepTheirExactTypedProof(rawValue: String) throws {
    let node = try rawNode(rawValue: rawValue)
    let index = try FBSimulatorAXNativeObjectIndex(roots: [node, node], metadata: .init(complete: true))
    #expect(try index.resolve(identity: .init(pid: 42, objectID: 100), elementType: "Button", expectedPID: 42).isAlias)
    #expect(index.subtreeDigest(for: .init(pid: 42, objectID: 100)) != nil)
  }

  @Test func incompleteTreeAndBoundsNeverSupplyUniqueness() throws {
    let fixture = AliasFixture()
    #expect(throws: FBSimulatorAXNativeObjectIndex.Failure.incompleteTree) {
      _ = try FBSimulatorAXNativeObjectIndex(roots: [fixture.node()], metadata: .init(complete: false))
    }
    #expect(throws: FBSimulatorAXNativeObjectIndex.Failure.hierarchyBound) {
      _ = try make(Array(repeating: fixture, count: 4097))
    }
    var deep = fixture
    for _ in 0..<65 {
      var parent = fixture; parent.children = [deep]; deep = parent
    }
    #expect(throws: FBSimulatorAXNativeObjectIndex.Failure.hierarchyBound) { _ = try make([deep]) }
  }

  @Test func existingPointAndFocusedPoliciesStayStrict() throws {
    let fixture = AliasFixture()
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: [fixture.node(), fixture.node()],
        identity: fixture.key, elementType: "Button")
    }
    var selection = FBAXFocusedNativeTextFieldSelection(identity: fixture.key)
    _ = try selection.include(identity: fixture.key)
    #expect(throws: FBSimulatorAXSnapshotError.self) { _ = try selection.include(identity: fixture.key) }
    var other = fixture; other.nativeIdentity = .init(pid: 42, objectID: 999)
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.hit([other.node()], expected: fixture.node(),
        selector: .nativeObject(identity: fixture.key, elementType: "Button"), expectedPID: 42, hitPID: 42,
        point: CGPoint(x: 50, y: 30))
    }
  }

  private func rawNode(rawValue: String) throws -> FBSimulatorAXNode {
    let text = #"{"type":"Button","role":"AXButton","pid":42,"nativeIdentity":{"pid":42,"objectID":"100"},"enabled":true,"hidden":false,"focused":false,"frame":{"x":0,"y":0,"width":100,"height":60},"children":[],"AXValue":\#(rawValue)}"#
    return try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(text.utf8))
  }

  private func make(_ fixtures: [AliasFixture]) throws -> FBSimulatorAXNativeObjectIndex {
    try FBSimulatorAXNativeObjectIndex(roots: fixtures.map { try $0.node() }, metadata: .init(complete: true))
  }
}

private struct AliasFixture: Encodable {
  var type = "Button", role = "AXButton"
  var subrole: String?, role_description: String? = "button", AXUniqueId: String?
  var AXLabel: String? = "Target", AXValue: FBSimulatorAXValue? = .string("")
  var pid: Int32 = 42
  var nativeIdentity: FBSimulatorAXNativeIdentity? = .init(pid: 42, objectID: 100)
  var focused: Bool? = false, enabled: Bool? = true, hidden: Bool? = false
  var custom_actions: [String] = []
  var frame = AliasFrame(x: 0, y: 0, width: 100, height: 60)
  var children: [AliasFixture] = []
  var key: FBSimulatorAXNativeIdentity { nativeIdentity! }
  func node() throws -> FBSimulatorAXNode { try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(self)) }
}

private struct AliasFrame: Encodable {
  var x: Double, y: Double, width: Double, height: Double
}
