import Darwin
import Dispatch
import Foundation

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
