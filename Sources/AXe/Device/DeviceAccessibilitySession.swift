import Foundation

struct DeviceAccessibilitySnapshot: Sendable {
    let sequence: UInt64
    let receivedAt: ContinuousClock.Instant
    let archive: PhysicalAXTreeArchive
}

/// Owns one live DTX subscription and serializes all requests and push admission.
final class DeviceAccessibilitySession: @unchecked Sendable {
    private let directory: DeviceServiceDirectory
    private let lock = NSLock()
    private var state: State
    // Assigned before connect publishes the owner. The worker never changes this reference.
    private var worker: Task<Void, Never>?

    private init(directory: DeviceServiceDirectory, timeout: TimeInterval) {
        self.directory = directory
        state = State(generation: Generation(id: 1, deadline: ContinuousClock.now + .seconds(timeout)))
    }

    static func connect(using directory: DeviceServiceDirectory,
                        timeout: TimeInterval = 6) async throws -> DeviceAccessibilitySession {
        try validateTimeout(timeout)
        let session = DeviceAccessibilitySession(directory: directory, timeout: timeout)
        session.worker = Task.detached { await session.run() }
        do {
            _ = try await session.snapshot(timeout: timeout)
            return session
        } catch {
            await session.close()
            throw error
        }
    }

    /// A repeated YES replays the old tree. Start a new DTX subscription and keep it
    /// alive for any request that uses a translation object from the returned archive.
    func readArchive(timeout: TimeInterval = 6) async throws -> PhysicalAXTreeArchive {
        try Self.validateTimeout(timeout)
        try Task.checkCancellation()
        let generation = try lock.withLock {
            try requireOpen()
            guard state.pending == nil, !state.refreshing else { throw Self.busy }
            let generation = Generation(id: state.generation.id + 1, deadline: ContinuousClock.now + .seconds(timeout))
            state.generation = generation
            state.refreshing = true
            state.snapshot = nil
            return generation
        }
        do {
            return try await waitForSnapshot(after: nil, generation: generation.id, deadline: generation.deadline).archive
        } catch {
            terminate(error)
            throw error
        }
    }

    /// False once the worker has stopped, for example after the device closed the connection.
    var isOpen: Bool { lock.withLock { state.terminal == nil } }

    func snapshot(after sequence: UInt64? = nil, timeout: TimeInterval = 6) async throws -> DeviceAccessibilitySnapshot {
        try Self.validateTimeout(timeout)
        return try await waitForSnapshot(after: sequence, generation: nil,
                                         deadline: ContinuousClock.now + .seconds(timeout))
    }

    /// The caller can block on a translator thread. Only the owner writes to the socket.
    func request(_ secureArchive: Data, matching identity: DeviceAXRequestIdentity,
                 timeout: TimeInterval, expectedSequence: UInt64? = nil) throws -> Data {
        try Self.validateTimeout(timeout)
        guard identity.pid > 0, identity.objectID != 0, [2, 3, 5, 7].contains(identity.requestType),
              identity.requestType != 7 || expectedSequence != nil,
              secureArchive.count <= 32 * 1024, secureArchive.starts(with: "bplist00".utf8) else {
            throw CLIOutputFailure(code: "invalidAccessibilityRequest", message: "The live accessibility request has no supported target or archive.")
        }
        try Task.checkCancellation()
        let waitUntil = DispatchTime.now() + timeout
        let pending = try lock.withLock {
            try requireOpen()
            guard state.pending == nil, !state.refreshing else { throw Self.busy }
            if let expectedSequence, state.snapshot?.sequence != expectedSequence {
                throw Self.screenChanged
            }
            if identity.requestType == 7 {
                guard state.snapshot?.archive.entries.contains(where: {
                    $0.pid == identity.pid && $0.objectID == identity.objectID
                }) == true else { throw Self.screenChanged }
            }
            let pending = PendingRequest(archive: secureArchive, identity: identity,
                expectedSequence: expectedSequence,
                deadline: ContinuousClock.now + .seconds(timeout))
            state.pending = pending
            return pending
        }
        if pending.ready.wait(timeout: waitUntil) == .timedOut {
            lock.withLock {
                if state.pending === pending { terminateLocked(Self.requestTimedOut) }
            }
        }
        return try lock.withLock {
            guard let result = pending.result else { throw Self.requestTimedOut }
            return try result.get()
        }
    }

    func close() async {
        terminate(CancellationError())
        await worker?.value
    }

    private func waitForSnapshot(after sequence: UInt64?, generation: UInt64?,
                                 deadline: ContinuousClock.Instant) async throws -> DeviceAccessibilitySnapshot {
        let clock = ContinuousClock()
        while true {
            try Task.checkCancellation()
            let snapshot = try lock.withLock {
                try requireOpen()
                if let generation, state.generation.id != generation { throw Self.screenChanged }
                return state.snapshot
            }
            if let snapshot, snapshot.sequence > (sequence ?? 0) {
                return snapshot
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw Self.treeUnavailable }
            try await Task.sleep(for: min(remaining, .milliseconds(25)))
        }
    }

