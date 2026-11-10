import Foundation

public struct ActivePanelIdentity: Codable, Hashable, Sendable {
    public let displayID: UInt32
    public let uniqueID: UUID
    public init(displayID: UInt32, uniqueID: UUID) {
        self.displayID = displayID
        self.uniqueID = uniqueID
    }
}

/// Independent host geometry for active-panel discovery; no active state or rotation is assumed.
public struct ActivePanelCatalogEntry: Codable, Equatable, Sendable {
    public let identity: ActivePanelIdentity
    public let nativePixelWidth: Double
    public let nativePixelHeight: Double
    public let scale: Double

    public init(identity: ActivePanelIdentity, nativePixelWidth: Double,
                nativePixelHeight: Double, scale: Double) {
        self.identity = identity
        self.nativePixelWidth = nativePixelWidth
        self.nativePixelHeight = nativePixelHeight
        self.scale = scale
    }
}

public enum ActivePanelRotation: String, Codable, Sendable {
    case rot0, rot90, rot180, rot270
}

/// Values must come from the independently joined host and guest catalog.
public struct ActivePanelExpectation: Codable, Equatable, Sendable {
    public let identity: ActivePanelIdentity
    public let nativePixelWidth: Double
    public let nativePixelHeight: Double
    public let scale: Double
    public let rotation: ActivePanelRotation
    public init(identity: ActivePanelIdentity, nativePixelWidth: Double,
                nativePixelHeight: Double, scale: Double, rotation: ActivePanelRotation) {
        self.identity = identity
        self.nativePixelWidth = nativePixelWidth
        self.nativePixelHeight = nativePixelHeight
        self.scale = scale
        self.rotation = rotation
    }
}

/// A display report with several integrated panels must flag exactly one as active. A report
/// that omits the flag can select only one lit primary panel.
public enum ActivePanelSchemaPolicy: String, Codable, Sendable {
    case explicitActiveFlag
}

public enum ActivePanelSelectionBasis: String, Codable, Sendable {
    case explicitActiveFlag
    /// The explicit flag of a report with a lit inactive panel that stayed unchanged and matched
    /// the hinge for longer than a fold takes (`FBSimulatorLitInactivePolicy`).
    case steadyExplicitActiveFlag
    case verifiedSingleIntegratedPanel
}

public struct ActivePanel: Codable, Equatable, Sendable {
    public let identity: ActivePanelIdentity
    public let active: Bool?
    public let primary: Bool
    public let currentOrientation: ActivePanelRotation
    public let nativeOrientation: ActivePanelRotation
    public let nativePixelWidth: Double
    public let nativePixelHeight: Double
    public let boundsOriginX: Double
    public let boundsOriginY: Double
    public let boundsWidth: Double
    public let boundsHeight: Double
    public let pointScale: Int
    public let backlightState: String?
}

public struct ActivePanelSnapshot: Codable, Sendable {
    public let requestedSimulatorUDID: UUID
    public let sourceCommandType: String
    public let sourceJSONVersion: Int
    public let sourceVersion: String
    public let activePanel: ActivePanel
    public let selectionBasis: ActivePanelSelectionBasis
    public let panels: [ActivePanel]
}

public enum ActivePanelValidationError: Error, Equatable, Sendable {
    case invalidExpectedCatalog
    case invalidSelectedExpectation
    case invalidDisplayCount
    case duplicateIdentity
    case catalogMismatch
    case catalogGeometryMismatch(UInt32)
    case invalidGeometry(UInt32)
    case activeStateUnavailable(Int)
    case missingActiveFlag
    case inactiveSelection(requested: ActivePanelIdentity, observed: ActivePanelIdentity)
    case selectedGeometryMismatch
    case selectedRotationMismatch
}

public enum ActivePanelChildFailure: String, Codable, Sendable {
    case cancelled, deadline, outputLimit, launchFailed, nonzeroExit
    case cleanupUnconfirmed, ioFailure, missingJSON
}

/// Diagnostic fields do not belong in semantic context equality.
public struct ActivePanelChildReceipt: Codable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let startedUptime: Double
    public let finishedUptime: Double
    public let processIdentifier: Int32?
    public let launchAttempted: Bool
    public let launchReturned: Bool
    public let exitConfirmed: Bool
    public let terminationStatus: Int32?
    public let terminationReason: String?
    public let stopReason: ActivePanelChildFailure?
    public let detail: String?
    public let sentTerminate: Bool
    public let sentKill: Bool
    public let json: Data
    public let stderr: Data
}

public struct ActivePanelReadError: Error, Sendable {
    public let childFailure: ActivePanelChildFailure?
    public let validationFailure: ActivePanelValidationError?
    public let receipt: ActivePanelChildReceipt?
    public init(childFailure: ActivePanelChildFailure? = nil,
                validationFailure: ActivePanelValidationError? = nil,
                receipt: ActivePanelChildReceipt? = nil) {
        self.childFailure = childFailure
        self.validationFailure = validationFailure
        self.receipt = receipt
    }
}

public struct ActivePanelReadback: Sendable {
    public let snapshot: ActivePanelSnapshot
    public let receipt: ActivePanelChildReceipt
}

/// Metadata for a completed full discovery read, separate from physical panel snapshots.
/// Uptime values use the host monotonic clock. They are not frame times or an admission lease.
public struct ActivePanelDiscoveryResult: Sendable {
    public let readback: ActivePanelReadback
    public let bootIdentity: String
    public let startedUptime: Double
    public let finishedUptime: Double
}
