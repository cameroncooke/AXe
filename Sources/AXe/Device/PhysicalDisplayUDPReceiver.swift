import Darwin
import Foundation

/// Receives only datagrams from the negotiated tunnel endpoint.
final class PhysicalDisplayUDPReceiver: @unchecked Sendable {
    let receiverIP: String
    let senderIP: String
    let receiverPort: UInt16

    private let remote: sockaddr_in6
    private let queue = DispatchQueue(label: "axe.device-display-udp")
    private let lock = NSLock()
    private var stopping = false
    // The receiver queue owns the descriptor once the socket has bound.
    private var descriptor: Int32
    private var reports: PhysicalDisplayRTCP?

    init(tunnelAddress: String) throws {
        remote = try DeviceTunnelAddress(tunnelAddress).socketAddress(port: 1)
        senderIP = try Self.addressString(remote)
        var local = try Self.localAddress(for: remote)
        receiverIP = try Self.addressString(local)
        local.sin6_port = 0

        let fd = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Self.failure(errno) }
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                throw Self.failure(errno)
            }
            var bufferSize: Int32 = 1_048_576
            guard setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw Self.failure(errno)
            }
            let result = withUnsafePointer(to: local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard result == 0 else { throw Self.failure(errno) }
            let actual = try Self.boundAddress(of: fd)
            guard actual.sin6_port != 0 else { throw DeviceServiceError.invalidProtocol("the UDP receiver has no port") }
            receiverPort = UInt16(bigEndian: actual.sin6_port)
            descriptor = fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func enableReceiverReports(_ reports: PhysicalDisplayRTCP) {
        queue.sync { self.reports = reports }
    }

    func receive(senderPort: UInt16, timeout: TimeInterval) async throws -> Data {
        let deadline = DispatchTime.now() + timeout
        let cancellation = ReceiveCancellation()
        try Task.checkCancellation()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try self.receive(senderPort: senderPort, deadline: deadline, cancellation: cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return data
    }

    func close() {
        lock.withLock { stopping = true }
        queue.sync {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
        }
    }

    func matchesSender(_ value: String) -> Bool {
        guard let address = try? DeviceTunnelAddress(value).socketAddress(port: 1) else { return false }
        return Self.sameAddress(address, remote)
    }

    func matchesReceiver(_ value: String) -> Bool {
        guard let address = try? DeviceTunnelAddress(value).socketAddress(port: 1),
              let local = try? DeviceTunnelAddress(receiverIP).socketAddress(port: 1) else { return false }
        return Self.sameAddress(address, local)
    }

    private func receive(senderPort: UInt16, deadline: DispatchTime,
                         cancellation: ReceiveCancellation) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if cancellation.isCancelled || lock.withLock({ stopping }) { throw CancellationError() }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw DeviceServiceError.timeout }
            if let report = reports?.reportIfDue(at: .now) {
                try send(report, senderPort: senderPort)
            }
            let remaining = deadline.uptimeNanoseconds - now
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let count = poll(&ready, 1, Int32(min(100, (remaining + 999_999) / 1_000_000)))
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.failure(errno)
            }
            if count == 0 { continue }

            var peer = sockaddr_in6()
            var peerSize = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let received = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &buffer, buffer.count, 0, $0, &peerSize)
                }
            }
            if received < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw Self.failure(errno)
            }
            guard peerSize == socklen_t(MemoryLayout<sockaddr_in6>.size),
                  peer.sin6_family == sa_family_t(AF_INET6),
                  UInt16(bigEndian: peer.sin6_port) == senderPort,
                  Self.sameAddress(peer, remote) else { continue }
            let datagram = Data(buffer.prefix(received))
            try reports?.observe(datagram, at: .now)
            return datagram
        }
    }

    private func send(_ report: Data, senderPort: UInt16) throws {
        var endpoint = remote
        endpoint.sin6_port = senderPort.bigEndian
        let sent = report.withUnsafeBytes { bytes in
            withUnsafePointer(to: endpoint) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        if sent == report.count { return }
        if sent < 0 {
            // A transient UDP send failure drops this report. The next interval
            // emits another bounded report without retrying a queued datagram.
            if errno == EAGAIN || errno == EINTR || errno == ENOBUFS { return }
            throw Self.failure(errno)
        }
        throw DeviceServiceError.connectionFailed("the RTCP receiver report was incomplete")
    }

    private static func localAddress(for remote: sockaddr_in6) throws -> sockaddr_in6 {
        let fd = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw failure(errno) }
        defer { Darwin.close(fd) }

        // Connecting a UDP socket selects the tunnel route without sending a packet.
        let result = withUnsafePointer(to: remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard result == 0 else { throw failure(errno) }
        return try boundAddress(of: fd)
    }

    private static func boundAddress(of fd: Int32) throws -> sockaddr_in6 {
        var address = sockaddr_in6()
        var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard result == 0, address.sin6_family == sa_family_t(AF_INET6) else { throw failure(errno) }
        return address
    }

    private static func sameAddress(_ first: sockaddr_in6, _ second: sockaddr_in6) -> Bool {
        withUnsafeBytes(of: first.sin6_addr) { a in
            withUnsafeBytes(of: second.sin6_addr) { b in a.elementsEqual(b) }
        }
    }

    private static func addressString(_ address: sockaddr_in6) throws -> String {
        var binary = address.sin6_addr
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &binary, &text, socklen_t(text.count)) != nil else { throw failure(errno) }
        return String(cString: text)
    }

    private final class ReceiveCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            lock.withLock { cancelled = true }
        }
    }

    private static func failure(_ code: Int32) -> DeviceServiceError {
        let detail = POSIXErrorCode(rawValue: code).map { POSIXError($0).localizedDescription }
        return .connectionFailed(detail ?? "display UDP socket error \(code)")
    }
}
