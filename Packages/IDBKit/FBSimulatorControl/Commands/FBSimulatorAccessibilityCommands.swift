/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@_implementationOnly @preconcurrency import AccessibilityPlatformTranslation
import AppKit
import CoreSimulator
import FBControlCore
import Foundation

// MARK: - FBSimulator (translation dispatcher construction)

extension FBSimulator {

  /// Builds a dispatcher for the given translator and wires it up as the
  /// translator's token delegate. `translator` is typed `Any` to accept the test
  /// fixture's mock `AXPTranslator` (mirrors the original `id` parameter). Swift-only
  /// (not `@objc`): an `@objc` `Any` parameter double-visions as `Any`/`Any!` and
  /// makes the call ambiguous; nothing in Objective-C calls this anymore.
  static func createAccessibilityTranslationDispatcher(withTranslator translator: Any) -> FBAXTranslationDispatcher {
    let axTranslator = unsafeBitCast(translator as AnyObject, to: AXPTranslator.self)
    let dispatcher = FBAXTranslationDispatcher(translator: axTranslator, logger: nil)
    axTranslator.bridgeTokenDelegate = dispatcher
    return dispatcher
  }

  // Process-wide singleton: AXPTranslator is itself a singleton with a single
  // bridgeTokenDelegate slot, so exactly one dispatcher backs every simulator (it
  // disambiguates concurrent requests by token, guarded internally by a lock).
  // The lazy `static let` initialiser is thread-safe; `nonisolated(unsafe)` opts
  // this shared instance out of Swift 6 Sendable checking accordingly.
  private nonisolated(unsafe) static let sharedAccessibilityTranslationDispatcher: FBAXTranslationDispatcher = {
    let translator = unsafeBitCast(AXPTranslator.sharedInstance() as AnyObject, to: AXPTranslator.self)
    return FBSimulator.createAccessibilityTranslationDispatcher(withTranslator: translator)
  }()

  var accessibilityTranslationDispatcher: FBAXTranslationDispatcher {
    FBSimulator.sharedAccessibilityTranslationDispatcher
  }
}

// MARK: - FBSimulatorAccessibilityCommands

/// Simulator implementation of the accessibility command surface. Resolves the
/// frontmost / at-point / matching accessibility element via the translation
/// dispatcher, applying SpringBoard-crash remediation for frontmost lookups.
///
/// `final`; unit tests inject a mock dispatcher via `injectedDispatcher` (`@testable`).
/// Stays `NSObject` because it is stored in the simulator's Objective-C command cache.
public final class FBSimulatorAccessibilityCommands: NSObject, AsyncAccessibilityOperations {

  private static let coreSimulatorBridgeServiceName = "com.apple.CoreSimulator.bridge"

  static func requiresAccessibilityBootstrap(for runtimeVersion: OperatingSystemVersion) -> Bool {
    runtimeVersion.majorVersion >= 27
  }

  private weak var simulator: FBSimulator?

  /// Test injection seam: when set, overrides the simulator's shared dispatcher.
  var injectedDispatcher: FBAXTranslationDispatcher?

  @objc(initWithSimulator:)
  public init(simulator: FBSimulator) {
    self.simulator = simulator
    super.init()
  }

  @objc(commandsWithTarget:)
  public class func commands(with target: FBSimulator) -> Self {
    self.init(simulator: target)
  }

  // MARK: Translation Dispatcher

  /// The translation dispatcher for accessibility requests: the test-injected one
  /// when present, otherwise the simulator's process-wide shared dispatcher.
  private var resolvedDispatcher: FBAXTranslationDispatcher? {
    injectedDispatcher ?? simulator?.accessibilityTranslationDispatcher
  }

  // MARK: AsyncAccessibilityOperations

  public func accessibilityElement(at point: CGPoint) async throws -> FBAccessibilityElement {
    try await accessibilityElement(at: point, bootstrap: true)
  }

  /// `bootstrap: false` reads directly. Runtime 27 needs its short-lived bootstrap only before
  /// the first read after boot; a caller retries with `bootstrap: true` after a failed read.
  public func accessibilityElement(at point: CGPoint, bootstrap: Bool) async throws -> FBAccessibilityElement {
    try validateAccessibility(bootstrap: bootstrap)
    let request = FBAXTranslationRequest(kind: .point(point), pointDisplayID: 0)
    return try await accessibilityElement(request: request, remediationPermitted: false)
  }

  /// A plain point read on a measured display. The logical point uses the observation's display
  /// transform and AX display ID, as selected point reads do. The default display query has no
  /// translation object on a Duo panel. The result is a description, not an input target.
  public func accessibilityElement(atLogicalPoint point: CGPoint, observation: FBSimulatorHIDSessionObservation,
                                   bootstrap: Bool) async throws -> FBAccessibilityElement {
    try validateAccessibility(bootstrap: bootstrap)
    let native = try FBAXPointReadRules.nativePoint(point, observation: observation)
    let request = FBAXTranslationRequest(kind: .point(native), pointDisplayID: observation.axDisplayID,
      displayContext: observation.displayContext)
    return try await accessibilityElement(request: request, remediationPermitted: false)
  }

