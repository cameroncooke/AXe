import Darwin
import Dispatch
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

/// The DOWN point of a contact the raw broker holds across CLI calls.
struct HIDBrokerRetainedContact: Equatable {
    let x: Double
    let y: Double
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
    static let protocolVersion = 5
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
        try send(HIDBrokerRequest(primitives: primitives), descriptorProvider: descriptorProvider)
    }

    private static func send(_ request: HIDBrokerRequest, descriptorProvider: () throws -> Int32) throws {
        var requestData = try JSONEncoder().encode(request)
        requestData.append(0x0A)
        guard requestData.count <= maximumMessageBytes else {
            throw CLIError(errorDescription: "The input request exceeds the maximum size.", code: .invalidArguments)
        }

        // Recovery is limited to broker readiness. Once exchange starts, a lost response has an
        // ambiguous outcome, so the request must never be reconnected or replayed.
        let descriptor = try descriptorProvider()
        defer { Darwin.close(descriptor) }
        try exchange(requestData, on: descriptor)
    }

    private static let socketIO = DispatchQueue(label: "axe.raw-hid.socket", attributes: .concurrent)

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            socketIO.async { continuation.resume(with: Result { try work() }) }
        }
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
        var session: HIDInteractor.Session? = nil
        var retainedContact: HIDBrokerRetainedContact? = nil
        // One admitted task runs at a time. Retained touch state is separate so MOVE/UP remains valid.
        var active: Task<Void, Never>?
        let admission = HIDBrokerRequestAdmission()
        var shouldStop = false
        var lastActivity = ProcessInfo.processInfo.systemUptime
        do {
            while !shouldStop {
                if active == nil && ProcessInfo.processInfo.systemUptime - lastActivity >= Double(idleTimeoutMilliseconds) / 1000 {
                    break
                }
                let accepted = try await offMain {
                    var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                    let count = Darwin.poll(&descriptor, 1, 250)
                    if count == 0 || (count < 0 && errno == EINTR) { return (Int32(-1), Optional<UUID>.none) }
                    guard count > 0 else { throw posixError("poll") }
                    let accepted = Darwin.accept(listener, nil, nil)
                    guard accepted >= 0 else { throw posixError("accept") }
                    return (accepted, admission.reserve())
                }
                let client = accepted.0
                guard client >= 0 else { continue }
                configureNoSignalPipe(client)
                do {
                    try configureSocketTimeouts(client, readMilliseconds: serverIOTimeoutMilliseconds,
                        writeMilliseconds: serverIOTimeoutMilliseconds)
                } catch {
                    Darwin.close(client)
                    if let token = accepted.1 { admission.release(token) }
                    throw error
                }

                guard let reservation = accepted.1 else {
                    // Terminal handshake: the client must not send its body or enter startup recovery.
                    try? await offMain { try writeHandshake(ready: false, version: protocolVersion,
                        rejection: "busy", to: client) }
                    Darwin.close(client)
                    continue
                }
                // A failed active send can retire the broker while accept is off the actor.
                // This request has not sent a body and must not use the failed native session.
                guard !shouldStop else {
                    try? await offMain { try writeHandshake(ready: false, version: protocolVersion, to: client) }
                    Darwin.close(client)
                    admission.release(reservation)
                    break
                }
                let currentBoot: HIDBrokerBootIdentity
                do { currentBoot = try currentBootIdentity(simulatorUDID: simulatorUDID) }
                catch {
                    Darwin.close(client); admission.release(reservation); throw error
                }
                guard bootIdentity == currentBoot else {
                    try? await offMain { try writeHandshake(ready: false, version: protocolVersion, to: client) }
                    Darwin.close(client)
                    admission.release(reservation)
                    break
                }
                // Assign before the task can suspend on handshake, body read, native input or response.
                active = Task { @MainActor in
                    defer {
                        Darwin.close(client)
                        active = nil
                        lastActivity = ProcessInfo.processInfo.systemUptime
                        admission.release(reservation)
                    }
                    do {
                        try await offMain { try writeHandshake(ready: true, version: protocolVersion, to: client) }
                        let keepServing = await handle(client: client, simulatorUDID: simulatorUDID,
                            session: &session, retainedContact: &retainedContact, logger: logger)
                        if !keepServing { shouldStop = true }
                    } catch { logger.error().log("Raw broker handshake failed before input: \(error.localizedDescription)") }
                }
            }
        } catch {
            if let active { await active.value }
            await releaseRetainedContact(&retainedContact, session: session, logger: logger)
            throw error
        }
        if let active { await active.value }
        // An idle or retiring broker must not leave a DOWN held after it exits.
        await releaseRetainedContact(&retainedContact, session: session, logger: logger)
    }

    @MainActor
    private static func releaseRetainedContact(
        _ contact: inout HIDBrokerRetainedContact?,
        session: HIDInteractor.Session?,
        logger: AxeLogger
    ) async {
        guard let session else { return }
        await releaseRetainedContact(&contact, logger: logger) { event in
            try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
        }
    }

    /// Sends one UP at the held DOWN point. A failed release is logged and never repeated.
    static func releaseRetainedContact(
        _ contact: inout HIDBrokerRetainedContact?,
        logger: AxeLogger,
        send: (FBSimulatorHIDEvent) async throws -> Void
    ) async {
        guard let point = contact else { return }
        contact = nil
        do { try await send(.touch(direction: .up, x: point.x, y: point.y)) }
        catch { logger.error().log("Raw broker could not release its held contact: \(error.localizedDescription)") }
    }

    @MainActor
    private static func handle(
        client: Int32,
        simulatorUDID: String,
        session: inout HIDInteractor.Session?,
        retainedContact: inout HIDBrokerRetainedContact?,
        logger: AxeLogger
    ) async -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            try? await offMain { try writeResponse(error: "The AXe input service belongs to another user.", to: client) }
            return true
        }

        var shouldContinue = true
        do {
            let data = try await offMain { try readMessage(from: client) }
            let request = try JSONDecoder().decode(HIDBrokerRequest.self, from: data)
            try await perform(request.primitives, simulatorUDID: simulatorUDID,
                session: &session, retainedContact: &retainedContact,
                shouldContinue: &shouldContinue, logger: logger)
            // A completed UP releases common input ownership before the client receives success.
            // A failed request keeps the prior ownership policy; it is never declared clear here.
            if retainedContact == nil { session = nil }
            try await offMain { try writeResponse(error: nil, to: client) }
        } catch {
            logger.error().log("HID broker request failed: \(error.localizedDescription)")
            let description = brokerResponseDescription(for: error)
            try? await offMain { try writeResponse(error: description, to: client) }
        }
        return shouldContinue
    }

    /// Keep one raw session while a contact spans CLI calls. Idle brokers do not own input.
    @MainActor
    private static func perform(
        _ primitives: [HIDBrokerPrimitive],
        simulatorUDID: String,
        session: inout HIDInteractor.Session?,
        retainedContact: inout HIDBrokerRetainedContact?,
        shouldContinue: inout Bool,
        logger: AxeLogger
    ) async throws {
        try validate(primitives)
        let activeSession: HIDInteractor.Session
        if let session {
            activeSession = session
        } else {
            activeSession = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
            session = activeSession
        }
        do {
            try await send(primitives, retainedContact: &retainedContact) { event in
                try await HIDInteractor.performHIDEvent(event, in: activeSession, logger: logger)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            shouldContinue = false
            throw error
        }
    }

    /// The broker is the trust boundary: refuse the whole request before its first event.
    static func validate(_ primitives: [HIDBrokerPrimitive]) throws {
        // An empty list, such as a keyboard request from an older build, has nothing to send.
        guard !primitives.isEmpty else {
            throw CLIError(errorDescription: "The input request has no touch events.", code: .invalidArguments)
        }
        guard primitives.count <= 1024 else {
            throw CLIError(errorDescription: "The input request has too many touch events.", code: .invalidArguments)
        }
        for primitive in primitives {
            switch primitive.kind {
            case .down, .up:
                guard let x = primitive.x, let y = primitive.y, x.isFinite, y.isFinite else {
                    throw CLIError(errorDescription: "Touch primitive is missing coordinates.", code: .invalidArguments)
                }
            case .delay:
                guard let duration = primitive.duration, duration >= 0, duration <= 10 else {
                    throw CLIError(errorDescription: "The input delay is invalid.", code: .invalidArguments)
                }
            }
        }
    }

    /// Sends validated primitives in order and records the DOWN point while a contact is held.
    static func send(
        _ primitives: [HIDBrokerPrimitive],
        retainedContact: inout HIDBrokerRetainedContact?,
        event send: (FBSimulatorHIDEvent) async throws -> Void
    ) async throws {
        for primitive in primitives {
            switch primitive.kind {
            case .down, .up:
                guard let x = primitive.x, let y = primitive.y else {
                    throw CLIError(errorDescription: "Touch primitive is missing coordinates.", code: .invalidArguments)
                }
                let direction: FBSimulatorHIDDirection = primitive.kind == .down ? .down : .up
                try await send(.touch(direction: direction, x: x, y: y))
                retainedContact = primitive.kind == .down ? HIDBrokerRetainedContact(x: x, y: y) : nil
            case .delay:
                try await Task.sleep(for: .seconds(primitive.duration ?? 0))
            }
        }
    }

    static func brokerResponseDescription(for error: Error) -> String {
        if let userFacingError = error as? UserFacingError {
            return userFacingError.userFacingDescription
        }
        return inputDeliveryFailureDescription
    }

    static func endpointPath(simulatorUDID: String, version: Int = protocolVersion) throws -> String {
        let developerDirectory = try FBXcodeDirectory.resolveDeveloperDirectory()
        return try endpointPath(simulatorUDID: simulatorUDID, developerDirectory: developerDirectory, version: version)
    }

    static func endpointPath(simulatorUDID: String, developerDirectory: String, version: Int = protocolVersion) throws -> String {
        let uid = getuid()
        let developerDirectory = URL(fileURLWithPath: developerDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let identity = String(fnv1a64(developerDirectory), radix: 16)
        let simulatorIdentity = String(fnv1a64(simulatorUDID), radix: 16)
        // Version the endpoint so a running broker from an older wire protocol cannot intercept
        // a request before the current client completes its readiness handshake.
        let filename = "\(simulatorIdentity)-\(identity)-v\(version).sock"
        guard let location = endpointLocation(filename: filename, uid: uid, temporaryDirectory: NSTemporaryDirectory()) else {
            throw CLIError(errorDescription: "The AXe input service socket path is too long.", code: .inputUnavailable)
        }
        try ensurePrivateDirectory(location.directory, uid: uid)
        return location.path
    }

    /// The per-user temporary directory is where every release has put the socket, and other AXe
    /// versions find the shared input lease and the quarantine record by that path, so it stays
    /// there whenever it fits `sun_path`. That directory is 48 bytes, which leaves room only for
    /// uids of up to four digits (issue #83); longer uids use `/tmp/axe-hid-<uid>`, where
    /// `ensurePrivateDirectory` still requires a 0700 directory owned by this user.
    static func endpointLocation(filename: String, uid: uid_t, temporaryDirectory: String) -> (directory: String, path: String)? {
        let preferred = URL(fileURLWithPath: temporaryDirectory, isDirectory: true).resolvingSymlinksInPath().path
        for root in [preferred, "/tmp"] {
            let directory = (root.hasSuffix("/") ? root : root + "/") + "axe-hid-\(uid)"
            let path = directory + "/" + filename
            if path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) {
                return (directory, path)
            }
        }
        return nil
    }

    private static func ensurePrivateDirectory(_ path: String, uid: uid_t) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == uid,
                  info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
                throw CLIError(errorDescription: "The AXe input service directory is not private to this user.", code: .inputUnavailable)
            }
            return
        }
        guard errno == ENOENT else { throw posixError("lstat") }
        guard mkdir(path, S_IRWXU) == 0 || errno == EEXIST else { throw posixError("mkdir") }
        guard lstat(path, &info) == 0 else { throw posixError("lstat") }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid else {
            throw CLIError(errorDescription: "The AXe input service directory is not private to this user.", code: .inputUnavailable)
        }
        guard chmod(path, S_IRWXU) == 0 else { throw posixError("chmod") }
        guard lstat(path, &info) == 0 else { throw posixError("lstat") }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == uid,
              info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CLIError(errorDescription: "The AXe input service directory is not private to this user.", code: .inputUnavailable)
        }
    }

    private static func spawnBroker(simulatorUDID: String) throws {
        guard let executable = Bundle.main.executableURL else {
            throw CLIError(errorDescription: "AXe could not locate its own executable to start its input service.", code: .inputUnavailable)
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
                sleeper: { _ = usleep($0) },
                expectedVersion: protocolVersion
            )
        } catch {
            logDiagnostic(error)
            throw error
        }
    }

    /// A connection to a broker that is already running, or nil when there is none. It never starts one.
    static func connectToRunningBroker(endpoint: String, connector: (String) throws -> Int32 = connect(to:),
                                       expectedVersion: Int? = nil) throws -> Int32? {
        do {
            return try connectAndAwaitHandshake(endpoint: endpoint, connector: connector,
                timeoutMilliseconds: serverIOTimeoutMilliseconds, expectedVersion: expectedVersion)
        } catch {
            guard isBrokerUnavailable(error) else { throw error }
            return nil
        }
    }

    static func connectToReadyBroker(
        simulatorUDID: String,
        endpoint: String,
        connector: (String) throws -> Int32,
        spawner: (String) throws -> Void,
        sleeper: (useconds_t) -> Void,
        monotonicNow: () -> UInt64 = monotonicTimeNanoseconds,
        expectedVersion: Int? = nil
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
                timeoutMilliseconds: handshakeTimeout(),
                expectedVersion: expectedVersion
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
                timeoutMilliseconds: handshakeTimeout(),
                expectedVersion: expectedVersion
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
                    timeoutMilliseconds: handshakeTimeout(),
                    expectedVersion: expectedVersion
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
