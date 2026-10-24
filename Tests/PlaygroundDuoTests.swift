import Foundation
import Testing

let isDuoPlaygroundE2EEnabled = {
    let value = ProcessInfo.processInfo.environment["AXE_DUO_E2E"]?.lowercased() ?? ""
    return isE2EEnabled && ["1", "true", "yes"].contains(value)
}()

/// Run alone on the dedicated Duo simulator. Every input uses a fresh measured panel.
@Suite("Playground Duo E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoTests {
    @Test("Closed, tabletop and open poses permit a fresh lookup and real button action")
    func namedHingePoses() async throws {
        let app = try DuoPlaygroundSession()
        let original = try await app.catalogue()
        let initialPID = try await app.launch()
        let initial = try await app.catalogue(boot: original.bootIdentity)
        _ = try await app.waitForButtonState("Initial", catalogue: initial, pid: initialPID)
        _ = try await app.setPose(.open, boot: original.bootIdentity)
        var panels: [DuoPlaygroundPose: DuoPanelIdentity] = [:]

        for pose in [DuoPlaygroundPose.closed, .tabletop, .open] {
            let pid = try await app.launch()
            let before = try await app.catalogue(boot: original.bootIdentity)
            _ = try await app.waitForButtonState("Initial", catalogue: before, pid: pid)
            let catalogue = try await app.setPose(pose, boot: original.bootIdentity)
            let fresh = try await app.waitForButtonState("Initial", catalogue: catalogue, pid: pid)
            try await app.tapAndVerify(catalogue: catalogue, pid: pid, fresh: fresh)
            panels[pose] = catalogue.activePanel.identity
            app.report("hinge \(pose.rawValue)", catalogue: catalogue)
        }

        let closed = try #require(panels[.closed])
        let open = try #require(panels[.open])
        #expect(closed != open, "Closed and open must select different measured Duo panels.")
    }

    @Test("All four open-panel rotations permit a fresh lookup and real button action")
    func openPanelRotations() async throws {
        try await supportedRotations(pose: .open)
    }

    @Test("All three closed-panel rotations permit a fresh lookup and real button action")
    func closedPanelRotations() async throws {
        try await supportedRotations(pose: .closed)
    }

    @Test("A fold rejects the old agent reference and a fresh reference changes the app")
    func foldInvalidatesAgentReference() async throws {
        try await verifyAgentReferenceInvalidation(fold: true)
    }

    @Test("An inner-panel rotation rejects the old agent reference and a fresh reference changes the app")
    func rotationInvalidatesAgentReference() async throws {
        try await verifyAgentReferenceInvalidation(fold: false)
    }

    @Test("An inactive screen rejects input before a fresh active-screen tap")
    func inactivePanelRejectsInput() async throws {
        let app = try DuoPlaygroundSession()
        let original = try await app.catalogue()
        _ = try await app.setPose(.open, boot: original.bootIdentity)
        let pid = try await app.launch()
        let current = try await app.catalogue(boot: original.bootIdentity)
        let fresh = try await app.waitForButtonState("Initial", catalogue: current, pid: pid)
        let inactive = try #require(current.panels.first { $0.identity != current.activePanel.identity })
        try #require(inactive.active != true)

        try await app.requireInactivePanelRefusal(inactive.identity, pid: pid)
        let after = try await app.catalogue(boot: original.bootIdentity)
        try #require(after.activePanel == current.activePanel)
        _ = try await app.waitForButtonState("Initial", catalogue: after, pid: pid)
        try await app.tapAndVerify(catalogue: after, pid: pid, fresh: fresh)
        app.report("inactive screen rejected; active screen tapped", catalogue: after)
    }

    private func verifyAgentReferenceInvalidation(fold: Bool) async throws {
        let app = try DuoPlaygroundSession()
        let agent = try AgentPlaygroundSession()
        let original = try await app.catalogue()
        let open = try await app.setPose(.open, boot: original.bootIdentity)
        let pid = try await app.launch()
        let launched = try await app.catalogue(boot: original.bootIdentity)
        try #require(launched.activePanel.identity == open.activePanel.identity)
        _ = try await app.waitForButtonState("Initial", catalogue: launched, pid: pid)
        let old = try await agent.timedCapture(pid: pid)
        let oldButton = try old.capture.target(id: "slider-value-button")

        let after: DuoCatalogue
        if fold {
            after = try await app.setPose(.closed, boot: original.bootIdentity)
            try #require(after.activePanel.identity != open.activePanel.identity, "The fold did not change the active panel.")
        } else {
            let before = try await app.catalogue(boot: original.bootIdentity)
            after = try await app.rotateRight(catalogue: before)
            try #require(after.activePanel.identity == open.activePanel.identity)
        }
        _ = try await app.waitForButtonState("Initial", catalogue: after, pid: pid)
        try await agent.requireRefusal(oldButton.ref, capture: old, pid: pid)
        _ = try await app.waitForButtonState("Initial", catalogue: after, pid: pid)

        let fresh = try await agent.timedCapture(pid: pid)
        try #require(fresh.capture.snapshotID != old.capture.snapshotID)
        try #require(fresh.capture.applicationPID == pid)
        let button = try fresh.capture.target(id: "slider-value-button")
        try old.requireUnexpired("before fresh reference input after Duo transition")
        try fresh.requireUnexpired("before fresh reference input after Duo transition")
        let result = try await agent.tap(button.ref, snapshot: fresh.capture.snapshotID, pid: pid)
        let action = try #require(result.data.action)
        #expect(action.kind == "tap")
        #expect(action.outcome == "enqueuedAndDrained")
        #expect(action.enqueuedEventCount > 0)
        #expect(action.cleanup != "uncertain")
        #expect(!action.replayed)
        _ = try await app.waitForButtonState("Tapped", catalogue: after, pid: pid)
        try old.requireUnexpired("after app recovery from Duo transition")
        try fresh.requireUnexpired("after app recovery from Duo transition")
        app.report(fold ? "agent reference recovered after fold" : "agent reference recovered after rotation", catalogue: after)
    }

    private func supportedRotations(pose: DuoPlaygroundPose) async throws {
        let app = try DuoPlaygroundSession()
        let original = try await app.catalogue()
        let start = try await app.setPose(pose, boot: original.bootIdentity)
        let expectedPositions = pose == .open ? Set([0, 90, 180, 270]) : Set([0, 90, 270])
        var observedPositions = Set<Int>()

        for _ in 0..<expectedPositions.count {
            let pid = try await app.launch()
            let before = try await app.catalogue(boot: original.bootIdentity)
            _ = try await app.waitForButtonState("Initial", catalogue: before, pid: pid)
            let after = try await app.rotateRight(catalogue: before)
            #expect(after.activePanel.identity == start.activePanel.identity)
            let fresh = try await app.waitForButtonState("Initial", catalogue: after, pid: pid)
            try await app.tapAndVerify(catalogue: after, pid: pid, fresh: fresh)
            observedPositions.insert(try after.activePanel.rotationDegrees())
            app.report("rotate right, hinge \(pose.rawValue)", catalogue: after)
        }

        let final = try await app.catalogue(boot: original.bootIdentity)
        #expect(observedPositions == expectedPositions)
        #expect(final.activePanel.identity == start.activePanel.identity)
    }
}
