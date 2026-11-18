@_implementationOnly import AccessibilityPlatformTranslation
import CoreGraphics
import FBControlCore
import Foundation

public enum FBSimulatorAXWebError: Error, Sendable {
  /// Web controls are read in the display's portrait orientation only.
  case unsupportedRotation
  /// The element at the point is not in a hosted web page.
  case notWebContent
}

/// Where to hit-test for hosted web views.
enum FBAXWebContentProbePlan {
  /// The centres of a lattice of cells about `spacing` points wide, nearest the centre of
  /// `bounds` first. A web view usually fills most of the screen, so the first point finds it.
  static func points(in bounds: CGRect, spacing: CGFloat) -> [CGPoint] {
    guard spacing.isFinite, spacing > 0, !bounds.isNull, !bounds.isInfinite,
          bounds.width > 0, bounds.height > 0 else { return [] }
    let columns = max(1, Int((bounds.width / spacing).rounded(.down)))
    let rows = max(1, Int((bounds.height / spacing).rounded(.down)))
    let cell = CGSize(width: bounds.width / CGFloat(columns), height: bounds.height / CGFloat(rows))
    var points: [CGPoint] = []
    points.reserveCapacity(columns * rows)
    for row in 0..<rows {
      for column in 0..<columns {
        points.append(CGPoint(x: bounds.minX + (CGFloat(column) + 0.5) * cell.width,
                              y: bounds.minY + (CGFloat(row) + 0.5) * cell.height))
      }
    }
    let centre = CGPoint(x: bounds.midX, y: bounds.midY)
    func distance(_ point: CGPoint) -> CGFloat {
      let dx = point.x - centre.x, dy = point.y - centre.y
      return dx * dx + dy * dy
    }
    // Ties keep reading order, so the plan is the same on every run.
    return points.enumerated().sorted {
      let left = distance($0.element), right = distance($1.element)
      return left == right ? $0.offset < $1.offset : left < right
    }.map(\.element)
  }
}

/// Rules for reading the controls of hosted web pages (WKWebView, Safari, SFSafariViewController
/// and ASWebAuthenticationSession). A page runs in a WebContent process that the application
/// tree never reaches; a hit test inside it does.
public enum FBAXWebControlPolicy {
  /// The process that renders a hosted web page.
  static let webContentBundleIdentifier = "com.apple.WebKit.WebContent"
  /// The process that draws the browser controls of SFSafariViewController and
  /// ASWebAuthenticationSession sheets over the app. Its elements report the short process name
  /// for the bundle attribute; the bundle ID is accepted too. Its bottom toolbar (Back, Forward,
  /// Share, Reload, Open in Safari) is read. Its top bar is not: on iOS 27.2 a hit test anywhere
  /// on it, Close and the page menu included, answers an address label with no container.
  static let safariChromeProcessNames: Set<String> = ["SafariViewService", "com.apple.SafariViewService"]
  /// What a control was found in: a web page, or the Safari sheet's own controls.
  public static let pageDiscovery = "web"
  public static let chromeDiscovery = "webChrome"
  /// AXPTranslator attribute request (request type 2) whose attribute type 63 passes the
  /// number in `parameters["parameter"]` to the simulator as an iOS accessibility attribute.
  static let attributeRequestType: UInt64 = 2
  static let guestAttributeType: UInt64 = 63
  /// iOS attribute: the bundle identifier of the process that owns the element.
  static let bundleIdentifierAttribute: UInt32 = 3041
  /// iOS attribute: the element's nearest container. On a web page it returns the enclosing
  /// region, then that region's container, and nothing once it reaches the page's root.
  static let containerAttribute: UInt32 = 2202
  static let maximumContainerDepth = 64
  /// Distance between the hit tests that look for a page. A web view smaller than this in
  /// both directions can be missed.
  static let probeSpacing: CGFloat = 80
  /// A hit whose page root cannot be found is tried again at most this many times per process.
  static let maximumRootAttempts = 3
  /// A Safari sheet's toolbar is a root of its own (its container answers nothing above it);
  /// hits in the sheet are climbed this many times at most.
  static let maximumChromeAttempts = 40
  /// How long a web read keeps app Accessibility on for a page without a tree, and how often it
  /// reads the page meanwhile.
  static let loadedReadSeconds: Double = 2.5
  static let loadedReadInterval: Double = 0.15
  /// Unanswered bundle reads before a process is taken as neither a page nor a Safari sheet.
  static let maximumBundleReads = 3
  /// Time kept back from the session's deadline for ending it.
  static let loadedReadCleanupSeconds: Double = 0.5
  static let maximumPageNodes = 4096
  static let maximumPageDepth = 64
  static let maximumControls = 512

