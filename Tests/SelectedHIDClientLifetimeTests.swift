import Darwin
import Foundation
import Testing
@testable import AXe

@Suite("Selected waiting client lifetime")
@MainActor
struct SelectedHIDClientLifetimeTests {
    private func socketPair() throws -> (server: Int32, client: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw HIDBroker.posixError("socketpair")
        }
        return (descriptors[0], descriptors[1])
    }

    @Test func consumedRequestNewlineDoesNotLookLikeADisconnect() throws {
        let pair = try socketPair()
        defer { Darwin.close(pair.server); Darwin.close(pair.client) }
        try HIDBroker.writeAll(Data("{}\n".utf8), to: pair.client)
        #expect(try HIDBroker.readMessage(from: pair.server) == Data("{}".utf8))
        #expect(SelectedHIDClientLifetime.peerState(descriptor: pair.server) == .connected)
    }

    @Test func unexpectedBytesAreDetectedWithoutConsumingThem() throws {
        let pair = try socketPair()
        defer { Darwin.close(pair.server); Darwin.close(pair.client) }
        try HIDBroker.writeAll(Data([42]), to: pair.client)
        #expect(SelectedHIDClientLifetime.peerState(descriptor: pair.server) == .unexpectedData)
        var byte: UInt8 = 0
        #expect(Darwin.recv(pair.server, &byte, 1, MSG_DONTWAIT) == 1)
        #expect(byte == 42)
    }

    @Test func aClosedPeerCancelsBeforeTheOperationCanStartInput() async throws {
        let pair = try socketPair()
        defer { Darwin.close(pair.server) }
        Darwin.close(pair.client)
        let cancelled = await SelectedHIDClientLifetime.run(descriptor: pair.server) {
            Task.isCancelled
        }
        #expect(cancelled)
    }

    @Test func disconnectCancelsTheWaitingOperationAndJoinsTheMonitor() async throws {
        let pair = try socketPair()
        defer { Darwin.close(pair.server) }
        var inspections = 0
        var pending: Task<Bool, Never>?
        await withCheckedContinuation { started in
            pending = Task { @MainActor in
                await SelectedHIDClientLifetime.run(descriptor: pair.server, inspectPeer: { descriptor in
                    inspections += 1
                    return SelectedHIDClientLifetime.peerState(descriptor: descriptor)
                }) {
                    started.resume()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        return false
                    } catch {
                        return Task.isCancelled
                    }
                }
            }
        }
        Darwin.close(pair.client)
        let task = try #require(pending)
        #expect(await task.value)
        let completedInspections = inspections
        try await Task.sleep(for: .milliseconds(75))
        #expect(inspections == completedInspections)
    }

    @Test func normalCompletionJoinsTheMonitorBeforeTheCallerCanReuseTheDescriptor() async throws {
        let pair = try socketPair()
        defer { Darwin.close(pair.client) }
        var inspections = 0
        let result = await SelectedHIDClientLifetime.run(descriptor: pair.server, inspectPeer: { descriptor in
            inspections += 1
            return SelectedHIDClientLifetime.peerState(descriptor: descriptor)
        }) { 42 }
        #expect(result == 42)
        Darwin.close(pair.server)
        let completedInspections = inspections
        try await Task.sleep(for: .milliseconds(75))
        #expect(inspections == completedInspections)
    }

    @Test func parentCancellationReachesTheOwnedOperation() async throws {
        let pair = try socketPair()
        defer { Darwin.close(pair.server); Darwin.close(pair.client) }
        var pending: Task<Bool, Never>?
        await withCheckedContinuation { started in
            pending = Task { @MainActor in
                await SelectedHIDClientLifetime.run(descriptor: pair.server) {
                    started.resume()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        return false
                    } catch {
                        return Task.isCancelled
                    }
                }
            }
        }
        let task = try #require(pending)
        task.cancel()
        #expect(await task.value)
    }
}
