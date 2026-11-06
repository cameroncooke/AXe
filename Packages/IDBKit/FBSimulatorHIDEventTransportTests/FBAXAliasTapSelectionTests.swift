import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Tap-only consistent native object admission")
struct FBAXAliasTapSelectionTests {
  @Test func singletonNumericKeepsOldStrictSelection() throws {
    var node = TapAliasFixture(); node.AXValue = .number(1)
    let snapshot = try make([node])
    #expect(try FBAXAliasTapSelection.select(in: snapshot, selector: selector, expectedPID: 42) == nil)
    #expect(try FBAXNativeObjectSelection.uniqueNode(in: snapshot.roots,
      identity: node.key, elementType: "Button").value == .number(1))
  }

  @Test func equalAliasesAllowExactDirectHitWithoutLosingPaths() throws {
    let node = TapAliasFixture()
    let original = try make([node, node])
    let selection = try #require(try FBAXAliasTapSelection.select(in: original, selector: selector, expectedPID: 42))
    let index = try selection.validateFresh(make([node, node]), original: original)
    #expect(selection.paths == [[0], [1]])
    #expect(try selection.match(pointRoots: [node.node()], hitPID: 42, point: point, index: index)
      == "consistentAliasDirect")
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: original.roots, identity: node.key, elementType: "Button")
    }
  }

  @Test func sameChildInEveryAliasCanProveButtonOwnership() throws {
    let child = text()
    var node = TapAliasFixture(); node.children = [child]
    let original = try make([node, node])
    let selection = try #require(try FBAXAliasTapSelection.select(in: original, selector: selector, expectedPID: 42))
    let index = try selection.validateFresh(make([node, node]), original: original)
    #expect(try selection.match(pointRoots: [child.node()], hitPID: 42, point: point, index: index)
      == "consistentAliasButtonDescendant")
  }

  @Test(arguments: ["outside-owner", "nested-button", "direct-nested-button", "keyboard", "group", "wrong-pid", "moved-hit", "disabled-hit", "point-outside"])
  func pointCannotBorrowAnotherControlOrFrame(change: String) throws {
    var child = text()
    if change == "direct-nested-button" { child.type = "Button"; child.role = "AXButton" }
    var node = TapAliasFixture(); node.children = [child]
    var roots = [node, node]
    switch change {
    case "outside-owner": roots.append(child)
    case "nested-button":
      var nested = TapAliasFixture(); nested.nativeIdentity = .init(pid: 42, objectID: 300); nested.children = [child]
      node.children = [nested]; roots = [node, node]
    default: break
    }
    let original = try make(roots)
    let selection = try #require(try FBAXAliasTapSelection.select(in: original, selector: selector, expectedPID: 42))
    let index = try selection.validateFresh(make(roots), original: original)
    switch change {
    case "keyboard": child.nativeIdentity = .init(pid: 42, objectID: 999); child.type = "Button"; child.role = "AXButton"
    case "group": child.type = "Group"; child.role = "AXGroup"; child.nativeIdentity = .init(pid: 42, objectID: 999)
    case "moved-hit": child.frame.x += 1
    case "disabled-hit": child.enabled = false
    default: break
    }
    #expect(throws: (any Error).self) {
      _ = try selection.match(pointRoots: [child.node()], hitPID: change == "wrong-pid" ? 43 : 42,
        point: change == "point-outside" ? CGPoint(x: 200, y: 200) : point, index: index)
    }
  }

  @Test(arguments: ["count", "child", "value", "frame", "hidden", "disabled", "owner", "incomplete", "order"])
  func freshClassOrWholeTreeChangeRefusesAdmission(change: String) throws {
    let node = TapAliasFixture()
    var unrelated = text(); unrelated.nativeIdentity = .init(pid: 42, objectID: 300)
    let original = try make([node, node, unrelated])
    let selection = try #require(try FBAXAliasTapSelection.select(in: original, selector: selector, expectedPID: 42))
    var changed = node
    var roots = [node, node, unrelated]
    switch change {
    case "count": roots = [node, unrelated]
    case "child": changed.children = [text()]; roots = [changed, changed, unrelated]
    case "value": changed.AXValue = .string("changed"); roots = [changed, changed, unrelated]
    case "frame": changed.frame.width += 1; roots = [changed, changed, unrelated]
    case "hidden": changed.hidden = true; roots = [changed, changed, unrelated]
    case "disabled": changed.enabled = false; roots = [changed, changed, unrelated]
    case "owner": changed.pid = 43; roots = [changed, changed, unrelated]
    case "order": roots = [unrelated, node, node]
    default: break
    }
    #expect(throws: (any Error).self) {
      _ = try selection.validateFresh(make(roots, complete: change != "incomplete"), original: original)
    }
  }

  @Test(arguments: ["number", "nested-number", "conflict", "hidden-ancestor"])
  func aliasCertificateStillFailsClosed(change: String) throws {
    var node = TapAliasFixture()
    if change == "number" { node.AXValue = .number(1) }
    if change == "nested-number" { node.AXValue = .object(["value": .array([.number(1)])]) }
    var second = node
    if change == "conflict" { second.AXLabel = "Changed" }
    var roots = [node, second]
    if change == "hidden-ancestor" {
      var parent = text(); parent.nativeIdentity = .init(pid: 42, objectID: 300)
      parent.type = "Group"; parent.role = "AXGroup"; parent.hidden = true; parent.children = [second]
      roots = [node, parent]
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXAliasTapSelection.select(in: make(roots), selector: selector, expectedPID: 42)
    }
  }

  @Test(arguments: ["StaticText", "Button"])
  func exactParentHitAllowsOnlyContainedChildKeyRename(childType: String) throws {
    var child = text(); child.type = childType; child.role = "AX" + childType
    var parent = TapAliasFixture(); parent.children = [child]
    let original = try make([parent, parent])
    let selection = try #require(try FBAXAliasTapSelection.select(in: original, selector: selector, expectedPID: 42))
    var changed = child; changed.nativeIdentity = .init(pid: 42, objectID: UInt64.max)
    var freshParent = parent; freshParent.children = [changed]
    let fresh = try make([freshParent, freshParent])
    let index = try selection.currentIndex(in: fresh)
    try selection.validateDirectFresh(fresh, original: original, index: index)
    #expect(try selection.match(pointRoots: [freshParent.node()], hitPID: 42, point: point, index: index)
      == "consistentAliasDirect")
    #expect(throws: (any Error).self) { _ = try selection.validateFresh(fresh, original: original) }
    // The renamed child never gains direct authority or a relaxed descendant route.
    if childType == "Button" {
      #expect(throws: (any Error).self) {
        _ = try selection.match(pointRoots: [changed.node()], hitPID: 42, point: point, index: index)
      }
    } else {
      #expect(try selection.match(pointRoots: [changed.node()], hitPID: 42, point: point, index: index)
        == "consistentAliasButtonDescendant")
      #expect(throws: (any Error).self) { _ = try selection.validateFresh(fresh, original: original) }
    }
  }

  @Test(arguments: ["child-value", "child-label", "child-type", "child-frame", "child-hidden", "child-disabled",
    "child-actions", "child-order", "child-number", "child-container", "parent-key", "parent-value", "ancestor-path", "outside-key", "outside-value"])
  func directParentKeepsTypedTreeOrderOwnershipAndOutsideKeys(change: String) throws {
    let child = text()
    var second = child; second.nativeIdentity = .init(pid: 42, objectID: 201); second.AXLabel = "Second"
    var parent = TapAliasFixture(); parent.children = [child, second]
    var outside = text(); outside.nativeIdentity = .init(pid: 42, objectID: 300)
    let original = try make([parent, parent, outside])
    let selection = try #require(try FBAXAliasTapSelection.select(in: original, selector: selector, expectedPID: 42))
    var changed = parent
    switch change {
    case "child-value": changed.children[0].AXValue = .string("changed")
    case "child-label": changed.children[0].AXLabel = "changed"
    case "child-type": changed.children[0].type = "Group"
    case "child-frame": changed.children[0].frame.x += 1
    case "child-hidden": changed.children[0].hidden = true
    case "child-disabled": changed.children[0].enabled = false
    case "child-actions": changed.children[0].custom_actions = ["Changed"]
    case "child-order": changed.children.reverse()
    case "child-number": changed.children[0].AXValue = .number(1)
    case "child-container": changed.children[0].AXValue = .array([.string("value")])
    case "parent-key": changed.nativeIdentity = .init(pid: 42, objectID: 999)
    case "parent-value": changed.AXValue = .string("changed")
    case "outside-key": outside.nativeIdentity = .init(pid: 42, objectID: 301)
    case "outside-value": outside.AXValue = .string("changed")
    default: break
    }
    var roots = [changed, changed, outside]
    if change == "ancestor-path" {
      var group = outside; group.type = "Group"; group.role = "AXGroup"; group.children = [changed, changed]
      roots = [group]
    }
    let fresh = try make(roots)
    #expect(throws: (any Error).self) {
      let index = try selection.currentIndex(in: fresh)
      try selection.validateDirectFresh(fresh, original: original, index: index)
    }
  }

  @Test(arguments: ["old-key-outside", "new-key-outside", "split", "merge", "foreign-child-owner"])
  func descendantRenamesCannotCrossBoundaryOrChangeAliasPartition(change: String) throws {
    var child = text()
    if change == "foreign-child-owner" { child.pid = 43; child.nativeIdentity = .init(pid: 43, objectID: 200) }
    var parent = TapAliasFixture(); parent.children = [child]
    var outside = text(); outside.nativeIdentity = .init(pid: 42, objectID: 300)
    if change == "old-key-outside" { outside = child }
    if change == "new-key-outside" { outside.nativeIdentity = .init(pid: 42, objectID: 201) }
    if change == "split" { parent.children = [child, child] }
    if change == "merge" {
      var other = child; other.nativeIdentity = .init(pid: 42, objectID: 201)
      parent.children = [child, other]
    }
    let original = try make([parent, parent, outside])
    let selection = try #require(try FBAXAliasTapSelection.select(in: original, selector: selector, expectedPID: 42))
    var changed = parent
    for index in changed.children.indices {
      let key: UInt64 = change == "merge" ? 202 : (change == "split" ? 201 + UInt64(index) : 201)
      changed.children[index].nativeIdentity = .init(pid: changed.children[index].pid, objectID: key)
    }
    let fresh = try make([changed, changed, outside])
    #expect(throws: (any Error).self) {
      let index = try selection.currentIndex(in: fresh)
      try selection.validateDirectFresh(fresh, original: original, index: index)
    }
  }

  @Test(arguments: ["key", "value", "label", "frame", "owner", "actions"])
  func directConfirmationStillRequiresExactSelectedParent(change: String) throws {
    let parent = TapAliasFixture()
    let original = try make([parent, parent])
    let selection = try #require(try FBAXAliasTapSelection.select(in: original, selector: selector, expectedPID: 42))
    let index = try selection.currentIndex(in: original)
    #expect(try selection.match(pointRoots: [parent.node()], hitPID: 42, point: point, index: index) == "consistentAliasDirect")
    var changed = parent
    switch change {
    case "key": changed.nativeIdentity = .init(pid: 42, objectID: 999)
    case "value": changed.AXValue = .string("changed")
    case "label": changed.AXLabel = "changed"
    case "frame": changed.frame.x += 1
    case "owner": changed.pid = 43; changed.nativeIdentity = .init(pid: 43, objectID: 100)
    default: changed.custom_actions = ["Changed"]
    }
    #expect(throws: (any Error).self) {
      _ = try selection.match(pointRoots: [changed.node()], hitPID: change == "owner" ? 43 : 42, point: point, index: index)
    }
  }

  private let point = CGPoint(x: 50, y: 30)
  private var selector: FBSimulatorAXSelector { .nativeObject(identity: .init(pid: 42, objectID: 100), elementType: "Button") }
  private func text() -> TapAliasFixture {
    var node = TapAliasFixture(); node.type = "StaticText"; node.role = "AXStaticText"
    node.nativeIdentity = .init(pid: 42, objectID: 200)
    node.frame = .init(x: 10, y: 10, width: 80, height: 40)
    return node
  }
  private func make(_ roots: [TapAliasFixture], complete: Bool = true) throws -> FBSimulatorAXSnapshot {
    let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "00000000-0000-0000-0000-000000000001",
      bootIdentity: "test-boot", screenID: 1, screenUniqueID: "DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0", axDisplayID: 1,
      displayContext: FBSimulatorHIDDisplayContext(hidTarget: 1,
        nativePixelSize: CGSize(width: 1200, height: 2400), scale: 3, rotation: .rot0), poseRevision: "rigid")
    return try FBSimulatorAXSnapshot(observation: observation, jsonData: JSONEncoder().encode(roots),
      nativeIdentityMetadata: .init(complete: complete))
  }
}

private struct TapAliasFixture: Encodable {
  var type = "Button", role = "AXButton"
  var AXLabel: String? = "Repeated", AXValue: FBSimulatorAXValue? = .string("")
  var pid: Int32 = 42
  var nativeIdentity: FBSimulatorAXNativeIdentity? = .init(pid: 42, objectID: 100)
  var focused = false, enabled = true, hidden = false
  var custom_actions: [String] = []
  var frame = TapAliasFrame(x: 0, y: 0, width: 100, height: 60)
  var children: [TapAliasFixture] = []
  var key: FBSimulatorAXNativeIdentity { nativeIdentity! }
  func node() throws -> FBSimulatorAXNode { try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(self)) }
}
private struct TapAliasFrame: Encodable { var x: Double, y: Double, width: Double, height: Double }