  /// AX roles that take input on a web page. Text inside a control is its label, so the walk
  /// does not descend into one.
  public static let controlRoles: Set<String> = [
    "AXLink", "AXButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    "AXCheckBox", "AXRadioButton", "AXSwitch", "AXPopUpButton", "AXMenuButton",
    "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
  ]

  /// The point a control is tapped at: the centre of its part on the screen. Nil when no
  /// usable part is on screen. Shared by discovery, which proves the control is the element
  /// at this point, and by the caller that taps it.
  public static func tapPoint(frame: CGRect, screen: CGRect) -> CGPoint? {
    let values = [frame.minX, frame.minY, frame.width, frame.height]
    guard values.allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else { return nil }
    let visible = frame.intersection(screen)
    guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
    return CGPoint(x: visible.midX, y: visible.midY)
  }

  /// A container is followed only while it is another real element of the process that was
  /// hit. Safari's own elements answer with elements of Safari, which are never walked as a page.
  static func acceptsContainer(hitPID: pid_t, currentObjectID: UInt64, containerPID: pid_t,
                               containerObjectID: UInt64) -> Bool {
    hitPID > 0 && containerPID == hitPID && containerObjectID != 0 && containerObjectID != currentObjectID
  }

  /// Whether the element at a control's tap point is that control: the control itself, content
  /// inside it (its text or image) that is not another control, or one of its two nearest
  /// containers that is not a control. WebKit answers a point on a link inside a heading (a
  /// news site's story headline) with the heading.
  static func hitShowsControl(hit: FBSimulatorAXNativeIdentity?, hitFrame: CGRect,
                              control: FBSimulatorAXNativeIdentity, controlFrame: CGRect,
                              controls: Set<FBSimulatorAXNativeIdentity>,
                              parents: [FBSimulatorAXNativeIdentity] = []) -> Bool {
    guard let hit, hit.pid == control.pid else { return false }
    if hit == control { return true }
    if controls.contains(hit) { return false }
    if parents.prefix(2).contains(hit) { return true }
    guard !hitFrame.isNull, hitFrame.width > 0, hitFrame.height > 0 else { return false }
    return controlFrame.insetBy(dx: -1, dy: -1).contains(hitFrame)
  }

  /// Where a keyboard's accessory bar is looked for: rows up to `accessoryBarSearchHeight` above
  /// the keys, which the suggestion bar can sit between.
  static let accessoryBarSearchHeight: CGFloat = 120
  static let accessoryBarProbeStep: CGFloat = 20
  static func accessoryBarPoints(keyboard: CGRect, screen: CGRect) -> [CGPoint] {
    let values = [keyboard.minX, keyboard.minY, keyboard.width, keyboard.height]
    guard values.allSatisfy(\.isFinite), keyboard.width > 0, keyboard.height > 0 else { return [] }
    var points: [CGPoint] = []
    var offset = accessoryBarProbeStep / 2
    while offset < accessoryBarSearchHeight {
      let y = keyboard.minY - offset
      if y > screen.minY, y < screen.maxY {
        points += [0.1, 0.5, 0.9].map { CGPoint(x: screen.minX + screen.width * $0, y: y) }
      }
      offset += accessoryBarProbeStep
    }
    return points
  }

  public static let textRole = "AXStaticText"
  /// Key of a listed control's dictionary: the container that answers a point read at its tap
  /// point, when that is not the control itself.
  public static let tapAnswerKey = "webTapAnswer"

  /// WebKit reports an ARIA option (`role="option"`, as in a search box's suggestions) with the
  /// static-text role but without the static-text trait that page text carries. Other clickable
  /// text, such as a `div` with a click handler, looks like any text and is not listed.
  static func isSelectableText(traits: [String]?) -> Bool {
    guard let traits, traits.contains("WebContent") else { return false }
    return !traits.contains("StaticText")
  }

