import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Native identity input admission")
struct FBSimulatorAXNativeIdentityAdmissionTests {
  @Test func exactDirectPointKeepsItsOpaqueKey() throws {
    let fixture = NativeIdentityFixture()
    let node = try fixture.node()
    let hit = try FBAXTargetValidationRules.hit([node], expected: node,
      selector: .nativeObject(identity: fixture.key, elementType: "Button"), expectedPID: 42, hitPID: 42,
      point: CGPoint(x: 50, y: 30))
    #expect(hit.nativeIdentity == fixture.key)
    try FBAXTargetValidationRules.opaqueTarget(node, expectedPID: 42, context: nativeIdentityObservation().displayContext)
  }

  @Test(arguments: ["key", "pid", "type", "role", "subrole", "description", "label", "value", "frame",
    "hidden", "disabled", "unknown-enabled", "unknown-hidden", "focus"])
  func directPointCannotSelectAnObjectWithSimilarAppearance(change: String) throws {
    let original = NativeIdentityFixture()
    var changed = original
    switch change {
    case "key": changed.nativeIdentity = .init(pid: 42, objectID: 2)
    case "pid": changed.pid = 99
    case "type": changed.type = "Group"
    case "role": changed.role = "AXGroup"
    case "subrole": changed.subrole = "other"
    case "description": changed.role_description = "other"
    case "label": changed.AXLabel = "other"
    case "value": changed.AXValue = "1"
    case "frame": changed.frame.x += 1
    case "hidden": changed.hidden = true
    case "disabled": changed.enabled = false
    case "unknown-enabled": changed.enabled = nil
    case "unknown-hidden": changed.hidden = nil
    default: changed.focused = true
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.hit([changed.node()], expected: original.node(),
        selector: .nativeObject(identity: original.key, elementType: "Button"), expectedPID: 42, hitPID: 42,
        point: CGPoint(x: 50, y: 30))
    }
  }

  @Test(arguments: ["negative-width", "negative-height", "zero-width", "outside", "disabled", "hidden", "pid"])
  func opaqueTargetMustBeCurrentVisibleAndInsideSelectedDisplay(change: String) throws {
    var fixture = NativeIdentityFixture()
    switch change {
    case "negative-width": fixture.frame.width = -100
    case "negative-height": fixture.frame.height = -30
    case "zero-width": fixture.frame.width = 0
    case "outside": fixture.frame.x = 390
    case "disabled": fixture.enabled = false
    case "hidden": fixture.hidden = true
    default: fixture.pid = 99
    }
    #expect(throws: (any Error).self) {
      try FBAXTargetValidationRules.opaqueTarget(fixture.node(), expectedPID: 42,
        context: nativeIdentityObservation().displayContext)
    }
  }

  @Test func hiddenAncestorCannotAuthorizeOpaqueChild() throws {
    let child = NativeIdentityFixture()
    var parent = child; parent.type = "Group"; parent.role = "AXGroup"
    parent.nativeIdentity = .init(pid: 42, objectID: 2); parent.children = [child]; parent.hidden = true
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: [parent.node()], identity: child.key, elementType: "Button")
    }
  }

  @Test func buttonDescendantNeedsExactFreshIdentityAndUniqueChild() throws {
    var parent = NativeIdentityFixture()
    var child = NativeIdentityFixture(); child.nativeIdentity = .init(pid: 42, objectID: 2)
    child.type = "StaticText"; child.role = "AXStaticText"; child.AXUniqueId = nil
    parent.children = [child]
    let selector = FBSimulatorAXSelector.nativeObject(identity: parent.key, elementType: "Button")
    let target = try FBAXTargetValidationRules.descendantHit([child.node()], freshRoots: [parent.node()],
      expected: parent.node(), selector: selector, expectedPID: 42, hitPID: 42, point: CGPoint(x: 50, y: 30))
    #expect(target.nativeIdentity == parent.key)
    var replacement = child; replacement.nativeIdentity = .init(pid: 42, objectID: 3)
    #expect(!FBAXTargetValidationRules.sameOpaqueNode(try child.node(), try replacement.node()))
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.descendantHit([replacement.node()], freshRoots: [parent.node()],
        expected: parent.node(), selector: selector, expectedPID: 42, hitPID: 42, point: CGPoint(x: 50, y: 30))
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.descendantHit([child.node()], freshRoots: [parent.node(), child.node()],
        expected: parent.node(), selector: selector, expectedPID: 42, hitPID: 42, point: CGPoint(x: 50, y: 30))
    }
    var group = parent; group.type = "Group"; group.role = "AXGroup"
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.descendantHit([child.node()], freshRoots: [group.node()],
        expected: group.node(), selector: .nativeObject(identity: group.key, elementType: "Group"),
        expectedPID: 42, hitPID: 42, point: CGPoint(x: 50, y: 30))
    }
  }

  @Test func checkboxChildRelationshipPinsBothOpaqueObjects() throws {
    var parent = NativeIdentityFixture(); parent.type = "CheckBox"; parent.role = "AXCheckBox"
    parent.AXUniqueId = nil; parent.AXValue = "1"
    var child = parent; child.nativeIdentity = .init(pid: 42, objectID: 2)
    child.AXLabel = nil; child.frame = .init(x: 50, y: 20, width: 50, height: 30)
    parent.children = [child]
    let native = try [parent.node()]
    let selector = FBSimulatorAXSelector.nativeObject(identity: parent.key, elementType: "CheckBox")
    let context = try nativeIdentityObservation().displayContext
    let candidate = try FBAXCheckBoxChildSelection.select(in: native, parent: native[0], selector: selector,
      expectedPID: 42, context: context)
    let selected = try #require(candidate)
    #expect(try selected.validate(in: native, hitRoots: [child.node()], selector: selector,
      expectedPID: 42, hitPID: 42, context: context).nativeIdentity == parent.key)
    #expect(try selected.validate(in: native, hitRoots: native, selector: selector,
      expectedPID: 42, hitPID: 42, context: context).nativeIdentity == parent.key)
    var changed = child; changed.nativeIdentity = .init(pid: 42, objectID: 3)
    #expect(throws: (any Error).self) {
      _ = try selected.validate(in: native, hitRoots: [changed.node()], selector: selector,
        expectedPID: 42, hitPID: 42, context: context)
    }
    #expect(throws: (any Error).self) {
      _ = try selected.validate(in: [parent.node(), child.node()], hitRoots: [child.node()], selector: selector,
        expectedPID: 42, hitPID: 42, context: context)
    }
  }
}

