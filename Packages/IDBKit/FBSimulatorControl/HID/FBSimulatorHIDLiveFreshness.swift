@preconcurrency import CoreSimulator
import Foundation

/// A session owns this provider until close. The cheap check must use a verified live feed;
/// returning an unchanged cached observation is not an implementation of this contract.
public protocol FBSimulatorHIDLiveFreshnessProvider: FBSimulatorHIDFreshnessProvider {
  func validateCurrentRevision(expected: FBSimulatorHIDSessionObservation) throws
  func close()
}

public struct FBSimulatorHIDFeedStatus: Sendable {
  public let generation: UInt64
  public let motionSampleCount: UInt64
  public let displayCallbackCount: UInt64
  public let displayRefreshCount: UInt64
  public let motionAgeSeconds: Double?
  public let displayAgeSeconds: Double?
  public let failure: String?
}

/// Owns real native subscriptions and background fresh reads. No external process runs on the
/// per-primitive check. Full guest/boot observations remain mandatory at start and after drain.
public final class FBSimulatorHIDNativeFreshnessProvider: FBSimulatorHIDLiveFreshnessProvider, FBSimulatorHIDCleanupIdentityProvider, Sendable {
  public let initialObservation: FBSimulatorHIDSessionObservation
  private let authoritative: any FBSimulatorHIDFreshnessProvider
  private let state: FBSimulatorHIDFeedState
  private let generation: UInt64
  private let displayFeed: FBSimulatorHIDDisplayFeed
  private let renewal: Task<Void, Never>

  private init(observation: FBSimulatorHIDSessionObservation,
               authoritative: any FBSimulatorHIDFreshnessProvider,
               state: FBSimulatorHIDFeedState, generation: UInt64,
               displayFeed: FBSimulatorHIDDisplayFeed, renewal: Task<Void, Never>) {
    self.initialObservation = observation
    self.authoritative = authoritative
    self.state = state
    self.generation = generation
    self.displayFeed = displayFeed
    self.renewal = renewal
  }

  /// Preferred entry point: native full context reads plus the native change feed.
  public static func start(for simulator: FBSimulator, screenID: UInt32,
                           screenUniqueID: UUID, maximumFeedAge: TimeInterval = 0.5) async throws -> FBSimulatorHIDNativeFreshnessProvider {
    let reader = FBSimulatorNativeContextReader(simulator: simulator,
      screenID: screenID, screenUniqueID: screenUniqueID)
    return try await start(for: simulator, authoritativeProvider: reader, maximumFeedAge: maximumFeedAge)
  }

  public static func start(for simulator: FBSimulator,
                           authoritativeProvider: any FBSimulatorHIDFreshnessProvider,
                           maximumFeedAge: TimeInterval = 0.5) async throws -> FBSimulatorHIDNativeFreshnessProvider {
    guard maximumFeedAge.isFinite, maximumFeedAge >= 0.1, maximumFeedAge <= 3 else {
      throw FBSimulatorHIDSessionError.invalidObservation("Feed maximum age must be in [0.1, 3] seconds")
    }
    let capability = try FBSimulatorNativeContextReader.capability(for: simulator)
    let requiresMotion = try capability.hinge.requiresMotionFeed()
    let state = FBSimulatorHIDFeedState(maximumAge: maximumFeedAge, requiresMotion: requiresMotion)
    let displays = try await FBSimulatorHIDDisplayFeed.start(for: simulator, state: state)
    var firstMotion: FBSimulatorHIDMotionSubscription?
    var renewal: Task<Void, Never>?
    do {
      if requiresMotion {
        let motion = try FBSimulatorHIDMotionSubscription(simulator: simulator, state: state)
        firstMotion = motion
        try await motion.waitForFreshSample()
      }
      state.observeDisplays(try await FBSimulatorDisplayDiscovery.displays(for: simulator))
      let motion = firstMotion
      let task = Task { await renew(simulator: simulator, first: motion, state: state,
                                   interval: min(0.1, maximumFeedAge / 4)) }
      renewal = task
      let checkpoint = try state.checkpoint()
      let observation = try await authoritativeProvider.observation()
      try Task.checkCancellation()
      try state.validate(generation: checkpoint)
      guard observation.simulatorUDID == simulator.udid,
            capability.integratedDigitizerIDs.contains(observation.screenID) else {
        throw FBSimulatorHIDSessionError.invalidObservation("Authoritative simulator or selected screen identity does not match the verified profile")
      }
      return FBSimulatorHIDNativeFreshnessProvider(observation: observation, authoritative: authoritativeProvider,
        state: state, generation: checkpoint, displayFeed: displays, renewal: task)
    } catch {
      renewal?.cancel(); firstMotion?.close(); displays.close(); state.close()
      await renewal?.value
      throw error
    }
  }

