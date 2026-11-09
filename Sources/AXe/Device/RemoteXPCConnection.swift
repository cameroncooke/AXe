import Darwin
import Foundation

/// One point-to-point RemoteXPC connection. Its caller owns and serializes all I/O.
final class RemoteXPCConnection {
    private let socket: DeviceTCPSocket
    private var nextMessageID: UInt64 = 1
    private var sendConnectionWindow = 65_535
    private var initialSendStreamWindow = 65_535
    private var sendStreamWindow = 65_535
    private var buffers: [UInt32: Data] = [:]
    private var connectionCredit: UInt32 = 0
    private var streamCredit: [UInt32: UInt32] = [:]
    private static let flowUpdateThreshold: UInt32 = 4 * 1024 * 1024
    private static let initialWindow: UInt32 = 16 * 1024 * 1024

    init(tunnel: DeviceTunnelAddress, port: UInt16, timeout: TimeInterval) throws {
        socket = try DeviceTCPSocket(address: tunnel.socketAddress(port: port), timeout: timeout)
        try start()
    }

    func readServiceDirectory(expectedUDID: String) throws -> [String: RemoteXPCValue] {
        while true {
            let (stream, message) = try nextMessage()
            guard stream == 1, let body = message.body?.dictionaryValue,
                body["MessageType"]?.stringValue == "Handshake"
            else { continue }

            guard let udid = body["Properties"]?.dictionaryValue?["UniqueDeviceID"]?.stringValue,
                let services = body["Services"]?.dictionaryValue
            else {
                throw DeviceServiceError.invalidProtocol("the directory omitted device or service details")
            }
            guard udid.caseInsensitiveCompare(expectedUDID) == .orderedSame else {
                throw DeviceServiceError.targetMismatch
            }
            return services
        }
    }

    func request(_ body: [String: RemoteXPCValue], timeout: TimeInterval? = nil) throws -> [String: RemoteXPCValue] {
        if let timeout { socket.renewDeadline(after: timeout) }
        let messageID = try send(body, expectsReply: true)
        while true {
            let (stream, reply) = try nextMessage()
            guard stream == 3, reply.flags & 0x20000 != 0 else { continue }
            guard reply.messageID == messageID, let body = reply.body?.dictionaryValue else {
                throw DeviceServiceError.invalidProtocol("the reply did not match the service request")
            }
            return body
        }
    }

    func sendEvent(_ body: [String: RemoteXPCValue]) throws {
        socket.renewDeadline(after: 2)
        _ = try send(body, expectsReply: false)
    }

    /// A PING ACK establishes that the peer consumed the preceding HTTP/2 frames.
    /// It does not acknowledge guest input.
    func drainEvents() throws {
        socket.renewDeadline(after: 2)
        let nonce = bigEndianBytes(UInt32.random(in: .min ... .max))
            + bigEndianBytes(UInt32.random(in: .min ... .max))
        try write(.ping, payload: nonce)
        while true {
            let frame = try readFrame()
            if frame.type == .ping, frame.stream == 0, frame.flags == 0x1, frame.payload == nonce {
                return
            }
            try handle(frame)
        }
    }

    private func send(_ body: [String: RemoteXPCValue], expectsReply: Bool) throws -> UInt64 {
        let id = nextMessageID
        nextMessageID += 1
        let flags: UInt32 = expectsReply ? 0x10101 : 0x101
        let payload = try RemoteXPCMessage(flags: flags, messageID: id, body: .dictionary(body)).encode()
        while sendConnectionWindow < payload.count || sendStreamWindow < payload.count {
            try handle(readFrame())
        }
        try write(.data, stream: 1, payload: payload)
        sendConnectionWindow -= payload.count
        sendStreamWindow -= payload.count
        return id
    }

    private func start() throws {
        var handshake = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        var settings = Data([0, 3])
        settings.append(bigEndianBytes(100))
        settings.append(contentsOf: [0, 4])
        settings.append(bigEndianBytes(Self.initialWindow))
        handshake.append(Frame(type: .settings, payload: settings).encode())
        handshake.append(Frame(type: .windowUpdate, payload: bigEndianBytes(Self.initialWindow - 65_535)).encode())
        handshake.append(Frame(type: .headers, flags: 0x4, stream: 1).encode())
        handshake.append(try handshakeData(flags: 0x1, stream: 1, body: .dictionary([:])))
        handshake.append(Frame(type: .headers, flags: 0x4, stream: 3).encode())
        handshake.append(try handshakeData(flags: 0x201, stream: 1, body: nil))
        handshake.append(try handshakeData(flags: 0x400001, stream: 3, body: nil))
        // The opening DATA on streams 1 and 3 uses 92 bytes of connection credit.
        sendConnectionWindow -= 92
        sendStreamWindow -= 68
        try socket.write(handshake)

        let firstFrame = try readFrame()
        guard firstFrame.type == .settings, firstFrame.flags & 0x1 == 0 else {
            throw DeviceServiceError.invalidProtocol("the peer did not start with HTTP/2 SETTINGS")
        }
        try handle(firstFrame)
    }

