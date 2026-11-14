import AppKit
import FBControlCore
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Inactive-panel window filter (#87)")
struct FBAXInactivePanelWindowFilterTests {
  // iPhone Duo: outer screen 1 (1398x2034 px, 466x678 pt), inner screen 3 (2007x2853 px, 669x951 pt).
  private let duo: [FBAXInactivePanelWindowFilter.Panel] = [
    .init(screenID: 1, pixelSize: CGSize(width: 1398, height: 2034), scale: 3),
    .init(screenID: 3, pixelSize: CGSize(width: 2007, height: 2853), scale: 3),
  ]

  @Test func innerPanelDropsOnlyOuterPanelWindows() throws {
    let filter = try #require(FBAXInactivePanelWindowFilter(panels: duo, activeScreenID: 3))
    for size in [CGSize(width: 466, height: 678), CGSize(width: 678, height: 466),
                 CGSize(width: 1398, height: 2034), CGSize(width: 2034, height: 1398)] {
      #expect(filter.excludes(CGRect(origin: .zero, size: size)))
    }
    for size in [CGSize(width: 669, height: 951), CGSize(width: 951, height: 669),
                 CGSize(width: 2007, height: 2853), CGSize(width: 2853, height: 2007)] {
      #expect(!filter.excludes(CGRect(origin: .zero, size: size)))
    }
    #expect(!filter.excludes(CGRect(x: 0, y: 1, width: 466, height: 678)))
  }

  @Test func outerPanelDropsOnlyInnerPanelWindows() throws {
    let filter = try #require(FBAXInactivePanelWindowFilter(panels: duo, activeScreenID: 1))
    #expect(filter.excludes(CGRect(x: 0, y: 0, width: 669, height: 951)))
    #expect(filter.excludes(CGRect(x: 0, y: 0, width: 2853, height: 2007)))
    #expect(!filter.excludes(CGRect(x: 0, y: 0, width: 466, height: 678)))
    #expect(!filter.excludes(CGRect(x: 0, y: 0, width: 1398, height: 2034)))
  }

  @Test func noFilterWithoutTwoDistinctKnownPanels() {
    #expect(FBAXInactivePanelWindowFilter(panels: [duo[0]], activeScreenID: 1) == nil)
    #expect(FBAXInactivePanelWindowFilter(panels: duo, activeScreenID: 0) == nil)
    #expect(FBAXInactivePanelWindowFilter(panels: duo, activeScreenID: 2) == nil)
    let twins: [FBAXInactivePanelWindowFilter.Panel] = [duo[0], .init(screenID: 2, pixelSize: duo[0].pixelSize, scale: 3)]
    #expect(FBAXInactivePanelWindowFilter(panels: twins, activeScreenID: 1) == nil)
  }

  @Test func catalogReadsOnlyIntegratedTouchPanels() throws {
    let plist: [String: Any] = ["capabilities": ["displays": [
      ["displayType": "integrated", "hasDigitizer": true, "screenID": 1, "width": 1398, "height": 2034, "scale": 3.0],
      ["displayType": "tvOut", "hasDigitizer": false, "screenID": 2, "width": 720, "height": 480, "scale": 1.0],
      ["displayType": "integrated", "hasDigitizer": true, "screenID": 3, "width": 2007, "height": 2853, "scale": 3.0],
      ["displayType": "scene", "hasDigitizer": true, "screenID": 5, "width": 7680, "height": 4320, "scale": 3.0],
      ["displayType": "integrated", "hasDigitizer": true, "screenID": 6],
    ]]]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    #expect(try FBAXIntegratedPanelCatalog.decode(data) == duo)
  }

  @Test(arguments: [true, false])
  func serializerLeavesOutOnlyTopLevelInactivePanelWindows(nested: Bool) throws {
    let filter = try #require(FBAXInactivePanelWindowFilter(panels: duo, activeScreenID: 3))
    let root = try serialize(duoSpringBoard(), nested: nested, filter: filter)
    #expect(labels(root).sorted() == ["Inner settings", "Inner window", "Nested outer-sized", "SpringBoard"])
    let unfiltered = try serialize(duoSpringBoard(), nested: nested, filter: nil)
    #expect(labels(unfiltered).count == 7)
  }

  @Test(arguments: [true, false])
  func identitySerializerLeavesOutOnlyTopLevelInactivePanelWindows(nested: Bool) throws {
    let filter = try #require(FBAXInactivePanelWindowFilter(panels: duo, activeScreenID: 3))
    let identities = FBAXNativeIdentityCollector()
    let root = try serialize(duoSpringBoard(), nested: nested, filter: filter, identities: identities)
    #expect(identities.metadata == .init(complete: true))
    #expect(labels(root).sorted() == ["Inner settings", "Inner window", "Nested outer-sized", "SpringBoard"])
  }

  @Test func frameTapRefusesPointThatFallsThroughToTheWholePanel() throws {
    // Inner panel in landscape: native 669x951 pt, oriented 951x669 pt.
    let inner = try FBSimulatorHIDDisplayContext(hidTarget: 3, nativePixelSize: CGSize(width: 2007, height: 2853),
      scale: 3, rotation: .rot90)
    for frame in [CGRect(x: 0, y: 0, width: 669, height: 951), CGRect(x: 0, y: 0, width: 951, height: 669),
                  CGRect(x: -10, y: -10, width: 1000, height: 1000)] {
      #expect(throws: FBAXOpaqueFrameTapError.self) {
        try FBAXOpaqueFrameTapRules.requirePointInsidePanelContent([try node(frame)], context: inner)
      }
    }
    for frame in [CGRect(x: 0, y: 0, width: 669, height: 900), CGRect(x: 52, y: 417, width: 87, height: 68)] {
      try FBAXOpaqueFrameTapRules.requirePointInsidePanelContent([try node(frame)], context: inner)
    }
  }

  private func node(_ frame: CGRect) throws -> FBSimulatorAXNode {
    let values: [String: Any] = ["type": "Group", "pid": 42,
      "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]]
    return try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONSerialization.data(withJSONObject: values))
  }

  private func duoSpringBoard() -> Element {
    let outer = CGRect(x: 0, y: 0, width: 466, height: 678)
    let inner = CGRect(x: 0, y: 0, width: 669, height: 951)
    return Element(label: "SpringBoard", frame: outer, role: "AXApplication", children: [
      Element(label: "Outer window", frame: outer, children: [Element(label: "Outer settings", frame: CGRect(x: 52, y: 417, width: 87, height: 68))]),
      Element(label: "Inner window", frame: inner, children: [
        Element(label: "Inner settings", frame: CGRect(x: 52, y: 417, width: 87, height: 68)),
        Element(label: "Nested outer-sized", frame: outer),
      ]),
      Element(label: "Outer pixel window", frame: CGRect(x: 0, y: 0, width: 1398, height: 2034)),
    ])
  }

  private func serialize(_ root: Element, nested: Bool, filter: FBAXInactivePanelWindowFilter?,
    identities: FBAXNativeIdentityCollector? = nil) throws -> FBSimulatorAXValue {
    let keys: Set<FBAXKeys> = [.label, .type, .frameDict, .pid]
    let values: [[String: Any]]
    if let identities {
      values = try FBSimulatorAccessibilitySerializer.recursiveDescription(fromElement: root, token: "read",
        nestedFormat: nested, keys: keys, collector: nil, coverageGrid: nil, seenPids: nil,
        nativeIdentity: identities, windowFilter: filter)
    } else {
      values = try FBSimulatorAccessibilitySerializer.recursiveDescription(fromElement: root, token: "read",
        nestedFormat: nested, keys: keys, collector: nil, coverageGrid: nil, seenPids: nil, windowFilter: filter)
    }
    return try JSONDecoder().decode(FBSimulatorAXValue.self, from: JSONSerialization.data(withJSONObject: values))
  }

  private func labels(_ value: FBSimulatorAXValue) -> [String] {
    switch value {
    case .object(let members):
      var found: [String] = []
      if case .string(let label)? = members["AXLabel"] { found.append(label) }
      return found + members.filter { $0.key != "AXLabel" }.values.flatMap(labels)
    case .array(let members): return members.flatMap(labels)
    default: return []
    }
  }

  private final class Element: FBAXPlatformElement {
    let label: String
    let frame: CGRect
    let role: String
    let children: [Element]
    init(label: String, frame: CGRect, role: String = "AXGroup", children: [Element] = []) {
      self.label = label; self.frame = frame; self.role = role; self.children = children
    }
    func axNativeIdentity() -> FBSimulatorAXNativeIdentity? {
      .init(pid: 42, objectID: UInt64(UInt(bitPattern: ObjectIdentifier(self).hashValue)))
    }
    func axNativeIdentityChildren() -> FBAXNativeIdentityChildren { .init(elements: children, reason: nil) }
    func axChildren() -> [FBAXPlatformElement] { children }
    func axSetBridgeDelegateToken(_ token: String?) {}
    var axTranslationPid: pid_t { 42 }
    func axFrame() -> NSRect { frame }
    func axRole() -> String? { role }
    func axLabel() -> String? { label }
    func axValue() -> Any? { nil }
    func axIdentifier() -> String? { nil }
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
    func axPerformPress() -> Bool { false }
    func axScroll(_ direction: FBAccessibilityScrollDirection) {}
    func axSetValue(_ value: Any?) {}
  }
}
