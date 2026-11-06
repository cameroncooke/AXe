import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@MainActor
@Suite("Bounded agent swipe publication")
struct AgentPostSwipePublicationTests {
    @Test("The public coordinate agent swipe keeps its native swipe path")
    func coordinateAgentSwipeRetainsPathKind() throws {
        let command = try Swipe.parse(["--agent", "--udid", "419D3218-79E5-46DE-80C0-E58126A88252",
            "--snapshot-id", UUID().uuidString, "--start-x", "200", "--start-y", "600",
            "--end-x", "200", "--end-y", "200"])
        try command.validate()
        let request = try command.agentRequest()
        try request.validate()
        #expect(request.agent?.kind == .complete && request.path?.kind == .swipe)
    }

    @Test("Two equal exact observations publish the latest sample")
    func equalPairPublishesLatest() async throws {
        let a = try sample(x: 10)
        let h = Harness([a, a])
        let result = try await h.run()
        // The first sample is a baseline; only the compared pair is separated by a pause.
        #expect(h.starts == 2 && h.observations == 2 && h.pauses == 1)
        #expect(result.snapshot.nativeFingerprint == a.snapshot.nativeFingerprint)
        #expect(result.context == a.context && result.pid == a.pid && result.brokerID == a.brokerID)
    }

    @Test("An initial changed frame needs a new consecutive exact pair")
    func changedThenEqualPublishesLatest() async throws {
        let a = try sample(x: 10), b = try sample(x: 20)
        let h = Harness([a, b, b])
        let result = try await h.run()
        #expect(h.starts == 3 && h.observations == 3)
        #expect(result.snapshot.nativeFingerprint == b.snapshot.nativeFingerprint)
        #expect(!AgentModeController.canReuseSnapshot(a.snapshot, with: result.snapshot))
    }