  public func validateCurrentRevision(expected: FBSimulatorHIDSessionObservation) throws {
    guard expected == initialObservation else {
      throw FBSimulatorHIDSessionError.interrupted(reason: .staleContext, cleanup: .notNeeded)
    }
    try state.validate(generation: generation)
  }

  public func observation() async throws -> FBSimulatorHIDSessionObservation {
    try state.validate(generation: generation)
    let current = try await authoritative.observation()
    try state.validate(generation: generation)
    return current
  }

  public func cleanupIdentity() async throws -> FBSimulatorHIDCleanupIdentity {
    guard let reader = authoritative as? any FBSimulatorHIDCleanupIdentityProvider else {
      throw FBSimulatorHIDSessionError.invalidObservation("Authoritative provider has no cleanup identity reader")
    }
    // A changed generation invalidates normal input. It must not replace the original target or
    // prevent this separate read-only identity check for release on the original connection.
    return try await reader.cleanupIdentity()
  }

  public func status() -> FBSimulatorHIDFeedStatus { state.status() }

  public func close() {
    state.close()
    renewal.cancel()
    displayFeed.close()
  }
  /// Await the owned renewal task after cancelling subscriptions. Existing close remains nonblocking.
  public func closeAndWait() async {
    close()
    await renewal.value
  }
  deinit { close() }

  private static func renew(simulator: FBSimulator, first: FBSimulatorHIDMotionSubscription?,
                            state: FBSimulatorHIDFeedState, interval: TimeInterval) async {
    // One listener remains open to detect a change and reversion between fresh reads.
    defer { first?.close() }
    let motionRead: (@Sendable () async throws -> FBSimulatorHingeObservation)?
    if first != nil {
      motionRead = { try await FBSimulatorHingeReader.read(for: simulator) }
    } else {
      motionRead = nil
    }
    await FBSimulatorHIDFeedRenewal.run(state: state, interval: interval,
      motionRead: motionRead, displayRead: { try await FBSimulatorDisplayDiscovery.displays(for: simulator) })
  }
}


/// Fresh motion samples and display enumeration cannot delay each other's renewal.
/// The caller owns the persistent change listener and joins both tasks before closing it.
enum FBSimulatorHIDFeedRenewal {
  static func run(state: FBSimulatorHIDFeedState, interval: TimeInterval,
                  motionRead: (@Sendable () async throws -> FBSimulatorHingeObservation)?,
                  displayRead: @escaping @Sendable () async throws -> [FBSimulatorDisplayInfo]) async {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        if let motionRead {
          group.addTask {
            do {
              while true {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let sample = try await motionRead()
                try Task.checkCancellation()
                state.observeMotion(sample)
              }
            } catch {
              if !(error is CancellationError) { state.fail("Motion refresh: \(error)") }
              throw error
            }
          }
        }
        group.addTask {
          do {
            while true {
              try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
              let displays = try await displayRead()
              try Task.checkCancellation()
              state.observeDisplays(displays)
            }
          } catch {
            if !(error is CancellationError) { state.fail("Display refresh: \(error)") }
            throw error
          }
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
    } catch is CancellationError {
      state.close()
    } catch {
      state.fail("Feed renewal: \(error)")
    }
  }
}

// Runtime seed advances during stable enumeration without a context change.
// Keep it in discovery/observer diagnostics, not in this semantic comparison.
private struct FBSimulatorHIDFeedDisplay: Equatable {
  let identity: String?
  let size: CGSize
  let scale: Double
  let kind: UInt64
  let orientation: UInt32
  let power: Int32
  let backlight: Int32?
  init(_ value: FBSimulatorDisplayInfo) {
    identity = value.uniqueID; size = value.nativePixelSize; scale = value.scale
    kind = value.rawScreenType; orientation = value.rawUIOrientation
    power = value.rawPowerState; backlight = value.rawBacklightState
  }
}

