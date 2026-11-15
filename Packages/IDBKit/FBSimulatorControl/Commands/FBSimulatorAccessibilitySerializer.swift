/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import FBControlCore
import Foundation

/// Reference-typed accumulator for the process ids seen during a serialization
/// traversal. Shared with the remote-content phase so processes already present
/// in the main tree are skipped during grid hit-testing.
final class SeenPIDs {
  private var pids: Set<pid_t> = []
  func insert(_ pid: pid_t) { pids.insert(pid) }
  func contains(_ pid: pid_t) -> Bool { pids.contains(pid) }
}

/// Serializes an `AXPMacPlatformElement` tree into the JSON-ready dictionaries
/// emitted by the accessibility commands. The values mirror the old
/// SimulatorBridge implementation for downstream compatibility.
///
/// Driven entirely from Swift (`FBAXTranslationRequest` and its remote-content
/// code), so it is a plain Swift namespace returning Swift collections.
enum FBSimulatorAccessibilitySerializer {

  private static let axPrefix = "AX"
  private static let discoveryMethodRecursive = "recursive"
  private static let discoveryMethodPointGrid = "point_grid"

  // MARK: - Helpers

  private static func ensureJSONSerializable(_ object: Any?) -> Any {
    guard let object else {
      return NSNull()
    }
    if JSONSerialization.isValidJSONObject([object]) {
      return object
    }
    return String(describing: object)
  }

  // MARK: - Entry points

  static func recursiveDescription(
    fromElement element: FBAXPlatformElement,
    token: String,
    nestedFormat: Bool,
    keys: Set<FBAXKeys>,
    collector: FBAccessibilityProfilingCollector?,
    coverageGrid: FBAccessibilityCoverageGrid?,
    seenPids: SeenPIDs?,
    panel: FBAXPanelRead? = nil
  ) throws -> [[String: Any]] {
    try Task.checkCancellation()
    element.axSetBridgeDelegateToken(token)
    if nestedFormat {
      return try nestedRecursiveDescription(fromElement: element, token: token, keys: keys, collector: collector, coverageGrid: coverageGrid, seenPids: seenPids, panel: panel, transform: nil, attributes: nil, depth: 0).map { [$0] } ?? []
    }
    return try flatRecursiveDescription(fromElement: element, token: token, keys: keys, collector: collector, coverageGrid: coverageGrid, seenPids: seenPids, panel: panel, transform: nil, attributes: nil, depth: 0)
  }

  static func formattedDescription(
    ofElement element: FBAXPlatformElement,
    token: String,
    nestedFormat: Bool,
    keys: Set<FBAXKeys>,
    collector: FBAccessibilityProfilingCollector?,
    coverageGrid: FBAccessibilityCoverageGrid?,
    transform: FBAXPanelFrameTransform? = nil
  ) throws -> [String: Any] {
    try Task.checkCancellation()
    element.axSetBridgeDelegateToken(token)
    if nestedFormat {
      guard let root = try nestedRecursiveDescription(fromElement: element, token: token, keys: keys, collector: collector, coverageGrid: coverageGrid, seenPids: nil, panel: nil, transform: transform, attributes: nil, depth: 0) else {
        throw FBSimulatorAXSnapshotError.emptyHierarchy
      }
      return root
    }
    var attributes = FBAXElementAttributes(element, keys: keys, includeChildren: false)
    attributes.frameTransform = transform
    return try accessibilityDictionary(forElement: element, token: token, keys: keys, collector: collector, coverageGrid: coverageGrid, seenPids: nil, discoveryMethod: discoveryMethodRecursive, attributes: attributes)
  }

