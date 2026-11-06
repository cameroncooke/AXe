import AppKit
import CoreGraphics
import FBControlCore
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Selected slider exact label")
struct FBSimulatorSliderLabelTests {
  private struct Frame: Encodable { var x = 10.0; var y = 20.0; var width = 100.0; var height = 30.0 }
  private struct Node: Encodable {
    var AXLabel: String? = "Horizontal value"
    var AXUniqueId: String? = nil
    var type = "Slider"
    var pid: Int32 = 42
    var frame = Frame()
    var children: [Node] = []
  }
  private func node(_ value: Node = Node()) throws -> FBSimulatorAXNode {
    try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(value))
  }
  private func resolve(_ roots: [FBSimulatorAXNode], query: String = "Horizontal value", type: String? = nil) throws -> FBSimulatorAXNode {
    try FBSimulatorSliderTargetSelection.resolve(roots: roots, selection: .label(query), expectedPID: 42, elementType: type)
  }

  @Test(arguments: [nil, "target"] as [String?], [nil, "Slider"] as [String?])
  func uniqueLabelSupportsSliderWithOrWithoutID(identifier: String?, type: String?) throws {
    let prefix = try node(Node(AXLabel: "Horizontal value suffix", AXUniqueId: "prefix"))
    let actual = try resolve([prefix, node(Node(AXUniqueId: identifier))], type: type)
    #expect(actual.identifier == identifier && actual.label == "Horizontal value" && actual.pid == 42)
  }

  @Test(arguments: ["Horizontal", "horizontal value", "Horizontal value suffix", "", " "])
  func absentOrPartialLabelRejects(query: String) throws {
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([node()], query: query) }
  }

  @Test(arguments: ["Button", "Slider"])
  func duplicateLabelsRejectBeforeTypeFilter(otherType: String) throws {
    let nodes = try [node(), node(Node(AXUniqueId: "other", type: otherType))]
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve(nodes, type: "Slider") }
  }

  @Test(arguments: [" Horizontal value ", "\nHorizontal value\t", "\u{00a0}Horizontal value\u{00a0}"])
  func nativeAndSnapshotLabelPredicatesAgree(label: String) throws {
    let actual = try node(Node(AXLabel: label))
    #expect(FBSimulatorAXSelector.matchesLabel(label, query: "Horizontal value"))
    #expect(FBSimulatorAXSelector.label("Horizontal value").matches(actual))
    #expect(try resolve([actual]).label == label)
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([actual, node()]) }
  }

  @Test(arguments: ["label", "role", "pid", "width", "height"])
  func freshHandleChangesCannotPassTheSameSelector(change: String) throws {
    _ = try resolve([node()], type: "Slider")
    var changed = Node()
    switch change {
    case "label": changed.AXLabel = "Other"
    case "role": changed.type = "Button"
    case "pid": changed.pid = 43
    case "width": changed.frame.width = 0
    default: changed.frame.height = -1
    }
    #expect(throws: FBSimulatorSliderError.self) {
      _ = try FBSimulatorSliderTargetSelection.ownedRoot(roots: [node(changed)],
        selection: .label("Horizontal value"), expectedPID: 42, elementType: "Slider")
    }
  }

  @Test(arguments: ["Button", "slider", " Slider "])
  func optionalTypeCannotBroadenNativeSliderRole(type: String) throws {
    #expect(throws: FBSimulatorSliderError.self) { _ = try resolve([node()], type: type) }
  }

  private func selection(_ kind: String) -> FBSimulatorSliderSelection {
    kind == "id" ? .identifier("target") : .label("Horizontal value")
  }

  @Test(arguments: ["id", "label"])
  func matchingChildCannotReplaceChangedOwnedRoot(kind: String) throws {
    let child = Node(AXUniqueId: kind == "id" ? "target" : nil)
    var parent = child
    if kind == "id" { parent.AXUniqueId = "changed" }
    else { parent.AXLabel = "Changed label" }
    parent.children = [child]
    let roots = try [node(parent)]
    // App-tree lookup can find the child. That result must not validate a handle to its parent.
    let treeMatch = try FBSimulatorSliderTargetSelection.resolve(roots: roots,
      selection: selection(kind), expectedPID: 42, elementType: "Slider")
    #expect(treeMatch.label == child.AXLabel && treeMatch.identifier == child.AXUniqueId)
    #expect(throws: FBSimulatorSliderError.self) {
      _ = try FBSimulatorSliderTargetSelection.ownedRoot(roots: roots,
        selection: selection(kind), expectedPID: 42, elementType: "Slider")
    }
  }

  @Test(arguments: ["id", "label"], [nil, "Slider"] as [String?])
  func actualOwnedRootRemainsValid(kind: String, type: String?) throws {
    var root = Node(AXUniqueId: kind == "id" ? "target" : nil)
    root.children = [Node(AXLabel: "Other", AXUniqueId: "other", type: "StaticText")]
    let actual = try FBSimulatorSliderTargetSelection.ownedRoot(roots: [node(root)],
      selection: selection(kind), expectedPID: 42, elementType: type)
    #expect(actual.label == root.AXLabel && actual.identifier == root.AXUniqueId)
    #expect(actual.pid == 42 && actual.type == "Slider" && actual.children.count == 1)
  }

  @Test(arguments: ["id", "label"], ["empty", "multiple", "duplicate"])
  func malformedOwnedRootOrDuplicateSelectorRejects(kind: String, shape: String) throws {
    var root = Node(AXUniqueId: kind == "id" ? "target" : nil)
    let roots: [FBSimulatorAXNode]
    switch shape {
    case "empty": roots = []
    case "multiple": roots = try [node(root), node(Node(AXLabel: "Other", AXUniqueId: "other"))]
    default:
      root.children = [root]
      roots = try [node(root)]
    }
    #expect(throws: FBSimulatorSliderError.self) {
      _ = try FBSimulatorSliderTargetSelection.ownedRoot(roots: roots,
        selection: selection(kind), expectedPID: 42, elementType: "Slider")
    }
  }
}

