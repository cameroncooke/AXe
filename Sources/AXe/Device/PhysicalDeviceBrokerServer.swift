import ArgumentParser
import Darwin
import Dispatch
import Foundation

struct PhysicalDeviceBrokerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: PhysicalDeviceBrokerProtocol.commandName,
        shouldDisplay: false
    )

    @Option var udid: String

    @MainActor
    func run() async throws {
        // Listen before resolving the device, so a missing device reaches the client as `targetNotFound`.
        guard AutomationTarget.isPhysicalInputUDID(udid) else { throw PhysicalDeviceBrokerProtocol.unavailable }
        try await PhysicalDeviceBrokerServer.serve(udid: udid, backend: PhysicalDeviceBrokerOwner(udid: udid))
    }
}

@MainActor
private enum PhysicalDeviceBrokerServer {
    private typealias Wire = PhysicalDeviceBrokerProtocol

    static func serve(udid: String, backend: PhysicalDeviceBrokerOwner) async throws {
        let task = Task { @MainActor in try await listen(udid: udid, backend: backend) }
        let signals = SignalObserver(signals: [SIGINT, SIGTERM]) { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        signals.invalidate()
        try result.get()
    }

    private static func listen(udid: String, backend: PhysicalDeviceBrokerOwner) async throws {
        let endpoint = try Wire.endpoint(udid: udid)
        let build = try Wire.BuildIdentity.current()
        let lifetime = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        defer {
            _ = flock(lifetime, LOCK_UN)
            Darwin.close(lifetime)
        }
        try HIDBroker.removeOwnedSocket(endpoint)
        let listener = try PhysicalDeviceBrokerSocket(HIDBroker.makeListener(at: endpoint))
        let identity = try HIDBroker.socketIdentity(at: endpoint)
        defer { try? HIDBroker.removeOwnedSocket(endpoint, matching: identity) }

        var lastActivity = DispatchTime.now().uptimeNanoseconds
        var active: Task<Void, Never>?
        var reusable = true
        let result: Result<Void, Error>
        do {
            while !Task.isCancelled, reusable {
                let idle = DispatchTime.now().uptimeNanoseconds - lastActivity
                if active == nil, idle >= UInt64(Wire.leaseIdleMilliseconds) * 1_000_000 { break }
                guard let descriptor = try await PhysicalDeviceBrokerSocket.offMain({
                    try acceptClient(listener.descriptor)
                }) else { continue }
                guard let socket = try? PhysicalDeviceBrokerSocket(descriptor),
                      (try? socket.verifiedPeerPID(executable: build.executable)) != nil else { continue }
                guard !Task.isCancelled, reusable else { break }
                let hello = Wire.Hello(version: Wire.version, workerPID: getpid(), build: build, udid: udid,
                    failure: active == nil ? nil : Wire.Failure(Wire.busy))
                if active != nil {
                    try? await write(hello, to: socket)
                    continue
                }
                active = Task { @MainActor in
                    reusable = await serveClient(socket, hello: hello, backend: backend)
                    lastActivity = DispatchTime.now().uptimeNanoseconds
                    active = nil
                }
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }

        // Join the lease and release owned input before closing persistent device connections.
        active?.cancel()
        if let active { await active.value }
        await backend.shutdown()
        try result.get()
    }

    private static func serveClient(_ socket: PhysicalDeviceBrokerSocket, hello: Wire.Hello,
                                    backend: PhysicalDeviceBrokerOwner) async -> Bool {
        var began = false
        do {
            try await write(hello, to: socket)
            let open = try await read(from: socket, timeout: Wire.frameTimeoutMilliseconds)
            guard case .open = open else { return true }
            began = true
            let begin = await runMonitored(on: socket) { try await backend.begin() }
            if case let .failure(error) = begin {
                let cleanup = await end(backend)
                try? await write(Wire.Response.opened(cleanup ?? Wire.Failure(error)), to: socket)
                return cleanup == nil
            }
            try await write(Wire.Response.opened(nil), to: socket)

            while !Task.isCancelled {
                switch try await read(from: socket, timeout: Wire.leaseIdleMilliseconds) {
                case .open:
                    throw Wire.unavailable
                case .operation(let id, let operation):
                    let result = await runMonitored(on: socket, timeout: operation.timeoutMilliseconds) {
                        try operation.validate()
                        return try await backend.execute(operation)
                    }
                    let response: Wire.Response
                    switch result {
                    case .success(let value):
                        response = .value(id, value)
                    case .failure(let error):
                        response = .failed(id, Wire.Failure(error))
                    }
                    try await write(response, to: socket)
                case .close:
                    let cleanup = await end(backend)
                    try? await write(Wire.Response.closed(cleanup), to: socket)
                    return cleanup == nil
                }
            }
        } catch {
            // An abandoned connection can leave input owned by this lease.
        }
        if began { return await end(backend) == nil }
        return true
    }

    private static func read(from socket: PhysicalDeviceBrokerSocket, timeout: Int) async throws -> Wire.Request {
        try await withTaskCancellationHandler {
            try await PhysicalDeviceBrokerSocket.offMain {
                try socket.read(Wire.Request.self, timeoutMilliseconds: timeout)
            }
        } onCancel: {
            socket.interrupt()
        }
    }

    private static func write(_ value: some Encodable & Sendable,
                              to socket: PhysicalDeviceBrokerSocket) async throws {
        try await PhysicalDeviceBrokerSocket.offMain {
            try socket.write(PhysicalDeviceBrokerSocket.packet(value))
        }
    }

    private static func end(_ backend: PhysicalDeviceBrokerOwner) async -> Wire.Failure? {
        await Task.detached {
            do {
                try await backend.end()
                return nil
            } catch {
                return Wire.Failure(error)
            }
        }.value
    }

    private static func runMonitored<T: Sendable>(
        on socket: PhysicalDeviceBrokerSocket, timeout: Int = Wire.operationTimeoutMilliseconds,
        _ work: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        let operation = Task { try await work() }
        let monitor = Task {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout) * 1_000_000
            while !Task.isCancelled {
                let waiting = (try? await PhysicalDeviceBrokerSocket.offMain {
                    socket.peerIsWaiting(milliseconds: 50)
                }) == true
                if Task.isCancelled { return }
                guard waiting, DispatchTime.now().uptimeNanoseconds < deadline else {
                    socket.interrupt()
                    operation.cancel()
                    return
                }
            }
        }
        let result = await withTaskCancellationHandler {
            await operation.result
        } onCancel: {
            socket.interrupt()
            operation.cancel()
        }
        // The monitor checks cancellation again after poll. It cannot interrupt the
        // next request, and the current reply need not wait for the poll interval.
        monitor.cancel()
        return result
    }

    private static nonisolated func acceptClient(_ listener: Int32) throws -> Int32? {
        var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let count = Darwin.poll(&event, 1, 250)
        if count == 0 || (count < 0 && errno == EINTR) { return nil }
        guard count > 0, event.revents & Int16(POLLIN) != 0 else { throw Wire.unavailable }
        let descriptor = Darwin.accept(listener, nil, nil)
        if descriptor >= 0 { return descriptor }
        if [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { return nil }
        throw Wire.unavailable
    }
}
