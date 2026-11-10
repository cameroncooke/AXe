import Darwin
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

enum SelectedAXRetirementExclusion: String, CaseIterable, Sendable {
    case ready, notReady, cancelled, deadlineExceeded, requestTimedOut, processChanged, contextChanged
    case pointRead, tap, wrongFailure, missingAcquisition, missingContext, eventEnqueued, returnedToken
    case returnedQuarantine, uncertainCleanup, wrongRequestID, wrongBrokerID, wrongAXKind, wrongPID, noError, wrongOutcome, wrongVersion
    var acquisitionOutcome: FBSimulatorAXAcquisitionOutcome {
        switch self {
        case .ready: .ready
        case .notReady: .notReady
        case .cancelled: .cancelled
        case .deadlineExceeded: .deadlineExceeded
        case .requestTimedOut: .requestTimedOut
        case .processChanged: .processChanged
        case .contextChanged: .contextChanged
        default: .failed
        }
    }
}

@Suite("Selected AX terminal read retirement", .serialized)
@MainActor
struct SelectedAXRetirementTests {
    @Test("A typed pure-read failure returns unchanged, stops this owner and releases its lease", arguments: [
        "Error Domain=DTXProxyChannel Code=1 Channel disconnected", "Native accessibility read failed",
    ])
    func failedDescribeRetiresWithoutInput(diagnostic: String) async throws {
        let fixture = try RetirementFixture(exclusion: nil, diagnostic: diagnostic)
        var owner: SelectedHIDOwner? = fixture.owner()
        let active = try #require(owner)
        let request = fixture.request()
        let result = await active.perform(request)
        let original = try #require(fixture.state.lastResponse)
        #expect(try fixture.encoded(result) == fixture.encoded(original))
        #expect(active.shouldStop && active.isBusy)
        #expect(fixture.state.calls == 1 && fixture.state.persists == 0)
        let later = await active.perform(fixture.request())
        #expect(later.outcome == "rejectedBeforeInput" && later.enqueuedEventCount == 0 && later.cleanup == "notNeeded")
        #expect(fixture.state.calls == 1)
        // This is the same input lease boundary used by all production input paths.
        let probe = try HIDInputLease.acquire(simulatorUDID: fixture.udid)
        withExtendedLifetime(probe) {}
        owner = nil
    }

    @Test("Nonterminal or non-read outcomes cannot retire the owner", arguments: SelectedAXRetirementExclusion.allCases)
    func excludedOutcomesRemainOwned(_ exclusion: SelectedAXRetirementExclusion) async throws {
        let fixture = try RetirementFixture(exclusion: exclusion, diagnostic: "Controlled failed read")
        let owner = fixture.owner()
        let result = await owner.perform(fixture.request())
        #expect(!owner.shouldStop)
        #expect(fixture.state.calls == 1)
        if exclusion == .uncertainCleanup {
            #expect(result.cleanup == "uncertain" && result.quarantine?.persisted == true)
            #expect(owner.isBusy && fixture.state.persists == 1)
            #expect(throws: (any Error).self) { _ = try HIDInputLease.acquire(simulatorUDID: fixture.udid) }
            let blocked = await owner.perform(fixture.request())
            #expect(blocked.enqueuedEventCount == 0 && blocked.outcome == "rejectedBeforeInput")
            #expect(fixture.state.calls == 1)
        } else {
            let original = try #require(fixture.state.lastResponse)
            #expect(try fixture.encoded(result) == fixture.encoded(original))
            #expect(fixture.state.persists == 0 && !owner.isBusy)
        }
    }

    @Test("A retained-contact admission rejects a read before an AX operation can start")
    func retainedAdmissionBlocksDescribe() throws {
        let fixture = try RetirementFixture(exclusion: nil, diagnostic: "unused")
        var admission = SelectedHIDAdmission()
        let begin = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: fixture.screen, operation: .begin, token: nil, payload: .contact([.touch(.down, x: 1, y: 2)]))
        try admission.enter(begin)
        let token = UUID()
        admission.retain(begin, token: token)
        admission.finish()
        #expect(throws: (any Error).self) { try admission.enter(fixture.request()) }
        #expect(admission.token == token && !admission.inFlight)
        #expect(fixture.state.calls == 0)
    }
}

