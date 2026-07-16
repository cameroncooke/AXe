import Darwin
import Foundation
import Testing
@testable import AXe

@Suite("HID Broker Reliability Tests")
struct HIDBrokerReliabilityTests {
    @Test("A broker lifetime lock distinguishes a live process from a stale endpoint")
    func lifetimeLockTracksBrokerProcess() throws {
        let endpoint = try makeEndpoint()
        defer { try? FileManager.default.removeItem(atPath: endpoint + ".lifetime.lock") }

        let lifetimeLock = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        #expect(try HIDBroker.isBrokerProcessAlive(endpoint: endpoint))

        #expect(flock(lifetimeLock, LOCK_UN) == 0)
        Darwin.close(lifetimeLock)
        #expect(try !HIDBroker.isBrokerProcessAlive(endpoint: endpoint))
    }

    @Test("A refused connection cannot remove an endpoint owned by a live broker")
    func refusedConnectionPreservesLiveBrokerEndpoint() throws {
        let endpoint = try makeEndpoint()
        let listener = try HIDBroker.makeListener(at: endpoint)
        defer {
            Darwin.close(listener)
            try? HIDBroker.removeOwnedSocket(endpoint)
        }
        var isAlive = true
        var endpointExistedWhileAlive = false

        try HIDBroker.waitForStaleEndpointShutdown(
            endpoint,
            connector: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
            },
            sleeper: { _ in
                endpointExistedWhileAlive = FileManager.default.fileExists(atPath: endpoint)
                isAlive = false
            },
            brokerIsAlive: { isAlive }
        )

        #expect(endpointExistedWhileAlive)
    }

    @Test("Broker startup uses a monotonic deadline")
    func startupDeadlineIsBounded() throws {
        let endpoint = try makeEndpoint()
        defer { removeEndpointArtifacts(endpoint) }
        var now: UInt64 = 0
        var spawnCount = 0

        do {
            _ = try HIDBroker.connectToReadyBroker(
                simulatorUDID: "simulator-a",
                endpoint: endpoint,
                connector: { _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                },
                spawner: { _ in spawnCount += 1 },
                sleeper: { _ in now = HIDBroker.startupTimeoutNanoseconds },
                monotonicNow: { now }
            )
            Issue.record("Startup should stop at its deadline")
        } catch let error as HIDBrokerNotReadyError {
            #expect(error.userFacingDescription.contains("could not establish simulator input"))
        }

        #expect(spawnCount == 1)
    }

    @Test("A slow broker startup is not spawned more than once")
    func slowStartupSpawnsOnce() throws {
        let endpoint = try makeEndpoint()
        defer { removeEndpointArtifacts(endpoint) }
        var now: UInt64 = 0
        var spawnCount = 0
        var attemptsAfterSpawn = 0
        var peerDescriptors: [Int32] = []
        defer { peerDescriptors.forEach { Darwin.close($0) } }

        let descriptor: Int32
        do {
            descriptor = try HIDBroker.connectToReadyBroker(
                simulatorUDID: "simulator-a",
                endpoint: endpoint,
                connector: { _ in
                    guard spawnCount > 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                    }
                    attemptsAfterSpawn += 1
                    guard attemptsAfterSpawn > 4 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                    }
                    var descriptors = [Int32](repeating: -1, count: 2)
                    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    try HIDBroker.writeAll(Data("{\"ready\":true}\n".utf8), to: descriptors[1])
                    peerDescriptors.append(descriptors[1])
                    return descriptors[0]
                },
                spawner: { _ in spawnCount += 1 },
                sleeper: { _ in now += 3_000_000_000 },
                monotonicNow: { now }
            )
        } catch let error as HIDBrokerNotReadyError {
            Issue.record("Broker diagnostic: \(error.diagnosticDescription)")
            return
        }
        Darwin.close(descriptor)

        #expect(now > 2_000_000_000)
        #expect(spawnCount == 1)
    }

    @Test("Handshake failures preserve diagnostics without exposing them to users")
    func handshakeDiagnosticsRemainInternal() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { Darwin.close(descriptors[1]) }
        try HIDBroker.writeAll(Data("not-json\n".utf8), to: descriptors[1])

        do {
            _ = try HIDBroker.connectAndAwaitHandshake(
                endpoint: "unused",
                connector: { _ in descriptors[0] }
            )
            Issue.record("An invalid handshake should fail")
        } catch let error as HIDBrokerNotReadyError {
            #expect(error.diagnosticDescription.contains("readiness handshake failed"))
            #expect(!error.userFacingDescription.contains("JSON"))
            #expect(!error.isSafeToReplaceBroker)
            #expect(error.allowsReplacementAfterProcessExit)
        }
    }

    private func makeEndpoint() throws -> String {
        try HIDBroker.endpointPath(
            simulatorUDID: UUID().uuidString,
            developerDirectory: FileManager.default.temporaryDirectory.path
        )
    }

    private func removeEndpointArtifacts(_ endpoint: String) {
        try? HIDBroker.removeOwnedSocket(endpoint)
        try? FileManager.default.removeItem(atPath: endpoint + ".lock")
        try? FileManager.default.removeItem(atPath: endpoint + ".lifetime.lock")
    }
}
