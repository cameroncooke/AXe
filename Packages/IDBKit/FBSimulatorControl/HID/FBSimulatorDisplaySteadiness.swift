import Foundation

/// A lit inactive panel normally means the Duo is folding: during a fold the incoming panel can be
/// active while the outgoing one is still lit, or the reverse, and after a close the inner panel
/// stays lit for SpringBoard's 3 s dwell. Measured on iOS 27.2 under heavy host load, CoreDevice's
/// display report can also miss one update and then stay stale for minutes: SpringBoard has turned
/// the inner panel off but the report still says it is lit, or it has swapped panels but the report
/// still flags the old one active. Only the first stale shape can be trusted.
///
/// A lit inactive report is trusted only when it is consistent with the hinge, which is read
/// separately, and has stayed identical for longer than the longest measured real transition:
/// - the hinge is at rest at an end stop, closed with the primary (outer) panel active, or open
///   with the other panel active;
/// - exactly one panel is active, and it is lit;
/// - the report and the hinge reading have not changed for `steadySeconds`.
public enum FBSimulatorLitInactivePolicy {
  /// Longest measured lit inactive span of a real fold: the 3 s inner dwell after a close (up to
  /// 3.2 s on iOS 27.2, about 3.8 s on iOS 27.3), with margin. Below the 8 s display budget.
  public static let steadySeconds: Double = 5
  /// Reads further apart than this do not prove the report stayed the same in between.
  public static let maximumGapSeconds: Double = 1
  /// `hinge set`'s default tolerance; at the end stops the sensed angle equals the mechanical one.
  public static let endStopToleranceDegrees: Double = 0.5
  static let litBacklightStates: Set<String> = ["activeOn", "activeDimmed"]

  /// Whether any display with an explicit `active: false` is lit.
  public static func hasLitInactivePanel(_ rows: [FBSimulatorDisplayInfoRow]) -> Bool {
    rows.contains { $0.active == false && litBacklightStates.contains($0.backlightState ?? "") }
  }

  /// The identity of a trustworthy lit inactive report, or nil when the report contradicts the hinge
  /// or could be part of a fold. The hinge values come from a separate native read.
  public static func fingerprint(_ rows: [FBSimulatorDisplayInfoRow], bootIdentity: String,
                                 mechanicalDegrees: Double, sensedDegrees: Double,
                                 velocityDegreesPerSecond: Double, maximumDegrees: Double) -> FBSimulatorDisplayFingerprint? {
    let panels = rows.filter(\.integrated).sorted { $0.displayID < $1.displayID }
    guard panels.count == 2, panels.allSatisfy({ $0.active != nil }), hasLitInactivePanel(panels),
          !hasLitInactivePanel(rows.filter { !$0.integrated }),
          [mechanicalDegrees, sensedDegrees, velocityDegreesPerSecond, maximumDegrees].allSatisfy(\.isFinite),
          velocityDegreesPerSecond == 0 else { return nil }
    let active = panels.filter { $0.active == true }
    guard active.count == 1, let only = active.first, litBacklightStates.contains(only.backlightState ?? "") else {
      return nil
    }
    let tolerance = endStopToleranceDegrees
    let closed = mechanicalDegrees <= tolerance && sensedDegrees <= tolerance
    let open = mechanicalDegrees >= maximumDegrees - tolerance && sensedDegrees >= maximumDegrees - tolerance
    guard (closed && only.primary) || (open && !only.primary) else { return nil }
    return FBSimulatorDisplayFingerprint(bootIdentity: bootIdentity,
      panels: panels.map { .init(displayID: $0.displayID, uniqueID: $0.uniqueID, active: $0.active,
        backlightState: $0.backlightState, currentOrientation: $0.currentOrientation.rawValue) },
      mechanicalDegrees: mechanicalDegrees, sensedDegrees: sensedDegrees)
  }
}

/// The whole integrated display report and the hinge reading, within one simulator boot.
public struct FBSimulatorDisplayFingerprint: Codable, Equatable, Sendable {
  public struct Panel: Codable, Equatable, Sendable {
    let displayID: UInt32
    let uniqueID: UUID
    let active: Bool?
    let backlightState: String?
    let currentOrientation: String
  }
  let bootIdentity: String
  let panels: [Panel]
  let mechanicalDegrees: Double
  let sensedDegrees: Double
}

/// One simulator's steadiness record. Times are host uptime, which every process shares.
public struct FBSimulatorDisplaySteadinessEntry: Codable, Equatable, Sendable {
  let fingerprint: FBSimulatorDisplayFingerprint
  let firstSeen: TimeInterval
  var lastSeen: TimeInterval
  var proven: Bool
}

/// Where steadiness records live. The CLI process reads the display before it hands input to the
/// per-device broker, which reads it again, so the record is shared between processes.
public protocol FBSimulatorDisplaySteadinessStore: Sendable {
  func load(_ key: String) -> FBSimulatorDisplaySteadinessEntry?
  func save(_ entry: FBSimulatorDisplaySteadinessEntry?, for key: String)
}

/// Tracks, per simulator, how long one trustworthy lit inactive report has stayed unchanged. Reads
/// must be at most `maximumGapSeconds` apart until the report has stayed the same for
/// `steadySeconds`; after that the same report is accepted at once, so later commands and the
/// broker do not wait again. Any other report, or an ordinary one, forgets it.
public final class FBSimulatorDisplaySteadiness: @unchecked Sendable {
  public static let shared = FBSimulatorDisplaySteadiness(store: FBSimulatorDisplaySteadinessFileStore.privateTemporary()
    ?? FBSimulatorDisplaySteadinessMemoryStore())

