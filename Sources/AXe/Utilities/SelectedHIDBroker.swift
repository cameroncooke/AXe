import Darwin
import Foundation
import FBControlCore

/// Socket work runs off the main actor. Only immutable requests cross into the input owner.
enum SelectedHIDBroker {
    private static let io = DispatchQueue(label: "axe.selected-hid.socket", attributes: .concurrent)
    static func endpoint(simulatorUDID: String) throws -> String {
        try HIDBroker.endpointPath(simulatorUDID: simulatorUDID,
            developerDirectory: FBXcodeDirectory.resolveDeveloperDirectory(), version: SelectedHIDRequest.version)
    }
    static func send(_ request: SelectedHIDRequest, simulatorUDID: String) throws -> SelectedHIDResponse {
        guard request.ordinaryKeyboard == nil else {
            throw SelectedHIDFailure.invalid("Legacy keyboard requires the cancellable owned exchange")
        }
        let data = try encoded(request)
        // Includes starting a broker when none is ready.
        let descriptor = try PhaseTimer.measureSync("client.connect") {
            try readyDescriptor(simulatorUDID: simulatorUDID)
        }
        defer { Darwin.close(descriptor) }
        try HIDBroker.configureSocketTimeouts(descriptor, readMilliseconds: request.agentBatch?.responseTimeoutMilliseconds ?? request.path?.responseTimeoutMilliseconds ?? 120_000, writeMilliseconds: 2000)
        return try PhaseTimer.measureSync("client.exchange") {
            try exchange(data, requestID: request.requestID, descriptor: descriptor,
                maximumResponseBytes: request.ax == nil && request.keyboard == nil && request.agent == nil && request.agentBatch == nil ? HIDBroker.maximumMessageBytes : SelectedAXBounds.responseBytes)
        }
    }

    /// Sends to a broker that is already running, without starting one. Nil means nothing was sent:
    /// there is no broker to reach, or the request is not one it accepts. A failure after the request
    /// has gone out is thrown, because the input may have been sent.
    static func sendToRunningBroker(_ request: SelectedHIDRequest, simulatorUDID: String,
                                    readMilliseconds: Int? = nil) throws -> SelectedHIDResponse? {
        guard let data = try? encoded(request), let path = try? endpoint(simulatorUDID: simulatorUDID),
              let descriptor = (try? HIDBroker.connectToRunningBroker(endpoint: path,
                  expectedVersion: SelectedHIDRequest.version)) ?? nil else { return nil }
        defer { Darwin.close(descriptor) }
        guard (try? HIDBroker.configureSocketTimeouts(descriptor,
            readMilliseconds: readMilliseconds ?? request.path?.responseTimeoutMilliseconds ?? 120_000, writeMilliseconds: 2000)) != nil else {
            return nil
        }
        return try exchange(data, requestID: request.requestID, descriptor: descriptor)
    }

    /// Keeps an already-running broker from shutting down while idle. Starts nothing: with no broker
    /// running it returns false, and the next input starts one as usual.
    static let keepAliveResponseMilliseconds = 2000