@MainActor
private struct RetirementFixture {
    final class State {
        var calls = 0
        var persists = 0
        var lastResponse: SelectedHIDResponse?
    }
    struct Acquisition: Encodable {
        let outcome: FBSimulatorAXAcquisitionOutcome
        let attempts: [SelectedAXAttempt] = []
        let phases: [SelectedAXPhase] = []
        let failureDescription: String
    }
    let udid = UUID().uuidString
    let screen = UUID()
    let exclusion: SelectedAXRetirementExclusion?
    let diagnostic: String
    let acquisition: SelectedAXAcquisition
    let context: SelectedHIDContext
    let state = State()

    init(exclusion: SelectedAXRetirementExclusion?, diagnostic: String) throws {
        self.exclusion = exclusion
        self.diagnostic = diagnostic
        let encoder = JSONEncoder()
        acquisition = try JSONDecoder().decode(SelectedAXAcquisition.self, from: encoder.encode(
            Acquisition(outcome: exclusion?.acquisitionOutcome ?? .failed, failureDescription: diagnostic)))
        let json = "{\"bootIdentity\":\"fixture-boot\",\"screenID\":3,\"screenUUID\":\"\(screen.uuidString)\",\"logicalWidth\":390,\"logicalHeight\":844,\"rotationDegrees\":0,\"nativePixelWidth\":1170,\"nativePixelHeight\":2532,\"scale\":3,\"poseRevision\":\"rigid\"}"
        context = try JSONDecoder().decode(SelectedHIDContext.self, from: Data(json.utf8))
    }
    func request() -> SelectedHIDRequest {
        let kind: SelectedAXRequest.Kind = exclusion == .pointRead ? .describePoint : exclusion == .tap ? .tap : .describe
        let ax = SelectedAXRequest(kind: kind, expectedPID: 42, endpoint: nil,
            selectorKind: kind == .tap ? .id : nil, selectorValue: kind == .tap ? "button" : nil,
            preDelay: 0, postDelay: 0, point: kind == .describePoint ? .init(x: 1, y: 2) : nil)
        return SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: screen, operation: .complete, token: nil, payload: .ax(ax))
    }
    func owner() -> SelectedHIDOwner {
        let dependencies = SelectedAXDependencies(execute: { request, _, broker, _, _ in
            state.calls += 1
            let axRequest = request.ax!
            var ax = SelectedAXResult(kind: exclusion == .wrongAXKind ? .tap : axRequest.kind,
                expectedPID: exclusion == .wrongPID ? 43 : axRequest.expectedPID)
            ax.failure = exclusion == .wrongFailure ? .setupFailed : .acquisitionFailed
            ax.acquisition = exclusion == .missingAcquisition ? nil : acquisition
            let response = SelectedHIDResponse(version: exclusion == .wrongVersion ? SelectedHIDRequest.version - 1 : SelectedHIDRequest.version,
                requestID: exclusion == .wrongRequestID ? UUID() : request.requestID,
                brokerID: exclusion == .wrongBrokerID ? UUID() : broker,
                outcome: exclusion == .wrongOutcome ? "rejectedBeforeInput" : "failedBeforeInput",
                token: exclusion == .returnedToken ? UUID() : nil, enqueuedEventCount: exclusion == .eventEnqueued ? 1 : 0,
                cleanup: exclusion == .uncertainCleanup ? "uncertain" : "notNeeded",
                error: exclusion == .noError ? nil : diagnostic, context: exclusion == .missingContext ? nil : context,
                ax: ax, quarantine: exclusion == .returnedQuarantine ? .init(recordPath: nil, persisted: false, error: "fixture") : nil)
            state.lastResponse = response
            return response
        }, persist: { _, _, _ in state.persists += 1 }, now: { 0 })
        return SelectedHIDOwner(simulatorUDID: udid, logger: AxeLogger(), dependencies: dependencies)
    }
    func encoded(_ value: SelectedHIDResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

@Suite("Selected AX retiring broker readiness")
struct SelectedAXRetirementReadinessTests {
    @Test("Ready-false sockets receive no request; one selected read reaches the replacement")
    func replacementReceivesTheRequestOnlyOnce() throws {
        let endpoint = try HIDBroker.endpointPath(simulatorUDID: UUID().uuidString,
            developerDirectory: FileManager.default.temporaryDirectory.path, version: SelectedHIDRequest.version)
        var lifetime: Int32? = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        var oldPeers: [Int32] = []
        var replacementPeer: Int32?
        var oldAlive = true
        var spawns = 0
        var now: UInt64 = 0
        defer {
            if let lifetime { _ = flock(lifetime, LOCK_UN); Darwin.close(lifetime) }
            for peer in oldPeers { Darwin.close(peer) }
            if let replacementPeer { Darwin.close(replacementPeer) }
            try? FileManager.default.removeItem(atPath: endpoint + ".lock")
            try? FileManager.default.removeItem(atPath: endpoint + ".lifetime.lock")
        }
        let descriptor = try HIDBroker.connectToReadyBroker(simulatorUDID: UUID().uuidString, endpoint: endpoint,
            connector: { _ in
                if !oldAlive && spawns == 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
                var pair = [Int32](repeating: -1, count: 2)
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw HIDBroker.posixError("fixture socketpair") }
                try HIDBroker.configureSocketTimeouts(pair[1], readMilliseconds: 100, writeMilliseconds: 100)
                try HIDBroker.writeHandshake(ready: !oldAlive, version: SelectedHIDRequest.version, to: pair[1])
                if oldAlive { oldPeers.append(pair[1]) } else { replacementPeer = pair[1] }
                return pair[0]
            }, spawner: { _ in
                #expect(!oldAlive)
                do {
                    let alive = try HIDBroker.isBrokerProcessAlive(endpoint: endpoint)
                    #expect(!alive)
                } catch {
                    Issue.record("Cannot inspect the old broker lifetime: \(error)")
                }
                spawns += 1
            }, sleeper: { _ in
                now += 100_000_000
                if let held = lifetime {
                    #expect(flock(held, LOCK_UN) == 0)
                    Darwin.close(held)
                    lifetime = nil
                    oldAlive = false
                }
            }, monotonicNow: { now }, expectedVersion: SelectedHIDRequest.version)
        defer { Darwin.close(descriptor) }
        #expect(spawns == 1 && !oldPeers.isEmpty)
        for peer in oldPeers {
            var byte: UInt8 = 0
            #expect(Darwin.read(peer, &byte, 1) == 0)
        }
        let peer = try #require(replacementPeer)
        let requestID = UUID()
        let response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: requestID, brokerID: UUID(),
            outcome: "failedBeforeInput", token: nil, enqueuedEventCount: 0, cleanup: "notNeeded", error: "fixture read", context: nil)
        var responseBytes = try JSONEncoder().encode(response)
        responseBytes.append(10)
        try HIDBroker.writeAll(responseBytes, to: peer)
        let ax = SelectedAXRequest(kind: .describe, expectedPID: 42, endpoint: nil, selectorKind: nil,
            selectorValue: nil, preDelay: 0, postDelay: 0)
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: requestID,
            screenID: 3, screenUUID: UUID(), operation: .complete, token: nil, payload: .ax(ax))
        try request.validate()
        var requestBytes = try JSONEncoder().encode(request)
        requestBytes.append(10)
        let actual = try SelectedHIDBroker.exchange(requestBytes, requestID: requestID, descriptor: descriptor)
        #expect(actual.requestID == requestID && actual.brokerID == response.brokerID)
        var body = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(peer, &body, body.count, MSG_DONTWAIT)
        try #require(count > 0)
        #expect(Data(body.prefix(count)) == requestBytes)
        #expect(Darwin.recv(peer, &body, body.count, MSG_DONTWAIT) < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    }
}
