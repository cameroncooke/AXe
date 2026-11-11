import Darwin
import Dispatch
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("HID Broker Tests")
struct HIDBrokerTests {
    private final class StartupState: @unchecked Sendable {
        private let condition = NSCondition()
        private let expectedInitialConnections: Int
        private var initialConnectionCount = 0
        private var isReady = false
        private var peerDescriptors: [Int32] = []
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
            var descriptors = [Int32](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try HIDBroker.writeAll(Data(#"{"ready":true}"#.utf8 + [0x0A]), to: descriptors[1])
            condition.lock()
            peerDescriptors.append(descriptors[1])
            condition.unlock()
            return descriptors[0]
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

        func closePeers() {
            condition.lock()
            let descriptors = peerDescriptors
            peerDescriptors.removeAll()
            condition.unlock()
            descriptors.forEach { Darwin.close($0) }
        }
    }

    private final class RecoveryState: @unchecked Sendable {
        private let lock = NSLock()
        private var staleRequestByteCount = 0
        private var replacementRequests: [Data] = []
        private var errors: [String] = []
        private var spawnAttempt = 0

        func nextSpawnAttempt() -> Int {
            lock.lock()
            defer { lock.unlock() }
            spawnAttempt += 1
            return spawnAttempt
        }

        func recordStaleRead(byteCount: Int) {
            lock.lock()
            staleRequestByteCount += max(0, byteCount)
            lock.unlock()
        }

        func recordReplacementRequest(_ data: Data) {
            lock.lock()
            replacementRequests.append(data)
            lock.unlock()
        }

        func record(_ error: Error) {
            lock.lock()
            errors.append(error.localizedDescription)
            lock.unlock()
        }

        func snapshot() -> (staleRequestByteCount: Int, replacementRequests: [Data], errors: [String]) {
            lock.lock()
            defer { lock.unlock() }
            return (staleRequestByteCount, replacementRequests, errors)
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

    // Issue #83: the per-user temporary directory is 48 bytes, so a five-digit uid pushed the
    // socket to 104 bytes, past sun_path, and every input command failed.
    private static let issue83TemporaryDirectory = "/var/folders/z6/14g3y9bx6635wxl4my_dw2q0001ks1/T/"
    private static let fullLengthFilename = String(repeating: "a", count: 16) + "-" + String(repeating: "b", count: 16) + "-v3.sock"

    @Test("A socket that fits stays in the per-user temporary directory, as in every earlier release")
    func endpointStaysInTemporaryDirectoryWhenItFits() throws {
        let location = try #require(HIDBroker.endpointLocation(
            filename: Self.fullLengthFilename, uid: 501, temporaryDirectory: Self.issue83TemporaryDirectory))
        #expect(location.directory == "/var/folders/z6/14g3y9bx6635wxl4my_dw2q0001ks1/T/axe-hid-501")
        #expect(location.path == location.directory + "/" + Self.fullLengthFilename)
        #expect(location.path.utf8.count == 102)
    }

    @Test("Users with long uids get a socket that fits sun_path (issue #83)", arguments: [52001, 4_294_967_294] as [uid_t])
    func endpointFitsForLongUIDs(uid: uid_t) throws {
        let location = try #require(HIDBroker.endpointLocation(
            filename: Self.fullLengthFilename, uid: uid, temporaryDirectory: Self.issue83TemporaryDirectory))
        #expect(location.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path))
        #expect(location.directory == "/tmp/axe-hid-\(uid)")
        #expect(location.path == location.directory + "/" + Self.fullLengthFilename)
    }