  // The values here mirror the old SimulatorBridge implementation for downstream
  // compatibility.
  static func accessibilityDictionary(
    forElement element: FBAXPlatformElement,
    token: String,
    keys: Set<FBAXKeys>,
    collector: FBAccessibilityProfilingCollector?,
    coverageGrid: FBAccessibilityCoverageGrid?,
    seenPids: SeenPIDs?,
    discoveryMethod: String,
    attributes: FBAXElementAttributes? = nil
  ) throws -> [String: Any] {
    try Task.checkCancellation()
    // The token must always be set so that the right callback is called.
    element.axSetBridgeDelegateToken(token)

    let elementPid = element.axTranslationPid
    seenPids?.insert(elementPid)
    let source = attributes ?? FBAXElementAttributes(element, keys: keys, includeChildren: false)

    collector?.incrementElementCount()

    var values: [String: Any] = [:]

    // Includes a key (with JSON serialization) only when requested, incrementing
    // the profiling counter and reading the value lazily so attribute access is
    // tracked exactly as the ObjC macro did.
    func include(_ key: FBAXKeys, _ value: @autoclosure () -> Any?) throws {
      try Task.checkCancellation()
      guard keys.contains(key) else {
        return
      }
      collector?.incrementAttributeFetchCount(forKey: key.rawValue)
      values[key.rawValue] = ensureJSONSerializable(value())
    }

    // Frame is always computed since it is used by multiple keys and the coverage grid.
    collector?.incrementAttributeFetchCount(forKey: FBAXKeys.frame.rawValue)
    try Task.checkCancellation()
    let frame = source.frame()

    // Role is used by multiple keys and needs processing. Check Role first to
    // assign rawRole, then Type can derive from it.
    var role: String?
    var rawRole: String?
    if keys.contains(.role) {
      collector?.incrementAttributeFetchCount(forKey: FBAXKeys.role.rawValue)
      try Task.checkCancellation()
      rawRole = source.role()
      values[FBAXKeys.role.rawValue] = ensureJSONSerializable(rawRole)
    }
    if keys.contains(.type) {
      if rawRole == nil {
        collector?.incrementAttributeFetchCount(forKey: FBAXKeys.type.rawValue)
        try Task.checkCancellation()
        rawRole = source.role()
      }
      // accessibilityRole may be prefixed with "AX"; strip it to match the
      // SimulatorBridge implementation.
      if let rawRole, rawRole.hasPrefix(axPrefix) {
        role = String(rawRole.dropFirst(2))
      } else {
        role = rawRole
      }
    }

    // Mark frame in coverage grid (for non-Application elements).
    if let coverageGrid {
      if rawRole == nil {
        collector?.incrementAttributeFetchCount(forKey: nil)
        try Task.checkCancellation()
        rawRole = source.role()
      }
      let isApplication = rawRole == "AXApplication" || rawRole == "Application"
      if !isApplication {
        coverageGrid.markFilled(with: frame)
      }
    }

    // Legacy values that mirror SimulatorBridge.
    try include(.label, source.label())
    if keys.contains(.frame) {
      values[FBAXKeys.frame.rawValue] = NSStringFromRect(frame)
    }
    try include(.value, source.value())
    try include(.uniqueID, source.identifier())

    // Synthetic values.
    if keys.contains(.type) {
      values[FBAXKeys.type.rawValue] = ensureJSONSerializable(role)
    }

    // New values.
    try include(.title, source.title())
    if keys.contains(.frameDict) {
      collector?.incrementAttributeFetchCount(forKey: FBAXKeys.frameDict.rawValue)
      values[FBAXKeys.frameDict.rawValue] = [
        "x": frame.origin.x,
        "y": frame.origin.y,
        "width": frame.size.width,
        "height": frame.size.height,
      ]
    }
    try include(.help, source.help())
    try include(.enabled, source.isEnabled())
    try include(.customActions, source.customActionNames())
    try include(.roleDescription, source.roleDescription())
    try include(.subrole, source.subrole())
    try include(.contentRequired, source.isRequired())
    try include(.pid, element.axTranslationPid)
    if keys.contains(.traits) {
      collector?.incrementAttributeFetchCount(forKey: FBAXKeys.traits.rawValue)
      try Task.checkCancellation()
      values[FBAXKeys.traits.rawValue] = source.traits() ?? NSNull()
    }
    try include(.expanded, source.isExpanded())
    try include(.placeholder, source.placeholderValue())
    try include(.hidden, source.isHidden())
    try include(.focused, source.isFocused())
    try include(.isRemote, discoveryMethod)

    try Task.checkCancellation()
    return values
  }

  // MARK: - Recursion

