import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected broker agent lifetime", .serialized)
@MainActor
struct SelectedAgentLifetimeTests {
    @Test("An owner without references stops at its existing 30-second idle boundary")
    func ordinaryIdleBoundary() async {
        let clock = LifetimeClock()
        let owner = makeOwner(clock)
        clock.now = 29.999
        await owner.maintain()
        #expect(!owner.shouldStop)
        clock.now = 30
        await owner.maintain()
        #expect(owner.shouldStop)
        #expect(clock.nativeCalls == 0 && clock.persistenceCalls == 0)
    }

    @Test("A live agent table retains an idle owner without changing its idle clock")
    func referenceRetentionDoesNotRenewIdleClock() async {
        let clock = LifetimeClock()
        let owner = makeOwner(clock)
        for instant in [30.0, 35.0, 59.999] {
            clock.now = instant
            await owner.maintain(retainingAgentSnapshot: true)
            #expect(!owner.shouldStop)
            #expect(owner.currentTime == instant)
        }
        clock.now = 60
        await owner.maintain(retainingAgentSnapshot: false)
        #expect(owner.shouldStop)
        #expect(clock.nativeCalls == 0 && clock.persistenceCalls == 0)
    }

    @Test("A controller with no table does not retain its idle owner")
    func emptyControllerUsesOrdinaryIdleBoundary() async {
        let clock = LifetimeClock()
        let owner = makeOwner(clock)
        let controller = AgentModeController(simulatorUDID: UUID().uuidString, logger: AxeLogger(), owner: owner)
        clock.now = 29.999
        await controller.maintain()
        #expect(!owner.shouldStop)
        clock.now = 30
        await controller.maintain()
        #expect(owner.shouldStop)
        #expect(clock.nativeCalls == 0 && clock.persistenceCalls == 0)
    }

    @Test("A state-only rotation failure releases admission and permits a fresh read")
    func rotationObservationFailurePermitsFreshRead() async throws {
        let fixture = try RotationLifetimeFixture(cleanup: "notNeeded")
        let owner = fixture.owner()
        let failed = await owner.perform(fixture.rotationRequest())
        #expect(failed.outcome == "failedNoReplay" && failed.error == fixture.diagnostic)
        #expect(failed.rotation?.failure?.delivery == .uncertain && failed.context == fixture.before)
        #expect(failed.enqueuedEventCount == 0 && failed.cleanup == "notNeeded" && failed.quarantine == nil)
        #expect(!owner.isBusy && !owner.shouldStop && fixture.state.calls == 1 && fixture.state.persists == 0)
        do {
            let lease = try HIDInputLease.acquire(simulatorUDID: fixture.udid)
            withExtendedLifetime(lease) {}
        }
        let fresh = await owner.perform(fixture.readRequest())
        #expect(fresh.outcome == "ready" && fresh.error == nil && fresh.context == fixture.after)
        #expect(fresh.ax?.kind == .describe && fresh.ax?.acquisition?.outcome == .ready)
        #expect(fresh.enqueuedEventCount == 0 && fresh.cleanup == "notNeeded" && fresh.quarantine == nil)
        #expect(fixture.state.calls == 2 && fixture.state.persists == 0 && !owner.isBusy)
    }

    @Test("Unknown cleanup after a rotation still quarantines and blocks a fresh read")
    func rotationUnknownCleanupRemainsQuarantined() async throws {
        let fixture = try RotationLifetimeFixture(cleanup: "uncertain")
        let owner = fixture.owner()
        let failed = await owner.perform(fixture.rotationRequest())
        #expect(failed.outcome == "failedNoReplay" && failed.cleanup == "uncertain")
        #expect(failed.rotation?.failure?.delivery == .uncertain && failed.quarantine?.persisted == true)
        #expect(owner.isBusy && fixture.state.calls == 1 && fixture.state.persists == 1)
        #expect(throws: (any Error).self) { _ = try HIDInputLease.acquire(simulatorUDID: fixture.udid) }
        let blocked = await owner.perform(fixture.readRequest())
        #expect(blocked.outcome == "rejectedBeforeInput" && blocked.enqueuedEventCount == 0)
        #expect(fixture.state.calls == 1 && fixture.state.persists == 1 && owner.isBusy)
    }