  private let lock = NSLock()
  private let clock: @Sendable () -> TimeInterval
  private let store: any FBSimulatorDisplaySteadinessStore

  public init(store: any FBSimulatorDisplaySteadinessStore = FBSimulatorDisplaySteadinessMemoryStore(),
              clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.store = store
    self.clock = clock
  }

  /// Records one read of a trustworthy lit inactive report. Returns true once it is steady.
  public func observe(_ fingerprint: FBSimulatorDisplayFingerprint, simulatorUDID: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    let now = clock()
    let key = simulatorUDID.uppercased()
    // A record from the future (the host restarted) proves nothing.
    if var entry = store.load(key), entry.fingerprint == fingerprint, entry.firstSeen <= now, entry.lastSeen <= now,
       entry.proven || now - entry.lastSeen <= FBSimulatorLitInactivePolicy.maximumGapSeconds {
      entry.lastSeen = now
      entry.proven = entry.proven || now - entry.firstSeen >= FBSimulatorLitInactivePolicy.steadySeconds
      store.save(entry, for: key)
      return entry.proven
    }
    store.save(FBSimulatorDisplaySteadinessEntry(fingerprint: fingerprint, firstSeen: now, lastSeen: now, proven: false),
      for: key)
    return false
  }

  /// Records a read with no trustworthy lit inactive report: an ordinary report or a changing one.
  public func forget(simulatorUDID: String) {
    lock.lock(); defer { lock.unlock() }
    store.save(nil, for: simulatorUDID.uppercased())
  }
}

public final class FBSimulatorDisplaySteadinessMemoryStore: FBSimulatorDisplaySteadinessStore, @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String: FBSimulatorDisplaySteadinessEntry] = [:]
  public init() {}
  public func load(_ key: String) -> FBSimulatorDisplaySteadinessEntry? {
    lock.lock(); defer { lock.unlock() }
    return entries[key]
  }
  public func save(_ entry: FBSimulatorDisplaySteadinessEntry?, for key: String) {
    lock.lock(); defer { lock.unlock() }
    entries[key] = entry
  }
}

/// One small file per simulator in a directory only this user can read or write. Forgetting is a
/// single unlink, so an ordinary display read does no more than that.
public final class FBSimulatorDisplaySteadinessFileStore: FBSimulatorDisplaySteadinessStore, Sendable {
  private let directory: URL

  public init?(directory: URL) {
    let path = directory.path
    if mkdir(path, 0o700) != 0 && errno != EEXIST { return nil }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
          info.st_mode & 0o077 == 0 else { return nil }
    self.directory = directory
  }

  static func privateTemporary() -> FBSimulatorDisplaySteadinessFileStore? {
    FBSimulatorDisplaySteadinessFileStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
      .resolvingSymlinksInPath().appendingPathComponent("axe-display-\(getuid())", isDirectory: true))
  }

  private func file(_ key: String) -> URL? {
    guard UUID(uuidString: key) != nil else { return nil }
    return directory.appendingPathComponent(key + ".json")
  }

  public func load(_ key: String) -> FBSimulatorDisplaySteadinessEntry? {
    guard let url = file(key) else { return nil }
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
          info.st_size < 16_384, let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(FBSimulatorDisplaySteadinessEntry.self, from: data)
  }

  public func save(_ entry: FBSimulatorDisplaySteadinessEntry?, for key: String) {
    guard let url = file(key) else { return }
    guard let entry, let data = try? JSONEncoder().encode(entry) else {
      unlink(url.path)
      return
    }
    // Write beside the record and rename over it, so a reader never sees half a record.
    let temporary = directory.appendingPathComponent(key + "." + UUID().uuidString + ".tmp")
    guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
          rename(temporary.path, url.path) == 0 else {
      unlink(temporary.path)
      return
    }
  }
}

/// What one display report allows.
public enum FBSimulatorLitInactiveVerdict: Sendable, Equatable {
  /// No lit inactive panel: the ordinary rules apply.
  case ordinary
  /// A lit inactive panel that contradicts the hinge or could be part of a fold: refuse.
  case untrusted
  /// Consistent with the hinge, but not unchanged for `steadySeconds` yet.
  case settling
  /// Consistent with the hinge and unchanged for longer than a fold takes: accept its active flag.
  case steady
}

extension FBSimulatorDisplaySteadiness {
  /// Records one display report. An ordinary report needs nothing more; `hinge` is read only for a
  /// report with a lit inactive panel.
  public func verdict(_ response: FBSimulatorDisplayInfoResponse, simulatorUDID: String, bootIdentity: String,
                      hinge: () async throws -> FBSimulatorHingeObservation?) async -> FBSimulatorLitInactiveVerdict {
    guard FBSimulatorLitInactivePolicy.hasLitInactivePanel(response.rows) else {
      forget(simulatorUDID: simulatorUDID)
      return .ordinary
    }
    guard let sample = try? await hinge(),
          let fingerprint = FBSimulatorLitInactivePolicy.fingerprint(response.rows, bootIdentity: bootIdentity,
            mechanicalDegrees: sample.mechanicalDegrees, sensedDegrees: sample.sensedDegrees,
            velocityDegreesPerSecond: sample.velocityDegreesPerSecond, maximumDegrees: sample.maximumDegrees) else {
      forget(simulatorUDID: simulatorUDID)
      return .untrusted
    }
    return observe(fingerprint, simulatorUDID: simulatorUDID) ? .steady : .settling
  }
}
