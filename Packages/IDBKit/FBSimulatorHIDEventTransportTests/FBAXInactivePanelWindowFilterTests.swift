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
    let root = try serialize(duoSpringBoard(), nested: nested, panel: read(filter))
    #expect(labels(root).sorted() == ["Inner settings", "Inner window", "Nested outer-sized", "SpringBoard"])
    let unfiltered = try serialize(duoSpringBoard(), nested: nested, panel: nil)
    #expect(labels(unfiltered).count == 7)
  }

  @Test(arguments: [true, false])
  func identitySerializerLeavesOutOnlyTopLevelInactivePanelWindows(nested: Bool) throws {
    let filter = try #require(FBAXInactivePanelWindowFilter(panels: duo, activeScreenID: 3))
    let identities = FBAXNativeIdentityCollector()
    let root = try serialize(duoSpringBoard(), nested: nested, panel: read(filter), identities: identities)
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

  // Inner panel in landscape (rot90): native 669x951 pt, oriented 951x669 pt.
  private func innerContext(_ rotation: FBSimulatorHIDDisplayRotation = .rot90) throws -> FBSimulatorHIDDisplayContext {
    try FBSimulatorHIDDisplayContext(hidTarget: 3, nativePixelSize: CGSize(width: 2007, height: 2853),
      scale: 3, rotation: rotation)
  }

  @Test func frameTransformInvertsTheHIDPointTransform() throws {
    for rotation in [FBSimulatorHIDDisplayRotation.rot90, .rot270] {
      let context = try innerContext(rotation)
      let transform = try #require(FBAXPanelFrameTransform(context: context))
      for logical in [CGPoint(x: 903.2, y: 379.7), CGPoint(x: 10, y: 600), CGPoint(x: 951, y: 0)] {
        let normalized = try context.normalizedPoint(from: logical)
        let native = CGPoint(x: normalized.x * 669, y: normalized.y * 951)
        let back = transform.logicalPoint(native)
        #expect(abs(back.x - logical.x) < 0.001 && abs(back.y - logical.y) < 0.001)
      }
    }
    #expect(FBAXPanelFrameTransform(context: try innerContext(.rot0)) == nil)
    #expect(FBAXPanelFrameTransform(context: try innerContext(.rot180)) == nil)
  }

  @Test func frameTransformMovesTheDockIconToWhereItIsDrawn() throws {
    let transform = try #require(FBAXPanelFrameTransform(context: try innerContext()))
    // Measured: Safari's native frame, drawn at about (871...935, 348...412) in landscape.
    let safari = transform.logicalFrame(CGRect(x: 347.667, y: 15.833, width: 64, height: 64))
    #expect(abs(safari.minX - 871.167) < 0.01 && abs(safari.minY - 347.667) < 0.01)
    #expect(safari.size == CGSize(width: 64, height: 64))
    #expect(transform.logicalFrame(CGRect(x: 0, y: 0, width: 669, height: 951)) == CGRect(x: 0, y: 0, width: 951, height: 669))
    #expect(transform.logicalFrame(.zero) == .zero)
    let flipped = try #require(FBAXPanelFrameTransform(context: try innerContext(.rot270)))
    #expect(flipped.logicalFrame(CGRect(x: 10, y: 20, width: 30, height: 40)) == CGRect(x: 20, y: 629, width: 40, height: 30))
  }

  @Test func processSpaceNeedsOneKindOfPanelWindow() throws {
    let transform = try #require(FBAXPanelFrameTransform(context: try innerContext()))
    let native = CGRect(x: 0, y: 0, width: 669, height: 951)
    let oriented = CGRect(x: 0, y: 0, width: 951, height: 669)
    let outer = CGRect(x: 0, y: 0, width: 466, height: 678)
    #expect(FBAXNativeFrameProcesses.classify([native, outer], transform: transform) == .native)
    #expect(FBAXNativeFrameProcesses.classify([oriented], transform: transform) == .oriented)
    #expect(FBAXNativeFrameProcesses.classify([native, oriented], transform: transform) == .mixed)
    #expect(FBAXNativeFrameProcesses.classify([outer], transform: transform) == .mixed)
  }

  @Test(arguments: [true, false])
  func serializerOrientsOnlyNativePanelWindows(nested: Bool) throws {
    let transform = try #require(FBAXPanelFrameTransform(context: try innerContext()))
    let rules = try #require(FBAXPanelWindowRules(filter: nil, transform: transform))
    let root = Element(label: "SpringBoard", frame: CGRect(x: 0, y: 0, width: 466, height: 678), role: "AXApplication", children: [
      Element(label: "Native window", frame: CGRect(x: 0, y: 0, width: 669, height: 951), children: [
        Element(label: "Safari", frame: CGRect(x: 347.667, y: 15.833, width: 64, height: 64), role: "AXButton"),
        Element(label: "Structural", frame: .zero, role: "AXButton"),
      ]),
      Element(label: "Oriented window", frame: CGRect(x: 0, y: 0, width: 951, height: 669), children: [
        Element(label: "App button", frame: CGRect(x: 10, y: 20, width: 30, height: 40), role: "AXButton"),
      ]),
    ])
    let value = try serialize(root, nested: nested, panel: FBAXPanelRead(rules: rules, activeDisplayID: 3, processKey: nil))
    let frames = frames(value)
    #expect(frames["SpringBoard"] == CGRect(x: 0, y: 0, width: 466, height: 678))
    #expect(frames["Native window"] == CGRect(x: 0, y: 0, width: 951, height: 669))
    #expect(abs((frames["Safari"]?.minX ?? 0) - 871.167) < 0.01)
    #expect(frames["Structural"] == .zero)
    #expect(frames["Oriented window"] == CGRect(x: 0, y: 0, width: 951, height: 669))
    #expect(frames["App button"] == CGRect(x: 10, y: 20, width: 30, height: 40))
  }

  @Test(arguments: [true, false])
  func springBoardButtonsDrawnOnTheOtherPanelAreLeftOut(nested: Bool) throws {
    let filter = try #require(FBAXInactivePanelWindowFilter(panels: duo, activeScreenID: 3))
    let rules = try #require(FBAXPanelWindowRules(filter: filter, transform: nil))
    let inner = CGRect(x: 0, y: 0, width: 669, height: 951)
    let outer = CGRect(x: 0, y: 0, width: 466, height: 678)
    func springBoard(listsOuterWindow: Bool) -> Element {
      Element(label: "SpringBoard", frame: outer, role: "AXApplication", children: [
        Element(label: "Inner window", frame: inner, children: [
          Element(label: "Outer icon copy", frame: CGRect(x: 22, y: 52, width: 68, height: 86), role: "AXButton", display: 1,
            children: [Element(label: "Copy label", frame: CGRect(x: 24, y: 117, width: 64, height: 19))]),
          Element(label: "Widget", frame: CGRect(x: 52, y: 720, width: 184, height: 162), role: "AXButton", display: 3),
          Element(label: "Unknown display", frame: CGRect(x: 52, y: 417, width: 86, height: 68), role: "AXButton"),
          Element(label: "Group on outer", frame: CGRect(x: 0, y: 0, width: 10, height: 10), display: 1),
        ]),
      ] + (listsOuterWindow ? [Element(label: "Outer window", frame: outer)] : []))
    }
    let panel = { FBAXPanelRead(rules: rules, activeDisplayID: 3, processKey: nil) }
    let filtered = try serialize(springBoard(listsOuterWindow: true), nested: nested, panel: panel())
    #expect(labels(filtered).sorted() == ["Group on outer", "Inner window", "SpringBoard", "Unknown display", "Widget"])
    // An app lists no other panel's window, so its buttons are not asked for a display.
    let app = try serialize(springBoard(listsOuterWindow: false), nested: nested, panel: panel())
    #expect(labels(app).count == 7)
  }

  private func frames(_ value: FBSimulatorAXValue) -> [String: CGRect] {
    var found: [String: CGRect] = [:]
    func walk(_ value: FBSimulatorAXValue) {
      switch value {
      case .object(let members):
        if case .string(let label)? = members["AXLabel"], case .object(let frame)? = members["frame"],
           case .number(let x)? = frame["x"], case .number(let y)? = frame["y"],
           case .number(let width)? = frame["width"], case .number(let height)? = frame["height"] {
          found[label] = CGRect(x: x, y: y, width: width, height: height)
        }
        members.values.forEach(walk)
      case .array(let members): members.forEach(walk)
      default: break
      }
    }
    walk(value)
    return found
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

  private func read(_ filter: FBAXInactivePanelWindowFilter) -> FBAXPanelRead? {
    FBAXPanelWindowRules(filter: filter, transform: nil).map { FBAXPanelRead(rules: $0, activeDisplayID: 3, processKey: nil) }
  }

  private func serialize(_ root: Element, nested: Bool, panel: FBAXPanelRead?,
    identities: FBAXNativeIdentityCollector? = nil) throws -> FBSimulatorAXValue {
    let keys: Set<FBAXKeys> = [.label, .type, .frameDict, .pid]
    let values: [[String: Any]]
    if let identities {
      values = try FBSimulatorAccessibilitySerializer.recursiveDescription(fromElement: root, token: "read",
        nestedFormat: nested, keys: keys, collector: nil, coverageGrid: nil, seenPids: nil,
        nativeIdentity: identities, panel: panel)
    } else {
      values = try FBSimulatorAccessibilitySerializer.recursiveDescription(fromElement: root, token: "read",
        nestedFormat: nested, keys: keys, collector: nil, coverageGrid: nil, seenPids: nil, panel: panel)
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
    let display: UInt32?
    let children: [Element]
    init(label: String, frame: CGRect, role: String = "AXGroup", display: UInt32? = nil, children: [Element] = []) {
      self.label = label; self.frame = frame; self.role = role; self.display = display; self.children = children
    }
    func axDisplayID() -> UInt32? { display }
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