  /// A page element WebKit reports with another role but the link trait: a link inside a
  /// heading (a news site's story headline) is an `AXHeading` with `Link`. Text inside a link
  /// carries the link trait too, with the static-text trait.
  static func isLinkElement(role: String?, traits: [String]?) -> Bool {
    guard let role, !controlRoles.contains(role), role != textRole, let traits else { return false }
    return traits.contains("Link") && !traits.contains("StaticText")
  }

  /// A key of the software keyboard, by its traits.
  static func isKeyboardKey(traits: [String]?) -> Bool {
    guard let traits else { return false }
    return traits.contains("KeyboardKey") || traits.contains("DeleteKey") || traits.contains("AutoCorrectCandidate")
  }

  /// Leaves that never hold controls: an empty children answer from one is final.
  static func mayHaveChildren(role: String?) -> Bool {
    !["AXStaticText", "AXImage", "AXHeading"].contains(role ?? "")
  }

  /// Prune a subtree that lies wholly off the screen. A container without a usable frame is
  /// still walked, since its children may be on screen.
  static func mayContainVisibleControls(frame: CGRect, screen: CGRect) -> Bool {
    let values = [frame.minX, frame.minY, frame.width, frame.height]
    guard values.allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else { return true }
    return frame.intersects(screen)
  }
}

extension FBAXTranslationRequest {
  /// The controls of every hosted web page on screen that a tap at their tap point would reach.
  /// Each dictionary is one control without children, with its native identity. `pages` counts
  /// the pages found (a Safari sheet's own toolbar is not one); `unanswered` counts probe points
  /// where nothing at all answered the hit test, as over a WebKit page without an accessibility tree.
  func webControls(frontmostPID: pid_t, screenBounds: CGRect, budget: FBAXAcquisitionBudget?) throws
    -> (controls: [[String: Any]], pages: Int, unanswered: Int) {
    guard let translator else { return ([], 0, 0) }
    let (roots, unanswered) = try webPageRoots(frontmostPID: frontmostPID, screenBounds: screenBounds,
      translator: translator, budget: budget)
    var candidates: [WebCandidate] = []
    for root in roots {
      let before = candidates.count
      try collectControls(root.element, chrome: root.chrome, screenBounds: screenBounds, budget: budget,
        into: &candidates)
      // A page that has just loaded can answer its first walk with nothing while WebKit builds
      // its tree; one more walk then finds the controls.
      if candidates.count == before, !root.chrome {
        try collectControls(root.element, chrome: false, screenBounds: screenBounds, budget: budget,
          into: &candidates)
      }
    }
    let identities = Set(candidates.map(\.identity))
    var controls: [[String: Any]] = []
    for candidate in candidates {
      try budget?.check(); try Task.checkCancellation()
      candidate.element.axSetBridgeDelegateToken(token)
      guard !candidate.element.axIsHidden(),
            let point = FBAXWebControlPolicy.tapPoint(frame: candidate.frame, screen: screenBounds),
            let hit = translator.object(at: try nativePoint(from: point), displayId: pointDisplayID,
              bridgeDelegateToken: token) else { continue }
      hit.bridgeDelegateToken = token
      let hitIdentity = hit.pid > 0 && hit.objectID > 0
        ? FBSimulatorAXNativeIdentity(pid: hit.pid, objectID: hit.objectID) : nil
      var hitFrame = CGRect.null
      if hitIdentity != candidate.identity,
         let hitElement = translator.macPlatformElement(fromTranslation: hit) as? FBAXPlatformElement {
        hitElement.axSetBridgeDelegateToken(token)
        hitFrame = hitElement.axFrame()
      }
      guard FBAXWebControlPolicy.hitShowsControl(hit: hitIdentity, hitFrame: hitFrame,
              control: candidate.identity, controlFrame: candidate.frame, controls: identities,
              parents: candidate.parents) else { continue }
      var values = try webDictionary(candidate.element, chrome: candidate.chrome)
      // The tap guard later accepts exactly this container at the control's point.
      if let hitIdentity, hitIdentity != candidate.identity, candidate.parents.prefix(2).contains(hitIdentity) {
        values[FBAXWebControlPolicy.tapAnswerKey] = ["pid": hitIdentity.pid, "objectID": String(hitIdentity.objectID)]
      }
      controls.append(values)
    }
    return (controls, roots.filter { !$0.chrome }.count, unanswered)
  }

