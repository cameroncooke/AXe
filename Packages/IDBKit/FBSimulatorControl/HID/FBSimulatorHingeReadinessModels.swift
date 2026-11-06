import Foundation

/// A post-write comparator. It does not authorize input on this screen.
public struct FBSimulatorHingeReadinessRequest: Codable, Sendable {
  public let screenID: UInt32
  public let screenUUID: UUID
  public let timeoutSeconds: Double
  public init(screenID: UInt32, screenUUID: UUID, timeoutSeconds: Double = 8) throws {
    guard timeoutSeconds.isFinite, (0.5...15).contains(timeoutSeconds) else {
      throw FBSimulatorHingeReadinessError(.invalidRequest, "Readiness timeout must be finite and in 0.5...15 seconds")
    }
    self.screenID = screenID; self.screenUUID = screenUUID; self.timeoutSeconds = timeoutSeconds
  }
}

public enum FBSimulatorHingeReadinessFailureCode: String, Codable, Sendable {
  case invalidRequest, busy, closed, deadline, attemptLimit, cancelled
  case bootChanged, unsupported, unavailable, mechanicalTargetChanged, observationCleanupUnconfirmed
  case changedDuringRead, selectedRotationMismatch, inactiveSelection
}

public enum FBSimulatorHingeObserverCleanup: String, Codable, Sendable {
  case confirmed, unconfirmed
}

public struct FBSimulatorHingeReadinessError: Error, Codable, Sendable {
  public let code: FBSimulatorHingeReadinessFailureCode
  public let detail: String
  public let detailTruncated: Bool
  public let cleanup: FBSimulatorHingeObserverCleanup
  public init(_ code: FBSimulatorHingeReadinessFailureCode, _ detail: String,
       cleanup: FBSimulatorHingeObserverCleanup = .confirmed) {
    self.code = code
    self.detail = String(decoding: detail.utf8.prefix(256), as: UTF8.self)
    detailTruncated = detail.utf8.count > 256
    self.cleanup = cleanup
  }
  var permitsTransitionRetry: Bool {
    cleanup == .confirmed && [.changedDuringRead, .selectedRotationMismatch, .inactiveSelection].contains(code)
  }
}

/// Compact, measured state only. Timestamps do not take part in coherence equality.
public struct FBSimulatorHingeDisplayObservation: Codable, Sendable {
  public let simulatorUDID: UUID
  public let bootIdentity: String
  public let screenID: UInt32
  public let screenUUID: UUID
  public let axDisplayID: UInt32
  public let nativePixelWidth: Double
  public let nativePixelHeight: Double
  public let scale: Double
  public let rotation: Int
  public let poseRevision: String
  public let hostRawPowerState: Int32
  public let hostRawBacklightState: Int32?
  public let joinedPanels: [ActivePanelIdentity]
  public let mechanicalBefore: Double
  public let mechanicalAfter: Double
  public let velocityBefore: Double
  public let velocityAfter: Double
  public let startedUptime: Double
  public let finishedUptime: Double

  func coherent(with other: Self) -> Bool {
    simulatorUDID == other.simulatorUDID && bootIdentity == other.bootIdentity &&
      screenID == other.screenID && screenUUID == other.screenUUID && axDisplayID == other.axDisplayID &&
      nativePixelWidth == other.nativePixelWidth && nativePixelHeight == other.nativePixelHeight &&
      scale == other.scale && rotation == other.rotation && poseRevision == other.poseRevision &&
      hostRawPowerState == other.hostRawPowerState && hostRawBacklightState == other.hostRawBacklightState &&
      joinedPanels == other.joinedPanels && mechanicalBefore == other.mechanicalBefore && mechanicalAfter == other.mechanicalAfter
  }
}

public struct FBSimulatorHingeReadinessAttempt: Codable, Sendable {
  public let index: Int
  public let startedUptime: Double
  public let finishedUptime: Double
  public let failure: FBSimulatorHingeReadinessError?
}

public struct FBSimulatorHingeReadinessReceipt: Codable, Sendable {
  public enum Outcome: String, Codable, Sendable { case coherent, incomplete }
  public let outcome: Outcome
  public let expected: FBSimulatorHingeReadinessRequest
  public let expectedBootIdentity: String
  public let startedUptime: Double
  public let finishedUptime: Double
  public let attempts: [FBSimulatorHingeReadinessAttempt]
  public let coherentObservations: [FBSimulatorHingeDisplayObservation]
  public let lastObservation: FBSimulatorHingeDisplayObservation?
  public let failure: FBSimulatorHingeReadinessError?
  public let cleanup: FBSimulatorHingeObserverCleanup
}
