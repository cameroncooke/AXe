@_implementationOnly import AccessibilityPlatformTranslation
import AppKit
import Foundation

/// Read-only evidence. These values never select, merge, or authorize an element.
public struct FBSimulatorAXIdentityDiagnostic: Sendable {
  public let observation: FBSimulatorHIDSessionObservation
  public let point: CGPoint
  public let nativePoint: CGPoint
  public let expectedPID: Int32
  public let foregroundPIDBefore: Int32
  public let foregroundPIDAfter: Int32
  public let evidenceJSON: Data
  public let routingEvidenceJSON: Data
  public let startedUptime: Double
  public let finishedUptime: Double

  /// One explicit point and one bounded recursive tree. Existing bridge only.
  /// No grid, AX action, HID, retry, or change to request resolving behavior.
  public static func read(for simulator: FBSimulator, expectedPID: Int32,
    point: CGPoint, identifiers: [String], labels: [String] = [],
    observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    timeoutSeconds: Double = 8, pointContextMode: FBSimulatorAXPointContextMode = .absent) async throws -> Self {
    guard expectedPID > 0, timeoutSeconds.isFinite, timeoutSeconds > 0,
          timeoutSeconds <= 8, identifiers.count + labels.count <= 8,
          (identifiers + labels).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let size = observation.displayContext.logicalSize
    guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
          point.x < size.width, point.y < size.height else {
      throw FBSimulatorAXTargetError.invalidPoint
    }
    let budget = FBAXAcquisitionBudget(seconds: timeoutSeconds)
    let reservation = try FBAXTargetReservation.acquire()
    defer { withExtendedLifetime(reservation) {} }
    return try await withTaskCancellationHandler(operation: {
      try await FBSimulatorAXWorker.shared.readIdentity(for: simulator,
        expectedPID: expectedPID, point: point, identifiers: identifiers, labels: labels,
        observation: observation, provider: freshnessProvider, budget: budget, pointContextMode: pointContextMode)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

/// Preserves stopped bridge evidence without transporting framework handles.
public struct FBSimulatorAXIdentityReadFailure: Error, Sendable {
  public let failureDescription: String
  public let routingEvidenceJSON: Data
}

struct FBAXIdentityContext: Encodable, Sendable {
  let source: String
  let recursivePath: [Int]?
  let wrapperOrdinal: Int
  let translationPID: String?
  let translationObjectID: String?
  let windowContext: FBAXIdentityAttribute
  let display: FBAXIdentityAttribute
  let ownershipAccepted = false
}

private struct FBAXIdentityNode: Encodable {
  let wrapperOrdinal: Int
  let translationPID: String?
  let translationObjectID: String?
  let isApplicationElement: Bool?
  let role: String?
  let identifier: String?
  let label: String?
  let rawPlatformFrame: CGRect
  let clippedTextFields: [String]
}

private struct FBAXIdentityOccurrence: Encodable {
  let path: [Int]
  let node: FBAXIdentityNode
  let matched: Bool
  let childrenState: String
  let returnedChildCount: Int?
}

private struct FBAXIdentityRemote: Encodable {
  let presenterPID: String?
  let remoteElementPID: String?
  let isRemoteElement: Bool?
  let clientSideRemoteElement: Bool?
  let unavailableSelectors: [String]
}

private struct FBAXIdentityParent: Encodable {
  let index: Int
  let node: FBAXIdentityNode
  let declaredRemote: FBAXIdentityRemote
}

private struct FBAXIdentityChain: Encodable {
  let source: String
  let recursivePath: [Int]?
  let nodes: [FBAXIdentityParent]
  let endReason: String
}

private struct FBAXIdentityComparison: Encodable {
  let recursivePath: [Int]
  let recursiveWrapperOrdinal: Int
  let pointWrapperOrdinal: Int
  let sameRetainedWrapper: Bool
  let sameTranslationPIDAndObjectID: Bool?
  let translationIsEqualForward: Bool?
  let platformIsEqualForward: Bool
  let sameRawElementData: Bool?
  let meaning = "Comparison evidence only; no ownership, alias or display conclusion."
}

private struct FBAXIdentityEvidence: Encodable {
  let schema = 4
  let nodeContexts: [FBAXIdentityContext]
  let maximumContextNodes = 18
  let maximumRawAttributeRequests = 37
  let registeredHost: FBAXRegisteredHostEvidence
  let contextLimit = "Raw guest values can be cached or overridden. They do not prove current display ownership. Unlisted nodes were not queried."
  let recursive: [FBAXIdentityOccurrence]
  let parentChains: [FBAXIdentityChain]
  let point: FBAXIdentityNode
  let comparisons: [FBAXIdentityComparison]
  let maximumNodes = 512
  let maximumDepth = 32
  let maximumMatches = 16
  let maximumParents = 8
  let maximumRetainedWrappers = 1024
  let recursiveTruncated: Bool
  let unsupportedChildPaths: [[Int]]
  let maximumChildEdges = 1024
  let matchedOccurrences: Int
  let matchDetailsTruncated: Bool
  let ownershipAccepted = false
  let inputDispatched = false
  let rawValueLimit = "Zero/false can include an empty framework response. Nil parent has an unknown cause."
  let equalityLimit = "Installed translation equality compares objectID only; platform equality may compare raw data. Neither authorizes ownership."
}

/// All platform references remain on the existing serial AX worker. Retaining
/// wrappers for this operation prevents address reuse from changing ordinals.
/// A repeated wrapper on another branch remains a separate occurrence.
final class FBAXIdentityRecorder {
  private struct Match {
    let path: [Int]
    let element: AXPMacPlatformElement
    let token: String
  }
  private let budget: FBAXAcquisitionBudget
  private let routing: FBAXIdentityRoutingRecorder
  private var rootMatch: Match?
  private let earlyRootContext: FBAXIdentityContext?
  private let expectedHostPID: Int32?
  private let identifiers: Set<String>
  private let labels: Set<String>
  private var retained: [AXPMacPlatformElement] = []
  private var ordinals: [ObjectIdentifier: Int] = [:]
  private var occurrences: [FBAXIdentityOccurrence] = []
  private var matches: [Match] = []
  private var matchedOccurrences = 0
  private var truncated = false
  private var childEdges = 0
  private var unsupportedChildPaths: [[Int]] = []

  init(budget: FBAXAcquisitionBudget, identifiers: [String], labels: [String], routing: FBAXIdentityRoutingRecorder,
       earlyRootContext: FBAXIdentityContext? = nil, expectedHostPID: Int32? = nil) {
    self.expectedHostPID = expectedHostPID
    self.earlyRootContext = earlyRootContext
    self.routing = routing
    self.budget = budget; self.identifiers = Set(identifiers); self.labels = Set(labels)
  }

  private func check() throws { try budget.check(); try Task.checkCancellation() }

  private func ordinal(_ element: AXPMacPlatformElement) throws -> Int {
    let identity = ObjectIdentifier(element)
    if let result = ordinals[identity] { return result }
    guard retained.count < 1024 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    let result = retained.count
    retained.append(element); ordinals[identity] = result
    return result
  }

  private func node(_ element: AXPMacPlatformElement, token: String) throws -> FBAXIdentityNode {
    try check(); element.axSetBridgeDelegateToken(token)
    let ordinal = try ordinal(element)
    var clipped: [String] = []
    func bounded(_ text: String?, _ field: String) -> String? {
      guard let text else { return nil }
      guard text.count <= 1024 else { clipped.append(field); return String(text.prefix(1024)) }
      return text
    }
    let role = bounded(element.axRole(), "role"); try check()
    let identifier = bounded(element.axIdentifier(), "identifier"); try check()
    let label = bounded(element.axLabel(), "label"); try check()
    let frame = element.axFrame(); try check()
    return .init(wrapperOrdinal: ordinal, translationPID: element.translation.map { String($0.pid) },
      translationObjectID: element.translation.map { String($0.objectID) },
      isApplicationElement: element.translation?.isApplicationElement,
      role: role, identifier: identifier, label: label, rawPlatformFrame: frame,
      clippedTextFields: clipped)
  }

  func recursive(_ root: FBAXPlatformElement, token: String) throws {
    guard let native = root as? AXPMacPlatformElement else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    rootMatch = .init(path: [0], element: native, token: token)
    try walk(native, token: token, path: [0], ancestors: [])
  }

  private func walk(_ element: AXPMacPlatformElement, token: String,
                    path: [Int], ancestors: Set<ObjectIdentifier>) throws {
    try check()
    guard occurrences.count < 512 else { truncated = true; return }
    let value = try node(element, token: token)
    let matched = value.identifier.map { identifiers.contains($0) } == true ||
      value.label.map { labels.contains($0) } == true
    if matched {
      matchedOccurrences += 1
      if matches.count < 16 { matches.append(.init(path: path, element: element, token: token)) }
    }
    let identity = ObjectIdentifier(element)
    guard !ancestors.contains(identity) else {
      occurrences.append(.init(path: path, node: value, matched: matched,
        childrenState: "ancestorWrapperCycle", returnedChildCount: nil)); return
    }
    guard path.count <= 32 else {
      truncated = true
      occurrences.append(.init(path: path, node: value, matched: matched,
        childrenState: "depthLimit", returnedChildCount: nil)); return
    }
    // Preserve native child positions, including unsupported types. No compactMap.
    let returnedChildren = element.accessibilityChildren(); try check()
    guard let children = returnedChildren else {
      truncated = true
      occurrences.append(.init(path: path, node: value, matched: matched,
        childrenState: "nilChildrenUnknownCause", returnedChildCount: nil)); return
    }
    occurrences.append(.init(path: path, node: value, matched: matched,
      childrenState: children.isEmpty ? "readEmpty" : "read", returnedChildCount: children.count))
    var nextAncestors = ancestors; nextAncestors.insert(identity)
    for (index, child) in children.enumerated() {
      try check()
      guard occurrences.count < 512, childEdges < 1024 else { truncated = true; break }
      childEdges += 1
      guard let native = child as? AXPMacPlatformElement else {
        truncated = true; unsupportedChildPaths.append(path + [index]); continue
      }
      try walk(native, token: token, path: path + [index], ancestors: nextAncestors)
    }
  }

  private func remote(_ element: AXPMacPlatformElement) throws -> FBAXIdentityRemote {
    var unavailable: [String] = []
    func available(_ name: String) -> Bool {
      let result = element.responds(to: NSSelectorFromString(name))
      if !result { unavailable.append(name) }; return result
    }
    try check()
    let presenter = available("accessibilityPresenterProcessIdentifier") ? String(element.accessibilityPresenterProcessIdentifier()) : nil
    try check()
    let remotePID = available("_remoteElementPid") ? String(element._remoteElementPid()) : nil
    try check()
    let isRemote = available("_isRemoteElement") ? element._isRemoteElement() : nil
    try check()
    let clientSide = available("_clientSideRemoteElement") ? element._clientSideRemoteElement() : nil
    try check()
    return .init(presenterPID: presenter, remoteElementPID: remotePID, isRemoteElement: isRemote,
      clientSideRemoteElement: clientSide, unavailableSelectors: unavailable)
  }

  private func parents(_ initial: AXPMacPlatformElement, token: String,
                       source: String, path: [Int]?) throws -> FBAXIdentityChain {
    var current = initial
    var seen = Set<ObjectIdentifier>()
    var values: [FBAXIdentityParent] = []
    var endReason = "parentLimit"
    for index in 0...8 {
      try check()
      // Only retained wrapper identity stops a cycle. Repeated translation values
      // are recorded, not treated as proof that the parent is the same object.
      guard seen.insert(ObjectIdentifier(current)).inserted else { endReason = "wrapperCycle"; break }
      let value = try node(current, token: token)
      values.append(.init(index: index, node: value, declaredRemote: try remote(current)))
      guard index < 8 else { break }
      guard current.responds(to: NSSelectorFromString("accessibilityParent")) else {
        endReason = "parentSelectorUnavailable"; break
      }
      let parent = current.accessibilityParent(); try check()
      guard let parent else { endReason = "nilParentUnknownCause"; break }
      guard let typed = parent as? AXPMacPlatformElement else {
        endReason = "unsupportedParentType"; break
      }
      current = typed
    }
    return .init(source: source, recursivePath: path, nodes: values, endReason: endReason)
  }

  func attribute(_ element: AXPMacPlatformElement, token: String,
                         attribute: UInt64, guestAttribute: UInt32?) throws -> FBAXIdentityAttribute {
    try check()
    element.axSetBridgeDelegateToken(token)
    let first = routing.snapshot().attemptedReceipts + 1
    guard let translation = element.translation,
          let translator = AXPTranslator.sharedInstance() as? AXPTranslator,
          let request = AXPTranslatorRequest.request(withTranslation: translation) as? AXPTranslatorRequest else {
      return .init(state: "requestUnavailable", nativeResponsePresent: nil, translatorResponsePresent: false, responseError: nil,
        responseAttribute: nil, value: .inspect(nil), firstBridgeSequence: first,
        lastBridgeSequence: first - 1, bridgeObserved: false)
    }
    translation.bridgeDelegateToken = token
    request.requestType = 2
    request.attributeType = attribute
    if let guestAttribute { request.parameters = ["parameter": NSNumber(value: guestAttribute)] }
    let rawResponse = translator.sendRequest(request)
    let snapshot = routing.snapshot()
    let last = snapshot.attemptedReceipts
    // The bridge captures the actual native response. A translator can replace
    // a nil result; do not label that replacement as a native response.
    try check()
    let observed = snapshot.receipts.filter { $0.sequence >= first && $0.sequence <= last }
    guard observed.count == 1, let receipt = observed.first else {
      let state = last < first ? "noBridgeReceiptObserved" : snapshot.truncated ? "bridgeReceiptTruncated" : "multipleBridgeRequests"
      return .init(state: state, nativeResponsePresent: nil,
        translatorResponsePresent: rawResponse != nil, responseError: nil, responseAttribute: nil,
        value: .inspect(nil), firstBridgeSequence: first, lastBridgeSequence: last, bridgeObserved: last >= first)
    }
    return .init(state: receipt.outcome, nativeResponsePresent: receipt.reply?.nativeResponsePresent,
      translatorResponsePresent: rawResponse != nil, responseError: receipt.reply?.error,
      responseAttribute: receipt.reply?.attribute, value: receipt.reply?.rawValue ?? .inspect(nil),
      firstBridgeSequence: first, lastBridgeSequence: last, bridgeObserved: true)
  }

  private func context(_ match: Match, source: String) throws -> FBAXIdentityContext {
    let ordinal = try ordinal(match.element)
    let translation = match.element.translation
    let context = try attribute(match.element, token: match.token, attribute: 12, guestAttribute: nil)
    let display = try attribute(match.element, token: match.token, attribute: 63, guestAttribute: 2123)
    return .init(source: source, recursivePath: source == "point" ? nil : match.path,
      wrapperOrdinal: ordinal, translationPID: translation.map { String($0.pid) },
      translationObjectID: translation.map { String($0.objectID) },
      windowContext: context, display: display)
  }

  static func readRootContext(_ root: FBAXPlatformElement, token: String,
                              budget: FBAXAcquisitionBudget, routing: FBAXIdentityRoutingRecorder) throws -> FBAXIdentityContext {
    guard let native = root as? AXPMacPlatformElement else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    // This temporary recorder releases all retained wrappers before the point await.
    let recorder = FBAXIdentityRecorder(budget: budget, identifiers: [], labels: [], routing: routing)
    return try recorder.context(.init(path: [0], element: native, token: token), source: "root")
  }

  func finish(point: FBAXPlatformElement, token: String) throws -> Data {
    guard let native = point as? AXPMacPlatformElement else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let pointNode = try node(native, token: token)
    var contexts: [FBAXIdentityContext] = []
    guard let earlyRootContext, let rootMatch,
          earlyRootContext.translationPID == rootMatch.element.translation.map({ String($0.pid) }),
          earlyRootContext.translationObjectID == rootMatch.element.translation.map({ String($0.objectID) }) else {
      throw FBAXPointContextError.rejected("Root identity changed before evidence serialization")
    }
    contexts.append(earlyRootContext)
    contexts.append(try context(.init(path: [], element: native, token: token), source: "point"))
    for match in matches { contexts.append(try context(match, source: "recursiveMatch")) }
    var chains = [try parents(native, token: token, source: "point", path: nil)]
    // Capture the normal presenter accessor before the separate raw request.
    // The accessor can be cached; only attribute 65's native receipt is fresh evidence.
    let cachedPresenter = chains.first?.nodes.first?.declaredRemote.presenterPID
    guard let expectedHostPID else { throw FBSimulatorAXSnapshotError.invalidSelection }
    let rawPresenter = try attribute(native, token: token, attribute: 65, guestAttribute: nil)
    let registeredHost = FBAXRegisteredHostEvidence.evaluate(raw: rawPresenter,
      cached: cachedPresenter, expectedPID: expectedHostPID)
    var comparisons: [FBAXIdentityComparison] = []
    for match in matches {
      try check()
      match.element.axSetBridgeDelegateToken(match.token); native.axSetBridgeDelegateToken(token)
      let left = match.element.translation; let right = native.translation
      let sameTuple: Bool? = left.flatMap { l in right.map { l.pid == $0.pid && l.objectID == $0.objectID } }
      let translationEqual: Bool? = left.flatMap { l in right.map { l.isEqual($0) } }
      let sameRaw: Bool?
      if let leftData = left?.rawElementData, let rightData = right?.rawElementData {
        sameRaw = leftData == rightData
      } else { sameRaw = nil }
      let platformEqual = match.element.isEqual(native); try check()
      comparisons.append(.init(recursivePath: match.path,
        recursiveWrapperOrdinal: try ordinal(match.element), pointWrapperOrdinal: pointNode.wrapperOrdinal,
        sameRetainedWrapper: match.element === native, sameTranslationPIDAndObjectID: sameTuple,
        translationIsEqualForward: translationEqual, platformIsEqualForward: platformEqual,
        sameRawElementData: sameRaw))
      chains.append(try parents(match.element, token: match.token, source: "recursiveMatch", path: match.path))
    }
    let result = FBAXIdentityEvidence(nodeContexts: contexts, registeredHost: registeredHost, recursive: occurrences, parentChains: chains, point: pointNode,
      comparisons: comparisons, recursiveTruncated: truncated, unsupportedChildPaths: unsupportedChildPaths,
      matchedOccurrences: matchedOccurrences,
      matchDetailsTruncated: matchedOccurrences > matches.count)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(result); try check()
    guard data.count <= 2_000_000 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    return data
  }
}

extension FBSimulatorAXWorker {
  func readIdentity(for simulator: FBSimulator, expectedPID: Int32,
    point: CGPoint, identifiers: [String], labels: [String],
    observation: FBSimulatorHIDSessionObservation,
    provider: any FBSimulatorHIDFreshnessProvider, budget: FBAXAcquisitionBudget,
    pointContextMode: FBSimulatorAXPointContextMode
  ) async throws -> FBSimulatorAXIdentityDiagnostic {
    let started = ProcessInfo.processInfo.systemUptime
    let routing = FBAXIdentityRoutingRecorder()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    do {
      try budget.check(); try Task.checkCancellation()
      try await validateSelection(simulator, observation: observation, provider: provider)
      try budget.check()
      let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
      if let translator = AXPTranslator.sharedInstance() as? AXPTranslator {
        routing.setMode(translator.requestResolvingBehavior, beforeRead: true)
      }
      let rootRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      rootRequest.acquisitionBudget = budget
      rootRequest.identityRoutingRecorder = routing
      rootRequest.identityRoutingSource = "root"
      let root = try await commands.accessibilityElementForAcquisition(request: rootRequest, worker: self)
      defer { root.close() }
      let beforePID = root.acquisitionPID
      guard beforePID == expectedPID else {
        throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: beforePID)
      }
      try budget.check()
      // All modes read root attribute 12 then 63 before the one point request.
      let rootContext = try root.identityRootContext(budget: budget, routing: routing)
      let transform = FBAXTranslationRequest(kind: .point(point), pointDisplayID: observation.axDisplayID,
        displayContext: observation.displayContext)
      let native = try transform.nativePoint(from: point)
      let pointRequest = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
        displayContext: observation.displayContext)
      pointRequest.acquisitionBudget = budget
      pointRequest.identityRoutingRecorder = routing
      pointRequest.identityRoutingSource = "point"
      let rootResponseValid = rootContext.windowContext.state == "nativeResponse" &&
        rootContext.windowContext.bridgeObserved && rootContext.windowContext.nativeResponsePresent == true &&
        rootContext.windowContext.translatorResponsePresent && rootContext.windowContext.responseError == "0" &&
        rootContext.windowContext.responseAttribute == "12"
      let pointGate = try FBAXPointContextGate(mode: pointContextMode,
        rootContext: rootContext.windowContext.value, rootResponseValid: rootResponseValid,
        token: pointRequest.token, point: native, displayID: observation.axDisplayID)
      pointRequest.identityPointContextGate = pointGate
      routing.attachPointContext(pointGate)
      let hit = try await commands.accessibilityElementForAcquisition(request: pointRequest, worker: self)
      defer { hit.close() }
      try pointGate.requireComplete()
      // This synchronous scope owns and releases every retained wrapper before the
      // next await. Only immutable bytes leave it. Both request tokens remain live.
      let data: Data = try {
        let recorder = FBAXIdentityRecorder(budget: budget, identifiers: identifiers, labels: labels, routing: routing, earlyRootContext: rootContext, expectedHostPID: expectedPID)
        try root.recordIdentityTree(recorder)
        return try hit.finishIdentityEvidence(recorder)
      }()
      try pointGate.requireComplete()
      hit.close(); root.close()
      let afterRequest = FBAXTranslationRequest(kind: .frontmostApplication,
        pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
      afterRequest.acquisitionBudget = budget
      afterRequest.identityRoutingRecorder = routing
      afterRequest.identityRoutingSource = "finalForeground"
      let after = try await commands.accessibilityElementForAcquisition(request: afterRequest, worker: self)
      let afterPID = after.acquisitionPID; after.close()
      guard afterPID == expectedPID else {
        throw FBSimulatorAXTargetError.wrongPID(expected: expectedPID, actual: afterPID)
      }
      try budget.check()
      try await validateSelection(simulator, observation: observation, provider: provider)
      try budget.check(); try Task.checkCancellation()
      if let translator = AXPTranslator.sharedInstance() as? AXPTranslator {
        routing.setMode(translator.requestResolvingBehavior, beforeRead: false)
      }
      let routingData = try encoder.encode(routing.snapshot())
      return .init(observation: observation, point: point, nativePoint: native,
        expectedPID: expectedPID, foregroundPIDBefore: beforePID, foregroundPIDAfter: afterPID,
        evidenceJSON: data, routingEvidenceJSON: routingData,
        startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime)
    } catch {
      // No further framework reads after a stop; after-mode stays absent.
      throw FBSimulatorAXIdentityReadFailure(failureDescription: String(reflecting: error),
        routingEvidenceJSON: try encoder.encode(routing.snapshot()))
    }
  }
}
