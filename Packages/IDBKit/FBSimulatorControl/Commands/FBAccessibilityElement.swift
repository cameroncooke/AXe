/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@_implementationOnly import AccessibilityPlatformTranslation
import FBControlCore
import Foundation

/// An opaque accessibility element with a managed token lifecycle.
///
/// The element's translation token remains registered as long as the element is
/// open, allowing serialization (attribute reads go through XPC callbacks routed
/// by token). Actions (tap, scroll) are direct calls on the element and do not
/// require the token. Call `close()` when done to deregister the token; after
/// close, serialization fails.
///
/// A pure-Swift class in FBSimulatorControl (FBControlCore never consumed it —
/// only the simulator-side facade does, which is now Swift too).
public final class FBAccessibilityElement {

  private let element: FBAXPlatformElement
  private let request: FBAXTranslationRequest
  private let dispatcher: FBAXTranslationDispatcher
  private weak var simulator: FBSimulator?
  private var closed: Bool = false

  init(element: FBAXPlatformElement, request: FBAXTranslationRequest, dispatcher: FBAXTranslationDispatcher, simulator: FBSimulator) {
    self.element = element
    self.request = request
    self.dispatcher = dispatcher
    self.simulator = simulator
  }

  deinit {
    close()
  }

  var acquisitionPID: Int32 { element.axTranslationPid }