  /// Resolves a point in the selected display's unrotated logical coordinate space.
  /// Convert app coordinates using the measured display orientation before calling.
  /// The AX display ID is explicit; this does not select a frontmost application tree.
  public func accessibilityElement(atNativePoint point: CGPoint, displayID: UInt32) async throws -> FBAccessibilityElement {
    try validateAccessibility()
    let request = FBAXTranslationRequest(kind: .point(point), pointDisplayID: displayID)
    return try await accessibilityElement(request: request, remediationPermitted: false)
  }

  public func accessibilityElementForFrontmostApplication() async throws -> FBAccessibilityElement {
    try await accessibilityElementForFrontmostApplication(bootstrap: true)
  }

  /// `bootstrap: false` reads directly. A caller retries with `bootstrap: true` after an
  /// empty tree, as selected and agent reads do.
  public func accessibilityElementForFrontmostApplication(bootstrap: Bool) async throws -> FBAccessibilityElement {
    try validateAccessibility(bootstrap: bootstrap)
    let request = FBAXTranslationRequest(kind: .frontmostApplication)
    return try await accessibilityElement(request: request, remediationPermitted: true)
  }

  /// Selected-display whole tree. Context supplies the remote hit-test transform.
  public func accessibilityElementForFrontmostApplication(displayID: UInt32, displayContext: FBSimulatorHIDDisplayContext) async throws -> FBAccessibilityElement {
    try validateAccessibility(bootstrap: false)
    let request = FBAXTranslationRequest(kind: .frontmostApplication, pointDisplayID: displayID, displayContext: displayContext)
    return try await accessibilityElement(request: request, remediationPermitted: true)
  }

  public func accessibilityElementMatching(value: String, forKey key: FBAXSearchableKey, depth: UInt) async throws -> FBAccessibilityElement {
    try validateAccessibility()
    let request = FBAXTranslationRequest(kind: .frontmostApplication)
    let root = try await accessibilityElement(request: request, remediationPermitted: true)
    return try root.findElement(withValue: value, forKey: key, depth: depth)
  }

  // Snapshot handles are acquired and consumed on the same worker. This internal
  // boundary uses standard IDB validation with the existing bounded remediation path.
  func accessibilityElementForSnapshot(request: FBAXTranslationRequest,
                                       worker: isolated FBSimulatorAXWorker) async throws -> FBAccessibilityElement {
    try Task.checkCancellation()
    try validateAccessibility()
    let remediationPermitted: Bool
    switch request.kind {
    case .frontmostApplication: remediationPermitted = true
    case .point: remediationPermitted = false
    }
    return try await accessibilityElement(request: request,
      remediationPermitted: remediationPermitted, isolation: worker)
  }

  // The operation owner performs standard validation once before these rechecks.
  // Acquisition never uses the legacy bridge-restart recovery path.
  func accessibilityElementForAcquisition(request: FBAXTranslationRequest,
                                          worker: isolated FBSimulatorAXWorker) async throws -> FBAccessibilityElement {
    try Task.checkCancellation()
    try request.acquisitionBudget?.check()
    try validateAccessibility(bootstrap: false)
    return try await accessibilityElement(request: request, remediationPermitted: false, isolation: worker)
  }

  func accessibilityElementForSliderLease(request: FBAXTranslationRequest,
    worker: isolated FBSimulatorAXWorker) async throws -> FBAccessibilityElement {
    try Task.checkCancellation()
    try validateAccessibility(bootstrap: false)
    // A failed target must fail closed; this operation never restarts a guest service.
    return try await accessibilityElement(request: request, remediationPermitted: false, isolation: worker)
  }

  // MARK: Private

  // Uses the CoreSimulator accessibility API via
  // -[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:].
  // This API requires Xcode 12+ to have been installed on the host at some point.
  func validateAccessibility(bootstrap: Bool = true) throws {
    guard let simulator else {
      throw FBAccessibilityError.simulatorDeallocated
    }
    guard simulator.state == .booted else {
      throw FBAccessibilityError.simulatorNotBooted(description: "\(simulator)")
    }
    let selector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
    guard simulator.device.responds(to: selector) else {
      throw FBAccessibilityError.accessibilityUnavailable
    }
    try FBSimulatorControlFrameworkLoader.accessibilityFrameworks.loadPrivateFrameworks(simulator.logger)
    if bootstrap && Self.requiresAccessibilityBootstrap(for: simulator.osVersion.version) {
      try FBSimulatorControlFrameworkLoader.bootstrapAccessibility(
        forSimulatorDevice: simulator.device,
        timeout: 5,
        logger: simulator.logger
      )
    }
  }

