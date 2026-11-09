import Darwin
import Dispatch
import Foundation

actor PhysicalDeviceBrokerClient {
    private typealias Wire = PhysicalDeviceBrokerProtocol

    private let socket: PhysicalDeviceBrokerSocket
    private var open = true
    private var busy = false

    private init(socket: PhysicalDeviceBrokerSocket) {
        self.socket = socket
    }

    static func connect(udid: String) async throws -> PhysicalDeviceBrokerClient {
        try Task.checkCancellation()
        let socket = try await PhysicalDeviceBrokerSocket.offMain { try connectToWorker(udid: udid) }
        try Task.checkCancellation()
        let packet = try PhysicalDeviceBrokerSocket.packet(Wire.Request.open)
        let response: Wire.Response
        do {
            response = try await withTaskCancellationHandler {
                try await PhysicalDeviceBrokerSocket.offMain {
                    try socket.write(packet)
                    return try socket.read(Wire.Response.self, timeoutMilliseconds: Wire.operationTimeoutMilliseconds)
                }
            } onCancel: {
                socket.interrupt()
            }
        } catch {
            try Task.checkCancellation()
            throw Wire.unavailable
        }
        guard case let .opened(failure) = response else { throw Wire.unavailable }
        if let failure { throw failure.error }
        return PhysicalDeviceBrokerClient(socket: socket)
    }

    func exchange(_ operation: PhysicalDeviceBrokerOperation) async throws -> PhysicalDeviceBrokerValue {
        try Task.checkCancellation()
        guard open else { throw Wire.unavailable }
        guard !busy else { throw Wire.busy }
        try operation.validate()
        let id = UUID()
        let packet = try PhysicalDeviceBrokerSocket.packet(Wire.Request.operation(id, operation))
        let socket = self.socket
        busy = true
        defer { busy = false }
        let response: Wire.Response
        do {
            response = try await withTaskCancellationHandler {
                try await PhysicalDeviceBrokerSocket.offMain {
                    try socket.write(packet)
                    return try socket.read(Wire.Response.self, timeoutMilliseconds: operation.timeoutMilliseconds)
                }
            } onCancel: {
                socket.interrupt()
            }
        } catch {
            throw lostExchange(operation)
        }
        switch response {
        case let .value(responseID, value) where responseID == id && Self.matches(value, operation):
            return value
        case let .failed(responseID, failure) where responseID == id:
            throw failure.error
        default:
            throw lostExchange(operation)
        }
    }

    /// A successful close receipt confirms the worker ended the input lease.
    func close() async throws {
        guard open else { return }
        guard !busy else { throw Wire.busy }
        open = false
        let socket = self.socket
        defer { socket.interrupt() }
        let response: Wire.Response
        do {
            let packet = try PhysicalDeviceBrokerSocket.packet(Wire.Request.close)
            response = try await PhysicalDeviceBrokerSocket.offMain {
                try socket.write(packet)
                return try socket.read(Wire.Response.self, timeoutMilliseconds: Wire.closeTimeoutMilliseconds)
            }
        } catch {
            throw Self.cleanupUnconfirmed
        }
        guard case let .closed(failure) = response else { throw Self.cleanupUnconfirmed }
        if let failure { throw failure.error }
    }

    private func lostExchange(_ operation: PhysicalDeviceBrokerOperation) -> Error {
        open = false
        socket.interrupt()
        if operation.sendsInput { return Wire.outcomeUnknown }
        return Task.isCancelled ? CancellationError() : Wire.unavailable
    }

    private static var cleanupUnconfirmed: CLIOutputFailure {
        CLIOutputFailure(code: "cleanupUnconfirmed",
            message: "AXe could not confirm release of the physical device input lease.")
    }

    private static func matches(_ value: PhysicalDeviceBrokerValue, _ operation: PhysicalDeviceBrokerOperation) -> Bool {
        switch (value, operation) {
        case (.display, .display), (.tree, .tree), (.semanticPress, .semanticPress),
             (.done, .touch), (.done, .keys), (.done, .button), (.done, .rotate), (.done, .keepAlive):
            true
        default:
            false
        }
    }

    private static func connectToWorker(udid: String) throws -> PhysicalDeviceBrokerSocket {
        let endpoint = try Wire.endpoint(udid: udid)
        let build = try Wire.BuildIdentity.current()
        let deadline = DispatchTime.now().uptimeNanoseconds + HIDBroker.startupTimeoutNanoseconds

        func existing() throws -> PhysicalDeviceBrokerSocket? {
            let descriptor: Int32
            do {
                descriptor = try HIDBroker.connect(to: endpoint)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain &&
                (error.code == Int(ENOENT) || error.code == Int(ECONNREFUSED)) {
                return nil
            }
            let socket = try PhysicalDeviceBrokerSocket(descriptor)
            let pid: Int32
            let hello: Wire.Hello
            do {
                pid = try socket.verifiedPeerPID(executable: build.executable)
                hello = try socket.read(Wire.Hello.self, timeoutMilliseconds: Wire.frameTimeoutMilliseconds)
            } catch let failure as CLIOutputFailure {
                throw failure
            } catch {
                // A broker exiting on idle can accept and then close; treat it as no broker.
                socket.interrupt()
                return nil
            }
            guard hello.version == Wire.version, hello.build == build, hello.workerPID == pid,
                  hello.udid.caseInsensitiveCompare(udid) == .orderedSame else { throw Wire.mismatch }
            if let failure = hello.failure { throw failure.error }
            return socket
        }

        func spawnWorker() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: build.executable)
            process.arguments = [Wire.commandName, "--udid", udid]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }

        if let socket = try existing() { return socket }
        let lock = try HIDBroker.acquireStartupLock(endpoint: endpoint, deadline: deadline,
            monotonicNow: HIDBroker.monotonicTimeNanoseconds, sleeper: { _ = usleep($0) })
        defer {
            _ = flock(lock, LOCK_UN)
            Darwin.close(lock)
        }
        if let socket = try existing() { return socket }
        var spawned: Process?
        if try !HIDBroker.isBrokerProcessAlive(endpoint: endpoint) {
            spawned = try spawnWorker()
        }
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let socket = try existing() { return socket }
            if let spawned, !spawned.isRunning { break }
            if spawned == nil, try !HIDBroker.isBrokerProcessAlive(endpoint: endpoint) {
                // The previous broker finished exiting; start one for this build.
                spawned = try spawnWorker()
            }
            _ = usleep(25_000)
        }
        throw Wire.unavailable
    }
}