  // Isolated read-only diagnostic. These methods are used only by the AX worker;
  // the recorder and platform references never cross its execution boundary.
  func identityRootContext(budget: FBAXAcquisitionBudget, routing: FBAXIdentityRoutingRecorder) throws -> FBAXIdentityContext {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "read identity root context") }
    return try FBAXIdentityRecorder.readRootContext(element, token: request.token, budget: budget, routing: routing)
  }

  func recordIdentityTree(_ recorder: FBAXIdentityRecorder) throws {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "read identity tree") }
    try recorder.recursive(element, token: request.token)
  }

  func finishIdentityEvidence(_ recorder: FBAXIdentityRecorder) throws -> Data {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "read identity point") }
    return try recorder.finish(point: element, token: request.token)
  }

  // Experimental hosted-link admission; framework references stay on the AX worker.
  func hostedWebPoint(budget: FBAXAcquisitionBudget, routing: FBAXIdentityRoutingRecorder) throws -> FBAXHostedWebPoint {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "read hosted web point") }
    return try FBAXHostedWebPoint.read(element, token: request.token, budget: budget, routing: routing)
  }

  func semanticPressSelection(identifier: String, pid: Int32, rootContext: UInt32, display: UInt32,
    budget: FBAXAcquisitionBudget, routing: FBAXIdentityRoutingRecorder) throws -> FBAXSemanticPressSelection {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "select semantic press target") }
    return try FBAXSemanticPressSelection(root: element, request: request, dispatcher: dispatcher,
      identifier: identifier, pid: pid, rootContext: rootContext, display: display, budget: budget, routing: routing)
  }

  func simulatorPointToken(budget: FBAXAcquisitionBudget) throws -> FBAXSimulatorDeviceToken {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "read selected point token") }
    try budget.check()
    let token = try element.axSimulatorDeviceToken()
    try budget.check()
    return token
  }

  func simulatorSwitchToken(identifier: String, frame: CGRect, pid: Int32,
    budget: FBAXAcquisitionBudget) throws -> FBAXSimulatorDeviceToken {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "read selected switch token") }
    var matches: [FBAXSimulatorDeviceToken] = []
    var visited = 0
    func walk(_ node: FBAXPlatformElement, depth: Int) throws {
      try budget.check()
      guard depth <= 32, visited < 512 else { throw FBAXNativeSwitchError.rejected("Selected native tree bound exceeded") }
      visited += 1
      node.axSetBridgeDelegateToken(request.token)
      if node.axIdentifier() == identifier {
        guard node.axTranslationPid == pid, node.axRole() == "AXCheckBox", node.axFrame() == frame,
              node.axIsEnabled(), !node.axIsHidden() else { throw FBSimulatorAXTargetError.targetMismatch }
        matches.append(try node.axSimulatorDeviceToken())
      }
      for child in node.axChildren() { try walk(child, depth: depth + 1) }
    }
    try walk(element, depth: 0)
    guard matches.count == 1, let token = matches.first else { throw FBSimulatorAXTargetError.targetMismatch }
    try budget.check()
    return token
  }


  /// Uniqueness is checked across TextFields before focus, process or state filtering.
  /// Only the matched field is serialized; its platform handle stays on the AX worker.
  func focusedTextField(identifier: String, expectedPID: Int32,
                        budget: FBAXAcquisitionBudget) throws -> FBSimulatorAXNode {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "read keyboard focus") }
    var selected: FBAXPlatformElement?
    var selection = FBAXFocusedTextFieldSelection(identifier: identifier)
    var visited = 0
    func walk(_ node: FBAXPlatformElement, depth: Int) throws {
      try Task.checkCancellation()
      try budget.check()
      guard depth <= 32, visited < 512 else { throw FBSimulatorAXSnapshotError.invalidSelection }
      visited += 1
      node.axSetBridgeDelegateToken(request.token)
      if node.axIdentifier() == identifier,
         try selection.include(identifier: identifier, role: node.axRole()) {
        selected = node
      }
      for child in node.axChildren() { try walk(child, depth: depth + 1) }
      try budget.check()
    }
    try walk(element, depth: 0)
    guard let selected else { throw FBSimulatorAXSnapshotError.notFound }
    try budget.check()
    let values = try FBSimulatorAccessibilitySerializer.accessibilityDictionary(forElement: selected,
      token: request.token, keys: FBSimulatorAXWorker.snapshotKeys, collector: nil,
      coverageGrid: nil, seenPids: nil, discoveryMethod: "recursive")
    let data = try JSONSerialization.data(withJSONObject: values)
    guard data.count <= 1_048_576 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    let field = try JSONDecoder().decode(FBSimulatorAXNode.self, from: data)
    try selection.validate(field, expectedPID: expectedPID)
    try budget.check()
    try Task.checkCancellation()
    return field
  }

  func focusedTextField(identity: FBSimulatorAXNativeIdentity, expectedPID: Int32,
    logicalSize: CGSize, budget: FBAXAcquisitionBudget) throws -> FBSimulatorAXNode {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "read native keyboard focus") }
    try identity.validate()
    let identities = FBAXNativeIdentityCollector()
    var selection = FBAXFocusedNativeTextFieldSelection(identity: identity)
    var selected: FBAXPlatformElement?
    var selectedAncestors: [FBAXPlatformElement] = []
    var visited = 0
    func walk(_ node: FBAXPlatformElement, depth: Int, ancestors: [FBAXPlatformElement]) throws {
      try budget.check(); try Task.checkCancellation()
      guard depth <= 64, visited < 4096 else { throw FBSimulatorAXSnapshotError.invalidSelection }
      visited += 1
      node.axSetBridgeDelegateToken(request.token)
      let key = identities.identity(of: node, depth: depth)
      if try selection.include(identity: key) { selected = node; selectedAncestors = ancestors }
      for child in identities.children(of: node) { try walk(child, depth: depth + 1, ancestors: ancestors + [node]) }
      try budget.check()
    }
    try walk(element, depth: 0, ancestors: [])
    guard identities.metadata.complete else { throw FBSimulatorAXSnapshotError.invalidSelection }
    guard let selected else { throw FBSimulatorAXSnapshotError.notFound }
    for ancestor in selectedAncestors {
      try budget.check()
      guard !ancestor.axIsHidden(), ancestor.axIsEnabled() else { throw FBSimulatorAXTargetError.targetMismatch }
    }
    let values = try FBSimulatorAccessibilitySerializer.identityDictionary(selected, token: request.token,
      keys: FBSimulatorAXWorker.snapshotKeys, collector: nil, coverageGrid: nil, seenPids: nil,
      nativeIdentity: FBAXNativeIdentityCollector(), depth: 0)
    let data = try JSONSerialization.data(withJSONObject: values)
    guard data.count <= 1_048_576 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    let field = try JSONDecoder().decode(FBSimulatorAXNode.self, from: data)
    try selection.validate(field, expectedPID: expectedPID, logicalSize: logicalSize)
    try budget.check(); try Task.checkCancellation()
    return field
  }

  /// The worker retains this current root while the physical Button leaf is validated.
  func buttonLeafAdmission(expected: FBSimulatorAXNode, matchingCount: Int,
    budget: FBAXAcquisitionBudget) throws -> FBAXButtonLeafAdmission {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "select Button leaf") }
    return try FBAXButtonLeafAdmission(root: element, token: request.token,
      expected: expected, matchingCount: matchingCount, budget: budget)
  }

  func validateButtonLeafPoint(_ admission: FBAXButtonLeafAdmission, orientedPoint: CGPoint) throws {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "validate Button leaf point") }
    try admission.validatePoint(element, token: request.token, orientedPoint: orientedPoint)
  }

  // MARK: - Lifecycle

  /// Close the element, deregistering the token. Called automatically on dealloc
  /// as a safety net. After close, serialization fails.
  public func close() {
    if !closed {
      closed = true
      dispatcher.popRequest(request)
    }
  }

  // MARK: - Serialization

  /// Serialize the element to a full response (preserves profiling/coverage data).
  public func serialize(with options: FBAccessibilityRequestOptions) throws -> FBAccessibilityElementsResponse {
    if closed {
      throw FBAccessibilityError.closedElement(operation: "serialize")
    }
    if options.enableProfiling && request.collector == nil {
      request.collector = FBAccessibilityProfilingCollector()
    }
    // Wire the per-request logger from the option so the dispatcher's XPC
    // callbacks (which capture `request.logger`) actually emit request/response
    // logging during the serialization walk. Mirrors the `collector` wiring above.
    request.logger = options.enableLogging ? simulator?.logger : nil
    return try request.run(element, options: options)
  }

  /// Optional identity metadata never changes the legacy serialization entry point.
  func serialize(with options: FBAccessibilityRequestOptions,
    nativeIdentity: FBAXNativeIdentityCollector) throws -> FBAccessibilityElementsResponse {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "serialize native identity") }
    if options.enableProfiling && request.collector == nil {
      request.collector = FBAccessibilityProfilingCollector()
    }
    request.logger = options.enableLogging ? simulator?.logger : nil
    return try request.run(element, options: options, nativeIdentity: nativeIdentity)
  }

  /// Read the string value of a searchable accessibility key from this element.
  public func stringValue(forSearchableKey key: FBAXSearchableKey) throws -> String {
    if closed {
      throw FBAccessibilityError.closedElement(operation: "read from")
    }
    guard let value = Self.stringValue(forKey: key, from: element) else {
      throw FBAccessibilityError.noStringValue(key: key.rawValue)
    }
    return value
  }

  // MARK: - Actions

  func sliderAdjust(_ action: FBSimulatorSliderAction, deadline: Double) throws {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "adjust slider") }
    try element.axSliderAdjust(action, deadline: deadline)
  }

  func sliderCapabilityData() throws -> Data {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "read capabilities from") }
    return try element.axSliderCapabilityData(token: request.token)
  }

  /// Perform an unconditional accessibility tap (AXPress) without any label verification.
  public func tap() throws {
    if closed {
      throw FBAccessibilityError.closedElement(operation: "tap")
    }
    let actionNames = element.axActionNames()
    guard actionNames.contains("AXPress") else {
      throw FBAccessibilityError.pressUnsupported(supportedActions: FBCollectionInformation.oneLineDescription(from: actionNames))
    }
    guard element.axPerformPress() else {
      throw FBAccessibilityError.pressFailed
    }
  }

  /// Perform an accessibility scroll on the element.
  public func scroll(with direction: FBAccessibilityScrollDirection) throws {
    if closed {
      throw FBAccessibilityError.closedElement(operation: "scroll")
    }
    element.axScroll(direction)
  }

  /// Set the accessibility value of the element (e.g., text field content, slider position).
  public func setValue(_ value: Any) throws {
    if closed {
      throw FBAccessibilityError.closedElement(operation: "set value on")
    }
    element.axSetValue(value)
  }

  // MARK: - Descendant search (ownership-transferring)

  /// Searches the accessibility tree rooted at this element for a descendant
  /// matching the given value/key. If found, ownership of the request token is
  /// transferred to a new handle wrapping the found element, and the receiver is
  /// closed without popping. If not found, the receiver is closed and an error
  /// is thrown.
  public func findElement(withValue value: String, forKey key: FBAXSearchableKey, depth: UInt) throws -> FBAccessibilityElement {
    guard let found = Self.findElement(withValue: value, forKey: key, in: element, token: request.token, remainingDepth: depth) else {
      close()
      throw FBAccessibilityError.elementNotFound(key: key.rawValue, value: value, depth: depth)
    }
    assert(!closed, "Cannot transfer ownership from a closed element")
    guard let simulator else {
      throw FBAccessibilityError.simulatorDeallocated
    }
    let newHandle = FBAccessibilityElement(element: found, request: request, dispatcher: dispatcher, simulator: simulator)
    closed = true
    return newHandle
  }

  /// Selected slider handles use exact selectors. Uniqueness precedes role filtering.
  /// The existing substring search remains unchanged for its current callers.
  func findSliderElement(matching selection: FBSimulatorSliderSelection, depth: UInt, deadline: Double) throws -> FBAccessibilityElement {
    guard !closed else { throw FBAccessibilityError.closedElement(operation: "select exact slider") }
    var found: FBAXPlatformElement?
    do {
      try Self.findSliderElement(matching: selection, in: element, token: request.token, remainingDepth: depth,
        deadline: deadline, found: &found)
      guard let found else { throw FBSimulatorSliderError.invalidSelection }
      guard let simulator else { throw FBAccessibilityError.simulatorDeallocated }
      let handle = FBAccessibilityElement(element: found, request: request, dispatcher: dispatcher, simulator: simulator)
      closed = true
      return handle
    } catch {
      close()
      throw error
    }
  }

  static func findSliderElement(matching selection: FBSimulatorSliderSelection, in element: FBAXPlatformElement,
    token: String, remainingDepth: UInt, deadline: Double, found: inout FBAXPlatformElement?) throws {
    try FBSimulatorSliderEndpointController.check(deadline)
    element.axSetBridgeDelegateToken(token)
    let matches: Bool
    switch selection {
    case .identifier(let identifier): matches = element.axIdentifier() == identifier
    case .label(let label): matches = FBSimulatorAXSelector.matchesLabel(element.axLabel(), query: label)
    }
    if matches {
      guard found == nil else { throw FBSimulatorSliderError.invalidSelection }
      found = element
    }
    try FBSimulatorSliderEndpointController.check(deadline)
    guard remainingDepth > 0 else { return }
    for child in element.axChildren() {
      try findSliderElement(matching: selection, in: child, token: token, remainingDepth: remainingDepth - 1,
        deadline: deadline, found: &found)
    }
    try FBSimulatorSliderEndpointController.check(deadline)
  }

  // MARK: - Private helpers

  private static func stringValue(forKey key: FBAXSearchableKey, from element: FBAXPlatformElement) -> String? {
    switch key {
    case .label:
      return element.axLabel()
    case .uniqueID:
      return element.axIdentifier()
    case .value:
      return element.axValue() as? String
    case .title:
      return element.axTitle()
    case .role:
      return element.axRole()
    case .roleDescription:
      return element.axRoleDescription()
    case .subrole:
      return element.axSubrole()
    case .help:
      return element.axHelp()
    case .placeholder:
      return element.axPlaceholderValue()
    }
  }

  private static func findElement(withValue value: String, forKey key: FBAXSearchableKey, in element: FBAXPlatformElement, token: String, remainingDepth: UInt) -> FBAXPlatformElement? {
    element.axSetBridgeDelegateToken(token)
    if let propertyValue = stringValue(forKey: key, from: element), propertyValue.contains(value) {
      return element
    }
    if remainingDepth == 0 {
      return nil
    }
    for child in element.axChildren() {
      child.axSetBridgeDelegateToken(token)
      if let found = findElement(withValue: value, forKey: key, in: child, token: token, remainingDepth: remainingDepth - 1) {
        return found
      }
    }
    return nil
  }
}