  /// One web element as a dictionary without children, with its native identity.
  func webDictionary(_ element: FBAXPlatformElement, chrome: Bool = false) throws -> [String: Any] {
    element.axSetBridgeDelegateToken(token)
    let keys = FBSimulatorAXWorker.snapshotKeys
    var values = try FBSimulatorAccessibilitySerializer.identityDictionary(element, token: token, keys: keys,
      collector: nil, coverageGrid: nil, seenPids: nil, nativeIdentity: FBAXNativeIdentityCollector(), depth: 0,
      attributes: FBAXElementAttributes(element, keys: keys, includeChildren: false))
    values.removeValue(forKey: "children")
    if FBAXWebControlPolicy.isLinkElement(role: element.axRole(), traits: element.axTraits()) {
      // Reported as the link it is; the heading level is not its value.
      values["role"] = "AXLink"
      values.removeValue(forKey: "AXValue")
    }
    values["is_remote"] = chrome ? FBAXWebControlPolicy.chromeDiscovery : FBAXWebControlPolicy.pageDiscovery
    return values
  }

  /// `parents`: the identities of the control's two nearest containers, nearest first.
  typealias WebCandidate = (element: FBAXPlatformElement, identity: FBSimulatorAXNativeIdentity, frame: CGRect,
    chrome: Bool, parents: [FBSimulatorAXNativeIdentity])

  private enum WebProcessKind { case page, chrome, other }

  /// The root of each page under the probe points, one per WebContent process, and the root of a
  /// Safari sheet's own controls when one is over the app.
  private func webPageRoots(frontmostPID: pid_t, screenBounds: CGRect, translator: AXPTranslator,
                            budget: FBAXAcquisitionBudget?) throws
    -> (roots: [(element: FBAXPlatformElement, chrome: Bool)], unanswered: Int) {
    var roots: [(element: FBAXPlatformElement, chrome: Bool)] = []
    var unanswered = 0
    var found = Set<pid_t>()
    var kinds: [pid_t: WebProcessKind] = [:]
    var attempts: [pid_t: Int] = [:]
    var bundleMisses: [pid_t: Int] = [:]
    var chromeRoots = Set<UInt64>()
    var points = FBAXWebContentProbePlan.points(in: screenBounds, spacing: FBAXWebControlPolicy.probeSpacing)
    var probedAccessoryBar = false
    var index = 0
    while index < points.count {
      let point = points[index]
      index += 1
      try budget?.check(); try Task.checkCancellation()
      guard let hit = translator.object(at: try nativePoint(from: point), displayId: pointDisplayID,
        bridgeDelegateToken: token) else {
        unanswered += 1
        continue
      }
      hit.bridgeDelegateToken = token
      let pid = hit.pid
      guard pid > 0, pid != frontmostPID, !found.contains(pid) else { continue }
      if kinds[pid] == nil {
        let bundle = guestAttribute(FBAXWebControlPolicy.bundleIdentifierAttribute, of: hit,
          translator: translator)?.resultData as? String
        switch bundle {
        case FBAXWebControlPolicy.webContentBundleIdentifier: kinds[pid] = .page
        case let name? where FBAXWebControlPolicy.safariChromeProcessNames.contains(name): kinds[pid] = .chrome
        case .some: kinds[pid] = .other
        case nil:
          // No answer is not an answer: a few later points ask again.
          bundleMisses[pid, default: 0] += 1
          if bundleMisses[pid, default: 0] < FBAXWebControlPolicy.maximumBundleReads { continue }
          kinds[pid] = .other
        }
      }
      switch kinds[pid] {
      case .chrome?:
        guard attempts[pid, default: 0] < FBAXWebControlPolicy.maximumChromeAttempts else { continue }
        attempts[pid, default: 0] += 1
        // The sheet's toolbar is the top of its container chain.
        guard let bar = webRoot(containing: hit, translator: translator),
              chromeRoots.insert(bar.objectID).inserted,
              let element = translator.macPlatformElement(fromTranslation: bar) as? FBAXPlatformElement else {
          continue
        }
        element.axSetBridgeDelegateToken(token)
        roots.append((element, true))
        // The keyboard's accessory bar (Previous, Next, Done) is a container of its own above
        // the keys, thinner than the lattice's rows.
        if !probedAccessoryBar, let key = translator.macPlatformElement(fromTranslation: hit) as? FBAXPlatformElement {
          key.axSetBridgeDelegateToken(token)
          if FBAXWebControlPolicy.isKeyboardKey(traits: key.axTraits()) {
            probedAccessoryBar = true
            points += FBAXWebControlPolicy.accessoryBarPoints(keyboard: element.axFrame(), screen: screenBounds)
          }
        }
      case .page?:
        guard attempts[pid, default: 0] < FBAXWebControlPolicy.maximumRootAttempts else { continue }
        attempts[pid, default: 0] += 1
        guard let root = webRoot(containing: hit, translator: translator),
              let element = translator.macPlatformElement(fromTranslation: root) as? FBAXPlatformElement else {
          continue
        }
        element.axSetBridgeDelegateToken(token)
        found.insert(pid)
        roots.append((element, false))
      default:
        continue
      }
    }
    return (roots, unanswered)
  }

