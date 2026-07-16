import Darwin
import Foundation
import FBControlCore
import FBSimulatorControl

struct HIDBrokerPrimitive: Codable, Equatable {
    enum Kind: String, Codable {
        case down
        case up
        case delay
    }

    let kind: Kind
    let x: Double?
    let y: Double?
    let duration: Double?

    static func touch(_ kind: Kind, x: Double, y: Double) -> Self {
        Self(kind: kind, x: x, y: y, duration: nil)
    }

    static func delay(_ duration: Double) -> Self {
        Self(kind: .delay, x: nil, y: nil, duration: duration)
    }
}

private struct HIDBrokerRequest: Codable {
    let primitives: [HIDBrokerPrimitive]
}

struct HIDBrokerBootIdentity: Equatable {
    let processIdentifier: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

enum HIDBroker {
    static let inputDeliveryFailureDescription = "AXe could not deliver simulator input. The simulator may have restarted or disconnected. Confirm it is booted and try again."
    static let dtuhidMinimumBootUptime: TimeInterval = 10
    private static let protocolVersion = 2
    static let maximumMessageBytes = 64 * 1024
    private static let idleTimeoutMilliseconds: Int32 = 60_000
    static let serverIOTimeoutMilliseconds: Int = 2_000
    static let clientWriteTimeoutMilliseconds: Int = 2_000
    static let clientResponseTimeoutMilliseconds: Int = 30_000
    static let startupAttempts = 300
    static let startupTimeoutNanoseconds: UInt64 = 30_000_000_000
    static func sendTouchPrimitives(
        _ primitives: [HIDBrokerPrimitive],
        simulatorUDID: String
    ) throws {
        let endpoint = try endpointPath(simulatorUDID: simulatorUDID)
        try sendTouchPrimitives(primitives) {
            try connectToReadyBroker(simulatorUDID: simulatorUDID, endpoint: endpoint)
        }
    }

    static func sendTouchPrimitives(
        _ primitives: [HIDBrokerPrimitive],
        descriptorProvider: () throws -> Int32
    ) throws {
        let request = HIDBrokerRequest(primitives: primitives)
        var requestData = try JSONEncoder().encode(request)
        requestData.append(0x0A)
        guard requestData.count <= maximumMessageBytes else {
            throw CLIError(errorDescription: "HID broker request exceeds the maximum size.")
        }

        // Recovery is limited to broker readiness. Once exchange starts, a lost response has an
        // ambiguous outcome, so the request must never be reconnected or replayed.
        let descriptor = try descriptorProvider()
        defer { Darwin.close(descriptor) }
        try exchange(requestData, on: descriptor)
    }

