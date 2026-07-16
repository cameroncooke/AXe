import Darwin
import Dispatch
import Foundation
import OSLog

// Every connection receives this newline-delimited handshake before the client writes a request.
// A false value guarantees that the broker has not read or executed any touch primitives.
private struct HIDBrokerHandshake: Codable {
    let ready: Bool
}

private struct HIDBrokerResponse: Codable {
    let error: String?
}

struct HIDBrokerNotReadyError: UserFacingError {
    let userFacingDescription = "AXe could not establish simulator input. Wait for the simulator to finish booting and try again."
    let diagnosticDescription: String
    let isSafeToReplaceBroker: Bool
    let allowsReplacementAfterProcessExit: Bool

    init(
        diagnosticDescription: String = "The broker reported that its simulator session is stale.",
        isSafeToReplaceBroker: Bool = true,
        allowsReplacementAfterProcessExit: Bool = false
    ) {
        self.diagnosticDescription = diagnosticDescription
        self.isSafeToReplaceBroker = isSafeToReplaceBroker
        self.allowsReplacementAfterProcessExit = allowsReplacementAfterProcessExit
    }
}

struct HIDBrokerSocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

extension HIDBroker {
    private static let diagnosticLogger = Logger(
        subsystem: "com.cameroncooke.axe",
        category: "HIDBroker"
    )