  // Non-hierarchical (flat) output: frames are relative to the root, as in SimulatorBridge.
  private static func flatRecursiveDescription(
    fromElement element: FBAXPlatformElement,
    token: String,
    keys: Set<FBAXKeys>,
    collector: FBAccessibilityProfilingCollector?,
    coverageGrid: FBAccessibilityCoverageGrid?,
    seenPids: SeenPIDs?,
    panel: FBAXPanelRead?,
    transform: FBAXPanelFrameTransform?,
    attributes precomputed: FBAXElementAttributes?,
    depth: Int
  ) throws -> [[String: Any]] {
    try Task.checkCancellation()
    var values: [[String: Any]] = []
    var attributes = precomputed ?? FBAXElementAttributes(element, keys: keys, includeChildren: true)
    guard let subtree = panelSubtree(element, &attributes, panel: panel, inherited: transform, depth: depth) else { return [] }
    values.append(try accessibilityDictionary(forElement: element, token: token, keys: keys, collector: collector, coverageGrid: coverageGrid, seenPids: seenPids, discoveryMethod: discoveryMethodRecursive, attributes: attributes))
    try Task.checkCancellation()
    for (child, childAttributes) in children(of: element, attributes.children(), keys: keys, token: token, panel: panel, depth: depth) {
      try Task.checkCancellation()
      child.axSetBridgeDelegateToken(token)
      values.append(contentsOf: try flatRecursiveDescription(fromElement: child, token: token, keys: keys, collector: collector, coverageGrid: coverageGrid, seenPids: seenPids, panel: panel, transform: subtree.transform, attributes: childAttributes, depth: depth + 1))
    }
    try Task.checkCancellation()
    return values
  }

  private static func nestedRecursiveDescription(
    fromElement element: FBAXPlatformElement,
    token: String,
    keys: Set<FBAXKeys>,
    collector: FBAccessibilityProfilingCollector?,
    coverageGrid: FBAccessibilityCoverageGrid?,
    seenPids: SeenPIDs?,
    panel: FBAXPanelRead?,
    transform: FBAXPanelFrameTransform?,
    attributes precomputed: FBAXElementAttributes?,
    depth: Int
  ) throws -> [String: Any]? {
    try Task.checkCancellation()
    var attributes = precomputed ?? FBAXElementAttributes(element, keys: keys, includeChildren: true)
    guard let subtree = panelSubtree(element, &attributes, panel: panel, inherited: transform, depth: depth) else { return nil }
    var values = try accessibilityDictionary(forElement: element, token: token, keys: keys, collector: collector, coverageGrid: coverageGrid, seenPids: seenPids, discoveryMethod: discoveryMethodRecursive, attributes: attributes)
    var childrenValues: [[String: Any]] = []
    try Task.checkCancellation()
    for (child, childAttributes) in children(of: element, attributes.children(), keys: keys, token: token, panel: panel, depth: depth) {
      try Task.checkCancellation()
      child.axSetBridgeDelegateToken(token)
      if let childValues = try nestedRecursiveDescription(fromElement: child, token: token, keys: keys, collector: collector, coverageGrid: coverageGrid, seenPids: seenPids, panel: panel, transform: subtree.transform, attributes: childAttributes, depth: depth + 1) {
        childrenValues.append(childValues)
      }
    }
    values["children"] = childrenValues
    try Task.checkCancellation()
    return values
  }

  /// The frame transform for this element and its subtree, or nil to leave them out: another
  /// panel's window, or an element SpringBoard drew on another panel (#87).
  static func panelSubtree(_ element: FBAXPlatformElement, _ attributes: inout FBAXElementAttributes,
    panel: FBAXPanelRead?, inherited: FBAXPanelFrameTransform?, depth: Int) -> FBAXPanelSubtree? {
    guard let panel else {
      attributes.frameTransform = inherited
      return FBAXPanelSubtree(transform: inherited)
    }
    guard let subtree = panel.subtree(element, attributes: attributes, depth: depth, inherited: inherited) else { return nil }
    attributes.frameTransform = subtree.transform
    return subtree
  }

  /// A panel read reads the root's direct children before serializing any of them, so it knows
  /// whether the root also lists another panel's windows. Their attributes are reused.
  static func children(of element: FBAXPlatformElement, _ children: [FBAXPlatformElement], keys: Set<FBAXKeys>,
    token: String, panel: FBAXPanelRead?, depth: Int) -> [(FBAXPlatformElement, FBAXElementAttributes?)] {
    guard depth == 0, let panel else { return children.map { ($0, nil) } }
    let read = children.map { child -> (FBAXPlatformElement, FBAXElementAttributes?) in
      child.axSetBridgeDelegateToken(token)
      return (child, FBAXElementAttributes(child, keys: keys, includeChildren: true))
    }
    panel.prepare(pid: element.axTranslationPid, windowFrames: read.compactMap { $0.1?.rawFrame() })
    return read
  }
}