    @Test("Agent requests accept an omitted PID and reject explicit nonpositive assertions")
    func optionalAgentPIDValidation() throws {
        let snapshot = UUID()
        for pid in [Int32?.none, Int32(42)] {
            try AgentModeRequest(kind: .describe, expectedPID: pid).validate()
            try AgentModeRequest(kind: .tap, expectedPID: pid, snapshotID: snapshot, ref: "e1").validate()
        }
        for pid in [Int32(0), -1] {
            #expect(throws: (any Error).self) {
                try AgentModeRequest(kind: .describe, expectedPID: pid).validate()
            }
            #expect(throws: (any Error).self) {
                try AgentModeRequest(kind: .tap, expectedPID: pid, snapshotID: snapshot, ref: "e1").validate()
            }
        }
    }

    @Test("A saved owner binds omitted PID actions and cannot be replaced by an assertion")
    func optionalPIDUsesSavedOwner() throws {
        #expect(try AgentModePIDPolicy.expectedPID(assertion: nil, snapshot: nil) == nil)
        #expect(try AgentModePIDPolicy.expectedPID(assertion: 42, snapshot: nil) == 42)
        #expect(try AgentModePIDPolicy.expectedPID(assertion: nil, snapshot: 42) == 42)
        #expect(try AgentModePIDPolicy.expectedPID(assertion: 42, snapshot: 42) == 42)
        #expect(throws: (any Error).self) {
            _ = try AgentModePIDPolicy.expectedPID(assertion: 43, snapshot: 42)
        }
        for invalid in [Int32(0), -1] {
            #expect(throws: (any Error).self) {
                _ = try AgentModePIDPolicy.expectedPID(assertion: invalid, snapshot: nil)
            }
            #expect(throws: (any Error).self) {
                _ = try AgentModePIDPolicy.expectedPID(assertion: nil, snapshot: invalid)
            }
        }
    }

    @Test("Native owner evidence must be positive and match the bound PID")
    func automaticPIDRequiresVerifiedRoot() throws {
        #expect(try AgentModePIDPolicy.verifiedPID(42, expected: nil) == 42)
        #expect(try AgentModePIDPolicy.verifiedPID(42, expected: 42) == 42)
        #expect(throws: (any Error).self) {
            _ = try AgentModePIDPolicy.verifiedPID(43, expected: 42)
        }
        for invalid in [Int32(0), -1] {
            #expect(throws: (any Error).self) {
                _ = try AgentModePIDPolicy.verifiedPID(invalid, expected: nil)
            }
        }
    }

    @Test("Only a native full description can omit its internal PID")
    func unboundPIDCannotAdmitNativeInput() throws {
        let describe = SelectedAXRequest(kind: .describe, expectedPID: nil,
            endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0)
        try describe.validate()
        for invalid in [Int32(0), -1] {
            let request = SelectedAXRequest(kind: .describe, expectedPID: invalid,
                endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0)
            #expect(throws: (any Error).self) { try request.validate() }
        }
        let tap = SelectedAXRequest(kind: .tap, expectedPID: nil,
            endpoint: nil, selectorKind: .id, selectorValue: "button", preDelay: 0, postDelay: 0)
        #expect(throws: (any Error).self) { try tap.validate() }
        var point = SelectedAXRequest(kind: .describePoint, expectedPID: nil,
            endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0)
        point.point = .init(x: 10, y: 10)
        #expect(throws: (any Error).self) { try point.validate() }
    }

    private func makeOwner(_ clock: LifetimeClock) -> SelectedHIDOwner {
        let dependencies = SelectedAXDependencies(execute: { request, _, broker, _, _, _ in
            clock.nativeCalls += 1
            Issue.record("Idle maintenance must not start a native operation.")
            return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: broker, outcome: "rejectedBeforeInput", token: nil, enqueuedEventCount: 0,
                cleanup: "notNeeded", error: "Unexpected native operation", context: nil)
        }, persist: { _, _, _ in
            clock.persistenceCalls += 1
            Issue.record("Idle maintenance must not write an input recovery record.")
        }, now: { clock.now })
        return SelectedHIDOwner(simulatorUDID: UUID().uuidString, logger: AxeLogger(),
            helperURL: URL(fileURLWithPath: "/unused-cadisplay-context"), dependencies: dependencies)
    }
}

