import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Focused TextField typed identity")
struct FBSimulatorAXFocusedTextFieldTests {
  @Test func inheritedContainerIDsDoNotCountAsFields() throws {
    var selection = FBAXFocusedTextFieldSelection(identifier: "shared")
    for role in ["AXGroup", "AXButton", "AXStaticText", "AXScrollArea"] {
      #expect(try selection.include(identifier: "shared", role: role) == false)
    }
    #expect(try selection.include(identifier: "shared", role: "AXTextField"))
    #expect(selection.matchingCount == 1)
    try selection.validate(Field().node(), expectedPID: 42)
  }

  @Test(arguments: ["AXTextField", "TextField"])
  func typeAliasesMatchTheNativeSerializer(role: String) throws {
    var selection = FBAXFocusedTextFieldSelection(identifier: "shared")
    #expect(try selection.include(identifier: "shared", role: role))
    try selection.validate(Field().node(), expectedPID: 42)
  }

  @Test(arguments: ["AXSearchField", "AXTextArea", "AXTextView", "AXSecureTextField", "AXAXTextField", "textField"])
  func otherRawRolesDoNotExpandKeyboardAdmission(role: String) throws {
    var selection = FBAXFocusedTextFieldSelection(identifier: "shared")
    #expect(try selection.include(identifier: "shared", role: role) == false)
    #expect(selection.matchingCount == 0)
    #expect(throws: FBSimulatorAXTargetError.self) {
      try selection.validate(Field().node(), expectedPID: 42)
    }
  }

  @Test func aSecondTextFieldIsAmbiguousBeforeFocusOrStateFiltering() throws {
    for variant in ["unfocused", "hidden", "disabled", "foreign-process"] {
      var duplicate = Field()
      switch variant {
      case "unfocused": duplicate.focused = false
      case "hidden": duplicate.hidden = true
      case "disabled": duplicate.enabled = false
      default: duplicate.pid = 99
      }
      var selection = FBAXFocusedTextFieldSelection(identifier: "shared")
      #expect(try selection.include(identifier: "shared", role: "AXTextField"))
      let second = try duplicate.node()
      do {
        _ = try selection.include(identifier: second.identifier, role: "AXTextField")
        Issue.record("A duplicate field was accepted after filtering its state.")
      } catch FBSimulatorAXSnapshotError.ambiguous(let count) {
        #expect(count == 2)
      }
      #expect(throws: FBSimulatorAXTargetError.self) {
        try selection.validate(Field().node(), expectedPID: 42)
      }
    }
  }

  @Test func identifiersAreExactAndUnrelatedFieldsDoNotCount() throws {
    var selection = FBAXFocusedTextFieldSelection(identifier: "shared")
    for identifier in ["shared-extra", " shared", "shared ", "other"] {
      #expect(try selection.include(identifier: identifier, role: "AXTextField") == false)
    }
    #expect(try selection.include(identifier: nil, role: "AXTextField") == false)
    #expect(try selection.include(identifier: "shared", role: nil) == false)
    #expect(selection.matchingCount == 0)
    #expect(try selection.include(identifier: "shared", role: "TextField"))
    try selection.validate(Field().node(), expectedPID: 42)
  }

  @Test func finalSerializedFieldKeepsAllOriginalSafetyChecks() throws {
    var selection = FBAXFocusedTextFieldSelection(identifier: "shared")
    _ = try selection.include(identifier: "shared", role: "AXTextField")
    var invalid: [Field] = []
    var field = Field(); field.focused = false; invalid.append(field)
    field = Field(); field.focused = nil; invalid.append(field)
    field = Field(); field.enabled = false; invalid.append(field)
    field = Field(); field.enabled = nil; invalid.append(field)
    field = Field(); field.hidden = true; invalid.append(field)
    field = Field(); field.hidden = nil; invalid.append(field)
    field = Field(); field.pid = 99; invalid.append(field)
    field = Field(); field.type = "Group"; invalid.append(field)
    field = Field(); field.AXUniqueId = "other"; invalid.append(field)
    field = Field(); field.frame = nil; invalid.append(field)
    field = Field(); field.frame?.width = 0; invalid.append(field)
    field = Field(); field.frame?.height = 0; invalid.append(field)
    for field in invalid {
      #expect(throws: FBSimulatorAXTargetError.self) {
        try selection.validate(field.node(), expectedPID: 42)
      }
    }
    #expect(throws: FBSimulatorAXTargetError.self) {
      try selection.validate(Field().node(), expectedPID: 0)
    }
  }

  private struct Field: Encodable {
    struct Frame: Encodable {
      var x = 10.0
      var y = 10.0
      var width = 100.0
      var height = 40.0
    }
    var type = "TextField"
    var AXUniqueId = "shared"
    var pid: Int32 = 42
    var focused: Bool? = true
    var enabled: Bool? = true
    var hidden: Bool? = false
    var frame: Frame? = Frame()
    func node() throws -> FBSimulatorAXNode {
      try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(self))
    }
  }
}