    @MainActor
    static func serve(simulatorUDID: String, logger: AxeLogger) async throws {
        let endpoint = try endpointPath(simulatorUDID: simulatorUDID)
        let listener = try makeListener(at: endpoint)
        let endpointIdentity = try socketIdentity(at: endpoint)
        defer {
            Darwin.close(listener)
            try? removeOwnedSocket(endpoint, matching: endpointIdentity)
        }

        let bootIdentity = try currentBootIdentity(simulatorUDID: simulatorUDID)
        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        while true {
            var pollDescriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, idleTimeoutMilliseconds)
            if result == 0 {
                return
            }
            guard result > 0 else {
                if errno == EINTR { continue }
                throw posixError("poll")
            }

            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                throw posixError("accept")
            }
            configureNoSignalPipe(client)
            try configureSocketTimeouts(
                client,
                readMilliseconds: serverIOTimeoutMilliseconds,
                writeMilliseconds: serverIOTimeoutMilliseconds
            )
            guard shouldReuseSession(
                sessionBootIdentity: bootIdentity,
                currentBootIdentity: try currentBootIdentity(simulatorUDID: simulatorUDID)
            ) else {
                try? writeHandshake(ready: false, to: client)
                Darwin.close(client)
                return
            }
            do {
                try writeHandshake(ready: true, to: client)
            } catch {
                Darwin.close(client)
                continue
            }
            let shouldContinue = await handle(client: client, session: session, logger: logger)
            Darwin.close(client)
            if !shouldContinue {
                return
            }
        }
    }

    @MainActor
    private static func handle(
        client: Int32,
        session: HIDInteractor.Session,
        logger: AxeLogger
    ) async -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            try? writeResponse(error: "HID broker rejected a client owned by another user.", to: client)
            return true
        }

        var shouldContinue = true
        do {
            let data = try readMessage(from: client)
            let request = try JSONDecoder().decode(HIDBrokerRequest.self, from: data)
            for primitive in request.primitives {
                switch primitive.kind {
                case .down, .up:
                    guard let x = primitive.x, let y = primitive.y else {
                        throw CLIError(errorDescription: "Touch primitive is missing coordinates.")
                    }
                    let direction: FBSimulatorHIDDirection = primitive.kind == .down ? .down : .up
                    do {
                        try await HIDInteractor.performHIDEvent(
                            .touch(direction: direction, x: x, y: y),
                            in: session,
                            logger: logger
                        )
                    } catch {
                        shouldContinue = false
                        throw error
                    }
                case .delay:
                    guard let duration = primitive.duration, duration >= 0, duration <= 10 else {
                        throw CLIError(errorDescription: "HID broker delay is invalid.")
                    }
                    try await Task.sleep(for: .seconds(duration))
                }
            }
            try writeResponse(error: nil, to: client)
        } catch {
            logger.error().log("HID broker request failed: \(error.localizedDescription)")
            try? writeResponse(error: brokerResponseDescription(for: error), to: client)
        }
        return shouldContinue
    }

    static func brokerResponseDescription(for error: Error) -> String {
        if let userFacingError = error as? UserFacingError {
            return userFacingError.userFacingDescription
        }
        return inputDeliveryFailureDescription
    }

    static func endpointPath(simulatorUDID: String) throws -> String {
        let developerDirectory = try FBXcodeDirectory.resolveDeveloperDirectory()
        return try endpointPath(simulatorUDID: simulatorUDID, developerDirectory: developerDirectory)
    }

    static func endpointPath(simulatorUDID: String, developerDirectory: String) throws -> String {
        let uid = getuid()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("axe-hid-\(uid)", isDirectory: true)
        try ensurePrivateDirectory(root.path, uid: uid)
        let developerDirectory = URL(fileURLWithPath: developerDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let identity = String(fnv1a64(developerDirectory), radix: 16)
        let simulatorIdentity = String(fnv1a64(simulatorUDID), radix: 16)
        // Version the endpoint so a running broker from an older wire protocol cannot intercept
        // a request before the current client completes its readiness handshake.
        let filename = "\(simulatorIdentity)-\(identity)-v\(protocolVersion).sock"
        let path = root.appendingPathComponent(filename).path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw CLIError(errorDescription: "HID broker socket path is too long.")
        }
        return path
    }

    private static func ensurePrivateDirectory(_ path: String, uid: uid_t) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == uid,
                  info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
                throw CLIError(errorDescription: "HID broker directory is not a private owned directory.")
            }
            return
        }
        guard errno == ENOENT else { throw posixError("lstat") }
        guard mkdir(path, S_IRWXU) == 0 || errno == EEXIST else { throw posixError("mkdir") }
        guard lstat(path, &info) == 0 else { throw posixError("lstat") }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid else {
            throw CLIError(errorDescription: "HID broker directory is not a private owned directory.")
        }
        guard chmod(path, S_IRWXU) == 0 else { throw posixError("chmod") }
        guard lstat(path, &info) == 0 else { throw posixError("lstat") }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == uid,
              info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CLIError(errorDescription: "HID broker directory is not a private owned directory.")
        }
    }

    private static func spawnBroker(simulatorUDID: String) throws {
        guard let executable = Bundle.main.executableURL else {
            throw CLIError(errorDescription: "Unable to locate the AXe executable for the HID broker.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["hid-broker", "--udid", simulatorUDID]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func connectToReadyBroker(simulatorUDID: String, endpoint: String) throws -> Int32 {
        do {
            return try connectToReadyBroker(
                simulatorUDID: simulatorUDID,
                endpoint: endpoint,
                connector: connect(to:),
                spawner: spawnBroker(simulatorUDID:),
                sleeper: { _ = usleep($0) }
            )
        } catch {
            logDiagnostic(error)
            throw error
        }
    }

    static func connectToReadyBroker(
        simulatorUDID: String,
        endpoint: String,
        connector: (String) throws -> Int32,
        spawner: (String) throws -> Void,
        sleeper: (useconds_t) -> Void,
        monotonicNow: () -> UInt64 = monotonicTimeNanoseconds
    ) throws -> Int32 {
        let startedAt = monotonicNow()
        let deadlineResult = startedAt.addingReportingOverflow(startupTimeoutNanoseconds)
        let deadline = deadlineResult.overflow ? UInt64.max : deadlineResult.partialValue
        func handshakeTimeout() throws -> Int {
            let now = monotonicNow()
            guard now < deadline else {
                throw HIDBrokerNotReadyError(diagnosticDescription: "The broker startup deadline expired.")
            }
            let remainingMilliseconds = max(1, Int((deadline - now) / 1_000_000))
            return min(serverIOTimeoutMilliseconds, remainingMilliseconds)
        }

        do {
            return try connectAndAwaitHandshake(
                endpoint: endpoint,
                connector: connector,
                timeoutMilliseconds: handshakeTimeout()
            )
        } catch {
            guard isBrokerUnavailable(error) else { throw error }
        }
        // Hold the endpoint lock until the listener accepts connections so concurrent cold-start
        // clients wait for this broker instead of spawning competitors.
        let lockDescriptor = try acquireStartupLock(
            endpoint: endpoint,
            deadline: deadline,
            monotonicNow: monotonicNow,
            sleeper: sleeper
        )
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        do {
            return try connectAndAwaitHandshake(
                endpoint: endpoint,
                connector: connector,
                timeoutMilliseconds: handshakeTimeout()
            )
        } catch {
            guard isBrokerUnavailable(error) else { throw error }
        }
        var didSpawnBroker = false
        if try !isBrokerProcessAlive(endpoint: endpoint) {
            try waitForStaleEndpointShutdown(
                endpoint,
                deadline: deadline,
                monotonicNow: monotonicNow,
                sleeper: sleeper
            )
            try spawner(simulatorUDID)
            didSpawnBroker = true
        }
        var lastError: Error?
        for _ in 0..<startupAttempts {
            guard monotonicNow() < deadline else { break }
            do {
                return try connectAndAwaitHandshake(
                    endpoint: endpoint,
                    connector: connector,
                    timeoutMilliseconds: handshakeTimeout()
                )
            } catch {
                guard isBrokerUnavailable(error) else { throw error }
                lastError = error
                if let notReady = error as? HIDBrokerNotReadyError,
                   notReady.isSafeToReplaceBroker {
                    try waitForStaleEndpointShutdown(
                        endpoint,
                        deadline: deadline,
                        monotonicNow: monotonicNow,
                        sleeper: sleeper
                    )
                    try spawner(simulatorUDID)
                    didSpawnBroker = true
                } else if let notReady = error as? HIDBrokerNotReadyError,
                          notReady.allowsReplacementAfterProcessExit,
                          try !isBrokerProcessAlive(endpoint: endpoint) {
                    try waitForStaleEndpointShutdown(
                        endpoint,
                        deadline: deadline,
                        monotonicNow: monotonicNow,
                        sleeper: sleeper
                    )
                    try spawner(simulatorUDID)
                    didSpawnBroker = true
                } else if try !isBrokerProcessAlive(endpoint: endpoint), !didSpawnBroker {
                    try waitForStaleEndpointShutdown(
                        endpoint,
                        deadline: deadline,
                        monotonicNow: monotonicNow,
                        sleeper: sleeper
                    )
                    try spawner(simulatorUDID)
                    didSpawnBroker = true
                }
                sleeper(100_000)
            }
        }
        let failure: HIDBrokerNotReadyError
        if let notReady = lastError as? HIDBrokerNotReadyError {
            failure = notReady
        } else {
            failure = HIDBrokerNotReadyError(
                diagnosticDescription: "Broker startup failed: \(lastError?.localizedDescription ?? "no connection attempt completed")",
                isSafeToReplaceBroker: false
            )
        }
        throw failure
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        string.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

}