/// Callback bridge with one lock for every mutable field. Change generations are local
/// observations, not an Apple atomic state/send revision or a guarantee of callback ordering.
final class FBSimulatorHIDFeedState: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumAge: TimeInterval
  private let requiresMotion: Bool
  private let clock: @Sendable () -> TimeInterval
  private var generation: UInt64 = 0
  private var lastMotion: FBSimulatorHingeObservation?
  private var displays: [UInt32: FBSimulatorHIDFeedDisplay] = [:]
  private var hasDisplaySnapshot = false
  private var displayReceived: TimeInterval?
  private var motionSamples: UInt64 = 0
  private var displayCallbacks: UInt64 = 0
  private var displayRefreshes: UInt64 = 0
  private var failure: String?

  // Preserve the existing designated initializer and its exported initializing entry.
  init(maximumAge: TimeInterval, requiresMotion: Bool = true) {
    self.maximumAge = maximumAge
    self.requiresMotion = requiresMotion
    self.clock = { ProcessInfo.processInfo.systemUptime }
  }

  init(maximumAge: TimeInterval, requiresMotion: Bool,
       clock: @escaping @Sendable () -> TimeInterval) {
    self.maximumAge = maximumAge
    self.requiresMotion = requiresMotion
    self.clock = clock
  }

  func observeMotion(_ value: FBSimulatorHingeObservation) {
    lock.lock(); defer { lock.unlock() }
    guard failure == nil else { return }
    motionSamples += 1
    if let last = lastMotion,
       last.mechanicalDegrees != value.mechanicalDegrees || last.minimumDegrees != value.minimumDegrees || last.maximumDegrees != value.maximumDegrees {
      generation += 1
    }
    // An older callback can still prove a transient change. It cannot refresh the clock.
    if lastMotion == nil || value.timestampUptime > lastMotion!.timestampUptime { lastMotion = value }
  }

  func observeDisplayCallback(_ value: FBSimulatorDisplayInfo) {
    lock.lock(); defer { lock.unlock() }
    guard failure == nil else { return }
    displayCallbacks += 1
    let fingerprint = FBSimulatorHIDFeedDisplay(value)
    if let previous = displays[value.screenID], previous != fingerprint { generation += 1 }
    else if hasDisplaySnapshot && displays[value.screenID] == nil { generation += 1 }
    displays[value.screenID] = fingerprint
  }

  func observeDisplays(_ values: [FBSimulatorDisplayInfo]) {
    lock.lock(); defer { lock.unlock() }
    guard failure == nil else { return }
    let next = Dictionary(uniqueKeysWithValues: values.map { ($0.screenID, FBSimulatorHIDFeedDisplay($0)) })
    if hasDisplaySnapshot && displays != next { generation += 1 }
    displays = next
    hasDisplaySnapshot = true
    displayReceived = clock()
    displayRefreshes += 1
  }

  func fail(_ message: String) {
    lock.lock(); defer { lock.unlock() }
    if failure == nil { failure = message }
  }
  func close() { fail("Feed closed") }
  func motionSubscriptionCompleted() { fail("Motion subscription completed before close") }

  func checkpoint() throws -> UInt64 {
    lock.lock(); defer { lock.unlock() }
    try requireFresh()
    return generation
  }

  func validate(generation expected: UInt64) throws {
    lock.lock(); defer { lock.unlock() }
    try requireFresh()
    guard generation == expected else {
      throw FBSimulatorHIDSessionError.interrupted(reason: .staleContext, cleanup: .notNeeded)
    }
  }

  private func requireFresh() throws {
    if let failure {
      throw FBSimulatorHIDSessionError.interrupted(reason: .observationUnavailable(failure), cleanup: .notNeeded)
    }
    let now = clock()
    let motionIsFresh = !requiresMotion || lastMotion.map { now - $0.timestampUptime <= maximumAge } == true
    let displayIsFresh = displayReceived.map { now - $0 <= maximumAge } == true
    guard motionIsFresh, displayIsFresh else {
      let sources = [motionIsFresh ? nil : "motion", displayIsFresh ? nil : "display"].compactMap { $0 }
      let motionAge = lastMotion.map { String(now - $0.timestampUptime) } ?? "missing"
      let displayAge = displayReceived.map { String(now - $0) } ?? "missing"
      let timestamp = lastMotion.map { String($0.timestampUptime) } ?? "missing"
      let received = lastMotion.map { String($0.receivedUptime) } ?? "missing"
      let message = "Native observation feed is stale or not initialized; staleSources=\(sources.joined(separator: ",")); "
        + "nowUptime=\(now); maximumAgeSeconds=\(maximumAge); motionAgeSeconds=\(motionAge); displayAgeSeconds=\(displayAge); "
        + "motionTimestampUptime=\(timestamp); motionReceivedUptime=\(received); channelID=\(lastMotion?.channelID ?? "missing"); "
        + "motionSampleCount=\(motionSamples); displayCallbackCount=\(displayCallbacks); displayRefreshCount=\(displayRefreshes); generation=\(generation)"
      throw FBSimulatorHIDSessionError.interrupted(reason: .observationUnavailable(message), cleanup: .notNeeded)
    }
  }

  func status() -> FBSimulatorHIDFeedStatus {
    lock.lock(); defer { lock.unlock() }
    let now = clock()
    return FBSimulatorHIDFeedStatus(generation: generation, motionSampleCount: motionSamples,
      displayCallbackCount: displayCallbacks, displayRefreshCount: displayRefreshes,
      motionAgeSeconds: lastMotion.map { now - $0.timestampUptime },
      displayAgeSeconds: displayReceived.map { now - $0 }, failure: failure)
  }
}

// Only the verified device profile can select a display-only feed. Failed motion reads never
// change this policy. Unknown profiles must obtain a verified contract before any input.
extension FBSimulatorHingeCapability {
  func requiresMotionFeed() throws -> Bool {
    switch self {
    case .supported: return true
    case .unsupported: return false
    case .unverified:
      throw FBSimulatorHIDSessionError.invalidObservation("Device profile has no verified hinge capability")
    }
  }
}
