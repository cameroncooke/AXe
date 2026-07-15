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

private struct HIDBrokerResponse: Codable {
    let error: String?
}

struct HIDBrokerBootIdentity: Equatable {
    let processIdentifier: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

enum HIDBroker {
    static let dtuhidMinimumBootUptime: TimeInterval = 10
    private static let maximumMessageBytes = 64 * 1024
    private static let idleTimeoutMilliseconds: Int32 = 60_000
    private static let serverIOTimeoutMilliseconds: Int = 2_000
    private static let clientWriteTimeoutMilliseconds: Int = 2_000
    private static let clientResponseTimeoutMilliseconds: Int = 30_000
    private static let startupAttempts = 300
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
        defer {
            Darwin.close(listener)
            try? removeOwnedSocket(endpoint)
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
                Darwin.close(client)
                return
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
            try? writeResponse(error: error.localizedDescription, to: client)
        }
        return shouldContinue
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
        let filename = "\(simulatorIdentity)-\(identity).sock"
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
        guard chmod(path, S_IRWXU) == 0 else { throw posixError("chmod") }
    }

    private static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw CLIError(errorDescription: "HID broker socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return address
    }

    private static func makeListener(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("socket") }
        configureNoSignalPipe(descriptor)
        do {
            var address = try makeAddress(path: path)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw posixError("bind") }
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw posixError("chmod") }
            guard listen(descriptor, 8) == 0 else { throw posixError("listen") }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func connect(to path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("socket") }
        configureNoSignalPipe(descriptor)
        var address = try makeAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = posixError("connect")
            Darwin.close(descriptor)
            throw error
        }
        do {
            try configureSocketTimeouts(
                descriptor,
                readMilliseconds: clientResponseTimeoutMilliseconds,
                writeMilliseconds: clientWriteTimeoutMilliseconds
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
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
        try connectToReadyBroker(
            simulatorUDID: simulatorUDID,
            endpoint: endpoint,
            connector: connect(to:),
            spawner: spawnBroker(simulatorUDID:),
            sleeper: { _ = usleep($0) }
        )
    }

    static func connectToReadyBroker(
        simulatorUDID: String,
        endpoint: String,
        connector: (String) throws -> Int32,
        spawner: (String) throws -> Void,
        sleeper: (useconds_t) -> Void
    ) throws -> Int32 {
        do {
            return try connector(endpoint)
        } catch {
            guard isBrokerUnavailable(error) else { throw error }
        }
        // Hold the endpoint lock until the listener accepts connections so concurrent cold-start
        // clients wait for this broker instead of spawning competitors.
        let lockDescriptor = try acquireStartupLock(endpoint: endpoint)
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        do {
            return try connector(endpoint)
        } catch {
            guard isBrokerUnavailable(error) else { throw error }
        }
        try removeStaleEndpointIfSafe(endpoint)
        try spawner(simulatorUDID)
        var lastError: Error?
        for _ in 0..<startupAttempts {
            do {
                return try connector(endpoint)
            } catch {
                guard isBrokerUnavailable(error) else { throw error }
                lastError = error
                sleeper(100_000)
            }
        }
        throw lastError ?? CLIError(errorDescription: "Unable to connect to the HID broker.")
    }

    private static func acquireStartupLock(endpoint: String) throws -> Int32 {
        let path = endpoint + ".lock"
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("open startup lock") }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw posixError("fstat startup lock") }
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(),
                  info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
                throw CLIError(errorDescription: "HID broker startup lock is not a private owned file.")
            }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else { throw posixError("lock startup lock") }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func isBrokerUnavailable(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSPOSIXErrorDomain &&
            (error.code == Int(ECONNREFUSED) || error.code == Int(ENOENT))
    }
    static func exchange(_ requestData: Data, on descriptor: Int32) throws {
        let response: HIDBrokerResponse
        do {
            try writeAll(requestData, to: descriptor)
            let responseData = try readMessage(from: descriptor)
            response = try JSONDecoder().decode(HIDBrokerResponse.self, from: responseData)
        } catch {
            throw CLIError(errorDescription: "HID request outcome is unknown and was not replayed: \(error.localizedDescription)")
        }
        if let error = response.error {
            throw CLIError(errorDescription: error)
        }
    }

    private static func removeStaleEndpointIfSafe(_ path: String) throws {
        do {
            let descriptor = try connect(to: path)
            Darwin.close(descriptor)
            return
        } catch {
            if (error as NSError).code != Int(ECONNREFUSED) && (error as NSError).code != Int(ENOENT) {
                throw error
            }
        }
        try removeOwnedSocket(path)
    }

    private static func removeOwnedSocket(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw posixError("lstat")
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            throw CLIError(errorDescription: "Refusing to remove an unowned HID broker endpoint.")
        }
        guard unlink(path) == 0 || errno == ENOENT else { throw posixError("unlink") }
    }

    static func readMessage(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumMessageBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(errorDescription: "HID broker read timed out.")
                }
                throw posixError("read")
            }
            if count == 0 { break }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw CLIError(errorDescription: "HID broker message is missing or exceeds the maximum size.")
    }

    private static func writeResponse(error: String?, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(HIDBrokerResponse(error: error))
        data.append(0x0A)
        try writeAll(data, to: descriptor)
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw CLIError(errorDescription: "HID broker write timed out.")
                    }
                    throw posixError("write")
                }
                offset += count
            }
        }
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        string.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func configureNoSignalPipe(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    static func configureSocketTimeouts(
        _ descriptor: Int32,
        readMilliseconds: Int,
        writeMilliseconds: Int
    ) throws {
        var readTimeout = socketTimeout(milliseconds: readMilliseconds)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &readTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw posixError("setsockopt(SO_RCVTIMEO)")
        }

        var writeTimeout = socketTimeout(milliseconds: writeMilliseconds)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &writeTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw posixError("setsockopt(SO_SNDTIMEO)")
        }
    }

    private static func socketTimeout(milliseconds: Int) -> timeval {
        timeval(
            tv_sec: milliseconds / 1_000,
            tv_usec: Int32((milliseconds % 1_000) * 1_000)
        )
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "HID broker \(operation) failed: \(String(cString: strerror(errno)))"
        ])
    }
}
