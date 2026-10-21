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
        try request.validate()
        var data = try JSONEncoder().encode(request); data.append(10)
        guard data.count <= HIDBroker.maximumMessageBytes else { throw SelectedHIDFailure.invalid("Request too large") }
        let descriptor = try HIDBroker.connectToReadyBroker(simulatorUDID: simulatorUDID,
            endpoint: endpoint(simulatorUDID: simulatorUDID), connector: HIDBroker.connect(to:),
            spawner: { udid in
                guard let executable = Bundle.main.executableURL else { throw SelectedHIDFailure.invalid("Missing executable") }
                let child = Process(); child.executableURL = executable
                child.arguments = ["hid-broker", "--selected", "--udid", udid]
                child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice; try child.run()
            }, sleeper: { _ = usleep($0) }, expectedVersion: SelectedHIDRequest.version)
        defer { Darwin.close(descriptor) }
        try HIDBroker.configureSocketTimeouts(descriptor, readMilliseconds: 120_000, writeMilliseconds: 2000)
        return try exchange(data, requestID: request.requestID, descriptor: descriptor,
            maximumResponseBytes: request.ax == nil && request.keyboard == nil ? HIDBroker.maximumMessageBytes : SelectedAXBounds.responseBytes)
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
            throw CLIError(errorDescription: "Selected HID request outcome is unknown and was not replayed: \(error)")
        }
    }
    static func printResponse(_ response: SelectedHIDResponse) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(response), as: UTF8.self))
        if response.error != nil { throw CLIError(errorDescription: "Selected input failed; inspect the JSON receipt. No input was replayed.") }
    }
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            io.async { continuation.resume(with: Result { try work() }) }
        }
    }
    @MainActor
    static func serve(simulatorUDID: String, logger: AxeLogger) async throws {
        let endpoint = try endpoint(simulatorUDID: simulatorUDID)
        let lifetime = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        defer { _ = flock(lifetime, LOCK_UN); Darwin.close(lifetime) }
        let listener = try HIDBroker.makeListener(at: endpoint)
        let identity = try HIDBroker.socketIdentity(at: endpoint)
        defer { Darwin.close(listener); try? HIDBroker.removeOwnedSocket(endpoint, matching: identity) }
        guard let executable = Bundle.main.executableURL else { throw SelectedHIDFailure.invalid("Missing executable") }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("cadisplay-context")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw SelectedHIDFailure.invalid("Missing signed cadisplay-context helper beside axe") }
        let owner = SelectedHIDOwner(simulatorUDID: simulatorUDID, logger: logger, helperURL: helper)
        var tasks: [UUID: Task<Void, Never>] = [:]
        do {
            while !owner.shouldStop {
                await owner.maintain()
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
                // Bounded outstanding socket work. Rejection happens before the ready handshake.
                guard tasks.count < 8 else { Darwin.close(client); continue }
                let rejectedWhileBusy = owner.isBusy
                let id = UUID()
                tasks[id] = Task { @MainActor in
                    defer { Darwin.close(client); tasks.removeValue(forKey: id) }
                    do {
                        let request = try await offMain {
                            var uid: uid_t = 0; var gid: gid_t = 0
                            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { throw SelectedHIDFailure.invalid("Client UID mismatch") }
                            HIDBroker.configureNoSignalPipe(client)
                            try HIDBroker.configureSocketTimeouts(client, readMilliseconds: 2000, writeMilliseconds: 2000)
                            try HIDBroker.writeHandshake(ready: true, version: SelectedHIDRequest.version, to: client)
                            let bytes = try HIDBroker.readMessage(from: client)
                            guard bytes.count <= HIDBroker.maximumMessageBytes else { throw SelectedHIDFailure.invalid("Request too large") }
                            return try JSONDecoder().decode(SelectedHIDRequest.self, from: bytes)
                        }
                        let response = rejectedWhileBusy ? owner.rejectBusy(request) : await owner.perform(request)
                        try await offMain {
                            let maximumBytes = request.ax == nil && request.keyboard == nil ? HIDBroker.maximumMessageBytes : SelectedAXBounds.responseBytes
                            let bytes = try SelectedAXWire.boundedResponse(response, maximumBytes: maximumBytes)
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
