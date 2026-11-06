import Foundation
import Testing

enum PlaygroundDuoChange: String, CaseIterable { case fold, rotate, open }

/// The case will change the layout itself, so it verifies the new target separately.
func prepareDuoControls(_ position: DuoControlsPosition) async throws -> PlaygroundControlsSession {
    let simulator = try DuoPlaygroundSession()
    let original = try await simulator.catalogue()
    var current = try await simulator.setPose(position.pose, boot: original.bootIdentity)
    for _ in 0..<4 {
        if try current.activePanel.rotationDegrees() == position.rotation { break }
        current = try await simulator.rotateRight(catalogue: current)
    }
    let degrees = try current.activePanel.rotationDegrees()
    try #require(degrees == position.rotation)
    let target = DuoPlaygroundLaunchTarget(bootIdentity: current.bootIdentity, panel: current.activePanel)
    return try await DuoPlaygroundLaunchTarget.$current.withValue(target) { try await PlaygroundControlsSession() }
}

func changeDuoControls(_ app: PlaygroundControlsSession, change: PlaygroundDuoChange,
                       afterInputRelease: (() async throws -> Void)? = nil) async throws -> DuoCatalogue {
    let executable = try #require(ProcessInfo.processInfo.environment["AXE_DUO_STATE_CHANGE_PATH"])
    let panel = app.catalogue.activePanel.identity
    let mode = change == .rotate ? "rotate" : "fold"
    let operation = try PlaygroundTestProcess(executable: executable, arguments: [mode, app.catalogue.bootIdentity,
        String(panel.displayID), panel.uniqueID.uuidString, change == .open ? "180" : "0",
        app.artifacts.appendingPathComponent("change-marker-" + UUID().uuidString + ".json").path, app.app.udid],
        directory: app.artifacts, name: "external-" + UUID().uuidString)
    do {
        try operation.start()
        try await operation.wait(timeout: 20)
        let diagnostics = try operation.diagnostics()
        try #require(operation.exitCode == 0, "External state change failed: \(diagnostics)")
        let receipt = try JSONDecoder().decode(PlaygroundControlsStateChange.self, from: Data(try operation.output().utf8))
        try #require(receipt.mode == mode && receipt.finishedUptime >= receipt.startedUptime)
        if change != .rotate {
            let hinge = try #require(receipt.hinge)
            let expected = change == .open ? 180.0 : 0.0
            try #require(hinge.outcome == "observedMechanicalTarget" && hinge.requestedDegrees == expected && !hinge.wasAlreadyWithinTolerance)
            try #require(hinge.matchingSamples.count == 2 && hinge.matchingSamples.allSatisfy { abs($0.mechanicalDegrees - expected) <= 0.5 })
        }
        let after: DuoCatalogue
        if let afterInputRelease {
            try #require(change == .fold, "Deferred display readiness is only used after a fold and verified input release.")
            try await afterInputRelease()
            let wait = try DuoStateReadWait(phase: "raw-motion-fold-after-input-release", artifacts: app.artifacts)
            after = try await DuoStateReadWait.$current.withValue(wait) {
                try await DuoPlaygroundSession().stableCatalogue(boot: app.catalogue.bootIdentity, expectedScreenID: 1)
            }
        } else {
            after = try await DuoPlaygroundSession().catalogue(boot: app.catalogue.bootIdentity)
        }
        if change == .rotate {
            let rotated = try #require(receipt.rotation)
            let degrees = try after.activePanel.rotationDegrees()
            try #require(rotated.vendorEventCount == 1 && rotated.matchingObservationCount == 2 && rotated.before.rotation != rotated.after.rotation)
            try #require(after.activePanel.identity == panel && degrees == rotated.after.rotation)
        } else {
            try #require(after.activePanel.identity != panel)
        }
        await operation.finish()
        return after
    } catch { await operation.finish(); throw error }
}

private struct PlaygroundControlsStateChange: Decodable {
    let mode: String
    let startedUptime: Double
    let finishedUptime: Double
    let rotation: DuoCLIResponse.RotationReceipt?
    let hinge: Hinge?
    struct Hinge: Decodable {
        let outcome: String
        let requestedDegrees: Double
        let wasAlreadyWithinTolerance: Bool
        let matchingSamples: [DuoCLIResponse.HingeSample]
    }
}

func requireReleasedContacts(_ after: PlaygroundControlsDocument, before: PlaygroundControlsDocument, count: Int) throws {
    try after.requireClear()
    let added = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
    let groups = Dictionary(grouping: added, by: \.contactID)
    try #require(groups.count == count)
    for rows in groups.values {
        let first = try #require(rows.first)
        let last = try #require(rows.last)
        try #require(first.phase == "windowTouchBegan")
        try #require(["windowTouchEnded", "windowTouchCancelled"].contains(last.phase))
        try #require(rows.filter { ["windowTouchEnded", "windowTouchCancelled"].contains($0.phase) }.count == 1)
    }
}