    @Test("Three unmatched samples never publish a table", arguments: [[10.0, 20, 30], [10.0, 20, 10]])
    func noConsecutivePairDoesNotPublish(positions: [Double]) async throws {
        let h = Harness(try positions.map { try sample(x: $0) })
        do {
            _ = try await h.run()
            Issue.record("An unconfirmed replacement was published.")
        } catch let error as AgentModeFailure { #expect(error.code == "postSwipeSnapshotUnsettled") }
        #expect(h.starts == 3 && h.observations == 3)
    }

    enum ChangedAdmission: CaseIterable, Sendable { case context, pid, broker }

    @Test("Owner and context changes stop without another read", arguments: ChangedAdmission.allCases)
    func changedAdmissionStops(change: ChangedAdmission) async throws {
        let a = try sample(x: 10)
        let changed = AgentPostSwipePublication.Sample(snapshot: a.snapshot,
            context: try context(screen: change == .context ? 2 : 1),
            pid: change == .pid ? 5678 : a.pid, brokerID: change == .broker ? UUID() : a.brokerID)
        let h = Harness([changed, a])
        h.expected = a
        do {
            _ = try await h.run()
            Issue.record("Changed admission published a replacement.")
        } catch let error as AgentModeFailure { #expect(error.code == "postSwipeContextChanged") }
        #expect(h.starts == 1 && h.observations == 1)
    }

    @Test("A discovery overrun stops before a new native observation")
    func discoveryOverrunStartsNoNativeRead() async throws {
        let h = Harness([try sample(x: 10)])
        h.discoverySeconds = 3
        do {
            _ = try await h.run()
            Issue.record("An expired start window admitted a native read.")
        } catch let error as AgentModeFailure { #expect(error.code == "postSwipeSnapshotUnsettled") }
        #expect(h.starts == 1 && h.observations == 0)
    }

    @Test("An already started matching read can finish after the soft window")
    func matchingReadMayFinishAfterWindow() async throws {
        let a = try sample(x: 10)
        let h = Harness([a, a])
        h.readSeconds = [0, 4]
        _ = try await h.run()
        #expect(h.time > 3 && h.starts == 2 && h.observations == 2 && h.completedReads == 2)
    }

    @Test("An unmatched read overrun is joined and no next read starts")
    func mismatchOverrunStopsAfterJoinedRead() async throws {
        let h = Harness([try sample(x: 10), try sample(x: 20)])
        h.readSeconds = [4, 0]
        do {
            _ = try await h.run()
            Issue.record("An overrun scheduled a later sample.")
        } catch let error as AgentModeFailure { #expect(error.code == "postSwipeSnapshotUnsettled") }
        #expect(h.starts == 1 && h.observations == 1 && h.completedReads == 1)
    }

    @Test("A native read failure propagates without retry or an old table")
    func readFailureDoesNotRetry() async throws {
        let a = try sample(x: 10)
        let h = Harness([a, a, a])
        h.failRead = 2
        do {
            _ = try await h.run()
            Issue.record("A failed native observation produced a table.")
        } catch Fault.read { }
        #expect(h.starts == 2 && h.observations == 2 && h.completedReads == 1)
    }

    @Test("Cancellation during the cadence stops before the next read")
    func cancelledPauseStartsNoRead() async throws {
        let h = Harness([try sample(x: 10), try sample(x: 10)])
        h.cancelPause = true
        do {
            _ = try await h.run()
            Issue.record("Cancelled cadence started another native observation.")
        } catch is CancellationError { }
        #expect(h.pauses == 1 && h.starts == 1 && h.observations == 1)
    }

    private enum Fault: Error { case read }

    @MainActor
    private final class Harness {
        let samples: [AgentPostSwipePublication.Sample]
        var expected: AgentPostSwipePublication.Sample
        var time = 0.0
        var pauses = 0
        var starts = 0
        var observations = 0
        var completedReads = 0
        var discoverySeconds = 0.0
        var readSeconds: [Double] = []
        var failRead: Int?
        var cancelPause = false

        init(_ samples: [AgentPostSwipePublication.Sample]) {
            self.samples = samples
            expected = samples[0]
        }

        func run() async throws -> AgentPostSwipePublication.Sample {
            try await AgentPostSwipePublication.capture(context: expected.context, pid: expected.pid,
                brokerID: expected.brokerID, startedAt: 0, now: { self.time },
                pause: {
                    self.pauses += 1
                    if self.cancelPause { throw CancellationError() }
                    self.time += 0.3
                }, sample: { deadline in
                    self.starts += 1
                    self.time += self.discoverySeconds
                    try AgentPostSwipePublication.requireMayStart(now: self.time, deadline: deadline)
                    self.observations += 1
                    if self.failRead == self.observations { throw Fault.read }
                    let index = self.observations - 1
                    self.time += self.readSeconds.indices.contains(index) ? self.readSeconds[index] : 0
                    self.completedReads += 1
                    return self.samples[index]
                })
        }
    }

    private static let owner = UUID(uuidString: "5D62605A-F017-4D55-9F5A-5334311947DF")!

    private func sample(x: Double) throws -> AgentPostSwipePublication.Sample {
        let context = try context()
        let roots = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode([
            Fixture(frame: .init(x: x))]))
        return AgentPostSwipePublication.Sample(snapshot: try AgentModeSnapshot(roots: roots, context: context),
            context: context, pid: 1234, brokerID: Self.owner)
    }

    private func context(screen: Int = 1) throws -> SelectedHIDContext {
        try JSONDecoder().decode(SelectedHIDContext.self, from: Data("""
            {"bootIdentity":"1:2:3","screenID":\(screen),"screenUUID":"DFEBAD86-C7D4-45CA-BB20-2D73B355B0A1",\
            "logicalWidth":402,"logicalHeight":874,"rotationDegrees":0,"nativePixelWidth":1206,\
            "nativePixelHeight":2622,"scale":3,"poseRevision":"mechanicalDegrees=180.0"}
            """.utf8))
    }

    private struct Fixture: Encodable {
        struct Frame: Encodable { var x: Double; let y = 100.0; let width = 100.0; let height = 44.0 }
        let type = "Button"
        let label = "Control"
        let identifier = "control"
        let frame: Frame
        let children: [Fixture] = []
        let pid: Int32 = 1234
        let enabled = true
        let hidden = false
        private enum CodingKeys: String, CodingKey {
            case type, label = "AXLabel", identifier = "AXUniqueId", frame, children, pid, enabled, hidden
        }
    }
}
