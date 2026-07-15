import Darwin
import Dispatch
import Foundation
import Testing
@testable import AXe

@Suite("HID Broker Tests")
struct HIDBrokerTests {
    private final class StartupState: @unchecked Sendable {
        private let condition = NSCondition()
        private let expectedInitialConnections: Int
        private var initialConnectionCount = 0
        private var isReady = false
        private(set) var spawnCount = 0
        private(set) var successCount = 0
        private(set) var errors: [Error] = []

        init(expectedInitialConnections: Int) {
            self.expectedInitialConnections = expectedInitialConnections
        }

        func connect() throws -> Int32 {
            condition.lock()
            if !isReady, initialConnectionCount < expectedInitialConnections {
                initialConnectionCount += 1
                condition.broadcast()
                while initialConnectionCount < expectedInitialConnections {
                    condition.wait()
                }
            }
            let ready = isReady
            condition.unlock()
            guard ready else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return descriptor
        }

        func spawn() {
            condition.lock()
            spawnCount += 1
            isReady = true
            condition.unlock()
        }

        func recordSuccess() {
            condition.lock()
            successCount += 1
            condition.unlock()
        }

        func record(_ error: Error) {
            condition.lock()
            errors.append(error)
            condition.unlock()
        }
    }

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

    @Test("Ambiguous broker responses are not replayed")
    func ambiguousResponseIsNotReplayed() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { Darwin.close(descriptors[1]) }

        try HIDBroker.writeAll(Data("not-json\n".utf8), to: descriptors[1])
        var descriptorRequests = 0
        do {
            try HIDBroker.sendTouchPrimitives([]) {
                descriptorRequests += 1
                return descriptors[0]
            }
            Issue.record("An invalid response should fail with an ambiguous outcome")
        } catch {
            let cliError = error as? CLIError
            #expect(cliError?.errorDescription.contains("outcome is unknown") == true)
            #expect(cliError?.errorDescription.contains("was not replayed") == true)
        }

        let request = try HIDBroker.readMessage(from: descriptors[1])
        #expect(descriptorRequests == 1)
        #expect(String(decoding: request, as: UTF8.self) == #"{"primitives":[]}"#)
    }

    @Test("Concurrent cold starts spawn one broker")
    func concurrentColdStartSpawnsOnce() throws {
        let endpoint = try HIDBroker.endpointPath(
            simulatorUDID: UUID().uuidString,
            developerDirectory: FileManager.default.temporaryDirectory.path
        )
        defer { try? FileManager.default.removeItem(atPath: endpoint + ".lock") }
        let clientCount = 8
        let state = StartupState(expectedInitialConnections: clientCount)
        let group = DispatchGroup()

        for _ in 0..<clientCount {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                do {
                    let descriptor = try HIDBroker.connectToReadyBroker(
                        simulatorUDID: "simulator-a",
                        endpoint: endpoint,
                        connector: { _ in try state.connect() },
                        spawner: { _ in state.spawn() },
                        sleeper: { _ = usleep($0) }
                    )
                    Darwin.close(descriptor)
                    state.recordSuccess()
                } catch {
                    state.record(error)
                }
            }
        }
        group.wait()

        #expect(state.spawnCount == 1)
        #expect(state.successCount == clientCount)
        #expect(state.errors.isEmpty)
    }

    @Test("Broker endpoints use the canonical developer directory")
    func endpointUsesCanonicalDeveloperDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let developerDirectory = root.appendingPathComponent("Xcode.app/Contents/Developer", isDirectory: true)
        let alias = root.appendingPathComponent("SelectedDeveloper", isDirectory: true)
        try FileManager.default.createDirectory(at: developerDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: developerDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let canonical = try HIDBroker.endpointPath(
            simulatorUDID: "simulator-a",
            developerDirectory: developerDirectory.path
        )
        let selectedAlias = try HIDBroker.endpointPath(
            simulatorUDID: "simulator-a",
            developerDirectory: alias.path
        )

        #expect(canonical == selectedAlias)
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
