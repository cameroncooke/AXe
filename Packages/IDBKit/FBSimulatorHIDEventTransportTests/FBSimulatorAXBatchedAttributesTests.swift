import AppKit
import FBControlCore
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Batched accessibility attribute reads")
struct FBSimulatorAXBatchedAttributesTests {
  private static let keys: Set<FBAXKeys> = [.label, .frame, .value, .uniqueID, .type, .title, .frameDict, .help,
    .enabled, .customActions, .role, .roleDescription, .subrole, .contentRequired, .pid, .traits, .expanded,
    .placeholder, .hidden, .focused]

  @Test(arguments: [true, false])
  func batchedOutputMatchesIndividualReads(nested: Bool) throws {
    let individual = try serialize(tree(batched: false), nested: nested)
    let root = tree(batched: true)
    let batched = try serialize(root, nested: nested)
    #expect(batched == individual)
    // Only custom action names keep their own read; children arrive with the attributes.
    for element in [root] + root.descendants {
      #expect(element.individualReads.keys.sorted() == ["customActions"])
    }
  }

  @Test func identityWalkUsesBatchedChildrenAndKeepsCompleteness() throws {
    let root = tree(batched: true)
    let collector = FBAXNativeIdentityCollector()
    let batched = try serialize(root, identities: collector)
    #expect(collector.metadata == .init(complete: true))
    let individualCollector = FBAXNativeIdentityCollector()
    #expect(batched == (try serialize(tree(batched: false), identities: individualCollector)))
    #expect(individualCollector.metadata == .init(complete: true))
    for element in [root] + root.descendants { #expect(element.individualReads["nativeChildren"] == nil) }
  }

  @Test func unsupportedBatchedChildMarksIdentityIncomplete() throws {
    let root = tree(batched: true)
    root.extraBatchedChild = NSObject()
    let collector = FBAXNativeIdentityCollector()
    _ = try serialize(root, identities: collector)
    #expect(collector.metadata == .init(complete: false, reason: "unsupportedChildType"))
  }

  enum Gap: CaseIterable, Sendable { case frame, children, labelType, flagType, traitsType }

  @Test("A missing or unexpected batched value falls back to the accessor", arguments: Gap.allCases)
  func gapsFallBackToAccessors(gap: Gap) throws {
    let individual = try serialize(tree(batched: false))
    let root = tree(batched: true)
    root.gap = gap
    #expect(try serialize(root) == individual)
    let expected: String
    switch gap {
    case .frame: expected = "frame"
    case .children: expected = "children"
    case .labelType: expected = "label"
    case .flagType: expected = "enabled"
    case .traitsType: expected = "traits"
    }
    #expect(root.individualReads[expected] != nil)
  }

  private func tree(batched: Bool) -> BatchElement {
    let field = BatchElement(batched: batched, objectID: 3, role: "AXTextField", label: "Name", value: "Ada",
      identifier: "name", focused: true, traits: 0)
    let button = BatchElement(batched: batched, objectID: 2, role: "AXButton", label: "Save", identifier: "save",
      customActions: ["Delete"], traits: 1)
    return BatchElement(batched: batched, objectID: 1, role: "AXApplication", label: "App", children: [button, field])
  }

  private func serialize(_ root: BatchElement, nested: Bool = true,
    identities: FBAXNativeIdentityCollector? = nil) throws -> FBSimulatorAXValue {
    let values: [[String: Any]]
    if let identities {
      values = try FBSimulatorAccessibilitySerializer.recursiveDescription(fromElement: root, token: "read",
        nestedFormat: nested, keys: Self.keys, collector: nil, coverageGrid: nil, seenPids: nil,
        nativeIdentity: identities)
    } else {
      values = try FBSimulatorAccessibilitySerializer.recursiveDescription(fromElement: root, token: "read",
        nestedFormat: nested, keys: Self.keys, collector: nil, coverageGrid: nil, seenPids: nil)
    }
    return try JSONDecoder().decode(FBSimulatorAXValue.self, from: JSONSerialization.data(withJSONObject: values))
  }

  /// Answers batched requests the way `accessibilityMultipleAttributes:` does: nil values are omitted.
  private final class BatchElement: FBAXPlatformElement {
    let batched: Bool
    let objectID: UInt64
    let role: String
    let label: String?
    let value: Any?
    let identifier: String?
    let focused: Bool
    let customActions: [String]
    let traits: UInt64
    let children: [BatchElement]
    var gap: Gap?
    var extraBatchedChild: AnyObject?
    var individualReads: [String: Int] = [:]

    init(batched: Bool, objectID: UInt64, role: String, label: String?, value: Any? = nil,
      identifier: String? = nil, focused: Bool = false, customActions: [String] = [], traits: UInt64 = 0,
      children: [BatchElement] = []) {
      self.batched = batched; self.objectID = objectID; self.role = role; self.label = label; self.value = value
      self.identifier = identifier; self.focused = focused; self.customActions = customActions; self.traits = traits
      self.children = children
    }

    var descendants: [BatchElement] { children.flatMap { [$0] + $0.descendants } }
    private var frame: NSRect { NSRect(x: 10, y: Double(objectID) * 40, width: 100, height: 30) }
    private func read(_ name: String) { individualReads[name, default: 0] += 1 }

    func axBatchedAttributes(_ names: [String]) -> [String: Any]? {
      guard batched else { return nil }
      var all: [String: Any] = ["AXFrame": NSValue(rect: frame), "AXRole": role, "AXEnabled": NSNumber(value: true),
        "AXRoleDescription": role.lowercased(), "AXTraits": NSNumber(value: traits),
        "AXChildren": children + (extraBatchedChild.map { [$0] } ?? [])]
      if let label { all["AXDescription"] = label }
      if let value { all["AXValue"] = value }
      if let identifier { all["AXIdentifier"] = identifier }
      if focused { all["AXFocused"] = NSNumber(value: true) }
      switch gap {
      case .frame: all["AXFrame"] = nil
      case .children: all["AXChildren"] = nil
      case .labelType: all["AXDescription"] = NSNumber(value: 7)
      case .flagType: all["AXEnabled"] = "yes"
      case .traitsType: all["AXTraits"] = "button"
      case nil: break
      }
      return all.filter { names.contains($0.key) }
    }

    func axFrame() -> NSRect { read("frame"); return frame }
    func axRole() -> String? { read("role"); return role }
    func axLabel() -> String? { read("label"); return label }
    func axValue() -> Any? { read("value"); return value }
    func axIdentifier() -> String? { read("identifier"); return identifier }
    func axTitle() -> String? { read("title"); return nil }
    func axHelp() -> String? { read("help"); return nil }
    func axRoleDescription() -> String? { read("roleDescription"); return role.lowercased() }
    func axSubrole() -> String? { read("subrole"); return nil }
    func axPlaceholderValue() -> String? { read("placeholder"); return nil }
    func axIsEnabled() -> Bool { read("enabled"); return true }
    func axIsRequired() -> Bool { read("required"); return false }
    func axIsExpanded() -> Bool { read("expanded"); return false }
    func axIsHidden() -> Bool { read("hidden"); return false }
    func axIsFocused() -> Bool { read("focused"); return focused }
    func axCustomActionNames() -> [String] { read("customActions"); return customActions }
    func axActionNames() -> [String] { [] }
    func axTraits() -> [String]? { read("traits"); return Array(AXExtractTraits(traits)) }
    func axChildren() -> [FBAXPlatformElement] { read("children"); return children }
    func axNativeIdentity() -> FBSimulatorAXNativeIdentity? { .init(pid: 42, objectID: objectID) }
    func axNativeIdentityChildren() -> FBAXNativeIdentityChildren { read("nativeChildren"); return .init(elements: children, reason: nil) }
    func axPerformPress() -> Bool { false }
    func axScroll(_ direction: FBAccessibilityScrollDirection) {}
    func axSetValue(_ value: Any?) {}
    var axTranslationPid: pid_t { 42 }
    func axSetBridgeDelegateToken(_ token: String?) {}
  }
}