// Opt-in traversal. The old entry points and their default key set stay intact.
extension FBSimulatorAccessibilitySerializer {
  static func recursiveDescription(fromElement element: FBAXPlatformElement, token: String,
    nestedFormat: Bool, keys: Set<FBAXKeys>, collector: FBAccessibilityProfilingCollector?,
    coverageGrid: FBAccessibilityCoverageGrid?, seenPids: SeenPIDs?,
    nativeIdentity: FBAXNativeIdentityCollector,
    panel: FBAXPanelRead? = nil) throws -> [[String: Any]] {
    try identityDescription(element, token: token, nestedFormat: nestedFormat, keys: keys,
      collector: collector, coverageGrid: coverageGrid, seenPids: seenPids,
      nativeIdentity: nativeIdentity, panel: panel, transform: nil, attributes: nil, depth: 0)
  }

  static func formattedDescription(ofElement element: FBAXPlatformElement, token: String,
    nestedFormat: Bool, keys: Set<FBAXKeys>, collector: FBAccessibilityProfilingCollector?,
    coverageGrid: FBAccessibilityCoverageGrid?, nativeIdentity: FBAXNativeIdentityCollector,
    transform: FBAXPanelFrameTransform? = nil) throws -> [String: Any] {
    if nestedFormat {
      let values = try identityDescription(element, token: token, nestedFormat: true, keys: keys,
        collector: collector, coverageGrid: coverageGrid, seenPids: nil,
        nativeIdentity: nativeIdentity, panel: nil, transform: transform, attributes: nil, depth: 0)
      guard let root = values.first else { throw FBSimulatorAXSnapshotError.emptyHierarchy }
      return root
    }
    var attributes = FBAXElementAttributes(element, keys: keys, includeChildren: false)
    attributes.frameTransform = transform
    return try identityDictionary(element, token: token, keys: keys, collector: collector,
      coverageGrid: coverageGrid, seenPids: nil, nativeIdentity: nativeIdentity, depth: 0, attributes: attributes)
  }

  static func identityDictionary(_ element: FBAXPlatformElement, token: String,
    keys: Set<FBAXKeys>, collector: FBAccessibilityProfilingCollector?,
    coverageGrid: FBAccessibilityCoverageGrid?, seenPids: SeenPIDs?,
    nativeIdentity: FBAXNativeIdentityCollector, depth: Int,
    attributes: FBAXElementAttributes? = nil) throws -> [String: Any] {
    var values = try accessibilityDictionary(forElement: element, token: token, keys: keys,
      collector: collector, coverageGrid: coverageGrid, seenPids: seenPids, discoveryMethod: "recursive",
      attributes: attributes)
    if let identity = nativeIdentity.identity(of: element, depth: depth) {
      values["nativeIdentity"] = ["pid": identity.pid, "objectID": String(identity.objectID)]
    }
    return values
  }

  private static func identityDescription(_ element: FBAXPlatformElement, token: String,
    nestedFormat: Bool, keys: Set<FBAXKeys>, collector: FBAccessibilityProfilingCollector?,
    coverageGrid: FBAccessibilityCoverageGrid?, seenPids: SeenPIDs?,
    nativeIdentity: FBAXNativeIdentityCollector, panel: FBAXPanelRead?,
    transform: FBAXPanelFrameTransform?, attributes precomputed: FBAXElementAttributes?,
    depth: Int) throws -> [[String: Any]] {
    try Task.checkCancellation()
    element.axSetBridgeDelegateToken(token)
    var attributes = precomputed ?? FBAXElementAttributes(element, keys: keys, includeChildren: true)
    guard let subtree = panelSubtree(element, &attributes, panel: panel, inherited: transform, depth: depth) else { return [] }
    var values = try identityDictionary(element, token: token, keys: keys, collector: collector,
      coverageGrid: coverageGrid, seenPids: seenPids, nativeIdentity: nativeIdentity, depth: depth,
      attributes: attributes)
    var descendants: [[String: Any]] = []
    let identityChildren = nativeIdentity.children(from: attributes.nativeIdentityChildren())
    for (child, childAttributes) in children(of: element, identityChildren, keys: keys, token: token, panel: panel, depth: depth) {
      try Task.checkCancellation()
      child.axSetBridgeDelegateToken(token)
      descendants += try identityDescription(child, token: token, nestedFormat: nestedFormat, keys: keys,
        collector: collector, coverageGrid: coverageGrid, seenPids: seenPids,
        nativeIdentity: nativeIdentity, panel: panel, transform: subtree.transform,
        attributes: childAttributes, depth: depth + 1)
    }
    if nestedFormat { values["children"] = descendants; return [values] }
    return [values] + descendants
  }
}