/// One current native single-child Button chain. It sends no input and owns no session.
/// The enclosing worker keeps its root request registered until final admission returns.
final class FBAXButtonLeafAdmission {
  private struct Match {
    let element: AXPMacPlatformElement
    let path: [Int]
    let children: [AXPMacPlatformElement]
  }
  private let leaf: AXPMacPlatformElement
  private let chain: [AXPMacPlatformElement]
  private let rootToken: String
  private let expected: FBSimulatorAXNode
  private let budget: FBAXAcquisitionBudget
  private let pid: Int32
  private let objectID: UInt64
  private let rawData: Data?
  private let frame: CGRect
  private var pointSelection: FBAXButtonChainPointSelection

  init(root: FBAXPlatformElement, token: String, expected: FBSimulatorAXNode,
    matchingCount: Int, budget: FBAXAcquisitionBudget) throws {
    guard let root = root as? AXPMacPlatformElement, expected.type == "Button",
          expected.children.isEmpty, let identifier = expected.identifier, !identifier.isEmpty,
          let pid = expected.pid, pid > 0, let expectedFrame = expected.frame, matchingCount > 1 else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    var matches: [Match] = []
    var retained: [AXPMacPlatformElement] = []
    var edges = 0
    func walk(_ node: AXPMacPlatformElement, path: [Int], ancestors: Set<ObjectIdentifier>) throws {
      try budget.check(); try Task.checkCancellation()
      let identity = ObjectIdentifier(node)
      guard path.count <= 33, retained.count < 512, !ancestors.contains(identity) else {
        throw FBSimulatorAXTargetError.targetMismatch
      }
      retained.append(node); node.axSetBridgeDelegateToken(token)
      guard let rawChildren = node.accessibilityChildren(), rawChildren.count <= 1024 else {
        throw FBSimulatorAXTargetError.targetMismatch
      }
      let children = try rawChildren.map { child -> AXPMacPlatformElement in
        guard let value = child as? AXPMacPlatformElement else { throw FBSimulatorAXTargetError.targetMismatch }
        return value
      }
      if node.axIdentifier() == identifier { matches.append(Match(element: node, path: path, children: children)) }
      var next = ancestors; next.insert(identity)
      for (index, child) in children.enumerated() {
        edges += 1
        guard edges <= 1024 else { throw FBSimulatorAXTargetError.targetMismatch }
        try walk(child, path: path + [index], ancestors: next)
      }
    }
    try walk(root, path: [0], ancestors: [])
    guard matches.count == matchingCount, let last = matches.last, last.children.isEmpty,
          let translation = last.element.translation, translation.pid == pid, translation.objectID > 0 else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    let frame = last.element.axFrame()
    guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
          frame.width > 0, frame.height > 0, frame == expectedFrame else { throw FBSimulatorAXTargetError.invalidPoint }
    for (index, match) in matches.enumerated() {
      let node = match.element
      node.axSetBridgeDelegateToken(token)
      guard node.axTranslationPid == pid, node.axRole() == "AXButton", node.axIdentifier() == identifier,
            node.axLabel() == expected.label, node.axSubrole() == expected.subrole,
            try Self.value(node) == expected.value, node.axFrame() == frame,
            node.axIsEnabled(), !node.axIsHidden() else { throw FBSimulatorAXTargetError.targetMismatch }
      if index + 1 < matches.count {
        guard match.children.count == 1, matches[index + 1].path == match.path + [0] else {
          throw FBSimulatorAXTargetError.targetMismatch
        }
      }
    }
    let members = try matches.map { match -> FBAXButtonChainPointSelection.Identity in
      guard let identity = match.element.translation else { throw FBSimulatorAXTargetError.targetMismatch }
      return .init(pid: identity.pid, objectID: identity.objectID, rawData: identity.rawElementData)
    }
    let traversal = retained.map { node -> FBAXButtonChainPointSelection.Identity? in
      guard let identity = node.translation else { return nil }
      return .init(pid: identity.pid, objectID: identity.objectID, rawData: identity.rawElementData)
    }
    pointSelection = try FBAXButtonChainPointSelection(members: members, traversal: traversal)
    self.leaf = last.element; chain = matches.map(\.element)
    rootToken = token; self.expected = expected; self.budget = budget
    self.pid = pid; objectID = translation.objectID; rawData = translation.rawElementData; self.frame = frame
    try requireCurrentLeaf()
  }

