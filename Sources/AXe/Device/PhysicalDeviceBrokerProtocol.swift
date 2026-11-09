import Darwin
import Dispatch
import Foundation

enum PhysicalDeviceBrokerOperation: Codable, Sendable {
    case display
    case keepAlive
    case touch([PhysicalTouchStep], display: PhysicalDeviceDisplay?, allowPartial: Bool, deadlineUptime: UInt64?)
    case keys([PhysicalKeyStep])
    case button(PhysicalDeviceButton, hold: Double, allowLock: Bool)
    case rotate(PhysicalRotationDirection, timeout: Double)
    case tree(timeout: Double)
    case semanticPress(identifier: String)

    var sendsInput: Bool {
        switch self {
        case .display, .tree, .keepAlive: false
        case .touch, .keys, .button, .rotate, .semanticPress: true
        }
    }

    var timeoutMilliseconds: Int {
        guard case let .keys(steps) = self else { return PhysicalDeviceBrokerProtocol.operationTimeoutMilliseconds }
        let delay = steps.reduce(0) { $0 + $1.delayAfter }
        guard delay.isFinite, delay >= 0, delay <= 600 else {
            return PhysicalDeviceBrokerProtocol.operationTimeoutMilliseconds
        }
        return max(PhysicalDeviceBrokerProtocol.operationTimeoutMilliseconds, Int(ceil(delay * 1000)) + 30_000)
    }

    func validate() throws {
        let duration: Double
        switch self {
        case let .touch(steps, _, _, _):
            guard (1...8_192).contains(steps.count) else { throw Self.invalidOperation }
            duration = steps.reduce(0) { $0 + $1.delayAfter }
        case let .keys(steps):
            guard (1...8_192).contains(steps.count) else { throw Self.invalidOperation }
            let delay = steps.reduce(0) { $0 + $1.delayAfter }
            guard delay.isFinite, (0...600).contains(delay) else { throw Self.invalidOperation }
            return
        case let .button(button, hold, allowLock):
            guard button != .lock || allowLock else {
                throw AutomationTarget.unsupportedOnDevice("Physical lock requires --allow-lock.")
            }
            duration = hold
        case let .rotate(_, timeout), let .tree(timeout):
            duration = timeout
        case let .semanticPress(identifier):
            guard !identifier.isEmpty, identifier.utf8.count <= 4_096 else { throw Self.invalidOperation }
            duration = 0
        case .display, .keepAlive:
            duration = 0
        }
        guard duration.isFinite, (0...60).contains(duration) else { throw Self.invalidOperation }
    }

    private static var invalidOperation: CLIOutputFailure {
        CLIOutputFailure(code: "invalidArguments", message: "The device broker operation exceeds its input limits.")
    }
}

enum PhysicalDeviceBrokerValue: Codable, Sendable {
    case done
    case display(PhysicalDeviceDisplay)
    case tree(Data, display: PhysicalDeviceDisplay)
    case semanticPress(PhysicalSemanticPressReceipt)
}

/// The worker retains device connections across leases. End releases all input owned by the lease.
protocol PhysicalDeviceBrokerBackend: Sendable {
    func begin() async throws
    func execute(_ operation: PhysicalDeviceBrokerOperation) async throws -> PhysicalDeviceBrokerValue
    func end() async throws
    func shutdown() async
}

enum PhysicalDeviceBrokerProtocol {
    static let version = 1
    static let commandName = "physical-device-broker"
    static let maximumFrameBytes = 16 * 1024 * 1024
    static let frameTimeoutMilliseconds = 3_000
    static let operationTimeoutMilliseconds = 90_000
    static let closeTimeoutMilliseconds = 20_000
    static let leaseIdleMilliseconds = 60_000

    static func endpoint(udid: String) throws -> String {
        try HIDBroker.endpointPath(simulatorUDID: udid.uppercased(),
            developerDirectory: "/physical-device-broker", version: version)
    }

    static var busy: CLIOutputFailure {
        CLIOutputFailure(code: "deviceBusy", message: "Another AXe command owns this physical device.")
    }

    static var unavailable: CLIOutputFailure {
        CLIOutputFailure(code: "deviceBrokerUnavailable", message: "The physical device broker connection is unavailable.")
    }

    static var mismatch: CLIOutputFailure {
        CLIOutputFailure(code: "deviceBrokerMismatch",
            message: "A different AXe build owns the physical device broker. Wait for it to exit before trying again.")
    }

    static var outcomeUnknown: CLIOutputFailure {
        CLIOutputFailure(code: "inputOutcomeUnknown",
            message: "AXe could not confirm the result of the device input request. Check the device before sending more input.")
    }

    struct BuildIdentity: Codable, Equatable, Sendable {
        let executable: String
        let device: Int32
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        static func current() throws -> Self {
            guard let url = Bundle.main.executableURL else { throw unavailable }
            let executable = url.resolvingSymlinksInPath().path
            var info = stat()
            guard lstat(executable, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw unavailable }
            return Self(executable: executable, device: info.st_dev, inode: info.st_ino,
                bytes: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec,
                modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        }
    }