@Suite("Native identity focused keyboard read")
struct FBSimulatorAXNativeFocusedFieldTests {
  @Test func sameAnonymousFocusedFieldCanChangeValueWithoutSemanticID() throws {
    var field = fixture()
    var selection = FBAXFocusedNativeTextFieldSelection(identity: field.key)
    #expect(try selection.include(identity: field.key))
    try selection.validate(field.node(), expectedPID: 42, logicalSize: CGSize(width: 400, height: 800))
    field.AXValue = "typed value"
    try selection.validate(field.node(), expectedPID: 42, logicalSize: CGSize(width: 400, height: 800))
  }

  @Test func duplicateOpaqueKeysAreCountedBeforeFieldFiltering() throws {
    let field = fixture()
    var selection = FBAXFocusedNativeTextFieldSelection(identity: field.key)
    #expect(try selection.include(identity: nil) == false)
    #expect(try selection.include(identity: .init(pid: 99, objectID: field.key.objectID)) == false)
    #expect(try selection.include(identity: field.key))
    #expect(throws: FBSimulatorAXSnapshotError.self) { _ = try selection.include(identity: field.key) }
    #expect(throws: (any Error).self) {
      try selection.validate(field.node(), expectedPID: 42, logicalSize: CGSize(width: 400, height: 800))
    }
  }

  @Test(arguments: ["key", "pid", "identifier", "type", "role", "focus", "missing-focus", "hidden",
    "missing-hidden", "disabled", "missing-enabled", "negative-width", "negative-height", "zero-width", "outside"])
  func currentFocusedFieldCannotRelaxOwnerIdentityStateOrDisplayBounds(change: String) throws {
    let original = fixture()
    var field = original
    switch change {
    case "key": field.nativeIdentity = .init(pid: 42, objectID: 2)
    case "pid": field.pid = 99
    case "identifier": field.AXUniqueId = "materialized"
    case "type": field.type = "Group"
    case "role": field.role = "TextField"
    case "focus": field.focused = false
    case "missing-focus": field.focused = nil
    case "hidden": field.hidden = true
    case "missing-hidden": field.hidden = nil
    case "disabled": field.enabled = false
    case "missing-enabled": field.enabled = nil
    case "negative-width": field.frame.width = -100
    case "negative-height": field.frame.height = -30
    case "zero-width": field.frame.width = 0
    default: field.frame.y = 790
    }
    var selection = FBAXFocusedNativeTextFieldSelection(identity: original.key)
    _ = try selection.include(identity: original.key)
    #expect(throws: (any Error).self) {
      try selection.validate(field.node(), expectedPID: 42, logicalSize: CGSize(width: 400, height: 800))
    }
  }

  private func fixture() -> NativeIdentityFixture {
    var field = NativeIdentityFixture()
    field.type = "TextField"; field.role = "AXTextField"; field.AXUniqueId = nil; field.focused = true
    return field
  }
}
