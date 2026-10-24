import Foundation
import Testing

struct PlaygroundNativeCleanup: Decodable {
    let boundSimulatorUDID: String
    let boundBootIdentity: String
    let boundScreenID: UInt32
    let boundScreenUUID: String
    let contextValidation: String
    let timedOut: Bool
    let outcome: String?
    let drainCompletedUptime: Double?
    let identityBefore: Identity?
    let identityAfter: Identity?
    let releases: [Release]
    struct Identity: Decodable {
        let simulatorUDID: String
        let bootIdentity: String
        let screenID: UInt32
        let screenUUID: String
    }
    struct Release: Decodable {
        let primitive: String
        let startedUptime: Double
        let finishedUptime: Double?
        let returnedSuccessfully: Bool
        let errorDescription: String?
        let transport: Transport?
    }
    struct Transport: Decodable {
        let messageType: String
        let startedUptime: Double
        let hostEnqueueCompletedUptime: Double?
        let guestBarrierStartedUptime: Double?
        let guestBarrierCompletedUptime: Double?
        let errorDescription: String?
    }

    func requireOwnedReleases(_ expected: Set<String>, messageType: String,
                              catalogue: DuoCatalogue, udid: String, changedAt: Double) throws {
        try #require(outcome == "releaseEnqueuedAndDrained" && !timedOut)
        try #require(contextValidation == "releaseIdentityMatchedBeforeAndAfter")
        let original = catalogue.activePanel.identity
        try #require(UUID(uuidString: boundSimulatorUDID) == UUID(uuidString: udid))
        try #require(boundBootIdentity == catalogue.bootIdentity && boundScreenID == original.displayID)
        try #require(UUID(uuidString: boundScreenUUID) == original.uniqueID)
        let primitives = Set(releases.map(\.primitive))
        try #require(primitives == expected && releases.count == expected.count)
        let drained = try #require(drainCompletedUptime)
        for release in releases {
            try #require(release.returnedSuccessfully && release.errorDescription == nil)
            try #require(release.startedUptime >= changedAt)
            let ended = try #require(release.finishedUptime)
            try #require(ended >= release.startedUptime && drained >= ended)
            let transport = try #require(release.transport)
            try #require(transport.messageType == messageType && transport.errorDescription == nil)
            let enqueued = try #require(transport.hostEnqueueCompletedUptime)
            let guestStart = try #require(transport.guestBarrierStartedUptime)
            let guestEnd = try #require(transport.guestBarrierCompletedUptime)
            try #require(enqueued >= transport.startedUptime && guestStart >= enqueued && guestEnd >= guestStart)
        }
        for identity in [try #require(identityBefore), try #require(identityAfter)] {
            try #require(UUID(uuidString: identity.simulatorUDID) == UUID(uuidString: udid))
            try #require(identity.bootIdentity == catalogue.bootIdentity && identity.screenID == original.displayID)
            try #require(UUID(uuidString: identity.screenUUID) == original.uniqueID)
        }
    }
}

struct PlaygroundNativeHoldReceipt: Decodable {
    let frameworkPath: String
    let downMarkerWritten: Bool
    let outcome: String
    let normalEventCount: Int
    let phase: String?
    let interruption: String?
    let normalDrainCompleted: Bool?
    let cleanup: String
    let cleanupEvidence: PlaygroundNativeCleanup?
}

struct PlaygroundNativeDownMarker: Decodable {
    let source: String
    let button: String
    let normalDownSentCount: Int
    let state: String
    let capturedUptime: Double
    let normalSendCompleted: Bool
    let wholeGestureDrainCompleted: Bool
    let device: String
    let boot: String
    let screenID: UInt32
    let screenUUID: String
}

struct PlaygroundExternalLayoutReceipt: Decodable {
    let mode: String
    let startedUptime: Double
    let finishedUptime: Double
}

func preparePlaygroundChangingScreen(pose: DuoPlaygroundPose, rotation: Int,
                                    check: () async throws -> Void) async throws {
    let device = try DuoPlaygroundSession()
    let original = try await device.catalogue()
    var current = try await device.setPose(pose, boot: original.bootIdentity)
    for _ in 0..<4 {
        if try current.activePanel.rotationDegrees() == rotation { break }
        current = try await device.rotateRight(catalogue: current)
    }
    let actual = try current.activePanel.rotationDegrees()
    try #require(actual == rotation)
    let target = DuoPlaygroundLaunchTarget(bootIdentity: current.bootIdentity, panel: current.activePanel)
    try await DuoPlaygroundLaunchTarget.$current.withValue(target) { try await check() }
}

func playgroundShellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
