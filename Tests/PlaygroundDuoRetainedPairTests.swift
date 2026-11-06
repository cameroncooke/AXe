import Foundation
import Testing

enum PlaygroundRetainedPairMode: String, CaseIterable { case normal, open, rotate }

@Suite("Playground Duo Retained Native Pair", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoRetainedPairTests {
    @Test("Retained library pair preserves identity and rejects old input after layout change", arguments: PlaygroundRetainedPairMode.allCases)
    func retainedPair(mode: PlaygroundRetainedPairMode) async throws {
        if mode == .open { try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {} }
        let app = try await prepareDuoControls(mode == .rotate ? .inner90 : .outer0)
        let executable = try #require(ProcessInfo.processInfo.environment["AXE_DUO_RETAINED_PAIR_PATH"])
        try #require(FileManager.default.isExecutableFile(atPath: executable))
        let frame = try await app.frame("feature.pad")
        let x = frame.x + frame.width / 2
        let y = frame.y + frame.height / 2
        let before = try app.documents.read()
        let panel = app.catalogue.activePanel.identity
        let configuration = ControlsRetainedPairConfiguration(simulatorUDID: app.app.udid, bootIdentity: app.catalogue.bootIdentity,
            screenID: panel.displayID, screenUUID: panel.uniqueID,
            first: .init(x: x - 25, y: y), second: .init(x: x + 25, y: y),
            movedFirst: .init(x: x - 15, y: y), movedSecond: .init(x: x + 35, y: y),
            staleFirst: .init(x: x - 10, y: y), staleSecond: .init(x: x + 40, y: y),
            coordinationDirectory: app.artifacts.path, mode: mode == .open ? "fold" : mode.rawValue, hingeDegrees: 180)
        let file = app.artifacts.appendingPathComponent("pair-configuration.json")
        try JSONEncoder().encode(configuration).write(to: file)
        let probe = try PlaygroundTestProcess(executable: executable, arguments: ["pair", file.path], directory: app.artifacts, name: "pair")
        do {
            try probe.start()
            let began = try await pairStage(probe, name: "began")
            try #require(began.operation?.outcome == "retained" && began.operation?.normalEventDelta == 1 && began.operation?.tokenReturned == true)
            let held = try await app.documents.waitFor("two actual retained contacts") { $0.activeWindowTouches == 2 }
            let initial = Array(held.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
            let identities = Set(initial.map(\.contactID))
            try #require(identities.count == 2)
            try Data("continue\n".utf8).write(to: app.artifacts.appendingPathComponent("move.ready"))
            let moved = try await pairStage(probe, name: "moved")
            try #require(moved.operation?.outcome == "moved" && moved.operation?.normalEventDelta == 1 && moved.operation?.sameOriginalToken == true)
            _ = try await app.documents.waitFor("both original retained fingers moved") { state in
                let suffix = Array(state.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
                let last = identities.compactMap { identity in suffix.last { $0.contactID == identity } }
                return state.activeWindowTouches == 2 && last.count == 2
                    && last.contains { abs($0.x - (x - 15)) <= 2 && abs($0.y - y) <= 2 }
                    && last.contains { abs($0.x - (x + 35)) <= 2 && abs($0.y - y) <= 2 }
            }
            if mode != .normal {
                let changed = try await changeDuoControls(app, change: mode == .open ? .open : .rotate)
                let degrees = try changed.activePanel.rotationDegrees()
                try #require(degrees == (mode == .open ? 90 : 180))
            }
            try Data("continue\n".utf8).write(to: app.artifacts.appendingPathComponent("finish.ready"))
            if mode == .normal {
                let ended = try await pairStage(probe, name: "ended")
                try #require(ended.operation?.outcome == "endedAndDrained" && ended.operation?.normalEventDelta == 1 && ended.operation?.tokenReturned == false)
            } else {
                let idle = try await pairStage(probe, name: "idleAfterChange")
                try #require(idle.status.state == "invalidated")
                try #require(!idle.status.hasRetainedContact && idle.status.lastCleanup == "releaseEnqueuedAndDrained")
                let automaticRelease = try await app.documents.waitFor("both contacts released before stale commands") { $0.activeWindowTouches == 0 }
                try requireReleasedContacts(automaticRelease, before: before, count: 2)
                let cleanup = try #require(idle.cleanupEvidence)
                try #require(cleanup.trigger == "staleContext")
                try requirePairCleanupIdentity(cleanup, app: app)
                try #require(cleanup.outcome == "releaseEnqueuedAndDrained" && cleanup.contextValidation == "releaseIdentityMatchedBeforeAndAfter" && !cleanup.timedOut)
                try #require(cleanup.releases.count == 1 && cleanup.releases[0].primitive == "TwoFingerTouch <hidden>" && cleanup.releases[0].returnedSuccessfully)
                try Data("continue\n".utf8).write(to: app.artifacts.appendingPathComponent("stale-move.ready"))
                let first = try await pairStage(probe, name: "oldMove1")
                try #require(first.operation?.normalEventDelta == 0 && first.operation?.error != nil && first.cleanupEvidence == cleanup)
                try Data("continue\n".utf8).write(to: app.artifacts.appendingPathComponent("second-stale.ready"))
                let second = try await pairStage(probe, name: "oldMove2")
                let end = try await pairStage(probe, name: "oldEnd")
                try #require(second.operation?.normalEventDelta == 0 && second.operation?.error != nil && second.cleanupEvidence == cleanup)
                try #require(end.operation?.normalEventDelta == 0 && end.operation?.error != nil && end.cleanupEvidence == cleanup)
                try #require(try app.documents.read().windowTouchTrace.count == automaticRelease.windowTouchTrace.count)
            }
            let closed = try await pairStage(probe, name: "closed")
            try #require(!closed.status.hasRetainedContact && closed.operation?.tokenReturned == false)
            if mode != .normal { try #require(closed.operation?.normalEventDelta == 0) }
            try await probe.wait(timeout: 5)
            try #require(probe.exitCode == 0)
            let after = try await app.documents.waitFor("no contacts after pair close") { $0.activeWindowTouches == 0 }
            try requireReleasedContacts(after, before: before, count: 2)
            try await app.freshTap()
        } catch {
            try? Data("abort\n".utf8).write(to: app.artifacts.appendingPathComponent("abort.ready"))
            await probe.finish()
            throw error
        }
        await probe.finish()
    }
}

private struct ControlsRetainedPairConfiguration: Encodable {
    struct Point: Encodable { let x: Double; let y: Double }
    let simulatorUDID: String; let bootIdentity: String; let screenID: UInt32; let screenUUID: UUID
    let first: Point; let second: Point; let movedFirst: Point; let movedSecond: Point; let staleFirst: Point; let staleSecond: Point
    let coordinationDirectory: String; let mode: String; let hingeDegrees: Double
}
private struct ControlsPairStage: Decodable {
    let frameworkPath: String
    let stage: String; let status: Status; let operation: Operation?; let cleanupEvidence: Cleanup?; let feedValidation: String?
    struct Status: Decodable { let state: String; let hasRetainedContact: Bool; let normalEnqueuedEventCount: Int; let lastCleanup: String }
    struct Operation: Decodable { let outcome: String?; let error: String?; let normalEventDelta: Int; let tokenReturned: Bool?; let sameOriginalToken: Bool? }
    struct Cleanup: Decodable, Equatable {
        let trigger: String; let outcome: String; let contextValidation: String; let timedOut: Bool; let releases: [Release]
        let boundSimulatorUDID: String; let boundBootIdentity: String; let boundScreenID: UInt32; let boundScreenUUID: String
        let boundNativeWidth: Double; let boundNativeHeight: Double; let boundScale: Double; let boundRotation: Int; let boundPoseRevision: String
        let drainCompletedUptime: Double?
        struct Release: Decodable, Equatable {
            let primitive: String; let returnedSuccessfully: Bool; let startedUptime: Double; let finishedUptime: Double?; let errorDescription: String?
            let transport: Transport?
        }
        struct Transport: Decodable, Equatable {
            let messageType: String; let startedUptime: Double; let hostEnqueueCompletedUptime: Double?; let guestBarrierStartedUptime: Double?; let guestBarrierCompletedUptime: Double?; let errorDescription: String?
        }
    }
}
private func pairStage(_ process: PlaygroundTestProcess, name: String) async throws -> ControlsPairStage {
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    repeat {
        let rows = try process.output().split(separator: "\n").filter { $0.last == "}" }.map {
            try JSONDecoder().decode(ControlsPairStage.self, from: Data($0.utf8))
        }.filter { $0.stage == name }
        if let match = rows.first {
            try #require(rows.count == 1)
            let runtimeDirectory = URL(fileURLWithPath: try TestHelpers.getAxePath())
                .deletingLastPathComponent().standardizedFileURL.path + "/"
            try #require(match.frameworkPath.hasPrefix(runtimeDirectory))
            return match
        }
        let diagnostics = try process.diagnostics()
        try #require(process.isRunning, "Native pair probe ended before \(name): \(diagnostics)")
        try await Task.sleep(nanoseconds: 30_000_000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw TestError.unexpectedState("Native pair probe did not reach \(name).")
}

private func requirePairCleanupIdentity(_ cleanup: ControlsPairStage.Cleanup, app: PlaygroundControlsSession) throws {
    let panel = app.catalogue.activePanel
    let rotation = try panel.rotationDegrees()
    try #require(UUID(uuidString: cleanup.boundSimulatorUDID) == UUID(uuidString: app.app.udid))
    try #require(cleanup.boundBootIdentity == app.catalogue.bootIdentity && cleanup.boundScreenID == panel.identity.displayID)
    try #require(UUID(uuidString: cleanup.boundScreenUUID) == panel.identity.uniqueID)
    try #require(cleanup.boundNativeWidth == panel.nativePixelWidth && cleanup.boundNativeHeight == panel.nativePixelHeight
        && cleanup.boundScale == Double(panel.pointScale) && cleanup.boundRotation == rotation && !cleanup.boundPoseRevision.isEmpty)
    let drain = try #require(cleanup.drainCompletedUptime)
    for release in cleanup.releases {
        let finished = try #require(release.finishedUptime)
        let transport = try #require(release.transport)
        let host = try #require(transport.hostEnqueueCompletedUptime)
        let guestStart = try #require(transport.guestBarrierStartedUptime)
        let guestEnd = try #require(transport.guestBarrierCompletedUptime)
        try #require(release.returnedSuccessfully && release.errorDescription == nil && finished >= release.startedUptime && drain >= finished)
        try #require(transport.messageType == "IndigoDigitizerEvent" && transport.errorDescription == nil)
        try #require(host >= transport.startedUptime && guestStart >= host && guestEnd >= guestStart && finished >= guestEnd)
    }
}