  private static func value(_ element: AXPMacPlatformElement) throws -> FBSimulatorAXValue? {
    guard let raw = element.axValue(), !(raw is NSNull) else { return nil }
    let bytes = try JSONSerialization.data(withJSONObject: [raw])
    return try JSONDecoder().decode([FBSimulatorAXValue].self, from: bytes).first
  }

  func requireCurrentLeaf() throws {
    try budget.check(); try Task.checkCancellation()
    for (index, node) in chain.enumerated() {
      node.axSetBridgeDelegateToken(rootToken)
      guard let identity = node.translation else { throw FBSimulatorAXTargetError.targetMismatch }
      try pointSelection.requireCurrent(.init(pid: identity.pid, objectID: identity.objectID,
        rawData: identity.rawElementData), at: index)
      guard node.axTranslationPid == pid, node.axRole() == "AXButton",
            node.axIdentifier() == expected.identifier, node.axLabel() == expected.label,
            node.axSubrole() == expected.subrole, try Self.value(node) == expected.value,
            node.axFrame() == frame, node.axIsEnabled(), !node.axIsHidden(),
            let children = node.accessibilityChildren() else { throw FBSimulatorAXTargetError.targetMismatch }
      if index + 1 < chain.count {
        guard children.count == 1, let child = children.first as? AXPMacPlatformElement,
              let actual = child.translation, let next = chain[index + 1].translation,
              actual.pid == pid, actual.pid == next.pid, actual.objectID > 0,
              actual.objectID == next.objectID, child.isEqual(chain[index + 1]) else {
          throw FBSimulatorAXTargetError.targetMismatch
        }
      } else if !children.isEmpty { throw FBSimulatorAXTargetError.targetMismatch }
      try budget.check(); try Task.checkCancellation()
    }
    leaf.axSetBridgeDelegateToken(rootToken)
    guard let translation = leaf.translation, translation.pid == pid, translation.objectID == objectID,
          translation.rawElementData == rawData, leaf.axRole() == "AXButton",
          leaf.axIdentifier() == expected.identifier, leaf.axLabel() == expected.label,
          leaf.axSubrole() == expected.subrole, try Self.value(leaf) == expected.value,
          leaf.axFrame() == frame, leaf.axIsEnabled(), !leaf.axIsHidden(),
          let children = leaf.accessibilityChildren(), children.isEmpty else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    try budget.check()
  }

