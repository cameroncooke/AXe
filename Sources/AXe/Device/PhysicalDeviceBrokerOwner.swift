import Foundation
import FBSimulatorControl

/// Owns the device transports across client leases. Every lease still checks CoreDevice readiness.
/// When input in a lease needs a fresh lock check. The readiness check at lease start covers normal
/// commands, and input resets the device's auto-lock timer, so only input after a quiet gap (such as a
/// long batch sleep) reads the lock state again. Input after the lock button in the same lease is refused.
struct PhysicalLockRecheck: Sendable {
    static let quietGap: Duration = .seconds(25)
    private var lastInput: ContinuousClock.Instant?
    private(set) var lockedByButton = false

    mutating func leaseStarted(at now: ContinuousClock.Instant) {
        lastInput = now
        lockedByButton = false
    }

    func needsCheck(at now: ContinuousClock.Instant) -> Bool {
        guard let lastInput else { return true }
        return lastInput.duration(to: now) >= Self.quietGap
    }

    mutating func inputSent(at now: ContinuousClock.Instant, lockButton: Bool) {
        lastInput = now
        if lockButton { lockedByButton = true }
    }
}

actor PhysicalDeviceBrokerOwner: PhysicalDeviceBrokerBackend {
    private let device: CoreDevice
    private var input: PhysicalDeviceInputOwner?
    private var accessibility: DeviceAccessibilitySession?
    private var lockRecheck = PhysicalLockRecheck()

    init(device: CoreDevice) {
        self.device = device
    }

    func begin() async throws {
        let current = try await PhysicalDeviceInputOwner.readyDevice(device)
        lockRecheck.leaseStarted(at: .now)
        if let input, await input.matchesReadyDevice(current) { return }
        await shutdown()
        input = try await PhysicalDeviceInputOwner.connectReadyDevice(current)
    }

    private func admitInput(_ operation: PhysicalDeviceBrokerOperation) async throws {
        guard operation.sendsInput else { return }
        if lockRecheck.lockedByButton {
            throw CLIOutputFailure(code: "deviceLocked",
                message: "The lock button was pressed earlier in this command. Unlock the device before sending more input.")
        }
        if lockRecheck.needsCheck(at: .now), try await CoreDeviceInventory.lockState(for: device) != false {
            throw CLIOutputFailure(code: "deviceLocked", message: "Unlock the device before sending input or reading its screen.")
        }
    }

    private func recordInput(_ operation: PhysicalDeviceBrokerOperation) {
        guard operation.sendsInput else { return }
        var lockButton = false
        if case .button(.lock, _, _) = operation { lockButton = true }
        lockRecheck.inputSent(at: .now, lockButton: lockButton)
    }

    func execute(_ operation: PhysicalDeviceBrokerOperation) async throws -> PhysicalDeviceBrokerValue {
        guard let input else {
            throw CLIOutputFailure(code: "deviceBrokerUnavailable", message: "The broker has no ready device session.")
        }
        try await admitInput(operation)
        let value = try await perform(operation, on: input)
        recordInput(operation)
        return value
    }

    private func perform(_ operation: PhysicalDeviceBrokerOperation,
                         on input: PhysicalDeviceInputOwner) async throws -> PhysicalDeviceBrokerValue {
        switch operation {
        case .keepAlive:
            return .done
        case .display:
            return .display(try await input.display())
        case let .touch(steps, display, allowPartial, deadlineUptime):
            if let display, try await input.display() != display {
                throw CLIOutputFailure(code: "screenChanged", message: "The physical display changed before the broker received the touch.")
            }
            let deadline: ContinuousClock.Instant?
            if let deadlineUptime {
                let now = DispatchTime.now().uptimeNanoseconds
                guard deadlineUptime > now, deadlineUptime - now <= 30_000_000_000 else {
                    throw CLIOutputFailure(code: "waitTimedOut", message: "The element selection expired before the broker received it.")
                }
                deadline = .now + .nanoseconds(Int64(deadlineUptime - now))
            } else {
                deadline = nil
            }
            try await input.perform(steps, on: display, allowPartial: allowPartial, admissionDeadline: deadline)
            return .done
        case let .keys(steps):
            try await input.keys(steps)
            return .done
        case let .button(button, hold, allowLock):
            guard button != .lock || allowLock else {
                throw AutomationTarget.unsupportedOnDevice("Physical lock requires --allow-lock.")
            }
            try await input.pressButton(button, hold: hold)
            return .done
        case let .rotate(direction, timeout):
            try await input.rotate(direction, timeout: timeout)
            return .done
        case let .tree(timeout):
            do {
                let snapshot = try await readTree(on: input, budget: ReadBudget(timeout: timeout))
                return .tree(snapshot.json, display: snapshot.display)
            } catch {
                await closeAccessibility()
                throw error
            }
        case let .semanticPress(identifier):
            do {
                return .semanticPress(try await semanticPress(identifier, on: input))
            } catch {
                await closeAccessibility()
                throw error
            }
        }
    }

    func end() async throws {
        guard let input else { return }
        do {
            try await input.finishClient()
        } catch {
            await shutdown()
            throw error
        }
    }

    func shutdown() async {
        await closeAccessibility()
        guard let input else { return }
        self.input = nil
        try? await input.close()
    }

    private func closeAccessibility() async {
        guard let accessibility else { return }
        self.accessibility = nil
        await accessibility.close()
    }

    /// Returns the held session, or connects one. A new session has already received a complete tree,
    /// which the caller can use instead of requesting another.
    private func accessibilitySession(on input: PhysicalDeviceInputOwner,
                                      budget: ReadBudget) async throws -> (session: DeviceAccessibilitySession, connected: Bool) {
        if let accessibility {
            if accessibility.isOpen { return (accessibility, false) }
            // Reconnect from local state only; no probe is sent before reuse.
            await closeAccessibility()
        }
        let session = try await DeviceAccessibilitySession.connect(using: input.directory, timeout: budget.remaining())
        accessibility = session
        return (session, true)
    }

    /// The tree a new session received while connecting, or a fresh read on a held session.
    private func currentArchive(of session: DeviceAccessibilitySession, connected: Bool,
                                budget: ReadBudget) async throws -> PhysicalAXTreeArchive {
        connected ? try await session.snapshot(timeout: budget.remaining()).archive
            : try await session.readArchive(timeout: budget.remaining())
    }

    private func readTree(on input: PhysicalDeviceInputOwner, budget: ReadBudget) async throws -> PhysicalAccessibilitySnapshot {
        let before = try await input.display(timeout: budget.remaining())
        let (session, connected) = try await accessibilitySession(on: input, budget: budget)
        let archive = try await currentArchive(of: session, connected: connected, budget: budget)
        let after = try await input.display(timeout: budget.remaining())
        guard before == after else {
            throw CLIOutputFailure(code: "screenChanged", message: "The device display changed during the accessibility read.")
        }
        let snapshot = try PhysicalAccessibility.project(archive, display: before) { request in
            try Self.forward(request, to: session, timeout: min(1.5, budget.remaining()))
        }
        _ = try budget.remaining()
        return snapshot
    }

    private func semanticPress(_ identifier: String, on input: PhysicalDeviceInputOwner) async throws -> PhysicalSemanticPressReceipt {
        guard !identifier.isEmpty, identifier.utf8.count <= 4096,
              identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw CLIOutputFailure(code: "invalidArguments", message: "Supply one nonempty exact checkbox ID.")
        }
        let budget = try ReadBudget(timeout: 16)
        let display = try await input.display(timeout: budget.remaining())
        let bounds = try CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let (session, connected) = try await accessibilitySession(on: input, budget: budget)

        func prepare(_ archive: PhysicalAXTreeArchive) throws -> FBPhysicalAXTreeProjection.PreparedPress {
            do {
                return try FBPhysicalAXTreeProjection.preparePress(archive: archive.data,
                    entries: PhysicalAccessibility.projectionEntries(archive), identifier: identifier, displayBounds: bounds)
            } catch {
                try Task.checkCancellation()
                throw CLIOutputFailure(code: "semanticTargetUnavailable", message: error.localizedDescription)
            }
        }

        let initial = try prepare(await currentArchive(of: session, connected: connected, budget: budget))
        let freshArchive = try await session.readArchive(timeout: budget.remaining())
        let fresh = try prepare(freshArchive)
        let snapshot = try await session.snapshot(timeout: budget.remaining())
        guard snapshot.archive.data == freshArchive.data,
              initial.target.matchesReadback(fresh.target), initial.target.value == fresh.target.value,
              try await input.display(timeout: budget.remaining()) == display else {
            throw CLIOutputFailure(code: "targetChanged", message: "The checkbox or display changed before the semantic press.")
        }

        try Task.checkCancellation()
        let actionTimeout = try min(2.5, budget.remaining())
        do {
            let data = try Self.forward(fresh.request, to: session, timeout: actionTimeout,
                                        expectedSequence: snapshot.sequence)
            guard try FBPhysicalAXTreeProjection.acceptedPressReply(data) else {
                throw CLIOutputFailure(code: "semanticPressUnconfirmed", message: "The device did not accept AXPress.")
            }
        } catch let failure as CLIOutputFailure {
            throw failure
        } catch {
            throw CLIOutputFailure(code: "semanticPressUnconfirmed",
                message: "AXe did not confirm the semantic action. Inspect the checkbox before issuing another action.")
        }

        for count in 1...4 {
            do {
                if count > 1 { try await Task.sleep(for: .milliseconds(100)) }
                let readback = try prepare(await session.readArchive(timeout: budget.remaining()))
                guard fresh.target.matchesReadback(readback.target),
                      try await input.display(timeout: budget.remaining()) == display else {
                    break
                }
                if readback.target.value != fresh.target.value {
                    return PhysicalSemanticPressReceipt(identifier: identifier, stateBefore: fresh.target.value,
                        stateAfter: readback.target.value, readbackCount: count, outcome: "switchValueChangedObserved",
                        delivery: "nativeReplyAccepted")
                }
            } catch { break }
        }
        throw CLIOutputFailure(code: "semanticPressUnconfirmed",
            message: "The device accepted AXPress. AXe did not confirm the checkbox value change.")
    }

    private static func forward(_ request: FBPhysicalAXTreeProjection.LiveRequest, to session: DeviceAccessibilitySession,
                                timeout: TimeInterval, expectedSequence: UInt64? = nil) throws -> Data {
        let identity = DeviceAXRequestIdentity(requestType: request.requestType, attribute: request.attribute,
                                               pid: request.pid, objectID: request.objectID)
        return try session.request(request.archive, matching: identity, timeout: timeout,
                                   expectedSequence: expectedSequence)
    }

    private struct ReadBudget {
        let deadline: ContinuousClock.Instant

        init(timeout: TimeInterval) throws {
            guard timeout.isFinite, timeout > 0, timeout <= 30 else {
                throw CLIOutputFailure(code: "invalidArguments",
                    message: "The accessibility read timeout must be greater than 0 and at most 30 seconds.")
            }
            deadline = .now + .seconds(timeout)
        }

        func remaining() throws -> TimeInterval {
            try Task.checkCancellation()
            let interval = ContinuousClock.now.duration(to: deadline)
            guard interval > .zero else {
                throw CLIOutputFailure(code: "treeUnavailable", message: "The physical accessibility read timed out.")
            }
            return Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        }
    }
}
