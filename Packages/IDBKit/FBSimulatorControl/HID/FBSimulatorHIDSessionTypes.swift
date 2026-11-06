import CoreGraphics
import Foundation

/// One externally measured revision. Pose revision must change on folding even if this panel's
/// identity, dimensions and rotation do not. It is not an inferred active-panel flag.
public struct FBSimulatorHIDSessionObservation: Equatable, Sendable {
  public let simulatorUDID: String
  public let bootIdentity: String
  public let screenID: UInt32
  public let screenUniqueID: String
  public let axDisplayID: UInt32
  public let displayContext: FBSimulatorHIDDisplayContext
  public let poseRevision: String

  public init(simulatorUDID: String, bootIdentity: String, screenID: UInt32,
              screenUniqueID: String, axDisplayID: UInt32,
              displayContext: FBSimulatorHIDDisplayContext, poseRevision: String) throws {
    guard !simulatorUDID.isEmpty, !bootIdentity.isEmpty, !screenUniqueID.isEmpty,
          !poseRevision.isEmpty else {
      throw FBSimulatorHIDSessionError.invalidObservation("Identity and pose revision are required")
    }
    self.simulatorUDID = simulatorUDID
    self.bootIdentity = bootIdentity
    self.screenID = screenID
    self.screenUniqueID = screenUniqueID
    self.axDisplayID = axDisplayID
    self.displayContext = displayContext
    self.poseRevision = poseRevision
  }
}

/// Implementations must read current measured state, use bounded operations and throw when any
/// required observation is unavailable. Returning a cached revision defeats transition protection.
public protocol FBSimulatorHIDFreshnessProvider: Sendable {
  func observation() async throws -> FBSimulatorHIDSessionObservation
}

public struct FBSimulatorHIDContactToken: Equatable, Sendable {
  let sessionID: UUID
  let contactID: UUID
}

public enum FBSimulatorHIDSessionState: String, Sendable {
  case ready, executing, retainedContacts, retainedInputs, draining, invalidated, closed
}

/// These describe transport actions, never fixture/UI confirmation.
public enum FBSimulatorHIDCleanupOutcome: String, Sendable {
  case notNeeded
  case releaseEnqueuedAndDrained
  case uncertain
}

public enum FBSimulatorHIDInterruption: Equatable, Sendable {
  case cancelled
  case staleContext
  case observationUnavailable(String)
  case transportFailure(String)
  case invalidRetainedInput(String)
  case inputAdmissionRejected(String)
}

public enum FBSimulatorHIDSessionError: Error, Sendable {
  case busy
  case closed
  case invalidated
  case invalidToken
  case retainedContactExists
  case invalidObservation(String)
  case invalidEvent(String)
  case interrupted(reason: FBSimulatorHIDInterruption, cleanup: FBSimulatorHIDCleanupOutcome)
}

public enum FBSimulatorHIDSessionOutcome: String, Sendable {
  case enqueuedAndDrained
  case retained
  case moved
  case endedAndDrained
  case closed
}

public struct FBSimulatorHIDSessionReceipt: Sendable {
  public let outcome: FBSimulatorHIDSessionOutcome
  public let token: FBSimulatorHIDContactToken?
  public let enqueuedEventCount: Int
  public let elapsedSeconds: Double
  public let cleanup: FBSimulatorHIDCleanupOutcome
}

public struct FBSimulatorHIDSessionStatus: Sendable {
  public let state: FBSimulatorHIDSessionState
  public let hasRetainedContact: Bool
  public let enqueuedEventCount: Int
  public let lastCleanup: FBSimulatorHIDCleanupOutcome
}

public struct FBSimulatorHIDPreflight: Sendable {
  public let primitiveCount: Int
  public let requestedDelaySeconds: Double
}

/// Last complete or owned-part execute phase. This is transport evidence, not a UI result.
public enum FBSimulatorHIDExecutionPhase: String, Sendable {
  case beforeInput, admission, primitive, delay, drain, finalContextCheck, completed
}