    private func run() async {
        do {
            while let generation = lock.withLock({ state.terminal == nil ? state.generation : nil }) {
                let timeout = try Self.remaining(until: generation.deadline, failure: Self.treeUnavailable)
                try await directory.withRawService(DeviceAccessibilityTransport.service, timeout: timeout) { socket in
                    try self.runChannel(socket, generation: generation)
                }
            }
        } catch {
            terminate(error)
        }
    }

    private func runChannel(_ socket: DeviceTCPSocket, generation: Generation) throws {
        var nextID: UInt32 = 1
        func send(_ selector: String, argument: NSObject, expectsReply: Bool = false) throws -> UInt32 {
            let id = nextID
            nextID += 1
            try socket.write(DeviceDTXMessage.invocation(selector, argument: argument, identifier: id, expectsReply: expectsReply))
            return id
        }

        try socket.write(DeviceDTXMessage.capabilities(identifier: nextID))
        nextID += 1
        let capabilities = try DeviceDTXMessage.read(from: socket.read(count:))
        guard capabilities.channel == 0, capabilities.conversation == 0,
              try capabilities.selector() == "_notifyOfPublishedCapabilities:" else {
            throw DeviceServiceError.invalidProtocol("DTX: expected the peer capability message")
        }
        if capabilities.expectsReply { try socket.write(capabilities.acknowledgement()) }

        defer {
            socket.renewDeadline(after: 0.5)
            _ = try? send("clientNeedsAccessibility:", argument: NSNumber(value: false))
            socket.finishWrites()
        }
        _ = try send("clientNeedsAccessibility:", argument: NSNumber(value: true))
        let retryAt = ContinuousClock.now + .milliseconds(2_500)
        var retryNeeded = true
        var firstTree = true
        var admission = PhysicalAXTreeAdmission()
        var onWire: WireRequest?

        while true {
            let phase = lock.withLock { (state.terminal == nil && state.generation.id == generation.id, state.pending) }
            guard phase.0 else { return }
            let now = ContinuousClock.now
            if firstTree, now >= generation.deadline { throw Self.treeUnavailable }
            if let pending = phase.1, now >= pending.deadline { throw Self.requestTimedOut }

            if let pending = phase.1, onWire == nil, try beginSending(pending) {
                socket.renewDeadline(after: try Self.remaining(until: pending.deadline, failure: Self.requestTimedOut))
                let identifier = try send("processDataFromHost:", argument: pending.archive as NSData, expectsReply: true)
                onWire = WireRequest(pending: pending, identifier: identifier)
            }
            if retryNeeded, now >= retryAt {
                retryNeeded = false
                admission.reset()
                socket.renewDeadline(after: try Self.remaining(until: generation.deadline, failure: Self.treeUnavailable))
                _ = try send("clientNeedsAccessibility:", argument: NSNumber(value: true))
            }

            guard try socket.isReadable(for: 0.04) else { continue }
            let deadline = onWire?.pending.deadline ?? (firstTree ? generation.deadline : now + .seconds(2))
            socket.renewDeadline(after: try Self.remaining(until: deadline,
                failure: onWire == nil ? Self.treeUnavailable : Self.requestTimedOut))
            let message = try DeviceDTXMessage.read(from: socket.read(count:))
            if message.expectsReply, message.conversation == 0 {
                try socket.write(message.acknowledgement())
            }

            if message.conversation == 1, var request = onWire {
                guard message.channel == 0, message.identifier == request.identifier,
                      message.isEmptyAcknowledgement, !request.acknowledged else {
                    throw Self.replyMismatch
                }
                request.acknowledged = true
                onWire = request
            } else if message.conversation == 0, message.channel == 0,
                      try message.selector() == "processDataFromRemoteDevice:" {
                let bytes = try message.archiveArgument(maximumBytes: PhysicalAXTreeArchive.maximumBytes)
                let metadata = try DeviceAXLiveResponse.decode(bytes)
                if metadata.requestType == 11 {
                    // Resubscribe only when nothing arrived. On the iPad keyboard screen the AdditionalData
                    // push followed its InitialDump after the retry point; a reset discarded that pair.
                    retryNeeded = false
                    clearSnapshot(generation: generation.id)
                    if let archive = try admission.receive(bytes) {
                        publish(archive, generation: generation.id)
                        firstTree = false
                        retryNeeded = false
                    }
                } else if var request = onWire {
                    guard metadata.matches(request.pending.identity,
                              pinnedToFreshTree: request.pending.expectedSequence != nil),
                          request.response == nil else {
                        throw Self.replyMismatch
                    }
                    request.response = bytes
                    onWire = request
                }
            }

            if let request = onWire, request.acknowledged, let response = request.response {
                try complete(request.pending, response: response)
                onWire = nil
            }
        }
    }