    @Test("The current user's endpoint is unchanged from earlier releases when it fits")
    func endpointMatchesEarlierReleases() throws {
        let path = try HIDBroker.endpointPath(simulatorUDID: "simulator-a", developerDirectory: "/candidate-device-input", version: 3)
        let earlierRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("axe-hid-\(getuid())", isDirectory: true)
        let earlier = earlierRoot.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        if earlier.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) {
            #expect(path == earlier)
        } else {
            #expect(path.hasPrefix("/tmp/axe-hid-\(getuid())/"))
        }
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
            #expect(cliError?.errorDescription.contains("result is unknown") == true)
            #expect(cliError?.errorDescription.contains("was not repeated") == true)
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
        defer {
            try? FileManager.default.removeItem(atPath: endpoint + ".lock")
            try? FileManager.default.removeItem(atPath: endpoint + ".lifetime.lock")
        }
        let clientCount = 8
        let state = StartupState(expectedInitialConnections: clientCount)
        defer { state.closePeers() }
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
        let diagnostics = state.errors.compactMap { ($0 as? HIDBrokerNotReadyError)?.diagnosticDescription }
        #expect(state.errors.isEmpty, "Broker diagnostics: \(diagnostics)")
    }

    @Test("A stale broker is replaced without receiving or replaying the touch request")
    func staleBrokerIsSafelyReplaced() throws {
        let endpoint = try HIDBroker.endpointPath(
            simulatorUDID: UUID().uuidString,
            developerDirectory: FileManager.default.temporaryDirectory.path
        )
        defer {
            try? HIDBroker.removeOwnedSocket(endpoint)
            try? FileManager.default.removeItem(atPath: endpoint + ".lock")
        }
        let state = RecoveryState()
        let staleFinished = DispatchSemaphore(value: 0)
        let replacementFinished = DispatchSemaphore(value: 0)
        let staleListener = try HIDBroker.makeListener(at: endpoint)

        Thread.detachNewThread {
            defer {
                Darwin.close(staleListener)
                try? HIDBroker.removeOwnedSocket(endpoint)
                staleFinished.signal()
            }
            do {
                for _ in 0..<2 {
                    let client = try Self.acceptClient(on: staleListener)
                    try HIDBroker.writeAll(Data("{\"ready\":false}\n".utf8), to: client)
                    var byte: UInt8 = 0
                    state.recordStaleRead(byteCount: Darwin.read(client, &byte, 1))
                    Darwin.close(client)
                }
                let shutdownProbe = try Self.acceptClient(on: staleListener)
                Darwin.close(shutdownProbe)
            } catch {
                state.record(error)
            }
        }

        try HIDBroker.sendTouchPrimitives([.touch(.down, x: 10, y: 20)]) {
            try HIDBroker.connectToReadyBroker(
                simulatorUDID: "simulator-a",
                endpoint: endpoint,
                connector: HIDBroker.connect(to:),
                spawner: { _ in
                    let replacementListener = try HIDBroker.makeListener(at: endpoint)
                    let replacementIdentity = try HIDBroker.socketIdentity(at: endpoint)
                    if state.nextSpawnAttempt() == 1 {
                        Thread.detachNewThread {
                            defer {
                                Darwin.close(replacementListener)
                                try? HIDBroker.removeOwnedSocket(endpoint, matching: replacementIdentity)
                            }
                            do {
                                let client = try Self.acceptClient(on: replacementListener)
                                Darwin.close(client)
                            } catch {
                                state.record(error)
                            }
                        }
                        return
                    }
                    Thread.detachNewThread {
                        defer {
                            Darwin.close(replacementListener)
                            try? HIDBroker.removeOwnedSocket(endpoint, matching: replacementIdentity)
                            replacementFinished.signal()
                        }
                        do {
                            let client = try Self.acceptClient(on: replacementListener)
                            defer { Darwin.close(client) }
                            try HIDBroker.writeAll(Data("{\"ready\":true}\n".utf8), to: client)
                            state.recordReplacementRequest(try HIDBroker.readMessage(from: client))
                            try HIDBroker.writeAll(Data("{\"error\":null}\n".utf8), to: client)
                        } catch {
                            state.record(error)
                        }
                    }
                },
                sleeper: { _ = usleep($0) }
            )
        }

        #expect(staleFinished.wait(timeout: .now() + 2) == .success)
        #expect(replacementFinished.wait(timeout: .now() + 2) == .success)
        let snapshot = state.snapshot()
        #expect(snapshot.staleRequestByteCount == 0)
        #expect(snapshot.replacementRequests.count == 1)
        #expect(snapshot.errors.isEmpty)
        if let request = snapshot.replacementRequests.first {
            let json = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let primitives = try #require(json["primitives"] as? [[String: Any]])
            #expect(primitives.count == 1)
            #expect(primitives[0]["kind"] as? String == "down")
            #expect(primitives[0]["x"] as? Double == 10)
            #expect(primitives[0]["y"] as? Double == 20)
        }
    }