    private func handshakeData(flags: UInt32, stream: UInt32, body: RemoteXPCValue?) throws -> Data {
        let message = RemoteXPCMessage(flags: flags, messageID: 0, body: body)
        return Frame(type: .data, stream: stream, payload: try message.encode()).encode()
    }

    private func nextMessage() throws -> (UInt32, RemoteXPCMessage) {
        while true {
            for stream: UInt32 in [1, 3] {
                guard let buffer = buffers[stream], !buffer.isEmpty else { continue }
                let decoded: (message: RemoteXPCMessage, bytesConsumed: Int)?
                do {
                    decoded = try RemoteXPCMessage.decodePrefix(buffer)
                } catch {
                    throw DeviceServiceError.invalidProtocol(error.localizedDescription)
                }
                if let decoded {
                    buffers[stream] = Data(buffer.dropFirst(decoded.bytesConsumed))
                    return (stream, decoded.message)
                }
            }
            try handle(readFrame())
        }
    }

    private func readFrame() throws -> Frame {
        let header = try socket.read(count: 9)
        let length = (Int(header[0]) << 16) | (Int(header[1]) << 8) | Int(header[2])
        guard length <= 16_384 else {
            throw DeviceServiceError.invalidProtocol("an HTTP/2 frame exceeded the default frame size")
        }
        let stream = header[5...8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fff_ffff
        return Frame(
            type: FrameType(rawValue: header[3]),
            flags: header[4],
            stream: stream,
            payload: try socket.read(count: length)
        )
    }

    private func handle(_ frame: Frame) throws {
        switch frame.type {
        case .settings:
            guard frame.stream == 0, frame.payload.count.isMultiple(of: 6),
                frame.flags & 0x1 == 0 || frame.payload.isEmpty
            else {
                throw DeviceServiceError.invalidProtocol("invalid HTTP/2 SETTINGS")
            }
            if frame.flags & 0x1 == 0 {
                for offset in stride(from: 0, to: frame.payload.count, by: 6) {
                    let setting = (Int(frame.payload[offset]) << 8) | Int(frame.payload[offset + 1])
                    if setting == 4 {
                        let size = frame.payload[(offset + 2)..<(offset + 6)].reduce(0) { ($0 << 8) | Int($1) }
                        guard size <= 0x7fff_ffff else {
                            throw DeviceServiceError.invalidProtocol("invalid HTTP/2 initial window size")
                        }
                        sendStreamWindow += size - initialSendStreamWindow
                        initialSendStreamWindow = size
                    }
                }
                try write(.settings, flags: 0x1)
            }
        case .ping:
            guard frame.stream == 0, frame.payload.count == 8 else {
                throw DeviceServiceError.invalidProtocol("invalid HTTP/2 PING")
            }
            if frame.flags & 0x1 == 0 {
                try write(.ping, flags: 0x1, payload: frame.payload)
            }
        case .data:
            guard frame.stream == 1 || frame.stream == 3 else {
                throw DeviceServiceError.invalidProtocol("unexpected RemoteXPC stream")
            }
            var payload = frame.payload
            if frame.flags & 0x8 != 0 {
                guard let padding = payload.first, Int(padding) < payload.count else {
                    throw DeviceServiceError.invalidProtocol("invalid HTTP/2 DATA padding")
                }
                payload = Data(payload.dropFirst().dropLast(Int(padding)))
            }
            buffers[frame.stream, default: Data()].append(payload)
            try returnFlowCredit(for: frame)
        case .goAway, .resetStream:
            throw DeviceServiceError.connectionFailed("the peer closed its HTTP/2 connection or stream")
        case .windowUpdate:
            guard frame.payload.count == 4 else {
                throw DeviceServiceError.invalidProtocol("invalid HTTP/2 WINDOW_UPDATE")
            }
            let increment = frame.payload.reduce(0) { ($0 << 8) | Int($1) } & 0x7fff_ffff
            switch frame.stream {
            case 0: sendConnectionWindow += increment
            case 1: sendStreamWindow += increment
            default: break
            }
            guard increment > 0, sendConnectionWindow <= 0x7fff_ffff, sendStreamWindow <= 0x7fff_ffff else {
                throw DeviceServiceError.invalidProtocol("invalid HTTP/2 window increment")
            }
        case .headers, nil:
            break
        }
    }

    private func returnFlowCredit(for frame: Frame) throws {
        let count = UInt32(frame.payload.count)
        connectionCredit += count
        let credit = streamCredit[frame.stream, default: 0] + count
        if connectionCredit >= Self.flowUpdateThreshold {
            try write(.windowUpdate, payload: bigEndianBytes(connectionCredit))
            connectionCredit = 0
        }
        if credit >= Self.flowUpdateThreshold {
            try write(.windowUpdate, stream: frame.stream, payload: bigEndianBytes(credit))
            streamCredit[frame.stream] = 0
        } else {
            streamCredit[frame.stream] = credit
        }
    }

    private func write(
        _ type: FrameType,
        flags: UInt8 = 0,
        stream: UInt32 = 0,
        payload: Data = Data()
    ) throws {
        guard payload.count <= 16_384 else {
            throw DeviceServiceError.invalidProtocol("the outgoing HTTP/2 frame is too large")
        }
        try socket.write(Frame(type: type, flags: flags, stream: stream, payload: payload).encode())
    }

    private enum FrameType: UInt8 {
        case data = 0
        case headers = 1
        case resetStream = 3
        case settings = 4
        case ping = 6
        case goAway = 7
        case windowUpdate = 8
    }

    private struct Frame {
        let type: FrameType?
        var flags: UInt8 = 0
        var stream: UInt32 = 0
        var payload = Data()

        func encode() -> Data {
            let length = payload.count
            var bytes = Data([
                UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8),
                UInt8(truncatingIfNeeded: length),
                type?.rawValue ?? 0,
                flags,
            ])
            bytes.append(bigEndianBytes(stream))
            bytes.append(payload)
            return bytes
        }
    }
}

