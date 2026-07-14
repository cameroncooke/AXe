import Darwin
import Foundation
import Testing
@testable import AXe

@Suite("HID Broker Tests")
struct HIDBrokerTests {
    @Test("Broker endpoint is deterministic, bounded, and simulator-specific")
    func endpointIdentity() throws {
        let first = try HIDBroker.endpointPath(simulatorUDID: "simulator-a")
        let repeated = try HIDBroker.endpointPath(simulatorUDID: "simulator-a")
        let second = try HIDBroker.endpointPath(simulatorUDID: "simulator-b")

        #expect(first == repeated)
        #expect(first != second)
        #expect(first.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: URL(fileURLWithPath: first).deletingLastPathComponent().path
        )
        #expect(attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test("Touch primitives preserve their wire values")
    func primitiveRoundTrip() throws {
        let primitives = [
            HIDBrokerPrimitive.touch(.down, x: 12.5, y: 42),
            HIDBrokerPrimitive.delay(0.25),
            HIDBrokerPrimitive.touch(.up, x: 13, y: 43.5),
        ]

        let data = try JSONEncoder().encode(primitives)
        #expect(try JSONDecoder().decode([HIDBrokerPrimitive].self, from: data) == primitives)
    }

    @Test("Broker sessions are scoped to one simulator boot")
    func bootIdentityScopesSession() {
        let original = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 200
        )
        let rebootedWithNewPID = HIDBrokerBootIdentity(
            processIdentifier: 43,
            startSeconds: 101,
            startMicroseconds: 200
        )
        let rebootedWithReusedPID = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 101,
            startMicroseconds: 200
        )

        #expect(HIDBroker.shouldReuseSession(sessionBootIdentity: original, currentBootIdentity: original))
        #expect(!HIDBroker.shouldReuseSession(
            sessionBootIdentity: original,
            currentBootIdentity: rebootedWithNewPID
        ))
        #expect(!HIDBroker.shouldReuseSession(
            sessionBootIdentity: original,
            currentBootIdentity: rebootedWithReusedPID
        ))
    }

    @Test("DTUHID waits only for the remaining simulator boot readiness window")
    func dtuhidReadinessDelay() {
        let bootIdentity = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 250_000
        )

        #expect(HIDBroker.dtuhidReadinessDelay(
            bootIdentity: bootIdentity,
            now: Date(timeIntervalSince1970: 105.25)
        ) == 5)
        #expect(HIDBroker.dtuhidReadinessDelay(
            bootIdentity: bootIdentity,
            now: Date(timeIntervalSince1970: 110.25)
        ) == 0)
        #expect(HIDBroker.dtuhidReadinessDelay(
            bootIdentity: bootIdentity,
            now: Date(timeIntervalSince1970: 120.25)
        ) == 0)
    }

    @Test("DTUHID readiness timing handles a clock earlier than process start")
    func dtuhidReadinessDelayWithEarlierClock() {
        let bootIdentity = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 0
        )

        #expect(HIDBroker.dtuhidReadinessDelay(
            bootIdentity: bootIdentity,
            now: Date(timeIntervalSince1970: 99)
        ) == HIDBroker.dtuhidMinimumBootUptime)
    }

    @Test("DTUHID readiness uses the injected boot identity and clock")
    func dtuhidReadinessWait() async throws {
        let bootIdentity = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 250_000
        )
        var delays: [TimeInterval] = []

        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: bootIdentity,
            isDTUHIDSelected: true,
            now: { Date(timeIntervalSince1970: 106.25) },
            sleep: { delays.append($0) }
        )

        #expect(delays == [4])
    }

    @Test("Legacy Indigo transport is never delayed")
    func indigoReadinessDoesNotWait() async throws {
        let bootIdentity = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 0
        )
        var didSleep = false

        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: bootIdentity,
            isDTUHIDSelected: false,
            now: { Date(timeIntervalSince1970: 100) },
            sleep: { _ in didSleep = true }
        )

        #expect(!didSleep)
    }

    @Test("Partial messages cannot block a broker read indefinitely")
    func partialMessageReadTimesOut() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        try HIDBroker.configureSocketTimeouts(
            descriptors[0],
            readMilliseconds: 100,
            writeMilliseconds: 100
        )
        var partialByte: UInt8 = 0x7B
        #expect(Darwin.write(descriptors[1], &partialByte, 1) == 1)

        let start = Date()
        do {
            _ = try HIDBroker.readMessage(from: descriptors[0])
            Issue.record("A partial message should time out")
        } catch {}
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test("A client that does not read cannot block a broker write indefinitely")
    func unreadResponseWriteTimesOut() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        var bufferBytes: Int32 = 4_096
        #expect(setsockopt(
            descriptors[0],
            SOL_SOCKET,
            SO_SNDBUF,
            &bufferBytes,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0)
        try HIDBroker.configureSocketTimeouts(
            descriptors[0],
            readMilliseconds: 100,
            writeMilliseconds: 100
        )

        let start = Date()
        do {
            try HIDBroker.writeAll(Data(repeating: 0x41, count: 1_048_576), to: descriptors[0])
            Issue.record("An unread response should time out")
        } catch {}
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