    @discardableResult
    static func keepAliveIfRunning(simulatorUDID: String) -> Bool {
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: nil, screenUUID: nil, operation: .complete, token: nil, payload: .keepAlive)
        // A keep-alive sends no input, so a broker that does not answer at once is not worth waiting for.
        guard let response = try? sendToRunningBroker(request, simulatorUDID: simulatorUDID,
            readMilliseconds: keepAliveResponseMilliseconds) else { return false }
        return response.error == nil && response.outcome == "keptAlive"
    }

    /// Raw keyboard has no whole-command deadline. Cancellation closes this owned exchange, never replays it.
    static func sendOrdinaryKeyboard(_ request: SelectedHIDRequest, simulatorUDID: String) async throws -> SelectedHIDResponse {
        guard request.ordinaryKeyboard != nil else { throw SelectedHIDFailure.invalid("Missing legacy keyboard payload") }
        let data = try encoded(request)
        try Task.checkCancellation()
        let descriptor = try readyDescriptor(simulatorUDID: simulatorUDID)
        let socket = OrdinaryKeyboardSocket(descriptor: descriptor)
        defer { socket.close() }
        // A zero receive timeout preserves raw Type's existing unbounded whole-command duration.
        var timeout = timeval()
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw HIDBroker.posixError("configure legacy keyboard response")
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await offMain {
                try exchange(data, requestID: request.requestID, descriptor: descriptor)
            }
        } onCancel: {
            // EOF cancels the broker action. Keep the read side open for its joined cleanup receipt.
            socket.shutdownWrite()
        }
    }

    private static func encoded(_ request: SelectedHIDRequest) throws -> Data {
        try request.validate()
        var data = try JSONEncoder().encode(request); data.append(10)
        guard data.count <= maximumRequestBytes(request) else { throw SelectedHIDFailure.invalid("Request too large") }
        return data
    }

    /// Ordinary keyboard input may carry long text; every other request keeps the 64 KiB bound.
    private static func maximumRequestBytes(_ request: SelectedHIDRequest) -> Int {
        request.ordinaryKeyboard == nil ? HIDBroker.maximumMessageBytes : OrdinaryBrokerKeyboard.maximumMessageBytes
    }

    /// Reads one request from an admitted client. The larger read bound applies only to ordinary keyboard input.
    static func readRequest(from descriptor: Int32) throws -> SelectedHIDRequest {
        let bytes = try HIDBroker.readMessage(from: descriptor, maximumBytes: OrdinaryBrokerKeyboard.maximumMessageBytes)
        let request = try JSONDecoder().decode(SelectedHIDRequest.self, from: bytes)
        guard bytes.count <= maximumRequestBytes(request) else { throw SelectedHIDFailure.invalid("Request too large") }
        return request
    }

    private static func readyDescriptor(simulatorUDID: String) throws -> Int32 {
        try HIDBroker.connectToReadyBroker(simulatorUDID: simulatorUDID,
            endpoint: endpoint(simulatorUDID: simulatorUDID), connector: HIDBroker.connect(to:),
            spawner: { udid in
                guard let executable = Bundle.main.executableURL else { throw SelectedHIDFailure.invalid("Missing executable") }
                let child = Process(); child.executableURL = executable
                child.arguments = ["hid-broker", "--selected", "--udid", udid]
                child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice; try child.run()
            }, sleeper: { _ = usleep($0) }, expectedVersion: SelectedHIDRequest.version)
    }
    static func exchange(_ data: Data, requestID: UUID, descriptor: Int32,
                         maximumResponseBytes: Int = HIDBroker.maximumMessageBytes) throws -> SelectedHIDResponse {
        // There is deliberately no reconnect or replay below this boundary.
        do {
            try HIDBroker.writeAll(data, to: descriptor)
            let bytes = try SelectedAXWire.readResponse(from: descriptor, maximumBytes: maximumResponseBytes)
            let response = try JSONDecoder().decode(SelectedHIDResponse.self, from: bytes)
            guard response.version == SelectedHIDRequest.version, response.requestID == requestID else {
                throw SelectedHIDFailure.invalid("Response version or request identity mismatch")
            }
            return response
        } catch {
            throw CLIError(errorDescription: "AXe lost contact with its input service, so the result is unknown. The request was not repeated; read the screen before trying again.", code: .inputFailed)
        }
    }
    /// `verbose` prints the full receipt in place of the plain-command result. The failure and its
    /// code are the same either way.
    static func printResponse(_ response: SelectedHIDResponse, verbose: Bool) throws {
        guard verbose else { try SelectedInputOutput.print(response); return }
        try writeReceipt(response)
        if SelectedInputOutput.failed(response) { throw SelectedInputOutput.failure(response) }
    }

    /// The broker reply, unchanged, for `--verbose`.
    static func writeReceipt(_ response: SelectedHIDResponse) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try CLIOutput.writeJSONData(encoder.encode(response))
    }
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            io.async { continuation.resume(with: Result { try work() }) }
        }
    }
    private static func configureClient(_ descriptor: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else {
            throw SelectedHIDFailure.invalid("Client UID mismatch")
        }
        HIDBroker.configureNoSignalPipe(descriptor)
        try HIDBroker.configureSocketTimeouts(descriptor, readMilliseconds: 2000, writeMilliseconds: 2000)
    }
    @MainActor
    static func serve(simulatorUDID: String, logger: AxeLogger) async throws {
        let endpoint = try endpoint(simulatorUDID: simulatorUDID)
        let lifetime = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        defer { _ = flock(lifetime, LOCK_UN); Darwin.close(lifetime) }
        let listener = try HIDBroker.makeListener(at: endpoint)
        let identity = try HIDBroker.socketIdentity(at: endpoint)
        defer { Darwin.close(listener); try? HIDBroker.removeOwnedSocket(endpoint, matching: identity) }
        let owner = SelectedHIDOwner(simulatorUDID: simulatorUDID, logger: logger)
        let agentController = AgentModeController(simulatorUDID: simulatorUDID, logger: logger, owner: owner)
        var tasks: [UUID: Task<Void, Never>] = [:]
        do {
            while !owner.shouldStop {
                owner.retireIfQuarantineCleared()
                if owner.shouldStop { break }
                await agentController.maintain()
                if owner.shouldStop { break }
                let client = try await offMain {
                    var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                    let count = Darwin.poll(&descriptor, 1, 250)
                    if count == 0 || (count < 0 && errno == EINTR) { return Int32(-1) }
                    guard count > 0 else { throw HIDBroker.posixError("poll") }
                    let accepted = Darwin.accept(listener, nil, nil)
                    guard accepted >= 0 else { throw HIDBroker.posixError("accept") }
                    return accepted
                }
                guard client >= 0 else { continue }
                // Capacity is terminal busy. EOF would let clients retry readiness and send later.
                guard tasks.count < 8 else {
                    try? await offMain {
                        try configureClient(client)
                        try HIDBroker.writeHandshake(ready: false, version: SelectedHIDRequest.version,
                            rejection: "busy", to: client)
                    }
                    Darwin.close(client)
                    continue
                }
                let rejectedWhileBusy = owner.isBusy || agentController.isBusy
                let id = UUID()
                tasks[id] = Task { @MainActor in
                    defer { Darwin.close(client); tasks.removeValue(forKey: id) }
                    do {
                        let ready = !owner.shouldStop
                        let request = try await offMain {
                            try configureClient(client)
                            try HIDBroker.writeHandshake(ready: ready, version: SelectedHIDRequest.version, to: client)
                            guard ready else { throw SelectedHIDFailure.busy }
                            return try readRequest(from: client)
                        }
                        var response: SelectedHIDResponse
                        let timer = request.timing == true ? PhaseTimer() : nil
                        if request.isKeepAlive {
                            // Never queued behind input and never refused as busy: input in flight
                            // already keeps the broker alive.
                            response = owner.keepAlive(request)
                        } else if rejectedWhileBusy || agentController.isBusy {
                            response = request.agent == nil && request.agentBatch == nil ? owner.rejectBusy(request) : agentController.reject(request)
                        } else if request.agentBatch != nil {
                            response = await SelectedHIDClientLifetime.run(descriptor: client) {
                                await PhaseTimer.$current.withValue(timer) {
                                    await PhaseTimer.measure("broker.batch") { await agentController.performBatch(request) }
                                }
                            }
                        } else if request.agent != nil {
                            response = await SelectedHIDClientLifetime.run(descriptor: client) {
                                await PhaseTimer.$current.withValue(timer) {
                                    await PhaseTimer.measure("broker.agent") { await agentController.perform(request) }
                                }
                            }
                        } else {
                            agentController.invalidate()
                            response = await SelectedHIDClientLifetime.run(descriptor: client) {
                                await PhaseTimer.$current.withValue(timer) {
                                    await PhaseTimer.measure("broker.selected") { await owner.perform(request) }
                                }
                            }
                        }
                        response.timing = timer?.payload
                        let reply = response
                        try await offMain {
                            let maximumBytes = request.ax == nil && request.keyboard == nil && request.agent == nil && request.agentBatch == nil ? HIDBroker.maximumMessageBytes : SelectedAXBounds.responseBytes
                            let bytes = try SelectedAXWire.boundedResponse(reply, maximumBytes: maximumBytes)
                            try HIDBroker.writeAll(bytes, to: client)
                        }
                    } catch { logger.error().log("Selected broker exchange failed; no replay: \(error)") }
                }
            }
        } catch {
            for task in Array(tasks.values) { await task.value }
            await owner.shutdown()
            throw error
        }
        for task in Array(tasks.values) { await task.value }
        await owner.shutdown()
    }
}

/// Cancellation can arrive on another thread while the send scope exits. Never act on a reused FD.
private final class OrdinaryKeyboardSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) { self.descriptor = descriptor }

    func shutdownWrite() {
        lock.lock()
        defer { lock.unlock() }
        if let descriptor { _ = Darwin.shutdown(descriptor, SHUT_WR) }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let descriptor { Darwin.close(descriptor); self.descriptor = nil }
    }
}