  /// Controls in one page, in reading order, skipping subtrees wholly off the screen.
  private func collectControls(_ root: FBAXPlatformElement, chrome: Bool, screenBounds: CGRect,
    budget: FBAXAcquisitionBudget?, into controls: inout [WebCandidate]) throws {
    var visited = 0
    func walk(_ node: FBAXPlatformElement, depth: Int, parents: [FBSimulatorAXNativeIdentity],
              controls: inout [WebCandidate]) throws {
      try budget?.check(); try Task.checkCancellation()
      guard depth <= FBAXWebControlPolicy.maximumPageDepth, visited < FBAXWebControlPolicy.maximumPageNodes,
            controls.count < FBAXWebControlPolicy.maximumControls else { return }
      visited += 1
      node.axSetBridgeDelegateToken(token)
      let frame = node.axFrame()
      guard FBAXWebControlPolicy.mayContainVisibleControls(frame: frame, screen: screenBounds) else { return }
      let role = node.axRole()
      // Static text is a leaf. One that is not plain text (an ARIA option, such as a search
      // suggestion) is tapped like a control; its traits are read instead of its children.
      if role == FBAXWebControlPolicy.textRole {
        if FBAXWebControlPolicy.isSelectableText(traits: node.axTraits()),
           let identity = node.axNativeIdentity(), FBAXWebControlPolicy.tapPoint(frame: frame, screen: screenBounds) != nil {
          controls.append((node, identity, frame, chrome, parents))
        }
        return
      }
      if let role, FBAXWebControlPolicy.controlRoles.contains(role)
          || FBAXWebControlPolicy.isLinkElement(role: role, traits: node.axTraits()) {
        // A keyboard shown in a Safari sheet is drawn by the sheet's process too; its keys are
        // not the sheet's controls.
        if chrome, FBAXWebControlPolicy.isKeyboardKey(traits: node.axTraits()) { return }
        if let identity = node.axNativeIdentity(), FBAXWebControlPolicy.tapPoint(frame: frame, screen: screenBounds) != nil {
          controls.append((node, identity, frame, chrome, parents))
        }
        return
      }
      var children = node.axChildren()
      if children.isEmpty, FBAXWebControlPolicy.mayHaveChildren(role: role) {
        // A web element can answer its first children request with none while WebKit builds
        // that part of the page's tree; the next request returns them.
        children = node.axChildren()
      }
      let chain = node.axNativeIdentity().map { [$0] + parents.prefix(1) } ?? Array(parents.prefix(1))
      for child in children {
        try walk(child, depth: depth + 1, parents: chain, controls: &controls)
      }
    }
    try walk(root, depth: 0, parents: [], controls: &controls)
  }