  func validatePoint(_ element: FBAXPlatformElement, token: String, orientedPoint: CGPoint) throws {
    try requireCurrentLeaf()
    guard let point = element as? AXPMacPlatformElement else { throw FBSimulatorAXTargetError.targetMismatch }
    point.axSetBridgeDelegateToken(token)
    guard let translation = point.translation else { throw FBSimulatorAXTargetError.targetMismatch }
    let identity = FBAXButtonChainPointSelection.Identity(pid: translation.pid,
      objectID: translation.objectID, rawData: translation.rawElementData)
    let index = try pointSelection.memberIndex(for: identity)
    if index == chain.count - 1 {
      // Preserve every original exact-leaf check.
      guard translation.pid == pid, translation.objectID == objectID,
            translation.rawElementData == rawData, point.isEqual(leaf), leaf.isEqual(point),
            point.axRole() == "AXButton", point.axIdentifier() == expected.identifier,
            point.axLabel() == expected.label, point.axFrame() == frame, frame.contains(orientedPoint) else {
        throw FBSimulatorAXTargetError.targetMismatch
      }
    } else {
      // Distinct native members are not aliases. Only one member of the already
      // qualified current chain may own this point, and confirmation must agree.
      let member = chain[index]
      guard point.isEqual(member), member.isEqual(point),
            point.axRole() == "AXButton", point.axIdentifier() == expected.identifier,
            point.axLabel() == expected.label, point.axSubrole() == expected.subrole,
            try Self.value(point) == expected.value, point.axFrame() == frame,
            point.axIsEnabled(), !point.axIsHidden(), frame.contains(orientedPoint) else {
        throw FBSimulatorAXTargetError.targetMismatch
      }
    }
    try budget.check(); try Task.checkCancellation()
    try pointSelection.pinMember(at: index)
  }
}