private func bigEndianBytes(_ number: UInt32) -> Data {
    withUnsafeBytes(of: number.bigEndian) { Data($0) }
}

/// Nonblocking file descriptor with a shared deadline for connection, reads, and writes.
final class DeviceTCPSocket {
    private let fd: Int32
    private var deadline: DispatchTime

    init(address: sockaddr_in6, timeout: TimeInterval) throws {
        let socket = Darwin.socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else { throw Self.socketError(errno) }

        let deadline = DispatchTime.now() + timeout
        do {
            try Self.connect(socket, address: address, deadline: deadline)
        } catch {
            Darwin.close(socket)
            throw error
        }
        fd = socket
        self.deadline = deadline
    }

    deinit {
        Darwin.close(fd)
    }

    func renewDeadline(after timeout: TimeInterval) {
        deadline = DispatchTime.now() + timeout
    }

    func isReadable(for timeout: TimeInterval) throws -> Bool {
        do {
            try Self.wait(fd, for: Int16(POLLIN), deadline: DispatchTime.now() + timeout)
            return true
        } catch DeviceServiceError.timeout {
            return false
        }
    }

    func finishWrites() {
        _ = shutdown(fd, SHUT_WR)
    }

    func read(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try Self.wait(fd, for: Int16(POLLIN), deadline: deadline)
                let received = recv(fd, base.advanced(by: offset), buffer.count - offset, 0)
                if received > 0 {
                    offset += received
                } else if received == 0 {
                    throw DeviceServiceError.connectionFailed("the peer closed the connection")
                } else {
                    let code = errno
                    guard code == EINTR || code == EAGAIN || code == EWOULDBLOCK else {
                        throw Self.socketError(code)
                    }
                }
            }
        }
        return data
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try Self.wait(fd, for: Int16(POLLOUT), deadline: deadline)
                let sent = send(fd, base.advanced(by: offset), buffer.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent == 0 {
                    throw DeviceServiceError.connectionFailed("the peer closed the connection")
                } else {
                    let code = errno
                    guard code == EINTR || code == EAGAIN || code == EWOULDBLOCK else {
                        throw Self.socketError(code)
                    }
                }
            }
        }
    }

    private static func connect(_ fd: Int32, address: sockaddr_in6, deadline: DispatchTime) throws {
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw socketError(errno)
        }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw socketError(errno)
        }

        var address = address
        let length = socklen_t(address.sin6_len)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result != 0 else { return }

        let code = errno
        guard code == EINPROGRESS || code == EINTR else { throw socketError(code) }
        try wait(fd, for: Int16(POLLOUT), deadline: deadline)
        var error: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorLength) == 0 else {
            throw socketError(errno)
        }
        guard error == 0 else { throw socketError(error) }
    }

    private static func wait(_ fd: Int32, for events: Int16, deadline: DispatchTime) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw DeviceServiceError.timeout }
            let remaining = deadline.uptimeNanoseconds - now
            let result = poll(&descriptor, 1, Int32((remaining + 999_999) / 1_000_000))
            if result > 0 {
                // POLLHUP and POLLERR are reported by the next socket operation.
                return
            }
            if result == 0 {
                throw DeviceServiceError.timeout
            }
            let code = errno
            guard code == EINTR else { throw socketError(code) }
        }
    }

    private static func socketError(_ code: Int32) -> DeviceServiceError {
        let reason = POSIXErrorCode(rawValue: code).map { POSIXError($0).localizedDescription }
        return .connectionFailed(reason ?? "socket error \(code)")
    }
}