@Suite("Selected slider owned handle search")
struct FBSimulatorSliderOwnedSearchTests {
  private final class Element: FBAXPlatformElement {
    let identifier: String?
    let label: String?
    let role: String
    let children: [Element]
    var onIdentifierRead: (() -> Void)?
    var onChildrenRead: (() -> Void)?
    private(set) var tokens: [String] = []
    private(set) var identifierReads = 0
    private(set) var labelReads = 0
    private(set) var roleReads = 0
    private(set) var childrenReads = 0
    private(set) var actionCalls = 0

    init(identifier: String? = nil, label: String? = nil, role: String = "AXSlider", children: [Element] = []) {
      self.identifier = identifier; self.label = label; self.role = role; self.children = children
    }

    func axIdentifier() -> String? { identifierReads += 1; onIdentifierRead?(); return identifier }
    func axLabel() -> String? { labelReads += 1; return label }
    func axRole() -> String? { roleReads += 1; return role }
    func axChildren() -> [FBAXPlatformElement] { childrenReads += 1; onChildrenRead?(); return children }
    func axSetBridgeDelegateToken(_ token: String?) { tokens.append(token ?? "<nil>") }
    var axTranslationPid: pid_t { 42 }
    func axFrame() -> NSRect { NSRect(x: 10, y: 20, width: 100, height: 30) }
    func axValue() -> Any? { nil }
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
    func axCustomActionNames() -> [String] { [] }
    func axActionNames() -> [String] { [] }
    func axTraits() -> [String]? { nil }
    func axPerformPress() -> Bool { actionCalls += 1; return false }
    func axScroll(_ direction: FBAccessibilityScrollDirection) { actionCalls += 1 }
    func axSetValue(_ value: Any?) { actionCalls += 1 }
  }

  private func search(_ root: Element, selection: FBSimulatorSliderSelection = .identifier("slider.unit"),
    depth: UInt = 64, deadline: Double? = nil) throws -> Element? {
    var found: FBAXPlatformElement?
    try FBAccessibilityElement.findSliderElement(matching: selection, in: root, token: "owned-search",
      remainingDepth: depth, deadline: deadline ?? ProcessInfo.processInfo.systemUptime + 30, found: &found)
    return found as? Element
  }