  /// Climbs from a hit element to its page's root. Nil when the hit has no container, so a
  /// lone element is never reported as a page.
  private func webRoot(containing hit: AXPTranslationObject, translator: AXPTranslator) -> AXPTranslationObject? {
    var current = hit
    for _ in 0..<FBAXWebControlPolicy.maximumContainerDepth {
      guard let container = guestAttribute(FBAXWebControlPolicy.containerAttribute, of: current,
              translator: translator)?.translationResponse,
            FBAXWebControlPolicy.acceptsContainer(hitPID: hit.pid, currentObjectID: current.objectID,
              containerPID: container.pid, containerObjectID: container.objectID) else {
        break
      }
      container.bridgeDelegateToken = token
      current = container
    }
    return current.objectID == hit.objectID ? nil : current
  }

  /// Whether the element at an oriented logical point belongs to a WebKit page process.
  func isWebContent(at point: CGPoint) throws -> Bool {
    guard let translator, let hit = translator.object(at: try nativePoint(from: point), displayId: pointDisplayID,
      bridgeDelegateToken: token) else { return false }
    hit.bridgeDelegateToken = token
    let bundle = guestAttribute(FBAXWebControlPolicy.bundleIdentifierAttribute, of: hit,
      translator: translator)?.resultData as? String
    return bundle == FBAXWebControlPolicy.webContentBundleIdentifier
  }

  private func guestAttribute(_ attribute: UInt32, of translation: AXPTranslationObject,
                              translator: AXPTranslator) -> AXPTranslatorResponse? {
    guard let request = AXPTranslatorRequest.request(withTranslation: translation) as? AXPTranslatorRequest else {
      return nil
    }
    request.requestType = FBAXWebControlPolicy.attributeRequestType
    request.attributeType = FBAXWebControlPolicy.guestAttributeType
    request.parameters = ["parameter": NSNumber(value: attribute)]
    return translator.sendRequest(request) as? AXPTranslatorResponse
  }
}

extension FBAccessibilityElement {
  /// The controls of hosted web pages on screen. Call on a frontmost-application handle.
  func webControls(screenBounds: CGRect, budget: FBAXAcquisitionBudget) throws
    -> (controls: [[String: Any]], pages: Int, unanswered: Int) {
    try webRequest(operation: "read web controls") { request, element in
      try request.webControls(frontmostPID: element.axTranslationPid, screenBounds: screenBounds, budget: budget)
    }
  }

  /// This point hit as one web element. Call on a point handle.
  func webElement() throws -> [String: Any] {
    try webRequest(operation: "read web element") { request, element in try request.webDictionary(element) }
  }

  /// Whether the element at this logical point is in a WebKit page process.
  func isWebContent(at point: CGPoint) throws -> Bool {
    try webRequest(operation: "read web process") { request, _ in try request.isWebContent(at: point) }
  }
}

extension FBSimulatorAXSnapshot {
  /// The controls of hosted web pages that a tap would reach now, each without children and
  /// with its native identity (`is_remote` is `web`). The frontmost application must be
  /// `expectedPID` before and after the read.
  public static func webControls(for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation, freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    timeoutSeconds: Double = 6) async throws -> [FBSimulatorAXNode] {
    guard expectedPID > 0, timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 8 else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let budget = FBAXAcquisitionBudget(seconds: timeoutSeconds)
    return try await withTaskCancellationHandler(operation: {
      try await FBSimulatorAXWorker.shared.readWebControls(for: simulator, expectedPID: expectedPID,
        observation: observation, provider: freshnessProvider, budget: budget)
    }, onCancel: { budget.stop(.cancelled) })
  }

