import AppKit
import FBControlCore
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Read-only custom action names")
struct FBSimulatorAXCustomActionMetadataTests {
  private func node(_ json: String) throws -> FBSimulatorAXNode {
    try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(json.utf8))
  }

  @Test func exactNamesRoundTripWithOrderDuplicatesAndChildren() throws {
    let original = try node(#"{"type":"Group","custom_actions":["Open","Éditer","Open"," ",""],"children":[{"custom_actions":["移動"]}]}"#)
    #expect(original.customActionNames == ["Open", "Éditer", "Open", " ", ""])
    let restored = try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(original))
    #expect(restored.customActionNames == original.customActionNames)
    #expect(restored.children.first?.customActionNames == ["移動"])
    #expect(restored.type == "Group")
  }

  @Test(arguments: [#"{}"#, #"{"custom_actions":null}"#, #"{"custom_actions":[]}"#])
  func absentOrEmptyNamesDoNotAddAnEncodedKey(json: String) throws {
    let original = try node(json)
    #expect(original.customActionNames.isEmpty)
    let encoded = try JSONDecoder().decode([String: FBSimulatorAXValue].self,
      from: JSONEncoder().encode(original))
    #expect(encoded["custom_actions"] == nil)
    #expect(Set(encoded.keys) == ["children"])
  }

  @Test(arguments: [#"true"#, #"42"#, #""Open""#, #"["Open",null]"#, #"[{}]"#])
  func malformedNamesRefuseRatherThanInventAName(value: String) {
    #expect(throws: (any Error).self) { _ = try node("{\"custom_actions\":\(value)}") }
  }

  @Test func selectedKeyAdditionPreservesLegacyOptionDefaults() {
    let previous: Set<FBAXKeys> = [.label, .value, .uniqueID, .type, .frameDict, .pid, .isRemote,
      .focused, .enabled, .hidden, .role, .roleDescription, .subrole]
    #expect(FBSimulatorAXWorker.snapshotKeys == previous.union([.customActions]))
    #expect(FBAccessibilityRequestOptions().keys == FBAXKeys.defaultSet)
    #expect(FBAXKeys.defaultSet.contains(.customActions))
    #expect(FBAXKeys.customActions.rawValue == "custom_actions")
  }

  @Test func anUnrequestedKeyDoesNotCallTheCustomActionGetter() throws {
    let element = MetadataElement()
    let rows = try serialize(element, keys: [.type])
    #expect(element.nameReads == 0 && element.actionCalls == 0)
    #expect(rows.first?["custom_actions"] == nil)
  }

  @Test func selectedAndLegacySerializationReadNamesWithoutPerformingActions() throws {
    for keys in [FBSimulatorAXWorker.snapshotKeys, FBAXKeys.defaultSet] {
      let element = MetadataElement()
      let rows = try serialize(element, keys: keys)
      #expect(rows.first?["custom_actions"] == .array([.string("Archive"), .string("Move")]))
      #expect(element.nameReads == 1 && element.actionCalls == 0)
      let data = try JSONEncoder().encode(rows.first)
      let selected = try JSONDecoder().decode(FBSimulatorAXNode.self, from: data)
      #expect(selected.customActionNames == ["Archive", "Move"])
    }
  }

  @Test func namesDoNotChangeExistingSemanticSelection() throws {
    let original = try node(#"{"type":"Group","AXUniqueId":"row","AXLabel":"Row","pid":42,"custom_actions":["Delete"]}"#)
    let changed = try node(#"{"type":"Group","AXUniqueId":"row","AXLabel":"Row","pid":42,"custom_actions":["Archive"]}"#)
    #expect(FBSimulatorAXSelector.identifier("row").matches(original))
    #expect(FBSimulatorAXSelector.identifier("row").matches(changed))
    #expect(FBSimulatorAXSelector.label("Row").matches(changed))
    #expect(original.type == "Group" && changed.type == "Group")
  }

  private func serialize(_ element: MetadataElement, keys: Set<FBAXKeys>) throws -> [[String: FBSimulatorAXValue]] {
    let raw = try FBSimulatorAccessibilitySerializer.recursiveDescription(fromElement: element,
      token: "metadata-only", nestedFormat: true, keys: keys, collector: nil,
      coverageGrid: nil, seenPids: nil)
    return try JSONDecoder().decode([[String: FBSimulatorAXValue]].self,
      from: JSONSerialization.data(withJSONObject: raw))
  }

  private final class MetadataElement: FBAXPlatformElement {
    var nameReads = 0
    var actionCalls = 0
    func axCustomActionNames() -> [String] { nameReads += 1; return ["Archive", "Move"] }
    func axActionNames() -> [String] { actionCalls += 1; return [] }
    func axPerformPress() -> Bool { actionCalls += 1; return false }
    func axScroll(_ direction: FBAccessibilityScrollDirection) { actionCalls += 1 }
    func axSetValue(_ value: Any?) { actionCalls += 1 }
    func axFrame() -> NSRect { NSRect(x: 10, y: 20, width: 100, height: 30) }
    func axRole() -> String? { "AXGroup" }
    func axLabel() -> String? { "Row" }
    func axValue() -> Any? { nil }
    func axIdentifier() -> String? { "row" }
    func axTitle() -> String? { nil }
    func axHelp() -> String? { nil }
    func axRoleDescription() -> String? { nil }
    func axSubrole() -> String? { nil }
    func axPlaceholderValue() -> String? { nil }
    func axIsEnabled() -> Bool { true }
    func axIsRequired() -> Bool { false }
    func axIsExpanded() -> Bool { false }
    func axIsHidden() -> Bool { false }
    func axIsFocused() -> Bool { false }
    func axTraits() -> [String]? { nil }
    func axChildren() -> [FBAXPlatformElement] { [] }
    var axTranslationPid: pid_t { 42 }
    func axSetBridgeDelegateToken(_ token: String?) {}
  }
}
