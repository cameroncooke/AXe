import Darwin
import Foundation
import Testing
@testable import AXe

@Suite("Raw broker accept-time admission")
struct HIDBrokerAdmissionTests {
    @Test("A busy handshake is terminal before request bytes or startup recovery")
    func busyDoesNotRecoverOrSend() throws {
        let endpoint = try endpointPath()
        var peers: [Int32] = []
        defer { peers.forEach { Darwin.close($0) } }
        var connections = 0
        var spawns = 0
        var sleeps = 0
        do {
            let unexpected = try HIDBroker.connectToReadyBroker(simulatorUDID: "unused", endpoint: endpoint,
                connector: { _ in
                    connections += 1
                    let pair = try socketPair()
                    peers.append(pair.1)
                    try HIDBroker.writeHandshake(ready: false, version: HIDBroker.protocolVersion,
                        rejection: "busy", to: pair.1)
                    return pair.0
                }, spawner: { _ in spawns += 1 }, sleeper: { _ in sleeps += 1 },
                expectedVersion: HIDBroker.protocolVersion)
            Darwin.close(unexpected)
            Issue.record("A busy client must not receive an admitted descriptor.")
        } catch let error as HIDBrokerAdmissionFailure {
            #expect(error.userFacingDescription == "Simulator input is owned by another action or retained contact")
        }
        #expect(connections == 1 && spawns == 0 && sleeps == 0)
        let peer = try #require(peers.first)
        var byte: UInt8 = 0
        #expect(Darwin.read(peer, &byte, 1) == 0, "The rejected client sent bytes after its handshake.")
        #expect(!HIDBroker.isBrokerUnavailable(HIDBrokerAdmissionFailure.busy))
        #expect(!FileManager.default.fileExists(atPath: endpoint + ".lock"))
    }

    @Test("Normal not-ready handshakes retain startup recovery")
    func notReadyStillRecovers() throws {
        let endpoint = try endpointPath()
        defer { try? FileManager.default.removeItem(atPath: endpoint + ".lock") }
        var peers: [Int32] = []
        defer { peers.forEach { Darwin.close($0) } }
        var connections = 0
        var spawns = 0
        var sleeps = 0
        let descriptor = try HIDBroker.connectToReadyBroker(simulatorUDID: "unused", endpoint: endpoint,
            connector: { _ in
                connections += 1
                let pair = try socketPair()
                peers.append(pair.1)
                try HIDBroker.writeHandshake(ready: connections > 1,
                    version: HIDBroker.protocolVersion, to: pair.1)
                return pair.0
            }, spawner: { _ in spawns += 1 }, sleeper: { _ in sleeps += 1 },
            expectedVersion: HIDBroker.protocolVersion)
        Darwin.close(descriptor)
        #expect(connections == 2 && spawns == 0 && sleeps == 0)
    }

    @Test("Only the active reservation can release admission")
    func reservationOwnership() throws {
        let admission = HIDBrokerRequestAdmission()
        let first = try #require(admission.reserve())
        #expect(admission.reserve() == nil)
        admission.release(first)
        let second = try #require(admission.reserve())
        #expect(second != first)
        admission.release(first)
        #expect(admission.reserve() == nil, "An old request released a newer request.")
        admission.release(second)
        #expect(admission.reserve() != nil)
    }

    private func endpointPath() throws -> String {
        try HIDBroker.endpointPath(simulatorUDID: UUID().uuidString,
            developerDirectory: FileManager.default.temporaryDirectory.path)
    }

    private func socketPair() throws -> (Int32, Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (descriptors[0], descriptors[1])
    }
}