  private func waitUntilExpired(_ deadline: Double) {
    while ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime))
    }
  }

  private func expectDeadline(_ operation: () throws -> Void) {
    do { try operation(); Issue.record("Owned search returned after its deadline") }
    catch FBSimulatorSliderError.deadline {}
    catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test func earlierStateLabelCannotReplaceExactSliderHandle() throws {
    let state = Element(identifier: "slider.unitState", label: "Unit value", role: "AXStaticText")
    let slider = Element(identifier: "slider.unit", label: "Unit range slider")
    let root = Element(role: "AXApplication", children: [state, slider])
    #expect(try search(root) === slider)
    #expect(root.tokens == ["owned-search"] && state.tokens == ["owned-search"] && slider.tokens == ["owned-search"])
    #expect(state.roleReads == 0 && slider.roleReads == 0)
    #expect(root.actionCalls == 0 && state.actionCalls == 0 && slider.actionCalls == 0)
  }

  @Test(arguments: [nil, "slider", "slider.unitState", "Slider.unit", "SLIDER.UNIT", " slider.unit", "slider.unit ", "\nslider.unit\t"] as [String?])
  func partialCaseChangedOrPaddedNativeIDDoesNotMatch(identifier: String?) throws {
    let candidate = Element(identifier: identifier)
    #expect(try search(Element(children: [candidate])) == nil)
    #expect(candidate.identifierReads == 1 && candidate.roleReads == 0 && candidate.actionCalls == 0)
  }

  @Test(arguments: ["slider", "Slider.unit", " slider.unit", "slider.unit "])
  func queryIDIsNotTrimmedOrMatchedAsSubstring(query: String) throws {
    let slider = Element(identifier: "slider.unit")
    #expect(try search(slider, selection: .identifier(query)) == nil)
    #expect(slider.identifierReads == 1 && slider.actionCalls == 0)
  }

  @Test(arguments: ["AXSlider", "AXButton", "AXStaticText"], ["sibling", "descendant"])
  func duplicateExactIDRejectsBeforeRoleFiltering(otherRole: String, placement: String) throws {
    let duplicate = Element(identifier: "slider.unit", role: otherRole)
    let first = Element(identifier: "slider.unit", children: placement == "descendant" ? [duplicate] : [])
    let root = Element(children: placement == "sibling" ? [first, duplicate] : [first])
    #expect(throws: FBSimulatorSliderError.self) { _ = try search(root) }
    #expect(first.tokens == ["owned-search"] && duplicate.tokens == ["owned-search"])
    #expect(first.roleReads == 0 && duplicate.roleReads == 0)
    #expect(first.actionCalls == 0 && duplicate.actionCalls == 0)
  }

  @Test(arguments: [" Unit range slider ", "\nUnit range slider\t", "\u{00a0}Unit range slider\u{00a0}"])
  func labelSelectorTrimsBothSidesAndKeepsTheExactHandle(label: String) throws {
    let prefix = Element(label: "Unit range slider state", role: "AXStaticText")
    let slider = Element(label: label)
    let root = Element(children: [prefix, slider])
    #expect(try search(root, selection: .label(" \nUnit range slider\t")) === slider)
    #expect(slider.labelReads == 1 && slider.identifierReads == 0 && slider.actionCalls == 0)
  }

  @Test(arguments: [nil, "Unit range", "unit range slider", "Unit range slider state", "", " "] as [String?])
  func absentPartialOrCaseChangedNativeLabelDoesNotMatch(label: String?) throws {
    let candidate = Element(label: label)
    #expect(try search(candidate, selection: .label("Unit range slider")) == nil)
    #expect(candidate.labelReads == 1 && candidate.identifierReads == 0 && candidate.actionCalls == 0)
  }

  @Test(arguments: ["", " ", "\n\t"])
  func emptyTrimmedLabelQueryCannotMatch(query: String) throws {
    #expect(try search(Element(label: "Unit range slider"), selection: .label(query)) == nil)
  }

  @Test(arguments: ["AXSlider", "AXButton"])
  func duplicateTrimmedLabelsRejectBeforeRoleFiltering(otherRole: String) throws {
    let first = Element(label: "Unit range slider")
    let duplicate = Element(label: "\n Unit range slider \t", role: otherRole)
    #expect(throws: FBSimulatorSliderError.self) {
      _ = try search(Element(children: [first, Element(children: [duplicate])]), selection: .label("Unit range slider"))
    }
    #expect(first.roleReads == 0 && duplicate.roleReads == 0 && duplicate.tokens == ["owned-search"])
    #expect(first.actionCalls == 0 && duplicate.actionCalls == 0)
  }

  @Test(arguments: [0, 1, 2] as [UInt])
  func nestedTraversalUsesTheExactDepthBound(depth: UInt) throws {
    let slider = Element(identifier: "slider.unit")
    let group = Element(children: [slider])
    let root = Element(children: [group])
    let found = try search(root, depth: depth)
    if depth == 2 { #expect(found === slider) }
    else { #expect(found == nil) }
    #expect(root.childrenReads == (depth > 0 ? 1 : 0))
    #expect(group.tokens.count == (depth > 0 ? 1 : 0))
    #expect(group.childrenReads == (depth > 1 ? 1 : 0))
    #expect(slider.tokens.count == (depth > 1 ? 1 : 0))
    #expect(slider.childrenReads == 0)
  }

  @Test func depthZeroCanSelectOnlyTheRoot() throws {
    let child = Element(identifier: "slider.unit")
    let root = Element(identifier: "slider.unit", children: [child])
    #expect(try search(root, depth: 0) === root)
    #expect(root.childrenReads == 0 && child.tokens.isEmpty && child.identifierReads == 0)
  }

  @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity])
  func invalidOrExpiredDeadlineRejectsBeforeNativeReads(deadline: Double) {
    let root = Element(identifier: "slider.unit")
    expectDeadline { _ = try search(root, deadline: deadline) }
    #expect(root.tokens.isEmpty && root.identifierReads == 0 && root.childrenReads == 0 && root.actionCalls == 0)
  }

  @Test func expiryDuringTraversalCannotReturnAnEarlierMatch() {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    let root = Element(identifier: "slider.unit")
    root.onChildrenRead = { waitUntilExpired(deadline) }
    expectDeadline { _ = try search(root, deadline: deadline) }
    #expect(root.identifierReads == 1 && root.childrenReads == 1 && root.actionCalls == 0)
  }

  @Test func expiryInDepthZeroSelectorReadCannotReturnAMatch() {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    let root = Element(identifier: "slider.unit")
    root.onIdentifierRead = { waitUntilExpired(deadline) }
    expectDeadline { _ = try search(root, depth: 0, deadline: deadline) }
    #expect(root.identifierReads == 1 && root.childrenReads == 0 && root.actionCalls == 0)
  }
}