/// One translator request per element for the attributes a read needs, instead of one request
/// per accessor. `accessibilityMultipleAttributes:` omits nil values, which read as absent here.
/// A missing answer, a missing frame or children, or an unexpected value type falls back to the
/// element's own accessor. Custom action names always use their own read: the batched value
/// omitted a keyboard key's custom actions in comparison reads.
struct FBAXElementAttributes {
  let element: FBAXPlatformElement
  private let batch: [String: Any]?
  /// Set for an element inside a native-oriented panel window; `frame()` is then oriented.
  var frameTransform: FBAXPanelFrameTransform?

  init(_ element: FBAXPlatformElement, keys: Set<FBAXKeys>, includeChildren: Bool) {
    self.element = element
    batch = element.axBatchedAttributes(Self.names(for: keys, includeChildren: includeChildren))
  }

  /// Frame and role are always read: frame for coverage, role for the type and coverage checks.
  static func names(for keys: Set<FBAXKeys>, includeChildren: Bool) -> [String] {
    let mapped: [(FBAXKeys, String)] = [(.label, "AXDescription"), (.value, "AXValue"), (.uniqueID, "AXIdentifier"),
      (.title, "AXTitle"), (.help, "AXHelp"), (.enabled, "AXEnabled"), (.roleDescription, "AXRoleDescription"),
      (.subrole, "AXSubrole"), (.contentRequired, "AXRequired"), (.traits, "AXTraits"), (.expanded, "AXExpanded"),
      (.placeholder, "AXPlaceholderValue"), (.hidden, "AXHidden"), (.focused, "AXFocused")]
    return ["AXFrame", "AXRole"] + mapped.filter { keys.contains($0.0) }.map(\.1)
      + (includeChildren ? ["AXChildren"] : [])
  }

  private func string(_ name: String, _ read: () -> String?) -> String? {
    guard let batch else { return read() }
    guard let value = batch[name] else { return nil }
    return (value as? String) ?? read()
  }

  private func flag(_ name: String, _ read: () -> Bool) -> Bool {
    guard let batch else { return read() }
    guard let value = batch[name] else { return false }
    return (value as? NSNumber)?.boolValue ?? read()
  }

  func rawFrame() -> NSRect { (batch?["AXFrame"] as? NSValue)?.rectValue ?? element.axFrame() }
  func frame() -> NSRect { frameTransform.map { $0.logicalFrame(rawFrame()) } ?? rawFrame() }
  func role() -> String? { string("AXRole") { element.axRole() } }
  func label() -> String? { string("AXDescription") { element.axLabel() } }
  func value() -> Any? {
    guard let batch else { return element.axValue() }
    return batch["AXValue"]
  }
  func identifier() -> String? { string("AXIdentifier") { element.axIdentifier() } }
  func title() -> String? { string("AXTitle") { element.axTitle() } }
  func help() -> String? { string("AXHelp") { element.axHelp() } }
  func roleDescription() -> String? { string("AXRoleDescription") { element.axRoleDescription() } }
  func subrole() -> String? { string("AXSubrole") { element.axSubrole() } }
  func placeholderValue() -> String? { string("AXPlaceholderValue") { element.axPlaceholderValue() } }
  func isEnabled() -> Bool { flag("AXEnabled") { element.axIsEnabled() } }
  func isRequired() -> Bool { flag("AXRequired") { element.axIsRequired() } }
  func isExpanded() -> Bool { flag("AXExpanded") { element.axIsExpanded() } }
  func isHidden() -> Bool { flag("AXHidden") { element.axIsHidden() } }
  func isFocused() -> Bool { flag("AXFocused") { element.axIsFocused() } }
  func customActionNames() -> [String] { element.axCustomActionNames() }

  func traits() -> [String]? {
    guard let batch else { return element.axTraits() }
    guard let value = batch["AXTraits"] else { return nil }
    guard let number = value as? NSNumber else { return element.axTraits() }
    return Array(AXExtractTraits(number.uint64Value))
  }

  func children() -> [FBAXPlatformElement] {
    guard let raw = batch?["AXChildren"] as? [Any] else { return element.axChildren() }
    return raw.compactMap { $0 as? FBAXPlatformElement }
  }

  /// The batched answer lists a leaf's children as an empty array, as the individual read does.
  func nativeIdentityChildren() -> FBAXNativeIdentityChildren {
    guard let raw = batch?["AXChildren"] as? [Any] else { return element.axNativeIdentityChildren() }
    let elements = raw.compactMap { $0 as? FBAXPlatformElement }
    return .init(elements: elements, reason: elements.count == raw.count ? nil : "unsupportedChildType")
  }
}