  /// The hosted web element at an oriented logical point, without children and with its native
  /// identity. The frontmost application must be `expectedPID` before and after, and the hit
  /// must belong to another process.
  /// With `pageOnly`, the hit must also belong to a WebKit page process (not a Safari sheet's
  /// controls, a keyboard or a system alert).
  public static func webElement(at point: CGPoint, for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation, freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    timeoutSeconds: Double = 4, pageOnly: Bool = false) async throws -> FBSimulatorAXNode {
    guard expectedPID > 0, timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 8 else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let budget = FBAXAcquisitionBudget(seconds: timeoutSeconds)
    return try await withTaskCancellationHandler(operation: {
      try await FBSimulatorAXWorker.shared.readWebElement(at: point, for: simulator, expectedPID: expectedPID,
        observation: observation, provider: freshnessProvider, budget: budget, pageOnly: pageOnly)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

extension FBSimulatorAXSnapshot {
  /// The elements at a few oriented logical points, from any process, each without children.
  /// A point with no element is left out. The frontmost application must be `expectedPID`
  /// before and after. Used to see a keyboard another process draws over the app.
  public static func pointElements(at points: [CGPoint], for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation, freshnessProvider: any FBSimulatorHIDFreshnessProvider,
    timeoutSeconds: Double = 2) async throws -> [FBSimulatorAXNode] {
    guard expectedPID > 0, points.count <= 16, timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 8 else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let budget = FBAXAcquisitionBudget(seconds: timeoutSeconds)
    return try await withTaskCancellationHandler(operation: {
      try await FBSimulatorAXWorker.shared.readPointElements(at: points, for: simulator, expectedPID: expectedPID,
        observation: observation, provider: freshnessProvider, budget: budget)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

extension FBSimulatorAXWorker {
  func readPointElements(at points: [CGPoint], for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDFreshnessProvider,
    budget: FBAXAcquisitionBudget) async throws -> [FBSimulatorAXNode] {
    try Task.checkCancellation(); try budget.check()
    try await validateSelection(simulator, observation: observation, provider: provider)
    let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
    try FBAXPointReadRules.frontmost(try await webFrontmostPID(commands, observation: observation, budget: budget),
      expectedPID: expectedPID)
    var values: [[String: Any]] = []
    for point in points {
      try budget.check(); try Task.checkCancellation()
      let native = try FBAXPointReadRules.nativePoint(point, observation: observation)
      let request = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
        displayContext: observation.displayContext)
      request.acquisitionBudget = budget
      let handle: FBAccessibilityElement
      do { handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self) }
      catch let accessibility as FBAccessibilityError {
        if case .noTranslationObject = accessibility { continue }
        throw accessibility
      }
      defer { handle.close() }
      values.append(try handle.webElement())
      handle.close()
    }
    try FBAXPointReadRules.frontmost(try await webFrontmostPID(commands, observation: observation, budget: budget),
      expectedPID: expectedPID)
    try budget.check(); try Task.checkCancellation()
    return try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONSerialization.data(withJSONObject: values))
  }

  func readWebControls(for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDFreshnessProvider,
    budget: FBAXAcquisitionBudget) async throws -> [FBSimulatorAXNode] {
    try Task.checkCancellation(); try budget.check()
    guard observation.displayContext.rotation == .rot0 else { throw FBSimulatorAXWebError.unsupportedRotation }
    try await validateSelection(simulator, observation: observation, provider: provider)
    let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
    let request = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    request.acquisitionBudget = budget
    let handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
    defer { handle.close() }
    try budget.check()
    try FBAXPointReadRules.frontmost(handle.acquisitionPID, expectedPID: expectedPID)
    let screen = CGRect(origin: .zero, size: observation.displayContext.logicalSize)
    let first = try handle.webControls(screenBounds: screen, budget: budget)
    var values = first.controls
    if first.pages == 0, first.unanswered > 0,
       FBSimulatorAccessibilityCommands.requiresAccessibilityBootstrap(for: simulator.osVersion.version) {
      values = try webControlsWhileLoaded(handle, simulator: simulator, screen: screen, budget: budget) ?? values
    }
    handle.close()
    try FBAXPointReadRules.frontmost(try await webFrontmostPID(commands, observation: observation, budget: budget),
      expectedPID: expectedPID)
    try await validateSelection(simulator, observation: observation, provider: provider)
    try budget.check(); try Task.checkCancellation()
    return try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONSerialization.data(withJSONObject: values))
  }

  func readWebElement(at point: CGPoint, for simulator: FBSimulator, expectedPID: Int32,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDFreshnessProvider,
    budget: FBAXAcquisitionBudget, pageOnly: Bool = false) async throws -> FBSimulatorAXNode {
    try Task.checkCancellation(); try budget.check()
    guard observation.displayContext.rotation == .rot0 else { throw FBSimulatorAXWebError.unsupportedRotation }
    let native = try FBAXPointReadRules.nativePoint(point, observation: observation)
    try await validateSelection(simulator, observation: observation, provider: provider)
    let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
    try FBAXPointReadRules.frontmost(try await webFrontmostPID(commands, observation: observation, budget: budget),
      expectedPID: expectedPID)
    let request = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
      displayContext: observation.displayContext)
    request.acquisitionBudget = budget
    let handle: FBAccessibilityElement
    do { handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self) }
    catch let accessibility as FBAccessibilityError {
      if case .noTranslationObject = accessibility { throw FBSimulatorAXWebError.notWebContent }
      throw accessibility
    }
    defer { handle.close() }
    try budget.check()
    let hitPID = handle.acquisitionPID
    guard hitPID > 0, hitPID != expectedPID else { throw FBSimulatorAXWebError.notWebContent }
    if pageOnly, try !handle.isWebContent(at: point) { throw FBSimulatorAXWebError.notWebContent }
    let values = try handle.webElement()
    handle.close()
    try FBAXPointReadRules.frontmost(try await webFrontmostPID(commands, observation: observation, budget: budget),
      expectedPID: expectedPID)
    try await validateSelection(simulator, observation: observation, provider: provider)
    try budget.check(); try Task.checkCancellation()
    let node = try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONSerialization.data(withJSONObject: values))
    guard node.pid == hitPID else { throw FBSimulatorAXWebError.notWebContent }
    return node
  }

  /// Reads web controls again while a remote automation session holds app Accessibility on.
  /// AXe's preparation for a just-launched app switches app Accessibility on only briefly; a
  /// WebKit page that starts outside that window has no accessibility tree, so its points answer
  /// nothing, until app Accessibility is on long enough for WebKit to build one. Once built the
  /// tree stays. Reads stop when a page appears or every probe point answers.
  private func webControlsWhileLoaded(_ handle: FBAccessibilityElement, simulator: FBSimulator, screen: CGRect,
                                      budget: FBAXAcquisitionBudget) throws -> [[String: Any]]? {
    let remaining = try budget.remainingSeconds()
    let hold = min(FBAXWebControlPolicy.loadedReadSeconds, remaining - 1)
    guard hold > 0 else { return nil }
    var values: [[String: Any]] = []
    var answered = false
    var failure: Error?
    let timeout = min(5, remaining - 0.5)
    let started = ProcessInfo.processInfo.systemUptime
    do {
      try FBSimulatorControlFrameworkLoader.bootstrapAccessibility(forSimulatorDevice: simulator.device,
        timeout: timeout, logger: simulator.logger) {
      // Leave the session time to end inside its own deadline.
      let end = min(ProcessInfo.processInfo.systemUptime + hold,
                    started + timeout - FBAXWebControlPolicy.loadedReadCleanupSeconds)
      repeat {
        do {
          let read = try handle.webControls(screenBounds: screen, budget: budget)
          values = read.controls
          answered = true
          if read.pages > 0 || read.unanswered == 0 { return }
        } catch {
          failure = error
          return
        }
        Thread.sleep(forTimeInterval: FBAXWebControlPolicy.loadedReadInterval)
      } while ProcessInfo.processInfo.systemUptime < end
      }
    } catch {
      // Controls read while the session held Accessibility on stay valid if the session then
      // ends late.
      guard answered, failure == nil else { throw failure ?? error }
    }
    if let failure { throw failure }
    try budget.check()
    return answered ? values : nil
  }

  private func webFrontmostPID(_ commands: FBSimulatorAccessibilityCommands,
                               observation: FBSimulatorHIDSessionObservation,
                               budget: FBAXAcquisitionBudget) async throws -> Int32 {
    try budget.check(); try Task.checkCancellation()
    let request = FBAXTranslationRequest(kind: .frontmostApplication,
      pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
    request.acquisitionBudget = budget
    let handle = try await commands.accessibilityElementForAcquisition(request: request, worker: self)
    defer { handle.close() }
    try budget.check()
    return handle.acquisitionPID
  }
}