    struct Hello: Codable, Sendable {
        let version: Int
        let workerPID: Int32
        let build: BuildIdentity
        let udid: String
        let failure: Failure?
    }

    enum Request: Codable, Sendable {
        case open
        case operation(UUID, PhysicalDeviceBrokerOperation)
        case close
    }

    enum Response: Codable, Sendable {
        case opened(Failure?)
        case value(UUID, PhysicalDeviceBrokerValue)
        case failed(UUID, Failure)
        case closed(Failure?)
    }

    struct Failure: Codable, Sendable {
        let code: String
        let message: String

        init(_ error: Error) {
            if let failure = error as? CLIOutputFailure {
                code = failure.code
                message = String(failure.message.prefix(1_024))
            } else if error is CancellationError {
                code = "deviceOperationInterrupted"
                message = "The device operation was interrupted."
            } else {
                code = "deviceOperationFailed"
                let detail = (error as? UserFacingError)?.userFacingDescription ?? error.localizedDescription
                message = String(detail.prefix(1_024))
            }
        }

        var error: CLIOutputFailure {
            CLIOutputFailure(code: code, message: message)
        }
    }
}

private enum PhysicalDeviceBrokerSocketError: Error {
    case timeout, connectionClosed, invalidFrame
}

/// Owns one socket descriptor. A cancellation shuts it down but leaves close to the last owner.
final class PhysicalDeviceBrokerSocket: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "axe.physical-broker.io", attributes: .concurrent)
    let descriptor: Int32

    init(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(descriptor)
            throw PhysicalDeviceBrokerProtocol.unavailable
        }
        self.descriptor = descriptor
        HIDBroker.configureNoSignalPipe(descriptor)
    }

    deinit { Darwin.close(descriptor) }

    func interrupt() {
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    func verifiedPeerPID(executable: String) throws -> Int32 {
        var uid = uid_t.max
        var gid = gid_t.max
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else {
            throw PhysicalDeviceBrokerProtocol.mismatch
        }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size, pid > 0 else {
            throw PhysicalDeviceBrokerProtocol.mismatch
        }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            throw PhysicalDeviceBrokerProtocol.mismatch
        }
        let peer = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        guard peer == executable else { throw PhysicalDeviceBrokerProtocol.mismatch }
        return pid
    }

    static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    func read<T: Decodable>(_ type: T.Type, timeoutMilliseconds: Int) throws -> T {
        let deadline = Self.deadline(timeoutMilliseconds)
        let header = try readBytes(4, deadline: deadline)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...PhysicalDeviceBrokerProtocol.maximumFrameBytes).contains(length) else {
            throw PhysicalDeviceBrokerSocketError.invalidFrame
        }
        return try JSONDecoder().decode(type, from: readBytes(length, deadline: deadline))
    }

    static func packet(_ value: some Encodable) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard (1...PhysicalDeviceBrokerProtocol.maximumFrameBytes).contains(payload.count) else {
            throw PhysicalDeviceBrokerSocketError.invalidFrame
        }
        var length = UInt32(payload.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(payload)
        return packet
    }

    func write(_ packet: Data, timeoutMilliseconds: Int = PhysicalDeviceBrokerProtocol.frameTimeoutMilliseconds) throws {
        let deadline = Self.deadline(timeoutMilliseconds)
        try packet.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(for: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.send(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
                if count > 0 {
                    offset += count
                } else if count == 0 || ![EINTR, EAGAIN, EWOULDBLOCK].contains(errno) {
                    throw PhysicalDeviceBrokerSocketError.connectionClosed
                }
            }
        }
    }

    /// While the worker executes a request, any incoming byte or EOF ends the sequential lease.
    func peerIsWaiting(milliseconds: Int32) -> Bool {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let count = Darwin.poll(&event, 1, milliseconds)
        return count == 0 || (count < 0 && errno == EINTR)
    }

    private static func deadline(_ milliseconds: Int) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000
    }

    private func readBytes(_ length: Int, deadline: UInt64) throws -> Data {
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(for: Int16(POLLIN), deadline: deadline)
                let count = Darwin.recv(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
                if count > 0 {
                    offset += count
                } else if count == 0 || ![EINTR, EAGAIN, EWOULDBLOCK].contains(errno) {
                    throw PhysicalDeviceBrokerSocketError.connectionClosed
                }
            }
        }
        return data
    }

    private func wait(for events: Int16, deadline: UInt64) throws {
        var event = pollfd(fd: descriptor, events: events, revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw PhysicalDeviceBrokerSocketError.timeout }
            let milliseconds = max(1, Int32((deadline - now + 999_999) / 1_000_000))
            let count = Darwin.poll(&event, 1, milliseconds)
            if count > 0 { return }
            if count == 0 { throw PhysicalDeviceBrokerSocketError.timeout }
            guard errno == EINTR else { throw PhysicalDeviceBrokerSocketError.connectionClosed }
        }
    }
}