@MainActor
private final class LifetimeClock {
    var now: TimeInterval = 0
    var nativeCalls = 0
    var persistenceCalls = 0
}

@MainActor
private struct RotationLifetimeFixture {
    final class State {
        var calls = 0
        var persists = 0
    }
    let udid = UUID().uuidString
    let screen = UUID()
    let cleanup: String
    let diagnostic = "Context hinge sample timed out"
    let before: SelectedHIDContext
    let after: SelectedHIDContext
    let acquisition: SelectedAXAcquisition
    let state = State()

    init(cleanup: String) throws {
        self.cleanup = cleanup
        let base = "\"bootIdentity\":\"1:2:3\",\"screenID\":3,\"screenUUID\":\"\(screen.uuidString)\",\"nativePixelWidth\":2007,\"nativePixelHeight\":2853,\"scale\":3,\"poseRevision\":\"mechanicalDegrees=180\""
        before = try JSONDecoder().decode(SelectedHIDContext.self, from: Data(("{" + base + ",\"logicalWidth\":669,\"logicalHeight\":951,\"rotationDegrees\":180}").utf8))
        after = try JSONDecoder().decode(SelectedHIDContext.self, from: Data(("{" + base + ",\"logicalWidth\":951,\"logicalHeight\":669,\"rotationDegrees\":270}").utf8))
        acquisition = try JSONDecoder().decode(SelectedAXAcquisition.self,
            from: Data("{\"outcome\":\"ready\",\"attempts\":[],\"phases\":[]}".utf8))
    }

    func rotationRequest() -> SelectedHIDRequest {
        SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: 3, screenUUID: screen, operation: .complete, token: nil, primitives: [],
            rotation: SelectedRotationRequest(direction: .right, expectedBootIdentity: "1:2:3", timeoutSeconds: 8))
    }

    func readRequest() -> SelectedHIDRequest {
        let ax = SelectedAXRequest(kind: .describe, expectedPID: 42, endpoint: nil, selectorKind: nil,
            selectorValue: nil, preDelay: 0, postDelay: 0)
        return SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: 3, screenUUID: screen, operation: .complete, token: nil, primitives: [], ax: ax)
    }

    func owner() -> SelectedHIDOwner {
        let dependencies = SelectedAXDependencies(execute: { request, _, broker, _, _, _ in
            state.calls += 1
            if request.rotation != nil {
                var rotation = SelectedRotationResult(direction: .right)
                rotation.failure = FBSimulatorRotationFailure(detail: diagnostic, delivery: .uncertain, before: nil)
                return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                    brokerID: broker, outcome: "failedNoReplay", token: nil, enqueuedEventCount: 0,
                    cleanup: cleanup, error: diagnostic, context: before, rotation: rotation)
            }
            #expect(request.ax?.kind == .describe)
            var ax = SelectedAXResult(kind: .describe, expectedPID: 42)
            ax.acquisition = acquisition
            ax.roots = []
            return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: broker, outcome: "ready", token: nil, enqueuedEventCount: 0,
                cleanup: "notNeeded", error: nil, context: after, ax: ax)
        }, persist: { _, _, _ in state.persists += 1 }, now: { 0 })
        return SelectedHIDOwner(simulatorUDID: udid, logger: AxeLogger(),
            helperURL: URL(fileURLWithPath: "/unused-cadisplay-context"), dependencies: dependencies)
    }
}