    @Test("An exiting broker cannot unlink a replacement endpoint")
    func brokerCleanupIsSocketSpecific() throws {
        let endpoint = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let oldListener = try HIDBroker.makeListener(at: endpoint)
        let oldIdentity = try HIDBroker.socketIdentity(at: endpoint)
        try HIDBroker.removeOwnedSocket(endpoint)
        Darwin.close(oldListener)

        let replacementListener = try HIDBroker.makeListener(at: endpoint)
        defer {
            Darwin.close(replacementListener)
            try? HIDBroker.removeOwnedSocket(endpoint)
        }
        try HIDBroker.removeOwnedSocket(endpoint, matching: oldIdentity)

        let client = try HIDBroker.connect(to: endpoint)
        Darwin.close(client)
    }

    private static func acceptClient(on listener: Int32) throws -> Int32 {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client >= 0 {
                return client
            }
            if errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
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

@Suite("Raw broker contact lifetime")
@MainActor
struct HIDBrokerContactLifetimeTests {
    @Test("An invalid delay refuses the request before its DOWN is sent")
    func invalidDelayRejectsBeforeDown() {
        let request: [HIDBrokerPrimitive] = [.touch(.down, x: 10, y: 20), .delay(11), .touch(.up, x: 10, y: 20)]
        #expect(throws: CLIError.self) { try HIDBroker.validate(request) }
        let missing = HIDBrokerPrimitive(kind: .up, x: nil, y: 4, duration: nil)
        #expect(throws: CLIError.self) { try HIDBroker.validate([.touch(.down, x: 1, y: 2), missing]) }
        #expect(throws: CLIError.self) { try HIDBroker.validate([.touch(.down, x: .nan, y: 2)]) }
        #expect(throws: CLIError.self) {
            try HIDBroker.validate(Array(repeating: .delay(0), count: 1025))
        }
        #expect(throws: Never.self) { try HIDBroker.validate(Array(request.prefix(1)) + [.delay(10)]) }
    }

    @Test("A broker that exits while a contact is held sends its UP first")
    func idleExitReleasesRetainedContact() async throws {
        var sent: [FBSimulatorHIDEvent] = []
        var contact: HIDBrokerRetainedContact?
        try await HIDBroker.send([.touch(.down, x: 10, y: 20)], retainedContact: &contact) { sent.append($0) }
        #expect(contact == HIDBrokerRetainedContact(x: 10, y: 20))

        await HIDBroker.releaseRetainedContact(&contact, logger: AxeLogger()) { sent.append($0) }
        #expect(contact == nil)
        #expect(sent == [.touch(direction: .down, x: 10, y: 20), .touch(direction: .up, x: 10, y: 20)])

        await HIDBroker.releaseRetainedContact(&contact, logger: AxeLogger()) { sent.append($0) }
        #expect(sent.count == 2)
    }

    @Test("A completed contact leaves nothing to release")
    func completedContactIsNotRetained() async throws {
        var sent: [FBSimulatorHIDEvent] = []
        var contact: HIDBrokerRetainedContact?
        try await HIDBroker.send([.touch(.down, x: 1, y: 2), .delay(0), .touch(.up, x: 3, y: 4)],
            retainedContact: &contact) { sent.append($0) }
        #expect(contact == nil)
        await HIDBroker.releaseRetainedContact(&contact, logger: AxeLogger()) { sent.append($0) }
        #expect(sent.count == 2)
    }
}