/// Frozen when one complete or owned-part execute call returns or throws. Close preserves it.
/// Nil means no execute reached execution after its preflight checks.
public struct FBSimulatorHIDExecutionEvidence: Sendable {
  public let operationID: UUID
  public let boundObservation: FBSimulatorHIDSessionObservation
  public let phase: FBSimulatorHIDExecutionPhase
  public let plannedPrimitiveCount: Int
  public let sentPrimitiveCount: Int
  public let allInputsReleasedBeforeCleanup: Bool
  public let drainCompleted: Bool
  public let interruption: FBSimulatorHIDInterruption?
  public let cleanup: FBSimulatorHIDCleanupOutcome
  public let startedUptime: Double
  public let finishedUptime: Double
}

// All payloads are immutable Sendable value types. No transport handle is stored in an event.
extension FBSimulatorHIDEvent: Sendable {}

/// Diagnostic transport milestones. A guest barrier reply is not a UIKit acknowledgement.
public struct FBSimulatorHIDSendEvidence: Codable, Equatable, Sendable {
  public let messageType: String
  public let startedUptime: Double
  public var hostEnqueueCompletedUptime: Double?
  public var guestBarrierStartedUptime: Double?
  public var guestBarrierCompletedUptime: Double?
  public var failedUptime: Double?
  public var failurePhase: String?
  public var errorDescription: String?
}

protocol FBSimulatorHIDCleanupTransportDiagnostics: Sendable {
  func lastSendEvidence() async -> FBSimulatorHIDSendEvidence?
}

public struct FBSimulatorHIDCleanupReleaseEvidence: Codable, Equatable, Sendable {
  public let index: Int
  public let primitive: String
  public let startedUptime: Double
  public var finishedUptime: Double?
  public var returnedSuccessfully: Bool
  public var errorDescription: String?
  public var transport: FBSimulatorHIDSendEvidence?
}

/// Evidence for the last cleanup attempt. The conservative cleanup outcome is unchanged.
/// Bound identity is the original session identity, not a new cleanup-time observation.
public struct FBSimulatorHIDCleanupEvidence: Codable, Equatable, Sendable {
  public let boundSimulatorUDID: String
  public let boundBootIdentity: String
  public let boundScreenID: UInt32
  public let boundScreenUUID: String
  public let boundNativeWidth: Double
  public let boundNativeHeight: Double
  public let boundScale: Double
  public let boundRotation: Int
  public let boundPoseRevision: String
  public let startedUptime: Double
  public let trigger: String
  public var contextValidation: String
  public var contextValidationError: String?
  public var releases: [FBSimulatorHIDCleanupReleaseEvidence]
  public var drainStartedUptime: Double?
  public var drainCompletedUptime: Double?
  public var finishedUptime: Double?
  public var timedOut: Bool
  public var errorDescription: String?
  public var outcome: String?
  public var identityBefore: FBSimulatorHIDCleanupIdentity?
  public var identityAfter: FBSimulatorHIDCleanupIdentity?
  public var identityReadError: String?
}

/// Original connection target identity, deliberately separate from active-input admission.
public struct FBSimulatorHIDCleanupIdentity: Codable, Equatable, Sendable {
  public let simulatorUDID: String
  public let bootIdentity: String
  public let screenID: UInt32
  public let screenUUID: String
  public let nativePixelWidth: Double
  public let nativePixelHeight: Double
  public let scale: Double
  public let startedUptime: Double
  public let finishedUptime: Double

  func matches(_ expected: FBSimulatorHIDSessionObservation) -> Bool {
    simulatorUDID == expected.simulatorUDID && bootIdentity == expected.bootIdentity &&
      screenID == expected.screenID && UUID(uuidString: screenUUID) == UUID(uuidString: expected.screenUniqueID) &&
      UUID(uuidString: screenUUID) != nil && nativePixelWidth == expected.displayContext.nativePixelSize.width &&
      nativePixelHeight == expected.displayContext.nativePixelSize.height && scale == expected.displayContext.scale
  }
}

/// Read-only release evidence. This cannot admit new input or replace the session's fixed target.
public protocol FBSimulatorHIDCleanupIdentityProvider: Sendable {
  func cleanupIdentity() async throws -> FBSimulatorHIDCleanupIdentity
}

/// Validates every keyboard down while the session owns the complete keyboard operation.
/// Implementations must use bounded reads and must not call back into the same HID session.
/// Key-up events and owned cleanup never invoke this guard.
public protocol FBSimulatorHIDKeyboardAdmissionGuard: Sendable {
  func validateKeyDown(observation: FBSimulatorHIDSessionObservation, keyCode: UInt32) async throws
}