  // Returns an FBAccessibilityElement wrapping the platform element for the given request.
  // The handle owns the request's token and pops it on close.
  //
  // When remediationPermitted and a stale SpringBoard is detected (zero accessibility frame +
  // dead pid), the original request's token is popped manually (it is not wrapped in a handle
  // yet at that point), CoreSimulatorBridge is restarted, and the lookup retries with a fresh
  // request. The retry passes remediationPermitted=false, bounding it to a single attempt.
  private func accessibilityElement(request: FBAXTranslationRequest, remediationPermitted: Bool, isolation: isolated (any Actor)? = #isolation) async throws -> FBAccessibilityElement {
    guard let simulator else {
      throw FBAccessibilityError.simulatorDeallocated
    }
    guard let dispatcher = resolvedDispatcher else {
      throw FBAccessibilityError.dispatcherUnavailable
    }
    let element = try await dispatcher.platformElement(withRequest: request, simulator: simulator, isolation: isolation)
    var transferred = false
    defer { if !transferred { dispatcher.popRequest(request) } }
    try Task.checkCancellation()
    if !remediationPermitted {
      transferred = true
      return FBAccessibilityElement(element: element, request: request, dispatcher: dispatcher, simulator: simulator)
    }
    if try await !Self.remediationRequired(forSimulator: simulator, element: element, isolation: isolation) {
      try Task.checkCancellation()
      transferred = true
      return FBAccessibilityElement(element: element, request: request, dispatcher: dispatcher, simulator: simulator)
    }
    // The request's token was pushed by the dispatcher but is not yet wrapped in an
    // FBAccessibilityElement, so pop it manually before discarding the request.
    dispatcher.popRequest(request)
    transferred = true
    let nextRequest = request.cloneWithNewToken()
    try Task.checkCancellation()
    try await Self.remediateSpringBoard(forSimulator: simulator)
    return try await accessibilityElement(request: nextRequest, remediationPermitted: false, isolation: isolation)
  }

  private static func remediationRequired(forSimulator simulator: FBSimulator, element: FBAXPlatformElement, isolation: isolated (any Actor)? = #isolation) async throws -> Bool {
    // A quick check: a non-zero accessibility frame indicates a healthy element.
    if !element.axFrame().equalTo(.zero) {
      return false
    }
    // Otherwise confirm whether the translation object's pid represents a real process.
    // If it does not, we likely got the pid of a crashed SpringBoard; restarting
    // CoreSimulatorBridge lets launchd bring a fresh SpringBoard (and bridge) back up.
    let pid = element.axTranslationPid
    do {
      _ = try await bridgeFBFuture(simulator.serviceName(forProcessIdentifier: pid))
      return false
    } catch {
      simulator.logger?.log("Frontmost accessibility hierarchy is stale: the root element has a zero frame and its owning pid \(pid) is no longer a registered launchd service. SpringBoard has crashed and CoreSimulator's \(coreSimulatorBridgeServiceName) is still bound to the dead pid; restarting \(coreSimulatorBridgeServiceName) to recover.")
      return true
    }
  }

  private static func remediateSpringBoard(forSimulator simulator: FBSimulator) async throws {
    do {
      _ = try await bridgeFBFuture(simulator.stopService(withName: coreSimulatorBridgeServiceName))
    } catch {
      throw FBAccessibilityError.springBoardRemediationFailed(serviceName: coreSimulatorBridgeServiceName)
    }
  }
}

// MARK: - FBSimulator+AsyncAccessibilityCommands

extension FBSimulator: AsyncAccessibilityCommands {

  public func accessibilityElement(at point: CGPoint) async throws -> FBAccessibilityElement {
    try await accessibilityCommands().accessibilityElement(at: point)
  }

  /// Uses a selected-display native point rather than the default display query.
  public func accessibilityElement(atNativePoint point: CGPoint, displayID: UInt32) async throws -> FBAccessibilityElement {
    try await accessibilityCommands().accessibilityElement(atNativePoint: point, displayID: displayID)
  }

  public func accessibilityElementForFrontmostApplication() async throws -> FBAccessibilityElement {
    try await accessibilityCommands().accessibilityElementForFrontmostApplication()
  }

  public func accessibilityElement(at point: CGPoint, bootstrap: Bool) async throws -> FBAccessibilityElement {
    try await accessibilityCommands().accessibilityElement(at: point, bootstrap: bootstrap)
  }

  public func accessibilityElement(atLogicalPoint point: CGPoint, observation: FBSimulatorHIDSessionObservation,
                                   bootstrap: Bool) async throws -> FBAccessibilityElement {
    try await accessibilityCommands().accessibilityElement(atLogicalPoint: point, observation: observation, bootstrap: bootstrap)
  }

  public func accessibilityElementForFrontmostApplication(bootstrap: Bool) async throws -> FBAccessibilityElement {
    try await accessibilityCommands().accessibilityElementForFrontmostApplication(bootstrap: bootstrap)
  }

  public func accessibilityElementForFrontmostApplication(displayID: UInt32, displayContext: FBSimulatorHIDDisplayContext) async throws -> FBAccessibilityElement {
    try await accessibilityCommands().accessibilityElementForFrontmostApplication(displayID: displayID, displayContext: displayContext)
  }

  public func accessibilityElementMatching(
    value: String,
    forKey key: FBAXSearchableKey,
    depth: UInt
  ) async throws -> FBAccessibilityElement {
    try await accessibilityCommands().accessibilityElementMatching(value: value, forKey: key, depth: depth)
  }
}