    private func beginSending(_ pending: PendingRequest) throws -> Bool {
        try lock.withLock {
            guard state.terminal == nil, state.pending === pending else { return false }
            guard ContinuousClock.now < pending.deadline else { throw Self.requestTimedOut }
            if let sequence = pending.expectedSequence, state.snapshot?.sequence != sequence {
                pending.result = .failure(Self.screenChanged)
                state.pending = nil
                pending.ready.signal()
                return false
            }
            if pending.identity.requestType == 7 { state.snapshot = nil }
            pending.writeAttempted = true
            return true
        }
    }

    private func complete(_ pending: PendingRequest, response: Data) throws {
        try lock.withLock {
            guard state.terminal == nil, state.pending === pending else { return }
            guard ContinuousClock.now < pending.deadline else { throw Self.requestTimedOut }
            pending.result = .success(response)
            state.pending = nil
            pending.ready.signal()
        }
    }

    private func clearSnapshot(generation: UInt64) {
        lock.withLock {
            guard state.generation.id == generation else { return }
            state.snapshot = nil
        }
    }

    private func publish(_ archive: PhysicalAXTreeArchive, generation: UInt64) {
        lock.withLock {
            guard state.terminal == nil, state.generation.id == generation else { return }
            state.lastSequence += 1
            state.snapshot = DeviceAccessibilitySnapshot(sequence: state.lastSequence, receivedAt: .now, archive: archive)
            state.refreshing = false
        }
    }

    private func requireOpen() throws {
        if let terminal = state.terminal { throw terminal }
    }

    private func terminate(_ reason: Error) {
        lock.withLock { terminateLocked(reason) }
    }

    private func terminateLocked(_ reason: Error) {
        guard state.terminal == nil else { return }
        state.terminal = reason
        state.snapshot = nil
        if let pending = state.pending {
            if pending.identity.requestType == 7, pending.writeAttempted {
                pending.result = .failure(CLIOutputFailure(code: "actionOutcomeUnknown",
                    message: "The device did not confirm the semantic press. Inspect the screen before sending more input."))
            } else {
                pending.result = .failure(reason)
            }
            state.pending = nil
            pending.ready.signal()
        }
    }

    private static func remaining(until deadline: ContinuousClock.Instant, failure: Error) throws -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline)
        guard duration > .zero else { throw failure }
        return duration.timeInterval
    }

    private static func validateTimeout(_ timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else {
            throw CLIOutputFailure(code: "invalidArguments", message: "Device accessibility timeout must be greater than 0 and at most 60 seconds.")
        }
    }

    private static var busy: CLIOutputFailure {
        CLIOutputFailure(code: "deviceBusy", message: "Another operation owns the device accessibility connection.")
    }

    private static var treeUnavailable: CLIOutputFailure {
        CLIOutputFailure(code: "treeUnavailable", message: "The device did not send a complete accessibility tree. Dismiss any system or web alert and try again.")
    }

    private static var screenChanged: CLIOutputFailure {
        CLIOutputFailure(code: "screenChanged", message: "The device accessibility tree changed before the request.")
    }

    private static var requestTimedOut: CLIOutputFailure {
        CLIOutputFailure(code: "accessibilityRequestUnconfirmed", message: "The device did not confirm the accessibility request.")
    }

    private static var replyMismatch: CLIOutputFailure {
        CLIOutputFailure(code: "accessibilityReplyMismatch", message: "The device accessibility response did not match the pending request.")
    }

    private struct Generation: Sendable {
        let id: UInt64
        let deadline: ContinuousClock.Instant
    }

    private struct State {
        var generation: Generation
        var refreshing = true
        var lastSequence: UInt64 = 0
        var snapshot: DeviceAccessibilitySnapshot?
        var pending: PendingRequest?
        var terminal: Error?
    }

    private final class PendingRequest: @unchecked Sendable {
        let archive: Data
        let identity: DeviceAXRequestIdentity
        let expectedSequence: UInt64?
        let deadline: ContinuousClock.Instant
        let ready = DispatchSemaphore(value: 0)
        // The session lock protects writeAttempted and result.
        var writeAttempted = false
        var result: Result<Data, Error>?

        init(archive: Data, identity: DeviceAXRequestIdentity, expectedSequence: UInt64?, deadline: ContinuousClock.Instant) {
            self.archive = archive
            self.identity = identity
            self.expectedSequence = expectedSequence
            self.deadline = deadline
        }
    }

    private struct WireRequest {
        let pending: PendingRequest
        let identifier: UInt32
        var acknowledged = false
        var response: Data?
    }
}