    static func makeListener(at path: String) throws -> Int32 {
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
            // A full Unix-domain socket backlog can report ECONNREFUSED to clients. Use the
            // platform maximum to absorb command bursts; the lifetime lock below remains the
            // authoritative signal when the backlog is nevertheless exhausted.
            guard listen(descriptor, SOMAXCONN) == 0 else { throw posixError("listen") }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func connectAndAwaitHandshake(
        endpoint: String,
        connector: (String) throws -> Int32,
        timeoutMilliseconds: Int = serverIOTimeoutMilliseconds
    ) throws -> Int32 {
        let descriptor = try connector(endpoint)
        do {
            try configureReceiveTimeout(descriptor, milliseconds: timeoutMilliseconds)
            let data = try readMessage(from: descriptor)
            let handshake = try JSONDecoder().decode(HIDBrokerHandshake.self, from: data)
            guard handshake.ready else { throw HIDBrokerNotReadyError() }
            try configureReceiveTimeout(descriptor, milliseconds: clientResponseTimeoutMilliseconds)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            if let notReady = error as? HIDBrokerNotReadyError {
                throw notReady
            }
            throw HIDBrokerNotReadyError(
                diagnosticDescription: "The broker readiness handshake failed: \(error.localizedDescription)",
                isSafeToReplaceBroker: false,
                allowsReplacementAfterProcessExit: true
            )
        }
    }

    static func acquireStartupLock(
        endpoint: String,
        deadline: UInt64,
        monotonicNow: () -> UInt64,
        sleeper: (useconds_t) -> Void
    ) throws -> Int32 {
        let path = endpoint + ".lock"
        while monotonicNow() < deadline {
            do {
                return try acquirePrivateLock(path: path, operation: "startup lock", nonblocking: true)
            } catch let error as NSError
                where error.domain == NSPOSIXErrorDomain && error.code == Int(EWOULDBLOCK) {
                sleeper(100_000)
            }
        }
        throw HIDBrokerNotReadyError(
            diagnosticDescription: "Timed out waiting for another client to finish starting the broker.",
            isSafeToReplaceBroker: false
        )
    }

    static func acquireLifetimeLock(endpoint: String) throws -> Int32 {
        try acquirePrivateLock(path: lifetimeLockPath(endpoint), operation: "lifetime lock", nonblocking: true)
    }

    static func isBrokerProcessAlive(endpoint: String) throws -> Bool {
        let descriptor: Int32
        do {
            descriptor = try acquireLifetimeLock(endpoint: endpoint)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EWOULDBLOCK) {
            return true
        }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        return false
    }

    private static func lifetimeLockPath(_ endpoint: String) -> String {
        endpoint + ".lifetime.lock"
    }

    private static func acquirePrivateLock(
        path: String,
        operation: String,
        nonblocking: Bool
    ) throws -> Int32 {
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("open " + operation) }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw posixError("fstat " + operation) }
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(),
                  info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
                throw CLIError(errorDescription: "HID broker " + operation + " is not a private owned file.")
            }
            let lockOperation = nonblocking ? LOCK_EX | LOCK_NB : LOCK_EX
            while flock(descriptor, lockOperation) != 0 {
                guard errno == EINTR else { throw posixError("lock " + operation) }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func isBrokerUnavailable(_ error: Error) -> Bool {
        if error is HIDBrokerNotReadyError {
            return true
        }
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

    static func waitForStaleEndpointShutdown(_ path: String) throws {
        try waitForStaleEndpointShutdown(
            path,
            connector: connect(to:),
            sleeper: { _ = usleep($0) },
            brokerIsAlive: { try isBrokerProcessAlive(endpoint: path) }
        )
    }

    static func waitForStaleEndpointShutdown(
        _ path: String,
        deadline: UInt64,
        monotonicNow: () -> UInt64,
        sleeper: (useconds_t) -> Void
    ) throws {
        try waitForStaleEndpointShutdown(
            path,
            connector: connect(to:),
            sleeper: sleeper,
            brokerIsAlive: { try isBrokerProcessAlive(endpoint: path) },
            shouldContinue: { monotonicNow() < deadline }
        )
    }

    static func waitForStaleEndpointShutdown(
        _ path: String,
        connector: (String) throws -> Int32,
        sleeper: (useconds_t) -> Void,
        brokerIsAlive: () throws -> Bool = { false },
        shouldContinue: () -> Bool = { true }
    ) throws {
        for _ in 0..<startupAttempts {
            guard shouldContinue() else {
                throw HIDBrokerNotReadyError(
                    diagnosticDescription: "Timed out waiting for the stale broker to exit.",
                    isSafeToReplaceBroker: false
                )
            }
            do {
                let descriptor = try connector(path)
                Darwin.close(descriptor)
                sleeper(100_000)
            } catch {
                let error = error as NSError
                guard error.domain == NSPOSIXErrorDomain,
                      error.code == Int(ECONNREFUSED) || error.code == Int(ENOENT) else {
                    throw error
                }
                if try brokerIsAlive() {
                    sleeper(100_000)
                    continue
                }
                try removeOwnedSocket(path)
                return
            }
        }
        throw CLIError(errorDescription: "The stale HID broker did not shut down.")
    }

    static func socketIdentity(at path: String) throws -> HIDBrokerSocketIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw posixError("lstat") }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            throw CLIError(errorDescription: "Refusing to remove an unowned HID broker endpoint.")
        }
        return HIDBrokerSocketIdentity(device: info.st_dev, inode: info.st_ino)
    }

    static func removeOwnedSocket(
        _ path: String,
        matching expectedIdentity: HIDBrokerSocketIdentity? = nil
    ) throws {
        do {
            let identity = try socketIdentity(at: path)
            if let expectedIdentity, identity != expectedIdentity {
                return
            }
        } catch {
            if (error as NSError).domain == NSPOSIXErrorDomain,
               (error as NSError).code == Int(ENOENT) {
                return
            }
            throw error
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

    static func writeResponse(error: String?, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(HIDBrokerResponse(error: error))
        data.append(0x0A)
        try writeAll(data, to: descriptor)
    }

    static func writeHandshake(ready: Bool, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(HIDBrokerHandshake(ready: ready))
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

    static func configureNoSignalPipe(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    static func configureSocketTimeouts(
        _ descriptor: Int32,
        readMilliseconds: Int,
        writeMilliseconds: Int
    ) throws {
        try configureReceiveTimeout(descriptor, milliseconds: readMilliseconds)

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

    private static func configureReceiveTimeout(_ descriptor: Int32, milliseconds: Int) throws {
        var readTimeout = socketTimeout(milliseconds: max(1, milliseconds))
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &readTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw posixError("setsockopt(SO_RCVTIMEO)")
        }
    }

    static func monotonicTimeNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func logDiagnostic(_ error: Error) {
        guard let notReady = error as? HIDBrokerNotReadyError else { return }
        diagnosticLogger.debug("\(notReady.diagnosticDescription, privacy: .public)")
    }

    static func posixError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "HID broker \(operation) failed: \(String(cString: strerror(errno)))"
        ])
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

    static func connect(to path: String) throws -> Int32 {
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

    private static func socketTimeout(milliseconds: Int) -> timeval {
        timeval(
            tv_sec: milliseconds / 1_000,
            tv_usec: Int32((milliseconds % 1_000) * 1_000)
        )
    }
}
